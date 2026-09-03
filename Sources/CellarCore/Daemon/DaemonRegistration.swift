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