// CellarCoreCheck —— WP2 topoffprotection <80% 限充通道场景域（方案 §3 全部）
//
// 按域拆独立文件（评审 P2-9 先例）。覆盖清单（M1b 工单）：
// ①写入器原子序（§3.3：先 mclLimitValue 后 MCLFeatureState/两笔成功才通知/失败臂）
// ②违规与证据判定边界（§3.2 判据逐字）
// ③channelTick 状态机（幂等写/验证窗 20 tick/strike 重申/冷却门/strike×3 降级/24h 复位/
//   采样缺席拍不推进）
// ④healTick 自愈（1h 节奏/强证据恢复/20 违规回降级）
// ⑤汇聚点路由真值表（§3.1：单通道互斥/降级钳 80/自愈窗编排静默/编排开关门独立性/
//   26 回归逐值/actionActive 执法总开关）
// ⑥wire：sub80State 三态 round-trip + 旧 JSON 缺席（HealthCapabilitiesDomain 能力-9）

import CellarCore
import Foundation

/// topoff 场景域入口（Main.main 调用）。
func runTopoffDomainScenarios() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func tick(_ n: Int) -> Date { t0.addingTimeInterval(Double(n) * 30) }   // 30s tick 节奏

    // ---- ① 写入器原子序（§3.3）----

    // 写-1：顺序钉死（先 mclLimitValue 后 MCLFeatureState）+ 两笔成功才通知。
    do {
        var calls: [String] = []
        var notified = false
        let outcome = TopoffWriter.write(limit: 75, run: { _, args in
            calls.append(args.count >= 3 ? args[2] : "?")
            return ("", 0)
        }, notify: { _ in notified = true; return true })
        check(outcome == .written(notified: true) && calls == [Topoff.limitKey, Topoff.featureStateKey] && notified,
              "写-1", "原子序：先 mclLimitValue 后 MCLFeatureState（中间崩溃最多留惰性态）；两笔成功 → 通知已发")
    }

    // 写-2/3：任一笔失败 → .failed 且零通知（原子序红线）。
    do {
        func isFailed(_ outcome: TopoffWriteOutcome) -> Bool {
            if case .failed = outcome { return true }
            return false
        }
        var notified = false
        let limitFail = TopoffWriter.write(limit: 75, run: { _, args in
            (args.count >= 3 && args[2] == Topoff.limitKey) ? ("err", 1) : ("", 0)
        }, notify: { _ in notified = true; return true })
        check(isFailed(limitFail) && !notified, "写-2", "limit 写失败 → failed 且零通知")
        let stateFail = TopoffWriter.write(limit: 75, run: { _, args in
            (args.count >= 3 && args[2] == Topoff.featureStateKey) ? ("err", 1) : ("", 0)
        }, notify: { _ in notified = true; return true })
        check(isFailed(stateFail) && !notified, "写-3", "state 写失败 → failed 且零通知（先值后态——值已写仍不通知）")
    }

    // 写-4：通知失败 → written(notified: false)（agent 分钟级跟随兜底，不阻塞通道）。
    do {
        let outcome = TopoffWriter.write(limit: 75, run: { _, _ in ("", 0) }, notify: { _ in false })
        check(outcome == .written(notified: false), "写-4", "通知失败 → written(notified: false)（域值已落盘为权威）")
    }

    // ---- ② 违规/证据判定边界（§3.2 判据逐字）----

    // 判-1：percent > target+2 ∧ ext ∧ isCharging；证据 =「钉在 target」指纹
    //（P1-①：ext ∧ !isCharging ∧ percent ∈ [target-1, target]）。
    do {
        check(!Topoff.isViolationTick(percent: 77, target: 75, externalConnected: true, isCharging: true),
              "判-1", "percent == target+2（77/75）→ 非违规（余量边界，> 严格）")
        check(Topoff.isViolationTick(percent: 78, target: 75, externalConnected: true, isCharging: true),
              "判-1", "percent > target+2（78/75）→ 违规")
        check(!Topoff.isViolationTick(percent: 90, target: 75, externalConnected: false, isCharging: true)
                && !Topoff.isViolationTick(percent: 90, target: 75, externalConnected: true, isCharging: false),
              "判-1", "ext=false / isCharging=false → 非违规（证据不足）")
        check(Topoff.isEnforcementEvidence(percent: 75, target: 75, externalConnected: true, isCharging: false)
                && Topoff.isEnforcementEvidence(percent: 74, target: 75, externalConnected: true, isCharging: false),
              "判-1", "钉在 target 正点/下沿停充（75/74 ∈ [74,75] ∧ ext ∧ !isCharging）→ 通道存活强证据")
        check(!Topoff.isEnforcementEvidence(percent: 76, target: 75, externalConnected: true, isCharging: false)
                && !Topoff.isEnforcementEvidence(percent: 80, target: 75, externalConnected: true, isCharging: false),
              "判-1", "越窗停充（76/80 ∉ [74,75]）→ 非证据（P1-①故障臂 (a)：死通道 + native 钳 80 停充不构成假恢复）")
        check(!Topoff.isEnforcementEvidence(percent: 75, target: 75, externalConnected: false, isCharging: false)
                && !Topoff.isEnforcementEvidence(percent: 73, target: 75, externalConnected: true, isCharging: false),
              "判-1", "ext=false / percent < target-1 → 弱信号不构成恢复证据（观察窗继续）")
    }

    // ---- ③ channelTick 状态机（§3.2/§3.3）----

    // 通道-1：首写（activeTarget nil → 写 target + 动力学重置）+ 幂等（同值 → 零写）。
    do {
        let plan = Topoff.channelTick(state: TopoffChannelState(), target: 75, now: tick(0),
                                      percent: 90, externalConnected: true, isCharging: true)
        check(plan.writeLimit == 75 && plan.state.activeTarget == 75 && plan.state.violationTicks == 0,
              "通道-1", "首写：activeTarget nil → 写 75（写拍不推进验证窗——动力学重置）")
        var written = plan.state
        written.lastWrittenLimit = 75
        written.lastWriteAt = tick(0)
        let idle = Topoff.channelTick(state: written, target: 75, now: tick(1),
                                      percent: 90, externalConnected: true, isCharging: true)
        check(idle.writeLimit == nil && idle.state.violationTicks == 1,
              "通道-1", "幂等：lastWritten == target → 零写；违规拍开始计数（90>77 ∧ 充电中）")
    }

    // 通道-2：验证窗 20 tick → strike 1 → 重申写（冷却自然满足）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = tick(0)
        var strikePlan: TopoffTickPlan?
        for n in 1...20 {
            strikePlan = Topoff.channelTick(state: s, target: 75, now: tick(n),
                                            percent: 90, externalConnected: true, isCharging: true)
            s = strikePlan!.state
        }
        check(s.strikes == 1 && s.violationTicks == 0 && s.lastViolationAt == tick(20)
                && strikePlan?.writeLimit == 75,
              "通道-2", "连续 20 违规 tick → strike 1 + 重申写 75（重写即重置动力学；距初写 600s ≥ 冷却）")
        // 中断归零：19 违规 + 1 非违规 → 窗清零不 strike。
        var interrupted = TopoffChannelState()
        interrupted.activeTarget = 75
        interrupted.lastWrittenLimit = 75
        interrupted.lastWriteAt = tick(0)
        for n in 1...19 {
            interrupted = Topoff.channelTick(state: interrupted, target: 75, now: tick(n),
                                             percent: 90, externalConnected: true, isCharging: true).state
        }
        let reset = Topoff.channelTick(state: interrupted, target: 75, now: tick(20),
                                       percent: 75, externalConnected: true, isCharging: true)
        check(reset.state.violationTicks == 0 && reset.state.strikes == 0 && reset.writeLimit == nil,
              "通道-2", "窗中断（第 20 拍非违规）→ 计数归零不 strike（「持续 N=20」语义）")
    }

    // 通道-3：重申冷却门（strike 时距上次写 <10min → 不写，窗重置继续观察）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = tick(5)   // 距 strike 时刻 tick(20) 仅 450s < 冷却 600s
        var plan: TopoffTickPlan?
        for n in 1...20 {
            plan = Topoff.channelTick(state: s, target: 75, now: tick(n),
                                      percent: 90, externalConnected: true, isCharging: true)
            s = plan!.state
        }
        check(s.strikes == 1 && plan?.writeLimit == nil,
              "通道-3", "strike 时冷却未到（450s < 600s）→ 不重申（窗已重置继续观察——护栏防外源快触发）")
    }

    // 通道-4：strike×3 → 诚实降级（域随写 80 + degraded=true）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        for w in 0..<3 {
            s.lastWriteAt = tick(w * 25)   // 每窗重置 lastWriteAt（冷却自然满足）
            var plan: TopoffTickPlan?
            for n in 1...20 {
                plan = Topoff.channelTick(state: s, target: 75, now: tick(w * 25 + n),
                                          percent: 90, externalConnected: true, isCharging: true)
                s = plan!.state
                if plan!.writeLimit != nil { s.lastWrittenLimit = plan!.writeLimit; s.lastWriteAt = tick(w * 25 + n) }
            }
        }
        check(s.degraded && s.strikes == 3 && s.lastHealProbeAt == tick(70),
              "通道-4", "第 3 strike → 诚实降级（degraded=true，重申×3 封顶；P2：lastHealProbeAt 播种于降级时刻——降级稳态整 1h 后才首探）")
    }

    // 通道-5：24h 无违反 → strikes 复位（R1-P3）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.strikes = 2
        s.lastViolationAt = tick(0)
        let reset = Topoff.channelTick(state: s, target: 75, now: tick(0).addingTimeInterval(Topoff.violationResetWindow + 30),
                                       percent: 90, externalConnected: true, isCharging: true)
        check(reset.state.strikes == 0, "通道-5", "24h 无违反 → strikes 复位（降级自愈配套——防远古 strike 永久压制）")
        let notYet = Topoff.channelTick(state: s, target: 75, now: tick(0).addingTimeInterval(Topoff.violationResetWindow - 30),
                                        percent: 90, externalConnected: true, isCharging: true)
        check(notYet.state.strikes == 2, "通道-5", "24h 未满 → strikes 保留")
    }

    // 通道-6：采样缺席拍不推进窗（证据不足防误降级）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        let plan = Topoff.channelTick(state: s, target: 75, now: tick(1),
                                      percent: nil, externalConnected: nil, isCharging: nil)
        check(plan.writeLimit == nil && plan.state.violationTicks == 0,
              "通道-6", "采样缺席（nil 入参）→ 窗不推进（防误降级）")
    }

    // ---- ④ healTick 自愈（§3.2）----

    // 自愈-1：降级播种（P2）+ 到期重探（写 target + 观察窗开）+ 未到期零写。
    do {
        // P2 播种现实路径：降级时 lastHealProbeAt 已由 channelTick 播种 → 整 1h 后首探。
        var s = TopoffChannelState()
        s.degraded = true
        s.lastWrittenLimit = 80
        s.activeTarget = 75
        s.lastHealProbeAt = tick(0)
        let notDue = Topoff.healTick(state: s, target: 75, now: tick(0).addingTimeInterval(Topoff.healProbeInterval - 30),
                                     percent: 90, externalConnected: true, isCharging: true)
        check(notDue.writeLimit == nil && !notDue.state.healProbeActive,
              "自愈-1", "降级播种后 1h 未到 → 不重探（P2：降级稳态不被即刻探针打破）")
        let probe = Topoff.healTick(state: s, target: 75, now: tick(0).addingTimeInterval(Topoff.healProbeInterval),
                                    percent: 90, externalConnected: true, isCharging: true)
        check(probe.writeLimit == 75 && probe.state.healProbeActive && probe.state.lastHealProbeAt == tick(0).addingTimeInterval(Topoff.healProbeInterval),
              "自愈-1", "到期 → 每小时重探：域写 target + 观察窗开（lastHealProbeAt 重锚）")
        var probed = probe.state
        probed.lastWrittenLimit = 75   // daemon 簿记模拟：探针写成功 → lastWritten 回填
        let tooSoon = Topoff.healTick(state: probed, target: 75, now: tick(0).addingTimeInterval(Topoff.healProbeInterval + 30),
                                      percent: 90, externalConnected: true, isCharging: true)
        check(tooSoon.writeLimit == nil && tooSoon.state.healProbeActive,
              "自愈-1", "观察窗进行中 → 零写（编排静默由路由层承接）")
        // 防御臂钉死：lastHealProbeAt nil（理论不可达——P2 播种恒在）→ 立即探。
        let defensive = Topoff.healTick(state: {
            var x = TopoffChannelState(); x.degraded = true; x.lastWrittenLimit = 80; x.activeTarget = 75; return x
        }(), target: 75, now: tick(0), percent: 90, externalConnected: true, isCharging: true)
        check(defensive.writeLimit == 75 && defensive.state.healProbeActive,
              "自愈-1", "lastHealProbeAt nil（防御臂）→ 立即重探")
    }

    // 自愈-2：观察窗强证据（P1-①「钉在 target」指纹）→ 恢复（degraded/strikes 清零）。
    do {
        var s = TopoffChannelState()
        s.degraded = true
        s.strikes = 3
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.healProbeActive = true
        s.healProbeTicks = 7
        s.lastHealProbeAt = tick(0)
        let restored = Topoff.healTick(state: s, target: 75, now: tick(1),
                                       percent: 75, externalConnected: true, isCharging: false)
        check(!restored.state.degraded && restored.state.strikes == 0
                && !restored.state.healProbeActive && restored.writeLimit == nil,
              "自愈-2", "强证据拍（钉在 target 正点停充：75 ∈ [74,75] ∧ ext ∧ !isCharging）→ 恢复承载（degraded/strikes 清零；域值已在 target——channelTick 幂等无写）")
    }

    // 自愈-2b（P1-①故障臂 (a) 钉死）：死通道 + native 钳 80 停充 → 假证据不恢复。
    do {
        var s = TopoffChannelState()
        s.degraded = true
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.healProbeActive = true
        s.lastHealProbeAt = tick(0)
        let falseEvidence = Topoff.healTick(state: s, target: 75, now: tick(1),
                                            percent: 80, externalConnected: true, isCharging: false)
        check(falseEvidence.state.degraded && falseEvidence.state.healProbeActive
                && falseEvidence.state.healProbeTicks == 1 && falseEvidence.writeLimit == nil,
              "自愈-2b", "native 钳 80 停充（80 ∉ [74,75]）→ 不构成恢复证据（窗推进 1 拍——修死故障臂 (a)）")
    }

    // 自愈-2c（P1-③）：探针中 target 变更 → 幂等重写新目标 + 观察窗重置。
    do {
        var s = TopoffChannelState()
        s.degraded = true
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.healProbeActive = true
        s.healProbeTicks = 9
        s.lastHealProbeAt = tick(0)
        let retarget = Topoff.healTick(state: s, target: 70, now: tick(1),
                                       percent: 76, externalConnected: true, isCharging: true)
        check(retarget.writeLimit == 70 && retarget.state.activeTarget == 70
                && retarget.state.healProbeTicks == 0 && retarget.state.healProbeActive,
              "自愈-2c", "探针中 target 变更（75→70）→ 立即随写新目标 + 观察窗重置（域值不停留旧目标——P1-③）")
    }

    // 自愈-2d（P1-②故障臂 (b) 钉死）：观察窗 20 tick 无违反无证据 → 无差别超时回稳态。
    do {
        var s = TopoffChannelState()
        s.degraded = true
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.healProbeActive = true
        s.lastHealProbeAt = tick(0)
        var plan: TopoffTickPlan?
        for n in 1...20 {
            // 活 agent 钉 target 正点且充电微顶（75 ∈ 违规=false ∧ 证据需停充=false）——弱信号形态。
            plan = Topoff.healTick(state: s, target: 75, now: tick(n),
                                   percent: 75, externalConnected: true, isCharging: true)
            s = plan!.state
        }
        check(!s.healProbeActive && plan?.writeLimit == 80 && s.degraded && s.lastViolationAt == nil,
              "自愈-2d", "窗满 20 tick 无违反无证据 → 无差别超时：回降级稳态（补写 degradedLimit 维持稳态不变量）+ 下小时再探（修死故障臂 (b) 永久滞留）")
    }

    // 自愈-3：观察窗 20 连续违规 → 自愈失败回降级稳态（域随写 80，下小时再探）。
    do {
        var s = TopoffChannelState()
        s.degraded = true
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.healProbeActive = true
        s.lastHealProbeAt = tick(0)
        var plan: TopoffTickPlan?
        for n in 1...20 {
            plan = Topoff.healTick(state: s, target: 75, now: tick(n),
                                   percent: 90, externalConnected: true, isCharging: true)
            s = plan!.state
        }
        check(!s.healProbeActive && plan?.writeLimit == 80 && s.lastViolationAt == tick(20),
              "自愈-3", "20 连续违规 → 自愈失败：回降级稳态（域随写 80；无封顶持续诚实重试）")
    }

    // ---- ⑤b §3.7 关断清理状态不变量（P3-3 场景钉死——路由前置条件面）----

    // 清理-1：daemon 关断清理分支的触发前置（纯函数可钉面）——mode nil ∨（编排关 ∧
    // 目标 ≥80）时 desired=nil ∧ !topoffOwned（域随写卫生零触发）；<80 编排关 →
    // topoffOwned（不清理）。daemon 侧按此消费（CellarCoreCheck 不可 import daemon，
    // 调用点次序由 daemon 注记 + code-review 走查兜底）。
    do {
        let modeNil = Topoff.convergenceRoute(
            modeActive: false, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false,
            degraded: false, healProbeActive: false)
        check(modeNil.convergenceTarget == nil && modeNil.orchestrationDesired == nil && !modeNil.topoffOwned,
              "清理-1", "mode 非 active → 清理前置成立（域随写 100 + off）")
        let orchOff80 = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: false, chargingDisabledWindow: false,
            upperLimit: 85, sub80Capable: true, actionActive: false,
            degraded: false, healProbeActive: false)
        check(orchOff80.orchestrationDesired == nil && !orchOff80.topoffOwned
                && orchOff80.convergenceTarget == 85,
              "清理-1", "编排关 ∧ 目标 ≥80 → 清理前置成立（P3-3：fresh 重启首拍即清理——状态不变量）")
        let orchOff75 = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: false, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false,
            degraded: false, healProbeActive: false)
        check(orchOff75.topoffOwned,
              "清理-1", "编排关 ∧ 目标 <80 → topoff 承载（不清理——topoff 不受编排开关门）")
    }

    // ---- ⑤ 汇聚点路由真值表（§3.1 R1-P3）----

    // 路由-1：单通道互斥（sub80 ∧ <80 ∧ !degraded → topoff 独占，编排静默）。
    do {
        let route = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false,
            degraded: false, healProbeActive: false)
        check(route == (convergenceTarget: 75, orchestrationDesired: Int?.none, topoffOwned: true),
              "路由-1", "<80 topoff 承载 → 编排静默 desired=nil（单通道互斥钉死）")
    }

    // 路由-2：降级稳态 → 编排钳 80；自愈观察窗 → 编排静默（topoff 独占）。
    do {
        let steady = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false,
            degraded: true, healProbeActive: false)
        check(steady.orchestrationDesired == 80 && steady.topoffOwned,
              "路由-2", "降级稳态 → 编排钳 80（域随写 80 同值——§3.2 诚实降级）")
        let probing = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false,
            degraded: true, healProbeActive: true)
        check(probing.orchestrationDesired == nil && probing.topoffOwned,
              "路由-2", "自愈观察窗 → 编排静默（topoff 独占执法——行为观察有效前提）")
    }

    // 路由-3：≥80 → 0.19.20 原链逐值（nativeTarget/chargingDisabled 100 窗）。
    do {
        let r85 = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 85, sub80Capable: true, actionActive: false,
            degraded: false, healProbeActive: false)
        check(r85 == (convergenceTarget: 85, orchestrationDesired: 85, topoffOwned: false),
              "路由-3", "≥80 → 编排原样 85（topoffOwned=false——§3.6 域随写卫生由副作用面承接）")
        let r100 = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: true,
            upperLimit: 75, sub80Capable: true, actionActive: false,
            degraded: false, healProbeActive: false)
        check(r100 == (convergenceTarget: 100, orchestrationDesired: 100, topoffOwned: false),
              "路由-3", "chargingDisabled 窗 → 汇聚目标 100（放开充电——topoff 不承载，域随写卫生跟 100）")
    }

    // 路由-4：编排开关门独立性（R1-P3 位置约束）——编排关 ∧ <80 → topoff 仍承载。
    do {
        let route = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: false, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false,
            degraded: false, healProbeActive: false)
        check(route.topoffOwned && route.orchestrationDesired == nil,
              "路由-4", "编排开关关 ∧ 目标 <80 → topoff 仍承载（topoff 同受 mode/actionActive 门、不受编排开关门）")
        let off85 = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: false, chargingDisabledWindow: false,
            upperLimit: 85, sub80Capable: true, actionActive: false,
            degraded: false, healProbeActive: false)
        check(!off85.topoffOwned && off85.orchestrationDesired == nil,
              "路由-4", "编排开关关 ∧ 目标 ≥80 → 编排静默 ∧ topoff 不承载（域随写卫生零触发——§3.7 关断清理态保持，防域值复活）")
    }

    // 路由-5：26 回归（sub80Capable=false → 0.19.20 链逐值 + topoffOwned 恒 false）。
    do {
        let r75 = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: false, actionActive: false,
            degraded: false, healProbeActive: false)
        check(r75.topoffOwned == false && r75.orchestrationDesired == 80,
              "路由-5", "26（无 sub80）∧ <80 → 既有 nativeTarget 钳 80 逐值（topoff 零触及）")
        let r85 = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: false, chargingDisabledWindow: false,
            upperLimit: 85, sub80Capable: false, actionActive: false,
            degraded: false, healProbeActive: false)
        check(r85.orchestrationDesired == nil && r85.topoffOwned == false,
              "路由-5", "26 ∧ 编排关 → desired=nil 逐值（0.19.20 链零变化）")
    }

    // 路由-6：actionActive 执法总开关（topoff 不承载）+ mode 门（关断清理面）。
    do {
        let duringAction = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: true,
            degraded: false, healProbeActive: false)
        check(!duringAction.topoffOwned && duringAction.orchestrationDesired == 80,
              "路由-6", "动作活跃 → topoff 不承载（放电/校准维护分支掌权——执法总开关）；desired 沿既有链（断言由 assertionRequest 规则 2 actionActive → none 压制——0.19.20 语义零变化）")
        let modeOff = Topoff.convergenceRoute(
            modeActive: false, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false,
            degraded: false, healProbeActive: false)
        check(modeOff.convergenceTarget == nil && modeOff.orchestrationDesired == nil && !modeOff.topoffOwned,
              "路由-6", "mode 非 active → 汇聚目标 nil（关断清理面——域随写 100 + off）")
    }
}
