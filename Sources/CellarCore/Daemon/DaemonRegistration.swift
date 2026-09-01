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