// CellarCoreCheck —— 0.20.2 §2 TopoffState 诚实性字段持久化场景域（方案 §2 全部）：
// ①加载（round-trip / fresh 基底合成——瞬态字段一律 fresh）
// ②损坏 fallback（非 JSON / 读失败 → nil fail-open；缺失静默）
// ③值域钳制（strikes ∈ [0, 3]，越界置 0——R1-P3 纵深）
// ④降级跨重启 healTick 照跑（域值 80 物理持久不重写——「稳态下不重写」不变量；
//   lastHealProbeAt 连续；nil → `?? true` 立即首探）
// ⑤off 兼容（off=true round-trip + 关断清理幂等守卫纯函数钉面——(100, off) 零写）
// ⑥写入点 sub80 门（26 路由 topoffOwned 恒 false → 无计划消费无状态变更 → 零持久化；
//   写入点钉在 daemon sub80 门内由调用点注记 + code-review 走查兜底——CellarCoreCheck
//   不可 import daemon）
// ⑦触发源（strike / 降级跳变 / off 关断三触发钉死；域写与观察窗簿记不触发——R2-P3）

import CellarCore
import Foundation

/// 0.20.2 §2 持久化场景域入口（Main.main 调用；TopoffStateStore 路径注入缝 +
/// Topoff 纯函数面，不触碰真实 /Library 目录）。
func runTopoffPersistenceDomainScenarios() throws {
    let t0 = Date(timeIntervalSince1970: 3_000_000)

    // ---- ① 加载（round-trip + fresh 基底合成）----

    // 持久-1：五字段 round-trip 保真；restoredState 合成瞬态字段恒 fresh。
    do {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-check-topoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TopoffStateStore(url: dir.appendingPathComponent("topoff-state.json"))
        let persisted = TopoffPersistedState(
            degraded: true, strikes: 2, off: false,
            lastViolationAt: t0, lastHealProbeAt: t0.addingTimeInterval(600)
        )
        try store.save(persisted)
        let loaded = try requireNotNil(store.load(), "持久-1", "五字段 round-trip 读取成功")
        check(loaded == persisted,
              "持久-1", "诚实性五字段 round-trip 保真（degraded/strikes/off/lastViolationAt/lastHealProbeAt）")
        let restored = Topoff.restoredState(persisted: loaded)
        check(restored.degraded && restored.strikes == 2
                && restored.lastViolationAt == t0 && restored.lastHealProbeAt == t0.addingTimeInterval(600)
                && restored.lastWrittenLimit == nil && restored.lastWriteAt == nil
                && restored.violationTicks == 0 && !restored.healProbeActive
                && restored.healProbeTicks == 0 && restored.activeTarget == nil
                && restored.lastReassertAt == nil,
              "持久-1", "加载合成：诚实性五字段回填 ∧ 瞬态字段一律 fresh（首拍幂等重写对账停机漂移——R1-P2）")
        check(Topoff.restoredState(persisted: nil) == TopoffChannelState(),
              "持久-1", "persisted nil → 恒 fresh（缺失/损坏 fail-open 形态）")
    }

    // ---- ② 损坏 fallback（fail-open fresh）----

    // 持久-2：非 JSON / 截断 JSON → nil（域写幂等兜底）；空目录（缺失）→ nil 静默。
    do {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-check-topoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("topoff-state.json")
        try Data("corrupted".utf8).write(to: url)
        check(TopoffStateStore(url: url).load() == nil,
              "持久-2", "非 JSON 损坏 → nil（fail-open fresh——绝不抛错打断启动）")
        try Data("{\"degraded\":true,\"stri".utf8).write(to: url)
        check(TopoffStateStore(url: url).load() == nil,
              "持久-2", "截断 JSON 损坏 → nil（同款 fail-open）")
        try FileManager.default.removeItem(at: url)
        check(TopoffStateStore(url: url).load() == nil,
              "持久-2", "文件缺失 → nil 静默（首启/26 平台正常形态——写入点钉在 sub80 门内）")
    }

    // ---- ③ 值域钳制（R1-P3 纵深）----

    // 持久-3：strikes 越界（负/超 3）→ 钳 0；[0, 3] 域内原样；损坏文件内越界值经
    // load 全链钳制（store 直接构造注入形态）。
    do {
        check(TopoffPersistedState(degraded: false, strikes: -1, off: false,
                                   lastViolationAt: nil, lastHealProbeAt: nil).clamped().strikes == 0,
              "持久-3", "strikes = -1（越界）→ 钳 0")
        check(TopoffPersistedState(degraded: false, strikes: 7, off: false,
                                   lastViolationAt: nil, lastHealProbeAt: nil).clamped().strikes == 0,
              "持久-3", "strikes = 7（越界）→ 钳 0（fail-open 方向——×3 降级防线从头计，不跳降级）")
        for valid in [0, 1, 2, 3] {
            let state = TopoffPersistedState(degraded: false, strikes: valid, off: false,
                                             lastViolationAt: nil, lastHealProbeAt: nil)
            check(state.clamped().strikes == valid,
                  "持久-3", "strikes = \(valid)（域内）→ 原样保留（[0, 3] 闭区间）")
        }
        // load 全链：合法 JSON + 越界 strikes → 载入结果已钳 0。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-check-topoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("topoff-state.json")
        try Data("{\"degraded\":true,\"strikes\":99,\"off\":false,\"lastViolationAt\":3000000,\"lastHealProbeAt\":3000600}".utf8)
            .write(to: url)
        let loaded = try requireNotNil(TopoffStateStore(url: url).load(), "持久-3", "越界文件解码成功（钳制前）")
        check(loaded.strikes == 0 && loaded.degraded,
              "持久-3", "load 全链值域钳制（99 → 0；其余字段不受连累）")
    }

    // ---- ④ 降级跨重启 healTick 照跑（稳态下不重写域值 80）----

    // 持久-4：degraded=true + lastHealProbeAt 在 1h 内 → healTick not-due 零写
    //（域值 80 物理持久——「稳态下不重写」不变量，停机漂移交编排钳 80 兜底）；
    // lastHealProbeAt nil（越界/损坏 fallback 后 degraded 仍在的窄形态）→ 立即首探。
    do {
        let persisted = TopoffPersistedState(
            degraded: true, strikes: 3, off: false,
            lastViolationAt: t0.addingTimeInterval(-600), lastHealProbeAt: t0.addingTimeInterval(-120)
        )
        let restored = Topoff.restoredState(persisted: persisted)
        let steady = Topoff.healTick(state: restored, target: 75, now: t0.addingTimeInterval(60),
                                     percent: 90, externalConnected: true, isCharging: true)
        check(!steady.state.healProbeActive && steady.writeLimit == nil
                && steady.state.lastHealProbeAt == t0.addingTimeInterval(-120),
              "持久-4", "降级跨重启：lastHealProbeAt 连续（1h 未到）→ healTick 稳态零写（域值 80 不重写——物理持久；探针照跑节奏不变）")
        let due = Topoff.healTick(state: restored, target: 75,
                                  now: t0.addingTimeInterval(-120 + Topoff.healProbeInterval),
                                  percent: 90, externalConnected: true, isCharging: true)
        check(due.writeLimit == 75 && due.state.healProbeActive,
              "持久-4", "跨重启后 1h 到期 → 探针照跑（域写 target + 观察窗开——lastHealProbeAt 跨重启连续判定）")
        let noProbeAt = Topoff.restoredState(persisted: TopoffPersistedState(
            degraded: true, strikes: 3, off: false, lastViolationAt: nil, lastHealProbeAt: nil
        ))
        let immediate = Topoff.healTick(state: noProbeAt, target: 75, now: t0,
                                        percent: 90, externalConnected: true, isCharging: true)
        check(immediate.writeLimit == 75 && immediate.state.healProbeActive,
              "持久-4", "lastHealProbeAt nil → `?? true` 立即首探（已核实语义保持）")
    }

    // ---- ⑤ off 兼容（跨重启关断清理幂等守卫）----

    // 持久-5：off=true round-trip；关断清理幂等守卫纯函数钉面——(100, off) 零写恢复、
    // 重启 fresh lastWrittenLimit → 一次幂等重写 100 后归位。
    do {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-check-topoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TopoffStateStore(url: dir.appendingPathComponent("topoff-state.json"))
        let persisted = TopoffPersistedState(
            degraded: false, strikes: 0, off: true,
            lastViolationAt: nil, lastHealProbeAt: nil
        )
        try store.save(persisted)
        let restored = Topoff.restoredState(persisted: try requireNotNil(store.load(), "持久-5", "off=true round-trip 读取"))
        check(restored.off && !restored.degraded && restored.strikes == 0,
              "持久-5", "off=true 跨重启保持（sub80State=off 源——关断态不被重启洗白）")
        check(!Topoff.shutdownCleanupNeeded(lastWrittenLimit: Topoff.shutdownLimit, off: true),
              "持久-5", "(100, off) 态 → 幂等守卫零写（关断稳态不重写）")
        check(Topoff.shutdownCleanupNeeded(lastWrittenLimit: nil, off: true),
              "持久-5", "重启 fresh lastWrittenLimit(nil) ∧ off=true → 守卫放行一次幂等重写 100（停机期域漂移对账后归位零写稳态——已核实兼容）")
        check(Topoff.shutdownCleanupNeeded(lastWrittenLimit: 75, off: false),
              "持久-5", "(75, off=false) → 守卫放行（常规关断清理路径）")
    }

    // ---- ⑥ 写入点 sub80 门（26 平台不生成状态文件）----

    // 持久-6：26（sub80Capable=false）路由 topoffOwned 恒 false → 无 plan 消费无状态
    // 变更 → shouldPersistHonestyChange 恒 false——持久化触发面结构性不可达；
    // daemon 写入点钉在 DaemonCore+Topoff.swift sub80 早退之后（defer 收口）由
    // 调用点注记 + code-review 走查兜底（CellarCoreCheck 不可 import daemon）。
    do {
        let route26 = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: false, actionActive: false,
            degraded: false, healProbeActive: false)
        check(!route26.topoffOwned
                && !Topoff.shouldPersistHonestyChange(previous: TopoffChannelState(),
                                                      current: TopoffChannelState()),
              "持久-6", "26 路由（topoffOwned 恒 false）→ 无状态变更 → 持久化触发恒 false（状态文件 26 不生成——红线锚）")
        let route26Degraded = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: false, actionActive: false,
            degraded: true, healProbeActive: false)
        check(!route26Degraded.topoffOwned,
              "持久-6", "26 ∧ 载入态 degraded=true → topoff 仍不承载（持久化脏读不外溢——26 行为零变化）")
    }

    // ---- ⑦ 触发源（三触发钉死；域写/观察窗簿记不触发——R2-P3）----

    // 持久-7：strike / 降级跳变 / off 关断 → true；lastWritten/lastWriteAt（域写）/
    // violationTicks / healProbeActive / activeTarget / lastReassertAt / 两 Date 单独
    // 变化 → false。
    do {
        func changed(_ mutate: (inout TopoffChannelState) -> Void) -> Bool {
            var current = TopoffChannelState()
            mutate(&current)
            return Topoff.shouldPersistHonestyChange(previous: TopoffChannelState(), current: current)
        }
        // 双向跳变需要显式 previous 基底（fresh 基底上 true→false 是净值零变）。
        func changedFrom(_ base: TopoffChannelState, _ mutate: (inout TopoffChannelState) -> Void) -> Bool {
            var current = base
            mutate(&current)
            return Topoff.shouldPersistHonestyChange(previous: base, current: current)
        }
        check(changed({ $0.strikes = 1 }), "持久-7", "strike（strikes 跳变）→ 触发持久化")
        check(changed({ $0.degraded = true }), "持久-7", "降级跳变（degraded false→true）→ 触发持久化")
        var degradedBase = TopoffChannelState()
        degradedBase.degraded = true
        degradedBase.strikes = 3
        check(changedFrom(degradedBase, { $0.degraded = false; $0.strikes = 0 }),
              "持久-7", "自愈恢复（degraded true→false）→ 触发持久化（双向跳变）")
        check(changed({ $0.off = true }), "持久-7", "off 关断 → 触发持久化")
        var offBase = TopoffChannelState()
        offBase.off = true
        check(changedFrom(offBase, { $0.off = false }),
              "持久-7", "off 重新承载清除（true→false）→ 触发持久化（跳变）")
        check(!changed({ $0.lastWrittenLimit = 75 }), "持久-7", "域写簿记（lastWrittenLimit）→ 不触发（R2-P3：域写无持久化字段变更）")
        check(!changed({ $0.lastWriteAt = t0 }), "持久-7", "域写簿记（lastWriteAt）→ 不触发")
        check(!changed({ $0.violationTicks = 19 }), "持久-7", "验证窗推进（violationTicks）→ 不触发（瞬态）")
        check(!changed({ $0.healProbeActive = true }), "持久-7", "探针开窗（healProbeActive）→ 不触发（瞬态）")
        check(!changed({ $0.activeTarget = 75 }), "持久-7", "承载目标（activeTarget）→ 不触发（瞬态）")
        check(!changed({ $0.lastReassertAt = t0 }), "持久-7", "轻量重申簿记（lastReassertAt）→ 不触发（内存态）")
        check(!changed({ $0.lastViolationAt = t0 }), "持久-7", "lastViolationAt 单独变化（healTick 失败拍）→ 不触发（随下一触发拍快照落盘）")
        check(!changed({ $0.lastHealProbeAt = t0 }), "持久-7", "lastHealProbeAt 单独重锚（探针开窗拍）→ 不触发（fail-open——重启后提前重探无害）")
        check(!Topoff.shouldPersistHonestyChange(previous: TopoffChannelState(),
                                                 current: TopoffChannelState()),
              "持久-7", "零变更 → 不触发（幂等——低频纪律）")
    }
}

/// 场景域内非空断言助手（nil → 计失败并抛出中止本域）。
private func requireNotNil<T>(_ value: T?, _ scenario: String, _ message: String) throws -> T {
    if let value { return value }
    check(false, scenario, "\(message)——实际 nil")
    throw CocoaError(.fileReadUnknown)
}
