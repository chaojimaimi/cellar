// CellarCoreCheck —— 0.22.3「锁存持续性与周期读回」场景域（方案 §6 清单）
//
// 覆盖清单（方案 §6 钉死项）：
// ① 释放持续性 ≥3（持-1..3）：锁存 ∧ 单次一致 → 仍锁存；连续两次 → 释放；
//    一致后签名 → streak 清零仍锁存
// ② 瞬态守卫 ≥2（守-1..3）：守卫窗内一致 → 不计不减；窗外/lastWriteAt 缺席 → 计
// ③ 确认拍 ≥2（确-1..3）：未锁存签名 → pending 置位；锁存签名不置位（负臂）；
//    消费循环（daemon 读+清位模拟）→ 两拍内锁存形成
// ④ 周期到期 ≥3（期-0..3）：同源别名钉死；nil → due；599s → 非；600s → due
// ⑤ 失速 ≥6（失-1..8）：四重置 + 无锚点立 + 龄到∧不降 → due + 下降刷新 + 触发拍
//    刷新封顶
// ⑥ healTick degraded 簿记 ≥2（heal-1..2）；未锁存一致全清 ≥1（全清-1）；
//    nil readback 不动 streak ≥1（nil-1）；stallConsistentCount 升级 ≥1（warn-1）
// ⑦ doctor 行为启发（doc-1..3）：触发 + 排除矩阵 + snapshot 缺席
//
// 全部纯函数面（直接构造），不触碰真实 plist、不起 daemon。

import CellarCore
import Foundation

/// 0.22.3 §1-§4 场景域入口（Main.main 调用）。
func runTopoffLatchDomainScenarios() {
    let t0 = Date(timeIntervalSince1970: 4_000_000)
    func tick(_ n: Int) -> Date { t0.addingTimeInterval(Double(n) * 30) }   // 30s tick 节奏

    /// 锁存态基底（count=2 已锁存、lastWriteAt 可调）。
    func latched(lastWriteAt: Date, streak: Int = 0) -> TopoffChannelState {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = lastWriteAt
        s.suppressionConsecutive = 2
        s.suppressionConsistentStreak = streak
        return s
    }

    // ---- ① 释放持续性（方案 §1）----

    // 持-1：锁存 ∧ 守卫窗外单次一致 → 仍锁存（streak=1、count 保持 2、不重写）。
    do {
        let plan = Topoff.channelTick(
            state: latched(lastWriteAt: tick(0)), target: 75, now: tick(5),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 75, featureState: 1))
        check(plan.state.suppressionConsecutive == 2
                && plan.state.suppressionConsistentStreak == 1
                && plan.writeLimit == nil,
              "持-1", "锁存 ∧ 守卫窗外单次一致 → 仍锁存 streak=1（单次一致虚假释放根治）")
    }

    // 持-2：连续第二次一致（两拍均过守卫窗）→ 释放（count=0、streak=0）。
    do {
        let first = Topoff.channelTick(
            state: latched(lastWriteAt: tick(0)), target: 75, now: tick(5),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 75, featureState: 1))
        check(first.state.suppressionConsistentStreak == 1
                && first.state.suppressionConsecutive == 2,
              "持-2", "连续一致第一拍 → streak=1 保持锁存")
        let second = Topoff.channelTick(
            state: first.state, target: 75, now: tick(6),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 75, featureState: 1))
        check(second.state.suppressionConsecutive == 0
                && second.state.suppressionConsistentStreak == 0
                && second.state.suppressionConsecutive < Topoff.suppressionThreshold,
              "持-2", "连续两次一致 → 释放（suppressionConsecutive=0、streak=0——锁存解除唯一路径）")
    }

    // 持-3：一致后签名命中 → streak 清零、计数照旧 +1（仍锁存）。
    do {
        let consistent = Topoff.channelTick(
            state: latched(lastWriteAt: tick(0)), target: 75, now: tick(5),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 75, featureState: 1))
        let override = Topoff.channelTick(
            state: consistent.state, target: 75, now: tick(6),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 100, featureState: 0))
        check(override.state.suppressionConsistentStreak == 0
                && override.state.suppressionConsecutive == 3
                && override.state.suppressionConsecutive >= Topoff.suppressionThreshold,
              "持-3", "一致后签名命中 → streak 清零计数照旧（一致性证据被打断——仍锁存）")
    }

    // ---- ② 瞬态守卫（方案 §1 评审 P2-1 采纳）----

    // 守-1：守卫窗内一致（30s < 120s）→ 不计不减（streak 0 不动、count 2 不动）。
    do {
        let plan = Topoff.channelTick(
            state: latched(lastWriteAt: tick(0)), target: 75, now: tick(1),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 75, featureState: 1))
        check(plan.state.suppressionConsecutive == 2
                && plan.state.suppressionConsistentStreak == 0,
              "守-1", "守卫窗内一致（30s）→ 不计不减（读到自己的重写无证据——10:19 形态排除）")
    }

    // 守-2：恰 120s 边界 → 守卫已过（≥ 判定）→ 计证据 streak=1。
    do {
        let plan = Topoff.channelTick(
            state: latched(lastWriteAt: tick(0)), target: 75, now: tick(4),   // 120s
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 75, featureState: 1))
        check(plan.state.suppressionConsistentStreak == 1,
              "守-2", "恰 120s 边界 → 守卫已过计证据（≥ 判定语义钉面）")
    }

    // 守-3：lastWriteAt 缺席（fresh/重启形态）→ 守卫视为已过 → 计证据。
    do {
        var s = latched(lastWriteAt: tick(0))
        s.lastWriteAt = nil
        let plan = Topoff.channelTick(
            state: s, target: 75, now: tick(1),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 75, featureState: 1))
        check(plan.state.suppressionConsistentStreak == 1,
              "守-3", "lastWriteAt 缺席 → 守卫视为已过（无重写瞬态窗可读——计证据）")
    }

    // ---- ③ 确认拍（方案 §2 臂 4）----

    // 确-1：未锁存签名命中 → pendingSuppressionConfirmation 置位（纯函数置态——
    // 下一拍 daemon 必读，30s 内完成「连续两次」锁存判定）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = tick(0)
        let plan = Topoff.channelTick(
            state: s, target: 75, now: tick(1),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 100, featureState: 0))
        check(plan.state.suppressionConsecutive == 1
                && plan.state.pendingSuppressionConfirmation,
              "确-1", "未锁存签名命中 → 确认拍置位（count=1——下一拍必读）")
    }

    // 确-2（负臂）：锁存态签名命中 → 不置位（臂 ① 锁存期补采样已逐拍读——无需加速）。
    do {
        let plan = Topoff.channelTick(
            state: latched(lastWriteAt: tick(0)), target: 75, now: tick(1),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 100, featureState: 0))
        check(plan.state.suppressionConsecutive == 3
                && !plan.state.pendingSuppressionConfirmation,
              "确-2", "锁存态签名命中 → 确认拍不置位（锁存期补采样逐拍覆盖）")
    }

    // 确-3：确认拍消费循环（daemon 读+清位模拟）——tick N 未锁存签名（pending 置位、
    // count=1）→ daemon 读回并清位 → tick N+1 注入读回：仍签名 → count=2 锁存形成
    // 且 pending 保持 false（锁存拍不置位）；一致 → 两计数全清不误锁。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = tick(0)
        let hit = Topoff.channelTick(
            state: s, target: 75, now: tick(1),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 100, featureState: 0))
        check(hit.state.pendingSuppressionConfirmation && hit.writeLimit == 75,
              "确-3", "tick N 未锁存签名 → pending 置位 + 重写 75")
        // daemon 模拟：读回（臂 ④）→ pending 清位 + lastWritten/lastWriteAt 回填。
        var consumed = hit.state
        consumed.pendingSuppressionConfirmation = false
        consumed.lastWrittenLimit = 75
        consumed.lastWriteAt = tick(1)
        let confirmed = Topoff.channelTick(
            state: consumed, target: 75, now: tick(2),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 100, featureState: 0))
        check(confirmed.state.suppressionConsecutive == 2
                && confirmed.state.suppressionConsecutive >= Topoff.suppressionThreshold
                && !confirmed.state.pendingSuppressionConfirmation,
              "确-3", "确认拍读回仍签名 → 两拍内锁存形成（30s 加速判定兑现）且 pending 保持 false")
        let cleared = Topoff.channelTick(
            state: consumed, target: 75, now: tick(2),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 75, featureState: 1))
        check(cleared.state.suppressionConsecutive == 0
                && cleared.state.suppressionConsistentStreak == 0
                && !cleared.state.pendingSuppressionConfirmation,
              "确-3", "确认拍读回一致 → 两计数全清（误报自愈——无锁存无确认拍）")
    }

    // ---- ④ 周期到期（方案 §2 臂 3）----

    // 期-0：别名同源钉死（评审 P2-4——读回节奏 = 重写限频节奏，防双常量漂移）。
    expectEqual(Topoff.periodicReadbackInterval, Topoff.reassertionCooldown,
                "期-0", "periodicReadbackInterval 引用 reassertionCooldown 同源")
    // 期-1：nil（从未读过）→ due（首拍即读——重启即最便宜对账）。
    check(Topoff.periodicReadbackDue(last: nil, now: tick(1)),
          "期-1", "lastPeriodicReadbackAt nil → due（远古首拍即读）")
    // 期-2：599s → 非 due；期-3：600s → due（≥ 边界钉面）。
    check(!Topoff.periodicReadbackDue(last: tick(0), now: tick(0).addingTimeInterval(599)),
          "期-2", "599s < periodicReadbackInterval → 非 due")
    check(Topoff.periodicReadbackDue(last: tick(0), now: tick(0).addingTimeInterval(600)),
          "期-3", "600s == periodicReadbackInterval → due（≥ 边界）")

    // ---- ⑤ 失速检测（方案 §3）----

    func stall(anchor: TopoffStallAnchor?, ext: Bool? = true, charging: Bool? = false,
               owned: Bool = true, percent: Int, target: Int = 75, n: Int)
        -> (anchor: TopoffStallAnchor?, stallDue: Bool) {
        Topoff.stallTick(anchor: anchor, owned: owned, percent: percent, target: target,
                         externalConnected: ext, isCharging: charging, now: tick(n))
    }
    let seeded = TopoffStallAnchor(percent: 90, at: tick(0))

    // 失-1..4：四重置条件（任一 → 锚点清空）。
    check(stall(anchor: seeded, ext: false, percent: 90, n: 1).anchor == nil,
          "失-1", "!ext → 锚点重置（拔电非失速语义）")
    check(stall(anchor: seeded, charging: true, percent: 90, n: 1).anchor == nil,
          "失-2", "isCharging → 锚点重置（充电中 = 行为在跟随）")
    check(stall(anchor: seeded, percent: 76, n: 1).anchor == nil,
          "失-3", "percent 76 < target+2 → 锚点重置（violating 带外——violation 链管辖）")
    check(stall(anchor: seeded, owned: false, percent: 90, n: 1).anchor == nil,
          "失-4", "!owned → 锚点重置（通道未承载——非 topoff 语义）")

    // 失-5：无锚点 → 立 (percent, now)，非 due。
    do {
        let (anchor, due) = stall(anchor: nil, percent: 90, n: 1)
        check(!due && anchor == TopoffStallAnchor(percent: 90, at: tick(1)),
              "失-5", "无锚点 → 立 (90, tick1) 且非 due（观测起点）")
    }

    // 失-6：龄到 1800s ∧ percent 不降 → due + 触发拍刷新锚点（30 min 节奏封顶）。
    do {
        let (anchor, due) = stall(anchor: seeded, percent: 90, n: 60)   // 1800s
        check(due && anchor == TopoffStallAnchor(percent: 90, at: tick(60)),
              "失-6", "龄 ≥30 min ∧ 不降 → due ∧ 锚点刷新 (90, tick60)（防每 30s 复读风暴）")
    }

    // 失-7：percent 下降 → 刷新锚点、非 due（合法回落恒可辨）。
    do {
        let (anchor, due) = stall(anchor: seeded, percent: 84, n: 40)   // 1200s 龄
        check(!due && anchor == TopoffStallAnchor(percent: 84, at: tick(40)),
              "失-7", "percent 90→84 下降 → 锚点刷新 (84, tick40) 非 due（合法回落）")
    }

    // 失-8：触发拍刷新封顶——刷新后 30s 同 percent → 非 due（节奏封顶兑现）。
    do {
        let (refreshed, due1) = stall(anchor: seeded, percent: 90, n: 60)
        check(due1, "失-8", "前置：首触发拍 due")
        let (_, due2) = stall(anchor: refreshed, percent: 90, n: 61)    // +30s
        check(!due2, "失-8", "触发拍刷新后 30s 同 percent → 非 due（复读风暴封顶）")
    }

    // ---- ⑥ healTick degraded 簿记 / 未锁存全清 / nil readback / WARN 计数 ----

    // heal-1：degraded 稳态 ∧ 签名命中 → suppressionConsecutive 计数（两拍 → 锁存
    // ——wire 恢复可见 → App 恢复链降级态同样可点火）；80 钳/探针语义零变化。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 80
        s.lastWrittenLimit = 80
        s.degraded = true
        s.lastHealProbeAt = tick(0)   // 稳态未到期——本拍探针不动
        let first = Topoff.healTick(
            state: s, target: 80, now: tick(1),
            percent: 85, externalConnected: true, isCharging: false,
            domainReadback: (limit: 100, featureState: 0))
        check(first.state.suppressionConsecutive == 1 && !first.state.healProbeActive
                && first.writeLimit == nil,
              "heal-1", "degraded 签名命中 → 计数 +1（探针不动 writeLimit nil——仅簿记）")
        let second = Topoff.healTick(
            state: first.state, target: 80, now: tick(2),
            percent: 85, externalConnected: true, isCharging: false,
            domainReadback: (limit: 100, featureState: 0))
        check(second.state.suppressionConsecutive == 2
                && second.state.suppressionConsecutive >= Topoff.suppressionThreshold,
              "heal-1", "degraded 第二拍签名命中 → 锁存（wire 可见——降级态恢复链可点火）")
    }

    // heal-2：degraded 锁存释放同样需持续一致（§1 streak 语义同源——守卫窗外
    // 两拍一致 → 释放）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 80
        s.lastWrittenLimit = 80
        s.degraded = true
        s.suppressionConsecutive = 2
        s.lastWriteAt = tick(0)
        let first = Topoff.healTick(
            state: s, target: 80, now: tick(5),
            percent: 80, externalConnected: true, isCharging: false,
            domainReadback: (limit: 80, featureState: 1))
        check(first.state.suppressionConsecutive == 2
                && first.state.suppressionConsistentStreak == 1,
              "heal-2", "degraded 锁存 ∧ 首次一致 → streak=1 保持锁存（§1 语义同源）")
        let second = Topoff.healTick(
            state: first.state, target: 80, now: tick(6),
            percent: 80, externalConnected: true, isCharging: false,
            domainReadback: (limit: 80, featureState: 1))
        check(second.state.suppressionConsecutive == 0
                && second.state.suppressionConsistentStreak == 0,
              "heal-2", "degraded 连续第二次一致 → 释放（降级态锁存释放同判据）")
    }

    // 全清-1：未锁存一致 → 两计数全清（streak 仅锁存期有意义——简化）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = tick(0)
        s.suppressionConsecutive = 1
        s.suppressionConsistentStreak = 1   // 陈旧 streak（历史锁存遗留）
        let plan = Topoff.channelTick(
            state: s, target: 75, now: tick(1),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 75, featureState: 1))
        check(plan.state.suppressionConsecutive == 0
                && plan.state.suppressionConsistentStreak == 0,
              "全清-1", "未锁存一致 → 两计数全清（未锁存无「释放」概念）")
    }

    // nil-1：nil readback（读失败）→ streak 与 suppressionConsecutive 均不动。
    do {
        let plan = Topoff.channelTick(
            state: latched(lastWriteAt: tick(0), streak: 1), target: 75, now: tick(5),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: nil)
        check(plan.state.suppressionConsecutive == 2
                && plan.state.suppressionConsistentStreak == 1,
              "nil-1", "nil readback → 两计数均不动（失败不构成任何证据——fail-open）")
    }

    // warn-1：失速一致读回计数推进——连续 2 次一致 → 达升级阈值；签名命中 → 归零。
    do {
        check(Topoff.stallConsistentCountNext(current: 1, overridden: false)
                >= Topoff.stallConsistentWarnThreshold,
              "warn-1", "失速 ∧ 连续 2 次一致 → 计数达升级阈值（persistLog WARN 数据面）")
        check(Topoff.stallConsistentCountNext(current: 3, overridden: true) == 0,
              "warn-1", "失速读回签名命中 → 计数归零（成因 = 机制关闭，交重写自愈链）")
    }

    // ---- ⑦ doctor 行为启发（方案 §4）----

    func doctorStatus(
        upperLimit: Int = 75, sub80State: Sub80State? = .active,
        hysteresis: Bool? = nil, fullOnce: Bool? = nil, scheduleWindow: Bool? = nil
    ) -> DaemonStatus {
        DaemonStatus(
            version: "t", mode: "active", upperLimit: upperLimit, hysteresis: 2,
            capabilities: ["orchestration", DaemonXPC.capabilitySub80],
            orchestration: OrchestrationStatus(enabled: false),   // 0.23.1 退役照填（enabled 数据源硬编码 false）
            sub80State: sub80State, sub80Hysteresis: hysteresis,
            fullOnceWindowActive: fullOnce, chargingDisabledWindowActive: scheduleWindow,
            timestamp: tick(0))
    }
    func note(snapshot: BatterySnapshot?, status: DaemonStatus) -> String {
        DoctorReportGenerator.generate(DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .noneAvailable, chargingEnabled: nil, chargingError: nil,
            snapshot: snapshot, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            daemonStatus: status, daemonProbeAttempted: true,
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil),
            mclProbeAttempted: true,
            osMajorVersion: 27
        )).checks.first { $0.name == "关断残留" }?.detail ?? ""
    }
    func batterySnapshot(percent: Int, charging: Bool, ext: Bool) -> BatterySnapshot {
        var props = batteryProps()
        props["CurrentCapacity"] = percent
        props["IsCharging"] = charging
        props["ExternalConnected"] = ext
        return try! BatterySnapshotParser.parse(props, timestamp: tick(0))
    }

    // doc-1：触发臂——死寂态（未充电 ∧ 外接 ∧ 94 ≥ 75+3 ∧ 无窗/无降级/无迟滞）→
    // 附注文案在位；检查 status 保持 pass（附注不影响退出码——方案 §4 钉死）。
    do {
        let status = doctorStatus()
        let inputs = DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .noneAvailable, chargingEnabled: nil, chargingError: nil,
            snapshot: batterySnapshot(percent: 94, charging: false, ext: true),
            snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            daemonStatus: status, daemonProbeAttempted: true,
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil),
            mclProbeAttempted: true,
            osMajorVersion: 27
        )
        let checkRow = DoctorReportGenerator.generate(inputs).checks.first { $0.name == "关断残留" }
        check(checkRow?.status == .pass
                && checkRow?.detail.contains("行为启发") == true
                && checkRow?.detail.contains("电量 94% 高于上限 75%") == true
                && checkRow?.detail.contains("FAQ Q16") == true,
              "doc-1", "死寂态 → 行为启发附注在位（MCL 100 == 期望 100 pass 臂共存）且检查保持 pass（退出码零影响）")
        // 附注不抬退出码（unit 面 = 检查 status 保持 pass——上方已断言；此处整报告
        // 退出码带附注/不带附注**相等**（mock 输入下其余检查含无关 FAIL，取等值
        // 而非绝对 0——「若持续 ≥30 min」启发声非硬判）。
        let exitWithout = DoctorReportGenerator.generate(DoctorInputs(
            isRoot: true, smcConnected: true, probe: .noneAvailable,
            chargingEnabled: nil, chargingError: nil,
            snapshot: batterySnapshot(percent: 74, charging: false, ext: true),
            snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            daemonStatus: status, daemonProbeAttempted: true,
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil),
            mclProbeAttempted: true, osMajorVersion: 27)).exitCode
        let exitWith = DoctorReportGenerator.generate(inputs).exitCode
        check(exitWithout == exitWith,
              "doc-1", "附注前后整报告退出码不变（附注不改检查 status——启发声非硬判）")
    }

    // doc-2：排除矩阵——isCharging / 未越 +3 带 / 降级驻留 / 迟滞带 / 两窗任一。
    do {
        let status = doctorStatus()
        check(!note(snapshot: batterySnapshot(percent: 94, charging: true, ext: true),
                    status: status).contains("行为启发"),
              "doc-2", "isCharging=true → 不触发（充电中行为正常）")
        check(!note(snapshot: batterySnapshot(percent: 77, charging: false, ext: true),
                    status: status).contains("行为启发"),
              "doc-2", "percent 77 < 75+3 → 不触发（带内驻留）")
        check(!note(snapshot: batterySnapshot(percent: 94, charging: false, ext: true),
                    status: doctorStatus(sub80State: .degraded)).contains("行为启发"),
              "doc-2", "sub80State=degraded → 不触发（降级 80 驻留合法态）")
        check(!note(snapshot: batterySnapshot(percent: 94, charging: false, ext: true),
                    status: doctorStatus(hysteresis: true)).contains("行为启发"),
              "doc-2", "sub80Hysteresis=true → 不触发（CHIE 迟滞带驻留合法态）")
        check(!note(snapshot: batterySnapshot(percent: 94, charging: false, ext: true),
                    status: doctorStatus(fullOnce: true)).contains("行为启发"),
              "doc-2", "fullOnce 窗在位 → 不触发（显式放开意图）")
        check(!note(snapshot: batterySnapshot(percent: 94, charging: false, ext: true),
                    status: doctorStatus(scheduleWindow: true)).contains("行为启发"),
              "doc-2", "chargingDisabled 日程窗在位 → 不触发（显式放开意图）")
        check(!note(snapshot: batterySnapshot(percent: 94, charging: false, ext: false),
                    status: status).contains("行为启发"),
              "doc-2", "!ext → 不触发（电池供电回落自由）")
    }

    // doc-3：snapshot 缺席（检查 5 失败形态）→ 零附注（诚实缺席）。
    do {
        check(!note(snapshot: nil, status: doctorStatus()).contains("行为启发"),
              "doc-3", "snapshot nil → 零附注（数据面缺席不猜测）")
    }
}
