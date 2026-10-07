// CellarCoreCheck —— 0.21.0 §3 校准共存场景域（方案 §3.1/§3.2）
//
// 按域拆独立文件（CHHysteresisDomain 先例）。覆盖清单（M2 工单验收门禁钉死项）：
// ①校准指纹（fingerprintMatches 判定矩阵各角：percent 94/95 门、target 90/91 门、
//   ext/charging 门、target=100 防误报、target 91-94 盲区——R1-P3 登记场景钉死）
// ②识别窗推进（9 tick 不命中 / 第 10 tick risingEdge / 中断拍清零重窗）
// ③进入/退出（risingEdge/fallingEdge 边沿；退出判据 percent < 95 ∨ target > 90
//   逐字；退出后重进需重满窗；抑制态维持语义——非退出集变化不打断）
// ④三臂抑制（suppressionPlan 双臂钉面 + convergenceRoute 扩参 calibrationSuspected：
//   desired=nil 断言静默矩阵〔≥80 主力区间 enforcement / 降级钳 80 / 迟滞覆盖序〕、
//   fullOnce 窗优先、mode 关优先、缺省参零 diff 既有链回归锚）
// ⑤violationTicks 清零（R1-P2-4：识别窗 10 tick < strike 验证窗 20 tick 的证据
//   优先序——daemon 消费面注记场景 + 常量关系钉死）
// ⑥wire：calibrationSuspected / sub80HealProbeActive / sub80HealProbeTicks 三字段
//   round-trip + 旧 JSON 缺席兼容（decodeIfPresent）
// ⑦§1.5 对账环补偿臂校准可疑豁免（review P2-1——App 侧独立近似判定纯函数钉面）；
//   校准共存-11 扩臂：日程窗 ∧ 校准态 desired=nil（两窗断言臂不同权——P3-1 角）
//
// daemon 侧消费（topoffConvergenceRouteLocked 边沿副作用/三臂早退/buildStatusLocked
// 恒填）为 cellar-daemon executable internal，CellarCoreCheck 不可 import——与
// CHHysteresisDomain XPCServer 臂同款注记登记，走真机走查兜底。
//
// 全部纯函数面，不触碰真实 SMC/IOKit/daemon。

import CellarCore
import Foundation
import XPC

/// 校准共存场景域入口（Main.main 调用）。
func runCalibrationCoexistenceDomainScenarios() {
    runCalibrationFingerprintScenarios()
    runCalibrationWindowScenarios()
    runCalibrationExitScenarios()
    runCalibrationSuppressionPlanScenarios()
    runCalibrationRouteScenarios()
    runCalibrationWireScenarios()
    runCalibrationResidualExemptionScenarios()
}

// MARK: - ① 指纹判定矩阵（§3.1 判据逐字）

private func runCalibrationFingerprintScenarios() {
    // 校准-1：判定矩阵各角——`percent ≥ 95 ∧ ext ∧ charging ∧ target ≤ 90`。
    check(CalibrationCoexistence.fingerprintMatches(
        percent: 95, externalConnected: true, isCharging: true, target: 90),
        "校准共存-1", "95 ∧ ext ∧ charging ∧ target=90 → 命中（四门全开边界）")
    check(CalibrationCoexistence.fingerprintMatches(
        percent: 100, externalConnected: true, isCharging: true, target: 80),
        "校准共存-1", "100% 主力形态（27 GA 校准典型——MCL 越权充满）→ 命中")
    check(!CalibrationCoexistence.fingerprintMatches(
        percent: 94, externalConnected: true, isCharging: true, target: 80),
        "校准共存-1", "percent 94 < 95 门 → 不命中")
    check(!CalibrationCoexistence.fingerprintMatches(
        percent: 96, externalConnected: false, isCharging: false, target: 80),
        "校准共存-1", "未外接（电池供电）→ 不命中")
    check(!CalibrationCoexistence.fingerprintMatches(
        percent: 96, externalConnected: true, isCharging: false, target: 80),
        "校准共存-1", "外接但停充（常规限充到位）→ 不命中")
    check(!CalibrationCoexistence.fingerprintMatches(
        percent: 96, externalConnected: true, isCharging: true, target: 91),
        "校准共存-1", "target=91 > 90 门 → 不命中（盲区起点——R1-P3）")
    check(!CalibrationCoexistence.fingerprintMatches(
        percent: 96, externalConnected: true, isCharging: true, target: 94),
        "校准共存-1", "target=94 → 不命中（盲区内——91-94 用户真实校准期无抑制，登记局限）")
    check(CalibrationCoexistence.fingerprintMatches(
        percent: 96, externalConnected: true, isCharging: true, target: 60),
        "校准共存-1", "target=60（最低合法值）→ 命中（target 门下界）")

    // 校准-2：防误报锚——target=100（完全放开设置）时指纹永不满足（方案 §3.1 钉死）。
    for percent in [95, 96, 99, 100] {
        check(!CalibrationCoexistence.fingerprintMatches(
            percent: percent, externalConnected: true, isCharging: true, target: 100),
            "校准共存-2", "target=100 ∧ percent=\(percent) → 恒不命中（防误报：放开态不构成校准证据）")
    }
}

// MARK: - ② 识别窗推进（10 tick = 5 min）

private func runCalibrationWindowScenarios() {
    // 校准-3：9 tick 不命中、第 10 tick risingEdge（窗长常量 = 10）。
    do {
        var state = CalibrationCoexistence.State()
        for tick in 1...9 {
            let outcome = CalibrationCoexistence.tick(
                state: state, percent: 97, externalConnected: true,
                isCharging: true, target: 80)
            state = outcome.state
            check(!state.suspected && !outcome.risingEdge,
                  "校准共存-3", "第 \(tick) tick：窗内不命中（计数 \(state.fingerprintTicks)）")
        }
        check(state.fingerprintTicks == 9, "校准共存-3", "9 tick 累计（差 1 拍）")
        let tenth = CalibrationCoexistence.tick(
            state: state, percent: 97, externalConnected: true, isCharging: true, target: 80)
        check(tenth.risingEdge && tenth.state.suspected && tenth.state.fingerprintTicks == 0,
              "校准共存-3", "第 10 tick：risingEdge + suspected=true + 计数归零（识别窗 = 5 min）")
        check(CalibrationCoexistence.detectionTicks == 10,
              "校准共存-3", "窗长常量 = 10 tick（30s 心跳 → 5 min；CellarCore 常量单一真相）")
    }

    // 校准-4：窗内中断拍清零（瞬时满电顶充不构成校准证据——中断即重窗）。
    do {
        var state = CalibrationCoexistence.State()
        for _ in 1...5 {
            state = CalibrationCoexistence.tick(
                state: state, percent: 97, externalConnected: true,
                isCharging: true, target: 80).state
        }
        // 中断拍：停充（常规限充到位形态）。
        let interrupt = CalibrationCoexistence.tick(
            state: state, percent: 97, externalConnected: true,
            isCharging: false, target: 80)
        check(!interrupt.state.suspected && interrupt.state.fingerprintTicks == 0,
              "校准共存-4", "窗内停充拍 → 计数清零（中断即重窗）")
        let resumed = CalibrationCoexistence.tick(
            state: interrupt.state, percent: 97, externalConnected: true,
            isCharging: true, target: 80)
        check(resumed.state.fingerprintTicks == 1 && !resumed.state.suspected,
              "校准共存-4", "恢复充电 → 从 1 重计（重窗语义）")
    }

    // 校准共存-4b：完全放开窗惰性拍（fullOnce 临时放开窗 ∨ chargingDisabled 日程窗
    // ——「target=100 永不满足」防误报锚的窗形态推广：窗内充到 100 是显式意图，
    // 与指纹同形，计入即假阳性）——不推进计数、不评估进出、状态原样。
    do {
        var state = CalibrationCoexistence.State()
        for i in 1...(CalibrationCoexistence.detectionTicks + 3) {
            let outcome = CalibrationCoexistence.tick(
                state: state, percent: 100, externalConnected: true,
                isCharging: true, target: 80, fullOpenWindow: true)
            state = outcome.state
            check(!state.suspected && state.fingerprintTicks == 0
                  && !outcome.risingEdge && !outcome.fallingEdge,
                  "校准共存-4b", "完全放开窗拍 \(i)：指纹惰性（零推进零边沿）")
        }
        // 已抑制态进窗：状态保持（不退出不推进）——窗毕若仍 ≥95 充电则抑制延续。
        let suspectedInWindow = CalibrationCoexistence.tick(
            state: CalibrationCoexistence.State(suspected: true),
            percent: 100, externalConnected: true, isCharging: true, target: 80,
            fullOpenWindow: true)
        check(suspectedInWindow.state.suspected && !suspectedInWindow.fallingEdge,
              "校准共存-4b", "抑制态 ∧ 完全放开窗 → 状态保持（窗毕再评估）")
    }
}

// MARK: - ③ 进入/退出边沿（退出判据逐字）

private func runCalibrationExitScenarios() {
    // 校准-5：抑制态维持——percent < 95 ∨ target > 90 之外的拍不退出
    //（充电停了但电量仍在 ≥95 门内：抑制延续无害——三臂在非充电压本就零触达）。
    do {
        var state = CalibrationCoexistence.State(suspected: true)
        let hold = CalibrationCoexistence.tick(
            state: state, percent: 100, externalConnected: true,
            isCharging: false, target: 80)
        check(hold.state.suspected && !hold.fallingEdge,
              "校准共存-5", "抑制态 ∧ 100% 停充（校准保持相）→ 维持（不退出）")
        state = hold.state
        let holdUnplug = CalibrationCoexistence.tick(
            state: state, percent: 97, externalConnected: false,
            isCharging: false, target: 80)
        check(holdUnplug.state.suspected && !holdUnplug.fallingEdge,
              "校准共存-5", "拔电但电量未回落 → 维持（percent < 95 后自然收敛）")
    }

    // 校准-6：退出判据逐字——percent < 95 → fallingEdge；target > 90 → fallingEdge；
    // 退出后重进需重满窗（R1-P2-4 证据优先序的对称面）。
    do {
        let percentExit = CalibrationCoexistence.tick(
            state: CalibrationCoexistence.State(suspected: true),
            percent: 94, externalConnected: true, isCharging: false, target: 80)
        check(percentExit.fallingEdge && !percentExit.state.suspected
              && percentExit.state.fingerprintTicks == 0,
              "校准共存-6", "percent 94 < 95 → 退出 + fallingEdge + 计数清零")
        let targetExit = CalibrationCoexistence.tick(
            state: CalibrationCoexistence.State(suspected: true),
            percent: 100, externalConnected: true, isCharging: true, target: 95)
        check(targetExit.fallingEdge && !targetExit.state.suspected,
              "校准共存-6", "target 80→95（>90 门）→ 退出（用户改值 = 意图变更）")
        // 退出后重进：需重满 10 tick 窗。
        var state = percentExit.state
        for _ in 1...(CalibrationCoexistence.detectionTicks - 1) {
            state = CalibrationCoexistence.tick(
                state: state, percent: 97, externalConnected: true,
                isCharging: true, target: 80).state
        }
        check(!state.suspected, "校准共存-6", "退出后 9 tick：未重进（重满窗）")
        let reenter = CalibrationCoexistence.tick(
            state: state, percent: 97, externalConnected: true, isCharging: true, target: 80)
        check(reenter.risingEdge && reenter.state.suspected,
              "校准共存-6", "退出后第 10 tick：重进（识别窗完整重走）")
    }
}

// MARK: - ④ 三臂抑制（R1-P1-5 定版）

private func runCalibrationSuppressionPlanScenarios() {
    // 校准-7：抑制计划双臂钉面——suspected=true → ①topoff 臂（strike 验证窗/轻量
    // 重申/自愈推进）+ ③域随写卫生 全静默、②断言静默；false → 双臂全 false
    //（既有链零变化锚）。
    do {
        let on = CalibrationCoexistence.suppressionPlan(suspected: true)
        check(on.suspendTopoffArms && on.silenceAssertion,
              "校准共存-7", "抑制态 → 双臂全开（①topoff 臂静默 + ②断言静默；③域随写随①早退同承）")
        let off = CalibrationCoexistence.suppressionPlan(suspected: false)
        check(!off.suspendTopoffArms && !off.silenceAssertion,
              "校准共存-7", "非抑制态 → 双臂全关（既有链零 diff 锚）")
        // 完全放开窗豁免：窗内各臂天然指向 100（convergenceTarget 强制 100——域随写
        // 100/断言 100 与校准同向；违规判定对 target=100 恒假），抑制会冻结「域随写
        // 100」对账写、阻断临时放开——窗优先。
        let windowExempt = CalibrationCoexistence.suppressionPlan(
            suspected: true, fullOpenWindow: true)
        check(!windowExempt.suspendTopoffArms && !windowExempt.silenceAssertion,
              "校准共存-7", "抑制态 ∧ 完全放开窗 → 双臂豁免（窗内域写 100/断言 100 同向放行）")
    }

    // 校准-8：证据优先序常量关系（R1-P2-4）——识别窗 10 tick < strike 验证窗
    // 20 tick：指纹命中必然先于首个 strike（20 tick）与轻量重申窗，daemon 命中拍
    // 同步清零 violationTicks 的前提（校准证据覆盖违规证据）。
    check(CalibrationCoexistence.detectionTicks < Topoff.verificationTicks,
          "校准共存-8", "识别窗 10 < strike 验证窗 20（R1-P2-4 前提常量关系钉死）")
}

// MARK: - ④' 校准抑制路由消费面（**0.23.1 编排退役翻新**——原「②断言静默 desired=nil」
// 扩参矩阵随断言链退役删除：convergenceRoute 不再消费 calibrationSuspected，校准
// 抑制的执法面由 daemon 侧 suppressionPlan 三臂承接（校准共存-13/14/15 钉面），
// 路由仅钉汇聚目标/承载两输出不受校准态影响）

private func runCalibrationRouteScenarios() {
    // 校准共存-9：路由面不受校准态影响（0.23.1 锚——校准抑制不改变汇聚目标与
    // 承载判定；topoff 臂静默由 daemon 早退承接，域值/簿记冻结）。
    do {
        let baseline = Topoff.convergenceRoute(
            modeActive: true, chargingDisabledWindow: false,
            upperLimit: 85, sub80Capable: true, actionActive: false)
        check(baseline.convergenceTarget == 85 && baseline.topoffOwned,
              "校准共存-9", "基线：target=85 → 汇聚 85 ∧ owned（域承载全区间）")
        check(baseline == Topoff.convergenceRoute(
            modeActive: true, chargingDisabledWindow: false,
            upperLimit: 85, sub80Capable: true, actionActive: false),
              "校准共存-9", "路由签名收敛：calibrationSuspected 输入删除（0.23.1——抑制面 = daemon 侧 suppressionPlan 三臂，路由输出恒等）")
    }

    // 校准共存-10：降级态与校准态对路由输出不可见（原「降级钳 80 断言静默」分支随
    // 断言链退役——degraded 由 channelTick/healTick 状态机承担）。
    do {
        let route = Topoff.convergenceRoute(
            modeActive: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false)
        check(route.convergenceTarget == 75 && route.topoffOwned,
              "校准共存-10", "<80 → topoff 承载（域值/簿记冻结由 daemon 早退分支消费——路由面无校准感知）")
    }

    // 校准共存-11：窗优先序保留（0.23.1）——fullOnce/日程窗汇聚目标 100（窗豁免
    // 同权放行经 suppressionPlan）。
    do {
        let fullOnce = Topoff.convergenceRoute(
            modeActive: true, chargingDisabledWindow: false,
            upperLimit: 85, sub80Capable: true, actionActive: false, fullOnceWindow: true)
        check(fullOnce.convergenceTarget == Topoff.shutdownLimit && !fullOnce.topoffOwned,
              "校准共存-11", "fullOnce 窗 → 汇聚 100 ∧ 不承载（显式放开——域随写 100 同向加速）")
        let scheduleWindow = Topoff.convergenceRoute(
            modeActive: true, chargingDisabledWindow: true,
            upperLimit: 85, sub80Capable: true, actionActive: false)
        check(scheduleWindow.convergenceTarget == Topoff.shutdownLimit
                  && !scheduleWindow.topoffOwned,
              "校准共存-11", "日程窗 → 汇聚 100 ∧ 不承载（域随写放行——窗豁免同权）")
        let modeOff = Topoff.convergenceRoute(
            modeActive: false, chargingDisabledWindow: false,
            upperLimit: 85, sub80Capable: true, actionActive: false)
        check(modeOff.convergenceTarget == nil && !modeOff.topoffOwned,
              "校准共存-11", "mode 关 → 既有关断语义（nil/不承载——硬关断不受抑制影响）")
    }
}

// MARK: - ⑦ §1.5 对账环补偿臂校准可疑豁免（review P2-1——App 侧独立近似判定）

/// P2-1 失败链（review 原文）：target 75 ∧ 编排关（合法稳态，期望 80）∧ 系统真实
/// 校准推 MCL 到 100 → 对账环 ≤30s set 80 压回 → 电池钳 80-85 → daemon 指纹
/// percent ≥95 永不满足 → 三臂抑制结构性不可达。App 侧近似豁免是引导链（放行
/// MCL 100 → 电池自由充 → daemon 指纹接管）。**与 daemon 指纹是两个独立判定**
///（App 无 10 tick 窗状态——本域钉 App 纯函数面，daemon 对账环消费点为 App 层
/// StatusController.reconcileShutdownResidual，CellarCoreCheck 不可 import——注记
/// 登记，真机走查兜底）。
private func runCalibrationResidualExemptionScenarios() {
    // 校准共存-16：review 工单两例逐字。
    check(CalibrationCoexistence.residualCompensationExempt(
        readback: 100, expected: 80, percent: 96, isCharging: true, target: 75),
        "校准共存-16", "期望 80 ∧ 读回 100 ∧ percent 96 充电 → 豁免（不补偿——P2-1 主形态）")
    check(!CalibrationCoexistence.residualCompensationExempt(
        readback: 100, expected: 80, percent: 85, isCharging: true, target: 75),
        "校准共存-16", "期望 80 ∧ 读回 100 ∧ percent 85 → 补偿照旧（review 工单第二例）")
    // 读回 ≤ 期望 → 恒不豁免（无压回意图，对账一致/补足分支不经过补偿臂）。
    check(!CalibrationCoexistence.residualCompensationExempt(
        readback: 80, expected: 80, percent: 96, isCharging: true, target: 75),
        "校准共存-16", "读回 == 期望 → 不豁免（一致分支仅刷新判定源）")
    check(!CalibrationCoexistence.residualCompensationExempt(
        readback: 75, expected: 80, percent: 96, isCharging: true, target: 75),
        "校准共存-16", "读回 < 期望 → 不豁免（残留补足语义无校准对抗面）")
    // 诚实边界：停充拍不豁免；证据缺席保守不豁免；盲区与防误报锚同 daemon 指纹。
    check(!CalibrationCoexistence.residualCompensationExempt(
        readback: 100, expected: 80, percent: 100, isCharging: false, target: 75),
        "校准共存-16", "percent 100 停充 → 不豁免（非充电拍压回不对抗校准——边界⑤）")
    check(!CalibrationCoexistence.residualCompensationExempt(
        readback: 100, expected: 80, percent: nil, isCharging: true, target: 75),
        "校准共存-16", "percent 缺席 → 不豁免（保守方向：关断残留语义优先）")
    check(!CalibrationCoexistence.residualCompensationExempt(
        readback: 100, expected: 80, percent: 96, isCharging: nil, target: 75),
        "校准共存-16", "charging 缺席 → 不豁免（同上）")
    check(!CalibrationCoexistence.residualCompensationExempt(
        readback: 100, expected: 80, percent: 96, isCharging: true, target: 92),
        "校准共存-16", "target 92（盲区）→ 不豁免（91-94 盲区同 daemon 指纹——R1-P3）")
    check(!CalibrationCoexistence.residualCompensationExempt(
        readback: 100, expected: 80, percent: 96, isCharging: true, target: 100),
        "校准共存-16", "target 100 → 不豁免（完全放开态无校准对抗面——防误报锚）")
}

// MARK: - ⑥ wire（三字段 round-trip + 旧 JSON 缺席兼容）

private func runCalibrationWireScenarios() {
    // 校准-13：三字段 round-trip（encode → decode 保真）。
    do {
        let status = DaemonStatus(
            version: DaemonXPC.daemonVersion, mode: "active", upperLimit: 85, hysteresis: 2,
            calibrationSuspected: true, sub80HealProbeActive: true, sub80HealProbeTicks: 7
        )
        let json = DaemonXPC.encodeStatus(status)
        check(json != nil, "校准共存-13", "encode 成功")
        let decoded = try? DaemonXPC.decodeStatus(json!)
        check(decoded?.calibrationSuspected == true,
              "校准共存-13", "calibrationSuspected round-trip（§3.2 面板横幅/status/doctor 行数据源）")
        check(decoded?.sub80HealProbeActive == true && decoded?.sub80HealProbeTicks == 7,
              "校准共存-13", "sub80HealProbe 两键 round-trip（§5 自愈进度数据源）")
    }

    // 校准-14：旧 JSON 缺席 → nil（decodeIfPresent 天然兼容——旧 daemon 回包不炸）。
    do {
        let legacyJSON = """
        {"version":"0.20.2-alpha","mode":"active","upperLimit":80,"hysteresis":2,"timestamp":0}
        """
        let decoded = try? DaemonXPC.decodeStatus(legacyJSON)
        check(decoded != nil && decoded?.calibrationSuspected == nil
              && decoded?.sub80HealProbeActive == nil && decoded?.sub80HealProbeTicks == nil,
              "校准共存-14", "旧 JSON 三字段缺席 → 解码成功恒 nil（wire 追加式兼容）")
    }

    // 校准-15：false 显式编码（orchestrationTerminal 门内恒填含 false——抑制退出后
    // App 侧横幅收口依赖 false 在场而非缺席）。
    do {
        let status = DaemonStatus(
            version: DaemonXPC.daemonVersion, mode: "active", upperLimit: 85, hysteresis: 2,
            calibrationSuspected: false
        )
        let json = DaemonXPC.encodeStatus(status)
        check(json?.contains("\"calibrationSuspected\"") == true,
              "校准共存-15", "false 显式编码在场（encodeIfPresent 对非 nil false 编码——退出同步语义）")
    }
}
