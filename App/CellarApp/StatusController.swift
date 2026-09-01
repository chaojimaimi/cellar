import CellarCore
import Combine
import Foundation

/// 控制操作反馈（规格 §2.3 三态 + §3.4 stale 分支）。非成功态全部红色系，
/// 面板按 case 渲染；Message 为 daemon 拒绝原文或本地预检文案。
enum ControlFeedback: Equatable {
    case success(String)
    /// daemon 拒绝原文上屏（含面板本地 LimitPolicy 预检失败文案——同一条反馈行）。
    case daemonRejected(String)
    /// 传输失败（timeout/connectionFailed）。
    case transferFailed
    /// stale daemon：版本不匹配（旧二进制无 admin 组判定，拒绝原文对面板用户是错误引导）。
    case staleDaemon
}

/// 面板运行态控制器：轮询调度、busy 门控、控制操作（全部 XPC 后台执行）。
///
/// 与 DaemonInstaller 职责分离（规格 §2.1）：installer 管注册态，本控制器管运行态/
/// 策略控制；单向接线 = 面板 onChange(of: installer.registration) →
/// `registrationChanged(_:)`，不反向依赖。
///
/// 主线程纪律（WP2 实证）：任何 XPC 调用不得同步出现在主线程——一切走
/// Task.detached，结果经 MainActor.run 回到主 actor 更新状态。
@MainActor
final class StatusController: ObservableObject {
    @Published private(set) var daemonStatus: DaemonStatus?
    @Published private(set) var connection: ConnectionState = .unknown
    @Published private(set) var busy = false
    @Published private(set) var controlFeedback: ControlFeedback?

    /// 控制成功回调（面板据此同步滑杆本地态；轮询回包不回写滑杆——规格 §2.3
    /// 同步时机 = 面板打开 + 应用成功）。
    var onLimitsApplied: ((Int, Int) -> Void)?

    /// ⚠️ nonisolated(unsafe)：deinit（非隔离）需取消轮询 Task；属性仅在主 actor
    /// 方法或 deinit 中访问（Task.cancel() 本身线程安全），无数据竞争面。
    private nonisolated(unsafe) var pollTask: Task<Void, Never>?

    deinit {
        pollTask?.cancel()   // MenuBarExtra 视图重建后防多实例轮询泄漏（规格 §2.6）
    }

    // MARK: - 轮询调度（规格 §2.2）

    /// 换档：cancel 旧 Task + 立即单次刷新 + 以新间隔重启（cancel+restart 定版）。
    /// nil 间隔 = 不轮询（未注册）。循环体内串行（await 完成再 sleep），天然防
    /// 5s 超时下的请求堆积；尾部 busy 门控跳过本轮（控制在途时轮询静默）。
    ///
    /// 与 installer 授权轮询的叠加：pending 期间本控制器不轮询（daemonRegistered
    /// 门控）；授权完成 installer 轮询自退、本控制器接棒——勿自行「优化」此推演。
    func setPolling(panelVisible: Bool, daemonRegistered: Bool) {
        pollTask?.cancel()
        pollTask = nil
        guard let interval = refreshInterval(panelVisible: panelVisible, daemonRegistered: daemonRegistered) else {
            return
        }
        // 换档即立即补一次刷新：防「面板打开后最长 60s 空窗」；控制在途时跳过
        // 立即刷新（控制结果回包即最新，无需轮询抢占），但轮询循环照常重启。
        if !busy {
            Task { await refreshOnce() }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                guard !self.busy else { continue }   // busy 门控：跳过本轮（规格 §2.2 P1）
                await self.refreshOnce()
            }
        }
    }

    /// registration 单向入口（规格 §2.1）：离开 .enabled → 停轮询 + 清空状态
    /// （daemonStatus=nil、connection=.unknown）——防残留 .unreachable 让图标永久
    /// .alert（用户主动卸载 ≠ 故障）；回到 .enabled → 以面板可见档位接棒轮询。
    func registrationChanged(_ registration: RegistrationStatus) {
        guard registration == .enabled else {
            pollTask?.cancel()
            pollTask = nil
            daemonStatus = nil
            connection = .unknown
            controlFeedback = nil
            return
        }
        setPolling(panelVisible: true, daemonRegistered: true)
    }

    /// 面板打开时同步滑杆值的来源（仅本地态初始化用，非轮询回写）。
    func syncSliderFromStatus() -> (upper: Int, hysteresis: Int)? {
        guard let status = daemonStatus else { return nil }
        return (status.upperLimit, status.hysteresis)
    }

    /// 面板本地预检失败的上屏入口（不发 XPC；文案由面板给出）。
    func reportLocalRejection(_ message: String) {
        controlFeedback = .daemonRejected(message)
    }

    // MARK: - 控制操作（规格 §2.3；全部 XPC 后台）

    /// 应用上限/滞回。成功 → 回包更新 daemonStatus + onLimitsApplied 同步滑杆。
    func applyLimits(upperLimit: Int, hysteresis: Int) {
        runControl(
            operation: { try DaemonXPCClient().setLimits(upperLimit: upperLimit, hysteresis: hysteresis) },
            successFeedback: "已应用：上限 \(upperLimit)%、滞回 \(hysteresis)"
        ) { [weak self] status in
            self?.onLimitsApplied?(status.upperLimit, status.hysteresis)
        }
    }

    /// 总开关：mode 驱动「停用限充 / 启用限充」（禁用/启用命令语义相反）。
    func toggleCharging(enabled: Bool) {
        if enabled {
            runControl(operation: { try DaemonXPCClient().enable() }, successFeedback: "已启用限充")
        } else {
            runControl(operation: { try DaemonXPCClient().disable() }, successFeedback: "已停用限充（恢复默认充电）")
        }
    }

    /// 统一控制执行器：busy 防重入（非静默）+ XPC 后台 + 结果回主 actor。
    private func runControl(
        operation: @escaping @Sendable () throws -> DaemonStatus,
        successFeedback: String,
        onSuccess: (@MainActor (DaemonStatus) -> Void)? = nil
    ) {
        guard !busy else { return }
        busy = true
        controlFeedback = nil
        Task.detached { [weak self] in
            let result: Result<DaemonStatus, DaemonClientError>
            do {
                result = .success(try operation())
            } catch let error as DaemonClientError {
                result = .failure(error)
            } catch {
                // 协议域外错误（编码失败等）：按 daemon 拒绝呈现，不静默。
                result = .failure(.daemonError(String(describing: error)))
            }
            await MainActor.run {
                self?.finishControl(result: result, successFeedback: successFeedback, onSuccess: onSuccess)
            }
        }
    }

    /// 控制结果处理（主 actor）：成功 → 状态更新 + 反馈 + 滑杆同步回调；
    /// 失败三态：daemonError → stale 版本比对；timeout/connectionFailed →
    /// connection=.unreachable + 「守护进程未运行或无响应」。
    private func finishControl(
        result: Result<DaemonStatus, DaemonClientError>,
        successFeedback: String,
        onSuccess: (@MainActor (DaemonStatus) -> Void)?
    ) {
        busy = false
        switch result {
        case .success(let status):
            daemonStatus = status
            connection = .connected
            controlFeedback = .success(successFeedback)
            onSuccess?(status)
        case .failure(.daemonError(let message)):
            detectStaleBeforeReject(message)
        case .failure(.timeout), .failure(.connectionFailed):
            connection = .unreachable
            controlFeedback = .transferFailed
        }
    }

    /// stale daemon 版本比对（规格 §3.4）：daemonError 原文不可信时经 getStatus
    /// 比对 status.version 与 DaemonXPC.daemonVersion。不匹配 → 上屏版本过旧 +
    /// 重装入口（面板 daemon 区按钮即入口）；匹配 → 按新版拒绝文案展示。
    /// getStatus 亦失败（无法比对）→ 保守展示原文。
    private func detectStaleBeforeReject(_ message: String) {
        Task.detached { [weak self] in
            let version = (try? DaemonXPCClient().getStatus())?.version
            await MainActor.run {
                guard let self else { return }
                if let version, version != DaemonXPC.daemonVersion {
                    self.controlFeedback = .staleDaemon
                } else {
                    self.controlFeedback = .daemonRejected(message)
                }
            }
        }
    }

    // MARK: - 内部：单次刷新

    /// 单次 getStatus（XPC 在 detached Task——主线程永不阻塞，WP2 实证）。
    /// 失败（超时/连接失败）→ connection=.unreachable；成功 → .connected。
    private func refreshOnce() async {
        let status = await Task.detached { () -> DaemonStatus? in
            try? DaemonXPCClient().getStatus()
        }.value
        guard !Task.isCancelled else { return }
        daemonStatus = status
        connection = status == nil ? .unreachable : .connected
    }
}