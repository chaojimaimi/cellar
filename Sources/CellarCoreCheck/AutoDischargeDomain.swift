// CellarCoreCheck —— 自动放电 wire/通知兼容面场景域（0.23.0 退役版）
//
// **0.23.0 自动放电自动机退役（方案 §2/§8 F4 账）**：autoTriggerReady/振荡熔断/
// strike 伴随/limitObservation 判定族随生产代码删除，对应场景族（原自动-1..6、
// 12、13、20..34）一并退役。本域收缩为 **F5 兼容保留面回归锚 + 退役面 wire 兼容
// 钉**（方案 §8：留自动-11 OneShotLiteral.autoStart 格式 + 自动-15/16/17/18
// notificationEvents/Onboarding 事件承载；wire/policy 解码面照填不消费）。
//
// 覆盖清单（收缩后）：
// ① DaemonPolicy Codable：旧 JSON 兼容 / round-trip / validated 透传 / .default
//    （autoDischargeEnabled 字段**解码保留、不消费**——policy 冻结容忍）
// ② DaemonStatus 兼容：旧 JSON → nil / round-trip / init 默认 nil（wire 照填面）
// ③ 线格式：makeMessage auto 缺席不发键 / validateRequest 解析 / 类型混淆整包拒绝
//    （auto 键 wire 兼容保留——旧 App/CLI 可发，daemon 照收进 policy 镜像）
// ④ 字面量：OneShotLiteral.autoStart 格式钉死（**新 daemon 恒不产**——F5 保留面，
//    旧 daemon 混装窗内 App 解析/通知映射仍可达）
// ⑤ 值域纯函数 validAutoFlag（XPCServer 校验臂同源）
// ⑥ 通知矩阵：autostart 首样本 / 转移 / 终态链不遮蔽 / fullOnce 前缀豁免回归
// ⑦ 事件承载：autoDischargeStarted 关联值 == current.upperLimit（F5 保留面）
//
// 盲区声明：自动触发链本体已随批删除（无消费语义可测）；Initiator/.auto 臂仅校准
// 调度消费（CalibrationDomain 承接）。

import CellarCore
import Foundation
import XPC

/// 自动放电兼容面场景域入口（Main.main 调用；Codable 兼容组含 JSON decode/encode）。
func runAutoDischargeDomainScenarios() throws {
    let kind = Discharge.dischargeToLimitKind

    // ---- ① DaemonPolicy Codable（方案 §2.1 兼容模式——解码保留不消费）----

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

    // ---- ② DaemonStatus 兼容（合成 Codable decodeIfPresent 既有模式）----

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

    // ---- ③ 线格式（makeMessage / validateRequest——auto 键 wire 兼容保留）----

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

    // ---- ④ 字面量（F5 兼容保留面——新 daemon 恒不产，解析映射仍可达）----

    // 自动-11：autoStart 格式钉死（无默认参数——调用点必须显式传 kind）。
    check(OneShotLiteral.autoStart(kind: kind) == "dischargeToLimit:autostart", "自动-11",
          "autoStart(kind:) = \"dischargeToLimit:autostart\"（0.23.0 起新 daemon 恒不产——旧 daemon 混装窗内解析兼容，非死码）")

    // ---- ⑤ 值域纯函数（XPCServer 校验臂同源）----

    // 自动-14：validAutoFlag 0/1 合法；2 / UInt64.max 非法。
    check(Discharge.validAutoFlag(0) && Discharge.validAutoFlag(1), "自动-14", "0/1 合法")
    check(!Discharge.validAutoFlag(2) && !Discharge.validAutoFlag(UInt64.max), "自动-14",
          "2 / UInt64.max 非法（XPCServer 臂与测试同源）")

    // ---- ⑥ 通知矩阵（transfer 臂——F5 保留面：旧 daemon autostart 字面量仍识别）----

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
        "自动-16", "start → autostart 转移 → [.autoDischargeStarted(upperLimit: current.upperLimit)]（旧 daemon 混装窗事件映射兼容）")
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

    // ---- ⑦ 事件承载：关联值 == current.upperLimit（非 previous；F5 保留面）----

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
