import Foundation
import os
import CellarCore

/// daemon 单一属主（WP4 §0.1 硬约束，评审 C-1）：LimitController/backend/policy/lastStatus
/// 在本类型内是唯一归属——XPC 串行队列、主 RunLoop 定时器、电源通知、信号处理全部经
/// 本类型的加锁方法操作状态；值语义下若多处持 controller 副本，策略更新会静默丢失。
///
/// 锁纪律（规格 §0.3）：**os_log 一律在锁外调用**——方法在锁内完成状态组装并把日志事件
/// 收集到数组，解锁后统一发出（防 logd 压力放大锁持有时间）。
///
/// tick 失败纪律（评审 C-2）：采样/控制键读取/enforce 抛错 → 记日志（verifyFailed=warn、
/// 传输类=error）+ 保留上次状态 + 下 tick 继续，daemon 绝不因 tick 异常退出。
///
/// 自愈（评审 C-3）：控制路径连续失败 ≥3 次 → 重建 SMCClient（IOKit 连接可能失效）后重试。
final class DaemonCore: @unchecked Sendable {
    /// 日志事件（锁内收集、锁外发出）。OSLogType 无 warn 级，自定义三档
    /// （warn 映射 Logger.warning，统一日志中为 error 级，语义等价规格的 warn）。
    /// ⚠️ 可见性：WP2 起放宽为 internal——一次性动作实现（DaemonCore+OneShot.swift
    /// 扩展文件）需要本类型；cellar-daemon 为 executable target，internal 即模块私有，
    /// 单一属主/锁纪律不变量不受影响。
    enum LogCategory { case lifecycle, control }

    enum LogLevel {
        case info, warn, error
    }

    struct LogEvent {
        let category: LogCategory
        let level: LogLevel
        let message: String
    }

    // MARK: - 锁内状态

    /// ⚠️ 可见性：WP2 起部分成员为 internal——一次性动作实现在
    /// DaemonCore+OneShot.swift 扩展文件（DaemonCore.swift 触及 800 行硬上限拆分）；
    /// cellar-daemon 为 executable target，internal 符号模块外不可达，单一属主
    /// 不变量（锁内唯一归属）不受影响。
    let lock = NSLock()
    private let policyStore: PolicyStore
    let monitor: BatteryMonitor
    /// 锁内统一写、锁外统一发（category lifecycle/control 各一）。
    private let lifecycleLogger: os.Logger
    private let controlLogger: os.Logger

    /// 当前策略（经 `applyPolicyLocked` 写入——validated 已保证语义合法）。
    var policy: DaemonPolicy = .default
    var controller = LimitController(policy: try! LimitPolicy(upperLimit: 80, hysteresis: 2))
    /// IOKit 传输持有方（重建 SMCClient 即换新 transport）。⚠️ 可见性：Phase 5
    /// v1.1 起 internal——风扇状态机需经它读写 F0 键（executable internal 模块外不可达）。
    var smcClient: SMCClient?
    /// Phase 5 v1.1 风扇运行时状态（结构体定义在 DaemonCore+Fan.swift——扩展不能加存储属性）。
    var fanState = FanRuntimeState()
    /// 探测得到的后端；nil = 尚未探测成功（心跳驱动重试/自愈）。
    var backend: (any ChargingBackend)?
    /// daemon 能力清单（WP2' §2.1）：启动探测通过（tahoe ∧ CHIE 在位，评审 P1-1
    /// fail-closed）→ ["discharge"]；否则 []。置值挂 establishBackendLocked 成功
    /// 路径（含自愈重建——评审轮 2 注记 1）；自愈重建后能力随探测结果刷新。
    private(set) var capabilities: [String]?
    /// 最近一次成功采样的状态快照（tick 失败保留上次）。
    var lastStatus: DaemonStatus?
    /// 上次成功采样的电量（百分点变化事件判定，评审 A-1）。
    private var lastPercent: Int?
    /// 控制路径连续失败计数（≥3 重建 SMCClient，评审 C-3）。
    private var consecutiveControlFailures = 0
    /// 一次性动作轨道（WP2 §1.1 六路径门控；activeAction/终态锁存/去抖计数单一事实源）。
    var actionTrack = OneShotTrack()
    /// 动作持久化（action.json；独立于 policy.json，格式红线不动）。
    let actionStore: ActionStore
    /// Phase 5 v1.4 校准运行时状态（**锁内内存缓存 + 写透**——buildStatusLocked 读
    /// 缓存不读盘，daemon 单属主惯例；store 仅 IO，启动时载入一次）。
    var calibrationState = CalibrationState()
    /// 校准状态持久化（calibration-state.json；路径注入缝照 ActionStore 先例——可测）。
    let calibrationStateStore: CalibrationStateStore
    /// WP2' 自动放电冷却态（锁内普通变量，不持久化；崩溃重启即清零——重启后由
    /// 崩溃恢复完成记录补记冷却，§3.7）。最近一次放电动作终止/取消时刻。
    var lastAutoDischargeCompletedAt: Date?
    /// WP2' 适配器翻转门（完成后见过外接状态翻转才可重触发；初值 true = 从未完成
    /// 时判定直通，门只在完成记录存在后参与判定）。
    var adapterCycleSinceAutoCompletion = true
    /// WP2' 翻转门武装位（code-review P1：放电稳态遥测 ext=false，终止恢复 CHIE 后
    /// 1-2 tick 内回跳 true——该回跳是放电自身的恢复痕迹而非物理重插，直接开门会
    /// 击穿翻转门）。终止即 disarm；disarm 态的 false→true 回跳仅重新武装不开门；
    /// 武装后的转移（真实拔/插）才开门。首 tick lastStatus nil 的恒真比较同理被
    /// disarm 吸收（崩溃恢复已记冷却关门）。
    var adapterCycleArmed = true

    // MARK: - 生命周期

    init(
        policyStore: PolicyStore, log: os.Logger,
        actionStore: ActionStore = ActionStore(url: ActionStore.defaultURL),
        calibrationStateStore: CalibrationStateStore = CalibrationStateStore(url: CalibrationStateStore.defaultURL)
    ) {
        self.policyStore = policyStore
        self.actionStore = actionStore
        self.calibrationStateStore = calibrationStateStore
        self.monitor = BatteryMonitor.makeDefault()
        self.lifecycleLogger = log
        self.controlLogger = Logger(subsystem: "com.cellar.daemon", category: "control")
    }

    /// 启动即校对（整理 C-3 定版）：载入（校验式）策略 → 探测 backend（成功即建
    /// SMCClient/经 probe 建后端）→ active 则 enforce。任何失败只记日志，不退出。
    func startup() {
        var events: [LogEvent] = []

        lock.lock()
        if let loaded = policyStore.load() {
            applyPolicyLocked(loaded, events: &events)
            events.append(LogEvent(
                category: .lifecycle, level: .info,
                message: "已载入策略：mode=\(loaded.mode) upper=\(loaded.upperLimit) hys=\(loaded.hysteresis)"
            ))
        } else {
            events.append(LogEvent(
                category: .lifecycle, level: .info,
                message: "policy.json 缺失或非法，使用默认策略（active 80/2）"
            ))
        }

        // Phase 5 v1.4：校准运行时状态载入（缺失/损坏 → 空状态容错；此后全部经
        // 内存缓存 + 写透，读路径不再触盘）。
        calibrationState = calibrationStateStore.load()

        do {
            let detected = try establishBackendLocked(events: &events)
            events.append(LogEvent(
                category: .lifecycle, level: .info,
                message: "后端探测成功：\(detected.name)（控制键 \(detected.keyNames.joined(separator: ", "))）"
            ))
        } catch {
            events.append(LogEvent(
                category: .lifecycle, level: .error,
                message: "后端探测失败：\(error)（重试由心跳驱动）"
            ))
        }
        // WP2 崩溃恢复（规格 §1.1 startup 行；P0-2）：发现 action.json → 一律 cancelled、
        // 不恢复执行、删文件 → 终态字面量锁存（App 首查必见）→ 后续按当前策略 enforce
        // （KeepAlive 崩溃即重拉，此路径只有一次机会写对）。
        // WP2'（硬事实 6）：pending 为放电动作 → **最高优先**写 CHIE=0x0（重试阶梯 +
        // 告警），残留禁用 = 电池耗尽；enforce CHTE 由启动后常规 tick 完成（startup
        // 无采样数据，首个 tick 全量重估等价）。
        if let pending = actionStore.load() {
            try? actionStore.delete()
            if pending.kind == Discharge.dischargeToLimitKind {
                // 统一完成记录（五落点之五）：崩溃恢复终止即记冷却——顺带给 daemon
                // 重启后 30min 冷却 + 翻转门关闭（叠加 §3.7 良性分析）。
                noteDischargeTerminatedLocked(now: Date())
                if let backend, backend.adapterControlSupported {
                    let restoreError = DischargeAdapterControl.restoreEnabled(
                        backend: backend, attempts: Discharge.terminalRestoreAttempts
                    )
                    if let restoreError {
                        events.append(LogEvent(
                            category: .control, level: .error,
                            message: "崩溃恢复：放电动作残留，CHIE 恢复失败（\(restoreError)）——残留禁用交 §2.4 残留不变量巡检兜底"
                        ))
                    } else {
                        events.append(LogEvent(
                            category: .control, level: .warn,
                            message: "崩溃恢复：放电动作残留，已恢复 CHIE=0x00（限制充电由启动后常规 enforce 收敛）"
                        ))
                    }
                } else {
                    events.append(LogEvent(
                        category: .control, level: .error,
                        message: "崩溃恢复：放电动作残留但无控制后端——CHIE 恢复不可执行（残留交 §2.4 不变量）"
                    ))
                }
            }
            if pending.kind == Calibration.kind {
                // WP3：校准残留按相位恢复 CHIE（discharge 在场/相位缺失未知 → 无条件
                // 恢复 fail-closed；chargeFull/hold 无需）。通知经 crash-recovery 锁存补发。
                restoreCalibrationAfterCrashLocked(pending, events: &events)
                // Phase 5 v1.4 终态补写（UD-5）：crash-recovery 路径写 cancel(crash-
                // recovery) 归一记录——startedAt 取在手 pending（state 丢失时仍有源
                // 可取，R2 P3）；去重见 recordCalibrationOutcomeLocked。
                recordCalibrationOutcomeLocked(
                    outcome: .crashRecovery, startedAt: pending.startedAt, events: &events
                )
            }
            _ = actionTrack.adoptForCrashRecovery(pending)
            events.append(LogEvent(
                category: .lifecycle, level: .info,
                message: "崩溃恢复：取消未完成的动作（kind=\(pending.kind)），按当前策略恢复限充"
            ))
        } else if actionStore.fileExists {
            // 损坏 / 动作类型未知：删文件 + 无动作启动（字面量无从构造，不设锁存）。
            try? actionStore.delete()
            events.append(LogEvent(
                category: .lifecycle, level: .error,
                message: "崩溃恢复：action.json 损坏或动作类型未知，已删除并无动作启动"
            ))
        }
        // Phase 5 v1.1：风扇启动恢复（F0Md≠0 → 写 0 + warn——崩溃残留窗口收口，
        // 方案 §6.5；逻辑在 DaemonCore+Fan.swift 的 releaseFanLocked 内）。
        releaseFanLocked(events: &events)
        let shouldEnforce = policy.mode == "active"
        lock.unlock()
        emit(events)

        if shouldEnforce {
            sampleAndEnforce()
        }
    }

    // MARK: - 心跳与事件驱动（PowerEvent 词表内触发，规格 §0.5）

    /// 心跳：snapshot → context → active 模式 enforce → 更新 lastStatus。
    /// 30 秒 CFRunLoopTimer 调用；幂等、失败不退出。
    func sampleAndEnforce() {
        performTick()
    }

    /// 唤醒：全量重评估（与心跳同路径；DarkWake 频繁触发可接受，全量 enforce 成本低）。
    func wakeUp() {
        performTick()
    }

    /// 睡眠（kIOMessageSystemWillSleep，同步执行）：PowerEventPolicy.sleepAction
    /// （外接且当前允许充电 → 停充）→ controller.perform（写后回读校验，评审 B-2）。
    /// 失败仅 error 日志（不得静默）；调用方（电源回调）随后**无条件** IOAllowPowerChange。
    func sleepNow() {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }

        // Phase 5 v1.1：睡眠前释放风扇（睡眠中系统管热，boost 值滞留无意义——
        // 方案 §6.4 路口④；逻辑在 DaemonCore+Fan.swift）。
        releaseFanLocked(events: &events)

        // WP2 P0-1 门控：动作活跃 → 跳过睡前停充（充电即目标，无上限可守；否则用户
        // 睡前点充满 → 夜间停充 → 超时取消，最高频场景失效）。lastAction 保持动作字面量。
        // WP2'（硬事实 5）：**放电动作 → 睡眠即取消**（恢复 CHIE=0x0——同步路径内
        // 无 sleep 立即重试 1 次，不阻塞 IOAllowPowerChange；终态 + 通知），随后照常
        // 执行睡眠停充判定（恢复限充语义由 enforce 收敛）。
        if actionTrack.isActive {
            if actionTrack.action?.kind == Discharge.dischargeToLimitKind {
                cancelDischargeForSleepLocked(events: &events)
            } else {
                // WP3：校准同跳过睡前停充且不取消——睡眠中 SMC 继续充电（充电相），
                // 睡眠掉电即校准进程（放电相），唤醒全量 tick 推进相位；lastAction 直写
                // 当前相位字面量（nil/未知回退 calibration:chargeFull——不产出
                // calibration:start，R1 P2-2）。
                let constructed = actionTrack.action?.kind == Calibration.kind
                    ? CalibrationLiteral.phase(actionTrack.action?.phase.flatMap(Calibration.Phase.init(rawValue:)) ?? .chargeFull)
                    : OneShotLiteral.start(kind: actionTrack.action?.kind ?? OneShot.fullOnceKind)
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "睡眠策略跳过停充：一次性动作进行中（充电即目标，规格 P0-1）"
                ))
                lastStatus = DaemonStatus(
                    version: DaemonXPC.daemonVersion,
                    mode: policy.mode,
                    upperLimit: policy.upperLimit,
                    hysteresis: policy.hysteresis,
                    lastAction: actionTrack.effectiveLastAction(constructed),
                    lastPercent: lastStatus?.lastPercent,
                    lastExternalConnected: lastStatus?.lastExternalConnected,
                    lastChargingEnabled: lastStatus?.lastChargingEnabled,
                    action: actionTrack.action,
                    timestamp: Date()
                )
                return
            }
        }

        guard let backend else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "睡眠策略未执行：无控制后端"
            ))
            return
        }
        do {
            let enabled = try backend.chargingEnabled()
            // 外接状态：优先新鲜快照；失败回落上次已知值（从未成功采样按电池供电处理，
            // 不无据停充）；再失败则本次睡眠不动作。
            let external: Bool?
            do {
                external = try monitor.snapshot().externalConnected
            } catch {
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "睡眠前电池快照失败（\(error)），使用上次已知外接状态"
                ))
                external = lastStatus?.lastExternalConnected
            }
            let action = PowerEventPolicy.sleepAction(
                externalConnected: external ?? false,
                currentChargingEnabled: enabled
            )
            let performed = try controller.perform(action, backend: backend)
            let description: String
            switch performed {
            case .disableCharging:
                description = "sleep:disableCharging"
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "睡眠策略已停充（外接且允许充电）"
                ))
            case .noop:
                description = "sleep:noop"
            case .enableCharging:
                description = "sleep:enableCharging"
            }
            lastStatus = DaemonStatus(
                version: DaemonXPC.daemonVersion,
                mode: policy.mode,
                upperLimit: policy.upperLimit,
                hysteresis: policy.hysteresis,
                lastAction: description,
                lastPercent: lastStatus?.lastPercent,
                lastExternalConnected: lastStatus?.lastExternalConnected,
                // perform 已含写后回读校验：状态 = 动作后的真实值（回读保证）。
                lastChargingEnabled: performed == .enableCharging
                    ? true
                    : (performed == .disableCharging ? false : enabled),
                action: actionTrack.action,
                timestamp: Date()
            )
        } catch BackendError.verifyFailed(let key, let desired, let actual) {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "睡眠停充回读校验失败（key=\(key) desired=\(desired) actual=\(actual)）——冲突显式化"
            ))
        } catch {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "睡眠策略执行失败：\(error)"
            ))
        }
    }

    // MARK: - XPC 命令入口（全部经本类型，单一属主）

    /// setLimits：更新上限并切回 active（规格 §0.4）→ 持久化（失败仅记日志）→
    /// policyChanged 全量重评估 → 返回状态。LimitPolicy 构造失败（含 60 地板）原样上抛。
    /// WP2'：auto == nil → 保持内存策略现值（缺席保持——CLI 不带键不重置开关）；
    /// 0/1 → 更新 flag；**flag 自非 1 翻转为 1 时清空两门**（R2 P2-A：重新 opt-in =
    /// 新意图；解决常插电设备「一适配器会话只触发一次」的窄口）。
    func setLimits(upper: Int, hys: Int, auto: UInt64? = nil) throws -> DaemonStatus {
        _ = try LimitPolicy(upperLimit: upper, hysteresis: hys)
        var events: [LogEvent] = []
        lock.lock()
        var autoFlag = policy.autoDischargeEnabled
        if let auto {
            autoFlag = auto == 1
        }
        // WP2 门控：动作活跃 → 隐式取消（恢复限充语义）→ 再设新限并立即 enforce。
        // 审查 M3：daemon 发起取消 → 锁存 cancel 字面量（App 轮询必见终态/通知必发）。
        if actionTrack.isActive {
            cancelActionLocked(events: &events, latchCancelled: true)
        } else {
            // 用户动作清除终态锁存（P0-2：setLimits/enable/disable/fullOnce 重启）。
            actionTrack.clearUserActionLatch()
        }
        // **flag 自非 1 翻转为 1 时清空两门**（R2 P2-A：重新 opt-in = 新意图；解决
        // 常插电设备「一适配器会话只触发一次」的窄口）。置于隐式取消之后（code-review
        // P2：取消会经完成记录重新关门——清门必须后置才能兑现「新意图」语义）。
        if autoFlag == true && policy.autoDischargeEnabled != true {
            lastAutoDischargeCompletedAt = nil
            adapterCycleSinceAutoCompletion = true
            adapterCycleArmed = true
        }
        applyPolicyLocked(
            DaemonPolicy(
                mode: "active", upperLimit: upper, hysteresis: hys,
                autoDischargeEnabled: autoFlag, fan: policy.fan,
                calibrationSchedule: policy.calibrationSchedule
            ),
            events: &events
        )
        persistPolicyLocked(events: &events)
        performTickLocked(events: &events)
        let status = buildStatusLocked()
        lock.unlock()
        emit(events)
        return status
    }

    /// disable：切 disabled 并恢复默认充电（写使能 00000000）。
    /// 先恢复后切态：恢复写失败 → 仍 active 并上抛（避免"已 disabled 但充电停着"的中间态）。
    func disable() throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }

        // WP2 门控：动作活跃 → 先走统一 cancel（落终态 + 恢复限充语义）再执行 disable 原义。
        // 审查 M3：daemon 发起取消 → 锁存（同上，disable 通知必发）。
        if actionTrack.isActive {
            cancelActionLocked(events: &events, latchCancelled: true)
        } else {
            // 用户动作清除终态锁存（P0-2）。
            actionTrack.clearUserActionLatch()
        }

        if let backend {
            do {
                _ = try controller.perform(.enableCharging, backend: backend)
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "disable：已恢复默认充电（写使能 + 回读校验通过）"
                ))
            } catch {
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "disable：恢复默认充电失败（\(error)），保持 active"
                ))
                throw error
            }
        } else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "disable：无控制后端，仅切换模式（恢复默认充电不可执行）"
            ))
        }

        applyPolicyLocked(
            DaemonPolicy(
                mode: "disabled", upperLimit: policy.upperLimit, hysteresis: policy.hysteresis,
                autoDischargeEnabled: policy.autoDischargeEnabled, fan: policy.fan,
                calibrationSchedule: policy.calibrationSchedule
            ),
            events: &events
        )
        persistPolicyLocked(events: &events)
        lastStatus = DaemonStatus(
            version: DaemonXPC.daemonVersion,
            mode: "disabled",
            upperLimit: policy.upperLimit,
            hysteresis: policy.hysteresis,
            lastAction: "disable",
            lastPercent: lastStatus?.lastPercent,
            lastExternalConnected: lastStatus?.lastExternalConnected,
            lastChargingEnabled: true,
            action: actionTrack.action,
            timestamp: Date()
        )
        return buildStatusLocked()
    }

    /// enable：切 active + enforce（评审：enforce 失败走 tick 纪律——记日志不抛出）。
    func enable() throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        // 用户动作清除终态锁存（P0-2：enable 是锁存终止事件之一）。
        actionTrack.clearUserActionLatch()
        applyPolicyLocked(
            DaemonPolicy(
                mode: "active", upperLimit: policy.upperLimit, hysteresis: policy.hysteresis,
                autoDischargeEnabled: policy.autoDischargeEnabled, fan: policy.fan,
                calibrationSchedule: policy.calibrationSchedule
            ),
            events: &events
        )
        persistPolicyLocked(events: &events)
        performTickLocked(events: &events)
        let status = buildStatusLocked()
        lock.unlock()
        emit(events)
        return status
    }

    /// getStatus：任意身份可调（状态非敏感，规格 §0.2）。
    func status() -> DaemonStatus {
        lock.lock()
        let status = buildStatusLocked()
        lock.unlock()
        return status
    }

    /// SIGTERM/SIGINT：恢复默认充电（写使能）→ exit(0)（红线 2；KeepAlive={SuccessfulExit:false}
    /// 确保恢复动作不被 launchd 重拉撤销）。
    func restoreAndExit() -> Never {
        var events: [LogEvent] = []
        lock.lock()
        // WP2 门控：动作活跃 → 先走统一 cancel（落终态 + 恢复限充语义）再恢复默认充电。
        // 审查 M3：SIGTERM 亦为 daemon 发起取消 → 锁存。
        if actionTrack.isActive {
            cancelActionLocked(events: &events, latchCancelled: true)
        }
        // Phase 5 v1.1：退出恢复风扇（boost 中 → Tg→原值 + Md=0，方案 §6.4 路口①）。
        releaseFanLocked(events: &events)
        if let backend {
            do {
                try backend.setChargingEnabled(true)
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "退出恢复：已写使能（00000000）"
                ))
            } catch {
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "退出恢复写使能失败：\(error)（仍按契约退出）"
                ))
            }
        } else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "退出恢复：无控制后端，跳过写使能"
            ))
        }
        lock.unlock()
        emit(events)
        exit(0)
    }

    /// SIGHUP：重读 policy 文件（launchd 惯例，不退出）。载入失败保留当前策略。
    /// 模式 active → disabled 时与 disable 语义一致恢复默认充电；切回 active 则全量重评估。
    func reloadPolicy() {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }

        guard let loaded = policyStore.load() else {
            events.append(LogEvent(
                category: .lifecycle, level: .error,
                message: "SIGHUP：policy.json 缺失或非法，保留当前策略"
            ))
            return
        }
        let oldMode = policy.mode
        applyPolicyLocked(loaded, events: &events)
        events.append(LogEvent(
            category: .lifecycle, level: .info,
            message: "SIGHUP：已重读策略（mode=\(loaded.mode) upper=\(loaded.upperLimit) hys=\(loaded.hysteresis)）"
        ))

        // WP2 门控（规格 §1.1 SIGHUP 行；P1-1）：重载后 mode == "disabled" → 取消动作；
        // 否则动作存活——deadline（start 时绝对 Date）与完成判定不重算（轨道未触碰）。
        if loaded.mode == "disabled" && actionTrack.isActive {
            // 审查 M3：SIGHUP-disabled 为 daemon 发起取消 → 锁存。
            cancelActionLocked(events: &events, latchCancelled: true)
        } else if loaded.mode == "active" {
            // 动作存活分支：仅记日志（状态照旧），不重算 deadline。
            if actionTrack.isActive {
                events.append(LogEvent(
                    category: .lifecycle, level: .info,
                    message: "SIGHUP：一次性动作存活（deadline 不重算）"
                ))
            }
        }

        if oldMode == "active" && loaded.mode == "disabled" {
            if let backend {
                do {
                    _ = try controller.perform(.enableCharging, backend: backend)
                    events.append(LogEvent(
                        category: .control, level: .info,
                        message: "SIGHUP：模式切为 disabled，已恢复默认充电"
                    ))
                } catch {
                    events.append(LogEvent(
                        category: .control, level: .error,
                        message: "SIGHUP 恢复默认充电失败：\(error)"
                    ))
                }
            }
        } else if loaded.mode == "active" {
            performTickLocked(events: &events)
        }
    }

    // MARK: - 内部：心跳实现

    private func performTick() {
        var events: [LogEvent] = []
        lock.lock()
        performTickLocked(events: &events)
        lock.unlock()
        emit(events)
    }

    /// 锁内 tick（调用方负责解锁与 emit；WP2 起 internal——DaemonCore+OneShot.swift 的
    /// fullOnce 启动后调用；WP2' 放电维护分支在 DaemonCore+Discharge.swift）：
    /// backend 保证 → 采样 → 控制键读取 → 电量变化事件 → active 模式 enforce → lastStatus。
    func performTickLocked(events: inout [LogEvent]) {
        // 1) 控制后端（探测失败 → 计数自愈；无后端不能构建上下文，保留上次状态）。
        guard let backend = ensureBackendLocked(events: &events) else {
            // WP2' 评审 P1-5：放电动作活跃期的早退 = 监护缺失（计数 ≥3 tick 终止）。
            noteDischargeMonitoringLossLocked(events: &events)
            return
        }

        // 2) 电池采样。
        let snapshot: BatterySnapshot
        do {
            snapshot = try monitor.snapshot()
        } catch {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "电池采样失败：\(error)（保留上次状态）"
            ))
            noteDischargeMonitoringLossLocked(events: &events)
            return
        }

        // 3) 控制键当前状态（enforce 的决策输入，读自 backend——崩溃重启不丢决策上下文）。
        let chargingEnabled: Bool
        do {
            chargingEnabled = try backend.chargingEnabled()
        } catch {
            noteControlFailureLocked(error, events: &events, context: "控制键读取")
            noteDischargeMonitoringLossLocked(events: &events)
            return
        }

        // 4) 电量整数百分点变化事件（评审 A-1：batteryLevelChanged）。
        if lastPercent != snapshot.percent {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "电量变化：\(lastPercent.map(String.init) ?? "未知") → \(snapshot.percent)%"
            ))
            lastPercent = snapshot.percent
        }
        // WP2' 适配器翻转检测（code-review P1 armed 语义）：终止后 disarm——放电稳态
        // 遥测 ext=false、恢复 CHIE 后 1-2 tick 内回跳 true 是放电自身恢复痕迹，仅
        // 重新武装不开门；武装后的转移（真实拔/插）才开重插门。首 tick lastStatus nil
        // 的恒真比较被 disarm 吸收（崩溃恢复已记冷却关门，不误开）。
        if snapshot.externalConnected != lastStatus?.lastExternalConnected {
            if adapterCycleArmed {
                adapterCycleSinceAutoCompletion = true
            } else if snapshot.externalConnected {
                adapterCycleArmed = true   // 放电后回跳：仅武装
            }
        }

        // Phase 5 v1.4 终态观察（UD-5 第②点，空闲臂）：无在轨动作 ∧ 锁存字面量 ∈
        // 校准终态族（全等匹配）→ 补写上次校准记录——覆盖 done/timeout/safety 等
        // 锁存型终态（取消路径不锁存，由 cancelActionLocked 即时补写，第①点）。
        // startedAt 去重（第③点）在记录助手内——锁存存活期内逐 tick 不重写。
        if !actionTrack.isActive, let latched = actionTrack.latchedLiteral,
           let outcome = calibrationOutcomeLiteral(latched) {
            recordCalibrationOutcomeLocked(outcome: outcome, startedAt: nil, events: &events)
        }

        // 5) 策略执行：动作活跃 → 维护分支（规格 §1.1 tick 行——采样/控制键读取/percent
        // 事件（步骤 2/3/4）保留，仅「enforce」替换为完成判定 + 保活）；其余原样。
        let context = ChargingContext(
            percent: snapshot.percent,
            externalConnected: snapshot.externalConnected,
            chargingEnabled: chargingEnabled
        )
        var actionName = "enforce:noop"
        if actionTrack.isActive {
            if actionTrack.action?.kind == Discharge.dischargeToLimitKind {
                // WP2'：放电 → 放电维护分支（本节判定链 + 副作用）。
                actionName = maintainDischargeLocked(
                    now: Date(),
                    snapshot: snapshot,
                    backend: backend,
                    events: &events
                )
            } else if actionTrack.action?.kind == Calibration.kind {
                // WP3：校准 → 相位状态机维护分支（转移纯函数 + 副作用，方案 §2.2）。
                actionName = maintainCalibrationLocked(
                    now: Date(), snapshot: snapshot, backend: backend, events: &events
                )
            } else {
                actionName = maintainActionLocked(
                    now: Date(),
                    fullyCharged: snapshot.fullyCharged,
                    isCharging: snapshot.isCharging,
                    percent: snapshot.percent,
                    backend: backend,
                    events: &events
                )
            }
        } else if policy.mode == "active" {
            // §2.4 CHIE 残留不变量巡检（无动作期，安全红线）：命中 → 本 tick 转
            // 安全告警（lastAction=safety），enforce 延后至下 tick（巡检优先级最高）。
            if let patrolLiteral = patrolCHIEResidualLocked(backend: backend, events: &events) {
                actionName = patrolLiteral
            } else {
                // WP2' 自动触发插桩（优先序钉死：巡检命中 > 自动触发 > enforce，R1
                // P2-3——巡检命中 tick 到此为止，无「恢复 0x00 后同 tick 又写 0x8」乒乓）。
                // 判定链全过 → 锁内启动（locked 内部不 tick）；catch 记 warn 后落回
                // 下方既有 enforce 块（不重入 performTickLocked——失败臂已做 CHIE
                // 恢复/回滚，残留无约束窗口 ≤1 tick，下 tick 全量收敛，R1 P1-1）。
                var autoStarted = false
                var calibrationStarted = false
                let tickNow = Date()
                if Discharge.autoTriggerReady(
                    enabled: policy.autoDischargeEnabled,
                    mode: policy.mode,
                    externalConnected: snapshot.externalConnected,
                    percent: snapshot.percent,
                    upperLimit: policy.upperLimit,
                    actionActive: false,          // 本分支进入条件即 !actionTrack.isActive
                    dischargeCapable: capabilities?.contains(DaemonXPC.capabilityDischarge) == true,
                    now: tickNow,
                    lastAutoCompletion: lastAutoDischargeCompletedAt,
                    adapterCycleSinceCompletion: adapterCycleSinceAutoCompletion
                ) {
                    do {
                        if try dischargeToLimitLocked(now: tickNow, initiator: .auto, events: &events) == .started {
                            autoStarted = true
                            actionName = maintainDischargeLocked(
                                now: tickNow, snapshot: snapshot, backend: backend, events: &events
                            )
                        }
                    } catch {
                        events.append(LogEvent(
                            category: .control, level: .warn,
                            message: "自动放电触发失败：\(error)"
                        ))
                    }
                }
                if !autoStarted {
                    // Phase 5 v1.4 调度臂（空闲 active 臂内、autoTriggerReady 判定
                    // **之后**——自动放电就绪优先占轨，校准下 tick 重判，R1 P2 次序
                    // 钉死）：动作空闲（本分支前提）∧ 调度开启 ∧ 周期就绪 → 锁内
                    // 自动启动（直调 Locked 版——本处已持锁，NSLock 不可重入，UD-6）。
                    // 复用本拍 snapshot（免重复拍电池，R2 P3）。
                    if let schedule = policy.calibrationSchedule, schedule.enabled,
                       calibrationAutoStartReady(
                           now: tickNow,
                           lastStartedAt: calibrationAnchorDateLocked(),
                           schedule: schedule
                       ) {
                        do {
                            if try startCalibrationLocked(
                                initiator: .auto, snapshot: snapshot, events: &events
                            ) == .started {
                                // 同拍 maintainCalibrationLocked 接管（R2 P1，照
                                // autoDischarge autoStarted 门结构——使 enforce 块
                                // 跳过，防 enforce 按 idle 语境对着 chargeFull 相写
                                // 停充，30s 后才被保活纠正）。
                                calibrationStarted = true
                                actionName = maintainCalibrationLocked(
                                    now: tickNow, snapshot: snapshot, backend: backend, events: &events
                                )
                            }
                        } catch let rejection as CalibrationStartRejection
                            where rejection == .persistenceFailed {
                            // persistenceFailed 提级 warn（P3-1，对齐自动放电臂 catch
                            // warn 先例）：action.json 写失败 = 动作未落盘的异常态，
                            // 非静默顺延；下 tick 幂等重试，残留交启动崩溃恢复兜底。
                            events.append(LogEvent(
                                category: .control, level: .warn,
                                message: "自动校准启动失败：\(rejection)（持久化是动作存活的前提）"
                            ))
                        } catch {
                            // 前置拒绝静默顺延（info 级，防窗口内每 30s 刷 error）：
                            // 不写锚点——当日窗口内顺延重试，窗口过后自然跨日（UD-4）。
                            events.append(LogEvent(
                                category: .control, level: .info,
                                message: "自动校准未启动：\(error)（静默顺延，窗口内下 tick 重判）"
                            ))
                        }
                    }
                }
                if !autoStarted && !calibrationStarted {
                do {
                    // WP1：温度守卫介入常规执法——decide → ThermalGuard.guarded →
                    // perform（noop 不触碰 backend；enable/disable 经写后回读校验，
                    // 红线 5 不变）。「充电中升温」（chargingEnabled==true ∧ percent
                    // < 上限）时 decide 恒 noop，守卫直接看充电现态判热停写（方案
                    // §2.2）。actionName 映射：暂停态（case 2/3/4）统一字面量
                    // enforce:tempPause——case 3/4 无写也返回，percent < 恢复阈值
                    // 期间持续可见（滞回带 [resume, upper) 内落 case 6 不标——
                    // 限充滞回语义，方案 §2.1；审查 M3 同构）。
                    let base = controller.decide(context: context)
                    let guarded = ThermalGuard.guarded(
                        base: base,
                        context: context,
                        temperatureC: snapshot.temperatureC
                    )
                    _ = try controller.perform(guarded.action, backend: backend)
                    if guarded.tempPauseActive {
                        actionName = "enforce:tempPause"
                    } else {
                        switch guarded.action {
                        case .enableCharging: actionName = "enforce:enableCharging"
                        case .disableCharging: actionName = "enforce:disableCharging"
                        case .noop: actionName = "enforce:noop"
                        }
                    }
                } catch BackendError.verifyFailed(let key, let desired, let actual) {
                    // 外部写者在写读之间翻转状态 = 冲突显式化（WP4 不得误诊为协议故障）。
                    // 错误臂优先于暂停态显示：热停写被外部/硬件拒绝是红线 5 事件，
                    // 显式化压过状态行注词（方案 §2.2）。
                    actionName = "enforce:verifyFailed"
                    events.append(LogEvent(
                        category: .control, level: .warn,
                        message: "回读校验失败（key=\(key) desired=\(desired) actual=\(actual)）——外部写者冲突显式化"
                    ))
                } catch {
                    actionName = "enforce:error"
                    noteControlFailureLocked(error, events: &events, context: "策略执行")
                }
                }   // if !autoStarted && !calibrationStarted（未自动启动才落常规 enforce 块）
            }
        } else {
            // disabled 档同样巡检（不变式无条件：CHIE=0x8 仅允许在动作活跃期存在）。
            if let patrolLiteral = patrolCHIEResidualLocked(backend: backend, events: &events) {
                actionName = patrolLiteral
            } else {
                actionName = "disabled:idle"
            }
        }

        // 6) 更新快照（保留上次状态 = lastStatus 不被失败 tick 覆盖）。
        // lastAction 经终态锁存生效值（P0-2：fullOnce:* 终态不被常规 tick 覆盖）。
        lastStatus = DaemonStatus(
            version: DaemonXPC.daemonVersion,
            mode: policy.mode,
            upperLimit: policy.upperLimit,
            hysteresis: policy.hysteresis,
            lastAction: actionTrack.effectiveLastAction(actionName),
            lastPercent: snapshot.percent,
            lastExternalConnected: snapshot.externalConnected,
            lastChargingEnabled: chargingEnabled,
            action: actionTrack.action,
            timestamp: snapshot.timestamp
        )
    }

    /// 锁内建立/复用控制后端。返回 nil = 探测失败（已计数，≥3 触发重建）。
    private func ensureBackendLocked(events: inout [LogEvent]) -> (any ChargingBackend)? {
        if let backend { return backend }
        // 自愈：连续失败 ≥3 次 → 先重建 SMCClient（IOKit 连接可能失效）再探测。
        if consecutiveControlFailures >= 3 {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "控制路径连续失败 ≥3 次：重建 SMCClient 后重试（评审 C-3）"
            ))
            smcClient = nil
            backend = nil
        }
        do {
            let detected = try establishBackendLocked(events: &events)
            consecutiveControlFailures = 0
            return detected
        } catch {
            consecutiveControlFailures += 1
            events.append(LogEvent(
                category: .control, level: .error,
                message: "后端探测失败（连续第 \(consecutiveControlFailures) 次）：\(error)"
            ))
            return nil
        }
    }

    /// 锁内探测：新建 SMCClient + RuntimeProbe（成功即持有；失败上抛并记探测日志）。
    /// WP2'：capabilities 置值挂本成功路径（含自愈重建——ensureBackendLocked 的
    /// 重建亦经本方法，能力随探测结果刷新，评审轮 2 注记 1）。
    private func establishBackendLocked(events: inout [LogEvent]) throws -> any ChargingBackend {
        let client = try SMCClient.makeDefault()
        let detected = try RuntimeProbe.probe(client: client)
        smcClient = client
        fanState.clientGeneration += 1   // Phase 5 v1.1：SMCClient 重建代际——风扇 facts 缓存失效信号
        backend = detected
        capabilities = RuntimeProbe.supportsDischarge(backend: detected, client: client)
            ? [DaemonXPC.capabilityDischarge, DaemonXPC.capabilityAutoDischarge, DaemonXPC.capabilityCalibration]
            : []
        events.append(LogEvent(
            category: .control, level: .info,
            message: "后端探测成功：\(detected.name)（\(detected.keyNames.joined(separator: ", "))）能力=\(capabilities?.joined(separator: ",") ?? "[]")"
        ))
        return detected
    }

    /// 控制路径失败计数（评审 C-3 统一口径：探测失败/控制键读取失败/enforce 传输类失败；
    /// verifyFailed 由调用方单独处理，不计数——冲突显式化，非连接问题）。
    /// 计数达 3 → 丢弃后端，下 tick 重建。WP2 起 internal（保活重写走本计数）。
    func noteControlFailureLocked(_ error: Error, events: inout [LogEvent], context: String) {
        consecutiveControlFailures += 1
        events.append(LogEvent(
            category: .control, level: .error,
            message: "\(context)失败（连续第 \(consecutiveControlFailures) 次）：\(error)"
        ))
        if consecutiveControlFailures >= 3 {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "控制路径连续失败 ≥3 次：重建 SMCClient（IOKit 连接可能失效，评审 C-3）"
            ))
            smcClient = nil
            backend = nil
            consecutiveControlFailures = 0
        }
    }

    // MARK: - 内部：策略/持久化/状态

    /// 应用策略（validated 保证可构造；防御分支理论上不可达）。
    private func applyPolicyLocked(_ newPolicy: DaemonPolicy, events: inout [LogEvent]) {
        guard let limit = try? LimitPolicy(upperLimit: newPolicy.upperLimit, hysteresis: newPolicy.hysteresis) else {
            events.append(LogEvent(
                category: .lifecycle, level: .error,
                message: "策略非法（validated 已保证，不应发生）：upper=\(newPolicy.upperLimit) hys=\(newPolicy.hysteresis)"
            ))
            return
        }
        policy = newPolicy
        controller.updatePolicy(limit)
    }

    /// 持久化当前策略（失败仅记日志——内存策略继续生效；SIGHUP 重读会回落磁盘旧值）。
    /// ⚠️ 可见性：Phase 5 v1.1 起 internal——setFanConfig 持久化风扇策略复用本方法。
    func persistPolicyLocked(events: inout [LogEvent]) {
        do {
            try policyStore.save(policy)
            events.append(LogEvent(
                category: .lifecycle, level: .info,
                message: "策略已持久化：mode=\(policy.mode) upper=\(policy.upperLimit) hys=\(policy.hysteresis)"
            ))
        } catch {
            events.append(LogEvent(
                category: .lifecycle, level: .error,
                message: "策略持久化失败：\(error)"
            ))
        }
    }

    /// 组装当前状态快照（模式/策略取当前值；采样字段取 lastStatus，未采样过为 nil）。
    /// lastAction 经终态锁存生效值；action 取轨道当前值（动作活跃但 tick 未成功的
    /// 空窗期仍向 App 呈现动作——轮询不冻结，P1-2）。WP2 起 internal（XPC 动作命令
    /// 经 fullOnce/cancelAction 调用本方法）。
    func buildStatusLocked() -> DaemonStatus {
        var status = lastStatus ?? DaemonStatus(
            version: DaemonXPC.daemonVersion,
            mode: policy.mode,
            upperLimit: policy.upperLimit,
            hysteresis: policy.hysteresis,
            timestamp: Date()
        )
        status.version = DaemonXPC.daemonVersion
        status.mode = policy.mode
        status.upperLimit = policy.upperLimit
        status.hysteresis = policy.hysteresis
        status.autoDischargeEnabled = policy.autoDischargeEnabled
        status.fan = fanStatusLocked()
        // Phase 5 v1.4：校准调度三键**恒填**（未配置 → .default，UD-7——照
        // fanStatusLocked `policy.fan ?? .default` 先例，防新装用户被误判旧 daemon）；
        // lastCal 三键读 state 内存缓存（无记录 → 缺席表达，勿读盘）。
        let schedule = policy.calibrationSchedule ?? .default
        status.calSchedEnabled = schedule.enabled
        status.calSchedIntervalDays = schedule.intervalDays
        status.calSchedStartHour = schedule.startHour
        if let last = calibrationState.lastCalibration {
            status.lastCalStart = last.startedAt
            status.lastCalEnd = last.endedAt
            status.lastCalOutcome = last.outcome
        }
        status.lastAction = actionTrack.effectiveLastAction(status.lastAction)
        status.action = actionTrack.action
        status.capabilities = capabilities
        return status
    }

    // MARK: - 锁外日志

    /// 锁外统一发出（锁内只组装，规格 §0.3）。WP2 起 internal（扩展方法在 lock 内组装、
    /// 解锁后经本方法发出）。
    func emit(_ events: [LogEvent]) {
        for event in events {
            let logger = event.category == .lifecycle ? lifecycleLogger : controlLogger
            let message = event.message
            switch event.level {
            case .error:
                logger.error("\(message, privacy: .public)")
            case .warn:
                logger.warning("\(message, privacy: .public)")
            case .info:
                logger.info("\(message, privacy: .public)")
            }
        }
    }
}