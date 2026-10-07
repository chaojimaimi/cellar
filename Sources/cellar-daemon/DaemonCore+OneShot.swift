import Foundation
import CellarCore

// MARK: - WP2 一次性动作（规格 §1.1；全部锁内）

/// WP2 一次性动作「充满一次」的 daemon 侧实现（扩展文件拆分——DaemonCore.swift
/// 触及 800 行硬上限；本扩展访问的成员在 DaemonCore.swift 中已放宽为 internal）。
///
/// ⚠️ 可见性说明：cellar-daemon 为 **executable target**，internal 符号模块外不可达
/// ——单一属主不变量（WP4 §0.1）不受影响：XPC/心跳/信号仍全部经 DaemonCore 的加锁
/// 方法操作状态，锁纪律（规格 §0.3）不变。
///
/// 六路径门控（规格 §1.1）的语义决策全部经 CellarCore.OneShotTrack（锁内单实例），
/// 本扩展只做副作用（写 CHTE / 删文件）与日志：daemon 侧逻辑与 CellarCoreCheck
/// 钉死的轨道转移同源。
extension DaemonCore {
    /// fullOnce 窗清除共用 helper（0.23.2 ②——§1.2/§1.4 裁决落点；全部锁内）：
    /// **只清状态——零 tick 零域写**（红 R2 钉死）：
    /// ① 窗标志 + startedAt + 充满去抖计数（窗口态三件）；
    /// ② `calibrationCoexistenceState` 清零（§1.4 兼修——共存 suspected 惰性保态会
    ///    吞掉窗毕恢复拍的域写（suppressionPlan 早退先于卫生臂），用户显式/自动完成
    ///    意图优先于指纹证据；0.23.1 手动恢复同型潜伏缺陷一并修复）；
    /// ③ 锁存字面量：`.full` → `fullOnce:done` / `.timeout` → `fullOnce:timeout`
    ///    （notificationEvents 映射与 App done 横幅复用既有字面量——§1.6 零新增）；
    ///    `.manual`（XPC 手动清窗）不落字面量（用户即时反馈路径，无终态语义）。
    /// 域写收敛：自动路径交同拍 observationTick 汇聚路由（清窗后 `fullOnceWindowActive`
    /// =false → route 收敛 target，防嵌套 tick）；手动路径交外层既有 performTickLocked
    /// （XPC 语境非嵌套）。
    enum FullOnceWindowClearReason {
        /// 充满自动恢复（连续 3 拍命中——锁存 fullOnce:done）。
        case full
        /// 4h 超时兜底（锁存 fullOnce:timeout）。
        case timeout
        /// 手动/XPC 清窗（setLimits/disable/SIGHUP/cancelAction/restoreChargeLimit
        /// ——不落字面量，消息由 detail 承载）。
        case manual
    }

    func clearFullOnceWindowStateLocked(
        reason: FullOnceWindowClearReason, detail: String? = nil, events: inout [LogEvent]
    ) {
        fullOnceWindowActive = false
        fullOnceWindowStartedAt = nil
        fullOnceFullTicks = 0
        // ② 共存 suspected 清零（§1.4）：清零即退出抑制——同拍/外层汇聚路由恢复
        // 域写不被 suspected 吞（`.empty` = suspected=false ∧ 指纹计数归零）。
        calibrationCoexistenceState = CalibrationCoexistence.State.empty
        switch reason {
        case .full:
            actionTrack.latchTerminalLiteral(OneShotLiteral.done())
            // lastStatus 直写照 cancelActionLocked/日程转移先例（仅可见性面——
            // buildStatusLocked 的锁存生效值同源，App 两条读取路径一致）。
            let prior = lastStatus?.lastAction
            lastStatus?.lastAction = actionTrack.effectiveLastAction(prior)
            events.append(LogEvent(
                category: .control, level: .info,
                message: "fullOnce 自动恢复：充满判据连续 \(FullChargeDetection.debounceTicks) 拍命中——窗关闭、done 字面量锁存、共存识别态清零；域写交同拍汇聚路由收敛（零直写防嵌套 tick）"
            ))
        case .timeout:
            actionTrack.latchTerminalLiteral(OneShotLiteral.timeout())
            let prior = lastStatus?.lastAction
            lastStatus?.lastAction = actionTrack.effectiveLastAction(prior)
            events.append(LogEvent(
                category: .control, level: .info,
                message: "fullOnce 窗超时（\(Int(FullChargeDetection.fullOnceWindowTimeout / 3600))h 兜底）：自动恢复——窗关闭、timeout 字面量锁存、共存识别态清零；域写交同拍汇聚路由收敛（零直写防嵌套 tick）"
            ))
        case .manual:
            events.append(LogEvent(
                category: .control, level: .info,
                message: detail ?? "fullOnce 临时放开窗已清除"
            ))
        }
    }

    /// fullOnce XPC（前置 + 幂等拆分，规格 §1.1/§2.2 + 0.23.2 §1.5）：
    /// - 前置拒绝：mode != active / 未外接 / 外接未知 → 上抛 daemonError 原文；
    /// - 幂等拆分：动作在轨 ∧ 27 → **上抛 .actionOccupiedOn27**（27 窗模式 fullOnce
    ///   不占轨——轨上活跃的是放电/校准，静默幂等回状态 = App 按钮假成功形态）；
    ///   动作在轨 ∧ 26 → 静默幂等返回（**原语义不动**——26 红线）；
    /// - 已满电 → 接受，动作启动后首个 tick 即进入完成判定路径（2 tick 去抖照常）。
    func fullOnce() throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }

        if actionTrack.isActive {
            if modernBackendTerminalLocked {
                // 0.23.2 §1.5：27 在轨动作（放电/校准）→ 显式拒绝（新拒因）。
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "fullOnce 拒绝：27 平台在轨动作活跃（\(actionTrack.action?.kind ?? "?")）——actionOccupiedOn27（先完成或取消）"
                ))
                throw OneShotStartRejection.actionOccupiedOn27
            }
            events.append(LogEvent(
                category: .control, level: .info,
                message: "fullOnce 重复请求：动作已在进行中，回当前状态（幂等）"
            ))
            return buildStatusLocked()
        }
        // 前置外接判定：新鲜快照优先；失败回落上次已知值；均未知 → 拒绝（不无据启动）。
        let external: Bool?
        do {
            external = try monitor.snapshot().externalConnected
        } catch {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "fullOnce 前置：电池快照失败（\(error)），使用上次已知外接状态"
            ))
            external = lastStatus?.lastExternalConnected
        }
        // Phase 5 v1.7 M2 原生限充守卫（方案 §3.1，挂点 fullOnceStartPrecondition 之二
        // ——校准臂 startCalibrationLocked 平行）：每请求一次读盘（/Library 域只读）；
        // 阻断判据与 fail-open 边界全在 CellarCore 纯函数（detectorError → 函数内
        // os_log warn 放行）。拒绝发生在 startIfIdle 之前 → 无锚点写入。
        let nativeReading = NativeChargeLimit.load(
            rooted: try Data(contentsOf: NativeChargeLimit.powerdPoliciesURL)
        )
        // **0.23.1 编排退役**：27 臂收敛为平台判别 + 原生守卫绕过（放行交下方
        // 置窗臂）；原「编排开关前置检查」（开关关 → .orchestrationSwitchOff 拒收）
        // 随编排开关决策消费面退役删除；26 瞬态（nil）/26 legacy（[]）照常走
        // 原生守卫（26 行为零变化）。
        if let rejection = fullOnceStartPrecondition(
            mode: policy.mode, externalConnected: external, nativeLimit: nativeReading,
            capabilities: capabilities
        ) {
            throw rejection
        }
        // 0.21.0 §1.3 → **0.23.1 置窗-only 化 → 0.23.2 自动恢复批**：27 分支——
        // **不启动动作轨**（26 语义保留），开临时放开窗 + 即时 tick（observationTick
        // → 汇聚点域随写 100——等价「完全放开」，M1 模型 v2 域写值直接执法）。原
        // pending(100) 产出（token/target/lastRequestAt）随断言链退役删除——App 消费
        // 链已不存在，窗内充电放开完全由域承载。policy.upperLimit < 80 分支同样合法
        // ——窗毕自动恢复臂/用户显式恢复臂即时 tick 域写回 target。**0.23.2 自动恢复
        // （§3）**：窗起始时刻与充满去抖计数随窗置位——充满判据连续 3 拍命中 →
        // ~1.5min 自动回落；4h 超时兜底（FullChargeDetection.fullOnceWindowTimeout，
        // 与 26 fullOnce 超时同源）；手动恢复臂（restoreChargeLimit）保持即时。
        if modernBackendTerminalLocked {
            actionTrack.clearUserActionLatch()   // 用户动作清除终态锁存（P0-2 对齐）
            fullOnceWindowActive = true
            fullOnceWindowStartedAt = Date()
            fullOnceFullTicks = 0
            events.append(LogEvent(
                category: .control, level: .info,
                message: "fullOnce 27：临时放开窗开启——域随写 100（免 root 免 set，M1 模型 v2 域写值直接执法）；充满判据连续 \(FullChargeDetection.debounceTicks) 拍命中自动恢复（~1.5min 回落，\(Int(FullChargeDetection.fullOnceWindowTimeout / 3600))h 超时兜底），手动恢复臂即时生效"
            ))
            performTickLocked(events: &events)
            return buildStatusLocked()
        }
        _ = actionTrack.startIfIdle(now: Date())
        // idle→active 原子持久化：写失败 → 动作不启动（上抛，App 原文上屏）。
        do {
            try actionStore.save(actionTrack.action!)
        } catch {
            _ = actionTrack.cancel()
            events.append(LogEvent(
                category: .control, level: .error,
                message: "fullOnce 启动失败：action.json 写入失败（\(error)）"
            ))
            throw OneShotStartRejection.persistenceFailed
        }
        events.append(LogEvent(
            category: .control, level: .info,
            message: "fullOnce 已启动：deadline=\(actionTrack.action?.deadline.description ?? "?")（4 小时超时）"
        ))
        // 即时 tick：保活使能充电 + 首样本（lastStatus 不冻结，P1-2）。
        performTickLocked(events: &events)
        return buildStatusLocked()
    }

    /// cancelAction XPC：无动作 → 幂等成功（回当前状态）；有动作 → 统一取消。
    func cancelAction() throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }

        if !actionTrack.isActive {
            // 0.21.1 §3.1（M1a P3-1）→ **0.23.1 清窗-only 化**：27 fullOnce 临时
            // 放开态取消——窗关闭 + 即时 tick（observationTick → 汇聚点域写回
            // target：恢复臂同款收敛；M1 模型 v2 域写值直接执法）。原「恢复
            // pending(policy.upperLimit) 产出」随断言链退役删除（无窗 → 下方既有
            // 幂等成功路径零变化——26 恒走本路径）。0.23.2：清面走共用 helper
            // （窗三件 + 共存 suspected 清零——红 R4 兼修；外层 performTickLocked 维持）。
            if fullOnceWindowActive {
                clearFullOnceWindowStateLocked(
                    reason: .manual,
                    detail: "fullOnce 临时放开已取消：窗关闭——即时 tick 域写回 target（\(policy.upperLimit)%，恢复臂同款收敛）",
                    events: &events
                )
                performTickLocked(events: &events)
                return buildStatusLocked()
            }
            events.append(LogEvent(
                category: .control, level: .info,
                message: "取消动作：无活跃动作（幂等成功）"
            ))
            return buildStatusLocked()
        }
        cancelActionLocked(events: &events)
        return buildStatusLocked()
    }

    /// 统一取消（规格 §1.1 setLimits/disable/restoreAndExit/SIGHUP 行共用）：
/// - fullOnce：写 CHTE 停充恢复限充语义 → lastAction=`fullOnce:cancel`（不锁存，直写）；
/// - dischargeToLimit（WP2' §2.3）：**恢复 CHIE=0x0（重试阶梯 + 告警——取消写失败
///   ≠ 取消完成，红线 5）→ enforce CHTE**（恢复限充语义，数据源 = lastStatus；
///   失败下 tick 常规 enforce 兜底）→ lastAction=`dischargeToLimit:cancel`；
/// - calibration（WP3 第三分支）：discharge 相（或 CHIE 回读非使能）→ CHIE 恢复
///   重试阶梯 + `enforceLimitChargingLocked`（恢复限充语义）
///   → lastAction=`calibration:cancel`；
/// - 清锁存 → 删 action.json。任何失败仅记日志——取消本身不因写失败中断。
///
/// `latchCancelled`（审查 M3）：setLimits/disable/restoreAndExit/SIGHUP-disabled
/// 为 daemon 发起取消 → discharge/calibration 取消字面量**锁存**（App 轮询必见
/// 终态、通知必发）；XPC cancelAction（用户点击取消）默认 false 不锁存（App 即时
/// 反馈路径）。fullOnce 不受本参数影响（恒走 cancel() 旧语义——cancel 不通知，
/// 锁存无消费面）。
/// `reason`（0.20.1 §2.1）：取消成因（用户/设置新上限/停用/退出/SIGHUP）——放电
/// 分支随事件落盘（挂钩表第五行；LogEvent 环随进程消失，持久轨迹才可溯源）。
    func cancelActionLocked(events: inout [LogEvent], latchCancelled: Bool = false, reason: String = "用户取消") {
        // kind 预取：cancel 会清空动作，分流判断必须在取消之前；
        // calibration 相位同理由：第三分支需要 phase 判定 CHIE 恢复；
        // calibration startedAt 同理由（v1.4 UD-5 第①点：终态补写取在手值——
        // state 锚点丢失时仍有源可取，R2 P3）。
        let kind = actionTrack.action?.kind
        let calibrationPhase = kind == Calibration.kind
            ? actionTrack.action?.phase.flatMap(Calibration.Phase.init(rawValue:))
            : nil
        let calibrationStartedAt = kind == Calibration.kind ? actionTrack.action?.startedAt : nil
        let literal: String?
        if latchCancelled && (kind == Discharge.dischargeToLimitKind || kind == Calibration.kind) {
            literal = actionTrack.cancelLatched()
        } else {
            literal = actionTrack.cancel()
        }
        guard let literal else { return }
        if kind == Discharge.dischargeToLimitKind {
            // 统一完成记录（五落点之三）：XPC cancelAction / setLimits·disable·SIGHUP·
            // SIGTERM 隐式取消一律记冷却 + 关翻转门（R1 P1-2——取消后被下一 tick
            // 立即重触发的漏洞修复）。
            noteDischargeTerminatedLocked()
            // 0.20.1 §2.1 事件落盘（挂钩表第五行·取消臂）：用户/隐式取消。
            Self.persistLog(DischargePersistEvent.cancelled(reason: reason).message)
            // 放电统一取消：恢复 CHIE（重试阶梯）+ enforce CHTE（恢复限充语义）。
            // 0.20 M1a §2.2 #9（:142 处置）：恢复写经控制面——26 tahoe 行为不变
            // （同一 client 同字节）；27 经 CHIE 探测连接真实还原，enforce 交 27
            // 收敛臂（编排/topoff 通道）。
            if let client = dischargeControlClientLocked {
                let restoreError = DischargeAdapterControl.restoreEnabled(
                    client: client, attempts: Discharge.terminalRestoreAttempts
                )
                if let restoreError {
                    events.append(LogEvent(
                        category: .control, level: .error,
                        message: "取消放电动作：CHIE 恢复失败（\(restoreError)——重试阶梯耗尽），残留交 §2.4 残留不变量巡检"
                    ))
                } else {
                    events.append(LogEvent(
                        category: .control, level: .info,
                        message: "取消放电动作：已恢复适配器使能（CHIE=0x00，回读校验通过）"
                    ))
                }
                // WP1：本作用域无现成 snapshot——锁内读一次温度（放电启动前置同款
                // 先例，方案 §1.9）；失败 → nil 旁路（≤1 tick 窗口，下 tick 常规
                // 守卫按充电现态重新介入，方案 §2.3）。
                enforceLimitChargingLocked(
                    backend: backend,
                    temperatureC: (try? monitor.snapshot())?.temperatureC,
                    events: &events
                )
            } else {
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "取消放电动作：无控制后端，跳过 CHIE 恢复与 enforce（仅落终态）"
                ))
            }
        } else if kind == Calibration.kind {
            // WP3 第三分支：校准取消——discharge 相（CHIE=0x8 在场）或回读非使能
            // （残留，fail-closed）→ CHIE 恢复重试阶梯；enforce CHTE 恢复限充语义
            // （数据源 = lastStatus；失败下 tick 常规 enforce 兜底，同放电分支）。
            if let backend, backend.adapterControlSupported {
                if calibrationPhase == .discharge
                    || Discharge.residualPatrolNeeded(enabled: (try? backend.adapterEnabled()) ?? nil) {
                    restoreCalibrationCHIELocked(terminal: "取消", events: &events)
                }
                enforceLimitChargingLocked(
                    backend: backend,
                    temperatureC: (try? monitor.snapshot())?.temperatureC,
                    events: &events
                )
            } else if modernBackendTerminalLocked {
                // 0.23.2 §③ code-review P1 补：27 校准取消臂（maintain abort 同款
                // 收敛）——restoreCalibrationCHIELocked 已 client 化（27 可用，原
                // 「无控制后端」warn 失实）；限充恢复 = 域直写 target（簿记包装），
                // 消「取消即安全恢复」FAQ 契约的 30-60s 巡检兜底窗。
                if calibrationPhase == .discharge {
                    restoreCalibrationCHIELocked(terminal: "取消", events: &events)
                }
                _ = topoffExecuteWriteLocked(
                    limit: policy.upperLimit, now: Date(), events: &events
                )
            } else {
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "取消校准动作：无控制后端，跳过 CHIE 恢复与 enforce（仅落终态）"
                ))
            }
            // Phase 5 v1.4 终态补写（UD-5 第①点）：取消链 OneShotTrack.cancel()
            // 不锁存字面量（latchedLiteral = nil）——空闲臂单点观察恒漏记最高频的
            // 「已取消」，在本臂即时补写（XPC cancelCalibration/cancelAction 与
            // SIGTERM/SIGHUP-disable 取消共用，latchCancelled 两态一点覆盖）；
            // startedAt 去重（第③点）在记录助手内。
            recordCalibrationOutcomeLocked(
                outcome: .cancel, startedAt: calibrationStartedAt, events: &events
            )
        } else if let backend {
            do {
                _ = try controller.perform(.disableCharging, backend: backend)
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "取消动作：已恢复限充（写 CHTE 停充 + 回读校验通过）"
                ))
            } catch {
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "取消动作：恢复限充写失败（\(error)）（取消仍生效）"
                ))
            }
        } else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "取消动作：无控制后端，跳过写停充（仅落终态）"
            ))
        }
        lastStatus?.lastAction = literal
        deleteActionFileLocked(events: &events)
    }

    /// 动作维护分支（performTickLocked 第 5 步动作分支；规格 §1.1 tick 行）：
    /// 完成（2 tick 去抖）/超时 → 恢复限充 + 删文件 + 终态锁存（轨道完成）；
    /// 未完成 → 保活充电（v1.5 UD-5 热守卫收编——temperatureC 非可选穿透，
    /// tick 步骤 2 采样失败即早退，本处温度恒在手）。返回本 tick 的 lastAction 字面量。
    func maintainActionLocked(
        now: Date,
        fullyCharged: Bool?,
        isCharging: Bool,
        percent: Int,
        temperatureC: Double,
        backend: any ChargingBackend,
        events: inout [LogEvent]
    ) -> String {
        switch actionTrack.tick(now: now, fullyCharged: fullyCharged, isCharging: isCharging, percent: percent) {
        case .completed:
            restoreLimitChargingLocked(backend: backend, terminal: "完成", events: &events)
            deleteActionFileLocked(events: &events)
            return actionTrack.latchedLiteral ?? OneShotLiteral.done()
        case .timedOut:
            restoreLimitChargingLocked(backend: backend, terminal: "超时", events: &events)
            deleteActionFileLocked(events: &events)
            return actionTrack.latchedLiteral ?? OneShotLiteral.timeout()
        case .keepAlive:
            keepAliveChargingLocked(backend: backend, temperatureC: temperatureC, events: &events)
            let literal = OneShotLiteral.start(kind: actionTrack.action?.kind ?? OneShot.fullOnceKind)
            return actionTrack.effectiveLastAction(literal) ?? literal
        case .idle:
            // 防御分支：维护分支仅在轨道活跃时进入，轨道 tick 空载不可达。
            return "enforce:noop"
        }
    }

    /// 终态恢复限充（写 CHTE 停充 + 回读校验；失败仅记日志——下 tick 常规 enforce 兜底）。
    func restoreLimitChargingLocked(backend: any ChargingBackend, terminal: String, events: inout [LogEvent]) {
        do {
            _ = try controller.perform(.disableCharging, backend: backend)
            events.append(LogEvent(
                category: .control, level: .info,
                message: "fullOnce \(terminal)：已恢复限充（写 CHTE 停充 + 回读校验通过）"
            ))
        } catch {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "fullOnce \(terminal)：恢复限充写失败（\(error)）"
            ))
        }
    }

    /// 保活校验（规格 §1.1 tick 行）：v1.5 UD-5 热守卫收编——三分支热判定
    /// （决策纯函数 `ThermalGuard.keepAliveDecision`，CellarCoreCheck 矩阵同源钉死；
    /// 本方法只做副作用）：
    /// - temp ≥ pause：CHTE 现态**非停充才写**停充（避免同值重写——写伴随 info
    ///   日志一次，即状态转移日志；已停充则驻留免写免日志，防每 tick 刷屏）；
    /// - temp ∈ [resume, pause)：hold **不重写**（滞回带驻留；含不修复外部改写
    ///   ——动作活跃期无常规 enforce，窗口至 temp < resume 或动作终态，R-3。
    ///   驻留期零日志：暂停写/恢复写已各在转移分支伴随记录，按现态再记必然每
    ///   tick 重复，正是防刷屏要消除的形态）；
    /// - temp < resume：既有重写使能（现态使能则免写免日志）。
    /// lastAction 保持动作相位字面量不动（不标 tempPause——显示面维持现状，UD-5）。
    func keepAliveChargingLocked(
        backend: any ChargingBackend,
        temperatureC: Double,
        events: inout [LogEvent]
    ) {
        let enabled: Bool
        do {
            enabled = try backend.chargingEnabled()
        } catch {
            noteControlFailureLocked(error, events: &events, context: "保活回读")
            return
        }
        switch ThermalGuard.keepAliveDecision(
            temperatureC: temperatureC,
            policy: policy.thermal ?? .default
        ) {
        case .pauseCharging:
            guard enabled else { return }
            do {
                _ = try controller.perform(.disableCharging, backend: backend)
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "充电因温度暂停（fullOnce/校准 chargeFull 保活，写 CHTE 停充 + 回读校验通过）"
                ))
            } catch {
                noteControlFailureLocked(error, events: &events, context: "保活热暂停写")
            }
        case .hold:
            // 滞回带驻留：不重写（R-3）。无转移、无日志（防刷屏）。
            break
        case .keepAlive:
            guard !enabled else { return }
            do {
                _ = try controller.perform(.enableCharging, backend: backend)
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "保活：CHTE 非使能（外部改写/热暂停恢复），已重写使能"
                ))
            } catch {
                noteControlFailureLocked(error, events: &events, context: "保活重写")
            }
        }
    }

    /// 终态/取消后删 action.json（失败仅记日志——残留文件由下次启动崩溃恢复路径兜底）。
    func deleteActionFileLocked(events: inout [LogEvent]) {
        do {
            try actionStore.delete()
        } catch {
            events.append(LogEvent(
                category: .lifecycle, level: .error,
                message: "action.json 删除失败：\(error)（启动崩溃恢复会兜底）"
            ))
        }
    }
}