// CellarCoreCheck —— Phase 4 WP2 自动放电（opt-in）场景域（方案 §4.1 九项）
//
// 按域拆独立文件（main.swift 不再增长）。与 main.swift / 其他场景域共用
// FailureCounter、断言助手与 XPC 环境（本域经 makeMessage/validateRequest
// 钉死线格式——CellarCoreCheck 已 import XPC）。
//
// 覆盖清单（方案 §4.1 九项）：
// ① 触发判定矩阵：九输入逐条真假两侧 + margin/冷却边界 + 从未完成直通
// ② DaemonPolicy Codable：旧 JSON 兼容 / round-trip / validated 透传 / .default
// ③ DaemonStatus 兼容：旧 JSON → nil / round-trip / init 默认 nil
// ④ 线格式：makeMessage auto 缺席不发键 / validateRequest 解析 / 类型混淆整包拒绝
// ⑤ 字面量与锁存：autoStart 格式钉死 / latchAutoStart 覆盖既有终态锁存 / 清除回落
// ⑥ 值域纯函数 validAutoFlag（XPCServer 校验臂同源）
// ⑦ 拆分判别：DischargeStartOutcome{.started/.alreadyActive}/Initiator 为
//    cellar-daemon 内部类型，Core 侧不可见 → 盲区声明（方案 §4.2 如实记录），
//    Core 侧可测先决「轨道占用拒绝再启动」（.alreadyActive 语义基础）见放电-24
// ⑧ 通知矩阵：autostart 首样本 / 转移 / 终态链不遮蔽 / fullOnce 前缀豁免回归
// ⑨ 事件承载：autoDischargeStarted 关联值 == current.upperLimit

import CellarCore
import Foundation

/// 自动放电场景域入口（Main.main 调用；Codable 兼容组含 JSON decode/encode）。
func runAutoDischargeDomainScenarios() throws {
    let t0 = Date(timeIntervalSince1970: 0)
    let kind = Discharge.dischargeToLimitKind

    // ---- ① 触发判定矩阵 ----

    // 全门开基线（enabled=true、active、外接、无动作、能力在位、82 ≥ 80+2、
    // 从未完成——冷却/重插两门直通）。
    func ready(
        enabled: Bool? = true, mode: String = "active", externalConnected: Bool = true,
        percent: Int = 82, upperLimit: Int = 80, actionActive: Bool = false,
        dischargeCapable: Bool = true, now: Date = t0,
        lastAutoCompletion: Date? = nil, adapterCycleSinceCompletion: Bool = true
    ) -> Bool {
        Discharge.autoTriggerReady(
            enabled: enabled, mode: mode, externalConnected: externalConnected,
            percent: percent, upperLimit: upperLimit, actionActive: actionActive,
            dischargeCapable: dischargeCapable, now: now,
            lastAutoCompletion: lastAutoCompletion,
            adapterCycleSinceCompletion: adapterCycleSinceCompletion
        )
    }

    // 自动-1：全门开触发 + enabled 真假两侧（nil 视为 false）。
    check(ready(), "自动-1", "全门开（active/外接/无动作/能力/82≥80+2/从未完成）→ 触发")
    check(!ready(enabled: false) && !ready(enabled: nil), "自动-1",
          "enabled=false / nil（未设置视为 false）→ 不触发")

    // 自动-2：mode / 外接两侧。
    check(!ready(mode: "disabled"), "自动-2", "disabled 模式 → 不触发（开启开关不越 mode 门）")
    check(!ready(externalConnected: false), "自动-2", "未外接 → 不触发（电池态无放电原语）")

    // 自动-3：动作在轨 / 能力缺席两侧。
    check(!ready(actionActive: true), "自动-3", "动作在轨 → 不触发（幂等到既有动作）")
    check(!ready(dischargeCapable: false), "自动-3", "放电能力缺席 → 不触发（探测结果门控，非 hardcoded）")

    // 自动-4：margin 边界（percent = 上限+1 → false；上限+2 → true）。
    check(!ready(percent: 81), "自动-4", "边界：percent = 上限+1 → 不触发（margin 门关）")
    check(ready(percent: 82), "自动-4", "边界：percent = 上限+2 → 触发（margin=2 钉死）")

    // 自动-5：冷却边界（29:59 → false；30:00 → true）。
    check(!ready(now: t0, lastAutoCompletion: t0.addingTimeInterval(-(29 * 60 + 59))), "自动-5",
          "边界：距完成 29:59 → 不触发（冷却门关）")
    check(ready(now: t0, lastAutoCompletion: t0.addingTimeInterval(-30 * 60)), "自动-5",
          "边界：距完成 30:00 → 触发（冷却门开）")

    // 自动-6：重插门 + 从未完成直通。
    let completedAnHourAgo = t0.addingTimeInterval(-3600)
    check(!ready(lastAutoCompletion: completedAnHourAgo, adapterCycleSinceCompletion: false), "自动-6",
          "冷却已过但无适配器翻转 → 不触发（重插门关）")
    check(ready(lastAutoCompletion: completedAnHourAgo, adapterCycleSinceCompletion: true), "自动-6",
          "冷却已过 + 适配器翻转 → 触发（两门 AND）")
    check(ready(lastAutoCompletion: nil, adapterCycleSinceCompletion: false), "自动-6",
          "从未完成（nil）：翻转门直通（两门只在完成记录存在后参与判定）")

    // ---- ② DaemonPolicy Codable（方案 §2.1 兼容模式）----

    // 自动-7：旧 JSON（无 autoDischargeEnabled 键）→ nil；新 JSON round-trip；
    // validated 默认参数；.default flag == nil。
    do {
        let oldJSON = "{\"mode\":\"active\",\"upperLimit\":80,\"hysteresis\":2}"
        let oldPolicy = try JSONDecoder().decode(DaemonPolicy.self, from: Data(oldJSON.utf8))
        check(oldPolicy.autoDischargeEnabled == nil, "自动-7",
              "旧 policy.json（无 auto 键）解码 → autoDischargeEnabled == nil（向后兼容）")

        let withFlag = try JSONDecoder().decode(
            DaemonPolicy.self,
            from: JSONEncoder().encode(
                DaemonPolicy(mode: "active", upperLimit: 75, hysteresis: 2, autoDischargeEnabled: true)
            )
        )
        check(withFlag.autoDischargeEnabled == true && withFlag.upperLimit == 75, "自动-7",
              "round-trip 保留 flag 与上限")

        check(DaemonPolicy.default.autoDischargeEnabled == nil, "自动-7", ".default flag == nil")
        check(
            DaemonPolicy.validated(mode: "active", upperLimit: 80, hysteresis: 2)?.autoDischargeEnabled == nil,
            "自动-7", "validated 默认参数 → flag == nil（既有构造点零改动）"
        )
        check(
            DaemonPolicy.validated(mode: "active", upperLimit: 80, hysteresis: 2, autoDischargeEnabled: true)?.autoDischargeEnabled == true,
            "自动-7", "validated 透传 flag"
        )
    }

    // ---- ③ DaemonStatus 兼容（合成 Codable decodeIfPresent 既有模式）----

    // 自动-8：旧 JSON → nil；新 JSON round-trip；init 默认 nil。
    do {
        let oldStatusJSON = """
        {"version":"0.4.0-alpha","mode":"active","upperLimit":80,"hysteresis":2,"timestamp":700000000}
        """
        let oldStatus = try JSONDecoder().decode(DaemonStatus.self, from: Data(oldStatusJSON.utf8))
        check(oldStatus.autoDischargeEnabled == nil, "自动-8",
              "旧 daemon 回包（无 autoDischargeEnabled 键）解码 → nil（兼容）")

        var withFlag = DaemonStatus(version: "fixture", mode: "active", upperLimit: 80, hysteresis: 2)
        withFlag.autoDischargeEnabled = true
        let revived = try JSONDecoder().decode(
            DaemonStatus.self, from: JSONEncoder().encode(withFlag)
        )
        check(revived.autoDischargeEnabled == true, "自动-8", "新 JSON round-trip 保留 flag")

        let defaults = DaemonStatus(version: "fixture", mode: "active", upperLimit: 80, hysteresis: 2)
        check(defaults.autoDischargeEnabled == nil, "自动-8", "init 默认 nil（既有夹具形态不破坏）")
    }

    // ---- ④ 线格式（makeMessage / validateRequest）----

    // 自动-9：auto 缺席不发键；0/1 解析。
    do {
        let noAuto = DaemonXPC.makeMessage(cmd: "setLimits", upper: 80, hysteresis: 2)
        check(xpc_dictionary_get_value(noAuto, DaemonXPC.autoKey) == nil, "自动-9",
              "makeMessage auto 缺省（nil）→ 字典无 auto 键（旧 daemon/CLI 天然兼容）")
        check(DaemonXPC.validateRequest(noAuto)?.auto == nil, "自动-9",
              "validateRequest：无 auto 键 → auto == nil")

        let auto0 = DaemonXPC.makeMessage(cmd: "setLimits", upper: 80, hysteresis: 2, auto: 0)
        let auto1 = DaemonXPC.makeMessage(cmd: "setLimits", upper: 80, hysteresis: 2, auto: 1)
        check(DaemonXPC.validateRequest(auto0)?.auto == 0, "自动-9", "auto=0 解析为 0（关闭）")
        check(DaemonXPC.validateRequest(auto1)?.auto == 1, "自动-9", "auto=1 解析为 1（开启）")
    }

    // 自动-10：类型混淆 → 整包拒绝（与 upper/hysteresis 同纪律）。
    do {
        let confused = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(confused, DaemonXPC.cmdKey, "setLimits")
        xpc_dictionary_set_uint64(confused, DaemonXPC.upperKey, 80)
        xpc_dictionary_set_uint64(confused, DaemonXPC.hysteresisKey, 2)
        xpc_dictionary_set_string(confused, DaemonXPC.autoKey, "yes")
        check(DaemonXPC.validateRequest(confused) == nil, "自动-10",
              "auto 类型混淆（STRING）→ 整包拒绝（不崩溃、不回半合法包）")
    }

    // ---- ⑤ 字面量与锁存 ----

    // 自动-11：autoStart 格式钉死（无默认参数——调用点必须显式传 kind）。
    check(OneShotLiteral.autoStart(kind: kind) == "dischargeToLimit:autostart", "自动-11",
          "autoStart(kind:) = \"dischargeToLimit:autostart\"（无默认参数，防 fullOnce:autostart 误用）")

    // 自动-12：latchAutoStart 覆盖既有终态锁存（fullOnce:done 先行 → autostart 仍可见）。
    do {
        var track = OneShotTrack()
        _ = track.startIfIdle(now: t0, kind: OneShot.fullOnceKind)
        // fullOnce 完成需连续 2 tick 去抖（fullOnceDebounceTicks=2）。
        _ = track.tick(now: t0.addingTimeInterval(30), fullyCharged: true, isCharging: false, percent: 100)
        let out = track.tick(now: t0.addingTimeInterval(60), fullyCharged: true, isCharging: false, percent: 100)
        check(out == .completed && track.latchedLiteral == OneShotLiteral.done() && track.action == nil, "自动-12",
              "前置：fullOnce 完成 → done 终态锁存在轨（动作已清空）")
        track.latchAutoStart(OneShotLiteral.autoStart(kind: kind))
        check(track.effectiveLastAction("enforce:noop") == "dischargeToLimit:autostart", "自动-12",
              "既有终态锁存（fullOnce:done 活到下次用户动作）期间 latchAutoStart → autostart 优先（App 轮询必见 → 通知必发，M3 判例）")
        check(track.action == nil, "自动-12", "latchAutoStart 纯锁存字面量，不动动作轨道")
    }

    // 自动-13：用户动作清除锁存后回落常规字面量。
    do {
        var track = OneShotTrack()
        _ = track.startIfIdle(now: t0, kind: OneShot.fullOnceKind)
        _ = track.tick(now: t0.addingTimeInterval(30), fullyCharged: true, isCharging: false, percent: 100)
        _ = track.tick(now: t0.addingTimeInterval(60), fullyCharged: true, isCharging: false, percent: 100)
        track.latchAutoStart(OneShotLiteral.autoStart(kind: kind))
        track.clearUserActionLatch()
        check(track.effectiveLastAction("enforce:noop") == "enforce:noop", "自动-13",
              "用户动作（clearUserActionLatch）清除锁存 → 回落常规字面量")
    }

    // ---- ⑥ 值域纯函数（XPCServer 校验臂同源）----

    // 自动-14：validAutoFlag 0/1 合法；2 / UInt64.max 非法。
    check(Discharge.validAutoFlag(0) && Discharge.validAutoFlag(1), "自动-14", "0/1 合法")
    check(!Discharge.validAutoFlag(2) && !Discharge.validAutoFlag(UInt64.max), "自动-14",
          "2 / UInt64.max 非法（XPCServer 臂与测试同源）")

    // ---- ⑦ 拆分判别盲区声明（方案 §4.2 如实记录）----
    // DischargeStartOutcome{.started/.alreadyActive} 与 Initiator{.manual/.auto}
    // 为 cellar-daemon 目标内部类型，本工具不可 import——判别语义（.alreadyActive
    // 幂等分支零副作用、仅 .started 才 tick/latchAutoStart、失败臂不 tick）无自动化
    // 覆盖，以代码走查 + 真机验收兜底；Core 侧可测先决（轨道占用时拒绝再启动 =
    // .alreadyActive 语义基础）已由放电-24 钉死。

    // ---- ⑧ 通知矩阵（transfer 臂）----

    // 自动-15：首样本 autostart → 无事件（首样本臂不破例）。
    do {
        func dStatus(_ lastAction: String?, upper: Int = 90) -> DaemonStatus {
            DaemonStatus(
                version: "fixture", mode: "active", upperLimit: upper,
                hysteresis: 2, lastAction: lastAction, lastPercent: 78,
                lastExternalConnected: true, lastChargingEnabled: false
            )
        }
        check(notificationEvents(previous: nil, current: dStatus("dischargeToLimit:autostart")) == [],
              "自动-15", "首样本 dischargeToLimit:autostart → 无事件（既有臂不破例）")
    }

    // 自动-16：start → autostart 转移 → autoDischargeStarted。
    do {
        func dStatus(_ lastAction: String?, upper: Int = 90) -> DaemonStatus {
            DaemonStatus(
                version: "fixture", mode: "active", upperLimit: upper,
                hysteresis: 2, lastAction: lastAction, lastPercent: 78,
                lastExternalConnected: true, lastChargingEnabled: false
            )
        }
        check(notificationEvents(
            previous: dStatus("dischargeToLimit:start"),
            current: dStatus("dischargeToLimit:autostart")
        ) == [.autoDischargeStarted(upperLimit: 90)],
        "自动-16", "start → autostart 转移 → [.autoDischargeStarted(upperLimit: current.upperLimit)]")
    }

    // 自动-17：autostart → 终态链不遮蔽（done/cancel 照发既有事件）。
    do {
        func dStatus(_ lastAction: String?) -> DaemonStatus {
            DaemonStatus(
                version: "fixture", mode: "active", upperLimit: 90,
                hysteresis: 2, lastAction: lastAction, lastPercent: 78,
                lastExternalConnected: true, lastChargingEnabled: false
            )
        }
        check(notificationEvents(
            previous: dStatus("dischargeToLimit:autostart"),
            current: dStatus("dischargeToLimit:done")
        ) == [.actionCompleted(kind: kind)],
        "自动-17", "autostart → done → actionCompleted（终态通知不被 autostart 遮蔽）")
        check(notificationEvents(
            previous: dStatus("dischargeToLimit:autostart"),
            current: dStatus("dischargeToLimit:cancel")
        ) == [.actionCancelled(kind: kind)],
        "自动-17", "autostart → cancel → actionCancelled（取消含自动起源，取消即通知）")
        check(notificationEvents(
            previous: dStatus("dischargeToLimit:start"),
            current: dStatus("dischargeToLimit:start")
        ) == [], "自动-17", "回归：同值 start → 无事件（转移守卫）")
    }

    // ---- ⑨ 事件承载：关联值 == current.upperLimit（非 previous）----

    // 自动-18：autostart 转移时上限变更（90 → 75），事件承载 current 现值。
    do {
        let events = notificationEvents(
            previous: DaemonStatus(
                version: "fixture", mode: "active", upperLimit: 90,
                hysteresis: 2, lastAction: "dischargeToLimit:start"
            ),
            current: DaemonStatus(
                version: "fixture", mode: "active", upperLimit: 75,
                hysteresis: 2, lastAction: "dischargeToLimit:autostart"
            )
        )
        check(events == [.autoDischargeStarted(upperLimit: 75)], "自动-18",
              "autoDischargeStarted 关联值 == current.upperLimit（75，非 previous 的 90）")
    }

    // 自动-19：fullOnce 前缀豁免不回归（终态锁存后恢复停充不误报 limitReached）。
    check(notificationEvents(
        previous: DaemonStatus(
            version: "fixture", mode: "active", upperLimit: 90,
            hysteresis: 2, lastAction: "fullOnce:done"
        ),
        current: DaemonStatus(
            version: "fixture", mode: "active", upperLimit: 90,
            hysteresis: 2, lastAction: "enforce:disableCharging"
        )
    ) == [], "自动-19", "回归：fullOnce:done → enforce:disableCharging → 无事件（P1-4 前缀豁免）")
}