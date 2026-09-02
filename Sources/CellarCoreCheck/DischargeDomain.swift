// CellarCoreCheck —— WP2' dischargeToLimit 场景域（方案 §5 S2 组①–⑤⑧）
//
// 按域拆独立文件（评审 P2-9：main.swift 约 2400 行已超 800 现状，新增用例不再
// 增长主文件）。与 main.swift 的 FailureCounter/断言助手/CheckTransport/mock
// 同模块复用（C 场景域跨文件调用 internal 助手）。
//
// 覆盖清单（方案 §5 S2 ①–⑤ + ⑧）：
// ①转移矩阵：完成/地板/温度/超时/ext 去抖族（1 次不触发/2 次触发/ext=false
//   清零/与保活互作用）/CHIE 保活失败 3 次/崩溃恢复/用户取消/setLimits×discharge/
//   sleepNow 分流（常量面）/backend-nil×discharge（能力面）/监护缺失 ≥3
// ②终态 CHIE 恢复写失败 + 残留巡检组（命中/巡检写失败/连续命中——纯函数面：
//   restoreEnabled 重试阶梯 + residualPatrolNeeded；daemon 编排面不可 import，
//   fullOnce 同款分层：轨道/纯函数钉死，IO 副作用由调用点依返回值执行）
// ③target=60 同 tick 完成 vs 地板优先级（完成前置钉死）
// ④旧格式 action.json decode（fullOnce 无 targetPercent → nil）
// ⑤XPC 前置拒绝矩阵（mode≠active/ext=false/percent≤目标/幂等）
// ⑧notificationEvents discharge 映射（用例 102 模式）

import CellarCore
import Foundation

/// 放电场景域入口（Main.main 调用；断言经 main.swift 的 internal 助手）。
/// throws：本域含 ActionStore 临时目录 IO（与用例 104 同款，失败上抛即场景失败）。
func runDischargeDomainScenarios() throws {
    let t0 = Date(timeIntervalSince1970: 0)
    let kind = Discharge.dischargeToLimitKind

    // 轨道回滚 helper：新放电轨（target 默认 80；**显式传 discharge 2h 超时窗口**——
    // startIfIdle 默认是 fullOnce 的 4h，各动作族超时不得混用）。
    func startTrack(target: Int = 80) -> OneShotTrack {
        var track = OneShotTrack()
        let started = track.startIfIdle(
            now: t0, kind: kind, targetPercent: target,
            timeout: Discharge.dischargeTimeout
        )
        check(started, "放电-1", "空轨 startIfIdle(discharge, target) → 启动成功")
        check(
            track.action?.targetPercent == target && track.action?.kind == kind,
            "放电-1", "动作承载 targetPercent/kind（deadline 校验见放电-3）"
        )
        return track
    }

    // ---- ① 转移矩阵 ----

    // 放电-2：完成判定（percent ≤ target → completed + done 锁存；>target → keepAlive）。
    do {
        var track = startTrack(target: 80)
        let out = track.tickDischarge(
            now: t0.addingTimeInterval(30), percent: 80, temperatureC: 30,
            externalConnected: false, chieStatus: .held, monitoringAvailable: true
        )
        check(out == .completed && track.action == nil
                && track.latchedLiteral == OneShotLiteral.done(kind: kind),
              "放电-2", "percent == target → completed + done 锁存（不依赖 Amperage——禁用态遥测冻结实证）")
        var notYet = startTrack(target: 80)
        let keep = notYet.tickDischarge(
            now: t0.addingTimeInterval(30), percent: 81, temperatureC: 30,
            externalConnected: false, chieStatus: .held, monitoringAvailable: true
        )
        check(keep == .keepAlive && notYet.action != nil && notYet.monitoringLossTicks == 0,
              "放电-2", "percent > target（81>80）→ keepAlive 继续")
    }

    // 放电-3：完成 vs 地板优先级（组③：target=60 同 tick 完成前置钉死）+ 超时同 tick。
    do {
        var floorHit = startTrack(target: 60)
        let out = floorHit.tickDischarge(
            now: t0.addingTimeInterval(30), percent: 60, temperatureC: 30,
            externalConnected: false, chieStatus: .held, monitoringAvailable: true
        )
        check(out == .completed && floorHit.latchedLiteral == OneShotLiteral.done(kind: kind),
              "放电-3", "target=60 同 tick：percent=60 完成与 60 地板并存 → 完成前置（评审 P2-3）")

        // 地板仍可达（防御面——手工写入 target<60 的 action.json：percent 在
        // (target, 60] 区间不构成完成 → 地板终止）。
        var crafted = OneShotTrack()
        _ = crafted.startIfIdle(now: t0, kind: kind, targetPercent: 30)
        let floor = crafted.tickDischarge(
            now: t0.addingTimeInterval(30), percent: 45, temperatureC: 30,
            externalConnected: false, chieStatus: .held, monitoringAvailable: true
        )
        check(floor == .safetyTerminated(reason: "floor")
                && crafted.latchedLiteral == OneShotLiteral.safety(kind: kind),
              "放电-3", "percent ∈ (target, 60] → safetyTerminated(floor)（防御面：target<60 异常文件）")
    }

    // 放电-4：完成 vs 超时同 tick → 完成优先（长睡唤醒报 done 而非 timeout）+ 超时窗口常量。
    do {
        var late = startTrack(target: 80)
        let out = late.tickDischarge(
            now: t0.addingTimeInterval(2 * 3600 + 60), percent: 78, temperatureC: 30,
            externalConnected: false, chieStatus: .held, monitoringAvailable: true
        )
        check(out == .completed && late.latchedLiteral == OneShotLiteral.done(kind: kind),
              "放电-4", "同 tick 完成成立 + 已过 deadline → 完成优先（done 而非 timeout）")
        let started = Discharge.start(now: t0, targetPercent: 80)
        check(started.deadline == t0.addingTimeInterval(Discharge.dischargeTimeout)
                && Discharge.dischargeTimeout == 2 * 3600,
              "放电-4", "Discharge.start：deadline = now + 2h（绝对 Date，SIGHUP 不重算）")
    }

    // 放电-5：温度（39.9 不触发 / 40.0 单点触发 / 温度×完成同 tick → 温度优先——链序 ③ 在 ④ 前）。
    do {
        var ok = startTrack(target: 80)
        let keep = ok.tickDischarge(
            now: t0.addingTimeInterval(30), percent: 90, temperatureC: 39.9,
            externalConnected: false, chieStatus: .held, monitoringAvailable: true
        )
        check(keep == .keepAlive, "放电-5", "温度 39.9°C（<40）→ keepAlive")
        var hot = startTrack(target: 80)
        let out = hot.tickDischarge(
            now: t0.addingTimeInterval(30), percent: 90, temperatureC: 40.0,
            externalConnected: false, chieStatus: .held, monitoringAvailable: true
        )
        check(out == .safetyTerminated(reason: "temperature")
                && hot.latchedLiteral == OneShotLiteral.safety(kind: kind),
              "放电-5", "温度 40.0°C（≥40）→ safetyTerminated(temperature) 单点即触发（评审 P2-2 刻意不对称）")
        var both = startTrack(target: 80)
        let edge = both.tickDischarge(
            now: t0.addingTimeInterval(30), percent: 78, temperatureC: 41,
            externalConnected: false, chieStatus: .held, monitoringAvailable: true
        )
        check(edge == .safetyTerminated(reason: "temperature"),
              "放电-5", "温度×完成同 tick → 温度优先（判定链序 ③ 温度在 ④ 完成之前，方案 §2.3 定版）")
    }

    // 放电-6：超时（未完成 + deadline → timedOut + timeout 锁存）。
    do {
        var timed = startTrack(target: 80)
        let out = timed.tickDischarge(
            now: t0.addingTimeInterval(2 * 3600 + 60), percent: 90, temperatureC: 30,
            externalConnected: false, chieStatus: .held, monitoringAvailable: true
        )
        check(out == .timedOut && timed.action == nil
                && timed.latchedLiteral == OneShotLiteral.timeout(kind: kind),
              "放电-6", "未完成 + now >= deadline → timedOut + timeout 锁存")
    }

    // 放电-7：ext 去抖族（1 次不触发 / 2 次触发 / ext=false 中断归零 / 与保活互作用）。
    do {
        var once = startTrack(target: 80)
        let step1 = once.tickDischarge(
            now: t0.addingTimeInterval(30), percent: 90, temperatureC: 30,
            externalConnected: true, chieStatus: .held, monitoringAvailable: true
        )
        check(step1 == .keepAlive && once.extDebounceTicks == 1,
              "放电-7", "ext=true 第 1 tick → keepAlive + 计数 1（60s 驻留判定，N=2）")
        let step2 = once.tickDischarge(
            now: t0.addingTimeInterval(60), percent: 90, temperatureC: 30,
            externalConnected: true, chieStatus: .held, monitoringAvailable: true
        )
        check(step2 == .cancelled(reason: "extRestored", literal: OneShotLiteral.cancel(kind: kind))
                && once.action == nil && once.latchedLiteral == OneShotLiteral.cancel(kind: kind),
              "放电-7", "ext=true 连续第 2 tick → cancelled(extRestored)——cancel 字面量**锁存**（审查 M3：daemon 发起取消，App 轮询必见终态/通知必发）")

        var inter = startTrack(target: 80)
        _ = inter.tickDischarge(
            now: t0.addingTimeInterval(30), percent: 90, temperatureC: 30,
            externalConnected: true, chieStatus: .held, monitoringAvailable: true
        )
        _ = inter.tickDischarge(
            now: t0.addingTimeInterval(60), percent: 90, temperatureC: 30,
            externalConnected: false, chieStatus: .held, monitoringAvailable: true
        )
        let retry = inter.tickDischarge(
            now: t0.addingTimeInterval(90), percent: 90, temperatureC: 30,
            externalConnected: true, chieStatus: .held, monitoringAvailable: true
        )
        check(retry == .keepAlive && inter.extDebounceTicks == 1,
              "放电-7", "中断归零后重新从 1 累计（第 3 tick：ext=1 未触发）")
        let retry2 = inter.tickDischarge(
            now: t0.addingTimeInterval(120), percent: 90, temperatureC: 30,
            externalConnected: true, chieStatus: .held, monitoringAvailable: true
        )
        check(retry2 == .cancelled(reason: "extRestored", literal: OneShotLiteral.cancel(kind: kind)),
              "放电-7", "ext=true→ext=false→ext=true×2 → 第 4 tick 触发取消（中断归零）")

        var mutual = startTrack(target: 80)
        _ = mutual.tickDischarge(
            now: t0.addingTimeInterval(30), percent: 90, temperatureC: 30,
            externalConnected: true, chieStatus: .held, monitoringAvailable: true
        )
        let rewritten = mutual.tickDischarge(
            now: t0.addingTimeInterval(60), percent: 90, temperatureC: 30,
            externalConnected: true, chieStatus: .rewritten, monitoringAvailable: true
        )
        // ⚠️ 计数断言必须逐步捕获（&& 链内读取 = 调用时刻的现值，最后一个 tick
        // 已把计数推进——状态断言与 tick 步进严格对应，防求值次序陷阱）。
        let extAfterRewritten = mutual.extDebounceTicks
        let afterRewrite1 = mutual.tickDischarge(
            now: t0.addingTimeInterval(90), percent: 90, temperatureC: 30,
            externalConnected: true, chieStatus: .held, monitoringAvailable: true
        )
        let extAfterRewrite1 = mutual.extDebounceTicks
        check(rewritten == .keepAlive && extAfterRewritten == 0
                && afterRewrite1 == .keepAlive && extAfterRewrite1 == 1,
              "放电-7", "与保活互作用：CHIE 被重置先被保活纠正（rewritten）→ ext 计数清零；ext 持续 true 而 CHIE 回读 0x8 才是真异常（评审 P0-3）")
        let afterRewrite2 = mutual.tickDischarge(
            now: t0.addingTimeInterval(120), percent: 90, temperatureC: 30,
            externalConnected: true, chieStatus: .held, monitoringAvailable: true
        )
        check(afterRewrite2 == .cancelled(reason: "extRestored", literal: OneShotLiteral.cancel(kind: kind)),
              "放电-7", "保活纠正后 ext 重新累计 2 tick → 触发取消")
    }

    // 放电-8：CHIE 保活失败族（2 次不触发 / 3 次触发取消 / held 中断清零）。
    do {
        var failing = startTrack(target: 80)
        let f1 = failing.tickDischarge(
            now: t0.addingTimeInterval(30), percent: 90, temperatureC: 30,
            externalConnected: false, chieStatus: .failed, monitoringAvailable: true
        )
        let f2 = failing.tickDischarge(
            now: t0.addingTimeInterval(60), percent: 90, temperatureC: 30,
            externalConnected: false, chieStatus: .failed, monitoringAvailable: true
        )
        check(f1 == .keepAlive && f2 == .keepAlive && failing.keepAliveFailures == 2,
              "放电-8", "保活失败 2 tick → keepAlive（连续失败计数 2，未达上限）")
        let f3 = failing.tickDischarge(
            now: t0.addingTimeInterval(90), percent: 90, temperatureC: 30,
            externalConnected: false, chieStatus: .failed, monitoringAvailable: true
        )
        check(f3 == .cancelled(reason: "keepAliveFailure", literal: OneShotLiteral.cancel(kind: kind)),
              "放电-8", "保活失败连续第 3 tick → cancelled(keepAliveFailure)（取消 + 告警）")

        var recovered = startTrack(target: 80)
        _ = recovered.tickDischarge(
            now: t0.addingTimeInterval(30), percent: 90, temperatureC: 30,
            externalConnected: false, chieStatus: .failed, monitoringAvailable: true
        )
        _ = recovered.tickDischarge(
            now: t0.addingTimeInterval(60), percent: 90, temperatureC: 30,
            externalConnected: false, chieStatus: .failed, monitoringAvailable: true
        )
        _ = recovered.tickDischarge(
            now: t0.addingTimeInterval(90), percent: 90, temperatureC: 30,
            externalConnected: false, chieStatus: .held, monitoringAvailable: true
        )
        check(recovered.keepAliveFailures == 0 && recovered.action != nil,
              "放电-8", "保活失败中断（held 恢复）→ 计数清零（连续失败语义）")
    }

    // 放电-9：监护缺失 ≥3（2 次不触发 / 恢复可用清零 / 第 3 次终止 safety + 告警面）。
    do {
        var tracked = startTrack(target: 80)
        check(!tracked.noteMonitoringLoss() && !tracked.noteMonitoringLoss() && tracked.monitoringLossTicks == 2,
              "放电-9", "监护缺失 2 tick → 不终止（计数 2 < 3）")
        _ = tracked.tickDischarge(
            now: t0.addingTimeInterval(30), percent: 90, temperatureC: 30,
            externalConnected: false, chieStatus: .held, monitoringAvailable: true
        )
        check(tracked.monitoringLossTicks == 0, "放电-9", "恢复可用（成功 tick）→ 监护计数清零")
        check(!tracked.noteMonitoringLoss() && !tracked.noteMonitoringLoss(),
              "放电-9", "清零后重新累计 2 tick → 仍不终止")
        check(tracked.noteMonitoringLoss(), "放电-9", "连续第 3 tick → 触发终止信号")
        let literal = tracked.terminateMonitoringLoss()
        check(literal == OneShotLiteral.safety(kind: kind) && tracked.action == nil
                && tracked.latchedLiteral == literal,
              "放电-9", "监护缺失终止：safety 字面量锁存 + 动作清空（评审 P1-5 兜底）")
        var empty = OneShotTrack()
        check(empty.noteMonitoringLoss() == false && empty.terminateMonitoringLoss() == nil,
              "放电-9", "非放电动作/空轨：监护计数不生效（fullOnce 不受影响）")
    }

    // 放电-10：崩溃恢复 adopt（discharge + fullOnce 同构 → cancel(crash-recovery) 锁存）。
    do {
        var track = OneShotTrack()
        let discharge = Discharge.start(now: t0, targetPercent: 80)
        let literal = track.adoptForCrashRecovery(discharge)
        check(literal == OneShotLiteral.cancelCrashRecovery(kind: kind) && track.action == nil
                && track.latchedLiteral == literal,
              "放电-10", "放电动作崩溃恢复 → cancel(crash-recovery) 锁存（App 轮询必见终态）")
        var full = OneShotTrack()
        let fullAction = OneShotAction(kind: OneShot.fullOnceKind, startedAt: t0, deadline: t0.addingTimeInterval(3600))
        let fullLiteral = full.adoptForCrashRecovery(fullAction)
        check(fullLiteral == OneShotLiteral.cancelCrashRecovery() && full.latchedLiteral == fullLiteral,
              "放电-10", "回归：fullOnce 崩溃恢复经 adopt 同样锁存（修正原空轨直取消不落锁存）")
    }

    // 放电-11：用户取消（cancel 字面量不锁存 + 空轨幂等 nil）。
    do {
        var track = startTrack(target: 80)
        let literal = track.cancel()
        check(literal == OneShotLiteral.cancel(kind: kind) && track.action == nil
                && track.latchedLiteral == nil,
              "放电-11", "用户取消 → cancel 字面量（不锁存）+ 动作清空")
        check(track.cancel() == nil, "放电-11", "无动作取消 → nil（XPC 幂等成功语义）")
    }

    // 放电-12：setLimits×discharge（纯转移面：SIGHUP disabled 取消 / 存活且 deadline 不重算）。
    do {
        var track = startTrack(target: 80)
        let deadlineBefore = track.action?.deadline
        check(track.reload(cancelled: false) == nil && track.isActive && track.action?.deadline == deadlineBefore,
              "放电-12", "SIGHUP 重载（未 disabled）→ 放电动作存活、deadline 不重算（评审 P0-2：setLimits/SIGHUP 语义与 fullOnce 实码一致）")
        check(track.reload(cancelled: true) == OneShotLiteral.cancel(kind: kind) && !track.isActive,
              "放电-12", "SIGHUP 重载（disabled）/setLimits 隐式取消 → cancel 字面量")
    }

    // 放电-26：daemon 发起取消锁存族（审查 M3）——sleepNow/setLimits/disable/
    // SIGHUP-disabled/SIGTERM 经 cancelLatched() **锁存** cancel 字面量（App 轮询
    // 必见终态、通知必发）；XPC 用户取消走 cancel() 不锁存保持原状；锁存清除面
    // （新动作启动/clearUserActionLatch）与 done/safety 同构。
    do {
        var sleep = startTrack(target: 80)
        let latchLiteral = sleep.cancelLatched()
        check(latchLiteral == OneShotLiteral.cancel(kind: kind) && !sleep.isActive
                && sleep.latchedLiteral == latchLiteral,
              "放电-26", "cancelLatched()：sleepNow 路径 → cancel 字面量锁存（终态常驻到用户动作）")
        check(sleep.effectiveLastAction("enforce:noop") == OneShotLiteral.cancel(kind: kind),
              "放电-26", "锁存生效：后续常规 tick 的 enforce:xxx 不覆盖 cancel 终态（60s 轮询档不漏发通知）")

        var fresh = startTrack(target: 80)
        check(fresh.action != nil && fresh.latchedLiteral == nil, "放电-26", "新动作启动清锁存（对照初态）")
        _ = fresh.cancelLatched()
        _ = fresh.startIfIdle(now: t0.addingTimeInterval(60), kind: kind, targetPercent: 70, timeout: Discharge.dischargeTimeout)
        check(fresh.latchedLiteral == nil && fresh.action?.targetPercent == 70,
              "放电-26", "用户动作（新放电启动）→ 清除锁存（与 done/safety 同形态，P0-2）")

        var userCancel = startTrack(target: 80)
        let plain = userCancel.cancel()
        check(plain == OneShotLiteral.cancel(kind: kind) && userCancel.latchedLiteral == nil,
              "放电-26", "XPC 用户取消（cancel()）→ 不锁存（App 即时反馈路径，保持现状）")
        var empty = OneShotTrack()
        check(empty.cancelLatched() == nil, "放电-26", "空轨 cancelLatched → nil（幂等成功语义）")
    }

    // 放电-13：sleepNow/终态重试约束常量（方案 §1.5：同步路径不得阻塞睡眠）。
    do {
        check(Discharge.sleepNowRestoreAttempts == 1, "放电-13", "sleepNow 恢复 CHIE 总尝试数 = 1（即零重试：失败立即上抛，不阻塞 IOAllowPowerChange 同步路径）")
        check(Discharge.terminalRestoreAttempts == 3, "放电-13", "终态/取消恢复重试阶梯 = 3（红线 5）")
        check(Discharge.floorPercent == 60 && Discharge.temperatureLimitC == 40.0
                && Discharge.extDebounceTicks == 2 && Discharge.keepAliveFailureLimit == 3
                && Discharge.monitoringLossLimit == 3,
              "放电-13", "判定常量钉死：地板 60 / 温度 40°C / ext 去抖 N=2 / 保活失败 3 / 监护缺失 3")
    }

    // 放电-14：backend-nil×discharge（能力面 fail-closed：不支持后端 restoreEnabled 显式报错）。
    do {
        let unsupported = MockChargingBackend(enabled: true)
        unsupported.adapterControlSupported = false
        unsupported.adapterEnabledRaw = false
        let error = DischargeAdapterControl.restoreEnabled(backend: unsupported, attempts: 3)
        check(error as? BackendError == BackendError.adapterControlUnsupported,
              "放电-14", "不支持适配器控制的后端：restoreEnabled → adapterControlUnsupported（fail-closed）")
    }

    // ---- ② 终态 CHIE 恢复写失败 + 残留巡检组 ----

    // 放电-15：恢复成功（一次写入即回读确认；写调用计数 1）。
    do {
        let backend = MockChargingBackend(enabled: true)
        backend.adapterEnabledRaw = false      // CHIE=0x08（放电中残留）
        let error = DischargeAdapterControl.restoreEnabled(backend: backend, attempts: Discharge.terminalRestoreAttempts)
        check(error == nil && backend.adapterEnabledRaw == true && backend.adapterWriteCount == 1,
              "放电-15", "恢复成功：写 0x00 + 回读确认 → nil，恰 1 次写调用")
    }

    // 放电-16：重试阶梯（前 2 次写被吞 → 第 3 次成功 → nil；共 3 次写调用）。
    do {
        let backend = MockChargingBackend(enabled: true)
        backend.adapterEnabledRaw = false
        backend.adapterFailWrites = 2
        let error = DischargeAdapterControl.restoreEnabled(backend: backend, attempts: 3)
        check(error == nil && backend.adapterWriteCount == 3 && backend.adapterEnabledRaw == true,
              "放电-16", "前 2 写不生效 → 第 3 写成功（重试阶梯 3 次耗尽前恢复）")
    }

    // 放电-17：重试阶梯耗尽（3 次全吞 → 返回最后一次 verifyFailed + 动作终态照常落盘由调用方保证）。
    do {
        let backend = MockChargingBackend(enabled: true)
        backend.adapterEnabledRaw = false
        backend.adapterFailWrites = 3
        let error = DischargeAdapterControl.restoreEnabled(backend: backend, attempts: 3)
        check(error as? BackendError == BackendError.verifyFailed(key: "CHIE", desired: true, actual: false)
                && backend.adapterWriteCount == 3,
              "放电-17", "重试耗尽 → 上抛 verifyFailed(CHIE)（调用方告警，残留交 §2.4 巡检兜底）")
    }

    // 放电-18：sleepNow 档恢复失败（attempts=1 单发失败 → 立即上抛，不拖长同步睡眠路径）。
    do {
        let backend = MockChargingBackend(enabled: true)
        backend.adapterEnabledRaw = false
        backend.adapterFailWrites = 1
        let error = DischargeAdapterControl.restoreEnabled(backend: backend, attempts: 1)
        check(error != nil && backend.adapterWriteCount == 1,
              "放电-18", "sleepNow 档（attempts=1）写失败 → 立即上抛（不阻塞 IOAllowPowerChange，§1.5）")
    }

    // 放电-19：残留巡检判定组（命中 / 巡检写失败 / 连续命中——判定函数无记忆，
    // 每次巡检独立判定 = 连续命中自然成立）。
    do {
        check(Discharge.residualPatrolNeeded(enabled: false) == true, "放电-19", "巡检索命中：CHIE=0x08（禁用残留）→ 需恢复")
        check(Discharge.residualPatrolNeeded(enabled: nil) == true, "放电-19", "巡检索命中：未知值（fail-closed）→ 需恢复")
        check(Discharge.residualPatrolNeeded(enabled: true) == false, "放电-19", "巡检放行：CHIE=0x00 → 无需恢复")
        check(Discharge.residualPatrolNeeded(enabled: false) == true
                && Discharge.residualPatrolNeeded(enabled: false) == true,
              "放电-19", "连续命中：恢复写失败后下一 tick 判定仍为需恢复（巡检无记忆，30s 节奏重试）")
        let failing = MockChargingBackend(enabled: true)
        failing.adapterEnabledRaw = false
        failing.adapterFailWrites = 1
        let error = DischargeAdapterControl.restoreEnabled(backend: failing, attempts: 1)
        check(error != nil, "放电-19", "巡检写失败路径：restoreEnabled 单发失败 → 告警由调用方发出，巡检继续")
    }

    // 放电-20：CHIE 值协议映射（adapterState 纯函数——TahoeBackend.adapterEnabled 同源）。
    do {
        check(Discharge.adapterState(from: [0x00]) == true, "放电-20", "0x00 → true（使能）")
        check(Discharge.adapterState(from: [0x08]) == false, "放电-20", "0x08 → false（禁用）")
        check(Discharge.adapterState(from: [0x01]) == nil, "放电-20", "未知值 0x01 → nil（显式表达，禁止猜测）")
        check(Discharge.adapterState(from: []) == nil && Discharge.adapterState(from: [0x00, 0x00]) == nil,
              "放电-20", "长度 ≠1 → nil（防御）")
    }

    // ---- ④ 旧格式 action.json decode ----

    // 放电-21：旧格式 fullOnce（无 targetPercent 键）→ 解码 nil；新增键 round-trip。
    do {
        let legacyJSON = #"{"kind":"fullOnce","startedAt":0,"deadline":14400}"#
        let legacy = try? JSONDecoder().decode(OneShotAction.self, from: Data(legacyJSON.utf8))
        check(legacy?.targetPercent == nil && legacy?.kind == OneShot.fullOnceKind,
              "放电-21", "旧格式 fullOnce JSON（无 targetPercent）→ 解码成功且 targetPercent == nil（评审 P1-6）")

        let discharge = Discharge.start(now: t0, targetPercent: 80)
        let data = try JSONEncoder().encode(discharge)
        let round = try JSONDecoder().decode(OneShotAction.self, from: data)
        check(round.kind == kind && round.targetPercent == 80 && round.deadline == t0.addingTimeInterval(2 * 3600),
              "放电-21", "新格式 dischargeToLimit 往返（kind/targetPercent/deadline 全字段）")
    }

    // 放电-22：ActionStore 白名单（fullOnce/dischargeToLimit 载入；未知 kind treat-as-absent）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-discharge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActionStore(url: directory.appendingPathComponent("action.json"))

        try store.save(Discharge.start(now: t0, targetPercent: 80))
        check(store.load()?.kind == kind && store.load()?.targetPercent == 80,
              "放电-22", "白名单一：dischargeToLimit 载入（ActionStore 白名单扩 {fullOnce, dischargeToLimit}）")
        let legacyAction = OneShotAction(kind: OneShot.fullOnceKind, startedAt: t0, deadline: t0.addingTimeInterval(3600))
        try store.save(legacyAction)
        check(store.load()?.kind == OneShot.fullOnceKind && store.load()?.targetPercent == nil,
              "放电-22", "白名单二：fullOnce 旧格式经新白名单照常载入（targetPercent nil）")
        try JSONEncoder().encode(OneShotAction(kind: "discharge", startedAt: t0, deadline: t0)).write(to: store.url)
        check(store.load() == nil && store.fileExists,
              "放电-22", "白名单三：kind=discharge（字面量不含 dischargeToLimit）→ 未知动作 treat-as-absent")
    }

    // ---- ⑤ XPC 前置拒绝矩阵 ----

    // 放电-23：前置矩阵（mode / ext / percent≤目标 / percent 未知）+ 拒绝原文可读。
    do {
        check(Discharge.startPrecondition(mode: "disabled", externalConnected: true, percent: 100, targetPercent: 80) == .modeNotActive,
              "放电-23", "mode=disabled → 拒绝（modeNotActive）")
        check(Discharge.startPrecondition(mode: "active", externalConnected: false, percent: 100, targetPercent: 80) == .noExternalPower,
              "放电-23", "未外接 → 拒绝（noExternalPower）")
        check(Discharge.startPrecondition(mode: "active", externalConnected: nil, percent: 100, targetPercent: 80) == .noExternalPower,
              "放电-23", "外接未知（快照失败且无上次已知值）→ 拒绝（noExternalPower）")
        check(Discharge.startPrecondition(mode: "active", externalConnected: true, percent: 80, targetPercent: 80) == .notAboveTarget(percent: 80, target: 80),
              "放电-23", "percent == 目标 → 拒绝（notAboveTarget）")
        check(Discharge.startPrecondition(mode: "active", externalConnected: true, percent: 79, targetPercent: 80) == .notAboveTarget(percent: 79, target: 80),
              "放电-23", "percent < 目标 → 拒绝（notAboveTarget）")
        check(Discharge.startPrecondition(mode: "active", externalConnected: true, percent: nil, targetPercent: 80) == .notAboveTarget(percent: 0, target: 80),
              "放电-23", "percent 未知 → 拒绝（不无据启动——禁用适配器前必须确认电量高于目标）")
        check(Discharge.startPrecondition(mode: "active", externalConnected: true, percent: 81, targetPercent: 80) == nil,
              "放电-23", "active + ext + percent>目标 → 放行")
        let rejection = DischargeStartRejection.noExternalPower
        check(rejection.message.contains("外接电源"), "放电-23", "拒绝原文为中文可读文案（XPC errorReply 上屏）")
        // S3 顺手修钉死：percent=0 为「电量未知」哨兵 → 上屏区分未知文案（防误导 0%）。
        let unknownPercentRejection = DischargeStartRejection.notAboveTarget(percent: 0, target: 80)
        check(unknownPercentRejection.message.contains("当前电量未知")
                && !unknownPercentRejection.message.contains("当前 0%"),
              "放电-23", "percent=0 → 「当前电量未知」（修「当前 0%」误导）")
    }

    // 放电-24：幂等（轨道在轨 → startIfIdle 拒绝，daemon 回当前状态——fullOnce 先例）。
    do {
        var track = startTrack(target: 80)
        check(!track.startIfIdle(now: t0.addingTimeInterval(10), kind: kind, targetPercent: 70),
              "放电-24", "已活跃再次启动 → 拒绝（幂等回当前状态）")
        _ = track.cancel()
        check(track.startIfIdle(now: t0.addingTimeInterval(20), kind: kind, targetPercent: 70),
              "放电-24", "取消后空轨 → 可启动（新目标经 daemon 每次 XPC 快照）")
    }

    // ---- ⑧ notificationEvents discharge 映射（用例 102 模式）----

    // 放电-25：六字面量映射 + 首样本 + 锁存重复 + P1-4 抑制 + 回归。
    do {
        func dStatus(_ lastAction: String?, upper: Int = 90) -> DaemonStatus {
            DaemonStatus(
                version: "fixture", mode: "active", upperLimit: upper,
                hysteresis: 2, lastAction: lastAction, lastPercent: 78,
                lastExternalConnected: true, lastChargingEnabled: false
            )
        }
        check(notificationEvents(previous: nil, current: dStatus("dischargeToLimit:start")) == [],
              "放电-25", "首样本 dischargeToLimit:start → 无事件（previous==nil 既有语义）")
        check(notificationEvents(previous: dStatus("dischargeToLimit:start"), current: dStatus("dischargeToLimit:done"))
                == [.actionCompleted(kind: kind)],
              "放电-25", "start→done 转移 → actionCompleted(kind: dischargeToLimit)")
        check(notificationEvents(previous: dStatus("dischargeToLimit:start"), current: dStatus("dischargeToLimit:timeout"))
                == [.actionTimeout(kind: kind)],
              "放电-25", "start→timeout 转移 → actionTimeout")
        check(notificationEvents(previous: dStatus("dischargeToLimit:start"), current: dStatus("dischargeToLimit:safety"))
                == [.actionSafetyTerminated(kind: kind)],
              "放电-25", "start→safety 转移 → actionSafetyTerminated（温度/地板/监护缺失/残留巡检告警通道）")
        check(notificationEvents(previous: dStatus("dischargeToLimit:start"), current: dStatus("dischargeToLimit:cancel"))
                == [.actionCancelled(kind: kind)],
              "放电-25", "start→cancel 转移 → actionCancelled（放电取消具安全显著性，§2.3 统一 cancel → 通知；与 fullOnce 用户取消静默对照）")
        check(notificationEvents(previous: dStatus("dischargeToLimit:start"), current: dStatus("dischargeToLimit:cancel(crash-recovery)"))
                == [.actionInterrupted(kind: kind)],
              "放电-25", "start→cancel(crash-recovery) 转移 → actionInterrupted")
        check(notificationEvents(previous: dStatus("dischargeToLimit:safety"), current: dStatus("dischargeToLimit:safety")) == [],
              "放电-25", "锁存期重复样本（safety→safety）→ 无重复事件")
        check(notificationEvents(previous: dStatus("dischargeToLimit:done"), current: dStatus("enforce:disableCharging")) == [],
              "放电-25", "P1-4 扩展：done 终态后恢复停充 → 不产 limitReached（dischargeToLimit: 前缀纳入抑制）")
        check(notificationEvents(previous: dStatus("dischargeToLimit:done"), current: dStatus("enforce:error")) == [.writeFailed],
              "放电-25", "回归：终态后写失败 → writeFailed 照旧（失败类不受 P1-4 抑制）")
        check(notificationEvents(previous: dStatus("fullOnce:start"), current: dStatus("fullOnce:cancel")) == [],
              "放电-25", "回归：fullOnce start→cancel → 无事件（用户取消静默语义不变）")
        check(notificationEvents(previous: dStatus("enforce:noop"), current: dStatus("enforce:disableCharging"))
                == [.limitReached(upperLimit: 90)],
              "放电-25", "回归：普通 enforce 转移 → limitReached 照旧（P1-4 仅抑制动作前缀）")
    }
}