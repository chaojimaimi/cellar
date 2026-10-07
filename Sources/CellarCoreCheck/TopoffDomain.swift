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
// ⑦0.20.2 §3 同步：违规带场景断言携带 notifyOnly=true（预期内变更——lastReassertAt
//   fresh nil 冷却恒过；轻量重申四组详表见 TopoffReassertDomain）

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
        // 0.20.2 §3 预期内变更：违规拍首拍（lastReassertAt fresh nil 冷却恒过）→
        // 超带轻量重申 notifyOnly=true（writeLimit 保持 nil——不重写域值）。
        check(idle.writeLimit == nil && idle.state.violationTicks == 1 && idle.notifyOnly
                && idle.state.lastReassertAt == tick(1),
              "通道-1", "幂等：lastWritten == target → 零写；违规拍开始计数（90>77 ∧ 充电中）；0.20.2 §3：违规带首拍轻量重申 notifyOnly=true（lastReassertAt 锚定）")
    }

    // 通道-2：验证窗 20 tick → strike 1 → 重申写（冷却自然满足）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = tick(0)
        var strikePlan: TopoffTickPlan?
        var firstInBandPlan: TopoffTickPlan?
        for n in 1...20 {
            strikePlan = Topoff.channelTick(state: s, target: 75, now: tick(n),
                                            percent: 90, externalConnected: true, isCharging: true)
            if n == 1 { firstInBandPlan = strikePlan }
            s = strikePlan!.state
        }
        check(s.strikes == 1 && s.violationTicks == 0 && s.lastViolationAt == tick(20)
                && strikePlan?.writeLimit == 75,
              "通道-2", "连续 20 违规 tick → strike 1 + 重申写 75（重写即重置动力学；距初写 600s ≥ 冷却）")
        // 0.20.2 §3 预期内变更：窗内非 strike 拍轻量重申（首拍 notifyOnly=true，
        // 冷却 5 min 封顶）；strike 拍自带重申写路径 → notifyOnly=false（机制分离）。
        check(firstInBandPlan?.notifyOnly == true && firstInBandPlan?.writeLimit == nil
                && strikePlan?.notifyOnly == false,
              "通道-2", "0.20.2 §3：窗内首拍 notifyOnly=true（提前重发信号）；strike 拍 notifyOnly=false（重申写自带通知——三套机制并行独立）")
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
        check(plan.writeLimit == nil && plan.state.violationTicks == 0 && !plan.notifyOnly,
              "通道-6", "采样缺席（nil 入参）→ 窗不推进（防误降级）；0.20.2 §3：无违规带证据 → 不轻量重申")
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

    // 自愈-4（0.22.0 §4.1 外接电源门）：电池态到期拍不启动探针、lastHealProbeAt
    // 不推进（不消耗 due）——插电后首拍即探。
    do {
        var s = TopoffChannelState()
        s.degraded = true
        s.lastWrittenLimit = 80
        s.activeTarget = 75
        s.lastHealProbeAt = tick(0)
        let dueOnBattery = Topoff.healTick(state: s, target: 75, now: tick(0).addingTimeInterval(Topoff.healProbeInterval),
                                           percent: 50, externalConnected: false, isCharging: false)
        check(dueOnBattery.writeLimit == nil && !dueOnBattery.state.healProbeActive
                && dueOnBattery.state.lastHealProbeAt == tick(0),
              "自愈-4", "电池态到期 → 门拦（nil plan 不启动；lastHealProbeAt 不推进——违规/证据判定均要求外接）")
        // 时刻继续前移（门内 due 持续成立），仍不启动——证明「不消耗 due」。
        let later = Topoff.healTick(state: dueOnBattery.state, target: 75,
                                    now: tick(0).addingTimeInterval(Topoff.healProbeInterval + 600),
                                    percent: 50, externalConnected: false, isCharging: false)
        check(later.writeLimit == nil && !later.state.healProbeActive
                && later.state.lastHealProbeAt == tick(0),
              "自愈-4", "电池态续拍 → 仍不启动（due 未被消耗，门独立于到期判定）")
        // 插电后首拍即探（lastHealProbeAt 重锚 + 域写 target + 观察窗开）。
        let plugged = Topoff.healTick(state: dueOnBattery.state, target: 75,
                                      now: tick(0).addingTimeInterval(Topoff.healProbeInterval + 660),
                                      percent: 50, externalConnected: true, isCharging: true)
        check(plugged.writeLimit == 75 && plugged.state.healProbeActive
                && plugged.state.lastHealProbeAt == tick(0).addingTimeInterval(Topoff.healProbeInterval + 660),
              "自愈-4", "插电首拍 → 即探（探针启动 + lastHealProbeAt 重锚——降级期电池使用的空转根治）")
    }

    // 自愈-5（0.22.0 §4.1，评审 P2-4）：nil 采样缺席态到期拍同样不启动
    //（externalConnected nil 与 false 同门——采样缺席不猜测电源态）。
    do {
        var s = TopoffChannelState()
        s.degraded = true
        s.lastWrittenLimit = 80
        s.activeTarget = 75
        s.lastHealProbeAt = tick(0)
        let dueNilSample = Topoff.healTick(state: s, target: 75, now: tick(0).addingTimeInterval(Topoff.healProbeInterval),
                                           percent: nil, externalConnected: nil, isCharging: nil)
        check(dueNilSample.writeLimit == nil && !dueNilSample.state.healProbeActive
                && dueNilSample.state.lastHealProbeAt == tick(0),
              "自愈-5", "nil 采样缺席态到期 → 门拦（不启动不推进——decodeIfPresent nil 零触及）")
    }

    // 自愈-6（0.22.0 §4.1 观察窗语义回归零变化）：观察窗中拔电不走门——窗照常
    // 推进（弱信号拍计数），20 tick 无差别超时臂照常收尾（补写 degradedLimit）。
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
                                   percent: 75, externalConnected: false, isCharging: false)
            s = plan!.state
        }
        check(!s.healProbeActive && plan?.writeLimit == 80 && s.degraded,
              "自愈-6", "观察窗中拔电 → 门不适用（窗照常推进 + 超时臂收尾补写 80——最小改动不扩权）")
    }

    // ---- ⑤b §3.7 关断清理状态不变量（P3-3 场景钉死——路由前置条件面；0.23.1 翻新）----

    // 清理-1：daemon 关断清理分支的触发前置（纯函数可钉面）——**仅 mode 非 active**
    //（0.23.1 编排退役定版：域承载全区间即新常态——mode active 期 ≥80 一律 owned
    // 域随写 target 执法，永不清理；编排开关入参随批删除）。daemon 侧按此消费
    //（CellarCoreCheck 不可 import daemon，调用点次序由 daemon 注记 + code-review
    // 走查兜底）。
    do {
        let modeNil = Topoff.convergenceRoute(
            modeActive: false, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false)
        check(modeNil.convergenceTarget == nil && !modeNil.topoffOwned,
              "清理-1", "mode 非 active → 清理前置成立（域随写 100 + off）")
        let modeNil85 = Topoff.convergenceRoute(
            modeActive: false, chargingDisabledWindow: false,
            upperLimit: 85, sub80Capable: true, actionActive: false)
        check(modeNil85.convergenceTarget == nil && !modeNil85.topoffOwned,
              "清理-1", "mode 非 active ∧ 85 → 清理前置成立（mode 门最优先——域承载不触及）")
        let owned75 = Topoff.convergenceRoute(
            modeActive: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false)
        check(owned75.topoffOwned,
              "清理-1", "目标 <80 → topoff 承载（不清理——mode active 域承载全区间）")
        let owned85 = Topoff.convergenceRoute(
            modeActive: true, chargingDisabledWindow: false,
            upperLimit: 85, sub80Capable: true, actionActive: false)
        check(owned85.topoffOwned && owned85.convergenceTarget == 85,
              "清理-1", "目标 85 → **域承载全区间（0.23.1 新常态）**（owned——旧清理前置臂废除；violation/strike/degraded 链生效）")
    }

    // ---- ⑤ 汇聚点路由真值表（§3.1；0.23.1 编排退役翻新——desired 推导链删除，
    // 路由收敛为「汇聚目标 + 承载判定」两输出）----

    // 路由-1：<80 topoff 承载（域执法原臂）。
    do {
        let route = Topoff.convergenceRoute(
            modeActive: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false)
        check(route == (convergenceTarget: 75, topoffOwned: true),
              "路由-1", "<80 topoff 承载（域通道独占执法——单通道语义钉死）")
    }

    // 路由-2：降级/自愈态不再参与路由分支（**0.23.1**：原「降级稳态 → 编排钳 80 /
    // 自愈观察窗 → 编排静默」desired 分支随断言链退役删除——degraded/healProbe
    // 是 channelTick/healTick 状态机内部态，路由面已无感知）。
    do {
        let route = Topoff.convergenceRoute(
            modeActive: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false)
        check(route.topoffOwned && route.convergenceTarget == 75,
              "路由-2", "路由签名收敛：degraded/healProbe 输入删除（0.23.1——降级/自愈链由 channelTick/healTick 状态机承担，路由面恒 owned <80）")
    }

    // 路由-3：≥80 域承载（**0.23.1 domainBackstop 新语义**——原「编排开 ∧ ≥80 →
    // 编排原样」分支删除，domainBackstop 的 `!orchestrationEnabled` 前置项删除）；
    // chargingDisabled 100 窗保留（窗排除原样）。
    do {
        let r85 = Topoff.convergenceRoute(
            modeActive: true, chargingDisabledWindow: false,
            upperLimit: 85, sub80Capable: true, actionActive: false)
        check(r85 == (convergenceTarget: 85, topoffOwned: true),
              "路由-3", "≥85 → owned（域承载全区间——§3.6 卫生臂随写 target + 执法链生效）")
        let r100 = Topoff.convergenceRoute(
            modeActive: true, chargingDisabledWindow: true,
            upperLimit: 75, sub80Capable: true, actionActive: false)
        check(r100 == (convergenceTarget: 100, topoffOwned: false),
              "路由-3", "chargingDisabled 窗 → 汇聚目标 100（放开充电——topoff 不承载，域随写卫生跟 100；窗排除保留）")
    }

    // 路由-4：fullOnce 窗排除（R1-P1-1，0.23.1 保留）——窗内不进 owned（窗覆盖
    // 优先；窗后回落域承载/卫生分支）。
    do {
        let windowed = Topoff.convergenceRoute(
            modeActive: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false, fullOnceWindow: true)
        check(!windowed.topoffOwned && windowed.convergenceTarget == 100,
              "路由-4", "fullOnce 窗 ∧ 75 → 汇聚目标强制 100 ∧ 不进 owned（窗语义即完全放开——域随写 100）")
    }

    // 路由-5：26 回归（sub80Capable=false → topoffOwned 恒 false——0.23.1 语义下
    // 26 仍零触及，红线锚）。
    do {
        let r75 = Topoff.convergenceRoute(
            modeActive: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: false, actionActive: false)
        check(r75.topoffOwned == false && r75.convergenceTarget == 75,
              "路由-5", "26（无 sub80）∧ <80 → topoff 零触及（owned 恒 false——26 红线锚）")
        let r85 = Topoff.convergenceRoute(
            modeActive: true, chargingDisabledWindow: false,
            upperLimit: 85, sub80Capable: false, actionActive: false)
        check(r85.topoffOwned == false && r85.convergenceTarget == 85,
              "路由-5", "26 ∧ 85 → topoff 零触及（sub80 门内恒 false——26 红线锚）")
    }

    // 路由-6：actionActive 执法总开关（topoff 不承载）+ mode 门（关断清理面）。
    do {
        let duringAction = Topoff.convergenceRoute(
            modeActive: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: true)
        check(!duringAction.topoffOwned && duringAction.convergenceTarget == 75,
              "路由-6", "动作活跃 → topoff 不承载（放电/校准维护分支掌权——执法总开关）")
        let modeOff = Topoff.convergenceRoute(
            modeActive: false, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false)
        check(modeOff.convergenceTarget == nil && !modeOff.topoffOwned,
              "路由-6", "mode 非 active → 汇聚目标 nil（关断清理面——域随写 100 + off）")
    }

    // ---- ⑥ 0.21.2 §3.2 strike 边沿信号（TopoffTickPlan.strikeFired——0.23.0 退役版）----
    // R1-P0 接线层盲区根治：验证窗满拍 violationTicks 即归零（先于 topoff tick 的
    // 观测点可见最大 19，「≥20 判据」按字面接线永不触发）——显式边沿信号取代。
    // **0.23.0 自动放电自动机退役**：strikeFired 产出语义保留（降级拍信号不变，
    // 本节 边沿-1/2/3 照旧钉面）；原唯一下游消费者（StrikeEdgeLatch 边沿锁存 +
    // strikeAccompaniment 伴随判定，原 边沿-4/5/6 场景）随批退役删除——边沿暂无人
    // 消费（无害），头注措辞随批改写（「供自动放电消费」过时）。

    // 边沿-1：channelTick strike 拍置位 + 单拍有效——窗内 19 拍恒 false、第 20 拍
    // （strikes 递增拍）true；非违规拍/幂等写拍/采样缺席拍恒 false。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = tick(0)
        var windowPlans: [TopoffTickPlan] = []
        for n in 1...20 {
            let plan = Topoff.channelTick(state: s, target: 75, now: tick(n),
                                          percent: 90, externalConnected: true, isCharging: true)
            windowPlans.append(plan)
            s = plan.state
        }
        check(windowPlans.prefix(19).allSatisfy { !$0.strikeFired }
                && windowPlans[19].strikeFired && windowPlans[19].state.strikes == 1,
              "边沿-1", "验证窗：19 拍无边沿 → 第 20 拍（strike 拍）strikeFired=true（单拍有效——strikes 递增拍置位）")
        let idle = Topoff.channelTick(state: s, target: 75, now: tick(21),
                                      percent: 90, externalConnected: true, isCharging: true)
        check(!idle.strikeFired && idle.state.strikes == 1,
              "边沿-1", "strike 后续拍（违规带内）无边沿——单拍有效不跨拍")
        let absent = Topoff.channelTick(state: s, target: 75, now: tick(22),
                                        percent: nil, externalConnected: nil, isCharging: nil)
        check(!absent.strikeFired, "边沿-1", "采样缺席拍恒无边沿")
    }

    // 边沿-2：第 3 strike（降级拍）strikeFired=true 且 degraded=true **同拍**——
    // 边沿在档但消费侧 !degraded 门拦截（「第 3 边沿不放电」的模型侧依据）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        var degradePlan: TopoffTickPlan?
        for w in 0..<3 {
            s.lastWriteAt = tick(w * 25)
            for n in 1...20 {
                degradePlan = Topoff.channelTick(state: s, target: 75, now: tick(w * 25 + n),
                                                 percent: 90, externalConnected: true, isCharging: true)
                s = degradePlan!.state
                if degradePlan!.writeLimit != nil {
                    s.lastWrittenLimit = degradePlan!.writeLimit; s.lastWriteAt = tick(w * 25 + n)
                }
            }
        }
        check(degradePlan?.strikeFired == true && s.degraded && s.strikes == 3,
              "边沿-2", "降级拍：strikeFired=true ∧ degraded=true 同拍置位（消费侧 !degraded 拦截臂的输入形态）")
    }

    // 边沿-3：healTick 恒无 strike 边沿（稳态等待拍/探针开窗拍/观察窗拍/自愈失败拍/
    // 恢复拍——strikes 只在 channelTick 递增；「degraded·healTick 无边不触发」模型侧）。
    do {
        var steady = TopoffChannelState()
        steady.degraded = true
        steady.lastWrittenLimit = 80
        steady.activeTarget = 75
        steady.lastHealProbeAt = tick(0)
        let waiting = Topoff.healTick(state: steady, target: 75, now: tick(1),
                                      percent: 90, externalConnected: true, isCharging: true)
        let probe = Topoff.healTick(state: steady, target: 75, now: tick(0).addingTimeInterval(Topoff.healProbeInterval),
                                    percent: 90, externalConnected: true, isCharging: true)
        var probing = probe.state
        probing.lastWrittenLimit = 75
        let observing = Topoff.healTick(state: probing, target: 75, now: tick(1),
                                        percent: 90, externalConnected: true, isCharging: true)
        let restored = Topoff.healTick(state: probing, target: 75, now: tick(1),
                                       percent: 75, externalConnected: true, isCharging: false)
        check(!waiting.strikeFired && !probe.strikeFired && !observing.strikeFired && !restored.strikeFired,
              "边沿-3", "healTick 全臂（等待/开窗/观察/恢复）恒无 strike 边沿")
    }
}
