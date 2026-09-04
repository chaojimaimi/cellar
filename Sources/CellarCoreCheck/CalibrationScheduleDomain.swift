// CellarCoreCheck —— Phase 5 v1.4 校准调度场景域（方案 §2.4 清单）
//
// 按域拆独立文件（main.swift 不再增长）。与 main.swift / 其他场景域共用
// FailureCounter 与断言助手。daemon 为 executable 不可 import——调度臂/记录三点
// 的 daemon 侧接线归 code-reviewer 走查必查项（CalibrationDomain 同款分层声明）；
// 本域覆盖 CellarCore 纯函数层 + PolicyStore 校验块 + wire 编解码 + state 文件。
//
// 覆盖清单（方案 §2.4）：
// ① 窗口判定（起点边界/跨午夜 startHour=22/窗口外）
// ② 就绪判定（首次启用 nil 锚点/间隔恰好/差 1 秒/禁用/负差值 clamp 时钟回拨）
// ③ validated 值域（intervalDays 0 与 181、startHour 越界 → nil；默认值钉死）
// ④ 「仅丢字段」分层语义直测（PolicyStore.load：调度值域非法 → 仅该字段 nil，
//    mode/限值/风扇保留——与 fan 整包 nil 分层不同，R1 P1-2/R2 P3）
// ⑤ Codable 向后兼容（无该字段旧 policy.json 解码成功；调度与 fan 并存互不覆盖）
// ⑥ wire 编解码（三键缺席保持/新值覆盖/值域拒绝/STRING 类型混淆整包拒绝）
// ⑦ 终态映射（五终态全等归一/相位字面量→nil/非校准字面量 nil/未知字面量 nil）
// ⑧ state 文件往返 + 损坏容错 + 缺失容错 + 0644/tmp 清理
// ⑨ 下次预估推算（就绪中/未到期/到期窗口已过次日/禁用/负差值 nil/逾期就绪收敛）
// ⑩ AppSide 派生助手（calSched 强类型视图/旧 daemon nil 门控/预估 nil 面/Codable 往返）

import CellarCore
import Foundation
import XPC

/// 校准调度场景域入口（Main.main 调用；窗口/预估按本地时区钟面表达）。
func runCalibrationScheduleDomainScenarios() throws {
    let calendar = Calendar.current

    /// 本地钟面构造助手（窗口判定按用户本地时钟——daemon 与本工具同机同 tz，
    /// 固定基准日防随机性）。
    func localTime(day: Int, hour: Int, minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        return calendar.date(from: comps)!
    }

    /// 独立期望：某日窗口起点（与实现不同写法的第二双眼睛——startOfDay + startHour）。
    func windowStart(of day: Date, startHour: Int) -> Date {
        calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: calendar.startOfDay(for: day))!
    }

    // ---- ① 窗口判定（方案 §1.9 跨午夜事实）----

    // 调度-1：起点边界（startHour=1，窗口 [1, 5)）。
    do {
        let schedule = CalibrationSchedulePolicy(enabled: true, intervalDays: 30, startHour: 1)
        let results = [0, 1, 2, 4, 5, 12].map { schedule.isWithinWindow(hour: $0) }
        check(results == [false, true, true, true, false, false],
              "调度-1", "startHour=1：hour 0/5/12 窗口外、1/2/4 窗口内（半开区间 [1,5)）")
    }

    // 调度-2：跨午夜（startHour=22，窗口 [22, 26)≡[22,24)∪[0,2)）。
    do {
        let schedule = CalibrationSchedulePolicy(enabled: true, intervalDays: 30, startHour: 22)
        let results = [21, 22, 23, 0, 1, 2, 12].map { schedule.isWithinWindow(hour: $0) }
        check(results == [false, true, true, true, true, false, false],
              "调度-2", "startHour=22 跨午夜（模 24 判定）：21/2/12 窗口外、22/23/0/1 窗口内")
    }

    // 调度-3：windowHours 常量钉死 + startHour=0 午夜起点边界。
    check(CalibrationSchedulePolicy.windowHours == 4,
          "调度-3", "windowHours 定版 4（凌晨低负载窗口；改动即方案偏离）")
    do {
        let midnight = CalibrationSchedulePolicy(enabled: true, intervalDays: 30, startHour: 0)
        let results = [0, 3, 4, 23].map { midnight.isWithinWindow(hour: $0) }
        check(results == [true, true, false, false],
              "调度-3", "startHour=0：0-3 窗口内、4/23 窗口外（模 24 对零起点无偏移）")
    }

    // ---- ② 就绪判定（方案 §2.1）----

    // 调度-4：首次启用 nil 锚点 → 就绪；禁用 → 不就绪（即便窗口内 + nil 锚点）。
    do {
        let on = CalibrationSchedulePolicy(enabled: true, intervalDays: 30, startHour: 1)
        let off = CalibrationSchedulePolicy(enabled: false, intervalDays: 30, startHour: 1)
        let inWindow = localTime(day: 1, hour: 3)
        check(calibrationAutoStartReady(now: inWindow, lastStartedAt: nil, schedule: on),
              "调度-4", "enabled + 窗口内 + nil 锚点 → 就绪（首次启用即明确意愿，UD-4）")
        check(!calibrationAutoStartReady(now: inWindow, lastStartedAt: nil, schedule: off),
              "调度-4", "禁用 → 恒不就绪（opt-in 默认关，UD-2）")
    }

    // 调度-5：间隔判定（恰好 30 天就绪 / 差 1 秒未就绪）。
    do {
        let schedule = CalibrationSchedulePolicy(enabled: true, intervalDays: 30, startHour: 1)
        let now = localTime(day: 31, hour: 3)   // 窗口内钟面
        let exact = calendar.date(byAdding: .day, value: -30, to: now)!
        let shortByASecond = exact.addingTimeInterval(1)
        check(calibrationAutoStartReady(now: now, lastStartedAt: exact, schedule: schedule),
              "调度-5", "距上次启动恰好 intervalDays 天 → 就绪（≥ 判定含边界）")
        check(!calibrationAutoStartReady(now: now, lastStartedAt: shortByASecond, schedule: schedule),
              "调度-5", "差 1 秒满 intervalDays → 未就绪（严格下界）")
    }

    // 调度-6：负差值 clamp（时钟回拨/NTP 校正视为刚校准过，不就绪，R1 P2）。
    do {
        let schedule = CalibrationSchedulePolicy(enabled: true, intervalDays: 30, startHour: 1)
        let now = localTime(day: 1, hour: 3)
        let future = now.addingTimeInterval(3600)
        check(!calibrationAutoStartReady(now: now, lastStartedAt: future, schedule: schedule),
              "调度-6", "锚点在未来（时钟回拨）→ 不就绪（max(0, 负差值) clamp 0 < interval）")
    }

    // ---- ③ validated 值域 ----

    // 调度-7：默认值钉死（R2 P3：false / 30 / 1）+ 默认整体过 validated。
    do {
        let d = CalibrationSchedulePolicy.default
        check(!d.enabled && d.intervalDays == 30 && d.startHour == 1,
              "调度-7", ".default = enabled false / 30 天 / 01:00（App Picker 预选 30、起点预选 01:00）")
        check(CalibrationSchedulePolicy.validated(
            enabled: d.enabled, intervalDays: d.intervalDays, startHour: d.startHour
        ) == d, "调度-7", "默认值整体过 validated")
    }

    // 调度-8：validated 越界 → nil（任何字段越界即拒，绝不半合法）。
    check(CalibrationSchedulePolicy.validated(enabled: true, intervalDays: 0, startHour: 1) == nil
            && CalibrationSchedulePolicy.validated(enabled: true, intervalDays: 181, startHour: 1) == nil
            && CalibrationSchedulePolicy.validated(enabled: true, intervalDays: 30, startHour: -1) == nil
            && CalibrationSchedulePolicy.validated(enabled: true, intervalDays: 30, startHour: 24) == nil,
          "调度-8", "intervalDays 0/181、startHour -1/24 越界 → nil（值域 1...180 / 0...23）")
    check(CalibrationSchedulePolicy.validated(enabled: true, intervalDays: 1, startHour: 0) != nil
            && CalibrationSchedulePolicy.validated(enabled: false, intervalDays: 180, startHour: 23) != nil,
          "调度-8", "区间端点 1/180、0/23 合法（构造往返）")

    // ---- ④ 「仅丢字段」分层语义（PolicyStore.load 校验块；R1 P1-2 定版）----

    // 调度-9：调度值域非法回流 → 仅丢该字段，mode/限值/fan 保留（与 fan 整包 nil 分层不同）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-calsched-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy.json")
        let fanJSON = #"{"enabled":true,"strategy":"constantSpeed","thresholdCentiC":3700,"releaseHysteresisCentiC":200,"speedPercent":60,"stage2Percent":90,"stage2RiseCentiC":300}"#
        try #"""
        {"mode":"active","upperLimit":80,"hysteresis":2,"fan":\#(fanJSON),"calibrationSchedule":{"enabled":true,"intervalDays":0,"startHour":1}}
        """#.write(to: url, atomically: true, encoding: .utf8)
        let loaded = PolicyStore(url: url).load()
        check(loaded != nil && loaded?.calibrationSchedule == nil && loaded?.mode == "active"
                && loaded?.upperLimit == 80 && loaded?.fan != nil,
              "调度-9", "调度 intervalDays=0 回流 → 仅丢该字段（mode/限值/fan 保留，不连累限充策略）")

        let url2 = directory.appendingPathComponent("policy2.json")
        try #"""
        {"mode":"active","upperLimit":80,"hysteresis":2,"calibrationSchedule":{"enabled":true,"intervalDays":30,"startHour":24}}
        """#.write(to: url2, atomically: true, encoding: .utf8)
        let loaded2 = PolicyStore(url: url2).load()
        check(loaded2 != nil && loaded2?.calibrationSchedule == nil && loaded2?.upperLimit == 80,
              "调度-9", "startHour=24 回流 → 同款仅丢字段（第二个越界维度直测）")
    }

    // ---- ⑤ Codable 向后兼容（合成 decodeIfPresent）----

    // 调度-10：旧 policy.json 无 calibrationSchedule 键 → nil；调度与 fan 并存往返互不覆盖。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-calsched-codable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy.json")
        // 0.8.0 形态：无 calibrationSchedule 键。
        try #"{"mode":"active","upperLimit":75,"hysteresis":3}"#.write(to: url, atomically: true, encoding: .utf8)
        let legacy = PolicyStore(url: url).load()
        check(legacy?.calibrationSchedule == nil && legacy?.upperLimit == 75,
              "调度-10", "旧 JSON 无 calibrationSchedule 键 → nil（decodeIfPresent 兼容）")

        let store = PolicyStore(url: url)
        let fan = FanPolicy.validated(
            enabled: true, strategy: .constantSpeed, thresholdCentiC: 3700,
            releaseHysteresisCentiC: 200, speedPercent: 60, stage2Percent: 90, stage2RiseCentiC: 300
        )
        let original = DaemonPolicy(
            mode: "active", upperLimit: 80, hysteresis: 2, autoDischargeEnabled: true,
            fan: fan, calibrationSchedule: CalibrationSchedulePolicy(enabled: true, intervalDays: 7, startHour: 22)
        )
        try store.save(original)
        let loaded = store.load()
        check(loaded?.calibrationSchedule == original.calibrationSchedule && loaded?.fan == original.fan
                && loaded?.autoDischargeEnabled == true,
              "调度-10", "调度 + fan + auto 并存往返互不覆盖（F-1 镜像条款）")
    }

    // ---- ⑥ wire 编解码（照 FanWire 全套先例）----

    // 调度-11：缺席保持合并——空 wire 原样返回 base；单键 wire 只改该键。
    do {
        let base = CalibrationSchedulePolicy(enabled: false, intervalDays: 30, startHour: 1)
        let empty = CalibrationScheduleWire().mergedPolicy(base: base)
        check(empty == base, "调度-11", "三键全缺席 → 合并结果 == base（缺席保持语义）")
        let single = CalibrationScheduleWire(intervalDays: 7).mergedPolicy(base: base)
        check(single == CalibrationSchedulePolicy(enabled: false, intervalDays: 7, startHour: 1),
              "调度-11", "仅 intervalDays 键 → 只改周期（enabled/startHour 保持）")
        let all = CalibrationScheduleWire(CalibrationSchedulePolicy(enabled: true, intervalDays: 14, startHour: 22))
            .mergedPolicy(base: base)
        check(all == CalibrationSchedulePolicy(enabled: true, intervalDays: 14, startHour: 22),
              "调度-11", "全键构造（CalibrationScheduleWire(policy)）→ 三键全覆盖（App 全键下发路径）")
    }

    // 调度-12：valid* 值域拒绝 + 与 validated 同源抽查（XPCServer 臂拒绝 == 持久化回流拒绝）。
    do {
        let enabledOK = CalibrationScheduleWireKeys.validEnabled(0)
            && CalibrationScheduleWireKeys.validEnabled(1)
            && !CalibrationScheduleWireKeys.validEnabled(2)
        let intervalOK = CalibrationScheduleWireKeys.validIntervalDays(1)
            && CalibrationScheduleWireKeys.validIntervalDays(180)
            && !CalibrationScheduleWireKeys.validIntervalDays(0)
            && !CalibrationScheduleWireKeys.validIntervalDays(181)
        let hourOK = CalibrationScheduleWireKeys.validStartHour(0)
            && CalibrationScheduleWireKeys.validStartHour(23)
            && !CalibrationScheduleWireKeys.validStartHour(24)
        check(enabledOK && intervalOK && hourOK,
              "调度-12", "valid* 值域：enabled 0/1、intervalDays 1...180、startHour 0...23（边界两侧）")
        let mergedBad = CalibrationScheduleWire(intervalDays: 181).mergedPolicy(
            base: CalibrationSchedulePolicy.default
        )
        check(mergedBad == nil,
              "调度-12", "mergedPolicy 非法 → nil（validated 同源——不落半合法策略）")
    }

    // 调度-13：XPC makeMessage/validateRequest——三键编解回；STRING 类型混淆整包拒绝；
    // 非本命令全键缺席 → calSched nil（既有命令兼容）。
    do {
        let message = DaemonXPC.makeMessage(
            cmd: CalibrationScheduleWireKeys.command, upper: 0, hysteresis: 0,
            calSched: CalibrationScheduleWire(enabled: 1, intervalDays: 14, startHour: 22)
        )
        let parsed = DaemonXPC.validateRequest(message)
        check(parsed?.cmd == "setCalibrationSchedule"
                && parsed?.calSched == CalibrationScheduleWire(enabled: 1, intervalDays: 14, startHour: 22),
              "调度-13", "三键发出并解回（UINT64 线格式 round-trip）")

        let partial = DaemonXPC.makeMessage(
            cmd: CalibrationScheduleWireKeys.command, upper: 0, hysteresis: 0,
            calSched: CalibrationScheduleWire(startHour: 5)
        )
        check(DaemonXPC.validateRequest(partial)?.calSched == CalibrationScheduleWire(startHour: 5),
              "调度-13", "单键发出 → 其余键缺席保持 nil（缺席 = 不发键）")

        let mixed = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(mixed, DaemonXPC.cmdKey, "setCalibrationSchedule")
        xpc_dictionary_set_uint64(mixed, DaemonXPC.upperKey, 0)
        xpc_dictionary_set_uint64(mixed, DaemonXPC.hysteresisKey, 0)
        xpc_dictionary_set_string(mixed, CalibrationScheduleWireKeys.intervalDays, "14")   // STRING 混入 UINT64 键
        check(DaemonXPC.validateRequest(mixed) == nil,
              "调度-13", "STRING 类型混淆 → 整包拒绝（validateRequest 白名单，不崩溃）")

        let plain = DaemonXPC.makeMessage(cmd: "setLimits", upper: 80, hysteresis: 2)
        let plainParsed = DaemonXPC.validateRequest(plain)
        check(plainParsed?.calSched == nil && plainParsed?.cmd == "setLimits",
              "调度-13", "非 setCalibrationSchedule 全键缺席 → calSched nil（既有命令兼容）")
    }

    // ---- ⑦ 终态映射（全等匹配，R1 P2）----

    // 调度-14：五终态全等归一（字面量构造器同源——wire 格式永不本地化）。
    check(calibrationOutcomeLiteral(CalibrationLiteral.done()) == .done
            && calibrationOutcomeLiteral(CalibrationLiteral.cancel()) == .cancel
            && calibrationOutcomeLiteral(CalibrationLiteral.timeout()) == .timeout
            && calibrationOutcomeLiteral(CalibrationLiteral.safety()) == .safety
            && calibrationOutcomeLiteral(CalibrationLiteral.cancelCrashRecovery()) == .crashRecovery,
          "调度-14", "五终态字面量全等归一（done/cancel/timeout/safety/crash-recovery）")
    do {
        let words = CalibrationOutcome.allCases.map(\.rawValue)
        check(words == ["done", "cancel", "timeout", "safety", "crash-recovery"],
              "调度-14", "归一词五值 rawValue 钉死（state 文件 wire 契约，M3 l10n 一一对齐）")
    }

    // 调度-15：相位字面量同前缀但必须 → nil（全等排除，R1 P2）+ 非校准/未知字面量 → nil。
    check(calibrationOutcomeLiteral(CalibrationLiteral.phase(.chargeFull)) == nil
            && calibrationOutcomeLiteral(CalibrationLiteral.phase(.hold)) == nil
            && calibrationOutcomeLiteral(CalibrationLiteral.phase(.discharge)) == nil,
          "调度-15", "相位字面量 chargeFull/hold/discharge 同前缀 → nil（全等匹配非前缀匹配）")
    check(calibrationOutcomeLiteral("fullOnce:done") == nil
            && calibrationOutcomeLiteral("dischargeToLimit:safety") == nil
            && calibrationOutcomeLiteral("enforce:noop") == nil
            && calibrationOutcomeLiteral("calibration:done ") == nil
            && calibrationOutcomeLiteral("calibration:") == nil,
          "调度-15", "非校准字面量/未知字面量/近似串（尾随空格、截断）→ nil")

    // ---- ⑧ state 文件（CalibrationStateStore；方案 §2.2）----

    // 调度-16：往返保真 + 缺失/损坏容错 + 0644 + tmp 无残留。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-calsched-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CalibrationStateStore(url: directory.appendingPathComponent("calibration-state.json"))

        check(store.load() == .empty, "调度-16", "文件缺失 → 空状态容错（不抛错打断启动路径）")

        var state = CalibrationState(lastStartedAt: 1_000)
        state.lastCalibration = CalibrationState.LastCalibrationRecord(
            startedAt: 1_000, endedAt: 36_000, outcome: "done"
        )
        try store.save(state)
        check(store.load() == state, "调度-16", "锚点 + 终态记录往返保真")
        let permissions = (try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber)?.uint16Value
        check(permissions == 0o644, "调度-16", "文件权限 0644（ActionStore 同款）")
        check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".calibration-state.json.tmp").path),
              "调度-16", "原子写后 tmp 无残留（defer 清理）")

        try Data("not json".utf8).write(to: store.url)
        check(store.load() == .empty, "调度-16", "损坏（非 JSON）→ 空状态容错（锚点重置 = 可能多发一次校准，低害）")
    }

    // ---- ⑨ 下次预估推算（方案 §2.1 NextEstimate）----

    // 调度-17：就绪中 → 当日窗口起点；未到期 → 到期日窗口起点；到期时当日窗口已过 → 次日；
    // 禁用/负差值 → nil。
    do {
        let schedule = CalibrationSchedulePolicy(enabled: true, intervalDays: 30, startHour: 1)

        // 就绪中（nil 锚点、当前在窗口内 03:00）→ 当日 01:00（窗口起点）。
        let readyNow = localTime(day: 1, hour: 3)
        check(nextAutoCalibrationEstimate(now: readyNow, schedule: schedule, lastStartedAt: nil)
                == windowStart(of: readyNow, startHour: 1),
              "调度-17", "就绪中（窗口内）→ 当日窗口起点（01:00）")

        // 未到期（锚点 03:00，30 天周期 → 到期日 03:00 仍在窗口 [1,5) 内）→ 到期日 01:00。
        let anchor = localTime(day: 1, hour: 3)
        let now20 = calendar.date(byAdding: .day, value: 20, to: anchor)!
        let due = calendar.date(byAdding: .day, value: 30, to: anchor)!
        check(nextAutoCalibrationEstimate(now: now20, schedule: schedule, lastStartedAt: anchor)
                == windowStart(of: due, startHour: 1),
              "调度-17", "未到期 → intervalDays 到期时刻当日窗口起点（到期 03:00 落在 [1,5) 内）")

        // 到期时当日窗口已过（锚点 12:00 → 到期 12:00 > 窗口结束 05:00）→ 次日 01:00。
        let anchorNoon = localTime(day: 1, hour: 12)
        let dueNoon = calendar.date(byAdding: .day, value: 30, to: anchorNoon)!
        let expectedNextDay = calendar.date(byAdding: .day, value: 1, to: windowStart(of: dueNoon, startHour: 1))!
        check(nextAutoCalibrationEstimate(now: anchorNoon.addingTimeInterval(86400 / 2), schedule: schedule, lastStartedAt: anchorNoon)
                == expectedNextDay,
              "调度-17", "到期时刻已过当日窗口 → 次日窗口起点（错过顺延语义）")

        // 禁用 → nil；负差值（时钟回拨）→ nil（预估与就绪判定同一 clamp 口径）。
        let disabled = CalibrationSchedulePolicy(enabled: false, intervalDays: 30, startHour: 1)
        check(nextAutoCalibrationEstimate(now: readyNow, schedule: disabled, lastStartedAt: nil) == nil,
              "调度-17", "禁用 → nil")
        check(nextAutoCalibrationEstimate(now: readyNow, schedule: schedule, lastStartedAt: readyNow.addingTimeInterval(3600)) == nil,
              "调度-17", "锚点在未来（负差值）→ nil（预估行上屏「—」）")
    }

    // 调度-19：逾期就绪收敛（P2-2）——到期日已过 → 以 now 起算下一窗口起点（与
    // nil 锚点就绪分支同形），绝不上屏过去日期（M3 预估行）。
    do {
        let schedule = CalibrationSchedulePolicy(enabled: true, intervalDays: 3, startHour: 1)
        let anchor = localTime(day: 1, hour: 12)   // 9/1 12:00 启动 → 9/4 12:00 到期
        // 逾期 + now 在窗口内（9/8 03:00）→ 当日窗口起点（与就绪中 nil 锚点分支一致）。
        let nowInWindow = localTime(day: 8, hour: 3)
        check(nextAutoCalibrationEstimate(now: nowInWindow, schedule: schedule, lastStartedAt: anchor)
                == windowStart(of: nowInWindow, startHour: 1),
              "调度-19", "逾期就绪（now 在窗口内）→ 当日窗口起点（与 nil 锚点就绪分支同形）")
        // 逾期 + now 窗口已过（9/8 12:00）→ 次日窗口起点（≥ now）。
        let nowPastWindow = localTime(day: 8, hour: 12)
        let estimate = nextAutoCalibrationEstimate(now: nowPastWindow, schedule: schedule, lastStartedAt: anchor)
        check(estimate == calendar.date(byAdding: .day, value: 1, to: windowStart(of: nowPastWindow, startHour: 1))!
                && estimate! > nowPastWindow,
              "调度-19", "逾期就绪（now 窗口已过）→ 次日窗口起点（≥now）")
        // 回归对照（修复前形态）：不再返回已过到期日（9/4）的窗口起点。
        let staleDue = calendar.date(byAdding: .day, value: 3, to: anchor)!
        check(nextAutoCalibrationEstimate(now: nowPastWindow, schedule: schedule, lastStartedAt: anchor)
                != windowStart(of: staleDue, startHour: 1),
              "调度-19", "不再返回已过到期日的窗口起点（过去日期，P2-2 回归钉死）")
    }

    // ---- ⑩ AppSide 派生助手（DaemonStatus calSched 强类型视图）----

    // 调度-18：三键 → 强类型策略；缺一键 → nil（防半视图）；旧 daemon 全缺 → nil；
    // 禁用视图预估 nil；编解码往返保留新字段。
    do {
        let status = DaemonStatus(
            version: "fixture", mode: "active", upperLimit: 80, hysteresis: 2,
            calSchedEnabled: true, calSchedIntervalDays: 14, calSchedStartHour: 22,
            lastCalStart: 1_000, lastCalEnd: 36_000, lastCalOutcome: "done"
        )
        check(status.calibrationSchedule == CalibrationSchedulePolicy(enabled: true, intervalDays: 14, startHour: 22),
              "调度-18", "calSched 三键 → calibrationSchedule 强类型视图")

        var half = status
        half.calSchedStartHour = nil
        check(half.calibrationSchedule == nil,
              "调度-18", "缺任一键 → nil（防半视图——三键恒填纪律的客户端镜像）")

        let legacy = DaemonStatus(version: "fixture", mode: "active", upperLimit: 80, hysteresis: 2)
        check(legacy.calibrationSchedule == nil && legacy.nextAutoCalibrationEstimate == nil,
              "调度-18", "旧 daemon 回包全键缺席 → 视图 nil + 预估 nil（整卡升级提示门控，UD-7）")

        var off = DaemonStatus(
            version: "fixture", mode: "active", upperLimit: 80, hysteresis: 2,
            calSchedEnabled: false, calSchedIntervalDays: 30, calSchedStartHour: 1
        )
        check(off.calibrationSchedule == CalibrationSchedulePolicy.default && off.nextAutoCalibrationEstimate == nil,
              "调度-18", "未配置恒填 .default（非 nil = 正常 off 态，勿当旧 daemon）+ 禁用预估 nil")
        off.calSchedEnabled = true
        off.lastCalStart = Int(Date().timeIntervalSince1970) + 3600   // 锚点在未来
        check(off.nextAutoCalibrationEstimate == nil,
              "调度-18", "负差值（时钟回拨）→ 预估 nil（上屏「—」，与纯函数同口径）")

        let round = try JSONDecoder().decode(DaemonStatus.self, from: JSONEncoder().encode(status))
        check(round.calSchedEnabled == true && round.calSchedIntervalDays == 14
                && round.lastCalOutcome == "done" && round.lastCalStart == 1_000,
              "调度-18", "DaemonStatus 新字段编解码往返（合成 Codable）")
        let legacyDecoded = try JSONDecoder().decode(
            DaemonStatus.self,
            from: Data(#"{"version":"x","mode":"active","upperLimit":80,"hysteresis":2,"timestamp":0}"#.utf8)
        )
        check(legacyDecoded.calSchedEnabled == nil && legacyDecoded.lastCalStart == nil,
              "调度-18", "旧 JSON（无新键）解码成功全 nil（decodeIfPresent 向后兼容）")
    }
}
