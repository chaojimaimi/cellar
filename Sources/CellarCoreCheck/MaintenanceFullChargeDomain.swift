// CellarCoreCheck —— 0.23.25 §2.2 charge-to-full 系统维护充满感知与退让场景域
//
// 按域拆独立文件（CalibrationCoexistenceDomain 先例）。覆盖清单（任务书 §3 断言
// 联动——状态机全真值表）：
// ①行为指纹（fingerprintMatches 判定矩阵各角：readback 100/99/nil、percent
//   target+2/+3 边界、ext/charging 门、采样缺席全拒、margin 同源 Topoff.
//   violationMarginPercent——§2.2 复用既有常量定值）
// ②进入通道 ①通知边沿（signalPending 拍立即进入 + 进入即清指纹计数 + 已在
//   退让态不重复进入）+ ②行为指纹（2 拍不进 / 第 3 拍进 / 中断拍清零重窗）
// ③退出三臂（①读回 limit != 100 + 读回缺席不构成退出证据〔fail-open〕；
//   ②超时 2h 强退 timeoutExit 标记 + 边界 1s；③mode 非 active 由 daemon 结构
//   承接——状态机无 mode 输入，头注登记同款注记）
// ④退让计划（suppressionPlan 双臂 + 非 active 零变化锚 + plan 经 tick 透出一致性）
// ⑤读回节奏（readbackDue：信号边沿恒 due / nil 首拍即读 / 10 min 边界）
// ⑥常量关系与共存（指纹窗 3 < 校准识别窗 10——校准证据优先序不被抢占；margin/
//   overrideLimit/读回间隔/超时独立语义钉面；R8 校准抑制期指纹通道结构性
//   不可达注记——daemon 侧消费面，executable internal 不可 import）
// ⑦B8 持久化缺失重启语义（State.empty 全零字段——重启即 ≤90s 指纹重识别空窗，
//   照 CalibrationCoexistence.State 先例；daemon 侧消费〔早退臂/B6 重申写/
//   buildStatusLocked 恒填〕为 cellar-daemon executable internal，CellarCoreCheck
//   不可 import——头注注记登记，走真机走查兜底）
// ⑧wire：maintenanceFullChargeActive nil/true/false 三态 round-trip（§3——
//   照 calibrationSuspected 先例位）
//
// 全部纯函数面，不触碰真实 SMC/IOKit/daemon。

import CellarCore
import Foundation
import XPC

/// charge-to-full 维护充满场景域入口（Main.main 调用）。
func runMaintenanceFullChargeDomainScenarios() {
    let t0 = Date(timeIntervalSince1970: 5_000_000)
    func tick(_ n: Int) -> Date { t0.addingTimeInterval(Double(n) * 30) }   // 30s 心跳

    // ---- ① 行为指纹判定矩阵（§2.2 判据逐字）----

    // 维护充满-1：判定矩阵各角——`readback==100 ∧ isCharging ∧ percent > target+2 ∧ ext`。
    check(MaintenanceFullCharge.fingerprintMatches(
        readback: 100, percent: 78, externalConnected: true, isCharging: true, target: 75),
        "维护充满-1", "读回 100 ∧ 78 > 75+2 ∧ ext ∧ 充电 → 命中（四门全开）")
    check(MaintenanceFullCharge.fingerprintMatches(
        readback: 100, percent: 100, externalConnected: true, isCharging: true, target: 75),
        "维护充满-1", "percent 100（§0 实证充满 92%+ 形态）→ 命中")
    check(!MaintenanceFullCharge.fingerprintMatches(
        readback: 75, percent: 96, externalConnected: true, isCharging: true, target: 75),
        "维护充满-1", "读回 75（域未被覆写）→ 不命中")
    check(!MaintenanceFullCharge.fingerprintMatches(
        readback: 99, percent: 96, externalConnected: true, isCharging: true, target: 75),
        "维护充满-1", "读回 99 ≠ 100 → 不命中（override 签名钉死 100）")
    check(!MaintenanceFullCharge.fingerprintMatches(
        readback: 100, percent: 77, externalConnected: true, isCharging: true, target: 75),
        "维护充满-1", "percent 77 == target+2 边界内 → 不命中（> 严格下界）")
    check(!MaintenanceFullCharge.fingerprintMatches(
        readback: 100, percent: 95, externalConnected: true, isCharging: false, target: 75),
        "维护充满-1", "停充（isCharging=false）→ 不命中")
    check(!MaintenanceFullCharge.fingerprintMatches(
        readback: 100, percent: 96, externalConnected: false, isCharging: false, target: 75),
        "维护充满-1", "未外接（电池供电）→ 不命中")
    // 采样缺席（nil 三角）全拒——证据不足不推进（channelTick 采样缺席拍同纪律）。
    check(!MaintenanceFullCharge.fingerprintMatches(
        readback: 100, percent: nil, externalConnected: true, isCharging: true, target: 75),
        "维护充满-1", "percent 缺席 → 不命中（采样缺席拍不推进）")
    check(!MaintenanceFullCharge.fingerprintMatches(
        readback: 100, percent: 96, externalConnected: nil, isCharging: true, target: 75),
        "维护充满-1", "ext 缺席 → 不命中")
    check(!MaintenanceFullCharge.fingerprintMatches(
        readback: 100, percent: 96, externalConnected: true, isCharging: nil, target: 75),
        "维护充满-1", "isCharging 缺席 → 不命中")
    // 读回缺席三角（外层 nil / 内层 nil）→ 不命中（fingerprintMatches 入参为
    // 外层已解包形态——两缺席形态解包后证据等价 nil）。
    check(!MaintenanceFullCharge.fingerprintMatches(
        readback: nil, percent: 96, externalConnected: true, isCharging: true, target: 75),
        "维护充满-1", "读回缺席（外层 nil = 未读过/读失败；内层 nil = 键缺席——解包后同形）→ 不命中（fail-open）")

    // 维护充满-2：margin 同源钉面——指纹超限判定与 Topoff.isViolationTick 同一
    // margin 常量（§2.2「复用既有常量定值，Topoff.swift:24」）。
    expectEqual(Topoff.violationMarginPercent, 2,
                "维护充满-2", "Topoff.violationMarginPercent == 2（既有常量定值——指纹门引用不另立常量）")
    for (percent, target) in [(77, 75), (78, 75), (95, 90), (83, 80)] {
        let fingerprint = MaintenanceFullCharge.fingerprintMatches(
            readback: 100, percent: percent, externalConnected: true,
            isCharging: true, target: target)
        check(fingerprint == (percent > target + Topoff.violationMarginPercent),
              "维护充满-2", "percent=\(percent)/target=\(target)：指纹超限门与 isViolationTick margin 同源（单常量单真相）")
    }

    // ---- ② 进入通道（通知边沿 / 行为指纹）----

    // 维护充满-3：通知边沿拍立即进入（快路径——无指纹门）。
    do {
        let outcome = MaintenanceFullCharge.tick(
            state: .empty, signalPending: true,
            readback: nil, percent: nil, externalConnected: nil,
            isCharging: nil, target: 75, now: tick(1))
        check(outcome.risingEdge && outcome.state.active
                  && outcome.state.enteredAt == tick(1)
                  && outcome.state.fingerprintTicks == 0,
              "维护充满-3", "signalPending 拍 → 立即进入（enteredAt 锚定 + 指纹计数清——边沿证据替代累积证据）")
        check(outcome.plan.suspendEnforcementArms && outcome.plan.violationTicksReset,
              "维护充满-3", "进入拍 plan 双臂全 true（三臂早退 + violationTicks 清零证据优先）")
        check(!outcome.fallingEdge && !outcome.timeoutExit,
              "维护充满-3", "进入拍无退出边沿（timeoutExit false）")
    }

    // 维护充满-4：已在退让态的重复 post 不重复进入（不假设 post 次数——§2.1）。
    do {
        let entered = MaintenanceFullCharge.tick(
            state: .empty, signalPending: true, readback: nil, percent: nil,
            externalConnected: nil, isCharging: nil, target: 75, now: tick(1))
        let again = MaintenanceFullCharge.tick(
            state: entered.state, signalPending: true,
            readback: Optional(Optional(100)), percent: 78, externalConnected: true,
            isCharging: true, target: 75, now: tick(2))
        check(again.state.active && !again.risingEdge && !again.fallingEdge,
              "维护充满-4", "退让态 ∧ 信号再至 → 维持（不重复进入/不误退出——post 次数无关）")
    }

    // 维护充满-5：行为指纹窗推进——2 拍不进 / 第 3 拍进（3 拍 = 90s）。
    do {
        var state = MaintenanceFullCharge.State()
        for n in 1...2 {
            let outcome = MaintenanceFullCharge.tick(
                state: state, signalPending: false,
                readback: Optional(Optional(100)), percent: 78, externalConnected: true,
                isCharging: true, target: 75, now: tick(n))
            state = outcome.state
            check(!state.active && !outcome.risingEdge && state.fingerprintTicks == n,
                  "维护充满-5", "第 \(n) 拍：窗内不进（计数 \(state.fingerprintTicks)）")
        }
        let third = MaintenanceFullCharge.tick(
            state: state, signalPending: false,
            readback: Optional(Optional(100)), percent: 78, externalConnected: true,
            isCharging: true, target: 75, now: tick(3))
        check(third.risingEdge && third.state.active
                  && third.state.fingerprintTicks == 0
                  && third.state.enteredAt == tick(3),
              "维护充满-5", "第 3 拍：risingEdge 进入（指纹窗 3 拍 = 90s ≤ 心跳保底上限）")
    }

    // 维护充满-6：指纹中断拍清零重窗（瞬时读回 100 不构成 override 证据——照校准
    // 识别窗「中断即重窗」纪律）。
    do {
        var state = MaintenanceFullCharge.State()
        for _ in 1...2 {
            state = MaintenanceFullCharge.tick(
                state: state, signalPending: false,
                readback: Optional(Optional(100)), percent: 78, externalConnected: true,
                isCharging: true, target: 75, now: tick(1)).state
        }
        check(state.fingerprintTicks == 2, "维护充满-6", "2 拍累计（前置态）")
        let interrupted = MaintenanceFullCharge.tick(
            state: state, signalPending: false,
            readback: Optional(Optional(75)), percent: 78, externalConnected: true,
            isCharging: true, target: 75, now: tick(2))
        check(interrupted.state.fingerprintTicks == 0 && !interrupted.state.active,
              "维护充满-6", "指纹失效拍（读回 75）→ 计数清零重窗")
        let resumed = MaintenanceFullCharge.tick(
            state: interrupted.state, signalPending: false,
            readback: Optional(Optional(100)), percent: 78, externalConnected: true,
            isCharging: true, target: 75, now: tick(3))
        check(resumed.state.fingerprintTicks == 1 && !resumed.state.active,
              "维护充满-6", "恢复命中从 1 重新计数（重窗语义）")
    }

    // ---- ③ 退出三臂 ----

    // 维护充满-7：臂① 读回 limit != 100 → 退出（fallingEdge；timeoutExit false）。
    do {
        let entered = MaintenanceFullCharge.tick(
            state: .empty, signalPending: true, readback: nil, percent: nil,
            externalConnected: nil, isCharging: nil, target: 75, now: tick(1)).state
        let outcome = MaintenanceFullCharge.tick(
            state: entered, signalPending: false,
            readback: Optional(Optional(75)), percent: 75, externalConnected: true,
            isCharging: false, target: 75, now: tick(2))
        check(outcome.fallingEdge && !outcome.state.active
                  && outcome.state.enteredAt == nil
                  && !outcome.timeoutExit,
              "维护充满-7", "读回 75 ≠ 100 → 退出（fallingEdge + enteredAt 清 + 非超时）")
        check(!outcome.plan.suspendEnforcementArms && !outcome.plan.violationTicksReset,
              "维护充满-7", "退出拍 plan 双臂全 false（既有链恢复锚——B6 重申写由 daemon 消费）")
    }

    // 维护充满-8：臂① 读回缺席不构成退出证据（fail-open 维持退让态）。
    do {
        let entered = MaintenanceFullCharge.tick(
            state: .empty, signalPending: true, readback: nil, percent: nil,
            externalConnected: nil, isCharging: nil, target: 75, now: tick(1)).state
        // 外层 nil（读失败）：
        let readFailed = MaintenanceFullCharge.tick(
            state: entered, signalPending: false, readback: nil, percent: 78,
            externalConnected: true, isCharging: true, target: 75, now: tick(2))
        check(readFailed.state.active && !readFailed.fallingEdge,
              "维护充满-8", "读回读失败（外层 nil）→ 维持退让（fail-open——不误判恢复）")
        // 内层 nil（键缺席）：
        let keyAbsentReadback: Int?? = .some(nil)
        let keyAbsent = MaintenanceFullCharge.tick(
            state: entered, signalPending: false,
            readback: keyAbsentReadback, percent: 78,
            externalConnected: true, isCharging: true, target: 75, now: tick(2))
        check(keyAbsent.state.active && !keyAbsent.fallingEdge,
              "维护充满-8", "读回键缺席（内层 nil）→ 维持退让")
        // 读回仍 100（override 在位）→ 维持：
        let stillOverridden = MaintenanceFullCharge.tick(
            state: entered, signalPending: false,
            readback: Optional(Optional(100)), percent: 78, externalConnected: true,
            isCharging: true, target: 75, now: tick(2))
        check(stillOverridden.state.active && !stillOverridden.fallingEdge,
              "维护充满-8", "读回仍 100（override 在位）→ 维持退让")
    }

    // 维护充满-9：臂② 超时 2h 强退（timeoutExit 标记 + 边界 1s 不退）。
    do {
        let entered = MaintenanceFullCharge.tick(
            state: .empty, signalPending: true, readback: nil, percent: nil,
            externalConnected: nil, isCharging: nil, target: 75, now: tick(1)).state
        let boundary = MaintenanceFullCharge.tick(
            state: entered, signalPending: false, readback: nil, percent: nil,
            externalConnected: nil, isCharging: nil, target: 75,
            now: tick(1).addingTimeInterval(MaintenanceFullCharge.timeout - 1))
        check(boundary.state.active && !boundary.fallingEdge,
              "维护充满-9", "2h − 1s → 维持（严格下界——读回缺席拍超时照判）")
        let expired = MaintenanceFullCharge.tick(
            state: entered, signalPending: false, readback: nil, percent: nil,
            externalConnected: nil, isCharging: nil, target: 75,
            now: tick(1).addingTimeInterval(MaintenanceFullCharge.timeout))
        check(expired.fallingEdge && !expired.state.active && expired.timeoutExit,
              "维护充满-9", "整 2h → 强退（fallingEdge + timeoutExit 标记——daemon warn 面可溯源 R2）")
    }

    // ---- ④ 退让计划 ----

    // 维护充满-10：suppressionPlan 双臂钉面 + 非 active 零变化锚。
    check(MaintenanceFullCharge.suppressionPlan(active: true)
              == MaintenanceFullCharge.Plan(
                  suspendEnforcementArms: true, violationTicksReset: true),
          "维护充满-10", "active → 双臂全 true（三臂早退 + violationTicks 清零）")
    check(MaintenanceFullCharge.suppressionPlan(active: false)
              == MaintenanceFullCharge.Plan(
                  suspendEnforcementArms: false, violationTicksReset: false),
          "维护充满-10", "非 active → 双臂全 false（既有链零变化锚）")

    // ---- ⑤ 读回节奏 ----

    // 维护充满-11：readbackDue——信号边沿恒 due / nil 首拍即读 / 10 min 边界。
    check(MaintenanceFullCharge.readbackDue(
        last: tick(1), signalPending: true, now: tick(2)),
        "维护充满-11", "信号边沿拍 → 恒 due（立即一次——恢复检出不等周期）")
    check(MaintenanceFullCharge.readbackDue(
        last: nil, signalPending: false, now: tick(1)),
        "维护充满-11", "last nil → 首拍即读（远古）")
    check(!MaintenanceFullCharge.readbackDue(
        last: tick(1), signalPending: false, now: tick(1).addingTimeInterval(599)),
        "维护充满-11", "距上次读回 < 10 min → 不 due（非读回拍零子进程成本）")
    check(MaintenanceFullCharge.readbackDue(
        last: tick(1), signalPending: false,
        now: tick(1).addingTimeInterval(MaintenanceFullCharge.readbackInterval)),
        "维护充满-11", "距上次读回 == 10 min → due（≥ 边界钉面）")

    // ---- ⑥ 常量关系与共存交互 ----

    // 维护充满-12：指纹窗 < 校准识别窗（校准证据优先序不被抢占——§2.2）+ 关键
    // 常量独立语义钉面。
    check(MaintenanceFullCharge.fingerprintTicksRequired
              < CalibrationCoexistence.detectionTicks,
          "维护充满-12", "指纹窗 3 拍 < 校准识别窗 10 tick（校准证据优先序不被抢占）")
    expectEqual(MaintenanceFullCharge.overrideLimit, 100,
                "维护充满-12", "override 签名钉死 100（PowerUIAgent 覆写值——§0 实证）")
    expectEqual(MaintenanceFullCharge.readbackInterval, 600,
                "维护充满-12", "maintenance 读回节奏 10 min（照健康稳态 2 子进程/10 min 成本口径）")
    expectEqual(MaintenanceFullCharge.timeout, 2 * 3600,
                "维护充满-12", "超时强退 2h（正常 15-25 min；兜底系统 hang）")

    // ---- ⑦ B8 持久化缺失重启语义 ----

    // 维护充满-13：State.empty 全零字段（重启即空 = ≤90s 指纹重识别空窗——不
    // 持久化换零新增落盘面；照 CalibrationCoexistence.State 先例）。
    check(MaintenanceFullCharge.State.empty == MaintenanceFullCharge.State(
        active: false, enteredAt: nil, lastReadbackLimit: nil, fingerprintTicks: 0),
        "维护充满-13", "State.empty = 非 active / 无锚 / 读回锁存空 / 计数零（B8 重启语义——退让中重启回 ≤90s 指纹识别空窗，期间既有缠斗照旧，任务书 §5 R7 登记）")
    // 重启后指纹重识别全窗重走（空态 3 拍不进——B8 空窗上界 = 3 拍 × 30s 心跳）。
    do {
        var state = MaintenanceFullCharge.State.empty
        var enteredAtBeat = 0
        for n in 1...3 {
            let outcome = MaintenanceFullCharge.tick(
                state: state, signalPending: false,
                readback: Optional(Optional(100)), percent: 92, externalConnected: true,
                isCharging: true, target: 75, now: tick(n))
            state = outcome.state
            if outcome.risingEdge { enteredAtBeat = n }
        }
        check(enteredAtBeat == 3,
              "维护充满-13", "重启空态重识别恰 3 拍（空窗 ≤ 90s 上界实证——通知不可达时指纹保底路径）")
    }

    // ---- ⑧ wire 三态 round-trip（照 calibrationSuspected 先例位）----

    // 维护充满-14：maintenanceFullChargeActive true / false / nil（缺席兼容）round-trip。
    do {
        let active = DaemonStatus(
            version: DaemonXPC.daemonVersion, mode: "active", upperLimit: 75, hysteresis: 2,
            maintenanceFullChargeActive: true
        )
        let decodedActive = try? DaemonXPC.decodeStatus(DaemonXPC.encodeStatus(active)!)
        check(decodedActive?.maintenanceFullChargeActive == true,
              "维护充满-14", "true round-trip（面板横幅 + App 恢复门数据源——§2.3/§2.4）")
        let inactive = DaemonStatus(
            version: DaemonXPC.daemonVersion, mode: "active", upperLimit: 75, hysteresis: 2,
            maintenanceFullChargeActive: false
        )
        let decodedInactive = try? DaemonXPC.decodeStatus(DaemonXPC.encodeStatus(inactive)!)
        check(decodedInactive?.maintenanceFullChargeActive == false,
              "维护充满-14", "false round-trip（27 在场未退让——恒填态）")
        // 缺席兼容：未填字段构造 → encode 缺键 → decode nil（旧 daemon/26 兼容——
        // decodeIfPresent 合成 Codable 先例）。
        let absent = DaemonStatus(
            version: DaemonXPC.daemonVersion, mode: "active", upperLimit: 75, hysteresis: 2
        )
        let json = DaemonXPC.encodeStatus(absent)
        let decodedAbsent = json.flatMap { try? DaemonXPC.decodeStatus($0) }
        check(decodedAbsent?.maintenanceFullChargeActive == nil,
              "维护充满-14", "缺席 → nil（26/旧 daemon decodeIfPresent wire 兼容）")
    }
}
