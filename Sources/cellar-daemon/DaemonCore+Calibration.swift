import Foundation
import CellarCore

// MARK: - WP3 校准动作（方案 §2.2；全部锁内）

/// 校准动作的 daemon 侧实现（扩展文件拆分——DaemonCore.swift 触及 800 行硬上限；
/// 可见性/属主不变量与 DaemonCore+OneShot.swift 同款：cellar-daemon 为 executable
/// target，internal 符号模块外不可达）。语义决策全部经 CellarCore.Calibration /
/// OneShotTrack 转移（CellarCoreCheck 矩阵穷举钉死），本扩展只做副作用（落盘/
/// 写 CHTE/写 CHIE、删文件、终态字面量落状态）与日志。
extension DaemonCore {
    /// startCalibration 锁内启动结果（照 DischargeStartOutcome 先例：仅 .started 才接管）。
    enum CalibrationStartOutcome {
        case started, alreadyActive
    }

    /// startCalibration XPC 臂（v1.4 拆分定版 UD-6）：取锁 → Locked 核（.manual，
    /// snapshot 传 nil → 核内走现序列自带新鲜快照+回落）→ **仅 .started 才即时
    /// tick**（首拍保活使能——现状语义零变化）→ buildStatusLocked。⚠️ NSLock 不可
    /// 重入：本臂取锁后调 Locked 版；tick 调度臂（已持锁）直调 Locked 版——两入口
    /// 共用同一副作用序列。
    func startCalibration() throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }
        let outcome = try startCalibrationLocked(initiator: .manual, snapshot: nil, events: &events)
        if outcome == .started {
            // 即时 tick：首 tick 保活使能 + 首样本（lastStatus 不冻结，P1-2 同判例）。
            performTickLocked(events: &events)
        }
        return buildStatusLocked()
    }

    /// startCalibration 锁内核心（v1.4 UD-6 提取，现有锁内序列原样搬移；**绝不自取
    /// lock**——调用方必须已持锁，工单提示 1）：幂等拆分（在轨且 kind==calibration →
    /// .alreadyActive；在轨且 kind≠calibration → **上抛 .actionOccupied**——防 App
    /// 误弹「校准已启动」假成功）→ 能力守卫（XPC 纵深防御）→ 前置快照 +
    /// calibrationStartPrecondition → startIfIdle + setCalibrationPhase(.chargeFull)
    /// → actionStore.save（失败 → cancel + 上抛 persistenceFailed，锚点不写）→
    /// **记锚点 state.lastStartedAt**（UD-4：启动即记——手动+自动统一刷新；前置
    /// 不满足不写锚点——当日窗口内顺延重试）。单一 now 纪律（工单提示 2）：一次
    /// `Date()` 贯穿 startIfIdle/setCalibrationPhase/锚点——保证 `action.startedAt ==
    /// state.lastStartedAt`（①② 记录与 ③ 去重键跨路径不得有微秒级偏移，否则去重失效）。
    @discardableResult
    func startCalibrationLocked(
        initiator: Initiator, snapshot: BatterySnapshot?, events: inout [LogEvent]
    ) throws -> CalibrationStartOutcome {
        if actionTrack.isActive {
            if actionTrack.action?.kind == Calibration.kind {
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "startCalibration 重复请求：校准已在进行中，回当前状态（幂等）"
                ))
                return .alreadyActive
            }
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "startCalibration 拒绝：其他动作进行中（actionOccupied——先完成或取消）"
            ))
            throw CalibrationStartRejection.actionOccupied
        }
        guard capabilities?.contains(DaemonXPC.capabilityCalibration) == true else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "startCalibration 拒绝：能力缺失（capabilityUnavailable——App 已按能力隐藏）"
            ))
            throw CalibrationStartRejection.capabilityUnavailable
        }
        // 前置外接判定（R2 P3 snapshot 注入）：调度臂传本拍快照（免重复拍电池）；
        // XPC 臂传 nil → 现序列新鲜快照；失败回落上次已知值；均未知 → 拒绝（不无据启动）。
        let external: Bool?
        if let snapshot {
            external = snapshot.externalConnected
        } else {
            do {
                external = try monitor.snapshot().externalConnected
            } catch {
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "startCalibration 前置：电池快照失败（\(error)），使用上次已知外接状态"
                ))
                external = lastStatus?.lastExternalConnected
            }
        }
        if let rejection = calibrationStartPrecondition(
            mode: policy.mode,
            externalConnected: external,
            actionActive: false,       // 本点已在幂等拆分放行（动作轨空闲）
            capabilityPresent: true    // 已由能力守卫拦截（XPC 纵深防御）
        ) {
            throw rejection
        }
        let now = Date()
        _ = actionTrack.startIfIdle(now: now, kind: Calibration.kind, timeout: Calibration.totalDeadline)
        // 相位字段注入（startIfIdle 经 OneShot.onshotStart 构造，无相位概念；
        // deadline = now+24h 整体兜底——hold 相 24h 兜底判据，相位决策不用）。
        actionTrack.setCalibrationPhase(.chargeFull, startedAt: now)
        // idle→active 原子持久化：写失败 → 动作不启动（上抛，App 原文上屏）。
        do {
            try actionStore.save(actionTrack.action!)
        } catch {
            _ = actionTrack.cancel()
            events.append(LogEvent(
                category: .control, level: .error,
                message: "startCalibration 启动失败：action.json 写入失败（\(error)）"
            ))
            throw CalibrationStartRejection.persistenceFailed
        }
        // 启动锚点（与 startIfIdle 同一 now——单一 now 纪律；UD-4）。
        calibrationState.lastStartedAt = Int(now.timeIntervalSince1970)
        persistCalibrationStateLocked(events: &events)
        events.append(LogEvent(
            category: .control, level: .info,
            message: "校准已启动（\(initiator == .manual ? "手动" : "自动调度")）：phase=chargeFull（充满 ≤6h → 静置 2h → 放电至 10%）"
        ))
        return .started
    }

    /// cancelCalibration XPC：用户取消（独立命令臂走鉴权门；实际副作用经
    /// cancelActionLocked 校准第三分支——kind 泛化统一取消路径全覆盖）。
    func cancelCalibration() throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }

        if !actionTrack.isActive {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "取消校准：无活跃动作（幂等成功）"
            ))
            return buildStatusLocked()
        }
        // code-review P1-2：在轨动作非校准（fullOnce/放电）→ 幂等回状态，不取消
        // 他人动作——与 startCalibration 的 .actionOccupied 拆分对称（CLI 路径
        // `cellar calibrate cancel` 真实可达；App 取消按钮仅校准活跃时渲染）。
        if actionTrack.action?.kind != Calibration.kind {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "取消校准：在轨动作非校准（\(actionTrack.action?.kind ?? "?")），不取消（幂等成功）"
            ))
            return buildStatusLocked()
        }
        cancelActionLocked(events: &events)
        return buildStatusLocked()
    }

    /// 校准维护分支（performTickLocked 第 5 步校准分支；方案 §2.2）：CHIE 保活
    /// 读改写（放电相）→ 转移纯函数 → 依输出执行副作用。返回本 tick 的 lastAction
    /// 字面量（相位字面量不锁存——持续态字面量每 tick 返回当前相位；相位转移通知
    /// 经 App 端 notificationEvents 转移检测）。
    func maintainCalibrationLocked(
        now: Date,
        snapshot: BatterySnapshot,
        backend: any ChargingBackend,
        events: inout [LogEvent]
    ) -> String {
        guard let action = actionTrack.action else { return "enforce:noop" }
        let phase = action.phase.flatMap(Calibration.Phase.init(rawValue:))

        // CHIE 保活读改写（仅 discharge 相；语义 = maintainDischargeLocked 同款）：
        // 回读 == 0x08 → held；≠0x8（含 0x00 重置/未知值）→ 重写 0x8 后回读；
        // 任何失败 → failed（连续 3 次由转移函数 abort）。
        let chieStatus: DischargeKeepAliveStatus?
        if phase == .discharge {
            do {
                let enabled = try backend.adapterEnabled()
                switch enabled {
                case false:
                    chieStatus = .held
                case true, nil:
                    do {
                        try backend.setAdapterEnabled(false)
                        let rechecked = try backend.adapterEnabled()
                        chieStatus = rechecked == false ? .rewritten : .failed
                    } catch {
                        noteControlFailureLocked(error, events: &events, context: "校准 CHIE 保活重写")
                        chieStatus = .failed
                    }
                }
            } catch {
                noteControlFailureLocked(error, events: &events, context: "校准 CHIE 保活回读")
                chieStatus = .failed
            }
        } else {
            chieStatus = nil
        }

        let result = calibrationTick(CalibrationTickInput(
            percent: snapshot.percent,
            temperatureC: snapshot.temperatureC,
            externalConnected: snapshot.externalConnected,
            isCharging: snapshot.isCharging,
            fullyCharged: snapshot.fullyCharged,
            now: now,
            phase: phase,
            phaseStartedAt: action.phaseStartedAt,
            deadline: action.deadline,
            debounceTicks: actionTrack.debounceTicks,
            keepAliveFailures: actionTrack.keepAliveFailures,
            chieStatus: chieStatus
        ))
        // 计数器回写（转移纯函数不持有状态；结果经轨道方法落回——单一属主不变量）。
        actionTrack.applyCalibrationCounters(
            debounceTicks: result.debounceTicks, keepAliveFailures: result.keepAliveFailures
        )

        switch result.output {
        case .stay(let phase):
            // 保活副作用按相位：chargeFull → CHTE 保活使能；hold → 写停充（回读
            // 非停充才写——满电停充维持）；discharge → CHIE 保活写 0x8（已由上方
            // 读改写完成，此处避免双重写）。
            switch phase {
            case .chargeFull:
                // v1.5 UD-5：chargeFull 相保活同入热守卫（盲区收编——本拍快照
                // 温度穿透，三分支判定与 fullOnce 保活同源）。
                keepAliveChargingLocked(backend: backend, temperatureC: snapshot.temperatureC, events: &events)
            case .hold:
                holdLimitChargingLocked(backend: backend, events: &events)
            case .discharge:
                break
            }
            return CalibrationLiteral.phase(phase)

        case .advance(let to):
            // 相位推进（四步副作用次序见 advanceCalibrationLocked；失败臂内存
            // 相位不推进 → 本 tick 返回当前相位字面量，下 tick 幂等重试全序列）。
            _ = advanceCalibrationLocked(to: to, now: now, backend: backend, events: &events)
            let current = actionTrack.action?.phase.flatMap(Calibration.Phase.init(rawValue:))
                ?? phase ?? .chargeFull
            return CalibrationLiteral.phase(current)

        case .restoreAndComplete:
            // RESTORE：CHIE 恢复（重试阶梯）→ enforce 恢复限充语义（审查 M2 同判
            // 例——通知说恢复即现状收敛）→ done 字面量锁存 + 删文件。
            restoreCalibrationCHIELocked(backend: backend, terminal: "完成", events: &events)
            enforceLimitChargingLocked(backend: backend, temperatureC: snapshot.temperatureC, events: &events)
            let literal = actionTrack.terminateCalibration(CalibrationLiteral.done())
            deleteActionFileLocked(events: &events)
            return literal

        case .abort(let reason, let safety):
            // 中止：曾入 discharge 相（CHIE=0x8 在场）→ CHIE 恢复（重试阶梯）；
            // enforce 恢复限充语义 → safety ? calibration:safety 锁存 : 按原因落
            // timeout/cancel 字面量 + 删文件。
            if phase == .discharge {
                restoreCalibrationCHIELocked(backend: backend, terminal: "中止(\(reason))", events: &events)
            }
            enforceLimitChargingLocked(backend: backend, temperatureC: snapshot.temperatureC, events: &events)
            let literal: String
            if safety {
                literal = CalibrationLiteral.safety()
            } else if reason == CalibrationLiteral.AbortReason.timeout {
                literal = CalibrationLiteral.timeout()
            } else {
                literal = CalibrationLiteral.cancel()
            }
            let latched = actionTrack.terminateCalibration(literal)
            deleteActionFileLocked(events: &events)
            return latched
        }
    }

    /// 相位推进副作用（方案 §2.2 次序钉死，失败臂按臂注记）：
    /// ① `actionStore.save`（phase/phaseStartedAt 落盘——崩溃恢复按相位恢复 CHIE
    ///    的精确性前提；失败记 error **继续**，内存态推进，残留交启动崩溃恢复兜底）；
    /// ② 仅 hold→discharge：先 `controller.perform(.enableCharging)` 撤停充——失败臂
    ///    **钉死（R2 P2-1）**：本 tick **不写 CHIE、内存相位不推进**（维持 hold 语义）、
    ///    记 error + `noteControlFailureLocked` 自愈；推进条件持续成立 → 下 tick 幂等
    ///    重试全序列（save 覆盖写）；「盘上 discharge / 内存 hold」窗口由重试或崩溃
    ///    恢复收口（恢复按 discharge 多余恢复一次 CHIE，fail-closed 无害）。**严禁
    ///    ② 失败继续 ③**——「CHTE=停充 × CHIE=0x8」未测胞照样进入即挫败本序目的；
    /// ③ 仅 hold→discharge：写 CHIE=0x8 + 回读（对齐 dischargeToLimitLocked 启动
    ///    序列；失败 → 记 error，相位同样不推进——CHIE 写入态未知，下 tick 重试全序列）；
    /// ④ 更新轨道 action 字段（内存相位推进）。
    /// 返回是否推进成功（调用方据此输出当前相位字面量）。
    @discardableResult
    private func advanceCalibrationLocked(
        to: Calibration.Phase, now: Date, backend: any ChargingBackend, events: inout [LogEvent]
    ) -> Bool {
        // ① 落盘（先更新内存字段再 save——save 的内容 = 推进后的相位/相位起始）。
        var pending = actionTrack.action
        pending?.phase = to.rawValue
        pending?.phaseStartedAt = now
        do {
            if let pending { try actionStore.save(pending) }
        } catch {
            events.append(LogEvent(
                category: .lifecycle, level: .error,
                message: "校准相位推进：action.json 写入失败（\(error)）——内存态继续推进（崩溃恢复兜底）"
            ))
        }
        if to == .discharge {
            // ② 撤停充（hold→discharge 前置——CHTE=0 放行充电与 CHIE=0x8 之间无
            // 未测胞窗口：撤停充成功才写 CHIE）。
            do {
                _ = try controller.perform(.enableCharging, backend: backend)
            } catch {
                noteControlFailureLocked(error, events: &events, context: "校准推进撤停充")
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "校准相位推进：撤停充失败——本 tick 不写 CHIE、相位不推进（维持 hold，下 tick 幂等重试全序列）"
                ))
                return false
            }
            // ③ CHIE=0x8 写 + 回读校验。
            do {
                try backend.setAdapterEnabled(false)
                let state = try backend.adapterEnabled()
                guard state == false else {
                    throw BackendError.verifyFailed(key: "CHIE", desired: false, actual: state ?? true)
                }
            } catch {
                noteControlFailureLocked(error, events: &events, context: "校准推进 CHIE 写")
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "校准相位推进：CHIE=0x08 写入/回读校验失败（\(error)）——相位不推进（下 tick 重试，残留交 §2.4 巡检）"
                ))
                return false
            }
        }
        // ④ 内存相位推进。
        actionTrack.setCalibrationPhase(to, startedAt: now)
        events.append(LogEvent(
            category: .control, level: .info,
            message: "校准相位推进：→ \(to.rawValue)（\(now.description)）"
        ))
        return true
    }

    /// hold 相保活停充（写 CHTE 停充——回读非停充才写；失败走自愈计数，下 tick 重试）。
    private func holdLimitChargingLocked(backend: any ChargingBackend, events: inout [LogEvent]) {
        let enabled: Bool
        do {
            enabled = try backend.chargingEnabled()
        } catch {
            noteControlFailureLocked(error, events: &events, context: "校准 hold 保活回读")
            return
        }
        guard enabled else { return }
        do {
            _ = try controller.perform(.disableCharging, backend: backend)
            events.append(LogEvent(
                category: .control, level: .info,
                message: "校准 hold 相：满电停充维持（写 CHTE 停充 + 回读校验通过）"
            ))
        } catch {
            noteControlFailureLocked(error, events: &events, context: "校准 hold 保活停充")
        }
    }

    /// 校准终态/取消恢复 CHIE=0x0（写 + 回读校验重试阶梯——写失败 ≠ 恢复完成，
    /// 红线 5：失败告警后终态照常落盘，残留交 §2.4 CHIE 残留不变量兜底）。
    /// internal：cancelActionLocked（DaemonCore+OneShot.swift）跨文件调用。
    func restoreCalibrationCHIELocked(
        backend: any ChargingBackend, terminal: String, events: inout [LogEvent]
    ) {
        let restoreError = DischargeAdapterControl.restoreEnabled(
            backend: backend, attempts: Discharge.terminalRestoreAttempts
        )
        if let restoreError {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "校准 \(terminal)：CHIE 恢复写失败（\(restoreError)——重试阶梯耗尽），残留交 §2.4 残留不变量巡检"
            ))
        } else {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "校准 \(terminal)：已恢复适配器使能（CHIE=0x00，回读校验通过）"
            ))
        }
    }

    /// 崩溃恢复专用（DaemonCore.startup）：校准动作残留按相位恢复 CHIE——discharge
    /// 相（CHIE=0x8 可能在场）必须恢复；相位缺失/未知串 → **无条件恢复（fail-closed，
    /// 一次多余 SMC 写无害，R1 P2-3）**；chargeFull/hold 相无需恢复。通知经
    /// adoptForCrashRecovery 的 cancel(crash-recovery) 锁存字面量由 App 轮询转移补发。
    func restoreCalibrationAfterCrashLocked(_ pending: OneShotAction, events: inout [LogEvent]) {
        let phase = pending.phase.flatMap(Calibration.Phase.init(rawValue:))
        guard (phase == .discharge || phase == nil), let backend, backend.adapterControlSupported else {
            return
        }
        let restoreError = DischargeAdapterControl.restoreEnabled(
            backend: backend, attempts: Discharge.terminalRestoreAttempts
        )
        if let restoreError {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "崩溃恢复：校准动作残留，CHIE 恢复失败（\(restoreError)）——残留交 §2.4 不变量"
            ))
        } else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "崩溃恢复：校准动作残留（phase=\(pending.phase ?? "未知")），已恢复 CHIE=0x00"
            ))
        }
    }
}