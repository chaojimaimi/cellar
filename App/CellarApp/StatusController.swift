import CellarCore
import Combine
import Foundation
import os

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

/// status 派生失败横幅形态（WP5 §2.3 P1-1 配套）：daemonStatus.lastAction 为
/// enforce:error / enforce:verifyFailed 时由 StatusController 暴露——**不占用
/// controlFeedback 通道**（daemon 侧 enforce 失败 WP4 横幅本不覆盖；原「双通道」
/// 表述系引用未接线的通道，本条修复该矛盾）。
enum StatusFailureKind: Equatable {
    /// 写/传输失败（enforce:error）——红线 5。
    case writeFailed
    /// 外部写者冲突显式化（enforce:verifyFailed）。
    case conflictSuspected

    /// 横幅文案（与通知文案同源，§2.3 定版常量集中 NotificationService）。
    var message: String {
        switch self {
        case .writeFailed: return NotificationService.writeFailedMessage
        case .conflictSuspected: return NotificationService.conflictSuspectedMessage
        }
    }

    /// 从 daemonStatus 派生（⚠️ lastAction 字面量与 CellarCore 通知分类同契约——
    /// 变更两侧同步暴露，CellarCoreCheck 钉死精确值）。
    init?(status: DaemonStatus) {
        switch status.lastAction {
        case "enforce:error": self = .writeFailed
        case "enforce:verifyFailed": self = .conflictSuspected
        default: return nil
        }
    }
}

/// 控制动作的可重放描述（告警横幅「重试」重发上次动作，规格 §2.7 分支 ①：
/// runControl 入口记录、成功清除）。
enum ControlAttempt: Equatable {
    case setLimits(upperLimit: Int, hysteresis: Int)
    case setChargingEnabled(Bool)

    /// 横幅摘要文案（上次动作是什么）。
    var summary: String {
        switch self {
        case .setLimits(let upperLimit, _):
            return "设置上限 \(upperLimit)%"
        case .setChargingEnabled(true):
            return "启用限充"
        case .setChargingEnabled(false):
            return "停用限充"
        }
    }
}

/// 面板运行态控制器：轮询调度、busy 门控、控制操作（全部 XPC 后台执行）、
/// 遥测采样（面板可见期 IOKit 只读快照，独立门控）。
///
/// 与 DaemonInstaller 职责分离（规格 §2.1）：installer 管注册态，本控制器管运行态/
/// 策略控制/遥测；单向接线 = 组合根 onChange(of: installer.registration) →
/// `registrationChanged(_:)`，不反向依赖。
///
/// 主线程纪律（WP2 实证）：任何 XPC/IOKit 调用不得同步出现在主线程——一切走
/// Task.detached，结果经 MainActor.run 回到主 actor 更新状态。
@MainActor
final class StatusController: ObservableObject {
    @Published private(set) var daemonStatus: DaemonStatus?
    @Published private(set) var connection: ConnectionState = .unknown
    @Published private(set) var busy = false
    @Published private(set) var controlFeedback: ControlFeedback?
    @Published private(set) var lastAttempt: ControlAttempt?
    /// status 派生失败横幅（WP5 §2.3 P1-1 配套）：enforce:error / enforce:verifyFailed
    /// 时呈现（不进 controlFeedback 通道；首次样本即呈现——失败类无需转移守卫）。
    @Published private(set) var statusFailure: StatusFailureKind?
    /// 遥测快照（App 进程内 IOKit 只读，规格 §2.1 语义分源）。采样失败 → nil
    /// （不进横幅、不触发图标 .alert——失联才有 alert 的不变量不破）。
    @Published private(set) var batterySnapshot: BatterySnapshot?

    /// 通知事件出口（CellarApp 注入 NotificationService.deliver；§2.3 单一入口投递）。
    var onNotificationEvent: ((CellarNotificationEvent) -> Void)?

    /// 通知分类基线（ingest 每样本推进；首样本语义见 CellarCore notificationEvents）。
    private var notificationBaseline: DaemonStatus?

    /// 菜单栏图标状态推导（MenuBarIconLabel 观察；纯函数映射见 CellarCore）。
    var iconState: MenuBarIconState {
        menuBarIconState(status: daemonStatus, connection: connection)
    }

    /// 控制成功回调（面板据此同步滑杆本地态；轮询回包不回写滑杆——规格 §2.3
    /// 同步时机 = 面板打开 + 应用成功）。
    var onLimitsApplied: ((Int, Int) -> Void)?

    /// 当前面板可见性（registrationChanged 入 .enabled 时按此档位接棒轮询；
    /// 组合根提升后轮询不依赖面板首开，规格 §2.8）。
    private var panelVisible = false
    private let batteryMonitor = BatteryMonitor.makeDefault()

    /// ⚠️ nonisolated(unsafe)：deinit（非隔离）需取消两个轮询 Task；属性仅在主 actor
    /// 方法或 deinit 中访问（Task.cancel() 本身线程安全），无数据竞争面。
    private nonisolated(unsafe) var pollTask: Task<Void, Never>?
    private nonisolated(unsafe) var telemetryTask: Task<Void, Never>?

    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "telemetry")

    deinit {
        pollTask?.cancel()        // MenuBarExtra 视图重建后防多实例轮询泄漏（规格 §2.6）
        telemetryTask?.cancel()
    }

    // MARK: - 轮询调度（规格 §2.2）

    /// 换档：cancel 旧 Task + 立即单次刷新 + 以新间隔重启（cancel+restart 定版）。
    /// nil 间隔 = 不轮询（未注册）。循环体内串行（await 完成再 sleep），天然防
    /// 5s 超时下的请求堆积；尾部 busy 门控跳过本轮（控制在途时轮询静默）。
    ///
    /// 与 installer 授权轮询的叠加：pending 期间本控制器不轮询（daemonRegistered
    /// 门控）；授权完成 installer 轮询自退、本控制器接棒——勿自行「优化」此推演。
    func setPolling(panelVisible: Bool, daemonRegistered: Bool) {
        self.panelVisible = panelVisible
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
    /// （daemonStatus=nil、connection=.unknown、lastAttempt=nil）——防残留
    /// .unreachable 让图标永久 .alert（用户主动卸载 ≠ 故障）；回到 .enabled →
    /// 按当前面板可见档位接棒轮询（组合根提升：App 启动注册即入 60s 图标档，
    /// 规格 §2.8）。遥测与 registration 无关（门控只有 panelVisible），不清快照。
    func registrationChanged(_ registration: RegistrationStatus) {
        guard registration == .enabled else {
            pollTask?.cancel()
            pollTask = nil
            daemonStatus = nil
            connection = .unknown
            controlFeedback = nil
            lastAttempt = nil
            // 基线复位：重注册后首样本按「首样本」语义分类（limitReached 抑制、
            // 失败类破例），失败横幅派生自 daemonStatus（nil 即清除）。
            notificationBaseline = nil
            statusFailure = nil
            return
        }
        setPolling(panelVisible: panelVisible, daemonRegistered: true)
    }

    // MARK: - 统一状态收口（WP5 §2.3 单一入口）

    /// 统一状态收口：refreshOnce 与 finishControl 两条路径共用——通知分类
    /// （previous 基线随每次更新推进，防双路径漏报/重报）→ 事件投递；
    /// status 派生失败横幅同步。status == nil（轮询失败）不清基线、不产出事件。
    func ingest(status: DaemonStatus?) {
        if let status {
            let events = notificationEvents(previous: notificationBaseline, current: status)
            notificationBaseline = status
            for event in events {
                onNotificationEvent?(event)
            }
        }
        daemonStatus = status
        connection = status == nil ? .unreachable : .connected
        statusFailure = status.flatMap(StatusFailureKind.init)
    }

    /// 面板打开时同步滑杆值的来源（仅本地态初始化用，非轮询回写）。
    func syncSliderFromStatus() -> (upper: Int, hysteresis: Int)? {
        guard let status = daemonStatus else { return nil }
        return (status.upperLimit, status.hysteresis)
    }

    /// 面板本地预检失败的上屏入口（不发 XPC；文案由面板给出）。
    func reportLocalRejection(_ message: String) {
        controlFeedback = .daemonRejected(message)
        lastAttempt = nil
    }

    // MARK: - 遥测采样（规格 §2.1 P0-2 独立门控）

    /// 遥测档启停：面板可见 1s、关闭 nil（停止采样）——与 status 轮询并行独立、
    /// 不复用同一循环。翻档沿用 cancel + 立即补采样 + 重启。未注册 daemon 时
    /// 遥测照常（门控只有 panelVisible；安装前展示产品能读什么是招牌场景）。
    func setTelemetry(panelVisible: Bool) {
        telemetryTask?.cancel()
        telemetryTask = nil
        guard let interval = telemetrySampleInterval(panelVisible: panelVisible) else {
            return
        }
        if panelVisible {
            Task { await sampleBatteryOnce() }   // 打开即补一次快照
        }
        telemetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                await self.sampleBatteryOnce()
            }
        }
    }

    /// 单次电池快照（IOKit 在 detached Task 后台执行——主线程永不阻塞）。
    /// 采样失败 → batterySnapshot=nil + os_log（不进横幅、不触发图标 .alert）。
    private func sampleBatteryOnce() async {
        let snapshot = await Task.detached { [batteryMonitor] in
            try? batteryMonitor.snapshot()
        }.value
        guard !Task.isCancelled else { return }
        batterySnapshot = snapshot
        if snapshot == nil {
            Self.log.error("电池快照采样失败（面板显「遥测不可用」降级形态）")
        }
    }

    // MARK: - 控制操作（规格 §2.3；全部 XPC 后台）

    /// 应用上限/滞回。成功 → 回包更新 daemonStatus + onLimitsApplied 同步滑杆。
    func applyLimits(upperLimit: Int, hysteresis: Int) {
        runControl(
            attempt: .setLimits(upperLimit: upperLimit, hysteresis: hysteresis),
            operation: { try DaemonXPCClient().setLimits(upperLimit: upperLimit, hysteresis: hysteresis) },
            successFeedback: "已应用：上限 \(upperLimit)%、滞回 \(hysteresis)"
        ) { [weak self] status in
            self?.onLimitsApplied?(status.upperLimit, status.hysteresis)
        }
    }

    /// 总开关：mode 驱动「停用限充 / 启用限充」（禁用/启用命令语义相反）。
    func toggleCharging(enabled: Bool) {
        if enabled {
            runControl(attempt: .setChargingEnabled(true), operation: { try DaemonXPCClient().enable() }, successFeedback: "已启用限充")
        } else {
            runControl(attempt: .setChargingEnabled(false), operation: { try DaemonXPCClient().disable() }, successFeedback: "已停用限充（恢复默认充电）")
        }
    }

    /// 横幅「重试」= 重发上次动作（分支 ①；lastAttempt 在 runControl 入口记录）。
    func retryLastAttempt() {
        guard let attempt = lastAttempt, !busy else { return }
        switch attempt {
        case .setLimits(let upperLimit, let hysteresis):
            applyLimits(upperLimit: upperLimit, hysteresis: hysteresis)
        case .setChargingEnabled(let enabled):
            toggleCharging(enabled: enabled)
        }
    }

    /// 横幅「重试」= 立即单次刷新（分支 ③：轮询致 unreachable 且无上次动作）。
    func refreshNow() {
        guard !busy else { return }
        Task { await refreshOnce() }
    }

    /// 统一控制执行器：busy 防重入（非静默）+ XPC 后台 + 结果回主 actor。
    /// lastAttempt 在入口记录（分支① 重试依据），成功清除（成功反馈自动清横幅）。
    private func runControl(
        attempt: ControlAttempt,
        operation: @escaping @Sendable () throws -> DaemonStatus,
        successFeedback: String,
        onSuccess: (@MainActor (DaemonStatus) -> Void)? = nil
    ) {
        guard !busy else { return }
        busy = true
        controlFeedback = nil
        lastAttempt = attempt
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

    /// 控制结果处理（主 actor）：成功 → 状态更新 + 反馈 + 滑杆同步回调 +
    /// lastAttempt 清除；失败三态：daemonError → stale 版本比对；timeout/
    /// connectionFailed → connection=.unreachable + 「守护进程未运行或无响应」。
    private func finishControl(
        result: Result<DaemonStatus, DaemonClientError>,
        successFeedback: String,
        onSuccess: (@MainActor (DaemonStatus) -> Void)?
    ) {
        busy = false
        switch result {
        case .success(let status):
            ingest(status: status)
            controlFeedback = .success(successFeedback)
            lastAttempt = nil
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
    /// 统一走 ingest（§2.3 单一入口：通知分类 + 失败横幅派生）。
    private func refreshOnce() async {
        let status = await Task.detached { () -> DaemonStatus? in
            try? DaemonXPCClient().getStatus()
        }.value
        guard !Task.isCancelled else { return }
        ingest(status: status)
    }
}
