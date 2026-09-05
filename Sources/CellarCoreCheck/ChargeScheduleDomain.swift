// CellarCoreCheck —— Phase 5 v1.6 充电日程场景域（方案 §2.4 清单 / 工单 M2 要点 7）
//
// 与 CalibrationScheduleDomain 同域拆分先例；wire/持久化/兼容面另拆
// ChargeScheduleWireDomain.swift（各文件 ≤400 行——FanDomain/ThermalPolicyDomain
// 先例）。daemon 为 executable 不可 import——日程臂/三级校验的 daemon 侧接线归
// code-reviewer 走查必查项；本文件覆盖 CellarCore 纯函数层。
//
// 本文件覆盖清单（方案 §2.4；转移矩阵四族钉死：A→B 直切 / 快照恢复 / 编辑保 id
// 本窗不重应用 / 重启补判）：
// ① validated（enabled/条数 9 拒/weekdays 空与越界与重复与乱序/start=end 拒/
//    limit 越界/双动作字段全 nil 拒/chargingDisabled 与 limit 并存合法/id 空与
//    重复拒/合法往返）
// ② matchingEntry（单条命中/星期不匹配/跨午夜 22:00-07:00 钟面星期语义/多条命中
//    最晚开始者胜/禁用整体 → nil/半开边界）
// ③ desiredState + transitionRequired（进入/退出恢复快照 base/A→B 无缝衔接直切
//    不经 base/重启保手动 lastApplied==W.id/重启补进入/重启补退出/编辑保 id 本窗
//    不重应用/耗尽语义/关总开关立即恢复/越域条目防御）
// ④ 字面量构造（schedule: 前缀/entered 前 8 位/restored）

import CellarCore
import Foundation

/// 本地钟面构造助手（固定 2026-09 基准周：9/2=周三、9/7=周一、9/8=周二、9/9=周四
/// ——`date -j -f` 实证；与实现不同源的独立锚点。窗口判定按用户本地时钟——
/// daemon 与本工具同机同 tz）。
func scheduleLocalTime(day: Int, hour: Int, minute: Int = 0) -> Date {
    var comps = DateComponents()
    comps.year = 2026
    comps.month = 9
    comps.day = day
    comps.hour = hour
    comps.minute = minute
    return Calendar.current.date(from: comps)!
}

/// 条目构造助手（经 validated——工厂即校验；两域文件共用）。
func scheduleEntry(
    id: String, weekdays: [Int], start: Int, end: Int,
    limit: Int? = nil, disable: Bool? = nil
) -> ChargeScheduleEntry? {
    ChargeScheduleEntry.validated(
        id: id, weekdays: weekdays, startMinute: start, endMinute: end,
        upperLimit: limit, chargingDisabled: disable
    )
}

/// 工作日 09:00-18:00 限充 70 基准条目（id 前 8 位 "workday1"；wire/兼容域共用）。
let scheduleWorkdayEntry = scheduleEntry(
    id: "workday1-1111-2222-3333-444444444444",
    weekdays: [1, 2, 3, 4, 5], start: 9 * 60, end: 18 * 60, limit: 70
)!

/// 基准配置（单条目命中形态；wire/兼容域共用）。
let scheduleWorkdayConfig = ChargeScheduleConfig(enabled: true, entries: [scheduleWorkdayEntry])

/// 充电日程纯函数域入口（Main.main 调用；窗口按本地时区钟面表达，固定基准日防随机）。
func runChargeScheduleDomainScenarios() throws {
    let calendar = Calendar.current
    let workday = scheduleWorkdayEntry
    let workdayConfig = scheduleWorkdayConfig

    // ---- ① validated ----

    // 日程-1：默认配置钉死（enabled false + 空表——UD-1 opt-in）+ 默认整体过 validated。
    do {
        let d = ChargeScheduleConfig.default
        check(!d.enabled && d.entries.isEmpty,
              "日程-1", ".default = enabled false + 空表（opt-in 默认关，UD-1）")
        check(ChargeScheduleConfig.validated(enabled: d.enabled, entries: d.entries) == d,
              "日程-1", "默认配置整体过 validated")
    }

    // 日程-2：条数上限（UD-1 定版 8）——9 拒 / 8 过。
    do {
        let many = (1...9).map {
            scheduleEntry(id: "id-\($0)", weekdays: [1], start: 0, end: $0 * 60, limit: 80)!
        }
        check(ChargeScheduleConfig.validated(enabled: true, entries: Array(many.prefix(8))) != nil,
              "日程-2", "8 条合法（上限内）")
        check(ChargeScheduleConfig.validated(enabled: true, entries: many) == nil,
              "日程-2", "9 条 → 整包 nil（maxEntries = 8）")
    }

    // 日程-3：weekdays 校验（空/越界/重复/乱序皆拒——canonical 去重升序，不做静默归一）。
    do {
        check(scheduleEntry(id: "e", weekdays: [], start: 0, end: 60, limit: 80) == nil,
              "日程-3", "weekdays 空 → nil")
        check(scheduleEntry(id: "e", weekdays: [0, 1], start: 0, end: 60, limit: 80) == nil
                && scheduleEntry(id: "e", weekdays: [1, 7, 8], start: 0, end: 60, limit: 80) == nil,
              "日程-3", "weekdays 越界 0/8 → nil（ISO 1...7，周一=1）")
        check(scheduleEntry(id: "e", weekdays: [2, 2], start: 0, end: 60, limit: 80) == nil,
              "日程-3", "weekdays 重复 → nil（不做静默去重）")
        check(scheduleEntry(id: "e", weekdays: [3, 1], start: 0, end: 60, limit: 80) == nil,
              "日程-3", "weekdays 乱序 → nil（canonical 严格升序）")
        check(scheduleEntry(id: "e", weekdays: [1, 3, 7], start: 0, end: 60, limit: 80) != nil,
              "日程-3", "升序 1/3/7 合法（端点 1 与 7）")
    }

    // 日程-4：时段校验（start==end 拒 / 分钟越界拒 / 0 与 1439 端点合法 / 跨午夜 end<start 合法）。
    do {
        check(scheduleEntry(id: "e", weekdays: [1], start: 540, end: 540, limit: 80) == nil,
              "日程-4", "start == end → nil（空窗口非法）")
        check(scheduleEntry(id: "e", weekdays: [1], start: -1, end: 60, limit: 80) == nil
                && scheduleEntry(id: "e", weekdays: [1], start: 0, end: 1440, limit: 80) == nil,
              "日程-4", "分钟越界 -1/1440 → nil（0...1439）")
        check(scheduleEntry(id: "e", weekdays: [1], start: 0, end: 1439, limit: 80) != nil,
              "日程-4", "端点 0/1439 合法")
        check(scheduleEntry(id: "e", weekdays: [2], start: 22 * 60, end: 7 * 60, limit: 80) != nil,
              "日程-4", "end < start = 跨午夜窗口合法（22:00-07:00）")
    }

    // 日程-5：动作字段（limit 越界拒 / 双动作全 nil 拒 / chargingDisabled 与 limit 并存合法 /
    // false+limit 合法 / false+nil 惰性条目形式合法——臂仅簿记，UD-1 字面语义）。
    do {
        check(scheduleEntry(id: "e", weekdays: [1], start: 0, end: 60, limit: 59) == nil
                && scheduleEntry(id: "e", weekdays: [1], start: 0, end: 60, limit: 101) == nil,
              "日程-5", "limit 59/101 → nil（60...100）")
        check(scheduleEntry(id: "e", weekdays: [1], start: 0, end: 60, limit: nil, disable: nil) == nil,
              "日程-5", "双动作字段全 nil → nil（至少一项动作）")
        check(scheduleEntry(id: "e", weekdays: [1], start: 0, end: 60, limit: 70, disable: true) != nil,
              "日程-5", "chargingDisabled 与 limit 并存合法（true 时 limit 忽略，UD-1）")
        check(scheduleEntry(id: "e", weekdays: [1], start: 0, end: 60, limit: 70, disable: false) != nil,
              "日程-5", "chargingDisabled=false + limit 合法（显式不停充的限充语义）")
        check(scheduleEntry(id: "e", weekdays: [1], start: 0, end: 60, limit: nil, disable: false) != nil,
              "日程-5", "chargingDisabled=false + limit nil 形式合法（惰性条目——臂仅簿记，登记语义）")
    }

    // 日程-6：id 校验（空拒 / 条目 id 重复整包拒——A→B 直切与编辑保 id 的去重键健全性防御）。
    do {
        check(scheduleEntry(id: "", weekdays: [1], start: 0, end: 60, limit: 80) == nil,
              "日程-6", "id 空 → nil")
        let a = scheduleEntry(id: "dup", weekdays: [1], start: 0, end: 60, limit: 80)!
        let b = scheduleEntry(id: "dup", weekdays: [2], start: 60, end: 120, limit: 90)!
        let c = scheduleEntry(id: "uniq", weekdays: [2], start: 60, end: 120, limit: 90)!
        check(ChargeScheduleConfig.validated(enabled: true, entries: [a, b]) == nil,
              "日程-6", "条目 id 重复 → 整包 nil（重 id 会让 B 窗被误判已应用——引擎语义防御）")
        check(ChargeScheduleConfig.validated(enabled: true, entries: [a, c]) != nil,
              "日程-6", "id 唯一并存合法")
    }

    // 日程-7：Codable 紧凑往返（App/daemon 双端同一 Codable 形态——解码一致由同源保证）。
    do {
        let original = ChargeScheduleConfig(enabled: true, entries: [
            workday,
            scheduleEntry(id: "night1-1111-2222-3333-444444444444",
                          weekdays: [6], start: 22 * 60, end: 7 * 60, disable: true)!,
        ])
        let decoded = try ChargeScheduleConfig.decoded(from: original.encoded!)
        check(decoded == original, "日程-7", "encoded → decoded 往返保真（含跨午夜 + 放开充电条目）")
        check(original.encoded!.contains(#""startMinute":540"#),
              "日程-7", "线格式键名钉死（自定义 CodingKeys——紧凑 JSON，无类名包装）")
    }

    // ---- ② matchingEntry ----

    // 日程-8：单条命中 + 星期不匹配 + 禁用整体 → nil。
    do {
        let hit = matchingEntry(now: scheduleLocalTime(day: 2, hour: 12), calendar: calendar, config: workdayConfig)
        check(hit?.id == workday.id, "日程-8", "周三 12:00 ∈ [09:00,18:00) ∧ 周三 ∈ 工作日 → 命中")
        let mondayOnly = ChargeScheduleConfig(enabled: true, entries: [
            scheduleEntry(id: "mon-only", weekdays: [1], start: 0, end: 1439, limit: 80)!
        ])
        check(matchingEntry(now: scheduleLocalTime(day: 2, hour: 12), calendar: calendar, config: mondayOnly) == nil,
              "日程-8", "周三不在 weekdays [1] → nil（ISO 星期换算：9/2=周三）")
        check(matchingEntry(now: scheduleLocalTime(day: 2, hour: 12), calendar: calendar,
                            config: ChargeScheduleConfig(enabled: false, entries: [workday])) == nil,
              "日程-8", "enabled=false → 恒 nil（禁用整体，UD-1）")
    }

    // 日程-9：跨午夜 22:00-07:00（模 1440 判定 + 钟面星期语义钉死——命中星期按 now 时刻）。
    do {
        let night = scheduleEntry(id: "night1-1111-2222-3333-444444444444",
                                  weekdays: [2], start: 22 * 60, end: 7 * 60, disable: true)!
        let nightConfig = ChargeScheduleConfig(enabled: true, entries: [night])
        check(matchingEntry(now: scheduleLocalTime(day: 8, hour: 23), calendar: calendar, config: nightConfig)?.id == night.id,
              "日程-9", "周二 23:00 命中（minute 1380 ∈ [1320,1440) 模窗口）")
        check(matchingEntry(now: scheduleLocalTime(day: 8, hour: 6), calendar: calendar, config: nightConfig)?.id == night.id,
              "日程-9", "周二 06:00 命中（minute 360 ∈ [0,420) 取模段——同一周二钟面星期）")
        check(matchingEntry(now: scheduleLocalTime(day: 9, hour: 1), calendar: calendar, config: nightConfig) == nil,
              "日程-9", "周三 01:00 不命中（钟面星期=周三 ∉ [2]——星期按时刻钉死，登记语义）")
        check(matchingEntry(now: scheduleLocalTime(day: 8, hour: 7), calendar: calendar, config: nightConfig) == nil,
              "日程-9", "周二 07:00 不命中（== endMinute 半开排除）")
        check(matchingEntry(now: scheduleLocalTime(day: 8, hour: 22), calendar: calendar, config: nightConfig)?.id == night.id,
              "日程-9", "周二 22:00 命中（== startMinute 半开含入）")
    }

    // 日程-10：多条命中最晚 startMinute 胜；同 startMinute 取条目序靠前者（确定性钉死）。
    do {
        let broad = scheduleEntry(id: "broad-1111-2222-3333-444444444444",
                                  weekdays: [3], start: 9 * 60, end: 18 * 60, limit: 70)!
        let narrow = scheduleEntry(id: "narrow-1111-2222-3333-444444444444",
                                   weekdays: [3], start: 12 * 60, end: 14 * 60, limit: 60)!
        let both = ChargeScheduleConfig(enabled: true, entries: [broad, narrow])
        check(matchingEntry(now: scheduleLocalTime(day: 2, hour: 13), calendar: calendar, config: both)?.id == narrow.id,
              "日程-10", "13:00 双命中 → 最晚开始者胜（narrow 12:00 > broad 09:00，R-6 确定性规则）")
        check(matchingEntry(now: scheduleLocalTime(day: 2, hour: 10), calendar: calendar, config: both)?.id == broad.id,
              "日程-10", "10:00 单命中 broad（narrow 窗口外）")
        let tieA = scheduleEntry(id: "tie-a", weekdays: [3], start: 600, end: 660, limit: 60)!
        let tieB = scheduleEntry(id: "tie-b", weekdays: [3], start: 600, end: 700, limit: 65)!
        let tie = ChargeScheduleConfig(enabled: true, entries: [tieA, tieB])
        check(matchingEntry(now: scheduleLocalTime(day: 2, hour: 10, minute: 30), calendar: calendar, config: tie)?.id == tieA.id,
              "日程-10", "同 startMinute → 条目序靠前者胜（确定性补充规则）")
    }

    // ---- ③ desiredState + transitionRequired（转移矩阵四族）----

    // 日程-11：desiredState 封装（命中 → .entry / 未命中与禁用 → .base）。
    do {
        check(desiredState(now: scheduleLocalTime(day: 2, hour: 12), calendar: calendar, config: workdayConfig)
                == .entry(workday), "日程-11", "命中 → .entry(条目)")
        check(desiredState(now: scheduleLocalTime(day: 2, hour: 20), calendar: calendar, config: workdayConfig) == .base,
              "日程-11", "20:00 窗口外 → .base")
        check(desiredState(now: scheduleLocalTime(day: 2, hour: 12), calendar: calendar,
                           config: ChargeScheduleConfig(enabled: false, entries: [workday])) == .base,
              "日程-11", "禁用 → .base（matchingEntry nil 封装）")
    }

    // 日程-12：重启补进入（lastApplied==nil ∧ 在窗 → applyEntry——UD-3 无侧重算补上错过的边沿）。
    check(transitionRequired(desired: .entry(workday), state: .empty, config: workdayConfig)
            == .applyEntry(workday),
          "日程-12", "重启补进入：lastApplied nil + desired .entry(W) → applyEntry(W)")

    // 日程-13：重启保手动（lastApplied==W.id ∧ 在窗 → nil——不重复转移）。
    do {
        let state = ScheduleState(lastAppliedEntryId: workday.id, baseUpperLimit: 80,
                                  baseMode: "active", lastAppliedAt: 1_000)
        check(transitionRequired(desired: .entry(workday), state: state, config: workdayConfig) == nil,
              "日程-13", "重启保手动：lastApplied==W.id + 在窗 → nil（幂等，验收「重启补判不重复转移」）")
    }

    // 日程-14：退出恢复**快照** base（desired .base ∧ lastApplied≠nil → restoreBase(快照值)）。
    do {
        let state = ScheduleState(lastAppliedEntryId: workday.id, baseUpperLimit: 80,
                                  baseMode: "active", lastAppliedAt: 1_000)
        check(transitionRequired(desired: .base, state: state, config: workdayConfig)
                == .restoreBase(baseUpperLimit: 80, baseMode: "active"),
              "日程-14", "退出恢复：restoreBase 携带 state **快照值**（80/active——非退出时刻现值，UD-2/R1 P0）")
        let snapshotless = ScheduleState(lastAppliedEntryId: workday.id)
        check(transitionRequired(desired: .base, state: snapshotless, config: workdayConfig)
                == .restoreBase(baseUpperLimit: nil, baseMode: nil),
              "日程-14", "快照字段缺失（R-8 部分损坏）→ 原样透传 nil（回落归臂执行层，判定层不虚构）")
    }

    // 日程-15：A→B 无缝衔接直切（lastApplied==A ∧ desired .entry(B) → applyEntry(B)
    // ——不经过 restore，base 快照保持不动，R1 P1-1 定版）。
    do {
        let entryB = scheduleEntry(id: "later-b-1111-2222-3333-444444444444",
                                   weekdays: [3], start: 12 * 60, end: 14 * 60, limit: 60)!
        let configAB = ChargeScheduleConfig(enabled: true, entries: [workday, entryB])
        let stateA = ScheduleState(lastAppliedEntryId: workday.id, baseUpperLimit: 80,
                                   baseMode: "active", lastAppliedAt: 1_000)
        let desired = desiredState(now: scheduleLocalTime(day: 2, hour: 13), calendar: calendar, config: configAB)
        check(transitionRequired(desired: desired, state: stateA, config: configAB) == .applyEntry(entryB),
              "日程-15", "A→B 直切：applyEntry(B)（不经 restoreBase——快照不动，无缝衔接）")
    }

    // 日程-16：编辑保 id 本窗不重应用（同 id 新参数 → nil——新参数下一边沿生效，R1 P3）。
    do {
        let edited = scheduleEntry(id: workday.id, weekdays: [1, 2, 3, 4, 5],
                                   start: 10 * 60, end: 17 * 60, limit: 65)!
        let editedConfig = ChargeScheduleConfig(enabled: true, entries: [edited])
        let state = ScheduleState(lastAppliedEntryId: workday.id, baseUpperLimit: 80,
                                  baseMode: "active", lastAppliedAt: 1_000)
        check(transitionRequired(desired: .entry(edited), state: state, config: editedConfig) == nil,
              "日程-16", "编辑保 id：lastApplied==W.id（同 id 不同参数）→ nil（本窗保持现值到边沿）")
    }

    // 日程-17：耗尽语义（恢复清空 state 后同窗重进 → 重新 applyEntry）+ 无事可复。
    do {
        check(transitionRequired(desired: .base, state: .empty, config: workdayConfig) == nil,
              "日程-17", "desired .base ∧ lastApplied nil → nil（无事可复，保手动值）")
        check(transitionRequired(desired: .entry(workday), state: ScheduleState(), config: workdayConfig)
                == .applyEntry(workday),
              "日程-17", "耗尽语义：state 清空（restoreBase 成功后形态）再入窗 → applyEntry（簿记耗尽即重快照）")
    }

    // 日程-18：关总开关立即恢复（enabled=false → desired .base ∧ lastApplied≠nil →
    // restoreBase——验收①「关总开关 → 立即恢复快照 base 后静默」的判定面）+ 越域条目防御。
    do {
        let offConfig = ChargeScheduleConfig(enabled: false, entries: [workday])
        let state = ScheduleState(lastAppliedEntryId: workday.id, baseUpperLimit: 85,
                                  baseMode: "active", lastAppliedAt: 1_000)
        check(transitionRequired(desired: .base, state: state, config: offConfig)
                == .restoreBase(baseUpperLimit: 85, baseMode: "active"),
              "日程-18", "关总开关 → restoreBase 快照（UD-3；matchingEntry 禁用 nil 自然落此分支）")
        let stranger = scheduleEntry(id: "stranger-1111-2222-3333-444444444444",
                                     weekdays: [3], start: 0, end: 60, limit: 60)!
        check(transitionRequired(desired: .entry(stranger), state: .empty, config: workdayConfig) == nil,
              "日程-18", "防御：desired 条目非 config 成员 → nil（转移绝不落地已删除条目）")
    }

    // ---- ④ 字面量族 ----

    // 日程-19：schedule: 前缀 + entered 前 8 位 + restored。
    do {
        check(ChargeScheduleLiteral.scheduleLiteralPrefix == "schedule:",
              "日程-19", "字面量族前缀钉死 schedule:")
        check(ChargeScheduleLiteral.entered(id: workday.id) == "schedule:entered:workday1",
              "日程-19", "entered(id) 取前 8 位（UD-5 字面量形态）")
        check(ChargeScheduleLiteral.entered(id: "abc") == "schedule:entered:abc",
              "日程-19", "短 id 原样（prefix(8) 不足不补）")
        check(ChargeScheduleLiteral.restored == "schedule:restored",
              "日程-19", "restored 字面量钉死")
    }
}
