// CellarCoreCheck —— Phase 5 v1.1 风扇智能降温场景域（方案 §9 表：F-1 全构造点 /
// FanGuard 矩阵 / 能力推进 / validFan* / DaemonStatus 兼容 —— 合计 ≈87 场景）
//
// 覆盖清单（方案 §9，逐组对齐；P1/P2 评审修订已并入）：
// ① FanPolicy 校验 10：默认值 / 边界内 / 各字段越界 → nil / 枚举法定型 /
//   Codable roundtrip
// ② F-1 全构造点透传 8：load() 保真；旧 JSON 无 fan 键 → nil；fan 非法值回流
//   → 整包 nil；setLimits/disable/enable 三处重建形态往返后 fan 保真（逻辑层
//   以 PolicyStore+临时目录模拟——daemon 为 executable 不可 import）
// ③ FanGuard 矩阵 39：A/B/F/C'/C/G/D/E/S 全覆盖 + 求值序钉死（F 压过 D、B 压过
//   C、A 压过一切、G 先于 E）+ 滞回边界（threshold−hys±ε）+ clamp 边界（Mn/Mx
//   端点）+ twoStage 升档写去重（P1-1：目标未变 → hold）/降档 hold + facts=nil
//   探测中 + minRaise 拒绝 + 不变量防御
// ④ 能力推进 10：unverified→verified / 观察窗到期 →unavailable / sticky /
//   开关翻转重置（resetRequired）/ 常量钉死
// ⑤ validFan* 10：各键值域拒绝矩阵 + 与 validated 同源抽查 + 缺席保持合并 +
//   STRING 混入整包拒绝 + 键域错误分流（P1-2 isKeyDomainError）
// ⑤b FanSMC LE 编解码向量 + 锁存阶梯常量 2：1350 ↔ 00C0A844 双向 + BE 反例 +
//   roundtrip；verifyLadderMs 语义（0.5.1-alpha 热修，真机验证路径注记）
// ⑥ DaemonStatus 兼容 3：旧 JSON 无 fan 键 → nil；fan roundtrip；显式 null
//（doctor 风扇检查项 5 场景在 FanDoctorDomain.swift——同域拆分，FanDomain 限 800 行）
//
// ⚠️ 浮点精确断言：C 组目标值一律取「精确可表示」组合（facts=(1500,4000)，
// speed=50%/stage2=80% → 2000/3200 精确）——防浮点尾差把矩阵钉死变脆弱。
import CellarCore
import Foundation
/// 风扇场景域入口（Main.main 调用；断言经 MainEntry.swift 的 internal 助手）。
func runFanDomainScenarios() throws {
    try runFanPolicyScenarios()
    try runFanFOneScenarios()
    runFanGuardScenarios()
    runFanCapabilityScenarios()
    runFanWireValidationScenarios()
    runFanSMCCodecScenarios()
    try runFanStatusCompatibilityScenarios()
    runFanDoctorScenarios()
}

// MARK: - 场景域内助手（本文件私有；与 MainEntry 的 check/expectEqual 共用）
/// 精确可表示事实（50%×4000=2000、80%×4000=3200 全为二进制精确值）。
private func fanFacts(min: Float = 1500, max: Float = 4000) -> FanFacts {
    FanFacts(minRPM: min, maxRPM: max)
}
/// 测试策略构造（默认：开启/恒速/阈值 3700/滞回 200/转速 50%/二级 80%/升档 300）。
private func fanPolicy(
    enabled: Bool = true,
    strategy: FanStrategy = .constantSpeed,
    thresholdCentiC: Int = 3700,
    hysteresisCentiC: Int = 200,
    speed: Int = 50,
    stage2: Int = 80,
    stage2Rise: Int = 300
) -> FanPolicy {
    FanPolicy(
        enabled: enabled, strategy: strategy,
        thresholdCentiC: thresholdCentiC, releaseHysteresisCentiC: hysteresisCentiC,
        speedPercent: speed, stage2Percent: stage2, stage2RiseCentiC: stage2Rise
    )
}
/// 决策调用捷径（矩阵正例默认输入：健康 + 已认证 + 活跃模式 + 无当前目标）。
/// 参数序与 FanGuard.decided 签名（方案 §5.1 + P1-1 去重输入）逐位一致——
/// 防测试侧默认参数错位。
private func decide(
    temperatureC: Double,
    policy: FanPolicy,
    modeActive: Bool = true,
    capability: FanCapability = .verified,
    boostActive: Bool = false,
    boostTicks: Int = 0,
    currentTargetRPM: Float? = nil,
    facts: FanFacts? = fanFacts(),
    sampleHealthy: Bool = true
) -> FanDecision {
    FanGuard.decided(
        temperatureC: temperatureC,
        policy: policy,
        modeActive: modeActive,
        capability: capability,
        boostActive: boostActive,
        boostTicks: boostTicks,
        currentTargetRPM: currentTargetRPM,
        facts: facts,
        sampleHealthy: sampleHealthy
    )
}

// MARK: - ① FanPolicy 校验（方案 §4；10 场景）
private func runFanPolicyScenarios() throws {
    // 风扇策-1：默认值字段逐一断言 + 默认值整体过 validated。
    do {
        let d = FanPolicy.default
        check(d.enabled == false && d.strategy == .constantSpeed
                && d.thresholdCentiC == 3700 && d.releaseHysteresisCentiC == 200
                && d.speedPercent == 60 && d.stage2Percent == 90 && d.stage2RiseCentiC == 300,
              "风扇策-1", "默认值定版：off/恒速/3700/200/60%/90%/300（方案 §4）")
        check(FanPolicy.validated(
            enabled: d.enabled, strategy: d.strategy,
            thresholdCentiC: d.thresholdCentiC, releaseHysteresisCentiC: d.releaseHysteresisCentiC,
            speedPercent: d.speedPercent, stage2Percent: d.stage2Percent,
            stage2RiseCentiC: d.stage2RiseCentiC
        ) != nil, "风扇策-1", "默认值整体过 validated（非 nil）")
    }
    // 风扇策-2：边界内端点组合（低端点/高端点）→ 合法。
    do {
        let low = FanPolicy.validated(
            enabled: false, strategy: .emergency,
            thresholdCentiC: 3000, releaseHysteresisCentiC: 100,
            speedPercent: 40, stage2Percent: 60, stage2RiseCentiC: 100
        )
        let high = FanPolicy.validated(
            enabled: true, strategy: .twoStage,
            thresholdCentiC: 5500, releaseHysteresisCentiC: 500,
            speedPercent: 100, stage2Percent: 100, stage2RiseCentiC: 500
        )
        check(low != nil && high != nil, "风扇策-2", "两端点组合全部合法（3000/5500·100/500·40/100·60/100·100/500）")
    }
    // 风扇策-3：阈值越界（2999/5501）→ nil。
    do {
        let below = FanPolicy.validated(
            enabled: true, strategy: .constantSpeed,
            thresholdCentiC: 2999, releaseHysteresisCentiC: 200,
            speedPercent: 60, stage2Percent: 90, stage2RiseCentiC: 300
        )
        let above = FanPolicy.validated(
            enabled: true, strategy: .constantSpeed,
            thresholdCentiC: 5501, releaseHysteresisCentiC: 200,
            speedPercent: 60, stage2Percent: 90, stage2RiseCentiC: 300
        )
        check(below == nil && above == nil, "风扇策-3", "阈值越界（2999/5501）→ nil")
    }
    // 风扇策-4：滞回越界（99/501）→ nil。
    do {
        let below = FanPolicy.validated(
            enabled: true, strategy: .constantSpeed,
            thresholdCentiC: 3700, releaseHysteresisCentiC: 99,
            speedPercent: 60, stage2Percent: 90, stage2RiseCentiC: 300
        )
        let above = FanPolicy.validated(
            enabled: true, strategy: .constantSpeed,
            thresholdCentiC: 3700, releaseHysteresisCentiC: 501,
            speedPercent: 60, stage2Percent: 90, stage2RiseCentiC: 300
        )
        check(below == nil && above == nil, "风扇策-4", "滞回越界（99/501 厘摄氏度）→ nil")
    }
    // 风扇策-5：转速越界（39/101）→ nil。
    do {
        let below = FanPolicy.validated(
            enabled: true, strategy: .constantSpeed,
            thresholdCentiC: 3700, releaseHysteresisCentiC: 200,
            speedPercent: 39, stage2Percent: 90, stage2RiseCentiC: 300
        )
        let above = FanPolicy.validated(
            enabled: true, strategy: .constantSpeed,
            thresholdCentiC: 3700, releaseHysteresisCentiC: 200,
            speedPercent: 101, stage2Percent: 90, stage2RiseCentiC: 300
        )
        check(below == nil && above == nil, "风扇策-5", "转速越界（39/101%）→ nil")
    }
    // 风扇策-6：二级转速越界（59/101）→ nil。
    do {
        let below = FanPolicy.validated(
            enabled: true, strategy: .twoStage,
            thresholdCentiC: 3700, releaseHysteresisCentiC: 200,
            speedPercent: 60, stage2Percent: 59, stage2RiseCentiC: 300
        )
        let above = FanPolicy.validated(
            enabled: true, strategy: .twoStage,
            thresholdCentiC: 3700, releaseHysteresisCentiC: 200,
            speedPercent: 60, stage2Percent: 101, stage2RiseCentiC: 300
        )
        check(below == nil && above == nil, "风扇策-6", "二级转速越界（59/101%）→ nil")
    }
    // 风扇策-7：升档温差越界（99/501）→ nil。
    do {
        let below = FanPolicy.validated(
            enabled: true, strategy: .twoStage,
            thresholdCentiC: 3700, releaseHysteresisCentiC: 200,
            speedPercent: 60, stage2Percent: 90, stage2RiseCentiC: 99
        )
        let above = FanPolicy.validated(
            enabled: true, strategy: .twoStage,
            thresholdCentiC: 3700, releaseHysteresisCentiC: 200,
            speedPercent: 60, stage2Percent: 90, stage2RiseCentiC: 501
        )
        check(below == nil && above == nil, "风扇策-7", "升档温差越界（99/501 厘摄氏度）→ nil")
    }
    // 风扇策-8：枚举法定型（顺序 = rawValue 不重排）——allCases 顺序与线格式
    // 映射 0..3 逐位一致（只追加不重排，R1 P3-3）。
    do {
        let strategies = FanStrategy.allCases
        check(strategies == [.constantSpeed, .minRaise, .twoStage, .emergency],
              "风扇策-8", "allCases 顺序 = 定版目录（constantSpeed/minRaise/twoStage/emergency）")
        check(zip(strategies, [0, 1, 2, 3]).allSatisfy { FanWire.wireValue($0) == $1 },
              "风扇策-8", "wire 映射逐个命中（0=恒速 1=抬升 2=两级 3=应急——只追加不重排）")
    }
    // 风扇策-9：组合非法 → 整包 nil（绝不半合法——A-2 同纪律）。
    do {
        let combo = FanPolicy.validated(
            enabled: true, strategy: .constantSpeed,
            thresholdCentiC: 9999, releaseHysteresisCentiC: 200,
            speedPercent: 101, stage2Percent: 90, stage2RiseCentiC: 300
        )
        check(combo == nil, "风扇策-9", "多字段同时越界 → 整包 nil（不落半合法策略）")
    }
    // 风扇策-10：Codable roundtrip 保真（含 enabled=true 全字段形态）。
    do {
        let original = fanPolicy(enabled: true, strategy: .twoStage, thresholdCentiC: 4200)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FanPolicy.self, from: data)
        check(decoded == original, "风扇策-10", "FanPolicy Codable roundtrip 保真（twoStage/4200 全字段）")
    }
}

// MARK: - ② F-1 全构造点透传（方案 §4 F-1 强制条款；8 场景）
private func runFanFOneScenarios() throws {
    // 风扇透传-1：load() 保真——带 fan 的策略落盘再读回，fan 逐字段一致。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-fan-f1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PolicyStore(url: directory.appendingPathComponent("policy.json"))
        let original = DaemonPolicy(
            mode: "active", upperLimit: 80, hysteresis: 2,
            autoDischargeEnabled: true,
            fan: fanPolicy(enabled: true, strategy: .twoStage, thresholdCentiC: 4200, speed: 70)
        )
        try store.save(original)
        let loaded = store.load()
        check(loaded?.fan == original.fan && loaded?.autoDischargeEnabled == true,
              "风扇透传-1", "load() 保真：fan 逐字段一致 + autoDischargeEnabled 并存不覆盖")
    }
    // 风扇透传-2：旧 policy.json 无 fan 键 → fan == nil（解码兼容不新增必填）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-fan-f1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy.json")
        // 0.4.0 形态：无 autoDischargeEnabled 更无 fan。
        try """
        {"mode":"active","upperLimit":75,"hysteresis":3}
        """.write(to: url, atomically: true, encoding: .utf8)
        let loaded = PolicyStore(url: url).load()
        check(loaded?.fan == nil && loaded?.upperLimit == 75,
              "风扇透传-2", "旧 JSON 无 fan 键 → fan==nil（decodeIfPresent 兼容）")
    }
    // 风扇透传-3：fan 非法值（阈值越界）持久化回流 → 整包 nil（load 强校验）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-fan-f1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy.json")
        try """
        {"mode":"active","upperLimit":80,"hysteresis":2,"fan":{"enabled":true,"strategy":"constantSpeed","thresholdCentiC":9999,"releaseHysteresisCentiC":200,"speedPercent":60,"stage2Percent":90,"stage2RiseCentiC":300}}
        """.write(to: url, atomically: true, encoding: .utf8)
        let loaded = PolicyStore(url: url).load()
        check(loaded == nil, "风扇透传-3", "fan 阈值 9999 回流 → 整包 nil（A-2 同纪律：绝不回落半合法配置）")
    }
    // 风扇透传-4：setLimits 重建形态（active+显式字段拷贝+fan 透传）落盘往返保真。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-fan-f1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PolicyStore(url: directory.appendingPathComponent("policy.json"))
        let base = DaemonPolicy(
            mode: "disabled", upperLimit: 85, hysteresis: 5,
            autoDischargeEnabled: false,
            fan: fanPolicy(enabled: true, strategy: .emergency, thresholdCentiC: 3800, speed: 80)
        )
        // daemon 侧 setLimits 的构造模式（DaemonCore.swift）：mode 固定 active + 显式字段拷贝。
        let rebuilt = DaemonPolicy(
            mode: "active", upperLimit: 85, hysteresis: 5,
            autoDischargeEnabled: base.autoDischargeEnabled, fan: base.fan
        )
        try store.save(rebuilt)
        check(store.load()?.fan == base.fan, "风扇透传-4", "setLimits 重建形态（active+显式拷贝+fan 透传）往返保真")
    }
    // 风扇透传-5：disable 重建形态（mode=disabled + 其余字段拷贝）往返保真。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-fan-f1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PolicyStore(url: directory.appendingPathComponent("policy.json"))
        let base = DaemonPolicy(
            mode: "active", upperLimit: 80, hysteresis: 2,
            autoDischargeEnabled: true,
            fan: fanPolicy(enabled: true, strategy: .twoStage, speed: 65, stage2: 85, stage2Rise: 400)
        )
        let rebuilt = DaemonPolicy(
            mode: "disabled", upperLimit: base.upperLimit, hysteresis: base.hysteresis,
            autoDischargeEnabled: base.autoDischargeEnabled, fan: base.fan
        )
        try store.save(rebuilt)
        check(store.load()?.fan == base.fan && store.load()?.mode == "disabled",
              "风扇透传-5", "disable 重建形态（disabled+拷贝+fan 透传）往返保真")
    }
    // 风扇透传-6：enable 重建形态（active 重建）往返保真——与 setLimits 形态同构
    // 但独立断言（三处重建点逐点钉死，防修一处漏两处）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-fan-f1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PolicyStore(url: directory.appendingPathComponent("policy.json"))
        let base = DaemonPolicy(
            mode: "disabled", upperLimit: 70, hysteresis: 1,
            autoDischargeEnabled: nil,
            fan: fanPolicy(enabled: false, strategy: .constantSpeed, thresholdCentiC: 5000)
        )
        let rebuilt = DaemonPolicy(
            mode: "active", upperLimit: base.upperLimit, hysteresis: base.hysteresis,
            autoDischargeEnabled: base.autoDischargeEnabled, fan: base.fan
        )
        try store.save(rebuilt)
        check(store.load()?.fan == base.fan, "风扇透传-6", "enable 重建形态（active 重建 + fan 透传）往返保真")
    }
    // 风扇透传-7：fan == nil 显式透传形态（重建点携带 nil 不误造默认开）→ 往返仍 nil。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-fan-f1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PolicyStore(url: directory.appendingPathComponent("policy.json"))
        let rebuilt = DaemonPolicy(
            mode: "active", upperLimit: 80, hysteresis: 2,
            autoDischargeEnabled: false, fan: nil
        )
        try store.save(rebuilt)
        check(store.load()?.fan == nil, "风扇透传-7", "fan==nil 显式透传 → 往返仍 nil（重建不误造默认）")
    }
    // 风扇透传-8：F-1 镜像条款——fan 与 autoDischargeEnabled 同時在场互不覆盖（R1 P0-2 同型事故回归）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-fan-f1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PolicyStore(url: directory.appendingPathComponent("policy.json"))
        let original = DaemonPolicy(
            mode: "active", upperLimit: 80, hysteresis: 2,
            autoDischargeEnabled: false,
            fan: fanPolicy(enabled: true, strategy: .constantSpeed, speed: 70)
        )
        try store.save(original)
        let loaded = store.load()
        check(loaded?.fan?.speedPercent == 70 && loaded?.autoDischargeEnabled == false,
              "风扇透传-8", "fan 与自动放电开关并存互不覆盖（F-1 姊妹条款）")
    }
}

// MARK: - ③ FanGuard 矩阵（方案 §5.1 求值序 A→B→F→C'→C→G→D→E→S；38 场景）
private func runFanGuardScenarios() {
    // ===== A 行：!enabled ∨ !modeActive（交还路径）=====
    // 风扇矩阵-1：开关关闭 ∧ 静息 → idle(.off)。
    do {
        let p = fanPolicy(enabled: false)
        check(decide(temperatureC: 40, policy: p) == .idle(stateWord: .off),
              "风扇矩阵-1", "A：!enabled ∧ 静息 → idle(已关闭)——t≥阈值也不进入")
    }
    // 风扇矩阵-2：开关关闭 ∧ boostActive → release(.off)。
    do {
        let p = fanPolicy(enabled: false)
        check(decide(temperatureC: 40, policy: p, boostActive: true) == .release(stateWord: .off),
              "风扇矩阵-2", "A：!enabled ∧ boost → release(已关闭)——关闭即交还")
    }
    // 风扇矩阵-3：daemon 停用（modeActive=false）∧ 静息 → idle(.off)。
    do {
        let p = fanPolicy(enabled: true)
        check(decide(temperatureC: 40, policy: p, modeActive: false) == .idle(stateWord: .off),
              "风扇矩阵-3", "A：!modeActive ∧ 静息 → idle(已关闭)——停用不介入")
    }
    // 风扇矩阵-4：daemon 停用 ∧ boostActive → release(.off)。
    do {
        let p = fanPolicy(enabled: true)
        check(decide(temperatureC: 40, policy: p, modeActive: false, boostActive: true) == .release(stateWord: .off),
              "风扇矩阵-4", "A：!modeActive ∧ boost → release——停用交还路径")
    }
    // 风扇矩阵-5：A 压过一切——关 ∧(unavailable+facts=nil+采样败+热)∧ boost → release。
    do {
        let p = fanPolicy(enabled: false)
        let hostile = decide(
            temperatureC: 45, policy: p,
            capability: .unavailable, boostActive: true, boostTicks: 99,
            facts: nil, sampleHealthy: false
        )
        check(hostile == .release(stateWord: .off),
              "风扇矩阵-5", "A 压过一切：!enabled 下 B/F/C' 全部让位 → release(已关闭)（一票否决）")
    }
    // ===== B 行：capability == .unavailable =====
    // 风扇矩阵-6：不可用 ∧ 静息 → idle(.unsupported)。
    do {
        check(decide(temperatureC: 20, policy: fanPolicy(), capability: .unavailable) == .idle(stateWord: .unsupported),
              "风扇矩阵-6", "B：unavailable ∧ 静息 → idle(本机不支持)——补格不进入")
    }
    // 风扇矩阵-7：不可用 ∧ boostActive → release(.unsupported)。
    do {
        check(decide(temperatureC: 20, policy: fanPolicy(), capability: .unavailable, boostActive: true) == .release(stateWord: .unsupported),
              "风扇矩阵-7", "B：unavailable ∧ boost → release(本机不支持)——不盲维持")
    }
    // 风扇矩阵-8：B 压过 C——unavailable ∧ t ≥ 阈值 → 不进入。
    do {
        check(decide(temperatureC: 37.5, policy: fanPolicy(), capability: .unavailable) == .idle(stateWord: .unsupported),
              "风扇矩阵-8", "B 压过 C：不可用 ∧ 热 → idle(本机不支持)（不进入 boost）")
    }
    // 风扇矩阵-9：B 压过 F——unavailable ∧ !sampleHealthy → B 先命中。
    do {
        check(decide(temperatureC: 37.5, policy: fanPolicy(), capability: .unavailable, sampleHealthy: false) == .idle(stateWord: .unsupported),
              "风扇矩阵-9", "B 压过 F：不可用 ∧ 采样败 → idle(本机不支持)（求值序 B 先于 F）")
    }
    // ===== F 行：!sampleHealthy =====
    // 风扇矩阵-10：采样异常 ∧ 静息 → idle(.degraded)（不进入）。
    do {
        check(decide(temperatureC: 37.5, policy: fanPolicy(), sampleHealthy: false) == .idle(stateWord: .degraded),
              "风扇矩阵-10", "F：采样异常 ∧ 静息 → idle(已暂停介入-采样异常)（不进入）")
    }
    // 风扇矩阵-11：采样异常 ∧ boostActive → release(.degraded)。
    do {
        check(decide(temperatureC: 37.5, policy: fanPolicy(), boostActive: true, sampleHealthy: false) == .release(stateWord: .degraded),
              "风扇矩阵-11", "F：采样异常 ∧ boost → release(已暂停介入)——采样失败即交还")
    }
    // 风扇矩阵-12：F 压过 D——异常 ∧ boost ∧ 带内 → release（不被 hold 吞掉，R1 P1-1c）。
    do {
        check(decide(temperatureC: 40, policy: fanPolicy(), boostActive: true, sampleHealthy: false) == .release(stateWord: .degraded),
              "风扇矩阵-12", "F 压过 D：异常 ∧ boost ∧ t=40（带内）→ release 而非 hold")
    }
    // 风扇矩阵-13：F 压过 C——异常 ∧ 热 ∧ 静息 → idle 不进入。
    do {
        check(decide(temperatureC: 45, policy: fanPolicy(), sampleHealthy: false) == .idle(stateWord: .degraded),
              "风扇矩阵-13", "F 压过 C：异常 ∧ 热 → idle（不进入 boost）")
    }
    // ===== C' 行：facts == nil =====
    // 风扇矩阵-14：facts 未探测 ∧ 静息 → idle(.probing)（探测中）。
    do {
        check(decide(temperatureC: 20, policy: fanPolicy(), facts: nil) == .idle(stateWord: .probing),
              "风扇矩阵-14", "C'：facts=nil ∧ 静息 → idle(探测中)——非 boost 期每 tick 重探")
    }
    // 风扇矩阵-15：facts 失效 ∧ boostActive → release(.probing)（不变量防御路径）。
    do {
        check(decide(temperatureC: 40, policy: fanPolicy(), boostActive: true, facts: nil) == .release(stateWord: .probing),
              "风扇矩阵-15", "C'：facts=nil ∧ boost → release(探测中)——boost 期 facts 失效不盲维持")
    }
    // 风扇矩阵-16：C' 压过 C——facts=nil ∧ 热 → idle(.probing) 不进入。
    do {
        check(decide(temperatureC: 37.5, policy: fanPolicy(), facts: nil) == .idle(stateWord: .probing),
              "风扇矩阵-16", "C' 压过 C：facts=nil ∧ 热 → idle(探测中)（成功重探后下 tick 进入）")
    }
    // ===== C 行：进入 boost =====
    // 风扇矩阵-17：进入 boost——t ≥ 阈值 → enterBoost(50%×4000=2000)。
    do {
        check(decide(temperatureC: 37.5, policy: fanPolicy()) == .enterBoost(targetRPM: 2000),
              "风扇矩阵-17", "C：t=37.5 ≥ 37.0 → enterBoost(2000rpm=50%×F0Mx 精确)（clamp 内直通）")
    }
    // 风扇矩阵-18：阈值含入侧边界 t == 37.0 → enterBoost。
    do {
        check(decide(temperatureC: 37.0, policy: fanPolicy()) == .enterBoost(targetRPM: 2000),
              "风扇矩阵-18", "C 边界：t == 阈值（含入侧）→ enterBoost")
    }
    // 风扇矩阵-19：clamp 下界——计算值低于 F0Mn → target == F0Mn。
    do {
        // 50%×4000=2000 < Mn=3500（合法 facts：Mn ≤ Mx，daemon 探测同约束）→ clamp 3500。
        check(decide(temperatureC: 38, policy: fanPolicy(), facts: fanFacts(min: 3500)) == .enterBoost(targetRPM: 3500),
              "风扇矩阵-19", "clamp 下界：target 2000 < Mn 3500 → 3500（F0Mn 只读下界）")
    }
    // 风扇矩阵-20：clamp 上界——emergency → F0Mx 直通。
    do {
        check(decide(temperatureC: 38, policy: fanPolicy(strategy: .emergency, speed: 50)) == .enterBoost(targetRPM: 4000),
              "风扇矩阵-20", "clamp 上界：emergency → 4000（=F0Mx 上限）")
    }
    // 风扇矩阵-21：emergency 无视 speed 参数。
    do {
        check(decide(temperatureC: 38, policy: fanPolicy(strategy: .emergency, speed: 40)) == .enterBoost(targetRPM: 4000),
              "风扇矩阵-21", "emergency ∧ speed 40% → 仍为 F0Mx（全速语义不随倍率缩放）")
    }
    // 风扇矩阵-22：阈值下沿 t == 36.99 → 落 S 静息（不进入）。
    do {
        check(decide(temperatureC: 36.99, policy: fanPolicy()) == .idle(stateWord: .automatic),
              "风扇矩阵-22", "C 下沿：t=36.99 < 37.0 → 不进入，落 S 静息(自动)")
    }
    // 风扇矩阵-23：twoStage 进入——stage1 = speed%×F0Mx。
    do {
        check(decide(temperatureC: 37.5, policy: fanPolicy(strategy: .twoStage)) == .enterBoost(targetRPM: 2000),
              "风扇矩阵-23", "twoStage 进入：t=37.5（未跨升档线）→ stage1=2000（50%）")
    }
    // 风扇矩阵-24：twoStage 升档写——boost ∧ t ≥ 阈值+rise → rewrite(stage2 3200)。
    do {
        check(decide(temperatureC: 40.0, policy: fanPolicy(strategy: .twoStage), boostActive: true) == .rewrite(targetRPM: 3200),
              "风扇矩阵-24", "D 例外①：twoStage 升档跨越 t=40.0 → rewrite(3200=80%×F0Mx)——带内写例外")
    }
    // 风扇矩阵-25：twoStage 升档边界 t == 阈值+rise（含入侧）→ rewrite。
    do {
        check(decide(temperatureC: 40.0, policy: fanPolicy(strategy: .twoStage, stage2Rise: 300), boostActive: true) == .rewrite(targetRPM: 3200),
              "风扇矩阵-25", "D 例外① 边界：t == 40.0（含入侧）→ rewrite(stage2)")
    }
    // ===== G 行：观察窗到期 =====
    // 风扇矩阵-26：unverified ∧ boostTicks ≥ 10 → hold（推进副作用在 daemon 侧，R1 P3-4）。
    do {
        check(decide(temperatureC: 40, policy: fanPolicy(), capability: .unverified, boostActive: true, boostTicks: 10) == .hold,
              "风扇矩阵-26", "G：unverified ∧ tick=10 → hold（观察窗到期触发 5.2 推进）")
    }
    // 风扇矩阵-27：G 先于 E——unverified ∧ tick=10 ∧ t 已出带外 → 仍 hold（推进副
    // 作用同 tick 收口——温度不参与到期判定）。
    do {
        check(decide(temperatureC: 30, policy: fanPolicy(), capability: .unverified, boostActive: true, boostTicks: 10) == .hold,
              "风扇矩阵-27", "G 先于 E：tick=10 ∧ t=30（出带外）→ hold（观察窗 semantics 优先，E 后置）")
    }
    // ===== D 行：带内驻留 =====
    // 风扇矩阵-28：boost ∧ 带内（35.0 ≤ t < 37.0）→ hold。
    do {
        check(decide(temperatureC: 36.0, policy: fanPolicy(), boostActive: true) == .hold,
              "风扇矩阵-28", "D：boost ∧ t=36.0（滞回带内）→ hold（带内不写）")
    }
    // 风扇矩阵-29：滞回下边界 t == 阈值−滞回（含入侧）→ hold。
    do {
        check(decide(temperatureC: 35.0, policy: fanPolicy(), boostActive: true) == .hold,
              "风扇矩阵-29", "D 边界：t == 35.0（阈值−滞回，含入侧）→ hold")
    }
    // 风扇矩阵-30：滞回下边沿之下 t == 34.99 → E release。
    do {
        check(decide(temperatureC: 34.99, policy: fanPolicy(), boostActive: true) == .release(stateWord: .automatic),
              "风扇矩阵-30", "E 边界：t == 34.99（阈值−滞回−0.01）→ release(自动)")
    }
    // 风扇矩阵-31：boost ∧ 热态（t ≥ 阈值）∧ 恒速 → hold（不重写——带内不写）。
    do {
        check(decide(temperatureC: 38.0, policy: fanPolicy(), boostActive: true) == .hold,
              "风扇矩阵-31", "D：boost ∧ t=38.0（≥ 阈值热态）→ hold（恒速不重写）")
    }
    // 风扇矩阵-32：twoStage 降档不写——boost ∧ t 回落 [threshold−hys, threshold+rise)
    // → hold（现值维持直到 release，R1 P3-4）。
    do {
        check(decide(temperatureC: 38.0, policy: fanPolicy(strategy: .twoStage), boostActive: true) == .hold,
              "风扇矩阵-32", "twoStage 降档不写：t=38.0 已出升档线 → hold（不 rewrite 回 stage1）")
    }
    // 风扇矩阵-33：D 带内 ∧ unverified ∧ tick=9（未到期）→ hold（G 未触发仍带内驻留）。
    do {
        check(decide(temperatureC: 36.0, policy: fanPolicy(), capability: .unverified, boostActive: true, boostTicks: 9) == .hold,
              "风扇矩阵-33", "D：unverified ∧ tick=9 ∧ 带内 → hold（观察窗未到期不特判）")
    }
    // ===== E/S 行 =====
    // 风扇矩阵-34：boost ∧ t 出带 → release(.automatic)（交还系统）。
    do {
        check(decide(temperatureC: 34.0, policy: fanPolicy(), boostActive: true) == .release(stateWord: .automatic),
              "风扇矩阵-34", "E：boost ∧ t=34.0 < 35.0 → release(自动)——Tg→原值 + Md=0 两侧效")
    }
    // 风扇矩阵-35：静息 ∧ t < 阈值 → idle(.automatic)（静息显式格，R1 P1-1b）。
    do {
        check(decide(temperatureC: 20, policy: fanPolicy()) == .idle(stateWord: .automatic),
              "风扇矩阵-35", "S：静息 ∧ t=20 < 阈值 → idle(自动)（最常见静息输入显式落格）")
    }
    // 风扇矩阵-36：S 最后序——静息 ∧ t < 阈值 ∧ unavailable → 落 B 非 S。
    do {
        check(decide(temperatureC: 20, policy: fanPolicy(), capability: .unavailable) == .idle(stateWord: .unsupported),
              "风扇矩阵-36", "S 最后序：unavailable 输入不落 S（B 先命中）——求值序钉死")
    }
    // ===== 其他 =====
    // 风扇矩阵-37：minRaise 拒绝——t ≥ 阈值 ∧ 静息 → idle(暂不支持该策略)（§0.5b）。
    do {
        check(decide(temperatureC: 37.5, policy: fanPolicy(strategy: .minRaise)) == .idle(stateWord: .strategyUnsupported),
              "风扇矩阵-37", "C 拦截：minRaise ∧ 热 → idle(暂不支持该策略)（v1.1 不进入）")
    }
    // 风扇矩阵-38：不变量防御穷举——boost 输入下 facts=nil / unavailable / !enabled /
    // !modeActive / !sampleHealthy 五种违规组合全部输出 release（不变量条款字面）。
    do {
        let p1 = fanPolicy(enabled: false)
        let p2 = fanPolicy(enabled: true)
        let cases: [FanDecision] = [
            decide(temperatureC: 40, policy: p1, boostActive: true),                                    // !enabled
            decide(temperatureC: 40, policy: p2, modeActive: false, boostActive: true),                 // !modeActive
            decide(temperatureC: 40, policy: p2, capability: .unavailable, boostActive: true),          // unavailable
            decide(temperatureC: 40, policy: p2, boostActive: true, facts: nil),                        // facts=nil
            decide(temperatureC: 40, policy: p2, boostActive: true, sampleHealthy: false),              // !sampleHealthy
        ]
        let allRelease = cases.allSatisfy { decision in
            if case .release = decision { return true }
            return false
        }
        check(allRelease, "风扇矩阵-38", "不变量防御：boostActive ⟹（enabled ∧ modeActive ∧ capability≠unavailable ∧ facts≠nil ∧ sampleHealthy）——五种违规输入全 release")
    }
    // 风扇矩阵-39（P1-1）：twoStage stage2 带内每 tick 决策去重——目标未变 →
    // hold 不写（消除「boost 期每 tick 常态写」的 §0.5c 违规形态）；仅目标变化
    // （跨线/配置变更重算）那一 tick 才 rewrite。漂移计数配套修正：daemon
    // rewriteFanTargetLocked 成功路径不再清零 driftTicks（漂移清零只由 tick
    // step4 干净回读承担）——本场景的逻辑面（决策去重）+ daemon 侧修正共同保证
    // 「自家重写不湮灭外部写者的跨 tick 漂移累计（可推进到 ≥2 触发冲突）」。
    do {
        let p = fanPolicy(strategy: .twoStage)
        let band = 40.0   // t ≥ 阈值+rise（37.0+3.0）= 40.0，stage2 带内
        check(decide(temperatureC: band, policy: p, boostActive: true, currentTargetRPM: 3200) == .hold,
              "风扇矩阵-39", "D 例外① 去重：stage2 带内目标未变（3200==3200）→ hold 不写（每 tick 常态写消除）")
        check(decide(temperatureC: band, policy: p, boostActive: true, currentTargetRPM: 2000) == .rewrite(targetRPM: 3200),
              "风扇矩阵-39", "D 例外①：目标变化（2000→3200，跨线那 tick）→ rewrite 仅此一次")
        check(decide(temperatureC: 38.0, policy: p, boostActive: true, currentTargetRPM: 3200) == .hold,
              "风扇矩阵-39", "未跨升档线（t=38.0 带内）→ hold（既有带内不写不回归；P1-1 去重不改变 D 常规行）")
    }
}

// MARK: - ④ 能力推进（方案 §5.2；10 场景）
private func runFanCapabilityScenarios() {
    // 风扇能力-1：unverified + writeFollowed → verified（首个可信证据 tick 即推进）。
    check(FanGuard.capabilityAdvanced(current: .unverified, boostTicks: 0, writeFollowed: true) == .verified,
          "风扇能力-1", "unverified + 证据 → verified（路径 A：Ac ≥ 目标−300rpm）")
    // 风扇能力-2：unverified + 未到期 + 无证据 → 保持 unverified。
    check(FanGuard.capabilityAdvanced(current: .unverified, boostTicks: 9, writeFollowed: false) == .unverified,
          "风扇能力-2", "unverified + tick=9 + 无证据 → 保持（观察窗内持续观察）")
    // 风扇能力-3：观察窗到期（tick=10）无证据 → unavailable。
    check(FanGuard.capabilityAdvanced(current: .unverified, boostTicks: 10, writeFollowed: false) == .unavailable,
          "风扇能力-3", "观察窗到期（100s）无证据 → unavailable（保守 release + 状态行本机不支持）")
    // 风扇能力-4：到期 tick 证据到达 → verified（证据压过到期）。
    check(FanGuard.capabilityAdvanced(current: .unverified, boostTicks: 10, writeFollowed: true) == .verified,
          "风扇能力-4", "到期 tick 有证据 → verified（证据优先于到期）")
    // 风扇能力-5：verified + 无证据（sticky 不回落）。
    check(FanGuard.capabilityAdvanced(current: .verified, boostTicks: 99, writeFollowed: false) == .verified,
          "风扇能力-5", "verified + 后续无证据 → 仍 verified（sticky 不因单 tick 抖动回落）")
    // 风扇能力-6：verified + 证据 → verified。
    check(FanGuard.capabilityAdvanced(current: .verified, boostTicks: 0, writeFollowed: true) == .verified,
          "风扇能力-6", "verified + 证据 → verified（幂等）")
    // 风扇能力-7：unavailable + 证据 → unavailable（sticky）。
    check(FanGuard.capabilityAdvanced(current: .unavailable, boostTicks: 0, writeFollowed: true) == .unavailable,
          "风扇能力-7", "unavailable + 证据 → 仍 unavailable（sticky——不因单次证据复活）")
    // 风扇能力-8：unavailable + 无证据 → unavailable。
    check(FanGuard.capabilityAdvanced(current: .unavailable, boostTicks: 10, writeFollowed: false) == .unavailable,
          "风扇能力-8", "unavailable + 无证据 → unavailable（幂等）")
    // 风扇能力-9：常量钉死——观察窗 10 tick / 写跟随地板 300rpm / 采样失败上限 3。
    check(FanGuard.capabilityObservationTicks == 10
            && FanGuard.writeFollowFloorRPM == 300
            && FanGuard.sampleFailureLimit == 3
            && FanGuard.conflictDriftTicks == 2,
          "风扇能力-9", "常量定版：观察窗 10 tick（100s）/ 跟随地板 300rpm / 采样失败 3 / 冲突漂移 2")
    // 风扇能力-10：开关翻转重置判定（resetRequired）——仅关→开触发（含 nil 旧值形态）。
    do {
        let first = FanGuard.resetRequired(old: nil, new: fanPolicy(enabled: true))
        let neverOn = FanGuard.resetRequired(old: nil, new: fanPolicy(enabled: false))
        let offOn = FanGuard.resetRequired(old: fanPolicy(enabled: false), new: fanPolicy(enabled: true))
        let stayOn = FanGuard.resetRequired(old: fanPolicy(enabled: true), new: fanPolicy(enabled: true))
        let onOff = FanGuard.resetRequired(old: fanPolicy(enabled: true), new: fanPolicy(enabled: false))
        check(first && !neverOn && offOn && !stayOn && !onOff,
              "风扇能力-10", "resetRequired 矩阵：nil→开 重置 / 关→开 重置 / 其余不重置（§5.2 仅关→开）")
    }
}

// MARK: - ⑤ validFan* 线格式值域（方案 §8；8 场景）
private func runFanWireValidationScenarios() {
    // 风扇线-1：fanEnabled 0/1 合法，其余拒绝。
    check(FanWireKeys.validEnabled(0) && FanWireKeys.validEnabled(1)
            && !FanWireKeys.validEnabled(2) && !FanWireKeys.validEnabled(99),
          "风扇线-1", "fanEnabled 值域 0/1（其余拒绝——UINT64 全值域防呆）")
    // 风扇线-2：fanStrategy 0-3 合法，4+ 拒绝（映射只追加不重排）。
    check([0, 1, 2, 3].allSatisfy(FanWireKeys.validStrategy)
            && !FanWireKeys.validStrategy(4) && !FanWireKeys.validStrategy(0xFFFFFFFF),
          "风扇线-2", "fanStrategy 0-3 合法（0=恒速 1=抬升 2=两级 3=应急）；4/全 1 拒绝")
    // 风扇线-3：fanThreshold 3000...5500。
    check(!FanWireKeys.validThreshold(2999) && FanWireKeys.validThreshold(3000)
            && FanWireKeys.validThreshold(5500) && !FanWireKeys.validThreshold(5501),
          "风扇线-3", "fanThreshold 值域 3000..5500（厘摄氏度）")
    // 风扇线-4：fanHysteresis 100...500。
    check(!FanWireKeys.validHysteresis(99) && FanWireKeys.validHysteresis(100)
            && FanWireKeys.validHysteresis(500) && !FanWireKeys.validHysteresis(501),
          "风扇线-4", "fanHysteresis 值域 100..500（厘摄氏度）")
    // 风扇线-5：fanSpeed 40...100。
    check(!FanWireKeys.validSpeed(39) && FanWireKeys.validSpeed(40)
            && FanWireKeys.validSpeed(100) && !FanWireKeys.validSpeed(101),
          "风扇线-5", "fanSpeed 值域 40..100（百分数）")
    // 风扇线-6：fanStage2 60...100。
    check(!FanWireKeys.validStage2(59) && FanWireKeys.validStage2(60)
            && FanWireKeys.validStage2(100) && !FanWireKeys.validStage2(101),
          "风扇线-6", "fanStage2 值域 60..100（百分数）")
    // 风扇线-7：fanStage2Rise 100...500。
    check(!FanWireKeys.validStage2Rise(99) && FanWireKeys.validStage2Rise(100)
            && FanWireKeys.validStage2Rise(500) && !FanWireKeys.validStage2Rise(501),
          "风扇线-7", "fanStage2Rise 值域 100..500（厘摄氏度）")
    // 风扇线-8：validFan* 与 validated 同源抽查（XPCServer 臂拒绝 == 持久化回流拒绝）
    // + FanWire 缺席保持合并（base 字段原样保留——方案 §8「缺席 = 保持现值」）。
    do {
        let thresholdOK = FanWireKeys.validThreshold(3000)
            && FanPolicy.validated(
                enabled: true, strategy: .constantSpeed, thresholdCentiC: 3000,
                releaseHysteresisCentiC: 200, speedPercent: 60, stage2Percent: 90, stage2RiseCentiC: 300
            ) != nil
        let speedBad = !FanWireKeys.validSpeed(101)
            && FanPolicy.validated(
                enabled: true, strategy: .constantSpeed, thresholdCentiC: 3700,
                releaseHysteresisCentiC: 200, speedPercent: 101, stage2Percent: 90, stage2RiseCentiC: 300
            ) == nil
        let base = fanPolicy()
        let merged = FanWire(threshold: 4500).mergedPolicy(base: base)
        let absentPreservation = merged != nil
            && merged?.thresholdCentiC == 4500
            && merged?.speedPercent == base.speedPercent
            && merged?.strategy == base.strategy
            && merged?.enabled == base.enabled
        check(thresholdOK && speedBad && absentPreservation,
              "风扇线-8", "validFan* 与 validated 同源（3000 双过 / 101 双拒）+ FanWire 缺席保持合并（只改阈值，其余原样）")
    }
    // 风扇线-9：minRaise 线格式可达（映射 1 → .minRaise——拒绝发生在 daemon setFanConfig
    // 层，fail-visible 原文「该策略在当前版本暂未开放」+ 类型混淆整包拒绝
    // （validateRequest 层：fanEnabled 以 STRING 混入 → 整包 nil，不崩溃）+
    // 非 setFan 命令全键缺席 → fan == nil（既有命令兼容）。
    do {
        let minRaiseMapped = FanWire.strategy(fromWire: 1) == .minRaise
            && FanWire.wireValue(.minRaise) == 1
        let mixed = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(mixed, DaemonXPC.cmdKey, "setFan")
        xpc_dictionary_set_uint64(mixed, DaemonXPC.upperKey, 80)
        xpc_dictionary_set_uint64(mixed, DaemonXPC.hysteresisKey, 2)
        xpc_dictionary_set_string(mixed, FanWireKeys.enabled, "1")   // STRING 混入 UINT64 键
        let mixedRejected = DaemonXPC.validateRequest(mixed) == nil
        let plain = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(plain, DaemonXPC.cmdKey, "setLimits")
        xpc_dictionary_set_uint64(plain, DaemonXPC.upperKey, 80)
        xpc_dictionary_set_uint64(plain, DaemonXPC.hysteresisKey, 2)
        let plainOK = DaemonXPC.validateRequest(plain)
        check(minRaiseMapped && mixedRejected && plainOK?.fan == nil && plainOK?.cmd == "setLimits",
              "风扇线-9", "minRaise 映射可达（拒绝在 daemon 层）+ STRING 混入整包拒绝 + 非 setFan 全键缺席兼容")
    }
    // 风扇线-10（P1-2）：键域错误分流——keyNotFound/invalidKey 是机型事实，不进
    // 共享传输失败计数（防键缺席机型周期性拆除充电后端）；仅传输类故障走共享
    // 自愈。与 daemon 探针/回读 catch 同一把尺（isKeyDomainError 同源）。
    do {
        let keyNotFound = FanGuard.isKeyDomainError(SMCError.keyNotFound("F0Mn"))
        let invalidKey = FanGuard.isKeyDomainError(SMCError.invalidKey("F0X"))
        let transport = FanGuard.isKeyDomainError(SMCError.transportFailure(kr: Int32(bitPattern: 0xE00002C7)))
        let service = FanGuard.isKeyDomainError(SMCError.serviceNotFound)
        let unexpected = FanGuard.isKeyDomainError(SMCError.unexpectedResult(key: "F0Ac", command: 5, result: 137))
        let notSMC = FanGuard.isKeyDomainError(BackendError.noBackendAvailable)
        check(keyNotFound && invalidKey && !transport && !service && !unexpected && !notSMC,
              "风扇线-10", "键域分流：keyNotFound/invalidKey → 纯键域（不进共享计数）；传输/服务/结果类与后端错误 → 共享通道")
    }
}

// MARK: - ⑤b FanSMC LE 编解码向量 + 锁存阶梯常量（方案 §2.4 条 1 U7 定版；2 场景）

private func runFanSMCCodecScenarios() {
    // 风扇码-1：已知向量 1350.0 ↔ 00C0A844（spike E0 双序对照样本：F0Mn=
    // 00C0A844 → LE 1350.0）——编码/解码双向钉死字节序；BE 反例（44A8C000 按
    // LE 解 ≠ 1350——防回退 BE 的回归防护）；roundtrip 3350；形状不符 → nil。
    do {
        let encoded = FanSMC.encodeRPM(1350)
        check(encoded == [0x00, 0xC0, 0xA8, 0x44], "风扇码-1", "encodeRPM(1350) == 00C0A844（LE 已知向量）")
        check(FanSMC.decodeRPM([0x00, 0xC0, 0xA8, 0x44]) == 1350, "风扇码-1", "decodeRPM(00C0A844) == 1350.0（双向）")
        check(FanSMC.decodeRPM([0x44, 0xA8, 0xC0, 0x00]) != 1350
                && FanSMC.decodeRPM([0x44, 0xA8, 0xC0, 0x00]) == Float(bitPattern: 0x00C0A844),
              "风扇码-1", "BE 字节序反例：44A8C000 按 LE 解 ≠ 1350（= 0x00C0A844 位型——字节序回归防护）")
        check(FanSMC.decodeRPM(FanSMC.encodeRPM(3350)) == 3350, "风扇码-1", "roundtrip 3350 无损")
        check(FanSMC.decodeRPM([0x00, 0xC0, 0xA8]) == nil && FanSMC.decodeRPM([]) == nil,
              "风扇码-1", "形状不符（非 4B）→ nil（调用方按格式不符 fail-visible，不做值格式猜测）")
    }
    // 风扇码-2（0.5.1-alpha 热修）：锁存重试阶梯常量语义——非空 / 首档 ≥ 100ms
    // / 严格单调递增（阶梯绝不回退）。真机验证路径：2026-09-04 探针实测 F0Md
    // 写后 T+10ms 回读仍旧值、T+100ms 锁存（≤100ms 量级锁存延迟）——首档必须
    // ≥ 100ms；实际时序在部署后经 daemon verifyFanKey 写路径真机承担，此处仅
    // 钉死常量语义（IO 时序不做纯函数模拟）。
    do {
        let ladder = FanSMC.verifyLadderMs
        check(!ladder.isEmpty && zip(ladder, ladder.dropFirst()).allSatisfy { $0 < $1 },
              "风扇码-2", "verifyLadderMs 非空且严格单调递增（阶梯绝不回退）")
        check(ladder.count == 3 && ladder[0] >= 100,
              "风扇码-2", "verifyLadderMs 三档且首档 ≥ 100ms（锁存延迟实测下限，探针 2026-09-04）")
    }
}

// MARK: - ⑥ DaemonStatus 兼容（方案 §8；3 场景）
private func runFanStatusCompatibilityScenarios() throws {
    // 风扇状态-1：旧 daemon 回包 JSON 无 fan 键 → fan == nil（decodeIfPresent 兼容）。
    do {
        let oldJSON = #"{"version":"0.4.0-alpha","mode":"active","upperLimit":80,"hysteresis":2,"timestamp":700000000.0}"#
        let decoded = try JSONDecoder().decode(DaemonStatus.self, from: Data(oldJSON.utf8))
        check(decoded.fan == nil && decoded.upperLimit == 80,
              "风扇状态-1", "旧 JSON 无 fan 键 → nil（App 提示升级路径的判定依据）")
    }
    // 风扇状态-2：fan 字段 roundtrip 保真（含 boost 载荷形态）。
    do {
        let status = DaemonStatus(
            version: "0.5.0-alpha", mode: "active", upperLimit: 80, hysteresis: 2,
            lastAction: "enforce:noop", lastPercent: 60,
            lastExternalConnected: true, lastChargingEnabled: false
        )
        var statusWithFan = status
        statusWithFan.fan = FanStatus(
            enabled: true, strategy: .twoStage, state: .boost,
            targetRPM: 3200, currentRPM: 3185, thresholdCentiC: 3700, conflictFlag: false
        )
        let data = try JSONEncoder().encode(statusWithFan)
        let decoded = try JSONDecoder().decode(DaemonStatus.self, from: data)
        check(decoded.fan == statusWithFan.fan, "风扇状态-2", "fan roundtrip 保真（boost 态全字段）")
    }
    // 风扇状态-3：fan 显式 null（JSON "fan": null）→ nil。
    do {
        let json = #"{"version":"0.5.0-alpha","mode":"active","upperLimit":80,"hysteresis":2,"fan":null,"timestamp":700000000.0}"#
        let decoded = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
        check(decoded.fan == nil, "风扇状态-3", "fan 显式 null → nil（可选字段编码语义）")
    }
}