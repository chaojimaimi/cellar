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
    /// fan 专用细粒度 pending（v0.19.7 §3.3）：fan 提交不置全局 busy（整节闪灰
    /// 根除）——仅被提交控件经 FanSectionView.pendingField 呈禁用态。**必须
    /// @Published**：ObservableObject 非 @Published 变更不触发 objectWillChange，
    /// pending 视觉会静默失效（R1 P3）。
    @Published private(set) var fanPendingField: FanPendingField?
    /// fan 单槽排队（latest-wins，深度恒 1）：飞行中收到新提交 → 暂存，回包后
    /// 自动补发——根治 runControl `guard !busy` 对并发提交的静默丢弃（细粒度
    /// pending 打开「飞行中第二笔提交」窗口后的前置防线，方案 §1/§3.3）。非视觉
    /// 态不入 @Published。
    private var fanQueuedApply: (wire: FanWire, field: FanPendingField)?
    @Published private(set) var controlFeedback: ControlFeedback?
    /// MagSafe LED 独立轻路径状态槽（v1.10 M2）：pending = LED 在途（不进全局 busy，防通用页全节闪灰）；
    /// feedback = 组件内轻提示（成功 5s 清 / 失败常驻，不写全局 controlFeedback——横幅归属隔离）。
    /// ⚠️ internal setter（偏离本类 private(set) 纪律）——WHY：写入面在外迁 extension 文件
    /// StatusController+LEDControl.swift，private(set) 跨文件只读不可写（R2 P1-A）；clearTask 同因 internal。
    @Published var magSafeLedPending = false
    @Published var magSafeLedFeedback: String?
    var magSafeLedFeedbackClearTask: Task<Void, Never>?   // LED 轻提示 5s 消退任务（extension 写入面）。
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
    /// 生命周期契约（v1.12.1 冻结修复）：非 nil ⇒ 有表面可见（全表面关闭时
    /// refreshCadence 即时清空 + 在途采样守卫共同钉死）；**反向不成立**——可见时
    /// 也可能短暂 nil（重开首帧补采样在途 / 采样失败降级），消费面必须自带 nil
    /// 处理。菜单栏电池形态徽标取值链（menuBarBatteryForm 快照第一优先）依赖
    /// 此契约，否则停采样后的最后值冻结成永久旧值，插拔电徽标点击面板才刷新。
    @Published private(set) var batterySnapshot: BatterySnapshot?
    /// 流向判定前态双槽（v0.19.5 §D3——「上一帧」语义的宿主）。
    ///
    /// WHY 双槽不能单槽直写：`batterySnapshot = new` 的视图重算虽在下一 runloop，
    /// 但同函数内顺序赋值会让消费点读到「本帧当前态」→ `generationChanged` 恒
    /// false → assist 确认门/锁存整体失效。定版：每帧先用 `flowPreviousSample`
    /// （= 上一帧）判定本帧 kind，再把本帧三元组存入 `pendingTriple`，下一帧
    /// 采样时才提交为 `flowPreviousSample`（§D3 顺序契约：①提交上帧 → ②采样
    /// → ③判定 → ④写回 pending → ⑤发布）。
    /// 上帧算好、待生效的三元组（下一帧 ① 提交进 flowPreviousSample）。
    private var pendingTriple: FlowDiagramPreviousSample?
    /// 消费点读的判定前态（= 上一帧三元组）。internal 只读投影（§D2 四入口
    /// 接线：PanelView / DashboardView+PowerFlowText 经此透传）；**非 @Published**
    /// ——纯判定输入，不驱动视图刷新（kind 判定随 batterySnapshot 发布重建时
    /// 自然取到最新值）。
    private(set) var flowPreviousSample: FlowDiagramPreviousSample?
    /// App 侧 IOPS 实时电源态（WP5 §2.4 图标即时化数据源；nil = 尚未收到电源
    /// 事件/读取失败——图标回退 daemonStatus 快照，零行为变化）。
    @Published private(set) var powerOverride: PowerOverride?
    /// IOPS 插拔电订阅（create-rule 所有权与释放见 PowerSourceMonitor）。
    private let powerSourceMonitor = PowerSourceMonitor()
    /// App 侧 CPU 表面温度/双风扇采样器（0.18 T5 D-5a）：真身由组合根 @StateObject
    /// 持有并直注 PanelView（@Published 不经本类传播——MenuBarIconLabel 双观察源
    /// 教训）；本类仅持弱引用转发面板可见性门控（panelVisible 是面板表面私有态，
    /// 转发点唯一 = setPanelVisible）。⚠️ 回填点在 PanelView.panelAppeared——
    /// App.init 早期访问 @StateObject 拿到的是被 SwiftUI 丢弃的临时实例
    /// （deinit 尸体链实锤），环境注入的真身互认（幂等）是安全装配点。
    weak var cpuFanMonitor: CpuFanMonitor?

    /// 通知事件出口（CellarApp 注入 NotificationService.deliver；§2.3 单一入口投递）。
    /// WP2'：载荷附带 lastPercent——放电终态文案「当前电量 N%」由 App 按
    /// event.kind + status.lastPercent 组装（评审 P2-6：参数不进 lastAction 线格式）。
    var onNotificationEvent: ((CellarNotificationEvent, Int?) -> Void)?

    /// 充电日程边沿事件出口（Phase 5 v1.6 UD-7；CellarApp 注入
    /// NotificationService.deliverSchedule 直投——不走 CellarNotificationEvent
    /// 映射，不新增 case、不动 daemon 字面量→通知映射）。
    var onScheduleEvent: ((ScheduleNotification) -> Void)?

    /// suppression 自动恢复结果出口（0.22.1 §1.3；CellarApp 注入通知直投）。
    /// **通知一律由恢复写完成回调驱动**（评审 P1-4——0.22.0 的 onSuppressionNotice
    /// 边沿直投退役，防「先手动指引后已恢复」双通知）：true = API 写成功投
    /// 「已自动恢复」；false = 写失败投既有手动指引。防轰炸由通知服务侧两个
    /// 独立 1h 静态限频窗承担（冷却重试拍失败静默的兜底）。
    var onSuppressionRecoveryOutcome: ((Bool) -> Void)?

    /// suppression 恢复写上次派发时刻（0.22.1 §1.2；会话内存态，App 重启即清）。
    /// ⚠️ internal 非 private（LED/reconcile 退避先例）——WHY：派发臂在外迁
    /// extension 文件 StatusController+LimitExecution.swift，跨文件需读写。
    /// **派发时刻即落值**（评审 P2-1）：防在途窗重复派发（setMCLLimit 挂起时
    /// NSLock 排队无界堆积——0.20.1 wedge 同通道实证）；结果回调不回写本值。
    /// **0.22.4**：lastSuppressionRecoverySucceeded 结果锁存随 shouldAttempt
    /// 删除 lastOutcomeSucceeded 参数（单一口径 = 冷却节奏）一并退役——本属性
    /// 是唯一在册恢复写状态。
    var lastSuppressionRecoveryAt: Date?

    /// suppression 恢复结果横幅数据源（0.22.2 §4；通用页警示块第三行消费）。
    /// at = 派发时刻（HH:mm 格式化上屏）、recovered = 写结果。仅内存态，App
    /// 重启清零；赋值钉死在 dispatchSuppressionRecovery 的 MainActor.run 块内
    /// （勿落组合根闭包）。⚠️ internal setter（偏离本类 private(set) 纪律，
    /// magSafeLedPending 同款先例）——WHY：写入面在外迁 extension 文件
    /// StatusController+LimitExecution.swift，private(set) 跨文件只读不可写。
    @Published internal(set) var suppressionRecoveryInfo: (at: Date, recovered: Bool)?

    /// 通知分类基线（ingest 每样本推进；首样本语义见 CellarCore notificationEvents）。
    private var notificationBaseline: DaemonStatus?
    // **0.23.1 编排退役**：App 侧编排执行链（processedOrchestrationTokens/
    // orchestrationTask / consumeOrchestrationPending / setOrchestration 发送端 /
    // ingest pending 消费挂点 / 编排状态·编排开关·编排生效中 三计算属性 /
    // orchestrationActive 计算属性 / ControlAttempt.setOrchestration）随批删除
    // ——daemon 域承载单通道（模型 v2 实证），App 侧 MCL 写仅存 suppression 恢复
    //（max(t,80)）与 W4 对账残余车道（degraded max(t,80)/mode 关 100）。
    // MARK: 0.20 M2 WP3 读回（MCLClient 产品化；R10 起失配提示迁通用页守护进程节）
    /// 原生限充 GET/SET 客户端（0.21.0 §1.1 set 面内嵌；类缺席 sticky + 实例自愈
    /// ——类型头注记）。⚠️ 仅后台线程调用（Task.detached 包裹——dlopen/ObjC 消息
    /// 派发同步调用，主线程永不阻塞；CpuFanMonitor 先例）。⚠️ internal——WHY：
    /// StatusController+LimitExecution.swift 对账臂跨文件读取（同上先例）。
    let mclClient = MCLClient()
    /// MCL 读回采样值（0.21.0 §1.3 面板恢复臂对账判定源；nil = 不可用/未采样）。
    /// ⚠️ 非 private(set)（LED 先例）——WHY：写入面在
    /// StatusController+LimitExecution.swift 关断补偿臂（对账一致后顺带刷新）。
    @Published var mclReadbackValue: Int?
    /// **R10 迁移新家（0.23.1）**：域生效值失配提示（0.21.1 §2.2 诚实性特性，原
    /// 展示在编排节 readbackLine——编排节随批删除）→ 通用页守护进程节尾行。
    /// 「系统设置 X% 已被 Cellar 目标 Y% 覆盖」——域随写覆盖全区间后系统 MCL 被
    /// 统一覆盖的显性化；nil = 无失配/不渲染（诚实缺席）。warning 色由视图层固定。
    @Published private(set) var domainOverrideNotice: String?

    // MARK: 0.21.0 §1.5 关断残留对账（W4 残余车道）
    /// 0.21.1 §3.2 关断残留补偿重试退避（M1a P3-2——存储属性在主类声明，消费在
    /// StatusController+LimitExecution.swift 对账臂；会话内存态，App 重启即清）。
    /// 连续补偿失败 ≥3 → 停试（补偿成功/对账一致复位）；期望值变化 = 新关断态
    /// → 重试机会重置。照 WP3 读回失配退避（R0-P2）同形态。
    var reconcileFailureStreak = 0
    /// 退避窗内记录的期望值（nil = 无失败记录——与 streak 配对推进/复位）。
    var reconcileBackoffExpected: Int?
    /// 0.22.4 静默门首拍日志旗标（会话内存态——首次静默打一条说明，稳态静默不
    /// 刷日志；存储属性在主类声明，消费在 StatusController+LimitExecution.swift
    /// 对账臂，internal 同 reconcileFailureStreak 先例）。
    var compensationSilenceLogged = false
    /// 读回采样循环（nil = 停止）。⚠️ nonisolated(unsafe)：deinit（非隔离）需取消；
    /// 属性仅在主 actor 方法或 deinit 中访问（Task.cancel() 本身线程安全——既有
    /// pollTask 同款注记）。
    private nonisolated(unsafe) var mclSampleTask: Task<Void, Never>?
    /// 通用页可见性（MCL 采样合并门控输入——面板可见也驱动采样，
    /// 供恢复臂对账判定源；私有态，转发点 setGeneralPageVisible）。
    private var generalPageVisible = false
    /// 0.21.0 §1.5 关断残留态驱动对账循环（30s 周期；App 进程常驻——覆盖 daemon
    /// 侧关断（CLI/SIGHUP/restoreAndExit）的 App 重启窗，R3-P2-2 读回驱动无需会话
    /// 记忆）。⚠️ nonisolated(unsafe)：deinit 取消，同 mclSampleTask 注记。
    private nonisolated(unsafe) var mclReconcileTask: Task<Void, Never>?

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
        // 0.21.0 §1.5：关断残留态驱动对账循环（App 进程常驻——daemon 侧关断无
        // 回包事件，唯轮询观察；26 平台循环内 platformModern 门 no-op）。
        mclReconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                await self.reconcileShutdownResidual()
            }
        }
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

    /// **0.27+ 现代后端平台判别（platformModern——0.23.1 R3/R7 平台门替换）**：
    /// capabilities 含 orchestration（27 红线平台标记——RuntimeProbe 终态上报照报，
    /// 语义 = 「27 现代后端终态」非编排功能开关）。消费面（原 orchestrationTerminal
    /// 六点全换本判别，行为零变化）：W4 对账门 / MCL 采样门 / fullOnce 按钮二态 /
    /// temporaryFullOpenActive 判定源 / nativeLimitFullOnceHintWord / 对账注释面。
    var platformModern: Bool {
        capabilities?.contains(DaemonXPC.capabilityOrchestration) == true
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
        mclSampleTask?.cancel()
        mclReconcileTask?.cancel()
    }

    // MARK: - 轮询调度（规格 §2.2 + Phase 5 v1.2 §2.3 多表面仲裁）

    /// 面板可见性换档（Phase 5 v1.2 §2.3）：与 setMainWindowVisible 对称——防漏停
    /// 要求两入口 appear 设 true / disappear 设 false（R-2 走查项）。最小化语义：
    /// macOS 窗口最小化不触发 onDisappear——最小化视同可见（1s 采样继续），属
    /// 可接受行为（R1 P3 注明，不引入 scenePhase 追踪）。
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        // 0.18 T5：面板观察增强采样门控转发（CPU 表面温度/风扇转速仅面板消费
        // ——主窗可见不采样；弱引用 nil = 尚未回填，静默跳过）。
        cpuFanMonitor?.setPanelVisible(visible)
        // 0.21.0 §1.3：面板可见也驱动 MCL 读回采样（恢复臂按钮/横幅判定源——
        // R2-P2-4 读回驱动；合并门控见 refreshMclSampling）。
        refreshMclSampling()
        refreshCadence()
    }

    /// 主窗口可见性换档（与 setPanelVisible 同语义的第二个表面）。
    func setMainWindowVisible(_ visible: Bool) {
        mainWindowVisible = visible
        // 0.22.0 §4.3：通用页 CPU 参考温度行消费——CpuFanMonitor 双表面 OR 门
        // 合并裁决（refreshMclSampling 多表面先例；单面板门会让主窗消费面恒 nil）。
        cpuFanMonitor?.setMainWindowVisible(visible)
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
            // v1.12.1 冻结修复：全表面关闭即清快照。batterySnapshot 是菜单栏电池
            // 形态徽标取值链第一优先源（menuBarBatteryForm），停采样不清空会把
            // 最后一次面板可见时刻的电源态冻结成永久旧值——拔电闪电不消失/插电
            // 无徽标、点击面板（重开遥测）才刷新的根因。清空后电池形态回退
            // powerOverride（IOPS 活数据 + 复查阶梯）+ daemonStatus.lastPercent；
            // 面板重开时本函数已接线立即补采样（无数据窗口有界于一次采样时长）。
            batterySnapshot = nil
            // v0.19.5 §D3 前态清空路径之一：全表面关闭断代——两槽同步置 nil，
            // 重开首帧即首代保守语义（previous == nil → assist 一律未确认）。
            pendingTriple = nil
            flowPreviousSample = nil
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
            // 充电日程边沿通知（UD-7）：scheduleActiveId 前后比对——nil→id = 窗口
            // 进入 / id→id 变更 = A→B 直切（按进入语义上报新条目）/ id→nil = 恢复；
            // **首样本不通知**（baseline nil，照 notificationEvents 基线语义）。
            // 须在基线推进前比对（与 notificationEvents 同拍）。
            if let previous = notificationBaseline,
               previous.scheduleActiveId != status.scheduleActiveId {
                if let activeId = status.scheduleActiveId {
                    onScheduleEvent?(.entered(entrySummary: scheduleEntrySummary(activeId, in: status)))
                } else {
                    onScheduleEvent?(.restored)
                }
            }
            // sub80 机制关闭自动恢复（0.22.1 §1.2 / 0.22.2 §1.1 / **0.22.4 §3.3
            // 单一口径**）：判定输入钉死取 ingest 入参 status——self.daemonStatus
            // 本拍下方才赋值，按属性取值会吃到上一拍陈旧 mode/wire（评审 P2-2）。
            // 多分支判定（首包破例/边沿与持续统一冷却/两窗不派发）在
            // SuppressionRecovery.shouldAttempt 纯函数（CellarCoreCheck 场景域
            // 钉死；26/旧 daemon current nil 与 mode 非 active 全拒）。0.22.4：
            // lastOutcomeSucceeded 输入删除（0.22.2 成功门退役——补偿互搏面已随
            // 补偿臂静默门消失），新增 fullOpenWindow（两窗任一在位不派发）。
            // 旧 0.22.0 边沿直投通知退役（评审 P1-4）——通知一律由恢复写完成
            // 回调驱动，防「先手动指引后已恢复」双通知。
            // 回合清理（0.22.2 code-review P2 → 0.22.4 简化）：锁存释放拍清横幅
            // 态——防观测空洞（全表面关闭 60s 轮询档/睡眠）吞掉「释放→再压制」
            // 整循环后，横幅以陈旧结果态虚假陈述。锁存期 wire 恒 true 不触发本
            // 清理；吞边沿后按冷却臂节奏恢复（lastAttemptAt 判定统一承担）。
            if status.sub80MechanismSuppressed != true {
                suppressionRecoveryInfo = nil
            }
            if SuppressionRecovery.shouldAttempt(
                previous: notificationBaseline?.sub80MechanismSuppressed,
                current: status.sub80MechanismSuppressed,
                modeActive: status.mode == "active",
                lastAttemptAt: lastSuppressionRecoveryAt,
                fullOpenWindow: status.fullOnceWindowActive == true
                    || status.chargingDisabledWindowActive == true,
                now: Date()
            ) {
                dispatchSuppressionRecovery(status)
            }
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
        // **0.23.1 编排退役**：原 ingest 末尾「编排 pending 消费挂点」（v0.19.20
        // WP-2——consumeOrchestrationPending detached 执行 + reportOrchestration
        // 回报）随 App 执行链删除——daemon 域承载单通道，App 无 pending 消费面。
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
    ///
    /// v0.19.5 §D3 双槽时序（顺序写反则 assist 确认门整体失效）：②采样结果
    /// 过两守卫后 → ①提交上帧（pendingTriple → flowPreviousSample，⚠️必须在
    /// 两守卫**之后**——否则在途采样被守卫 return 时会提交 pending 而不发布
    /// 快照，前态推进与发布脱钩）→ ③用上帧前态判本帧 kind（仅推进前态）→
    /// ④本帧三元组入 pendingTriple 待生效 → ⑤发布快照（消费点用上帧 prev
    /// 判定，与 ③ 同输入同结果）。
    private func sampleBatteryOnce() async {
        // ② 采样（物理上先于守卫——守卫检查的是本 Task 的取消态/表面可见态）。
        let snapshot = await Task.detached { [batteryMonitor] in
            try? batteryMonitor.snapshot()
        }.value
        guard !Task.isCancelled else { return }
        // v1.12.1 冻结修复配套：在途采样竞态守卫——关面板（refreshCadence 清空
        // 快照）瞬间可能存在一个已起飞的 detached 采样，放行会把「面板可见时刻」
        // 的值重新冻进快照，旧根因复发。采样结果只在有表面可见时发布。
        guard panelVisible || mainWindowVisible else { return }
        // ① 提交上帧（首帧 pendingTriple == nil → flowPreviousSample 保持
        // nil → 首代保守语义）。
        if let pending = pendingTriple {
            flowPreviousSample = pending
        }
        guard let snapshot else {
            // 采样失败 → batterySnapshot=nil + 前态断代（v0.19.5 §D3 清空路径
            // 之二：两槽同步置 nil，重开首帧即首代保守语义）。
            batterySnapshot = nil
            pendingTriple = nil
            flowPreviousSample = nil
            Self.log.error("电池快照采样失败（面板显「遥测不可用」降级形态）")
            return
        }
        // ③ 用上帧前态判本帧 kind（遥测缺席帧照常走此处——kind 为 ② 回退
        // 分支结果，SP/BP 存 nil，下一帧 generationChanged 判定自然处理）。
        let kind = flowModel(of: snapshot, previous: flowPreviousSample).kind
        // ④ 本帧三元组待生效（下一帧 ① 才提交为消费点前态）。
        pendingTriple = FlowDiagramPreviousSample(
            systemPowerInMW: snapshot.telemetry?.systemPowerInMW,
            batteryPowerMW: snapshot.telemetry?.batteryPowerMW,
            kind: kind
        )
        // ⑤ 发布（视图按 batterySnapshot 重建时读到的 flowPreviousSample =
        // 上一帧，与 ③ 判定同输入）。
        batterySnapshot = snapshot
        ingestSampleRing(snapshot)
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

    /// 应用上限/滞回（**0.23.0 §① 自动放电退役**：原 autoDischarge 可选键参数
    /// 删除——App 侧再无显式传值调用点；XPC wire auto 键兼容保留，调用恒缺席）。
    /// Phase 5 v1.2 §4.1（R1 P1-2）：成功回包经 runControl → ingest 统一更新
    /// daemonStatus——ControlSectionView 自同步单通路（onChange）即回写源，
    /// 不再需要 onLimitsApplied 单值回调（双宿主下后开覆盖先开的缺陷根除）。
    func applyLimits(upperLimit: Int, hysteresis: Int) {
        runControl(
            attempt: .setLimits(upperLimit: upperLimit, hysteresis: hysteresis),
            operation: {
                try DaemonXPCClient().setLimits(upperLimit: upperLimit, hysteresis: hysteresis)
            },
            successFeedback: CellarL10n.s("status.applied", upperLimit, hysteresis)
        )
    }

    /// 总开关：mode 驱动「停用限充 / 启用限充」（禁用/启用命令语义相反）。
    /// 0.21.0 §1.5：**App 自发关断**（面板 XPC 成功回包）→ 按表即时 set 补偿
    /// （disable 恒 100——R3-P1 第一行；补偿在 extension 关断对账臂执行）。
    func toggleCharging(enabled: Bool) {
        if enabled {
            runControl(attempt: .setChargingEnabled(true), operation: { try DaemonXPCClient().enable() }, successFeedback: CellarL10n.s("status.enabled"))
        } else {
            runControl(
                attempt: .setChargingEnabled(false),
                operation: { try DaemonXPCClient().disable() },
                successFeedback: CellarL10n.s("status.disabled"),
                onSuccess: { _ in self.reconcileShutdownResidualNow() }
            )
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
    /// v0.19.7 自 runControl 迁出为 fan 专用提交通道：**不置全局 busy**（细粒度
    /// pending，fanPendingField 钉被提交控件）；飞行中再收到提交 → 入单槽
    /// （latest-wins 覆盖旧槽）return，回包后自动补发。入口语义照 runControl：
    /// 清旧横幅 + 记 lastAttempt（重试依据）；XPC 后台执行 + 主线程回包纪律同款。
    func setFan(_ wire: FanWire, field: FanPendingField) {
        guard fanPendingField == nil else {
            fanQueuedApply = (wire, field)   // 飞行中：latest-wins 覆盖旧槽
            return
        }
        fanPendingField = field
        controlFeedback = nil
        lastAttempt = .setFan(wire, field)
        Task.detached { [weak self] in
            let result: Result<DaemonStatus, DaemonClientError>
            do {
                result = .success(try DaemonXPCClient().setFan(wire))
            } catch let error as DaemonClientError {
                result = .failure(error)
            } catch {
                // 协议域外错误（编码失败等）：按 daemon 拒绝呈现，不静默（同 runControl）。
                result = .failure(.daemonError(String(describing: error)))
            }
            await MainActor.run {
                self?.finishFanApply(result: result, wire: wire, field: field)
            }
        }
    }

    /// fan 回包处理（主 actor；照 finishControl 语义逐项保持，方案 §3.3.3）：
    /// 成功 → ingest + 成功反馈 + lastAttempt **compare-and-clear**（仅当仍是
    /// 本笔 (wire, field) 才清——fan 不置 busy 后与其他 runControl 操作可交错，
    /// 无条件清槽会踩掉他操作的重试槽；LED 先例正是为此不写 lastAttempt）；
    /// 失败 → classifyControlFailure（全局横幅/stale 比对不变；lastAttempt 照
    /// runControl 失败保留）。收尾按单槽队列补发：非空 → 取出重走 setFan 完整
    /// 入口语义（含 lastAttempt 重记录 + controlFeedback 清旧——否则补发笔失败
    /// 时重试槽已被前笔成功清空，重试钮退化，R2 P3）；空 → pending 复位。
    private func finishFanApply(
        result: Result<DaemonStatus, DaemonClientError>,
        wire: FanWire,
        field: FanPendingField
    ) {
        switch result {
        case .success(let status):
            ingest(status: status)
            setSuccessFeedback(CellarL10n.s("status.summary.setFan"))
            if lastAttempt == .setFan(wire, field) {
                lastAttempt = nil
            }
        case .failure(let error):
            classifyControlFailure(error) { self.controlFeedback = $0 }
        }
        // code-review P0：先清 pending 再补发——setFan 首行 guard fanPendingField
        // == nil 否则入槽；若带着旧 pending 调补发，补发笔会被弹回队列且再无
        // finishFanApply 驱动源，fan 通道永久卡死（无在飞 Task、pending 恒非 nil）。
        // MainActor 同步序列内 nil→新 field 中间态同周期合并，无视觉闪烁。
        fanPendingField = nil
        if let queued = fanQueuedApply {
            fanQueuedApply = nil
            setFan(queued.wire, field: queued.field)
        }
    }

    // MARK: - Phase 5 v1.4 校准调度

    /// 校准调度设置（照 setFan runControl 先例，方案 §3.2/§7-M3-3）：组件侧以
    /// `CalibrationScheduleWire(policy)` 组**全键**下发（缺席保持是 daemon 侧
    /// 语义，App 不依赖）；旧 daemon 回「未知命令」→ detectStaleBeforeReject
    /// 升级提示（既有闭环）。成功反馈由统一通道上屏。
    func applyCalibrationSchedule(_ wire: CalibrationScheduleWire) {
        runControl(
            attempt: .setCalibrationSchedule(wire),
            operation: { try DaemonXPCClient().setCalibrationSchedule(wire) },
            successFeedback: CellarL10n.s("status.summary.setCalibrationSchedule")
        )
    }

    // MARK: - Phase 5 v1.5 充电热暂停

    /// 充电热暂停配置（nil = 旧 daemon 未上报 therm 两键 → 热节 legacy 升级提示；
    /// 新 daemon buildStatusLocked 恒填 → 恒非 nil，UD-7 照 fanStatus 先例）。
    var thermalStatus: ThermalStatus? {
        guard let status = daemonStatus,
              let pause = status.thermPauseCentiC,
              let hysteresis = status.thermHysteresisCentiC else { return nil }
        return ThermalStatus(pauseCentiC: pause, hysteresisCentiC: hysteresis)
    }

    /// 充电热暂停设置（照 setFan runControl 先例，方案 §2.3）：组件侧以
    /// `ThermalWire(policy)` 组**全键**下发（缺席保持是 daemon 侧语义，App 不
    /// 依赖）；旧 daemon 回「未知命令」→ detectStaleBeforeReject 升级提示既有
    /// 闭环（R-4）。成功反馈由统一通道上屏。
    func setThermal(_ wire: ThermalWire) {
        runControl(
            attempt: .setThermal(wire),
            operation: { try DaemonXPCClient().setThermal(wire) },
            successFeedback: CellarL10n.s("status.summary.setThermal")
        )
    }

    // Phase 5 v1.8 MagSafe LED 域 v1.10 M2 整域外迁（magSafeLedStatus + setMagSafeLed → StatusController+LEDControl.swift）。

    // MARK: - Phase 5 v1.6 充电日程

    /// 充电日程状态（nil = 旧 daemon——daemonStatus.scheduleJson 缺席；新 daemon
    /// 恒填，UD-7 照 thermalStatus 先例）。解码失败（理论不可达——daemon 侧
    /// encode 产物）→ 回落空配置，不误判 legacy。
    var scheduleStatus: ChargeScheduleStatus? {
        guard let status = daemonStatus, let json = status.scheduleJson else { return nil }
        let config = (try? ChargeScheduleConfig.decoded(from: json)) ?? .default
        return ChargeScheduleStatus(config: config, activeEntryId: status.scheduleActiveId)
    }

    // MARK: - Phase 5 v1.7 原生限充（方案 §4 App 侧数据通路）

    /// 原生限充状态（nil = 旧 daemon 未上报 → App 侧功能整体隐藏，照 fanStatus
    /// 版本门控先例；字段在 + known=false = 检测器未知态，App 不猜测——注记行
    /// 不渲染、按钮不禁用 = fail-open 对齐，方案 §4.1/§3.1）。
    var nativeLimitStatus: NativeLimitStatus? {
        daemonStatus?.nativeLimit
    }

    /// 原生限充激活（守卫口径 active，校准/fullOnce 按钮禁用依据——与 daemon
    /// 拒绝行为一致；unknown 态 active 恒 false 自然放行）。
    var nativeLimitActive: Bool {
        nativeLimitStatus?.active == true
    }

    /// 按钮辅助文案词汇位（方案 §4.1 双口径，与 daemon 拒绝文案同语义——App 侧
    /// 为提前禁用提示）：manualSocLimit 有值 → 手动口径（「请先在系统设置中
    /// 关闭」）；仅非手动策略（OBC 等）→ 通用口径。nil = 未激活（不禁用不提示）。
    /// review P2-1 拆分：校准与 fullOnce 主语不同，词汇位分立、不得互相复用。
    var nativeLimitCalibrationHintWord: VocabularyWord? {
        nativeLimitHintWord(.nativeLimitCalibrationHintManual,
                            generic: .nativeLimitCalibrationHintGeneric)
    }

    /// fullOnce（充满一次）按钮辅助文案词汇位（主语「充满一次」，review P2-1）。
    /// **0.23.1 编排退役（R3/R7 平台门替换）**：27 现代后端不出提示（App/域写
    /// 覆写 MCL——fullOnceStartPrecondition 27 臂原生守卫绕过，残留非阻断）——
    /// 词汇位仅 26 语义保留（防残留误导）；判定源换 platformModern（行为零变化）。
    var nativeLimitFullOnceHintWord: VocabularyWord? {
        guard !platformModern else { return nil }
        return nativeLimitHintWord(.nativeLimitFullOnceHintManual,
                                   generic: .nativeLimitFullOnceHintGeneric)
    }

    private func nativeLimitHintWord(_ manual: VocabularyWord,
                                     generic: VocabularyWord) -> VocabularyWord? {
        guard let native = daemonStatus?.nativeLimit, native.active else { return nil }
        return native.manualSocLimit == nil ? generic : manual
    }

    /// 充电日程设置（照 applyCalibrationSchedule runControl 先例，方案 §3.2）：
    /// **全量配置 JSON** 下发（宿主页把完整 config encode 后传入——daemon 三级
    /// 校验长度/JSON/validated，任一失败 daemonError 原文上屏；旧 daemon 回
    /// 「未知命令」→ detectStaleBeforeReject 升级提示既有闭环，R-7）。成功反馈
    /// 由统一通道上屏。
    func applyChargeSchedule(_ json: String) {
        runControl(
            attempt: .setChargeSchedule(json),
            operation: { try DaemonXPCClient().setChargeSchedule(json) },
            successFeedback: CellarL10n.s("status.summary.setChargeSchedule")
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
        case .setFan(let wire, let field):
            // 走同一排队通道（v0.19.7）：落在 fan 飞行期自然入队（fan 不置 busy，
            // 既有 `guard !busy` 对 fan 通道不再拦截，语义正确）。
            setFan(wire, field: field)
        case .setCalibrationSchedule(let wire):
            applyCalibrationSchedule(wire)
        case .setThermal(let wire):
            setThermal(wire)
        case .setChargeSchedule(let json):
            applyChargeSchedule(json)
        case .restoreChargeLimit:
            restoreChargeLimit()
        case .setChHysteresisEnabled(let enabled):
            setChHysteresisEnabled(enabled)
        }
    }

    /// 横幅「重试」= 立即单次刷新（分支 ③：轮询致 unreachable 且无上次动作）。
    func refreshNow() {
        guard !busy else { return }
        Task { await refreshOnce() }
    }

    // MARK: - 0.21.0 §2.4 CHIE 迟滞备用通道（开关 + 执法横幅消费）

    /// 迟滞开关（daemon 回读单一真相——policy.chHysteresisEnabled 恒填 wire；
    /// nil = 旧 daemon = 关处理）。开关绑定源，与执法态 sub80Hysteresis 分立。
    var chHysteresisEnabled: Bool {
        daemonStatus?.chHysteresisEnabled == true
    }

    /// 迟滞执法挂载态（daemon 回读 sub80Hysteresis——面板横幅「实验性备用通道
    /// 执法中」数据源；nil = 旧 daemon / 26 无能力机器 = 不渲染）。
    var sub80HysteresisEnforcing: Bool {
        daemonStatus?.sub80Hysteresis == true
    }

    /// 迟滞开关设置（XPC setChHysteresisEnabled；旧 daemon 回「未知命令」→
    /// detectStaleBeforeReject 升级提示既有闭环）。daemon 侧 persist + 即时 tick
    /// ——挂载/退出 ≤1 tick 评估。
    func setChHysteresisEnabled(_ enabled: Bool) {
        runControl(
            attempt: .setChHysteresisEnabled(enabled),
            operation: { try DaemonXPCClient().setChHysteresisEnabled(enabled) },
            successFeedback: CellarL10n.s("status.summary.setChHysteresis")
        )
    }

    /// 0.21.0 §1.3 恢复臂可见判定（**0.23.1 R4 判定源改挂 wire fullOnceWindowActive**
    /// ——daemon 侧 authoritative 窗位；原「MCL 读回 100 ∧ policy < 100」读回驱动
    /// 判定随 fullOnceRestoreAvailable 退役删除）：叠加 27 现代后端（platformModern）
    /// ∧ mode active。面板横幅与恢复按钮共用本判定（daemon 置窗/清窗 → 轮询回包
    /// 自然刷新，无悬挂态）。
    var temporaryFullOpenActive: Bool {
        guard platformModern,
              daemonStatus?.mode == "active" else { return false }
        return daemonStatus?.fullOnceWindowActive == true
    }

    /// 「恢复限充」（0.21.0 §1.3 恢复臂；**0.23.1 R5 重写形态**）：daemon 清窗 +
    /// 清锁存 + 即时 tick 域写 target（M1 模型 v2——域写值直接执法，App 无 set）。
    func restoreChargeLimit() {
        runControl(
            attempt: .restoreChargeLimit,
            operation: { try DaemonXPCClient().restoreChargeLimit() },
            successFeedback: CellarL10n.s("status.summary.restoreLimit")
        )
    }

    /// 通用页可见性换档（GeneralSections onAppear/onDisappear 转发——R10 失配
    /// 提示所在表面私有态，转发点唯一；照 setPanelVisible 先例）。读回采样门控：
    /// 通用页或面板可见才轮询（避免常驻采样——CpuFanMonitor panelVisible 先例）。
    func setGeneralPageVisible(_ visible: Bool) {
        generalPageVisible = visible
        refreshMclSampling()
    }

    /// MCL 读回采样合并门控（通用页 **或** 面板可见即 30s 循环——mclReadbackValue
    /// 面板对账判定源与 R10 通用页失配提示共用采样；26/非现代后端机循环内
    /// platformModern 门 no-op，零行为增量）。
    private func refreshMclSampling() {
        let shouldRun = panelVisible || generalPageVisible
        let running = mclSampleTask != nil
        guard shouldRun != running else { return }
        if shouldRun {
            Task { await sampleMCLOnce() }   // 翻档可见即补一跳（CpuFanMonitor 先例）
            mclSampleTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard let self, !Task.isCancelled else { return }
                    await self.sampleMCLOnce()
                }
            }
        } else {
            mclSampleTask?.cancel()
            mclSampleTask = nil
        }
    }

    /// 读回采样单跳（27 现代后端机才采样；0.21.0 §1.3 采样值发布 mclReadbackValue
    /// ——W4 对账判定源）。**R10（0.23.1）**：域生效值失配提示迁通用页守护进程节
    /// 尾行（原编排节 readbackLine 随节删除）——MCL 读回 = 系统设置现值，daemon
    /// 上报 sub80WrittenLimit = 域生效值（agent 实际跟随值）；两者不等 = 系统设置
    /// 被 Cellar 域覆盖（域随写覆盖全区间后的显性化——防「静默顶掉」困惑）。
    /// off（真停用）/mode 非 active/域值缺席（fresh 重启首拍）→ 无提示（诚实缺席）。
    private func sampleMCLOnce() async {
        guard platformModern else {
            domainOverrideNotice = nil
            mclReadbackValue = nil
            return
        }
        let client = mclClient
        let limit = await Task.detached { client.readLimit() }.value
        guard !Task.isCancelled else { return }
        mclReadbackValue = limit
        if let status = daemonStatus,
           let written = status.sub80WrittenLimit,
           status.mode == "active", status.sub80State != .off,
           let limit, limit != written {
            domainOverrideNotice = CellarL10n.s(
                "settings.domain.overrideNotice", "\(limit)", "\(written)")
        } else {
            domainOverrideNotice = nil
        }
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

    /// 控制结果处理（主 actor）：成功 → ingest + 反馈 + lastAttempt 清除（§4.1 R1 P1-2）；失败三态走
    /// 公共分型 helper classifyControlFailure（v1.10 M2 抽取，落位 sink = 全局横幅——对既有控制零变化）。
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
        case .failure(let error):
            classifyControlFailure(error) { self.controlFeedback = $0 }
        }
    }

    /// 控制失败分型（v1.10 M2 抽取；internal——finishControl 与 LED 独立轻路径
    /// 共用，分型判定不复制，R1 P1-3-3）：daemonError → stale 比对后交
    /// .staleDaemon / .daemonRejected(原文)；timeout/connectionFailed → 置
    /// connection=.unreachable + 交 .transferFailed。落位由调用方注入（全局横幅 /
    /// LED 组件内轻提示各自 sink——分型语义单一真相）。
    func classifyControlFailure(_ error: DaemonClientError, deliver: @escaping @MainActor (ControlFeedback) -> Void) {
        switch error {
        case .daemonError(let message):
            detectStaleBeforeReject(message, deliver: deliver)
        case .timeout, .connectionFailed:
            connection = .unreachable
            deliver(.transferFailed)
        }
    }

    /// stale daemon 版本比对（规格 §3.4）：daemonError 原文不可信时经 getStatus
    /// 比对版本：不匹配 → .staleDaemon 落位（重装入口）；匹配 → 拒绝原文落位；
    /// getStatus 亦失败 → 保守按未 stale。v1.10 M2：sink 参数化 + private→internal
    /// （跨文件 extension 调用面，R2 P1-A——两路共用）。
    func detectStaleBeforeReject(_ message: String, deliver: @escaping @MainActor (ControlFeedback) -> Void) {
        Task.detached { [weak self] in
            let version = (try? DaemonXPCClient().getStatus())?.version
            await MainActor.run {
                guard self != nil else { return }   // 实例已释放 → 不投递（原 guard let self 语义）
                if let version, version != DaemonXPC.daemonVersion {
                    deliver(.staleDaemon)
                } else {
                    deliver(.daemonRejected(message))
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
