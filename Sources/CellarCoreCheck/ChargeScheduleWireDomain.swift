// CellarCoreCheck —— Phase 5 v1.6 充电日程 wire/持久化/兼容场景域（方案 §2.4 清单 /
// 工单 M2 要点 7；与 ChargeScheduleDomain.swift 同域拆分——FanDomain/FanDoctorDomain
// 先例，各文件 ≤400 行。基准条目/配置 fixture 来自 ChargeScheduleDomain.swift 的
// internal 全局）。
//
// daemon 为 executable 不可 import——setChargeScheduleConfig 三级校验的服务端接线归
// code-reviewer 走查必查项；本文件覆盖其可测纯函数面（validateRequest 白名单 +
// JSON 解码/validated 组合）与持久化/回读兼容。
//
// 本文件覆盖清单：
// ⑤ wire 字符串键编解码（round-trip/缺席保持/类型混淆整包拒/长度 8192 边界两侧）
// ⑥ JSON 解码 + validated 组合（合法/坏 JSON/条数越限/weekdays 非法/越域 limit/
//    双动作全 nil/null 可选字段）
// ⑦ DaemonStatus 兼容（新 daemon 两键往返/旧回包 nil decodeIfPresent）
// ⑧ PolicyStore（日程结构非法仅丢字段/与其他可选字段并存互不覆盖/旧 JSON 兼容）
// ⑨ ScheduleState 文件（往返含 base 快照字段/损坏容错/缺失容错/0644/tmp 无残留/
//    .empty 形态钉死）

import CellarCore
import Foundation
import XPC

/// 充电日程 wire/持久化/兼容域入口（Main.main 调用）。
func runChargeScheduleWireDomainScenarios() throws {
    let workday = scheduleWorkdayEntry
    let workdayConfig = scheduleWorkdayConfig

    // ---- ⑤ wire 字符串键编解码（validateRequest 白名单纯函数面）----

    // 日程-20：makeMessage/validateRequest round-trip + 既有命令键缺席保持。
    do {
        let json = workdayConfig.encoded!
        let message = DaemonXPC.makeMessage(
            cmd: ChargeScheduleWireKeys.command, upper: 0, hysteresis: 0,
            schedule: ChargeScheduleWire(scheduleJson: json)
        )
        let parsed = DaemonXPC.validateRequest(message)
        check(parsed?.cmd == ChargeScheduleWireKeys.command && parsed?.schedule?.scheduleJson == json,
              "日程-20", "scheduleJson 字符串键发出并解回（round-trip 保真）")
        check(parsed?.fan == nil && parsed?.thermal == nil && parsed?.calSched == nil,
              "日程-20", "其余键族缺席保持 nil（新命令不夹带）")

        let plain = DaemonXPC.makeMessage(cmd: "setLimits", upper: 80, hysteresis: 2)
        check(DaemonXPC.validateRequest(plain)?.schedule == nil,
              "日程-20", "非 setChargeSchedule 不发键 → schedule nil（既有命令兼容）")

        let carried = DaemonXPC.makeMessage(cmd: "setLimits", upper: 80, hysteresis: 2,
                                            schedule: ChargeScheduleWire(scheduleJson: json))
        check(DaemonXPC.validateRequest(carried)?.schedule?.scheduleJson == json,
              "日程-20", "键解析与命令字面量正交（与 fan/thermal 键族同语义）")
    }

    // 日程-21：类型混淆整包拒绝 + 长度 8192 边界两侧（R-3 输入面收口）。
    do {
        let mixed = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(mixed, DaemonXPC.cmdKey, ChargeScheduleWireKeys.command)
        xpc_dictionary_set_uint64(mixed, DaemonXPC.upperKey, 0)
        xpc_dictionary_set_uint64(mixed, DaemonXPC.hysteresisKey, 0)
        xpc_dictionary_set_uint64(mixed, ChargeScheduleWireKeys.scheduleJson, 1)   // UINT64 混入字符串键
        check(DaemonXPC.validateRequest(mixed) == nil,
              "日程-21", "scheduleJson 键 UINT64 混入 → 整包拒绝（STRING 白名单，不崩溃）")

        let atLimit = String(repeating: "a", count: 8192)
        let overLimit = String(repeating: "a", count: 8193)
        let atMessage = DaemonXPC.makeMessage(
            cmd: ChargeScheduleWireKeys.command, upper: 0, hysteresis: 0,
            schedule: ChargeScheduleWire(scheduleJson: atLimit)
        )
        check(DaemonXPC.validateRequest(atMessage)?.schedule?.scheduleJson == atLimit,
              "日程-21", "恰好 8192 字节放行（边界含入）")
        let overMessage = DaemonXPC.makeMessage(
            cmd: ChargeScheduleWireKeys.command, upper: 0, hysteresis: 0,
            schedule: ChargeScheduleWire(scheduleJson: overLimit)
        )
        check(DaemonXPC.validateRequest(overMessage) == nil,
              "日程-21", "8193 字节 → 整包拒绝（validateRequest 白名单长度门）")
        check(ChargeScheduleWireKeys.validLength(atLimit) && !ChargeScheduleWireKeys.validLength(overLimit),
              "日程-21", "validLength 与 validateRequest 同源（validateRequest/服务端臂/config 三处共用）")
    }

    // ---- ⑥ JSON 解码 + validated 组合（setChargeScheduleConfig ②③级的同源纯函数面）----

    // 日程-22：合法 JSON 三级全过；坏 JSON 解码失败原文上抛。
    do {
        let decoded = try ChargeScheduleConfig.decoded(from: workdayConfig.encoded!)
        check(ChargeScheduleConfig.validated(enabled: decoded.enabled, entries: decoded.entries) == workdayConfig,
              "日程-22", "合法 JSON → 解码 + validated 全过（daemon ②③级同源路径）")
        do {
            _ = try ChargeScheduleConfig.decoded(from: "{not json")
            check(false, "日程-22", "坏 JSON 应抛错")
        } catch {
            check(!String(describing: error).isEmpty,
                  "日程-22", "坏 JSON → 解码抛错原文（并入 malformedJSON 回传，不静默吞）")
        }
    }

    // 日程-23：解码成功但 validated 拒（9 条/weekdays 非法/limit 越域/双动作全 nil）。
    do {
        func rejects(_ json: String, _ label: String) {
            guard let decoded = try? ChargeScheduleConfig.decoded(from: json) else {
                check(false, label, "fixture 应可解码：\(json)")
                return
            }
            check(ChargeScheduleConfig.validated(enabled: decoded.enabled, entries: decoded.entries) == nil,
                  label, "解码成功但 validated 拒（第三级兜底——类型合法值域非法不落半合法）")
        }
        rejects(#"{"enabled":true,"entries":[{"id":"a","weekdays":[1],"startMinute":0,"endMinute":10,"upperLimit":80},{"id":"b","weekdays":[1],"startMinute":0,"endMinute":10,"upperLimit":80},{"id":"c","weekdays":[1],"startMinute":0,"endMinute":10,"upperLimit":80},{"id":"d","weekdays":[1],"startMinute":0,"endMinute":10,"upperLimit":80},{"id":"e","weekdays":[1],"startMinute":0,"endMinute":10,"upperLimit":80},{"id":"f","weekdays":[1],"startMinute":0,"endMinute":10,"upperLimit":80},{"id":"g","weekdays":[1],"startMinute":0,"endMinute":10,"upperLimit":80},{"id":"h","weekdays":[1],"startMinute":0,"endMinute":10,"upperLimit":80},{"id":"i","weekdays":[1],"startMinute":0,"endMinute":10,"upperLimit":80}]}"#,
                "日程-23")
        rejects(#"{"enabled":true,"entries":[{"id":"a","weekdays":[9],"startMinute":0,"endMinute":10,"upperLimit":80}]}"#,
                "日程-23")
        rejects(#"{"enabled":true,"entries":[{"id":"a","weekdays":[1],"startMinute":0,"endMinute":10,"upperLimit":101}]}"#,
                "日程-23")
        rejects(#"{"enabled":true,"entries":[{"id":"a","weekdays":[1],"startMinute":0,"endMinute":10}]}"#,
                "日程-23")
    }

    // 日程-24：null 可选字段与字段缺席解码（合成 decodeIfPresent——null/缺席皆 nil）。
    do {
        let json = #"{"enabled":true,"entries":[{"id":"a","weekdays":[2],"startMinute":1320,"endMinute":420,"chargingDisabled":true}]}"#
        let config = try ChargeScheduleConfig.decoded(from: json)
        check(config.entries.first?.chargingDisabled == true && config.entries.first?.upperLimit == nil,
              "日程-24", "null/缺席可选字段 → nil（跨午夜 + 放开充电条目形态）")
        check(ChargeScheduleConfig.validated(enabled: config.enabled, entries: config.entries) == config,
              "日程-24", "该形态过 validated（chargingDisabled 单动作合法）")
    }

    // ---- ⑦ DaemonStatus 兼容 ----

    // 日程-25：两键往返 + 旧回包/旧 JSON 缺席 → nil（decodeIfPresent 向后兼容）。
    // ⚠️ 字符串只 encode 一次再比对：新 Foundation JSONEncoder 的键序逐次非确定
    //（2026 实证）——App/daemon 一致性承诺在「解码等值」（值语义），非字节串等值。
    do {
        let encodedOnce = workdayConfig.encoded!
        let status = DaemonStatus(
            version: "fixture", mode: "active", upperLimit: 80, hysteresis: 2,
            scheduleJson: encodedOnce, scheduleActiveId: workday.id
        )
        let round = try JSONDecoder().decode(DaemonStatus.self, from: JSONEncoder().encode(status))
        check(round.scheduleJson == encodedOnce && round.scheduleActiveId == workday.id,
              "日程-25", "scheduleJson/scheduleActiveId 编解码往返（合成 Codable；嵌入串逐字节保真）")
        let legacyDecoded = try JSONDecoder().decode(
            DaemonStatus.self,
            from: Data(#"{"version":"x","mode":"active","upperLimit":80,"hysteresis":2,"timestamp":0}"#.utf8)
        )
        check(legacyDecoded.scheduleJson == nil && legacyDecoded.scheduleActiveId == nil,
              "日程-25", "旧 daemon JSON（无新键）解码成功全 nil（App 据此整卡升级提示，UD-6）")
        let emptyFill = ChargeScheduleConfig.default.encoded!
        check((try ChargeScheduleConfig.decoded(from: emptyFill)) == .default,
              "日程-25", "恒填空配置 JSON 解码 == .default（新 daemon 未配置用户非 nil——勿当旧 daemon，UD-7）")
    }

    // ---- ⑧ PolicyStore 校验块 ----

    // 日程-26：日程结构非法回流 → 仅丢该字段（mode/限值/fan 保留——照 thermal 块，勿照 fan 整包 nil）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-schedule-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fanJSON = #"{"enabled":true,"strategy":"constantSpeed","thresholdCentiC":3700,"releaseHysteresisCentiC":200,"speedPercent":60,"stage2Percent":90,"stage2RiseCentiC":300}"#
        let url = directory.appendingPathComponent("policy.json")
        try #"""
        {"mode":"active","upperLimit":80,"hysteresis":2,"fan":\#(fanJSON),"schedule":{"enabled":true,"entries":[{"id":"bad","weekdays":[],"startMinute":0,"endMinute":60,"upperLimit":80}]}}
        """#.write(to: url, atomically: true, encoding: .utf8)
        let loaded = PolicyStore(url: url).load()
        check(loaded != nil && loaded?.schedule == nil && loaded?.mode == "active"
                && loaded?.upperLimit == 80 && loaded?.fan != nil,
              "日程-26", "日程 weekdays 空 回流 → 仅丢该字段（mode/限值/fan 不受连累，R-9 回落）")

        let url2 = directory.appendingPathComponent("policy2.json")
        try #"{"mode":"active","upperLimit":75,"hysteresis":3}"#.write(to: url2, atomically: true, encoding: .utf8)
        let legacy = PolicyStore(url: url2).load()
        check(legacy?.schedule == nil && legacy?.upperLimit == 75,
              "日程-26", "旧 JSON 无 schedule 键 → nil（decodeIfPresent 兼容）")
    }

    // 日程-27：日程与其他可选字段并存往返互不覆盖（F-1 镜像条款）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-schedule-round-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PolicyStore(url: directory.appendingPathComponent("policy.json"))
        let thermal = ThermalPolicy.validated(pauseCentiC: 3800, hysteresisCentiC: 500)
        let original = DaemonPolicy(
            mode: "active", upperLimit: 80, hysteresis: 2, autoDischargeEnabled: true,
            calibrationSchedule: CalibrationSchedulePolicy(enabled: true, intervalDays: 7, startHour: 22),
            thermal: thermal, schedule: workdayConfig
        )
        try store.save(original)
        let loaded = store.load()
        check(loaded?.schedule == original.schedule && loaded?.thermal == original.thermal
                && loaded?.calibrationSchedule == original.calibrationSchedule
                && loaded?.autoDischargeEnabled == true,
              "日程-27", "schedule + thermal + calibrationSchedule + auto 并存往返互不覆盖（F-1 镜像）")
    }

    // ---- ⑨ ScheduleState 文件 ----

    // 日程-28：往返保真（含 base 快照字段）+ 0644 + tmp 无残留。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-schedule-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScheduleStateStore(url: directory.appendingPathComponent("schedule-state.json"))

        check(store.load() == .empty, "日程-28", "文件缺失 → 空状态容错（不抛错打断启动路径）")

        let state = ScheduleState(
            lastAppliedEntryId: "workday1-1111", baseUpperLimit: 80,
            baseMode: "active", lastAppliedAt: 1_788_000_000
        )
        try store.save(state)
        check(store.load() == state, "日程-28", "lastApplied + base 快照双字段 + 时刻往返保真")
        let permissions = (try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber)?.uint16Value
        check(permissions == 0o644, "日程-28", "文件权限 0644（CalibrationStateStore 同款）")
        check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".schedule-state.json.tmp").path),
              "日程-28", "原子写后 tmp 无残留（defer 清理）")
    }

    // 日程-29：损坏（非 JSON / 字段不符）→ 空状态容错（UD-3 重算自愈；R-8 已知边界）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-schedule-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScheduleStateStore(url: directory.appendingPathComponent("schedule-state.json"))
        try Data("not json".utf8).write(to: store.url)
        check(store.load() == .empty, "日程-29", "非 JSON → 空状态容错（在窗丢失 = 条目值成为新 base，R-8）")
        try Data(#"{"lastAppliedEntryId":42}"#.utf8).write(to: store.url)
        check(store.load() == .empty, "日程-29", "字段类型不符 → 空状态容错（同上分流）")
    }

    // 日程-30：ScheduleState.empty 形态钉死（四字段全 nil——「无事可复/待补判」语义承载）。
    do {
        let empty = ScheduleState.empty
        check(empty.lastAppliedEntryId == nil && empty.baseUpperLimit == nil
                && empty.baseMode == nil && empty.lastAppliedAt == nil,
              "日程-30", ".empty 四字段全 nil（restoreBase 成功后的清空形态 == .empty）")
    }
}
