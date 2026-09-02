// CellarCoreCheck —— WP2' 健康度 + capabilities 场景域（方案 §5 S2 组⑥⑦）
//
// 按域拆独立文件（评审 P2-9）：电池健康度纯函数（Nominal/Design 官方口径 +
// rawMax 兜底 + clamp）与 DaemonStatus.capabilities 合成 Codable 双向兼容
// （decodeIfPresent——旧 daemon 无字段 → nil，评审 P2-5）。

import CellarCore
import Foundation

/// 健康度/能力场景域入口（Main.main 调用）。throws：能力探测含 mock 传输调用。
func runHealthCapabilitiesDomainScenarios() throws {
    // ---- ⑥ batteryHealthPercent ----

    // 健康-1：正常口径（本机实测 Nominal=7654/Design=8694 → 88%）+ 舍入语义。
    check(batteryHealthPercent(nominal: 7654, design: 8694) == 88,
          "健康-1", "Nominal/Design 官方口径：7654/8694 → 88%（2026-09-02 ioreg 实测值）")
    check(batteryHealthPercent(nominal: 6030, design: 6300) == 96,
          "健康-1", "舍入：6030/6300 = 95.714 → 96（四舍五入）")

    // 健康-2：nominal 缺 → rawMax 兜底（消费侧表达式）；两级缺席 → nil；design 防御。
    let snapshotFallback = batteryHealthPercent(
        nominal: 7612,   // 生产消费表达式：snapshot.nominalChargeCapacityMAh ?? snapshot.rawMaxCapacityMAh
        design: 8694
    )
    check(snapshotFallback == 88, "健康-2", "nominal 缺席 → rawMax 兜底（消费侧 ?? 表达式），87.58 → 88")
    check(batteryHealthPercent(nominal: nil, design: 8694) == nil, "健康-2", "nominal 与 rawMax 均缺 → nil（UI 仅显示循环次数零回归）")
    check(batteryHealthPercent(nominal: 7654, design: 0) == nil, "健康-2", "design ≤ 0（防御 guard）→ nil")
    check(batteryHealthPercent(nominal: 7654, design: -1) == nil, "健康-2", "design 负数 → nil")

    // 健康-3：clamp 0...100（异常源不穿透显示，评审 P2-8）。
    check(batteryHealthPercent(nominal: 9200, design: 8694) == 100, "健康-3", "标称 > 设计 → clamp 100")
    check(batteryHealthPercent(nominal: 1, design: 8694) == 0, "健康-3", "极小值（0.0115% 舍入 0）→ clamp 0")
    check(batteryHealthPercent(nominal: 8694, design: 8694) == 100, "健康-3", "100% 边界保持")

    // 能力-3：RuntimeProbe.supportsDischarge 探测矩阵（tahoe ∧ CHIE 在位 → true；
    // CHIE 缺席 / Legacy 后端 / 传输错误 → false——fail-closed，评审 P1-1）。
    do {
        let chiePresent = CheckTransport()
        chiePresent.enqueue(reply(dataSize: 4, type: "ui32"), for: Spec.keyInfo)   // CHTE
        chiePresent.enqueue(reply(dataSize: 1, type: "hex_"), for: Spec.keyInfo)   // CHIE
        let tahoe = try RuntimeProbe.probe(client: SMCClient(transport: chiePresent))
        check(RuntimeProbe.supportsDischarge(backend: tahoe, client: SMCClient(transport: chiePresent)) == true,
              "能力-3", "tahoe + CHIE 在位 → discharge 能力 true（daemon capabilities 置值来源）")

        let chieAbsent = CheckTransport()
        chieAbsent.enqueue(reply(dataSize: 4, type: "ui32"), for: Spec.keyInfo)
        chieAbsent.enqueue(reply(result: 132), for: Spec.keyInfo)                  // CHIE keyNotFound
        let tahoeNoChie = try RuntimeProbe.probe(client: SMCClient(transport: chieAbsent))
        check(RuntimeProbe.supportsDischarge(backend: tahoeNoChie, client: SMCClient(transport: chieAbsent)) == false,
              "能力-3", "tahoe 但 CHIE 缺席 → false（fail-closed：不含 discharge 能力）")

        let legacy = CheckTransport()
        legacy.enqueue(reply(result: 132), for: Spec.keyInfo)                      // CHTE missing
        legacy.enqueue(reply(dataSize: 1, type: "ui8"), for: Spec.keyInfo)         // CH0B present
        let legacyBackend = try RuntimeProbe.probe(client: SMCClient(transport: legacy))
        check(RuntimeProbe.supportsDischarge(backend: legacyBackend, client: SMCClient(transport: legacy)) == false,
              "能力-3", "Legacy 后端（CH0B 代）→ false（CHIE 为 Tahoe 代键）")
    }

    // ---- ⑦ capabilities decode 双向 ----

    // 能力-1：合成 Codable round-trip（["discharge"] / [] 两形态）。
    do {
        let withCap = DaemonStatus(
            version: "0.3.1-alpha-dev", mode: "active", upperLimit: 80, hysteresis: 2,
            capabilities: [DaemonXPC.capabilityDischarge],
            timestamp: Date(timeIntervalSince1970: 1234)
        )
        let round = DaemonXPC.encodeStatus(withCap).flatMap { try? DaemonXPC.decodeStatus($0) }
        check(round == withCap && round?.capabilities == [DaemonXPC.capabilityDischarge],
              "能力-1", "capabilities=[\"discharge\"] round-trip 全字段保留")

        let emptyCap = DaemonStatus(
            version: "0.3.1-alpha-dev", mode: "disabled", upperLimit: 60, hysteresis: 20,
            capabilities: [],
            timestamp: Date(timeIntervalSince1970: 1234)
        )
        let emptyRound = DaemonXPC.encodeStatus(emptyCap).flatMap { try? DaemonXPC.decodeStatus($0) }
        check(emptyRound == emptyCap && emptyRound?.capabilities == [],
              "能力-1", "capabilities=[]（已上报但机型不支持）round-trip")
    }

    // 能力-2：旧 daemon 回包无 capabilities 键 → 解码 nil（升级窗口双向兼容）。
    do {
        let legacyJSON = #"{"version":"0.3.0-alpha-dev","mode":"active","upperLimit":80,"hysteresis":2,"lastAction":"enforce:disableCharging","lastPercent":80,"lastExternalConnected":true,"lastChargingEnabled":false,"timestamp":123.0}"#
        let legacy = try? JSONDecoder().decode(DaemonStatus.self, from: Data(legacyJSON.utf8))
        check(legacy?.capabilities == nil && legacy?.version == "0.3.0-alpha-dev"
                && legacy?.lastAction == "enforce:disableCharging",
              "能力-2", "旧 daemon JSON（无 capabilities 键）→ 解码 nil 且既有字段照常（decodeIfPresent）")

        let newEmpty = #"{"version":"0.3.1-alpha-dev","mode":"active","upperLimit":80,"hysteresis":2,"capabilities":[],"timestamp":123.0}"#
        let decodedEmpty = try? JSONDecoder().decode(DaemonStatus.self, from: Data(newEmpty.utf8))
        check(decodedEmpty?.capabilities == [], "能力-2", "显式空数组解码 → []（与缺席 nil 语义区分——App 两态文案）")
    }
}
// MARK: - StatusFailureKind 横幅通道映射（WP2' 验收修正钉死：done 不进失败通道）

/// 映射矩阵：安全/失败终态入通道、done 与用户取消不入（成功走 success 反馈 +
/// 自动消退——真机验收修正：done 曾被渲染为红色告警横幅且锁存常驻）。
func scenarioStatusFailureKindMapping() {
    // 全局 check 助手（MainEntry.swift，跨文件 internal；场景计数自动统计）
    func status(_ action: String) -> DaemonStatus {
        DaemonStatus(version: "t", mode: "active", upperLimit: 80, hysteresis: 2, lastAction: action)
    }
    check(StatusFailureKind(status: status("enforce:error")) == .writeFailed,
          "横幅-1", "enforce:error → writeFailed")
    check(StatusFailureKind(status: status("enforce:verifyFailed")) == .conflictSuspected,
          "横幅-2", "enforce:verifyFailed → conflictSuspected")
    check(StatusFailureKind(status: status("fullOnce:timeout")) == .actionTimedOut,
          "横幅-3", "fullOnce:timeout → actionTimedOut")
    check(StatusFailureKind(status: status("dischargeToLimit:timeout")) == .actionTimedOut,
          "横幅-4", "dischargeToLimit:timeout → actionTimedOut")
    check(StatusFailureKind(status: status("fullOnce:cancel(crash-recovery)")) == .actionInterrupted,
          "横幅-5", "fullOnce:cancel(crash-recovery) → actionInterrupted")
    check(StatusFailureKind(status: status("dischargeToLimit:safety")) == .actionSafetyTerminated,
          "横幅-6", "dischargeToLimit:safety → actionSafetyTerminated")
    check(StatusFailureKind(status: status("fullOnce:done")) == nil,
          "横幅-7", "fullOnce:done → nil（成功走 success 反馈 + 自动消退）")
    check(StatusFailureKind(status: status("dischargeToLimit:done")) == nil,
          "横幅-8", "dischargeToLimit:done → nil（同上）")
    check(StatusFailureKind(status: status("dischargeToLimit:cancel")) == nil,
          "横幅-9", "用户取消不入通道")
    check(StatusFailureKind(status: status("enforce:noop")) == nil,
          "横幅-10", "常规 enforce 不入通道")
}
