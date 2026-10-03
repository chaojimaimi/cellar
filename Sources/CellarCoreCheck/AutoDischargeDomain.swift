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
// ⑩ 意图降限观察（v0.19.6 方案 §5 九项）：limitObservation 判定（下调/上调/
//    等值/首次播种）/两步序列播种纪律锚点/重武装 × margin/冷却/enabled 组合
//    G1→G2 闭环/恢复场景等价——观察器接线本体在 cellar-daemon（照 ⑦ 盲区先例）

import CellarCore
import Foundation

/// 自动放电场景域入口（Main.main 调用；Codable 兼容组含 JSON decode/encode）。
func runAutoDischargeDomainScenarios() throws {
    let t0 = Date(timeIntervalSince1970: 0)
    let kind = Discharge.dischargeToLimitKind

    // ---- ① 触发判定矩阵 ----

    // 全门开基线（enabled=true、active、外接、无动作、能力在位、82 ≥ 80+2、
    // 从未完成——冷却/重插两门直通）。0.21.1 §1.1 三门增参默认值 = 26 时代假设
    //（charging=false 停充即时生效、无窗、未抑制）——既有真值表逐值不变（26 回归锚）。
    // 0.21.2 §3.2：strikeEdgeLatched 缺省 nil = 既有判定链零 diff（26 回归锚）。
    func ready(
        enabled: Bool? = true, mode: String = "active", externalConnected: Bool = true,
        isCharging: Bool = false,
        percent: Int = 82, upperLimit: Int = 80, windowOverride: Bool = false,
        actionActive: Bool = false,
        dischargeCapable: Bool = true, oscillationSuspended: Bool = false,
        now: Date = t0,
        lastAutoCompletion: Date? = nil, adapterCycleSinceCompletion: Bool = true,
        strikeEdgeLatched: Bool? = nil
    ) -> Bool {
        Discharge.autoTriggerReady(
            enabled: enabled, mode: mode, externalConnected: externalConnected,
            isCharging: isCharging,
            percent: percent,
            effectiveTarget: windowOverride ? nil : upperLimit,
            actionActive: actionActive,
            dischargeCapable: dischargeCapable,
            oscillationSuspended: oscillationSuspended,
            now: now,
            lastAutoCompletion: lastAutoCompletion,
            adapterCycleSinceCompletion: adapterCycleSinceCompletion,
            strikeEdgeLatched: strikeEdgeLatched
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

    // ---- ⑩ 意图降限观察（v0.19.6 维护批，方案 §5 九项；盲区见文件头 ⑩）----

    // 自动-20：limitObservation 判定两侧 + 首次播种（方案 §5 1–3）。
    do {
        let lowered = Discharge.limitObservation(previous: 80, current: 75)
        check(lowered.rearm && lowered.nextObserved == 75, "自动-20",
              "下调 80→75 → rearm=true、nextObserved=75（意图开门）")
        let raised = Discharge.limitObservation(previous: 75, current: 80)
        check(!raised.rearm && raised.nextObserved == 80, "自动-20",
              "上调 75→80 → rearm=false、nextObserved=80（无条件更新语义钉死）")
        let equal = Discharge.limitObservation(previous: 80, current: 80)
        check(!equal.rearm && equal.nextObserved == 80, "自动-20",
              "等值 → rearm=false、nextObserved=current")
        let first = Discharge.limitObservation(previous: nil, current: 80)
        check(!first.rearm && first.nextObserved == 80, "自动-20",
              "首次 previous=nil → rearm=false、nextObserved=current（播种由返回值承载，非调用方分支）")
    }

    // 自动-21：两步序列 75→80→75（方案 §5 4）：第一步必须播种 80，第二步以 80 为
    // previous 才命中——钉死播种纪律与「仅降限触发」（防接线烤入同坏代码的 Core 锚点）。
    do {
        let step1 = Discharge.limitObservation(previous: 75, current: 80)
        check(!step1.rearm && step1.nextObserved == 80, "自动-21",
              "第一步 75→80：rearm=false、nextObserved=80（播种）")
        let step2 = Discharge.limitObservation(previous: step1.nextObserved, current: 75)
        check(step2.rearm && step2.nextObserved == 75, "自动-21",
              "第二步 80→75（previous=第一步播种值）→ rearm=true、nextObserved=75")
    }

    // 自动-22：G1→G2 闭环（方案 §5 5）：完成后重插门关 → 模拟降限重武装（观察器
    // 置 adapterCycleSinceCompletion=true）→ autoTriggerReady 全链通过（margin
    // 82 ≥ 80+2、冷却已过）。
    check(!ready(lastAutoCompletion: completedAnHourAgo, adapterCycleSinceCompletion: false), "自动-22",
          "前置：完成一小时后无翻转 → 不触发（重插门关）")
    check(ready(lastAutoCompletion: completedAnHourAgo, adapterCycleSinceCompletion: true), "自动-22",
          "降限重武装（翻转门重开）→ 触发（margin 82≥80+2、冷却已过，G1→G2 闭环）")

    // 自动-23：重武装但冷却未过 → 不触发（方案 §5 6：冷却门独立生效）。
    check(!ready(now: t0, lastAutoCompletion: t0.addingTimeInterval(-(29 * 60 + 59)), adapterCycleSinceCompletion: true), "自动-23",
          "重武装但距完成 29:59 → 不触发（重武装不豁免冷却门）")

    // 自动-24：重武装但 margin 不足 → 不触发（方案 §5 7：margin 门独立生效）。
    check(!ready(percent: 76, upperLimit: 75, adapterCycleSinceCompletion: true), "自动-24",
          "重武装但 percent 76 < 75+2 → 不触发（重武装不豁免 margin 门）")

    // 自动-25：重武装但 enabled=false → 不触发（方案 §5 8：重武装无害性钉死——
    // 门状态仅被 autoTriggerReady 消费，auto 关时不开门）。
    check(!ready(enabled: false, adapterCycleSinceCompletion: true)
            && !ready(enabled: nil, adapterCycleSinceCompletion: true), "自动-25",
          "重武装但 enabled=false / nil → 不触发")

    // 自动-26：恢复场景等价（previous=base 80、current=75 → rearm=true，方案 §5 9：
    // restoreBase 降限与进窗降限同链）。
    check(Discharge.limitObservation(previous: 80, current: 75).rearm, "自动-26",
          "恢复场景等价（base 80 → current 75）→ rearm=true")

    // ---- ⑪ 0.21.2 §3.2 strike 边沿伴随触发矩阵（门向量 × 边沿穷举）----
    // 收紧语义：27 观测段自动放电 = strike 边沿伴随唯一场景（strikeEdgeLatched 非
    // nil 即收紧模式——无边沿直接静默；边沿拍门 a 放行）。0.21.1 判定链全保留。

    // 自动-27：边沿拍触发 + 门 a 放行（strike 后仍 charging=true = agent 不跟域的
    // 失效证据，放电即打断手段——R2-P3-1 门 a 边沿拍精化）。
    check(ready(isCharging: true, strikeEdgeLatched: true), "自动-27",
          "边沿拍 ∧ charging=true → 触发（门 a 放行——失效证据本身 = 打断手段）")
    check(ready(isCharging: false, strikeEdgeLatched: true), "自动-27",
          "边沿拍 ∧ !isCharging → 触发（门 a 本就开，边沿不改变停充态判定）")

    // 自动-28：非边沿拍静默——收紧模式 strikeEdgeLatched=false（含降级拍/校准抑制
    // 归并臂）→ 其余门全开也不触发（边沿锁存 = 收紧段触发必要条件）。
    check(!ready(strikeEdgeLatched: false), "自动-28",
          "收紧模式无边沿（停充态、门全开）→ 静默（旧链无此门——27 收紧面）")
    check(!ready(isCharging: true, strikeEdgeLatched: false), "自动-28",
          "收紧模式无边沿 ∧ charging → 静默（门 a 原样 + 边沿门双拦）")

    // 自动-29：26 不变（缺省 nil = 既有判定链零 diff——无 strike 链，门 a 原样，
    // 26 过冲即时停充；执法段 effectiveTarget=upperLimit 常量锚不变）。
    check(!ready(isCharging: true), "自动-29",
          "26 链（nil）∧ charging=true → 不触发（门 a 原样——26 回归锚）")
    check(ready(isCharging: false), "自动-29",
          "26 链（nil）∧ !isCharging → 触发（既有行为逐值不变）")

    // 自动-30：门 a 两态对齐（同一 charging=true 输入：nil = 原样拦 / 边沿拍 = 放行
    // ——0.21.2 门 a 精化的单点对照；非边沿收紧拍 false 与 nil 同拦）。
    check(!ready(isCharging: true) && ready(isCharging: true, strikeEdgeLatched: true)
            && !ready(isCharging: true, strikeEdgeLatched: false), "自动-30",
          "门 a 两态：nil 模式 charging 拦（26 原样）/ 边沿拍 charging 放行（失效证据即打断）/ 非边沿拍拦")

    // 自动-31：边∧窗静默（门 b 保留——fullOnce/日程窗 effectiveTarget=nil 直接沉默，
    // 边沿不豁免窗覆盖静默）。
    check(!ready(windowOverride: true, strikeEdgeLatched: true), "自动-31",
          "边沿拍 ∧ 完全放开窗 → 静默（门 b 窗覆盖——显式放开期不被放电对抗）")

    // 自动-32：边∧冷却丢失不补发（冷却/重插门保留——边沿不豁免；TTL 1 tick 结构性
    // 防陈旧边沿冷却后再触发——登记面，见 TopoffDomain 边沿-5）。
    check(!ready(lastAutoCompletion: t0.addingTimeInterval(-(29 * 60 + 59)), strikeEdgeLatched: true),
          "自动-32", "边沿拍 ∧ 冷却未过 → 静默（边沿丢失不补发——下一 strike 边沿 10 min 后再来）")
    check(!ready(lastAutoCompletion: completedAnHourAgo, adapterCycleSinceCompletion: false, strikeEdgeLatched: true),
          "自动-32", "边沿拍 ∧ 重插门未开 → 静默（同上登记面）")

    // 自动-33：margin 门保留——边沿拍不豁免 margin+2。
    check(!ready(percent: 81, strikeEdgeLatched: true), "自动-33",
          "边沿拍 ∧ percent = 上限+1 → 静默（margin 门原样）")

    // 自动-34：伴随组合消费形态（daemon 传入 strikeEdgeLatched 前先经
    // Topoff.strikeAccompaniment 归并——degraded 拦截/校准抑制/无边沿/**0.21.3 §1.1
    // target<80 门**四臂在组合层归并为 false，模型层输入形态见 TopoffDomain 边沿-2/3/6）。
    // 本域默认上限 80（<80 承载语境）；≥80 strike 边不放电（0.21.2 公开语义保持）
    // 的门面在 TopoffDomain 边沿-6 重定版钉死。
    let accompanimentRows: [(edge: Bool, degraded: Bool, suspected: Bool, expected: Bool, note: String)] = [
        (true, false, false, true, "边沿拍承载态 → 成立"),
        (true, true, false, false, "第 3 边沿（降级拍）→ !degraded 拦截 → 不放电"),
        (true, false, true, false, "校准抑制期 → 冻结"),
        (false, false, false, false, "无边沿（healTick 无边同型）→ 不成立"),
    ]
    for row in accompanimentRows {
        let accompanied = Topoff.strikeAccompaniment(
            edgeReadable: row.edge, degraded: row.degraded, calibrationSuspected: row.suspected,
            target: 79)
        check(accompanied == row.expected, "自动-34", "伴随组合（edge=\(row.edge), degraded=\(row.degraded), suspected=\(row.suspected)）→ \(row.note)")
        // 组合直通收紧判定（daemon 接线形态：非 nil = 收紧模式；charging=true 态下
        // 触发 ⇔ 伴随成立——边沿拍门 a 放行、非边沿拍门 a + 边沿门双拦）。
        check(ready(isCharging: true, strikeEdgeLatched: accompanied) == accompanied, "自动-34",
              "伴随组合直通（charging 态）：\(row.note)")
    }
}