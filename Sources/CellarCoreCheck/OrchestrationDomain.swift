// CellarCoreCheck —— v0.19.20 Shortcuts 编排场景域（方案 §2 清单）
//
// 覆盖清单（工单门禁钉死项）：
// ① nativeTarget 三分支（<80 钳 80 / 80-100 直通 / >100 防御）
// ② assertionRequest 真值表全分支（六条判定次序 = 契约，R2 复审定版）：
//    mode/desired 门 → actionActive 不对抗 → outstanding TTL 去抖（R2 P1）→
//    valueChange 不受冷却 → enforcement 冷却门 → 其余 none
// ③ WP-5 fullOnce 测试钉 ×2（26 legacy capabilities=[] 可启动 / 26 瞬态 nil 可启动）
//    + 27 终态拒绝（文案钉死）+ 次序钉（terminal 先于 native——27 残留不误报）
// ④ F-1 三处透传钉（setLimits/disable/enable 重建形态往返保真 + 旧 JSON 缺键兼容
//    + 日程转移落地段形态）——照 FanDomain/ThermalPolicyDomain F-1 先例
// ⑤ wire 编解码往返 + 旧 daemon JSON 缺字段容忍 + valid* 值域矩阵
// ⑥ chargingDisabled 27 纯簿记的可测纯函数部分（在窗 desired=100 灌真值表路径）
// ⑦ doctor 检查 17 分支（未探测零渲染/通道可用/缺动作指引/失败 INFO）+ 检查 15
//    的 27「注册残留」语义（26 语义零回归由 NativeLimitWireDomain 医生-7..12 背书）
//
// 全部纯函数面（PolicyStore 临时目录/Data 注入），不触碰真实 plist、不起 daemon。

import CellarCore
import Foundation
import XPC

/// 编排场景域入口（Main.main 调用；断言经 MainEntry.swift 的 internal 助手）。
func runOrchestrationDomainScenarios() throws {
    try runOrchestrationNativeTargetScenarios()
    try runOrchestrationTruthTableScenarios()
    try runOrchestrationFullOnceGateScenarios()
    try runOrchestrationFOneScenarios()
    try runOrchestrationWireScenarios()
    try runOrchestrationXPCWireScenarios()
    try runOrchestrationDoctorScenarios()
}

// MARK: - ① nativeTarget 三分支

private func runOrchestrationNativeTargetScenarios() throws {
    // 编排-1：<80 → 钳 80（clamped=true，UI 标注「原生最低 80」）；80/85/100 →
    // 直通（S6：27 原生范围硬限 80-100）。
    check(NativeOrchestration.nativeTarget(effectiveLimit: 75) == (target: 80, clamped: true),
          "编排-1", "75 → (80, true)——<80 钳 80（walkthrough 项 3 形态）")
    check(NativeOrchestration.nativeTarget(effectiveLimit: 60) == (target: 80, clamped: true),
          "编排-1", "60（地板值）→ (80, true)")
    check(NativeOrchestration.nativeTarget(effectiveLimit: 80) == (target: 80, clamped: false),
          "编排-1", "80 → (80, false)——边界直通不标钳制")
    check(NativeOrchestration.nativeTarget(effectiveLimit: 85) == (target: 85, clamped: false),
          "编排-1", "85 → (85, false)——S3 实证目标")
    check(NativeOrchestration.nativeTarget(effectiveLimit: 100) == (target: 100, clamped: false),
          "编排-1", "100 → (100, false)——充满语义 = 编排目标 100%")
}

// MARK: - ② assertionRequest 真值表（判定次序逐条钉死）

private func runOrchestrationTruthTableScenarios() throws {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let cooldown = NativeOrchestration.defaultCooldown
    // 判定辅助：desired=85、lastApplied=85（稳态基线）、modeActive=true。
    func decide(
        desired: Int? = 85, lastApplied: Int? = 85, lastRequestAt: Date? = nil,
        now: Date = t0.addingTimeInterval(10_000),
        external: Bool = false, isCharging: Bool = false, percent: Int = 80,
        cooldown: TimeInterval = NativeOrchestration.defaultCooldown,
        actionActive: Bool = false, modeActive: Bool = true,
        hasOutstanding: Bool = false
    ) -> AssertionDecision {
        NativeOrchestration.assertionRequest(
            desired: desired, lastApplied: lastApplied, lastRequestAt: lastRequestAt,
            now: now, external: external, isCharging: isCharging, percent: percent,
            cooldown: cooldown, actionActive: actionActive, modeActive: modeActive,
            hasOutstanding: hasOutstanding
        )
    }

    // 编排-2（规则 1）：desired == nil ∨ !modeActive → .none（编排关/mode 门——
    // 27 上 disable 无物理动作，语义 = 停止编排）。
    check(decide(desired: nil) == .none, "编排-2", "desired nil（编排关）→ none")
    check(decide(modeActive: false) == .none, "编排-2", "modeActive false → none（mode 门先于一切）")
    check(decide(desired: nil, lastApplied: 80) == .none, "编排-2", "desired nil + lastApplied 在场 → none（不回设）")

    // 编排-3（规则 2）：actionActive → .none（不对抗；27 上 fullOnce 本就被拒绝
    // 启动——本规则兜底 26- 与未来动作）。
    check(decide(lastApplied: 80, actionActive: true) == .none,
          "编排-3", "动作在轨（valueChange 在望）→ none——actionActive 优先于 valueChange（R1 P2 次序钉死）")
    check(decide(external: true, isCharging: true, percent: 90, actionActive: true) == .none,
          "编排-3", "动作在轨（enforcement 条件齐备）→ none")

    // 编排-4（规则 3）：hasOutstanding ∧ 未过期 → .none（App 缺席期去抖；R2 P1：
    // TTL = 冷却窗 600s——签发时刻超窗视为过期可重发，防非管理员回报被拒 →
    // pending 永不清 → 编排死锁）。
    check(decide(lastRequestAt: t0.addingTimeInterval(9_500), hasOutstanding: true) == .none,
          "编排-4", "outstanding 未过期（elapsed 500s < TTL）→ none")
    check(decide(lastApplied: 80, lastRequestAt: t0.addingTimeInterval(9_500), hasOutstanding: true) == .none,
          "编排-4", "outstanding 未过期压过 valueChange（次序 3 < 4）")
    check(decide(lastRequestAt: nil, hasOutstanding: true) == .none,
          "编排-4", "outstanding 在场但 lastRequestAt 缺失 → none（无法证明过期即保守去抖）")
    // TTL 边界：elapsed == cooldown → 过期可重发（valueChange 接管）。
    check(decide(lastApplied: 80, lastRequestAt: t0.addingTimeInterval(10_000 - cooldown), hasOutstanding: true)
              == .assert(reason: .valueChange),
          "编排-4", "outstanding elapsed == TTL（600s）→ 过期，valueChange 重发（churn 上界每 TTL 一次）")

    // 编排-5（规则 4）：lastApplied != desired → .assert(.valueChange)，不受冷却限制。
    check(decide(lastApplied: 80) == .assert(reason: .valueChange),
          "编排-5", "lastApplied 80 != desired 85 → valueChange")
    check(decide(lastApplied: nil) == .assert(reason: .valueChange),
          "编排-5", "lastApplied nil（首次/重启丢失）→ valueChange（幂等误发一次，R1 P2 取舍）")
    check(decide(lastApplied: 80, lastRequestAt: t0.addingTimeInterval(9_999)) == .assert(reason: .valueChange),
          "编排-5", "valueChange 不受冷却限制（elapsed 1s 仍直发）")

    // 编排-6（规则 5）：lastApplied == desired ∧ external ∧ isCharging ∧
    // percent >= desired → 冷却门外 enforcement / 门内 none。
    let enforcement = AssertionDecision.assert(reason: .enforcement)
    check(decide(lastRequestAt: t0.addingTimeInterval(10_000 - cooldown), external: true, isCharging: true, percent: 90) == enforcement,
          "编排-6", "行为验证条件齐备 + 冷却门外（elapsed == 600s）→ enforcement")
    check(decide(lastRequestAt: t0.addingTimeInterval(10_000 - cooldown), external: true, isCharging: true, percent: 85) == enforcement,
          "编排-6", "percent == desired 边界 → enforcement（>= 判据）")
    check(decide(lastRequestAt: t0.addingTimeInterval(9_500), external: true, isCharging: true, percent: 90) == .none,
          "编排-6", "行为验证条件齐备 + 冷却门内 → none（10min 语义）")
    check(decide(external: true, isCharging: true, percent: 90) == enforcement,
          "编排-6", "lastRequestAt nil（从未签发）→ 冷却门外 enforcement")
    check(decide(external: true, isCharging: false, percent: 90) == .none,
          "编排-6", "未充电 → none（S5：从下往上充到上限为持续钳制，无需重申）")
    check(decide(external: false, isCharging: true, percent: 90) == .none,
          "编排-6", "未外接 → none")
    check(decide(external: true, isCharging: true, percent: 84) == .none,
          "编排-6", "percent < desired → none（未达目标，充电即预期行为）")

    // 编排-7（chargingDisabled 在窗 27 语义的可测纯函数部分）：在窗期间编排
    // desired 强制 100（R2 P1——等价「完全放开」，退出边沿恢复 base）→ 真值表
    // 照常推进：进窗 desired 85→100 走 valueChange；窗内已生效（lastApplied=100）
    // 行为验证走 enforcement 冷却门。
    check(decide(desired: 100, lastApplied: 85) == .assert(reason: .valueChange),
          "编排-7", "chargingDisabled 在窗 desired=100、lastApplied=85 → valueChange（进窗放开）")
    check(decide(desired: 100, lastApplied: 100,
                 lastRequestAt: t0.addingTimeInterval(10_000 - cooldown),
                 external: true, isCharging: true, percent: 100) == enforcement,
          "编排-7", "在窗 desired=100 已生效 + 电量达 100 仍充电 + 冷却门外 → enforcement（在窗重申钳制——percent >= desired 判据）")
    // 退出边沿：desired 回 base（nativeTarget 映射后）→ lastApplied(100) != desired → valueChange 拉回。
    check(decide(desired: 80, lastApplied: 100) == .assert(reason: .valueChange),
          "编排-7", "退出边沿 lastApplied=100 != desired=80 → valueChange（恢复 base）")
}

// MARK: - ③ WP-5 fullOnce 门测试钉

private func runOrchestrationFullOnceGateScenarios() throws {
    // 编排-8：**两条测试钉**（R2 P2 钉死）——26 legacy（capabilities=[]、非终态）
    // 可启动 / 26 瞬态（backend=nil → capabilities=nil、非终态）可启动。
    check(fullOnceStartPrecondition(mode: "active", externalConnected: true, capabilities: []) == nil,
          "编排-8", "26 legacy：capabilities=[]（CH0B 后端在场）→ 放行（勿用 [] 误判 27）")
    check(fullOnceStartPrecondition(mode: "active", externalConnected: true, capabilities: nil) == nil,
          "编排-8", "26 瞬态：capabilities=nil（后端缺席窗口）→ 放行（勿用 backend nil 误判 27）")
    check(fullOnceStartPrecondition(mode: "active", externalConnected: true, capabilities: ["discharge"]) == nil,
          "编排-8", "26 discharge 机器 → 放行")

    // 编排-9：27 终态（capabilities 含 orchestration）→ 拒绝 + 文案钉死。
    let rejected = fullOnceStartPrecondition(
        mode: "active", externalConnected: true, capabilities: ["orchestration"]
    )
    check(rejected == .orchestrationTerminal,
          "编排-9", "27 终态 → .orchestrationTerminal（fail-visible）")
    check(rejected?.message == "平台限制：macOS 27 暂不支持充满一次（可用编排目标 100% 替代）",
          "编排-9", "拒绝文案钉死（可用编排目标 100% 替代）")

    // 编排-10：次序钉——terminal 判定先于 nativeLimit（27 上 plist 残留策略不得
    // 以 nativeChargeLimit 语义误报）；mode/外接门仍最优先。
    do {
        let residual = NativeChargeLimitReading(policies: [
            NativeChargePolicy(socLimit: 85, reason: "manualChargeLimit", terminated: false),
        ], detectorError: false)
        check(fullOnceStartPrecondition(
            mode: "active", externalConnected: true, nativeLimit: residual,
            capabilities: ["orchestration"]) == .orchestrationTerminal,
              "编排-10", "27 残留 85 在场 → 仍 .orchestrationTerminal（terminal 先于 native）")
        check(fullOnceStartPrecondition(
            mode: "disabled", externalConnected: true, capabilities: ["orchestration"]) == .modeNotActive,
              "编排-10", "mode 门先于 terminal 判定（既有前置次序不被新 case 扰动）")
        check(fullOnceStartPrecondition(
            mode: "active", externalConnected: false, capabilities: ["orchestration"]) == .noExternalPower,
              "编排-10", "外接门先于 terminal 判定")
        check(OneShotStartRejection.orchestrationTerminal == OneShotStartRejection.orchestrationTerminal,
              "编排-10", "新 case Equatable 合成可用（daemon 上抛 → XPC errorReply 原文通道）")
    }
}

// MARK: - ④ F-1 三处透传钉（DaemonPolicy.orchestrationEnabled）

private func runOrchestrationFOneScenarios() throws {
    // 编排-11：load() 保真——带编排开关的策略落盘再读回逐字段一致（照风扇透传-1 先例）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-orch-f1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PolicyStore(url: directory.appendingPathComponent("policy.json"))
        let original = DaemonPolicy(
            mode: "active", upperLimit: 85, hysteresis: 2,
            autoDischargeEnabled: true, orchestrationEnabled: true
        )
        try store.save(original)
        let loaded = store.load()
        check(loaded?.orchestrationEnabled == true && loaded?.autoDischargeEnabled == true
                  && loaded?.upperLimit == 85,
              "编排-11", "load() 保真：orchestrationEnabled 与既有字段并存不覆盖")
    }
    // 编排-12：旧 policy.json 无 orchestrationEnabled 键 → nil（decodeIfPresent 兼容）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-orch-f1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy.json")
        try #"{"mode":"active","upperLimit":75,"hysteresis":3}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let loaded = PolicyStore(url: url).load()
        check(loaded?.orchestrationEnabled == nil && loaded?.upperLimit == 75,
              "编排-12", "旧 JSON 无键 → nil（0.19.19 形态零回归）")
    }
    // 编排-13：三构造点重建形态（daemon 侧显式字段拷贝）往返保真——漏带 =
    // persistPolicyLocked 覆写丢开关（F-1 强制条款；CellarCoreCheck 以 PolicyStore
    // + 临时目录模拟重建/回流形态，照热透传-5/6/7 先例）。
    do {
        // setLimits 形态：mode 固定 active + 显式字段拷贝。
        let directorySet = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-orch-f1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directorySet, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directorySet) }
        let storeSet = PolicyStore(url: directorySet.appendingPathComponent("policy.json"))
        let baseSet = DaemonPolicy(mode: "active", upperLimit: 85, hysteresis: 2, orchestrationEnabled: true)
        try storeSet.save(DaemonPolicy(
            mode: "active", upperLimit: 90, hysteresis: 3,
            autoDischargeEnabled: baseSet.autoDischargeEnabled, fan: baseSet.fan,
            calibrationSchedule: baseSet.calibrationSchedule, thermal: baseSet.thermal,
            schedule: baseSet.schedule, magSafeLedMode: baseSet.magSafeLedMode,
            orchestrationEnabled: baseSet.orchestrationEnabled
        ))
        check(storeSet.load()?.orchestrationEnabled == true,
              "编排-13", "setLimits 重建形态（active + 编排开关透传）往返保真")

        // disable 形态：mode=disabled + 其余字段拷贝。
        let directoryDis = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-orch-f1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryDis, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryDis) }
        let storeDis = PolicyStore(url: directoryDis.appendingPathComponent("policy.json"))
        let baseDis = DaemonPolicy(mode: "active", upperLimit: 80, hysteresis: 2, orchestrationEnabled: true)
        try storeDis.save(DaemonPolicy(
            mode: "disabled", upperLimit: baseDis.upperLimit, hysteresis: baseDis.hysteresis,
            autoDischargeEnabled: baseDis.autoDischargeEnabled, fan: baseDis.fan,
            calibrationSchedule: baseDis.calibrationSchedule, thermal: baseDis.thermal,
            schedule: baseDis.schedule, magSafeLedMode: baseDis.magSafeLedMode,
            orchestrationEnabled: baseDis.orchestrationEnabled
        ))
        check(storeDis.load()?.orchestrationEnabled == true && storeDis.load()?.mode == "disabled",
              "编排-13", "disable 重建形态（disabled + 编排开关透传）往返保真")

        // enable 形态 + 编排开关 == nil 显式透传仍 nil（重建不误造默认）。
        let directoryEn = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-orch-f1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryEn, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryEn) }
        let storeEn = PolicyStore(url: directoryEn.appendingPathComponent("policy.json"))
        let baseEn = DaemonPolicy(mode: "disabled", upperLimit: 70, hysteresis: 1)
        try storeEn.save(DaemonPolicy(
            mode: "active", upperLimit: baseEn.upperLimit, hysteresis: baseEn.hysteresis,
            autoDischargeEnabled: baseEn.autoDischargeEnabled, fan: baseEn.fan,
            calibrationSchedule: baseEn.calibrationSchedule, thermal: baseEn.thermal,
            schedule: baseEn.schedule, magSafeLedMode: baseEn.magSafeLedMode,
            orchestrationEnabled: baseEn.orchestrationEnabled
        ))
        check(storeEn.load()?.orchestrationEnabled == nil,
              "编排-13", "enable 重建形态：编排开关 nil 显式透传 → 往返仍 nil（不误造默认）")

        // 日程转移落地段形态（applySchedulePolicyLocked——daemon 第四构造点）：
        // validated 全字段拷贝保真。
        let transferred = DaemonPolicy.validated(
            mode: "active", upperLimit: 70, hysteresis: 2,
            orchestrationEnabled: true
        )
        check(transferred?.orchestrationEnabled == true,
              "编排-13", "日程转移落地段形态（validated 透传）保真——漏带 = 转移清空用户开关")
    }
}

// MARK: - ⑤ wire 编解码 / DaemonStatus 兼容

private func runOrchestrationWireScenarios() throws {
    // 编排-14：OrchestrationStatus round-trip（DaemonStatus.orchestration 载荷全字段）。
    do {
        var status = DaemonStatus(version: "t", mode: "active", upperLimit: 85, hysteresis: 2)
        status.orchestration = OrchestrationStatus(
            enabled: true, pendingToken: "tok-1234", pendingTarget: 85,
            lastApplied: 80, lastError: nil
        )
        let round = DaemonXPC.encodeStatus(status).flatMap { try? DaemonXPC.decodeStatus($0) }
        check(round == status && round?.orchestration == status.orchestration,
              "编排-14", "orchestration 载荷 round-trip 全字段保留（enabled/pendingToken/pendingTarget/lastApplied）")
        var failure = DaemonStatus(version: "t", mode: "active", upperLimit: 85, hysteresis: 2)
        failure.orchestration = OrchestrationStatus(
            enabled: true, pendingToken: nil, pendingTarget: nil,
            lastApplied: 85, lastError: "快捷指令执行失败（exit 1）"
        )
        let failureRound = DaemonXPC.encodeStatus(failure).flatMap { try? DaemonXPC.decodeStatus($0) }
        check(failureRound?.orchestration?.lastError == "快捷指令执行失败（exit 1）",
              "编排-14", "lastError 形态 round-trip（失败回报详情）")
    }
    // 编排-15：旧 daemon 回包无 orchestration 键 → 解码 nil（升级窗口双向兼容）。
    do {
        let legacyJSON = #"{"version":"0.19.11-alpha","mode":"active","upperLimit":80,"hysteresis":2,"timestamp":123.0}"#
        let legacy = try? JSONDecoder().decode(DaemonStatus.self, from: Data(legacyJSON.utf8))
        check(legacy?.orchestration == nil && legacy?.upperLimit == 80,
              "编排-15", "旧 daemon JSON（无 orchestration 键）→ 解码 nil 且既有字段照常（decodeIfPresent）")
        // 缺 pendingTarget 子键（部分形态）→ 该键 nil、其余保留。
        let partialJSON = #"{"version":"t","mode":"active","upperLimit":80,"hysteresis":2,"orchestration":{"enabled":true},"timestamp":123.0}"#
        let partial = try? JSONDecoder().decode(DaemonStatus.self, from: Data(partialJSON.utf8))
        check(partial?.orchestration?.enabled == true && partial?.orchestration?.pendingToken == nil,
              "编排-15", "载荷子键缺席 → 子键 nil、enabled 照常（合成 Codable decodeIfPresent）")
    }
    // 编排-16：wire 值域矩阵（XPCServer 臂 / validateRequest 同源常量）。
    do {
        check(OrchestrationWireKeys.validEnabled(0) && OrchestrationWireKeys.validEnabled(1)
                  && !OrchestrationWireKeys.validEnabled(2),
              "编排-16", "开关值域 0/1（R2 P3：键型照既有开关统一）")
        check(!OrchestrationWireKeys.validToken("")
                  && OrchestrationWireKeys.validToken(String(repeating: "a", count: 64))
                  && !OrchestrationWireKeys.validToken(String(repeating: "a", count: 65)),
              "编排-16", "token 非空且 ≤64 字节边界")
        check(OrchestrationWireKeys.validDetail(String(repeating: "a", count: 8192))
                  && !OrchestrationWireKeys.validDetail(String(repeating: "a", count: 8193)),
              "编排-16", "detail ≤8192 字节边界（照 scheduleJson 上限先例）")
        check(OrchestrationWireKeys.command == "setOrchestration"
                  && OrchestrationWireKeys.reportCommand == "reportOrchestration",
              "编排-16", "命令字面量钉死（XPCServer 臂 / DaemonXPCClient 同源）")
    }
    // 编排-17：OrchestrationState 形态（hasOutstanding / empty）。
    do {
        let empty = OrchestrationState.empty
        check(!empty.hasOutstanding && empty.pendingToken == nil && empty.lastAppliedTarget == nil,
              "编排-17", "空状态：无 outstanding、无 lastApplied（daemon 启动初值——重启后首 tick valueChange 幂等误发，R1 P2 取舍）")
        let pending = OrchestrationState(pendingToken: "tok", pendingTarget: 85)
        check(pending.hasOutstanding && pending.pendingToken == "tok",
              "编排-17", "pending 在场 → hasOutstanding（真值表规则 3 输入）")
    }
}

// MARK: - ⑥' XPC 线格式（makeMessage + validateRequest 编排键组；照热线-3 先例）

private func runOrchestrationXPCWireScenarios() throws {
    // 编排-18：makeMessage 编排键组构造（开关单键 + 回报三键；detail 缺席不发键）。
    do {
        let enableMsg = DaemonXPC.makeMessage(
            cmd: OrchestrationWireKeys.command, upper: 0, hysteresis: 0, orchestrationEnabled: 1
        )
        let enableParsed = DaemonXPC.validateRequest(enableMsg)
        check(enableParsed?.orchestrationEnabled == 1 && enableParsed?.orchestrationReport == nil,
              "编排-18", "setOrchestration 消息 → orchestrationEnabled=1 提取、report nil")
        let reportMsg = DaemonXPC.makeMessage(
            cmd: OrchestrationWireKeys.reportCommand, upper: 0, hysteresis: 0,
            orchestrationReport: OrchestrationReportWire(token: "tok-1", ok: 0, detail: "执行失败")
        )
        let reportParsed = DaemonXPC.validateRequest(reportMsg)
        check(reportParsed?.orchestrationEnabled == nil
                  && reportParsed?.orchestrationReport == OrchestrationReportWire(token: "tok-1", ok: 0, detail: "执行失败"),
              "编排-18", "reportOrchestration 消息 → 三键 wire 提取（ok=false + detail）")
        let okNoDetail = DaemonXPC.makeMessage(
            cmd: OrchestrationWireKeys.reportCommand, upper: 0, hysteresis: 0,
            orchestrationReport: OrchestrationReportWire(token: "tok-2", ok: 1, detail: nil)
        )
        let okParsed = DaemonXPC.validateRequest(okNoDetail)
        check(okParsed?.orchestrationReport?.detail == nil
                  && okParsed?.orchestrationReport?.ok == 1,
              "编排-18", "ok=true 无 detail → detail 键不发（缺席即「无详情」语义）")
    }
    // 编排-19：validateRequest 类型白名单——STRING 混入开关键 / token 超长 /
    // detail 超长 → 整包拒绝；既有命令无编排键 → 双字段 nil 兼容。
    do {
        func baseMessage(_ cmd: String) -> xpc_object_t {
            let msg = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(msg, DaemonXPC.cmdKey, cmd)
            xpc_dictionary_set_uint64(msg, DaemonXPC.upperKey, 0)
            xpc_dictionary_set_uint64(msg, DaemonXPC.hysteresisKey, 0)
            return msg
        }
        let mixed = baseMessage(OrchestrationWireKeys.command)
        xpc_dictionary_set_string(mixed, OrchestrationWireKeys.enabled, "1")   // STRING 混入 UINT64 键
        check(DaemonXPC.validateRequest(mixed) == nil,
              "编排-19", "开关键以 STRING 混入 → 整包拒绝（不崩溃，照 auto 同纪律）")
        let longToken = baseMessage(OrchestrationWireKeys.reportCommand)
        xpc_dictionary_set_string(longToken, OrchestrationWireKeys.token, String(repeating: "a", count: 65))
        check(DaemonXPC.validateRequest(longToken) == nil,
              "编排-19", "token 超 64 字节 → 整包拒绝")
        let longDetail = baseMessage(OrchestrationWireKeys.reportCommand)
        xpc_dictionary_set_string(longDetail, OrchestrationWireKeys.token, "tok")
        xpc_dictionary_set_string(longDetail, OrchestrationWireKeys.detail, String(repeating: "a", count: 8193))
        check(DaemonXPC.validateRequest(longDetail) == nil,
              "编排-19", "detail 超 8192 字节 → 整包拒绝（照 scheduleJson 同纪律）")
        let plain = baseMessage("setLimits")
        let plainParsed = DaemonXPC.validateRequest(plain)
        check(plainParsed?.orchestrationEnabled == nil && plainParsed?.orchestrationReport == nil,
              "编排-19", "既有命令无编排键 → 编排字段 nil（天然兼容）")
    }
}

// MARK: - ⑦ doctor 检查 17 + 检查 15 的 27 语义

private func runOrchestrationDoctorScenarios() throws {
    let snapshot = try? BatterySnapshotParser.parse(batteryProps(), timestamp: Date())
    func doctorInputs(
        nativeLimit: NativeLimitStatus? = nil,
        nativeAttempted: Bool = false,
        orchestrationProbe: OrchestrationDoctorProbe? = nil,
        orchestrationAttempted: Bool = false,
        osMajorVersion: Int = 26
    ) -> DoctorInputs {
        DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: snapshot, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            daemonStatus: DaemonStatus(version: "t", mode: "active", upperLimit: 80, hysteresis: 2),
            daemonProbeAttempted: true,
            nativeLimit: nativeLimit,
            nativeLimitProbeAttempted: nativeAttempted,
            orchestrationProbe: orchestrationProbe,
            orchestrationProbeAttempted: orchestrationAttempted,
            osMajorVersion: osMajorVersion
        )
    }
    func check17(_ inputs: DoctorInputs) -> DoctorCheck? {
        DoctorReportGenerator.generate(inputs).checks.first { $0.name == "编排通道" }
    }
    func check15(_ inputs: DoctorInputs) -> DoctorCheck? {
        DoctorReportGenerator.generate(inputs).checks.first { $0.name == "原生限充共存" }
    }

    // 医生-13（检查 17）：attempted 缺省 → 零渲染（检查 15/16 惯例；既有 count
    // 断言零回归）；已探测 + 默认动作在列 → PASS。
    do {
        let report = DoctorReportGenerator.generate(doctorInputs(orchestrationProbe: nil))
        check(report.checks.first { $0.name == "编排通道" } == nil,
              "医生-13", "orchestrationProbeAttempted 缺省 → 检查 17 不渲染（条件渲染兼容约束）")
        let pass = check17(doctorInputs(orchestrationProbe: OrchestrationDoctorProbe(
            listSucceeded: true, shortcutCount: 3, defaultShortcutPresent: true, failureDetail: nil
        ), orchestrationAttempted: true))
        check(pass?.status == .pass && pass?.detail.contains("已找到") == true
                  && pass?.detail.contains(NativeOrchestration.defaultShortcutName) == true,
              "医生-13", "通道可用 + 默认动作在列 → PASS（detail 含动作名）")
        let full = DoctorReportGenerator.generate(doctorInputs(
            orchestrationProbe: OrchestrationDoctorProbe(
                listSucceeded: true, shortcutCount: 1, defaultShortcutPresent: true, failureDetail: nil
            ), orchestrationAttempted: true
        ))
        check(full.checks.last?.name == "编排通道",
              "医生-13", "检查 17 追加在末尾（顺序钉死——检查 16 之后）")
    }
    // 医生-14（检查 17）：列表可用但缺动作 → INFO 指引；执行失败 → INFO 不抬退出码。
    do {
        let missing = check17(doctorInputs(orchestrationProbe: OrchestrationDoctorProbe(
            listSucceeded: true, shortcutCount: 2, defaultShortcutPresent: false, failureDetail: nil
        ), orchestrationAttempted: true))
        check(missing?.status == .info && missing?.detail.contains("未找到") == true,
              "医生-14", "缺默认动作 → INFO 指引（不抬退出码——setup 未完成属常态）")
        let failed = check17(doctorInputs(orchestrationProbe: OrchestrationDoctorProbe(
            listSucceeded: false, shortcutCount: nil, defaultShortcutPresent: nil,
            failureDetail: "shortcuts: command error"
        ), orchestrationAttempted: true))
        check(failed?.status == .info && failed?.detail.contains("执行失败") == true
                  && failed?.detail.contains("shortcuts: command error") == true,
              "医生-14", "shortcuts list 失败 → INFO 带详情（不抬退出码）")
        let inputs = doctorInputs(orchestrationProbe: OrchestrationDoctorProbe(
            listSucceeded: true, shortcutCount: 1, defaultShortcutPresent: true, failureDetail: nil
        ), orchestrationAttempted: true)
        check(DoctorReportGenerator.generate(inputs).exitCode == 0,
              "医生-14", "全绿样本退出码 0（PASS/INFO 均不参与 worstStatus 抬升之外的面）")
    }
    // 医生-15（检查 15 的 WP-6 语义）：27 → 注册残留 INFO（冲突/等效分流不适用）；
    // 26 语义零回归（医生-8/9/10 已钉 26 分支——此处仅钉 27 臂 + 边界）。
    do {
        let active85 = NativeLimitStatus(known: true, active: true, socLimit: 85, manualSocLimit: 85)
        let residual27 = check15(doctorInputs(
            nativeLimit: active85, nativeAttempted: true, osMajorVersion: 27
        ))
        check(residual27?.status == .info && residual27?.detail.contains("注册残留 85%") == true
                  && residual27?.detail.contains("非现行上限") == true,
              "医生-15", "27 + active 85 → INFO「注册残留 85%（非现行上限）」（S4：plist 残留形态）")
        check(residual27?.detail.contains("二选一") != true,
              "医生-15", "27 不触发冲突 WARN 分流（冲突横幅/等效口径 27 不适用——编排即执法者）")
        let residual26 = check15(doctorInputs(
            nativeLimit: active85, nativeAttempted: true, osMajorVersion: 26
        ))
        check(residual26?.status == .warn && residual26?.detail.contains("Cellar 执法生效") == true,
              "医生-15", "26 同输入 → WARN 现行语义（osMajorVersion 缺省 26 = 既有断言零回归）")
        let inactive27 = check15(doctorInputs(
            nativeLimit: NativeLimitStatus(known: true, active: false, socLimit: nil, manualSocLimit: nil),
            nativeAttempted: true, osMajorVersion: 27
        ))
        check(inactive27?.status == .pass && inactive27?.detail.contains("未检测到") == true,
              "医生-15", "27 + 无阻断策略 → PASS 注册态（残留臂仅在 active 时接管）")
    }
}
