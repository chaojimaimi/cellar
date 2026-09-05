// CellarCoreCheck —— Phase 5 v1.5 keepAlive 热守卫收编场景域（方案 §2.2/§2.4 + §5-R-2：
// keepAliveChargingLocked 三分支 × fullOnce/校准 chargeFull 两调用点语境、降级机型
// 提前 advance/提前 done 两路径钉死 R-2 边界、校准滞留→恢复完成 + 超时中止；
// 与 ThermalPolicyDomain.swift 同域拆分——FanDomain/FanDoctorDomain 先例，
// 使各文件保持在 400 行内）
//
// 决策面 = CellarCore.ThermalGuard.keepAliveDecision（daemon keepAliveChargingLocked
// 只做副作用——executable 不可 import，纯函数即同源可测面）。

import CellarCore
import Foundation

/// keepAlive 收编场景域入口（Main.main 调用；断言经 MainEntry.swift 的 internal 助手）。
func runThermalKeepAliveDomainScenarios() throws {
    try runThermalKeepAliveScenarios()
}

// MARK: - ⑤ keepAlive 三分支 × 两调用点语境 + R-2 边界（方案 §2.4/§5-R-2；7 场景）
private func runThermalKeepAliveScenarios() throws {
    // 热保活-1：default 阈值三分支边界（40.0 停 / 39.99 带 / 37.0 带 / 36.99 恢复）。
    do {
        let d = ThermalPolicy.default
        check(ThermalGuard.keepAliveDecision(temperatureC: 40.0, policy: d) == .pauseCharging
                && ThermalGuard.keepAliveDecision(temperatureC: 41.0, policy: d) == .pauseCharging,
              "热保活-1", "t ≥ 40.0 → pauseCharging（含入侧——保活热暂停与常规守卫 case 2 同口径）")
        check(ThermalGuard.keepAliveDecision(temperatureC: 39.99, policy: d) == .hold
                && ThermalGuard.keepAliveDecision(temperatureC: 37.0, policy: d) == .hold,
              "热保活-1", "t ∈ [37.0, 40.0) → hold（滞回带驻留不重写，含 resume 含入侧）")
        check(ThermalGuard.keepAliveDecision(temperatureC: 36.99, policy: d) == .keepAlive,
              "热保活-1", "t < 37.0 → keepAlive（既有重写使能语义）")
    }
    // 热保活-2：自定义阈值三分支平移 + 纯函数幂等（同输入输出恒等）。
    // 3800/500 → pauseC=38.0、resumeC=38.0−5.0=33.0（滞回加大 → 恢复点下移）。
    do {
        // 直接构造（3800/500 为合法值域内 fixture——public memberwise init，
        // FanDomain 的 fanPolicy 助手同款形态）。
        let custom = ThermalPolicy(pauseCentiC: 3800, hysteresisCentiC: 500)
        check(ThermalGuard.keepAliveDecision(temperatureC: 38.0, policy: custom) == .pauseCharging
                && ThermalGuard.keepAliveDecision(temperatureC: 37.99, policy: custom) == .hold,
              "热保活-2", "自定义 38.0：38.0 → pauseCharging（含入侧）/ 37.99 → hold（滞回带）")
        check(ThermalGuard.keepAliveDecision(temperatureC: 33.0, policy: custom) == .hold
                && ThermalGuard.keepAliveDecision(temperatureC: 32.99, policy: custom) == .keepAlive,
              "热保活-2", "自定义恢复点 33.0（= 38.0 − 5.0 派生）：33.0 → hold / 32.99 → keepAlive")
        let first = ThermalGuard.keepAliveDecision(temperatureC: 39.5, policy: custom)
        let second = ThermalGuard.keepAliveDecision(temperatureC: 39.5, policy: custom)
        check(first == second, "热保活-2", "同输入两次调用输出恒等（纯函数无记忆）")
    }
    // 热保活-3：两调用点语境——fullOnce 轨道与校准 chargeFull 相在热停输入下均
    // 保持动作存活（keepAlive/stay），共用同一 pauseCharging 决策写停充（UD-5
    // 盲区收编：热保护覆盖所有充电使能路径）。
    do {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var fullOnceTrack = OneShotTrack()
        _ = fullOnceTrack.startIfIdle(now: start)
        // 热停形态：isCharging==false（CHTE 已停充）∧ 未满电 → 不完成不超时。
        let fullOnceTick = fullOnceTrack.tick(
            now: start.addingTimeInterval(30), fullyCharged: false, isCharging: false, percent: 60
        )
        let calibTick = calibrationTick(CalibrationTickInput(
            percent: 60, temperatureC: 41.0, externalConnected: true, isCharging: false,
            fullyCharged: false, now: start.addingTimeInterval(30), phase: .chargeFull,
            phaseStartedAt: start, deadline: start.addingTimeInterval(Calibration.totalDeadline),
            debounceTicks: 0, keepAliveFailures: 0, chieStatus: nil
        ))
        check(fullOnceTick == .keepAlive && calibTick.output == .stay(phase: .chargeFull),
              "热保活-3", "两调用点语境：fullOnce tick == keepAlive ∧ 校准 chargeFull tick == stay（热暂停不终止任一动作）")
        check(ThermalGuard.keepAliveDecision(temperatureC: 41.0, policy: .default) == .pauseCharging,
              "热保活-3", "两语境的保活副作用共用同一三分支决策（t=41 → 写停充）")
    }
    // 热保活-4（R-2a）：降级机型提前 done——FullyCharged 缺失 ∧ percent≥99 ∧
    // 热停（isCharging=false）→ isFullOnceComplete 误判成立，两 tick 去抖后提前
    // completed（已知边界：仅 ≥99% 近满电、后果属停充方向 = 安全）；非降级机型
    //（fullyCharged=false）同输入恒不完成（热停滞留）。
    do {
        check(OneShot.isFullOnceComplete(fullyCharged: nil, isCharging: false, percent: 99),
              "热保活-4", "降级判据：nil ∧ ¬charging ∧ 99% → 误判成立（R-2 边界钉死）")
        check(!OneShot.isFullOnceComplete(fullyCharged: false, isCharging: false, percent: 99),
              "热保活-4", "键在位 false 恒不成立（降级仅覆盖 nil）")
        let start = Date(timeIntervalSince1970: 2_000_000)
        var degraded = OneShotTrack()
        _ = degraded.startIfIdle(now: start)
        let tick1 = degraded.tick(now: start.addingTimeInterval(30), fullyCharged: nil, isCharging: false, percent: 99)
        let tick2 = degraded.tick(now: start.addingTimeInterval(60), fullyCharged: nil, isCharging: false, percent: 99)
        check(tick1 == .keepAlive && tick2 == .completed && degraded.latchedLiteral == OneShotLiteral.done(),
              "热保活-4", "降级机型热停两 tick → 提前 done（fullOnce 恢复限充，安全方向）")
        var normal = OneShotTrack()
        _ = normal.startIfIdle(now: start)
        let normalTick = normal.tick(now: start.addingTimeInterval(30), fullyCharged: false, isCharging: false, percent: 60)
        check(normalTick == .keepAlive, "热保活-4", "非降级机型热停 → keepAlive 滞留（保活写停充，恢复后继续）")
    }
    // 热保活-5（R-2b）：降级机型校准提前 advance——同判据复用（chargeFull 完成
    // 判定 = isFullOnceComplete），第二 tick 满去抖 → advance(hold)。
    do {
        let start = Date(timeIntervalSince1970: 3_000_000)
        func chargeFullInput(debounceTicks: Int, fullyCharged: Bool?) -> CalibrationTickInput {
            CalibrationTickInput(
                percent: 99, temperatureC: 41.0, externalConnected: true, isCharging: false,
                fullyCharged: fullyCharged, now: start.addingTimeInterval(60), phase: .chargeFull,
                phaseStartedAt: start, deadline: start.addingTimeInterval(Calibration.totalDeadline),
                debounceTicks: debounceTicks, keepAliveFailures: 0, chieStatus: nil
            )
        }
        let advance = calibrationTick(chargeFullInput(debounceTicks: 1, fullyCharged: nil))
        check(advance.output == .advance(to: .hold),
              "热保活-5", "降级机型热停去抖满 → 提前 advance 到 hold（静置方向 = 安全，R-2 共用边界）")
        let stay = calibrationTick(chargeFullInput(debounceTicks: 0, fullyCharged: false))
        check(stay.output == .stay(phase: .chargeFull) && stay.debounceTicks == 0,
              "热保活-5", "非降级机型同输入 → stay chargeFull 滞留（完成判据不被热停误触发）")
    }
    // 热保活-6：校准 chargeFull 热暂停滞留 → 冷却恢复 → 完成推进路径（UD-5：
    // 「校准被热中断」属正确保护行为非回归）。
    do {
        let start = Date(timeIntervalSince1970: 4_000_000)
        func input(fullyCharged: Bool?, isCharging: Bool, offset: TimeInterval, debounce: Int) -> CalibrationTickInput {
            CalibrationTickInput(
                percent: 70, temperatureC: isCharging ? 35.0 : 41.0, externalConnected: true,
                isCharging: isCharging, fullyCharged: fullyCharged,
                now: start.addingTimeInterval(offset), phase: .chargeFull,
                phaseStartedAt: start, deadline: start.addingTimeInterval(Calibration.totalDeadline),
                debounceTicks: debounce, keepAliveFailures: 0, chieStatus: nil
            )
        }
        let hotStay = calibrationTick(input(fullyCharged: false, isCharging: false, offset: 30, debounce: 0))
        check(hotStay.output == .stay(phase: .chargeFull),
              "热保活-6", "热停期（41°C 停充）→ stay chargeFull（保活走 hold/停充分支，校准滞留等待冷却）")
        let cooled1 = calibrationTick(input(fullyCharged: true, isCharging: false, offset: 600, debounce: 0))
        check(cooled1.output == .stay(phase: .chargeFull) && cooled1.debounceTicks == 1,
              "热保活-6", "冷却后充满首 tick → stay + 去抖 1（完成判定恢复累计）")
        let cooled2 = calibrationTick(input(fullyCharged: true, isCharging: false, offset: 630, debounce: 1))
        check(cooled2.output == .advance(to: .hold),
              "热保活-6", "充满第二 tick → advance(hold)（滞留→恢复完成闭环）")
    }
    // 热保活-7：滞留耗尽 chargeFullTimeout（6h）→ abort(timeout)——既有超时中止
    // 路径 = fail-safe 终态（热暂停不续期任何超时，UD-5 deadline 语义不变）。
    do {
        let start = Date(timeIntervalSince1970: 5_000_000)
        let timedOut = calibrationTick(CalibrationTickInput(
            percent: 70, temperatureC: 41.0, externalConnected: true, isCharging: false,
            fullyCharged: false, now: start.addingTimeInterval(Calibration.chargeFullTimeout + 1),
            phase: .chargeFull, phaseStartedAt: start,
            deadline: start.addingTimeInterval(Calibration.totalDeadline),
            debounceTicks: 0, keepAliveFailures: 0, chieStatus: nil
        ))
        check(timedOut.output == .abort(reason: CalibrationLiteral.AbortReason.timeout, safety: false),
              "热保活-7", "chargeFull 相 6h 耗尽（热停滞留消耗）→ abort(timeout) 非安全中止（终态恢复限充）")
    }
}

