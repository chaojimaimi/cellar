import CellarCore
import CellarUI
import Combine
import Foundation
import os

// WP4：ControlFeedback / StatusFailureKind 两类型按硬事实 3 判据迁 CellarCore
// （依赖闭包仅 Foundation；用户可见串剥离）——本文件仅保留 App 域文案投影。

/// StatusFailureKind 的 App 域横幅文案（Core 枚举本体已迁；S3 起经 CellarL10n
/// 解析 notification.* key——与通知文案同 catalog 同源，§2.3/§4.2 定版）。
/// 现文案原样，零行为变化。
@MainActor
final class StatusController: ObservableObject {

    @Published private(set) var daemonStatus: DaemonStatus?
    @Published private(set) var connection: ConnectionState = .unknown
    @Published private(set) var busy = false
    @Published private(set) var controlFeedback: ControlFeedback?
    /// 动作完成上升沿检测（ingest 用；lastAction 锁存语义下的 prev 值）。
    private var lastActionLiteral: String?
    /// success 反馈自动消退任务（新 success 重置计时；失败/告警类常驻不清）。
    private var successFeedbackClearTask: Task<Void, Never>?
    @Published private(set) var lastAttempt: ControlAttempt?
    /// status 派生失败横幅（WP5 §2.3 P1-1 配套）：enforce:error / enforce:verifyFailed
    /// 时呈现（不进 controlFeedback 通道；首次样本即呈现——失败类无需转移守卫）。
    /// WP2 扩充：fullOnce 终态字面量（done/timeout/crash-recovery）同通道呈现。
    @Published private(set) var statusFailure: StatusFailureKind?
    /// 活跃一次性动作（daemonStatus.action 派生；WP2 P2-4 接线——动作区/禁用态依据）。
    @Published private(set) var action: OneShotAction?
    /// 遥测快照（App 进程内 IOKit 只读，规格 §2.1 语义分源）。采样失败 → nil
    /// （不进横幅、不触发图标 .alert——失联才有 alert 的不变量不破）。
    @Published private(set) var batterySnapshot: BatterySnapshot?
    /// App 侧 IOPS 实时电源态（WP5 §2.4 图标即时化数据源；nil = 尚未收到电源
    /// 事件/读取失败——图标回退 daemonStatus 快照，零行为变化）。
    @Published private(set) var powerOverride: PowerOverride?
    /// IOPS 插拔电订阅（create-rule 所有权与释放见 PowerSourceMonitor）。
    private let powerSourceMonitor = PowerSourceMonitor()

    /// 通知事件出口（CellarApp 注入 NotificationService.deliver；§2.3 单一入口投递）。
    /// WP2'：载荷附带 lastPercent——放电终态文案「当前电量 N%」由 App 按
    /// event.kind + status.lastPercent 组装（评审 P2-6：参数不进 lastAction 线格式）。
    var onNotificationEvent: ((CellarNotificationEvent, Int?) -> Void)?

    /// 通知分类基线（ingest 每样本推进；首样本语义见 CellarCore notificationEvents）。
    private var notificationBaseline: DaemonStatus?

    /// 菜单栏图标状态推导（MenuBarIconLabel 观察；纯函数映射见 CellarCore）。
    /// WP5 §2.4：IOPS 实时电源态 override 参与规则 4/5——图标随插拔电即时翻转。
    var iconState: MenuBarIconState {
        menuBarIconState(status: daemonStatus, connection: connection, powerOverride: powerOverride)
    }

    /// 启动期自标定（WP5 真机取证·实例替换修复）：CellarApp.init 早期访问
    /// @StateObject 拿到的是被 SwiftUI 丢弃的临时实例——deinit 尸体链实锤（启动
    /// ~100ms 内三个实例全部释放，monitor 随葬、IOPS 通知源被摘除，图标即时化
    /// 静默失效）。修法 = WP3 StyleController 同款：自标定在自身 init 完成，
    /// **幸存实例诞生即自带**后台轮询档 + IOPS 即时化订阅；临时实例同样自装
    /// 随析构自摘（install 幂等 + deinit 摘源，无害）。
    init() {
        // 双表面初值全不可见 → 轮询 60s 档 + 遥测停（refreshCadence 统一裁决）。
        refreshCadence()
        powerSourceMonitor.controller = self
        powerSourceMonitor.install()
    }

    /// IOPS 实时电源态写入（PowerSourceMonitor 回调；图标即时翻转数据源）。
    func apply(powerOverride: PowerOverride) {
        self.powerOverride = powerOverride
    }

    /// daemon 能力清单透出（WP2' §2.1）：nil = 旧 daemon 未上报（升级提示）；
    /// [] = 已上报但不含 discharge（机型不支持）。放电按钮显示条件的消费面。
    var capabilities: [String]? {
        daemonStatus?.capabilities
    }

    /// 当前面板可见性（多表面仲裁输入之一：面板表面）。
    private var panelVisible = false
    /// 当前主窗口可见性（多表面仲裁输入之二：主窗口表面）。
    private var mainWindowVisible = false
    /// 最近已知注册态（registrationChanged 维护）：连接失败按其判定语义——已注册
    /// 失联 = 故障告警；未注册失联 = 「未安装」常态（不告警、图标不 .alert）。
    private var lastKnownRegistration: RegistrationStatus = .notRegistered
    private let batteryMonitor = BatteryMonitor.makeDefault()

    /// 时间估算样本环（Phase 5 v1.2 §3.6）：遥测管道挂载 (Date, percent) 环形
    /// 缓冲，容量 900 点 = 15 分钟 @1s（内存 ~14KB）；仅遥测运行期采样（追加点
    /// 位于 sampleBatteryOnce）。
    private var sampleRing: [TimeSample] = []
    private static let sampleRingCapacity = 900
    /// 上一快照电源态（翻转清环检测基线；nil = 环尚无基线）。
    private var lastSamplePowerState: (isCharging: Bool, externalConnected: Bool)?
    /// 时间估算只读投影（DashboardView 消费；TimeEstimator 内部再做新鲜度截断
    /// 与连续段校验——本环只保证追加顺序与电源态清环）。
    var estimateSamples: [TimeSample] { sampleRing }

    /// ⚠️ nonisolated(unsafe)：deinit（非隔离）需取消两个轮询 Task；属性仅在主 actor
    /// 方法或 deinit 中访问（Task.cancel() 本身线程安全），无数据竞争面。
    private nonisolated(unsafe) var pollTask: Task<Void, Never>?
    private nonisolated(unsafe) var telemetryTask: Task<Void, Never>?

    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "telemetry")

    deinit {
        pollTask?.cancel()        // MenuBarExtra 视图重建后防多实例轮询泄漏（规格 §2.6）
        telemetryTask?.cancel()
    }

    // MARK: - 轮询调度（规格 §2.2 + Phase 5 v1.2 §2.3 多表面仲裁）

    /// 面板可见性换档（Phase 5 v1.2 §2.3）：与 setMainWindowVisible 对称——防漏停
    /// 要求两入口 appear 设 true / disappear 设 false（R-2 走查项）。最小化语义：
    /// macOS 窗口最小化不触发 onDisappear——最小化视同可见（1s 采样继续），属
    /// 可接受行为（R1 P3 注明，不引入 scenePhase 追踪）。
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        refreshCadence()
    }

    /// 主窗口可见性换档（与 setPanelVisible 同语义的第二个表面）。
    func setMainWindowVisible(_ visible: Bool) {
        mainWindowVisible = visible
        refreshCadence()
    }

    /// 内部合并裁决（§2.3）：任一表面可见 → 遥测 1s + 轮询 1s；全不可见 →
    /// 遥测停（nil）+ 轮询 60s（轮询恒在不做 nil，注册态 freshness 语义保持）。
    /// 换档即立即补一次刷新：防「表面打开后最长 60s 空窗」；控制在途时跳过
    /// 立即刷新（控制结果回包即最新，无需轮询抢占），但轮询循环照常重启；
    /// 遥测同款：翻档到可见档即补一次采样。两管线并行独立、不复用同一循环
    /// （规格 §2.1 P0-2 独立门控语义保留）。
    private func refreshCadence() {
        let anyVisible = panelVisible || mainWindowVisible
        pollTask?.cancel()
        pollTask = nil
        let interval = refreshInterval(panelVisible: anyVisible)
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
        telemetryTask?.cancel()
        telemetryTask = nil
        guard let telemetryInterval = telemetrySampleInterval(panelVisible: anyVisible) else {
            return
        }
        if anyVisible {
            Task { await sampleBatteryOnce() }   // 翻档可见即补一次快照
        }
        telemetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(telemetryInterval))
                guard let self, !Task.isCancelled else { return }
                await self.sampleBatteryOnce()
            }
        }
    }

    /// registration 单向入口（双路线解耦定版）：维护 lastKnownRegistration（连接
    /// 失败的告警语义判定依据）+ 复位通知基线/失败横幅。**不清 daemonStatus、不停
    /// 轮询**——XPC 应答即真相：手工路线 daemon 运行中就如实显示运行中；daemon 真
    /// 消失时 refreshOnce 失败自行驱动 connection/.unreachable 或 .unknown。
    func registrationChanged(_ registration: RegistrationStatus) {
        lastKnownRegistration = registration
        guard registration != .enabled else { return }
        // 离开 .enabled：通知基线/失败横幅复位（重注册后首样本语义；防残留误导）。
        notificationBaseline = nil
        statusFailure = nil
        lastActionLiteral = nil
        successFeedbackClearTask?.cancel()
        controlFeedback = nil
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
                onNotificationEvent?(event, status.lastPercent)
            }
            // 动作完成上升沿（真机验收修正 2026-09-02）：done 已剥离失败横幅
            // 通道（红色告警 + 锁存常驻——成功终态语义错位），改走 success 反馈
            // + 5s 自动消退；lastAction 锁存期上升沿只触发一次（prev==done 不重报）。
            // WP3：calibration:done 同形态（成功横幅「校准完成」——完成文案含
            // 「请立即接通电源」，R1 P3-1）。
            let calibrationDone = status.lastAction == "calibration:done"
            let isDone = calibrationDone
                || status.lastAction == "fullOnce:done"
                || status.lastAction == "dischargeToLimit:done"
            let wasDone = lastActionLiteral == "calibration:done"
                || lastActionLiteral == "fullOnce:done"
                || lastActionLiteral == "dischargeToLimit:done"
            if isDone && !wasDone {
                // done 终态按动作类型拆 key（「充满一次」/放电到上限的
                // kindWord 组装不适合单格式串——zh 引号差异在 en 无对应形态；
                // 校准完成走通知同 catalog 专属 key）。
                setSuccessFeedback(calibrationDone
                    ? CellarL10n.s("notification.calibrationCompleted")
                    : status.lastAction == "fullOnce:done"
                        ? CellarL10n.s("status.doneFullOnce")
                        : CellarL10n.s("status.doneDischarge"))
            }
            lastActionLiteral = status.lastAction
        }
        daemonStatus = status
        // 连接态语义（双路线解耦定版）：已注册（enabled）失联 = 故障告警（pending
        // 期 daemon 尚未运行，落 .unknown 不告警）；
        // 未注册失联 = 「未安装」常态（.unknown，不告警）。
        connection = status == nil
            ? (lastKnownRegistration == .enabled ? .unreachable : .unknown)
            : .connected
        statusFailure = status.flatMap(StatusFailureKind.init)
        action = status?.action
    }

    /// success 反馈设置 + 5s 自动消退（真机验收修正 2026-09-02：成功类横幅
    /// 常驻面板——成功无需用户处理，展示即撤离；失败/告警类常驻不清）。
    /// 新 success 重置计时；失败反馈到达时取消计时（常驻语义）。
    private func setSuccessFeedback(_ message: String) {
        successFeedbackClearTask?.cancel()
        controlFeedback = .success(message)
        successFeedbackClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            guard let self, case .success = self.controlFeedback else { return }
            self.controlFeedback = nil
        }
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

    // MARK: - 遥测采样（规格 §2.1 P0-2 独立门控；档位仲裁见 refreshCadence）

    /// 单次电池快照（IOKit 在 detached Task 后台执行——主线程永不阻塞）。
    /// 采样失败 → batterySnapshot=nil + os_log（不进横幅、不触发图标 .alert）。
    /// 成功后挂样本环（电源态翻转先清环——R1 P1-3，杜绝充电↔放电异态混合
    /// 样本拟合出小斜率产生错误估算）。
    private func sampleBatteryOnce() async {
        let snapshot = await Task.detached { [batteryMonitor] in
            try? batteryMonitor.snapshot()
        }.value
        guard !Task.isCancelled else { return }
        batterySnapshot = snapshot
        if let snapshot {
            ingestSampleRing(snapshot)
        } else {
            Self.log.error("电池快照采样失败（面板显「遥测不可用」降级形态）")
        }
    }

    /// 样本环写入（仅遥测运行期经 sampleBatteryOnce 调用）：电源态
    /// （isCharging/externalConnected）翻转即清环重采；容量满丢最旧（900 点 =
    /// 15 分钟 @1s——新鲜度截断的环侧等价物，TimeEstimator 内仍再截断一次）。
    private func ingestSampleRing(_ snapshot: BatterySnapshot) {
        if let last = lastSamplePowerState,
           last.isCharging != snapshot.isCharging
            || last.externalConnected != snapshot.externalConnected {
            sampleRing.removeAll(keepingCapacity: true)
        }
        lastSamplePowerState = (snapshot.isCharging, snapshot.externalConnected)
        sampleRing.append(TimeSample(date: snapshot.timestamp, percent: snapshot.percent))
        if sampleRing.count > Self.sampleRingCapacity {
            sampleRing.removeFirst(sampleRing.count - Self.sampleRingCapacity)
        }
    }

    // MARK: - 控制操作（规格 §2.3；全部 XPC 后台）

    /// 应用上限/滞回（WP2'：autoDischarge 可选键——nil = 不发键，daemon 缺席保持）。
    /// 唯一显式传 true/false 的调用点是设置窗自动放电开关（其余三调用点走默认 nil，
    /// 防 60s 轮询窗口内用旧值覆写 CLI 刚改的限值，R1 P3）。
    /// Phase 5 v1.2 §4.1（R1 P1-2）：成功回包经 runControl → ingest 统一更新
    /// daemonStatus——ControlSectionView 自同步单通路（onChange）即回写源，
    /// 不再需要 onLimitsApplied 单值回调（双宿主下后开覆盖先开的缺陷根除）。
    func applyLimits(upperLimit: Int, hysteresis: Int, autoDischarge: Bool? = nil) {
        runControl(
            attempt: .setLimits(upperLimit: upperLimit, hysteresis: hysteresis),
            operation: {
                try DaemonXPCClient().setLimits(
                    upperLimit: upperLimit, hysteresis: hysteresis, autoDischarge: autoDischarge
                )
            },
            successFeedback: CellarL10n.s("status.applied", upperLimit, hysteresis)
        )
    }

    /// 总开关：mode 驱动「停用限充 / 启用限充」（禁用/启用命令语义相反）。
    func toggleCharging(enabled: Bool) {
        if enabled {
            runControl(attempt: .setChargingEnabled(true), operation: { try DaemonXPCClient().enable() }, successFeedback: CellarL10n.s("status.enabled"))
        } else {
            runControl(attempt: .setChargingEnabled(false), operation: { try DaemonXPCClient().disable() }, successFeedback: CellarL10n.s("status.disabled"))
        }
    }

    /// 「充满一次」：充电到 100% 后自动恢复限充（WP2）。前置拒绝 → daemonError 原文
    /// 上屏（stale 版本比对照走）；动作已在轨 → daemon 幂等回当前状态（按钮随状态消失）。
    func fullOnce() {
        runControl(
            attempt: .fullOnce,
            operation: { try DaemonXPCClient().fullOnce() },
            successFeedback: CellarL10n.s("status.fullOnceStarted")
        )
    }

    /// 取消当前一次性动作（幂等：无动作时亦成功，daemon 回当前状态）。
    func cancelFullOnce() {
        runControl(
            attempt: .cancelFullOnce,
            operation: { try DaemonXPCClient().cancelAction() },
            successFeedback: CellarL10n.s("status.fullOnceCancelled")
        )
    }

    /// 「放电到上限」（WP2'）：禁用适配器 → 电量降至策略上限 → 自动恢复限充。
    /// 前置（模式/外接/电量高于目标/能力）拒绝 → daemonError 原文上屏；动作已在轨
    /// → daemon 幂等回当前状态（按钮随状态消失）。目标 = daemon 当前策略上限快照。
    func dischargeToLimit() {
        runControl(
            attempt: .dischargeToLimit,
            operation: { try DaemonXPCClient().dischargeToLimit() },
            successFeedback: CellarL10n.s("status.dischargeStarted")
        )
    }

    /// 取消放电动作（XPC 同 cancelAction——幂等；横幅摘要区分动作类型）。
    func cancelDischarge() {
        runControl(
            attempt: .cancelDischarge,
            operation: { try DaemonXPCClient().cancelAction() },
            successFeedback: CellarL10n.s("status.dischargeCancelled")
        )
    }

    /// 「电池校准」（WP3）：一键启动四相校准（充满 → 静置平衡 2h → 放电至 10% →
    /// 恢复限充）。前置拒绝 → daemonError 原文上屏；校准已在轨 → daemon 幂等回
    /// 当前状态；其他动作在轨 → .actionOccupied 拒绝上屏（互斥双向，面板校准区
    /// idle 条件 action == nil 双重防护）。
    func calibrateStart() {
        runControl(
            attempt: .startCalibration,
            operation: { try DaemonXPCClient().startCalibration() },
            successFeedback: CellarL10n.s("calibration.start")
        )
    }

    /// 取消校准（XPC 独立臂 cancelCalibration——幂等，无动作亦成功回当前状态）。
    func calibrateCancel() {
        runControl(
            attempt: .cancelCalibration,
            operation: { try DaemonXPCClient().cancelCalibration() },
            successFeedback: CellarL10n.s("calibration.cancel")
        )
    }

    // MARK: - Phase 5 v1.1 风扇

    /// 风扇状态（nil = 旧 daemon 未上报——设置区需升级提示；新 daemon 恒非 nil）。
    var fanStatus: FanStatus? {
        daemonStatus?.fan
    }

    /// 风扇设置（FanWire 缺席字段 = daemon 保持现值；成功反馈由统一通道上屏）。
    /// 失败三态走统一控制通道（daemonError 原文 / stale 比对 / 连接态）。
    func setFan(_ wire: FanWire) {
        runControl(
            attempt: .setFan(wire),
            operation: { try DaemonXPCClient().setFan(wire) },
            successFeedback: CellarL10n.s("status.summary.setFan")
        )
    }

    /// 横幅「重试」= 重发上次动作（分支 ①；lastAttempt 在 runControl 入口记录）。
    func retryLastAttempt() {
        guard let attempt = lastAttempt, !busy else { return }
        switch attempt {
        case .setLimits(let upperLimit, let hysteresis):
            applyLimits(upperLimit: upperLimit, hysteresis: hysteresis)
        case .setChargingEnabled(let enabled):
            toggleCharging(enabled: enabled)
        case .fullOnce:
            fullOnce()
        case .cancelFullOnce:
            cancelFullOnce()
        case .dischargeToLimit:
            dischargeToLimit()
        case .cancelDischarge:
            cancelDischarge()
        case .startCalibration:
            calibrateStart()
        case .cancelCalibration:
            calibrateCancel()
        case .setFan(let wire):
            setFan(wire)
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

    /// 控制结果处理（主 actor）：成功 → ingest 状态更新（滑杆自同步通路的数据
    /// 源，§4.1 R1 P1-2）+ 反馈 + lastAttempt 清除；失败三态：daemonError →
    /// stale 版本比对；timeout/connectionFailed → connection=.unreachable +
    /// 「守护进程未运行或无响应」。
    private func finishControl(
        result: Result<DaemonStatus, DaemonClientError>,
        successFeedback: String,
        onSuccess: (@MainActor (DaemonStatus) -> Void)?
    ) {
        busy = false
        switch result {
        case .success(let status):
            ingest(status: status)
            setSuccessFeedback(successFeedback)
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
