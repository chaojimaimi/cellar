// CellarCoreCheck —— Phase 5 v1.8 M1 MagSafe LED 模型层场景域（方案 §2 清单）
//
// 覆盖清单（方案 §2 + M1 工单）：
// ① validating 白名单穷举：四值各一 / 越界 2/5/255 / nil 缺席
// ② interpreting：四值各一 + 0x02/0xFF 他写信号（通道 A 值域判据输入）
// ③ correctionDecision 矩阵穷举（重点 ≥10 条）：门槛三行（system/!modeActive/
//    unsupported·undecided）/.idle 计数器保留/未锁存期望回读 streak 累积/未读过
//    nil 无凭据/外来合法值计费 gating（writeVerified 计费 vs writeFailed/skipped/
//    none 不计费仍回收写）/driftLatchThreshold 边界（1→2 锁存）/锁存态 .skip +
//    streak 累积 + ==3 自动解除计数器清零（防永久卡死）/脏回读断链/越域值双分支
// ④ 常量钉死：driftLatchThreshold=2 / cleanUnlockStreak=3 / aclcKey（M0 观测⑤
//    定稿挂账——数值可上调，此处防无意识漂移）
// ⑤ wireStatus 三态（match/foreign/unknown）+ mode nil 形态 + Codable roundtrip
// ⑥ policy validated：缺席=system 默认（nil）/ 合法值保留 / 越界仅丢字段回落
//    system 且不连累 fan/thermal（完整 policy 验证）/ 类型错乱整包 nil
//
// 纯函数面，零 IOKit 代码（M1 只依赖读侧事实；SMC 字节编解码归 M2）。

import CellarCore
import Foundation

/// MagSafe LED 场景域入口（Main.main 调用；全部纯函数 + 临时目录 policy 注入）。
func runMagSafeLEDDomainScenarios() throws {
    // ---- 决策便捷调用（默认 amber 活跃执法 + 干净锁存态，矩阵行按需覆盖）----
    func decide(
        mode: MagSafeLEDMode = .amber,
        modeActive: Bool = true,
        support: MagSafeLED.SupportState = .supported,
        readback: UInt8?,
        lastTickAction: MagSafeLED.CorrectionAction = .none,
        latch: MagSafeLED.LatchState = MagSafeLED.LatchState()
    ) -> (outcome: MagSafeLED.CorrectionOutcome, latchState: MagSafeLED.LatchState) {
        MagSafeLED.correctionDecision(
            mode: mode, modeActive: modeActive, supportState: support,
            lastReadbackRaw: readback, lastTickAction: lastTickAction, latchState: latch
        )
    }

    /// 锁存态便捷构造。
    func latched(drift: Int = 2, streak: Int = 0) -> MagSafeLED.LatchState {
        MagSafeLED.LatchState(driftCount: drift, cleanReadbackStreak: streak, latched: true)
    }

    // ---- ① validating 白名单穷举 ----

    // 灯-1：四值白名单（0=system/1=off/3=green/4=amber，§1 实测语义）+ rawValue 钉死
    // + CaseIterable 全集恰四（防误加值/改值）。
    do {
        expectEqual(MagSafeLED.validating(0x00), .system, "灯-1", "validating 0x00 → system")
        expectEqual(MagSafeLED.validating(0x01), .off, "灯-1", "validating 0x01 → off")
        expectEqual(MagSafeLED.validating(0x03), .green, "灯-1", "validating 0x03 → green")
        expectEqual(MagSafeLED.validating(0x04), .amber, "灯-1", "validating 0x04 → amber")
        check(MagSafeLEDMode.system.rawValue == 0x00 && MagSafeLEDMode.off.rawValue == 0x01
                && MagSafeLEDMode.green.rawValue == 0x03 && MagSafeLEDMode.amber.rawValue == 0x04
                && MagSafeLEDMode.allCases.count == 4,
              "灯-1", "rawValue 钉死 0/1/3/4 且 allCases 恰四（只追加不重排纪律）")
    }

    // 灯-2：越界（2/5/255）→ nil + nil 缺席 → nil（= 未设置跟随 system 的 opt-in 语义）。
    check(MagSafeLED.validating(0x02) == nil && MagSafeLED.validating(0x05) == nil
            && MagSafeLED.validating(0xFF) == nil && MagSafeLED.validating(nil) == nil,
          "灯-2", "validating 越界 2/5/255 → nil；nil 缺席 → nil（未设置=system）")

    // ---- ② interpreting（读侧解释）----

    // 灯-3：四值 → 模式；0x02/0xFF → nil（= 他写信号，通道 A 判据输入，不做格式猜测）。
    check(MagSafeLED.interpreting(0x00) == .system && MagSafeLED.interpreting(0x01) == .off
            && MagSafeLED.interpreting(0x03) == .green && MagSafeLED.interpreting(0x04) == .amber,
          "灯-3", "interpreting 四值 → 模式（读侧事实，§1）")
    check(MagSafeLED.interpreting(0x02) == nil && MagSafeLED.interpreting(0xFF) == nil,
          "灯-3", "interpreting 0x02/0xFF → nil（他写信号，通道 A 值域判据）")

    // ---- ③ correctionDecision 矩阵穷举（方案 §0-D5 全量）----

    // 灯-4：mode==system → .idle 且计数器保留（含 latched 输入锁存保留——用户改模式
    // 的重置职责在调用方，函数不代行）。
    do {
        let state = MagSafeLED.LatchState(driftCount: 1, cleanReadbackStreak: 2, latched: true)
        let idle = decide(mode: .system, readback: 0x02, lastTickAction: .writeVerified, latch: state)
        check(idle.outcome == .idle && idle.latchState == state,
              "灯-4", "system 模式 → .idle 且计数器/锁存原样保留（重置职责在调用方）")
    }

    // 灯-5：!modeActive（disabled/停用期）→ .idle 计数器保留。
    do {
        let state = MagSafeLED.LatchState(driftCount: 1, cleanReadbackStreak: 2, latched: false)
        let idle = decide(modeActive: false, readback: 0x03, lastTickAction: .writeVerified, latch: state)
        check(idle.outcome == .idle && idle.latchState == state,
              "灯-5", "!modeActive → .idle 且计数器保留（停用期不介入不清理）")
    }

    // 灯-6：supportState unsupported/undecided → .idle 计数器保留（D6 分流：能力
    // 未决不等于放弃纠偏状态机）。
    do {
        let state = MagSafeLED.LatchState(driftCount: 1, cleanReadbackStreak: 2, latched: false)
        var ok = true
        for support in [MagSafeLED.SupportState.unsupported, .undecided] {
            let idle = decide(support: support, readback: 0x03, lastTickAction: .writeVerified, latch: state)
            if idle.outcome != .idle || idle.latchState != state { ok = false }
        }
        check(ok, "灯-6", "unsupported/undecided → .idle 且计数器保留（门槛先于锁存）")
    }

    // 灯-7：未锁存 + 期望回读 → streak+1 无动作（.skip 本 tick 无写；与 lastTickAction
    // 无关）；streak 达 3 而未锁存 = 惰性（无锁存可解，保持未锁存）。
    do {
        let r1 = decide(readback: 0x04, lastTickAction: .skipped, latch: MagSafeLED.LatchState(driftCount: 0, cleanReadbackStreak: 2, latched: false))
        check(r1.outcome == .skip && r1.latchState.driftCount == 0
                && r1.latchState.cleanReadbackStreak == 3 && !r1.latchState.latched,
              "灯-7", "未锁存+期望回读 → .skip + streak 2→3（无动作不写灯）")
        let r2 = decide(readback: 0x04, lastTickAction: .writeFailed, latch: MagSafeLED.LatchState(driftCount: 1, cleanReadbackStreak: 0, latched: false))
        check(r2.outcome == .skip && r2.latchState.cleanReadbackStreak == 1 && r2.latchState.driftCount == 1,
              "灯-7", "干净回读与 lastTickAction 无关（writeFailed 同养 streak 不计费）")
    }

    // 灯-8：未锁存 + 未读过（nil）→ 无凭据：.skip 计数器原样（勿与「他写」混叠）。
    do {
        let state = MagSafeLED.LatchState(driftCount: 1, cleanReadbackStreak: 2, latched: false)
        let r = decide(readback: nil, lastTickAction: .writeVerified, latch: state)
        check(r.outcome == .skip && r.latchState == state,
              "灯-8", "未锁存+nil 回读 → .skip 计数器原样（未读过≠他写）")
    }

    // 灯-9：未锁存 + 外来合法值 + writeVerified → 计费 drift+1 且回收写 .write(expected)
    // （通道 B：写成功后再现外来值 = 事件；streak 断链）。
    do {
        let r = decide(readback: 0x03, lastTickAction: .writeVerified,
                       latch: MagSafeLED.LatchState(driftCount: 0, cleanReadbackStreak: 5, latched: false))
        check(r.outcome == .write(expected: .amber) && r.latchState.driftCount == 1
                && r.latchState.cleanReadbackStreak == 0 && !r.latchState.latched,
              "灯-9", "外来合法值+writeVerified → drift 0→1 + .write(amber) 回收纠偏")
    }

    // 灯-10：driftLatchThreshold 边界——drift==1（阈值-1）+ writeVerified + 外来值
    // → drift 1→2 ==阈值 → conflictLatch（本 tick 即停纠偏，不写）+ latched=true。
    do {
        let r = decide(readback: 0x03, lastTickAction: .writeVerified,
                       latch: MagSafeLED.LatchState(driftCount: 1, cleanReadbackStreak: 0, latched: false))
        check(r.outcome == .conflictLatch && r.latchState.driftCount == MagSafeLED.driftLatchThreshold
                && r.latchState.cleanReadbackStreak == 0 && r.latchState.latched,
              "灯-10", "drift==阈值 2 边界 → conflictLatch（停纠偏入口，证据计数保留）")
    }

    // 灯-11：外来值 + writeFailed → **不计费**（drift 原样——写失败旧值读数不计数，
    // R2 N1）但仍回收写 .write(expected)。
    do {
        let r = decide(readback: 0x03, lastTickAction: .writeFailed,
                       latch: MagSafeLED.LatchState(driftCount: 1, cleanReadbackStreak: 4, latched: false))
        check(r.outcome == .write(expected: .amber) && r.latchState.driftCount == 1
                && r.latchState.cleanReadbackStreak == 0,
              "灯-11", "外来值+writeFailed → 不计费（drift 保 1）仍 .write(amber)（写失败旧值不计数）")
    }

    // 灯-12：外来值 + skipped / none → 不计费仍回收写（残留回收；skipped 即「解除后
    // 首 tick 不被计费」路径，none 即启动首读残留路径）。
    do {
        var ok = true
        for action in [MagSafeLED.CorrectionAction.skipped, .none] {
            let r = decide(readback: 0x03, lastTickAction: action,
                           latch: MagSafeLED.LatchState(driftCount: 1, cleanReadbackStreak: 2, latched: false))
            if r.outcome != .write(expected: .amber) || r.latchState.driftCount != 1
                || r.latchState.cleanReadbackStreak != 0 { ok = false }
        }
        check(ok, "灯-12", "外来值+skipped/none → 不计费仍 .write(amber)（残留回收，streak 断链）")
    }

    // 灯-13：越域值（非四值）双分支——writeVerified 计费（通道 A 与通道 B 累入同一
    // driftCount，R3）；writeFailed 不计费仍回收写；计费达阈值同样锁存。
    do {
        let billed = decide(readback: 0x02, lastTickAction: .writeVerified,
                            latch: MagSafeLED.LatchState(driftCount: 0, cleanReadbackStreak: 3, latched: false))
        check(billed.outcome == .write(expected: .amber) && billed.latchState.driftCount == 1
                && billed.latchState.cleanReadbackStreak == 0,
              "灯-13", "越域值 0x02+writeVerified → 计费 drift 0→1 仍回收写（通道 A 同尺）")
        let unbilled = decide(readback: 0xFF, lastTickAction: .writeFailed,
                              latch: MagSafeLED.LatchState(driftCount: 0, cleanReadbackStreak: 3, latched: false))
        check(unbilled.outcome == .write(expected: .amber) && unbilled.latchState.driftCount == 0
                && unbilled.latchState.cleanReadbackStreak == 0,
              "灯-13", "越域值 0xFF+writeFailed → 不计费仍回收写（streak 断链）")
        let latch = decide(readback: 0x02, lastTickAction: .writeVerified,
                           latch: MagSafeLED.LatchState(driftCount: 1, cleanReadbackStreak: 0, latched: false))
        check(latch.outcome == .conflictLatch && latch.latchState.latched,
              "灯-13", "越域值计费达阈值 → conflictLatch（A/B 事件同一计数锁存）")
    }

    // 灯-14：锁存态 → .skip 恒定（停纠偏）+ 干净回读 streak 累积（解除凭据养连击）。
    do {
        let r1 = decide(readback: 0x04, lastTickAction: .skipped, latch: latched(drift: 2, streak: 0))
        check(r1.outcome == .skip && r1.latchState == latched(drift: 2, streak: 1),
              "灯-14", "锁存态+干净回读 → .skip + streak 0→1（drift 证据保留）")
        let r2 = decide(readback: 0x04, lastTickAction: .skipped, latch: latched(drift: 2, streak: 1))
        check(r2.outcome == .skip && r2.latchState == latched(drift: 2, streak: 2),
              "灯-14", "锁存态+干净回读 → streak 1→2（连续性跨 tick 承载）")
    }

    // 灯-15：锁存态 streak==3 → **自动解除且计数器清零**（drift/streak 双清零 +
    // latched=false——防永久卡死路径，方案 §0-D5；解除后首 tick 以 skipped 起步
    // 不被计费）。
    do {
        let r = decide(readback: 0x04, lastTickAction: .skipped, latch: latched(drift: 2, streak: 2))
        check(r.outcome == .skip && r.latchState == MagSafeLED.LatchState(),
              "灯-15", "锁存态 streak 2→3 → 自动解除且计数器清零（latched=false 双计数归零）")
    }

    // 灯-16：锁存态脏回读 → streak 清零但保持锁存；nil 回读 → streak 保留（无新证据）。
    do {
        let dirty = decide(readback: 0x03, lastTickAction: .skipped, latch: latched(drift: 2, streak: 2))
        check(dirty.outcome == .skip && dirty.latchState == latched(drift: 2, streak: 0),
              "灯-16", "锁存态脏回读 → streak 清零保持锁存（证据链断裂）")
        let noRead = decide(readback: nil, lastTickAction: .skipped, latch: latched(drift: 2, streak: 2))
        check(noRead.outcome == .skip && noRead.latchState == latched(drift: 2, streak: 2),
              "灯-16", "锁存态 nil 回读 → streak 保留（未读过无新证据）")
    }

    // 灯-17：常量钉死——driftLatchThreshold=2 / cleanUnlockStreak=3 / aclcKey
    // （M0 观测⑤定稿挂账：数值可上调，此处防无意识漂移）。
    check(MagSafeLED.driftLatchThreshold == 2 && MagSafeLED.cleanUnlockStreak == 3
            && MagSafeLED.aclcKey == "ACLC",
          "灯-17", "具名常量钉死：阈值=2、解除 streak=3、键名 ACLC")

    // ---- ⑤ wireStatus 三态 + mode nil 形态 + Codable roundtrip ----

    // 灯-18：wireStatus 三态（match/foreign/unknown——readbackRaw 原值承载，防
    // 「未读过」与「他写」混叠，R1 P3-3）+ supported 映射（仅 .supported 为 true）。
    do {
        let match = MagSafeLED.wireStatus(mode: .amber, supportState: .supported, readbackRaw: 0x04)
        check(match.supported && match.mode == .amber && match.readbackRaw == 0x04
                && match.readbackState == .match,
              "灯-18", "mode=amber+回读 0x04 → match 且 supported=true（全字段保真）")
        let foreign = MagSafeLED.wireStatus(mode: .amber, supportState: .supported, readbackRaw: 0x03)
        check(foreign.readbackState == .foreign, "灯-18", "mode=amber+回读 0x03 → foreign（他写合法值）")
        let outOfDomain = MagSafeLED.wireStatus(mode: .amber, supportState: .supported, readbackRaw: 0x02)
        check(outOfDomain.readbackState == .foreign, "灯-18", "mode=amber+回读 0x02 → foreign（越域值同落他写态）")
        let unknown = MagSafeLED.wireStatus(mode: .amber, supportState: .supported, readbackRaw: nil)
        check(unknown.readbackState == .unknown, "灯-18", "readback nil → unknown（未读过，非他写）")
        check(MagSafeLED.wireStatus(mode: .off, supportState: .undecided, readbackRaw: nil).supported == false
                && MagSafeLED.wireStatus(mode: .off, supportState: .unsupported, readbackRaw: nil).supported == false,
              "灯-18", "undecided/unsupported → supported=false（降级位共用，D6 分流在探测侧）")
    }

    // 灯-19：mode nil（跟随系统）形态——合法四值 = 系统管理常态视作 match（寄存器
    // 常态是色值，勿把系统自身覆写误报为他写）；越域值 = foreign；nil = unknown。
    do {
        check(MagSafeLED.wireStatus(mode: nil, supportState: .supported, readbackRaw: 0x04).readbackState == .match
                && MagSafeLED.wireStatus(mode: nil, supportState: .supported, readbackRaw: 0x00).readbackState == .match,
              "灯-19", "mode nil + 合法值 0x04/0x00 → match（system 态色值常态，D2 事实）")
        check(MagSafeLED.wireStatus(mode: nil, supportState: .supported, readbackRaw: 0x02).readbackState == .foreign,
              "灯-19", "mode nil + 越域值 → foreign（越域=他写信号与 mode 无关）")
        check(MagSafeLED.wireStatus(mode: nil, supportState: .supported, readbackRaw: nil).readbackState == .unknown,
              "灯-19", "mode nil + readback nil → unknown（未读过）")
    }

    // 灯-20：MagSafeLEDStatus Codable roundtrip（JSON wire 形态——字面 JSON 解码钉
    // 死键名/值形态；readbackState 为派生只读不进编码）。
    do {
        let original = MagSafeLEDStatus(mode: .green, supported: true, readbackRaw: 0x03)
        let decoded = try JSONDecoder().decode(
            MagSafeLEDStatus.self, from: JSONEncoder().encode(original))
        check(decoded == original && decoded.readbackState == .match,
              "灯-20", "Codable roundtrip 保真（green/supported/0x03）")
        let fromLiteral = try JSONDecoder().decode(
            MagSafeLEDStatus.self,
            from: Data(#"{"mode":1,"supported":false,"readbackRaw":1}"#.utf8))
        check(fromLiteral.mode == .off && fromLiteral.supported == false
                && fromLiteral.readbackRaw == 0x01 && fromLiteral.readbackState == .match,
              "灯-20", "字面 JSON 解码（mode=1/readbackRaw=1 uint 形态钉死）")
    }

    // ---- ⑥ policy validated（仅丢字段分层）----

    // 灯-21：缺席=system 默认（旧 policy.json 无键 → nil 兼容）+ 合法值保留 + 与
    // fan/thermal 并存互不覆盖 + save/load 往返保真。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-led-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy.json")
        try """
        {"mode":"active","upperLimit":80,"hysteresis":2,"fan":{"enabled":true,"strategy":"constantSpeed","thresholdCentiC":4200,"releaseHysteresisCentiC":200,"speedPercent":60,"stage2Percent":90,"stage2RiseCentiC":300},"thermal":{"pauseCentiC":4000,"hysteresisCentiC":300}}
        """.write(to: url, atomically: true, encoding: .utf8)
        let legacy = PolicyStore(url: url).load()
        check(legacy?.magSafeLedMode == nil && legacy?.fan != nil && legacy?.thermal != nil,
              "灯-21", "旧 JSON 无 magSafeLedMode 键 → nil（=system 默认）且 fan/thermal 不受影响")

        try """
        {"mode":"active","upperLimit":80,"hysteresis":2,"fan":{"enabled":true,"strategy":"constantSpeed","thresholdCentiC":4200,"releaseHysteresisCentiC":200,"speedPercent":60,"stage2Percent":90,"stage2RiseCentiC":300},"thermal":{"pauseCentiC":4000,"hysteresisCentiC":300},"magSafeLedMode":3}
        """.write(to: url, atomically: true, encoding: .utf8)
        let valid = PolicyStore(url: url).load()
        check(valid?.magSafeLedMode == 0x03 && valid?.fan?.thresholdCentiC == 4200
                && valid?.thermal?.pauseCentiC == 4000,
              "灯-21", "合法值 3 保留且 fan/thermal 并存互不覆盖（完整 policy）")

        let store = PolicyStore(url: directory.appendingPathComponent("roundtrip.json"))
        try store.save(DaemonPolicy(
            mode: "active", upperLimit: 80, hysteresis: 2, magSafeLedMode: 0x04))
        check(store.load()?.magSafeLedMode == 0x04,
              "灯-21", "save/load 往返保真（0x04 原值承载）")
    }

    // 灯-22：越界丢字段回落 system——magSafeLedMode=2/255 → 仅该字段 nil，fan/thermal
    // 完整保留（仅丢字段不连累其他块，照 thermal 块分层）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-led-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy.json")
        for bad in [2, 255] {
            try """
            {"mode":"active","upperLimit":80,"hysteresis":2,"fan":{"enabled":true,"strategy":"constantSpeed","thresholdCentiC":4200,"releaseHysteresisCentiC":200,"speedPercent":60,"stage2Percent":90,"stage2RiseCentiC":300},"thermal":{"pauseCentiC":4000,"hysteresisCentiC":300},"magSafeLedMode":\(bad)}
            """.write(to: url, atomically: true, encoding: .utf8)
            let loaded = PolicyStore(url: url).load()
            if loaded?.magSafeLedMode != nil || loaded?.fan == nil || loaded?.thermal == nil {
                check(false, "灯-22", "magSafeLedMode=\(bad) → 仅丢字段保 fan/thermal")
            }
        }
        check(true, "灯-22", "越界 2/255 → 仅丢字段回落 system，fan/thermal 完整保留（不连累）")
    }

    // 灯-23：类型错乱（String 混入 uint 字段）→ 整包 nil（合成 Codable 行为，与
    // fan/thermal/schedule 同形——仅丢字段分层只覆盖值域非法，不覆盖类型错乱）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-led-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy.json")
        try """
        {"mode":"active","upperLimit":80,"hysteresis":2,"magSafeLedMode":"3"}
        """.write(to: url, atomically: true, encoding: .utf8)
        check(PolicyStore(url: url).load() == nil,
              "灯-23", "magSafeLedMode 类型错乱（String）→ 整包 nil（合成 Codable，与既有块同形）")
    }

    // ---- ⑦ 线格式（makeMessage / validateRequest，照自动-9/10 先例）----

    // 灯-24：makeMessage magSafeLedMode 参数 → validateRequest 解析往返（四合法值）。
    do {
        for raw: UInt64 in [0, 1, 3, 4] {
            let msg = DaemonXPC.makeMessage(
                cmd: MagSafeLED.commandName, upper: 0, hysteresis: 0, magSafeLedMode: raw
            )
            let parsed = DaemonXPC.validateRequest(msg)
            check(parsed?.magSafeLedMode == raw, "灯-24",
                  "validateRequest：magSafeLedMode=\(raw) 解析一致（合法四值）")
        }
    }

    // 灯-25：magSafeLedMode 缺席 → nil（非 setMagSafeLed 命令天然兼容）。
    do {
        let noLed = DaemonXPC.makeMessage(cmd: "setLimits", upper: 80, hysteresis: 2)
        check(DaemonXPC.validateRequest(noLed)?.magSafeLedMode == nil, "灯-25",
              "validateRequest：无 magSafeLedMode 键 → nil（缺席保持）")
    }

    // 灯-26：类型混淆（STRING 值）→ 整包拒绝（与 auto 同纪律，R1 P2-4）。
    do {
        let confused = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(confused, DaemonXPC.cmdKey, MagSafeLED.commandName)
        xpc_dictionary_set_string(confused, DaemonXPC.magSafeLedModeKey, "green")
        check(DaemonXPC.validateRequest(confused) == nil, "灯-26",
              "magSafeLedMode 类型混淆（STRING）→ 整包拒绝（不崩溃、不回半合法包）")
    }
}