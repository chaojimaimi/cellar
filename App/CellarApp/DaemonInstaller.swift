import AppKit
import CellarCore
import Foundation
import ServiceManagement

// MARK: - 注册态 adapter（3 行切缝，§2.6 定版）

/// SMAppService.Status → RegistrationStatus：CellarCore 不 import ServiceManagement，
/// App 侧是唯一转换点（镜像枚举切缝）。
extension RegistrationStatus {
    init(_ status: SMAppService.Status) {
        switch status {
        case .requiresApproval: self = .pending
        case .enabled: self = .enabled
        // 本 SDK（macOS 26）共 4 态：.notFound（找不到服务，如 plist 无效）与
        // .notRegistered（unregister 后的干净态）都落入「未注册」安装态（实证 1.4）。
        case .notFound, .notRegistered: self = .notRegistered
        @unknown default: self = .notRegistered
        }
    }
}

/// 守护进程安装状态机（面板数据源）。
///
/// 并发定版（§2.6）：register/unregister 为同步 IPC → Task.detached 后台执行；
/// openSystemSettingsLoginItems 主 actor、仅进入 pending 时调一次；授权轮询 1s 间隔 /
/// 120s 上限、面板关闭即取消（stopPolling）。SMAppService 实例不跨 actor 传递
/// （使用处创建，不存成员）。本类型 @MainActor 全隔离——Swift 6 严格并发下状态只属主线程。
@MainActor
final class DaemonInstaller: ObservableObject {
    /// SMAppService daemon plist 名（按调用方主 bundle 的 Contents/Library/LaunchDaemons/ 解析）。
    nonisolated static let plistName = "com.cellar.daemon"
    /// 手工路线 plist（迁移四象限的 legacyPlistExists 输入）。
    nonisolated static let legacyPlistPath = "/Library/LaunchDaemons/com.cellar.daemon.plist"
    /// 嵌入 plist 文件名（bundle 内探测）。
    nonisolated static let embeddedPlistName = "com.cellar.daemon.plist"
    /// 授权轮询时长上限（秒，§2.6 定版）。
    nonisolated static let pollingLimitSeconds = 120

    @Published private(set) var registration: RegistrationStatus = .notRegistered
    @Published private(set) var route: DaemonRoute = .unknown
    @Published private(set) var guidance: MigrationGuidance = .normalInstall
    @Published private(set) var hasLegacyPlist = false
    /// 嵌入 plist 缺失但 XPC 可达（多副本先后注册的异常形态，§2.6）。
    @Published private(set) var anomaly = false
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?

    private var pollTask: Task<Void, Never>?
    private var settingsOpened = false

    // MARK: - 查询（面板出现 / 授权轮询 / 操作完成后刷新）

    /// 刷新注册态。⚠️ 主线程只做本地文件检查；SMAppService status（同步 XPC）与
    /// launchctl print（子进程 waitUntilExit）都在后台执行——在面板展示事务里阻塞
    /// 主线程会让 MenuBarExtra 窗口创建后永远不上屏（2026-09-01 真机二分实证）。
    func refresh() {
        let legacy = FileManager.default.fileExists(atPath: Self.legacyPlistPath)
        hasLegacyPlist = legacy
        Task.detached { [weak self] in
            let registration = RegistrationStatus(SMAppService.daemon(plistName: Self.plistName).status)
            let route = Self.queryRoute()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.registration = registration
                self.route = route
                self.guidance = migrationGuidance(
                    legacyPlistExists: legacy,
                    registration: registration
                )
                // 重开面板时续上授权轮询（评审 P2-3）；beginPolling 自带取消前任，安全。
                if registration == .pending {
                    self.beginPolling()
                }
                // 拒绝/回落未注册态：允许下次安装重新引导系统设置（评审 P2-4）。
                if registration == .notRegistered {
                    self.settingsOpened = false
                }
                self.refreshAnomaly(registration: registration)
            }
        }
    }

    /// 异常提示（§2.6）：本 bundle 嵌入 plist 缺失但 XPC getStatus 可达。XPC 同步调用
    /// 有 5s 超时上限 → 后台探测，不阻塞主线程；仅未注册态才探测（评审 P2-5：
    /// pending 轮询期间每秒探测注定被丢弃，白白打 mach service 连接）。
    private func refreshAnomaly(registration: RegistrationStatus) {
        guard !Self.embeddedPlistExists else {
            anomaly = false
            return
        }
        guard registration == .notRegistered else { return }
        Task.detached { [weak self] in
            let reachable = (try? DaemonXPCClient().getStatus()) != nil
            await MainActor.run {
                self?.anomaly = reachable
            }
        }
    }

    // MARK: - 安装 / 卸载（同步 IPC 后台执行）

    func install() {
        guard !busy else { return }
        busy = true
        lastError = nil
        Task.detached { [weak self] in
            let outcome = Self.registerBlocking()
            await MainActor.run { self?.handleRegister(outcome) }
        }
    }

    func uninstall() {
        guard !busy else { return }
        busy = true
        lastError = nil
        Task.detached { [weak self] in
            let outcome = Self.unregisterBlocking()
            await MainActor.run { self?.handleUnregister(outcome) }
        }
    }

    /// 面板关闭：取消授权轮询（MenuBarExtra 重开时 refresh() 重查，§2.6）。
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - 操作结果（主 actor）

    private func handleRegister(_ outcome: Result<RegistrationStatus, Error>) {
        busy = false
        switch outcome {
        case .success(let status):
            refresh()
            guard status == .pending else { return }
            openSettingsOnce()
            beginPolling()
        case .failure(let error):
            refresh()
            lastError = "注册失败：\(error.localizedDescription)"
        }
    }

    private func handleUnregister(_ outcome: Result<Void, Error>) {
        busy = false
        switch outcome {
        case .success:
            refresh()
        case .failure(let error):
            refresh()
            lastError = "卸载失败：\(error.localizedDescription)"
        }
    }

    /// 系统设置授权引导：只在进入 pending 时调一次——轮询循环内不得反复调，
    /// 否则会把系统设置反复拉前台（§2.6）。
    private func openSettingsOnce() {
        guard !settingsOpened else { return }
        settingsOpened = true
        SMAppService.openSystemSettingsLoginItems()
    }

    /// 授权轮询（§2.6 定版参数）：1s 间隔 / 120s 上限 / 面板关闭取消。
    /// 状态回落 notRegistered = 用户拒绝路径——停在状态行文案，不死轮询。
    private func beginPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for _ in 1...Self.pollingLimitSeconds {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
                if self.registration == .enabled { return }        // 授权完成
                if self.registration == .notRegistered { return }  // 拒绝路径
            }
        }
    }

    // MARK: - 后台阻塞调用（SMAppService 实例函数内创建，不跨 actor）

    /// 同步注册（后台线程）。首次注册预期抛错（code=1）且状态转 .requiresApproval
    /// （spike 实证）；其他错误（如 plist 无效）不落入 pending/enabled → 原样上抛。
    nonisolated static func registerBlocking() -> Result<RegistrationStatus, Error> {
        let daemon = SMAppService.daemon(plistName: plistName)
        do {
            try daemon.register()
        } catch {
            let status = RegistrationStatus(daemon.status)
            guard status == .pending || status == .enabled else { return .failure(error) }
        }
        return .success(RegistrationStatus(daemon.status))
    }

    /// 同步卸载。未注册态下 unregister 抛错可容忍（目标态已达成）；enabled/pending 下
    /// 抛错才视为失败（不静默）。
    nonisolated static func unregisterBlocking() -> Result<Void, Error> {
        let daemon = SMAppService.daemon(plistName: plistName)
        do {
            try daemon.unregister()
        } catch {
            guard RegistrationStatus(daemon.status) != .notRegistered else { return .success(()) }
            return .failure(error)
        }
        return .success(())
    }

    // MARK: - 路由 / 文件探测

    /// 路由来源（防线 c）：launchctl print system/com.cellar.daemon 的 program 路径。
    /// 非 root 亦可读已加载系统服务（2026-09-01 实测）；无 program 行 → .unknown。
    private nonisolated static func queryRoute() -> DaemonRoute {
        let output = runLaunchctl(["print", "system/com.cellar.daemon"])
        guard let path = DaemonRoute.programPath(fromPrintOutput: output) else { return .unknown }
        return daemonRoute(programPath: path)
    }

    private static var embeddedPlistExists: Bool {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(embeddedPlistName)")
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 运行 launchctl 并返回 stdout（print 输出）。
    private nonisolated static func runLaunchctl(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        process.waitUntilExit()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}