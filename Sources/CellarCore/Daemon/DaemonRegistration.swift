import Foundation

// MARK: - 注册态（镜像枚举切缝）

/// SMAppService 注册态镜像（Phase 2 WP2 切缝定版）：CellarCore 不 import
/// ServiceManagement——`SMAppService.Status → RegistrationStatus` 的 3 行 adapter
/// 在 App target（DaemonInstaller）；CellarCoreCheck 因此无需依赖 ServiceManagement
/// 即可测注册态语义。
public enum RegistrationStatus: Equatable, Sendable {
    /// 未注册（SMAppService.Status.notFound；含用户在授权队列中选择拒绝后的回落态）。
    case notRegistered
    /// 待系统授权（requiresApproval：注册已进入授权队列，等待用户在系统设置批准）。
    case pending
    /// 已启用（注册完成，daemon 由 launchd 随系统托管）。
    case enabled
}

// MARK: - 迁移引导（四象限）

/// 迁移检测四象限的引导语义（旧手工 plist 存在与否 × 注册态 → 面板行为文案）。
public enum MigrationGuidance: Equatable, Sendable {
    /// 无旧 plist + 未注册：正常安装入口。
    case normalInstall
    /// 无旧 plist + 已启用：正常（显示运行中）。
    case running
    /// 有旧 plist + 未注册：迁移引导（App 不执行任何 root 操作，先卸旧路线再注册）。
    case migrateFromLegacy
    /// 有旧 plist + 已启用：混合态清理引导（防重启后两份配置抢同一 label）。
    case cleanMixedState
}

/// 迁移检测纯函数（四象限表格逐行）。
/// pending 是授权轮询中的过渡态：面板另有「等待系统授权」状态行，引导沿用未注册
/// 象限——授权流程本身覆盖迁移语义，不另开分支。
public func migrationGuidance(legacyPlistExists: Bool, registration: RegistrationStatus) -> MigrationGuidance {
    switch (legacyPlistExists, registration) {
    case (true, .enabled):
        return .cleanMixedState
    case (true, .notRegistered), (true, .pending):
        return .migrateFromLegacy
    case (false, .enabled):
        return .running
    case (false, .notRegistered), (false, .pending):
        return .normalInstall
    }
}

// MARK: - 安装路线（防线 c 收敛纯函数）

/// daemon 安装路线。判定基于 launchctl print 的 program 路径——不依赖进程存活
/// （enabled 但瞬时崩溃时 program 行仍在，不会漏检）。
public enum DaemonRoute: Equatable, Sendable {
    /// App 托管（路径含 ".app/"：SMAppService 注册的内嵌 daemon）。
    case appManaged
    /// 手工路线（CLI 安装至 /Library/PrivilegedHelperTools）。
    case manual
    /// 无法判定（program 路径为空/不可解析：job 未加载或输出格式不符）。
    case unknown

    /// 从 `launchctl print system/com.cellar.daemon` 输出直接判定安装路线。
    /// 两种实测格式（2026-09-01，macOS 26.6.2）：
    /// - SMAppService/BTM 托管：**无 `program =` 行**，代之以
    ///   `managed_by = com.apple.xpc.ServiceManagement`（另有 `program identifier =
    ///   <bundle 相对路径>`）——只认 program 行会把托管任务误判为 .unknown
    /// - 手工路线（launchctl bootstrap）：`program = <绝对路径>`
    public static func route(fromPrintOutput output: String) -> DaemonRoute {
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("managed_by = "), line.contains("com.apple.xpc.ServiceManagement") {
                return .appManaged
            }
        }
        if let path = programPath(fromPrintOutput: output) {
            return daemonRoute(programPath: path)
        }
        return .unknown
    }

    /// 从 `launchctl print system/com.cellar.daemon` 输出提取 program 路径
    /// （行形如 `program = /path/to/binary`）。job 未加载/找不到服务时输出无
    /// program 行 → nil。
    public static func programPath(fromPrintOutput output: String) -> String? {
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("program = ") else { continue }
            let path = line.dropFirst("program = ".count).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            return path
        }
        return nil
    }
}

/// 路由判定纯函数：路径含 ".app/" → appManaged；空路径 → unknown；其余 → manual。
public func daemonRoute(programPath: String) -> DaemonRoute {
    if programPath.isEmpty { return .unknown }
    if programPath.contains(".app/") { return .appManaged }
    return .manual
}

// MARK: - install bootstrap 终败的 BTM 幽灵检测（0.20.1 方案 §3.1）

/// bootstrap 终败后的指引分流（纯函数判定——CellarCoreCheck 场景域钉死；CLI 侧只做
/// 子进程采集与文案渲染）。背景（真机定谳）：BTM 数据库中损坏记录（ad-hoc 签名 App
/// 的 LWCR cdhash 空集 → spawn 永远 EX_CONFIG）+ smd 周期性对账（10min–1h）反复以
/// 同 label 重新提交 → 手工 job 被顶、手工 bootstrap EIO——盲目重试 install 是死循环。
public enum BootstrapFailureGuidance: Equatable, Sendable {
    /// BTM 损坏记录：输出含 `managed_by = com.apple.xpc.ServiceManagement`
    /// ∧ `last exit code = 78`（EX_CONFIG）→ 指引 App 面板卸载 + `sudo sfltool resetbtm`。
    case btmCorruptedRecord
    /// 无 managed_by（bootout 后 launchd 清理竞态——真机实证：等 60s 重跑 install
    /// 幂等，bootout no-op 后 bootstrap 即成功）→ 指引等待重跑。
    case cleanupRace
    /// 其余形态：不附 BTM 指引（防误导），原始错误透传。
    case other

    /// `launchctl print system/com.cellar.daemon` 输出 → 指引分流（宽松匹配，
    /// 缺字段不崩；行扫描纪律与 DaemonRoute.route/BTMState.parseLaunchctlPrint 同款）。
    public static func classify(fromPrintOutput output: String) -> BootstrapFailureGuidance {
        var managedBySMD = false
        var lastExit78 = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("managed_by = "), line.contains("com.apple.xpc.ServiceManagement") {
                managedBySMD = true
            }
            if line.contains("last exit code = 78") {
                lastExit78 = true
            }
        }
        if managedBySMD && lastExit78 { return .btmCorruptedRecord }
        if !managedBySMD { return .cleanupRace }
        return .other
    }
}

// MARK: - 跨进程互斥常量（防线 b）

/// daemon 跨进程互斥锁路径。daemon main 中 flock 为第一条可执行逻辑（Logger 之后、
/// 核心装配之前）；/var/run 为 root 专属目录——daemon 以 root 运行。
public enum DaemonRegistration {
    public static let daemonLockPath = "/var/run/com.cellar.daemon.lock"
}

// MARK: - 数据目录属主校验（0.4.1 安全审计 F-3，纵深防御；0.5.0 修订：组属主不作要求）

/// 校验目录为 root 属主且无组/其他可写位（uid==0 ∧ mode & 0o022 == 0）。
/// 数据目录若可被非 root 预创建或写入，固定名临时文件（.policy.json.tmp）的
/// symlink 竞态即成为 root 写原语（CWE-59/61）——uid==0 ∧ 无组/其他可写位已完整
/// 覆盖该威胁面。**组属主不参与判定**：macOS 惯例 `/Library/Application Support`
/// 为 root:admin，root 进程 `createDirectory` 组继承 admin（gid 80）且无组写位，
/// 不构成写面——严格执行 gid==0 会让 install/bootstrap 对自己创建的目录自否
/// （真机 2026-09-03 实证：install 校验拒绝 + daemon fail-secure 退出双触发）。
/// stat 失败 → false。
public func verifyRootOwnedDirectory(path: String) -> Bool {
    var st = stat()
    guard stat(path, &st) == 0 else { return false }
    guard st.st_uid == 0 else { return false }
    return (st.st_mode & S_IWGRP) == 0 && (st.st_mode & S_IWOTH) == 0
}

// MARK: - daemon 编译产物源路径推导（0.23.11 B5-5：CLI install 源路径去 CWD 化）

extension DaemonRegistration {
    /// 自 CLI 可执行文件位置推导仓库根（0.23.11 B5-5）+ 百分号解码。
    /// **原 CWD 相对路径（".build/release/cellar-daemon"）为提权面**：用户在攻击者
    /// 可控目录执行 `sudo cellar install` 时解析到攻击者预置文件 → root copyItem +
    /// chmod 0755 → launchd root 执行（任意代码提权）。推导失败（可执行位置缺席/
    /// 无 Package.swift 标记祖先链/百分号解码失败）→ nil——CLI 侧显式报错拒装
    /// （防静默回退 CWD 解析）；产物存在性由 CLI 层 fileExists + isExecutableFile
    /// 双检承担。
    /// 纯函数面（CellarCoreCheck 直测：临时目录树多布局成功路径 + symlink 解析
    /// + 无标记拒绝 + nil 拒绝；CLI executable target 不可 import，故推导核心落本库）。
    ///
    /// 0.23.12 热修（真机实证）：0.23.11 的**三级硬编码上溯**对 SwiftPM 新构建布局
    /// （`.build/out/Products/<config>/cellar`——Xcode 26 工具链副产物，四层）少算
    /// 层级 → repoRoot 误判为 `.build/out` 子目录 → 产物路径双层嵌套（`.build/out/
    /// .build/release/...`，用户 `sudo cellar install` 实证）。改 **walk-up 找
    /// Package.swift 标记**：从可执行所在目录逐级上溯，Package.swift 在位即仓库根
    /// ——对任意布局深度鲁棒（标记文件 = 仓库根的语义定义，非层数猜测）；上限
    /// 16 级防环。安全等价论证不变：walk-up 链条沿**运行中二进制的真实祖先目录**，
    /// 攻击者要操纵即需让恶意目录出现在真实落位的祖先链上——运行中 cellar 在
    /// 攻击者目录 = 本已全盘皆输；CLI 层 fileExists + isExecutableFile 双检保留。
    public static func helperSourceRoot(fromExecutablePath executablePath: String?) -> String? {
        guard let executablePath else { return nil }
        // 先解析 symlink（_NSGetExecutablePath 结果可含符号链接——PATH 形态调用时
        // argv 可执行为 symlink，不解析则上溯起点错位）。
        let resolved = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        var directory = resolved.deletingLastPathComponent()
        for _ in 0..<16 {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory.path.removingPercentEncoding ?? directory.path
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }   // 到根未找到
            directory = parent
        }
        return nil
    }
}

// MARK: - XPC 客户端身份钉扎（0.23.13 B6-1 纯判定层；与 helperSourceRoot 同文件
// 同域——连接期/安装期路径与身份纪律自然归属；CellarCoreCheck 直测可达，先例
// 照 B5-5 helperSourceRoot 下沉）

/// App bundle 标识符单一真相常量（0.23.13 B6：客户端身份钉扎期望身份源）。
/// 与 App/CellarApp.xcodeproj/project.pbxproj 内 `PRODUCT_BUNDLE_IDENTIFIER =
/// com.cellar.app` 的一致性由 XPCPinningDomain 源钉断言（钉扎-16 随 B6-2 落地
/// ——防两处漂移）。
public enum ClientIdentity {
    public static let appBundleIdentifier = "com.cellar.app"
}

/// daemon 可执行路径 → 期望 App bundle 锚点（App-route）。
/// 判定：路径含 "/Contents/" 分量 → 取首个 "/Contents/" 前缀为 App bundle，
/// 且前缀末段须以 ".app" 结尾（语义标记：macOS bundle 布局约定，非层数硬编码
/// ——0.23.12 教训：勿对工具链/安装布局硬编码层数）。否则 nil = CLI-route（无锚）。
///
/// 两条独立守卫（归因注释分离——各自独立可测，是互为对照的覆盖证据）：
/// - **守卫一（子串存在性）**："/Contents/" 子串缺席 → nil（"/Contents 测试" 这类
///   恰好共享前缀字符的目录名不构成该分量——两侧斜杠俱全才算语义子串）；
/// - **守卫二（.app 收尾）**：前缀末段非 ".app" 收尾 → nil（防非 bundle 目录恰好
///   含 Contents 子目录被误判为 App bundle，如 `/Users/x/Contents/...`）。
public func appBundleAnchor(fromDaemonExecutablePath executablePath: String?) -> String? {
    guard let executablePath else { return nil }
    // 守卫一："/Contents/" 子串存在性（缺席 → 无锚）。
    guard let contentsRange = executablePath.range(of: "/Contents/") else { return nil }
    let prefix = String(executablePath[..<contentsRange.lowerBound])
    // 守卫二：前缀末段 .app 收尾（语义标记命中才算 App bundle）。
    guard prefix.hasSuffix(".app") else { return nil }
    return prefix
}

/// 提取面事实（daemon glue 从 SecCode 信息产出；nil = 提取失败/缺失——诚实缺席）。
public struct ClientIdentityFacts: Equatable, Sendable {
    /// SecCodeCheckValidity（identifier requirement）通过与否。
    public var validityPassed: Bool
    /// kSecCodeInfoIdentifier（签名标识符）。
    public var identifier: String?
    /// 主可执行路径（B6-2 extractClientIdentity 自签名信息字典提取）。
    public var executablePath: String?

    public init(validityPassed: Bool, identifier: String?, executablePath: String?) {
        self.validityPassed = validityPassed
        self.identifier = identifier
        self.executablePath = executablePath
    }
}

/// 期望身份（pinned 模式；**legacy 模式不构成本类型**——无锚形态在 daemon 侧走
/// .legacy 分支维持既有 admin 门，本判定路径对其不存在）。
public struct PinnedClientIdentity: Equatable, Sendable {
    /// 期望 bundle 标识符（常量 ClientIdentity.appBundleIdentifier——单一真相，
    /// 源钉对 pbxproj）。
    public var bundleIdentifier: String
    /// 锚点（daemon 自身所在 App bundle，appBundleAnchor 派生）。
    public var appPath: String
    /// appPath + "/Contents/MacOS/" + 可执行名（daemon 启动期读锚 Info.plist
    /// CFBundleExecutable，缺席 fallback = bundle 名——B6-2 resolveClientAnchor）。
    public var executablePath: String

    public init(bundleIdentifier: String, appPath: String, executablePath: String) {
        self.bundleIdentifier = bundleIdentifier
        self.appPath = appPath
        self.executablePath = executablePath
    }
}

/// 判定结果（deny reason 进 daemon 日志，不上 wire——wire 仅专属错误消息）。
public enum ClientIdentityVerdict: Equatable, Sendable {
    case match
    case deny(reason: String)
}

/// 客户端身份判定（纯函数，全矩阵直测）。
/// 判定序（每条 deny reason 独立可测；多字段同坏取首个 reason）：
/// **路径精确相等（承重墙）优先于标识符/签名**（信息最可信、最难共谋）。
public func evaluateClientIdentity(_ facts: ClientIdentityFacts, expected: PinnedClientIdentity) -> ClientIdentityVerdict {
    // 1) executablePath 缺失/不等于期望 → deny("路径不符")——nil 同走本臂
    //    （诚实缺席 fail-closed：提取失败绝不静默放行）。
    guard let path = facts.executablePath, path == expected.executablePath else {
        return .deny(reason: "路径不符")
    }
    // 2) identifier 缺失/不等 → deny("标识符不符")。
    guard let identifier = facts.identifier, identifier == expected.bundleIdentifier else {
        return .deny(reason: "标识符不符")
    }
    // 3) validityPassed == false → deny("签名校验未通过")。
    guard facts.validityPassed else {
        return .deny(reason: "签名校验未通过")
    }
    return .match
}