import Foundation
import CellarCore

// MARK: - WP2' dischargeToLimit（放电到上限，方案 §2 全部）

/// WP2' 放电动作的 daemon 侧实现（扩展文件拆分——DaemonCore.swift 触及 800 行
/// 硬上限；可见性/属主不变量与 DaemonCore+OneShot.swift 同款：cellar-daemon 为
/// executable target，internal 符号模块外不可达）。
///
/// 语义决策全部经 CellarCore.Discharge / OneShotTrack（锁内单实例）转移，本扩展
/// 只做副作用（写 CHTE/CHIE、删文件、终态字面量落状态）与日志——判定链经
/// CellarCoreCheck 矩阵穷举钉死，daemon 运行时与测试同源。
extension DaemonCore {
    /// dischargeToLimit XPC（方案 §2.3 启动序列）：
    /// 门控（mode/ext/percent>目标/无在轨动作/能力）→ **先写 CHTE=00000000
    /// （enforce 撤停充，§1.1 E6 未测胞消除）→ 再写 CHIE=0x8 → 回读校验** →
    /// ActionState 落盘 → 即时 tick 切动作模式。
    ///
    /// 失败路径（不静默，红线 5）：
    /// - CHTE/CHIE 写失败 → 上抛原文 + 告警，**不进入动作态**（CHTE 已被写 0 →
    ///   立即走常规 enforce 恢复）；
    /// - action.json 写失败 → **立即写 CHIE=0x0 恢复 + 上抛**（评审轮 2 注记 2）。
    func dischargeToLimit() throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }

        // 幂等：动作已在轨（任意类型）→ 回当前状态（非错误——App 按钮随状态消失）。
        if actionTrack.isActive {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "dischargeToLimit 重复请求：动作已在进行中，回当前状态（幂等）"
            ))
            return buildStatusLocked()
        }
        // 能力纵深防御（App 已按 capabilities 隐藏按钮；XPC 侧独立核验，评审 P1-1
        // fail-closed）：Legacy 后端/CHIE 缺席/探测失败 → 拒绝。
        guard let backend, backend.adapterControlSupported else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "dischargeToLimit 拒绝：后端不支持适配器控制（capabilityUnavailable）"
            ))
            throw DischargeStartRejection.capabilityUnavailable
        }
        // 前置快照（新鲜优先；失败回落上次已知值；均未知 → 前置拒绝，不无据启动）。
        let snapshot: BatterySnapshot?
        do {
            snapshot = try monitor.snapshot()
        } catch {
            snapshot = nil
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "dischargeToLimit 前置：电池快照失败（\(error)），使用上次已知外接状态"
            ))
        }
        let target = policy.upperLimit
        let percent = snapshot?.percent ?? lastStatus?.lastPercent
        let external = snapshot?.externalConnected ?? lastStatus?.lastExternalConnected
        if let rejection = Discharge.startPrecondition(
            mode: policy.mode,
            externalConnected: external,
            percent: percent,
            targetPercent: target
        ) {
            throw rejection
        }

        // 启动序列：先 CHTE=00000000（撤停充——把未测胞 CHTE=停充×CHIE=0x8 从状态
        // 空间消除，评审 P1-2；恢复端由 enforce 收敛）→ 再写 CHIE=0x8 → 回读校验。
        do {
            _ = try controller.perform(.enableCharging, backend: backend)
        } catch {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "dischargeToLimit 启动：CHTE 撤停充失败（\(error)），不进入动作态"
            ))
            throw error
        }
        do {
            try backend.setAdapterEnabled(false)
            let state = try backend.adapterEnabled()
            guard state == false else {
                throw BackendError.verifyFailed(key: "CHIE", desired: false, actual: state ?? true)
            }
        } catch {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "dischargeToLimit 启动：CHIE=0x08 写入/回读校验失败（\(error)）——不进入动作态，CHTE 走常规 enforce 恢复"
            ))
            // 此路径 CHTE 已被写 0 且未进入动作态：立即常规 enforce 收敛（§1.1）。
            performTickLocked(events: &events)
            throw error
        }

        // ActionState 落盘：写失败 → **立即恢复 CHIE=0x0** + 上抛（不留下半启动态）。
        // ⚠️ timeout 必须显式传 discharge 2h 窗口（startIfIdle 默认是 fullOnce 的 4h——
        // 各动作族超时窗口不得混用，§2.3 超时终止语义按 2h 算术注记）。
        _ = actionTrack.startIfIdle(
            now: Date(),
            kind: Discharge.dischargeToLimitKind,
            targetPercent: target,
            timeout: Discharge.dischargeTimeout
        )
        do {
            try actionStore.save(actionTrack.action!)
        } catch {
            let restoreError = DischargeAdapterControl.restoreEnabled(
                backend: backend, attempts: Discharge.terminalRestoreAttempts
            )
            if let restoreError {
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "dischargeToLimit 启动回滚：CHIE 恢复失败（\(restoreError)）——残留交 §2.4 残留不变量兜底"
                ))
            }
            _ = actionTrack.cancel()
            events.append(LogEvent(
                category: .control, level: .error,
                message: "dischargeToLimit 启动失败：action.json 写入失败（\(error)）"
            ))
            // 审查 M2：回滚后立即常规 enforce 收敛 CHTE（本路径已写 CHTE=0 放行
            // 充电，动作又未在轨——不等下 tick 30s，直接收敛「恢复限充」语义）。
            performTickLocked(events: &events)
            throw DischargeStartRejection.persistenceFailed
        }
        events.append(LogEvent(
            category: .control, level: .info,
            message: "dischargeToLimit 已启动：目标 \(target)%（2 小时超时）"
        ))
        // 即时 tick：CHIE 保活 + 首样本（lastStatus 不冻结，P1-2）。
        performTickLocked(events: &events)
        return buildStatusLocked()
    }

    /// 放电动作维护分支（performTickLocked 第 5 步放电分支；方案 §2.3 判定次序在
    /// CellarCore 轨道转移，本方法仅做 CHIE 保活读改写 + 副作用执行）：
    /// 返回本 tick 的 lastAction 字面量。
    func maintainDischargeLocked(
        now: Date,
        snapshot: BatterySnapshot,
        backend: any ChargingBackend,
        events: inout [LogEvent]
    ) -> String {
        // ① CHIE 保活（tick 判定链输入；轨道的保活失败计数经本结果推进）：
        // 回读 == 0x08 → held；≠0x8（含 0x00 重置/未知值）→ 重写 0x8 后回读；
        // 任何失败 → failed（连续 3 次由轨道取消）。
        let chieStatus: DischargeKeepAliveStatus
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
                    noteControlFailureLocked(error, events: &events, context: "CHIE 保活重写")
                    chieStatus = .failed
                }
            }
        } catch {
            noteControlFailureLocked(error, events: &events, context: "CHIE 保活回读")
            chieStatus = .failed
        }

        let outcome = actionTrack.tickDischarge(
            now: now,
            percent: snapshot.percent,
            temperatureC: snapshot.temperatureC,
            externalConnected: snapshot.externalConnected,
            chieStatus: chieStatus,
            monitoringAvailable: true
        )

        switch outcome {
        case .completed, .timedOut, .safetyTerminated:
            let terminal: String
            switch outcome {
            case .completed: terminal = "完成"
            case .timedOut: terminal = "超时"
            case .safetyTerminated(let reason): terminal = "安全终止(\(reason))"
            default: terminal = "终态"
            }
            restoreDischargeAdapterLocked(backend: backend, terminal: terminal, events: &events)
            // 审查 M2：终态必须**即时** enforce CHTE——启动序列曾写 CHTE=0 放行充电，
            // 若只恢复 CHIE，通知说「限充已恢复」但最长 30s 存在无约束充电
            // （enforce 收敛前电池直接充到上限）。floor=60 案 percent<resume →
            // enableCharging 无害（CHTE 本就是 0）。
            enforceLimitChargingLocked(backend: backend, events: &events)
            deleteActionFileLocked(events: &events)
            return actionTrack.latchedLiteral ?? fallbackLiteral(for: outcome)
        case .cancelled(let reason, let literal):
            // 统一取消：恢复 CHIE（重试阶梯 + 告警）→ enforce CHTE（恢复限充语义）。
            restoreDischargeAdapterLocked(backend: backend, terminal: "取消(\(reason))", events: &events)
            enforceLimitChargingLocked(backend: backend, events: &events)
            deleteActionFileLocked(events: &events)
            return literal
        case .keepAlive:
            let literal = OneShotLiteral.start(kind: Discharge.dischargeToLimitKind)
            return actionTrack.effectiveLastAction(literal) ?? literal
        case .idle:
            // 防御分支：维护分支仅在轨道活跃时进入，轨道空载不可达。
            return "enforce:noop"
        }
    }

    /// 终态字面量回退（latchedLiteral 理论恒有值——防御分支同 fullOnce 模式）。
    private func fallbackLiteral(for outcome: DischargeTickOutcome) -> String {
        let kind = Discharge.dischargeToLimitKind
        switch outcome {
        case .completed: return OneShotLiteral.done(kind: kind)
        case .timedOut: return OneShotLiteral.timeout(kind: kind)
        case .safetyTerminated: return OneShotLiteral.safety(kind: kind)
        default: return OneShotLiteral.cancel(kind: kind)
        }
    }

    /// 终态/取消恢复 CHIE=0x0（写 + 回读校验重试阶梯 —— 取消写失败 ≠ 取消完成，
    /// 红线 5：失败告警后终态照常落盘，残留交 §2.4 CHIE 残留不变量兜底）。
    private func restoreDischargeAdapterLocked(
        backend: any ChargingBackend,
        terminal: String,
        events: inout [LogEvent]
    ) {
        let restoreError = DischargeAdapterControl.restoreEnabled(
            backend: backend, attempts: Discharge.terminalRestoreAttempts
        )
        if let restoreError {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "discharge \(terminal)：CHIE 恢复写失败（\(restoreError)——重试阶梯耗尽），残留交 §2.4 残留不变量巡检"
            ))
        } else {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "discharge \(terminal)：已恢复适配器使能（CHIE=0x00，回读校验通过）"
            ))
        }
    }

    /// 终态/取消后恢复限充语义（「enforce CHTE」，审查 M2 扩展至完成/超时/安全终止）：
/// 数据源 = 最近成功采样（lastStatus，≤30s 陈旧可接受——决策规则与常规 enforce
/// 相同，下 tick 全量重估兜底）；external 恒 true（CHIE=0x00 已确认写入 →
/// 适配器恢复）。失败仅记日志（enforce 常规分支本就会重试）。
    func enforceLimitChargingLocked(backend: any ChargingBackend, events: inout [LogEvent]) {
        guard let percent = lastStatus?.lastPercent else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "放电终态/取消：无采样电量，enforce CHTE 延后至下一常规 tick"
            ))
            return
        }
        do {
            let chargingEnabled = try backend.chargingEnabled()
            let context = ChargingContext(
                percent: percent,
                externalConnected: true,   // CHIE=0x00 回读已确认（恢复方校验过）
                chargingEnabled: chargingEnabled
            )
            _ = try controller.enforce(context: context, backend: backend)
            events.append(LogEvent(
                category: .control, level: .info,
                message: "放电终态/取消：已按当前策略恢复限充（percent=\(percent)% enforce 收敛）"
            ))
        } catch {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "放电终态/取消：enforce CHTE 失败（\(error)）（下 tick 常规 enforce 兜底）"
            ))
        }
    }

    /// §2.4 CHIE 残留不变量巡检（**安全红线**）：无动作活跃期的常规 tick 巡检——
    /// 回读 ≠ 0x00 → 写 0x00 + 回读校验 + 告警（lastAction = `dischargeToLimit:safety`，
    /// App 通知通道）+ 走既有自愈计数。不变式：**CHIE=0x8 仅允许在放电动作活跃期
    /// 存在**——本巡检覆盖全部「动作已终态但恢复写失败/重试耗尽」的泄漏路径。
    /// 返回命中时的 safety 字面量（调用方覆写本 tick lastAction）；未命中 → nil。
    ///
    /// 门控（审查 M1）：**必须用探测结果 capabilities**（tahoe ∧ CHIE 在位），
    /// 不得用 `adapterControlSupported`（TahoeBackend 硬编码 true）——CHTE 在位但
    /// CHIE 缺席的 Tahoe 机器若按 supported 门控会陷入「巡检读失败 → 自愈计数 →
    /// 90s 重建」的永久失败循环。capabilities 含 discharge 的机器 CHIE 必在位。
    @discardableResult
    func patrolCHIEResidualLocked(
        backend: any ChargingBackend,
        events: inout [LogEvent]
    ) -> String? {
        guard capabilities?.contains(DaemonXPC.capabilityDischarge) == true else { return nil }
        let enabled: Bool?
        do {
            enabled = try backend.adapterEnabled()
        } catch {
            noteControlFailureLocked(error, events: &events, context: "CHIE 残留巡检回读")
            return nil
        }
        guard Discharge.residualPatrolNeeded(enabled: enabled) else { return nil }
        // 巡检命中：写 0x00 + 回读校验（每次 tick 一次尝试——30s 节奏，连续命中
        // 由 App 侧「同字面量不重复通知」收敛）。
        let restoreError = DischargeAdapterControl.restoreEnabled(backend: backend, attempts: 1)
        if let restoreError {
            noteControlFailureLocked(restoreError, events: &events, context: "CHIE 残留巡检恢复")
            events.append(LogEvent(
                category: .control, level: .error,
                message: "CHIE 残留巡检：恢复写失败（\(restoreError)）——残留禁用未清除，继续巡检"
            ))
        } else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "CHIE 残留巡检：检测到非使能状态，已清零并回读确认（放电残留恢复）"
            ))
        }
        return OneShotLiteral.safety(kind: Discharge.dischargeToLimitKind)
    }

    /// 监护缺失计数（评审 P1-5）：backend/采样/控制键读取早退 × 放电动作活跃 →
    /// 连续 ≥3 tick（90s）→ 安全终止 + 告警（恢复尽力；失败交 §2.4 不变量）。
    /// performTickLocked 步骤 1/2/3 早退路径调用。
    func noteDischargeMonitoringLossLocked(events: inout [LogEvent]) {
        guard actionTrack.action?.kind == Discharge.dischargeToLimitKind else { return }
        guard actionTrack.noteMonitoringLoss() else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "放电动作监护缺失（连续第 \(actionTrack.monitoringLossTicks) tick，≤\(Discharge.monitoringLossLimit) 不终止）"
            ))
            return
        }
        guard let literal = actionTrack.terminateMonitoringLoss() else { return }
        if let backend, backend.adapterControlSupported {
            let restoreError = DischargeAdapterControl.restoreEnabled(
                backend: backend, attempts: Discharge.terminalRestoreAttempts
            )
            if let restoreError {
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "放电动作监护缺失终止：CHIE 恢复失败（\(restoreError)），残留交 §2.4 不变量"
                ))
            }
        } else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "放电动作监护缺失终止：无控制后端，CHIE 恢复不可执行（残留交 §2.4 不变量）"
            ))
        }
        lastStatus?.lastAction = literal
        deleteActionFileLocked(events: &events)
        events.append(LogEvent(
            category: .control, level: .warn,
            message: "放电动作监护缺失 ≥\(Discharge.monitoringLossLimit) tick：已安全终止（\(literal)）"
        ))
    }

    /// sleepNow 专用放电取消（硬事实 5）：同步路径内恢复 CHIE 立即尝试 1 次
    /// （总尝试数 1 = 零重试；不阻塞 IOAllowPowerChange），余量交 §2.4 残留不变量
    /// 与唤醒兜底；不 enforce CHTE——睡眠策略随后照常自行判定。
    /// 审查 M3：daemon 发起的取消一律**锁存** cancel 字面量——App 轮询必见终态、
    /// 通知必发（不锁存会被下一常规 tick 的 enforce:xxx 覆盖，60s 轮询档漏发）。
    func cancelDischargeForSleepLocked(events: inout [LogEvent]) {
        guard actionTrack.action?.kind == Discharge.dischargeToLimitKind else { return }
        let literal = actionTrack.cancelLatched() ?? OneShotLiteral.cancel(kind: Discharge.dischargeToLimitKind)
        if let backend, backend.adapterControlSupported {
            let restoreError = DischargeAdapterControl.restoreEnabled(
                backend: backend, attempts: Discharge.sleepNowRestoreAttempts
            )
            if let restoreError {
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "睡眠取消放电：CHIE 恢复失败（\(restoreError)）——残留交 §2.4 残留不变量与唤醒兜底"
                ))
            } else {
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "睡眠取消放电：已恢复适配器使能（CHIE=0x00）"
                ))
            }
        } else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "睡眠取消放电：无控制后端，CHIE 恢复不可执行"
            ))
        }
        lastStatus?.lastAction = literal
        deleteActionFileLocked(events: &events)
    }
}