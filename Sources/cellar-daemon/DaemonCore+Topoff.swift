import Foundation
import CellarCore

// MARK: - WP2 topoffprotection <80% 限充通道（daemon 侧；方案 §3 全部）
//
// 扩展文件拆分（DaemonCore.swift 800 行纪律；可见性/属主惯例同 DaemonCore+Discharge：
// cellar-daemon 为 executable target，internal 符号模块外不可达）。语义决策全部经
// CellarCore.Topoff（convergenceRoute/channelTick/healTick——CellarCoreCheck 场景域
// 钉死），本扩展只做副作用（域写/通知/簿记/日志）与路由消费。
//
// 平台门控：全部消费点以 capabilities 含 "sub80" 为门（仅 27 终态上报——M1a 矩阵）；
// 26 及更早零触及（26 行为零变化红线）。topoff 同受 mode/actionActive 门（执法总开关），
// 不受编排开关门（§3.1 门语义）。
extension DaemonCore {
    /// 汇聚点双通道路由消费（orchestrationTickLocked 内、applyScheduleTransitionLocked
    /// 之后调用——§3.1 路由挂点）。返回编排断言目标 desired（nil = 编排静默）；
    /// topoff 副作用（域写/验证/重申/降级/自愈/卫生/关断清理）在本方法内完成。
    ///
    /// 次序契约：路由判定（纯函数）→ topoff 副作用 → 返回 desired 给断言链——
    /// 副作用先行不改变断言输入（desired 在纯函数内已定）。
    func topoffConvergenceRouteLocked(
        now: Date, snapshot: BatterySnapshot, events: inout [LogEvent]
    ) -> Int? {
        let sub80Capable = capabilities?.contains(DaemonXPC.capabilitySub80) == true
        // chargingDisabled 在窗判定（§3.1 汇聚目标派生输入——等价「完全放开」窗口）。
        let chargingDisabledWindowActive = scheduleState.lastAppliedEntryId != nil
            && policy.schedule?.entries.first(where: { $0.id == scheduleState.lastAppliedEntryId })?
                .chargingDisabled == true
        let route = Topoff.convergenceRoute(
            modeActive: policy.mode == "active",
            orchestrationEnabled: policy.orchestrationEnabled == true,
            chargingDisabledWindow: chargingDisabledWindowActive,
            upperLimit: policy.upperLimit,
            sub80Capable: sub80Capable,
            actionActive: actionTrack.isActive,
            degraded: topoffState.degraded,
            healProbeActive: topoffState.healProbeActive
        )
        guard sub80Capable else { return route.orchestrationDesired }   // 非 sub80 机：零行为（26 回归锚）
        // §3.7 关断清理状态不变量（P3-3 评审修法——从事件驱动补成状态判定）：
        // mode 非 active ∨（编排开关关断 ∧ 汇聚目标 ≥80）→ 域随写 100 + off（幂等，
        // 守卫允许带 off 重试直至写成功）。覆盖：disable/SIGHUP/退出恢复事件路径、
        // **重启 fresh 角点**（编排关 ∧ ≥80 ∧ topoffState fresh → 首拍清理）、事件
        // 钩子写失败后的逐拍重试——「残留域值不滞留执法」不变量。
        guard let convergenceTarget = route.convergenceTarget,
              !(policy.orchestrationEnabled != true && convergenceTarget >= Topoff.degradedLimit) else {
            topoffShutdownCleanupLocked(now: now, events: &events)
            return route.orchestrationDesired
        }
        if route.topoffOwned {
            // 通道承载（<80）：off 清除（重新承载）→ 单通道互斥簿记 → 状态机推进。
            if topoffState.off { topoffState.off = false }
            discardStaleOrchestrationPendingLocked(events: &events)
            let plan = topoffState.degraded
                ? Topoff.healTick(
                    state: topoffState, target: convergenceTarget, now: now,
                    percent: snapshot.percent,
                    externalConnected: snapshot.externalConnected,
                    isCharging: snapshot.isCharging)
                : Topoff.channelTick(
                    state: topoffState, target: convergenceTarget, now: now,
                    percent: snapshot.percent,
                    externalConnected: snapshot.externalConnected,
                    isCharging: snapshot.isCharging)
            topoffState = plan.state
            if let limit = plan.writeLimit {
                _ = topoffExecuteWriteLocked(limit: limit, now: now, events: &events)
            }
            return route.orchestrationDesired
        }
        // 动作活跃（放电/校准）→ 域写一并静默（维护分支掌权——域值由终态后同拍
        // 汇聚恢复，防动作期无谓写抖动）。
        guard !actionTrack.isActive else { return route.orchestrationDesired }
        // ≥80（含 chargingDisabled 窗 100）：§3.6 域随写卫生——域值同步随写至汇聚
        // 目标（先值后态 + 通知；消除稳态互搏 + ≥80 双保险，含 fresh 首 tick 的
        // 0.19.20 实验期域残留同步）。**可达性 = 编排开关开 ∧ 无动作**（编排关 ∧
        // ≥80 已被上方关断清理状态不变量截收——§3.7 清理写的 100 不会被本分支
        // 复活，防「UI 已停用、域值钉 85」不诚实态）。26 平台无此卫生（sub80 门）。
        if topoffState.off { topoffState.off = false }
        if topoffState.lastWrittenLimit != convergenceTarget {
            _ = topoffExecuteWriteLocked(limit: convergenceTarget, now: now, events: &events)
        }
        return route.orchestrationDesired
    }

    /// 单通道互斥簿记：topoff 承载时撤销在轨编排断言（pending）——防 App 消费陈旧
    /// 断言与 topoff 域值短暂互搏（迟到回报 token 不匹配自然丢弃）。
    private func discardStaleOrchestrationPendingLocked(events: inout [LogEvent]) {
        guard orchestrationState.hasOutstanding else { return }
        orchestrationState.pendingToken = nil
        orchestrationState.pendingTarget = nil
        events.append(LogEvent(
            category: .control, level: .info,
            message: "topoff 通道承载：已撤销在轨编排断言（单通道互斥——陈旧 pending 与域值互搏防护）"
        ))
    }

    /// 域写入执行（TopoffWriter 接线：defaults/notifyutil 子进程；daemon root 上下文）。
    /// 成功 → lastWritten/lastWriteAt 簿记（幂等重写判定输入）+ 失败连计清零（P3-1
    /// 恢复日志）；失败 → 不簿记（下 tick needsWrite 幂等重写）+ **降频日志**（P3-1：
    /// 首条 error、后续合并计数 warn）。返回写入是否成功（P3-2 清理 off 置位条件）。
    @discardableResult
    private func topoffExecuteWriteLocked(
        limit: Int, now: Date, events: inout [LogEvent]
    ) -> Bool {
        let outcome = TopoffWriter.write(limit: limit, run: Self.runProcessCapture) { name in
            Self.runProcessCapture("/usr/bin/notifyutil", ["-p", name]).exitCode == 0
        }
        switch outcome {
        case .written(let notified):
            let recoveryNote = topoffWriteFailureStreak > 0
                ? "（写入恢复——此前连续失败 \(topoffWriteFailureStreak) 次）" : ""
            topoffWriteFailureStreak = 0
            topoffState.lastWrittenLimit = limit
            topoffState.lastWriteAt = now
            events.append(LogEvent(
                category: .control, level: .info,
                message: "topoff 域已写：mclLimitValue=\(limit)（MCLFeatureState=1，先值后态；通知\(notified ? "已发" : "发送失败——agent 分钟级跟随兜底")）\(recoveryNote)"
            ))
            return true
        case .failed(let detail):
            topoffWriteFailureStreak += 1
            let firstFailure = topoffWriteFailureStreak == 1
            events.append(LogEvent(
                category: .control, level: firstFailure ? .error : .warn,
                message: firstFailure
                    ? "topoff 域写入失败：\(detail)——下 tick 幂等重写（两笔未全成功不通知，§3.3 原子序）"
                    : "topoff 域写入连续失败第 \(topoffWriteFailureStreak) 次（\(detail)）——幂等重写中（日志降频）"
            ))
            return false
        }
    }

    /// §3.7 关断清理（第四处卫生）：域随写 100（先值后态 + 通知）+ off——杜绝
    /// 「UI 已停用、实际钉 75」（agent 每分钟跟随域值）。幂等：已 100 且 off → 零写；
    /// **P3-2 评审修法：off 置位以写成功为条件**——失败不置位，守卫允许带 off 缺席
    /// 逐拍重试（「残留域值不滞留执法」不变量）。消费点：汇聚点状态不变量（mode
    /// 非 active ∨ 编排关 ∧ 目标 ≥80——P3-3）+ disable/restoreAndExit 事件路径。
    func topoffShutdownCleanupLocked(now: Date, events: inout [LogEvent]) {
        guard topoffState.lastWrittenLimit != Topoff.shutdownLimit || !topoffState.off else { return }
        let written = topoffExecuteWriteLocked(limit: Topoff.shutdownLimit, now: now, events: &events)
        guard written else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "topoff 关断清理写失败——off 不置位，下拍重试（残留域值不滞留执法不变量）"
            ))
            return
        }
        topoffState.off = true
        topoffState.healProbeActive = false
        events.append(LogEvent(
            category: .control, level: .info,
            message: "topoff 关断清理：域随写 100 + 通道 off（sub80State=off——防 UI 已停用、域值残留钉 75）"
        ))
    }

    /// 子进程捕获（stdout+stderr 合并 + 退出码；DoctorCommand 同款实现——daemon root
    /// 上下文运行 defaults/notifyutil）。
    static func runProcessCapture(
        _ executablePath: String, _ arguments: [String]
    ) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ("", -1)
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }
}
