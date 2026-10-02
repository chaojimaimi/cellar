// CellarCoreCheck —— 0.20.2 §3 超带轻量重申场景域（方案 §3 全部；TopoffDomain 既有
// 违规带场景断言已同步 notifyOnly=true 预期内变更，本文件钉四组详表）：
// ①触发带（违规带判据逐字 + 边界 + 非违规拍零触发）
// ②冷却（lastReassertAt fresh nil 恒过 / 5 min 内静默 / ≥5 min 再发；不重置验证窗）
// ③不动降级计数（notifyOnly 拍不重写域值、不动 strikes/violationTicks/20 tick 窗——
//   三套机制并行独立，验证窗满仍走 strike 原路径）
// ④healProbe 窗不触发（观察窗内 / degraded 稳态零轻量重申；healTick 恒不产出 notify）

import CellarCore
import Foundation

/// 0.20.2 §3 轻量重申场景域入口（Main.main 调用）。
func runTopoffReassertDomainScenarios() {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    func tick(_ n: Int) -> Date { t0.addingTimeInterval(Double(n) * 30) }   // 30s tick 节奏

    /// 承载稳态基底（activeTarget/lastWritten 已对齐 target——零写前提）。
    func carrying(target: Int, writeAt: Date? = nil, lastReassertAt: Date? = nil,
                  healProbeActive: Bool = false, degraded: Bool = false) -> TopoffChannelState {
        var s = TopoffChannelState()
        s.activeTarget = target
        s.lastWrittenLimit = target
        s.lastWriteAt = writeAt
        s.lastReassertAt = lastReassertAt
        s.healProbeActive = healProbeActive
        s.degraded = degraded
        return s
    }

    // ---- ① 触发带（判据逐字：percent > target+2 ∧ ext ∧ charging）----

    // 重申-1：违规带内 → notifyOnly=true ∧ writeLimit nil（状态面只动 lastReassertAt）。
    do {
        let plan = Topoff.channelTick(state: carrying(target: 75), target: 75, now: tick(1),
                                      percent: 78, externalConnected: true, isCharging: true)
        check(plan.notifyOnly && plan.writeLimit == nil
                && plan.state.lastReassertAt == tick(1) && plan.state.violationTicks == 1,
              "重申-1", "违规带首拍（78 > 77 ∧ ext ∧ charging）→ notifyOnly=true（域值未动；验证窗照常计数 1）")
        // 边界：percent == target+2 非违规（余量 > 严格）→ 零重申。
        let boundary = Topoff.channelTick(state: carrying(target: 75), target: 75, now: tick(1),
                                          percent: 77, externalConnected: true, isCharging: true)
        check(!boundary.notifyOnly && boundary.writeLimit == nil && boundary.state.violationTicks == 0,
              "重申-1", "percent == target+2（77/75）→ 非违规带 → 不轻量重申（余量边界同 §3.2 判据）")
        // 证据不足臂：ext=false / isCharging=false → 零重申。
        let noExt = Topoff.channelTick(state: carrying(target: 75), target: 75, now: tick(1),
                                       percent: 90, externalConnected: false, isCharging: true)
        let notCharging = Topoff.channelTick(state: carrying(target: 75), target: 75, now: tick(1),
                                             percent: 90, externalConnected: true, isCharging: false)
        check(!noExt.notifyOnly && !notCharging.notifyOnly,
              "重申-1", "ext=false / isCharging=false → 不轻量重申（证据不足——拔电/已停充无重申对象）")
    }

    // ---- ② 冷却（lastReassertAt 簿记；5 min 封顶）----

    // 重申-2：fresh nil 恒过 → 5 min 内静默（violationTicks 照常推进）→ ≥5 min 再发。
    do {
        var s = carrying(target: 75)
        var plans: [TopoffTickPlan] = []
        for n in 1...13 {
            let plan = Topoff.channelTick(state: s, target: 75, now: tick(n),
                                          percent: 90, externalConnected: true, isCharging: true)
            s = plan.state
            plans.append(plan)
        }
        // tick(1)=notify；tick(2..10)（30s..270s < 300s）静默；tick(11)（300s）再发。
        check(plans[0].notifyOnly
                && (2...10).allSatisfy { !plans[$0 - 1].notifyOnly }
                && plans[10].notifyOnly,
              "重申-2", "冷却：fresh nil 恒过 → 首拍发；300s 内静默；≥300s（tick 11）再发——通知风暴 5 min 封顶")
        // 冷却静默拍不重置验证窗：13 拍全违规 → violationTicks 应为 13（无 strike——<20）。
        check(s.violationTicks == 13 && s.strikes == 0,
              "重申-2", "冷却静默拍验证窗照常推进（13 违规拍连计；未到 20 不 strike——两套簿记互不干扰）")
    }

    // ---- ③ 不动降级计数（三套机制并行独立钉死）----

    // 重申-3：19 个 notify/静默违规拍后第 20 拍仍正常 strike（窗计数未被轻量重申扰动）；
    // notifyOnly 拍恒 writeLimit=nil 且不触 lastWriteAt 语义（strike 冷却独立）。
    do {
        var s = carrying(target: 75, writeAt: tick(0))
        var plan: TopoffTickPlan?
        for n in 1...20 {
            plan = Topoff.channelTick(state: s, target: 75, now: tick(n),
                                      percent: 90, externalConnected: true, isCharging: true)
            s = plan!.state
        }
        check(s.strikes == 1 && s.violationTicks == 0 && s.lastViolationAt == tick(20)
                && plan?.writeLimit == 75 && plan?.notifyOnly == false,
              "重申-3", "20 违规拍（含 2 次轻量重申）→ 验证窗满照常 strike + 重申写 75（轻量重申不动 strike 计数——并行独立）")
        check(s.lastWriteAt == tick(0),
              "重申-3", "轻量重申拍不簿记 lastWriteAt（notifyOnly 消费不走域写——strike 重申冷却语义不受污染）")
    }

    // ---- ④ healProbe 窗 / degraded 稳态不触发（R1-P3 防污染探针观察语义）----

    // 重申-4：channelTick 防御门（degraded / healProbeActive 双臂）+ healTick 恒零 notify。
    do {
        let probing = Topoff.channelTick(state: carrying(target: 75, healProbeActive: true),
                                         target: 75, now: tick(1),
                                         percent: 90, externalConnected: true, isCharging: true)
        check(!probing.notifyOnly && probing.state.lastReassertAt == nil,
              "重申-4", "healProbe 观察窗内违规拍 → 不轻量重申（防污染探针行为观察语义——R1-P3）")
        let degradedSteady = Topoff.channelTick(state: carrying(target: 75, degraded: true),
                                                target: 75, now: tick(1),
                                                percent: 90, externalConnected: true, isCharging: true)
        check(!degradedSteady.notifyOnly && degradedSteady.state.lastReassertAt == nil,
              "重申-4", "degraded 稳态（防御臂——daemon 消费层恒走 healTick）→ 不轻量重申（降级稳态无 topoff 执法可重申）")
        // healTick 全路径恒不产出 notifyOnly（探针写 target / 稳态零写 / 恢复 / 超时回稳态）。
        var h = TopoffChannelState()
        h.degraded = true
        h.lastWrittenLimit = 80
        h.activeTarget = 75
        h.lastHealProbeAt = tick(0)
        let probeStart = Topoff.healTick(state: h, target: 75, now: tick(0).addingTimeInterval(Topoff.healProbeInterval),
                                         percent: 90, externalConnected: true, isCharging: true)
        let steady = Topoff.healTick(state: h, target: 75, now: tick(1),
                                     percent: 90, externalConnected: true, isCharging: true)
        let restored = Topoff.healTick(state: {
            var x = h
            x.lastWrittenLimit = 75
            x.healProbeActive = true
            return x
        }(), target: 75, now: tick(2), percent: 75, externalConnected: true, isCharging: false)
        check(!probeStart.notifyOnly && !steady.notifyOnly && !restored.notifyOnly,
              "重申-4", "healTick 探针开窗/稳态/恢复拍恒 notifyOnly=false（轻量重申仅 channelTick 承载态语义）")
    }
}
