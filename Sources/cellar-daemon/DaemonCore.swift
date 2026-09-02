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
    /// IOKit 传输持有方（重建 SMCClient 即换新 transport）。
    private var smcClient: SMCClient?
    /// 探测得到的后端；nil = 尚未探测成功（心跳驱动重试/自愈）。
    var backend: (any ChargingBackend)?
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

    // MARK: - 生命周期

    init(policyStore: PolicyStore, log: os.Logger, actionStore: ActionStore = ActionStore(url: ActionStore.defaultURL)) {
        self.policyStore = policyStore
        self.actionStore = actionStore
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
        if let pending = actionStore.load() {
            try? actionStore.delete()
            _ = actionTrack.cancelForCrashRecovery()
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

        // WP2 P0-1 门控：动作活跃 → 跳过睡前停充（充电即目标，无上限可守；否则用户
        // 睡前点充满 → 夜间停充 → 超时取消，最高频场景失效）。lastAction 保持动作字面量。
        if actionTrack.isActive {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "睡眠策略跳过停充：一次性动作进行中（充电即目标，规格 P0-1）"
            ))
            lastStatus = DaemonStatus(
                version: DaemonXPC.daemonVersion,
                mode: policy.mode,
                upperLimit: policy.upperLimit,
                hysteresis: policy.hysteresis,
                lastAction: actionTrack.effectiveLastAction(
                    OneShotLiteral.start(kind: actionTrack.action?.kind ?? OneShot.fullOnceKind)
                ),
                lastPercent: lastStatus?.lastPercent,
                lastExternalConnected: lastStatus?.lastExternalConnected,
                lastChargingEnabled: lastStatus?.lastChargingEnabled,
                action: actionTrack.action,
                timestamp: Date()
            )
            return
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
    func setLimits(upper: Int, hys: Int) throws -> DaemonStatus {
        _ = try LimitPolicy(upperLimit: upper, hysteresis: hys)
        var events: [LogEvent] = []
        lock.lock()
        // WP2 门控：动作活跃 → 隐式取消（恢复限充语义）→ 再设新限并立即 enforce。
        if actionTrack.isActive {
            cancelActionLocked(events: &events)
        } else {
            // 用户动作清除终态锁存（P0-2：setLimits/enable/disable/fullOnce 重启）。
            actionTrack.clearUserActionLatch()
        }
        applyPolicyLocked(DaemonPolicy(mode: "active", upperLimit: upper, hysteresis: hys), events: &events)
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
        if actionTrack.isActive {
            cancelActionLocked(events: &events)
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
            DaemonPolicy(mode: "disabled", upperLimit: policy.upperLimit, hysteresis: policy.hysteresis),
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
            DaemonPolicy(mode: "active", upperLimit: policy.upperLimit, hysteresis: policy.hysteresis),
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
        if actionTrack.isActive {
            cancelActionLocked(events: &events)
        }
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
            cancelActionLocked(events: &events)
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
    /// fullOnce 启动后调用）：
    /// backend 保证 → 采样 → 控制键读取 → 电量变化事件 → active 模式 enforce → lastStatus。
    func performTickLocked(events: inout [LogEvent]) {
        // 1) 控制后端（探测失败 → 计数自愈；无后端不能构建上下文，保留上次状态）。
        guard let backend = ensureBackendLocked(events: &events) else { return }

        // 2) 电池采样。
        let snapshot: BatterySnapshot
        do {
            snapshot = try monitor.snapshot()
        } catch {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "电池采样失败：\(error)（保留上次状态）"
            ))
            return
        }

        // 3) 控制键当前状态（enforce 的决策输入，读自 backend——崩溃重启不丢决策上下文）。
        let chargingEnabled: Bool
        do {
            chargingEnabled = try backend.chargingEnabled()
        } catch {
            noteControlFailureLocked(error, events: &events, context: "控制键读取")
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

        // 5) 策略执行：动作活跃 → 维护分支（规格 §1.1 tick 行——采样/控制键读取/percent
        // 事件（步骤 2/3/4）保留，仅「enforce」替换为完成判定 + 保活）；其余原样。
        let context = ChargingContext(
            percent: snapshot.percent,
            externalConnected: snapshot.externalConnected,
            chargingEnabled: chargingEnabled
        )
        var actionName = "enforce:noop"
        if actionTrack.isActive {
            actionName = maintainActionLocked(
                now: Date(),
                fullyCharged: snapshot.fullyCharged,
                isCharging: snapshot.isCharging,
                percent: snapshot.percent,
                backend: backend,
                events: &events
            )
        } else if policy.mode == "active" {
            do {
                let action = try controller.enforce(context: context, backend: backend)
                switch action {
                case .enableCharging: actionName = "enforce:enableCharging"
                case .disableCharging: actionName = "enforce:disableCharging"
                case .noop: actionName = "enforce:noop"
                }
            } catch BackendError.verifyFailed(let key, let desired, let actual) {
                // 外部写者在写读之间翻转状态 = 冲突显式化（WP4 不得误诊为协议故障）。
                actionName = "enforce:verifyFailed"
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "回读校验失败（key=\(key) desired=\(desired) actual=\(actual)）——外部写者冲突显式化"
                ))
            } catch {
                actionName = "enforce:error"
                noteControlFailureLocked(error, events: &events, context: "策略执行")
            }
        } else {
            actionName = "disabled:idle"
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
    private func establishBackendLocked(events: inout [LogEvent]) throws -> any ChargingBackend {
        let client = try SMCClient.makeDefault()
        let detected = try RuntimeProbe.probe(client: client)
        smcClient = client
        backend = detected
        events.append(LogEvent(
            category: .control, level: .info,
            message: "后端探测成功：\(detected.name)（\(detected.keyNames.joined(separator: ", "))）"
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
    private func persistPolicyLocked(events: inout [LogEvent]) {
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
        status.lastAction = actionTrack.effectiveLastAction(status.lastAction)
        status.action = actionTrack.action
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