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
    /// fullOnce XPC（前置 + 幂等三分支，规格 §1.1/§2.2）：
    /// - 前置拒绝：mode != active / 未外接 / 外接未知 → 上抛 daemonError 原文；
    /// - 幂等一：动作已在轨 → **回当前状态**（非错误——App 按钮随状态消失）；
    /// - 已满电 → 接受，动作启动后首个 tick 即进入完成判定路径（2 tick 去抖照常）。
    func fullOnce() throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }

        if actionTrack.isActive {
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
        if let rejection = fullOnceStartPrecondition(mode: policy.mode, externalConnected: external) {
            throw rejection
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
    func cancelActionLocked(events: inout [LogEvent], latchCancelled: Bool = false) {
        // kind 预取：cancel 会清空动作，分流判断必须在取消之前；
        // calibration 相位同理由：第三分支需要 phase 判定 CHIE 恢复。
        let kind = actionTrack.action?.kind
        let calibrationPhase = kind == Calibration.kind
            ? actionTrack.action?.phase.flatMap(Calibration.Phase.init(rawValue:))
            : nil
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
            noteDischargeTerminatedLocked(now: Date())
            // 放电统一取消：恢复 CHIE（重试阶梯）+ enforce CHTE（恢复限充语义）。
            if let backend, backend.adapterControlSupported {
                let restoreError = DischargeAdapterControl.restoreEnabled(
                    backend: backend, attempts: Discharge.terminalRestoreAttempts
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
                    restoreCalibrationCHIELocked(backend: backend, terminal: "取消", events: &events)
                }
                enforceLimitChargingLocked(
                    backend: backend,
                    temperatureC: (try? monitor.snapshot())?.temperatureC,
                    events: &events
                )
            } else {
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "取消校准动作：无控制后端，跳过 CHIE 恢复与 enforce（仅落终态）"
                ))
            }
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
    /// 未完成 → 保活充电。返回本 tick 的 lastAction 字面量。
    func maintainActionLocked(
        now: Date,
        fullyCharged: Bool?,
        isCharging: Bool,
        percent: Int,
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
            keepAliveChargingLocked(backend: backend, events: &events)
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

    /// 保活校验（规格 §1.1 tick 行）：回读 CHTE，非使能 → 重写使能 + 日志 +
    /// 走既有自愈计数（noteControlFailureLocked）——**不触发 conflictSuspected**
    /// （动作期间外部改写由保活纠正，属期望行为；P2 采纳）。
    func keepAliveChargingLocked(backend: any ChargingBackend, events: inout [LogEvent]) {
        let enabled: Bool
        do {
            enabled = try backend.chargingEnabled()
        } catch {
            noteControlFailureLocked(error, events: &events, context: "保活回读")
            return
        }
        guard !enabled else { return }
        do {
            _ = try controller.perform(.enableCharging, backend: backend)
            events.append(LogEvent(
                category: .control, level: .info,
                message: "保活：CHTE 非使能（外部改写），已重写使能"
            ))
        } catch {
            noteControlFailureLocked(error, events: &events, context: "保活重写")
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