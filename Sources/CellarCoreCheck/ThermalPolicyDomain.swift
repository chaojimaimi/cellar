// CellarCoreCheck —— Phase 5 v1.5 充电热阈值可配置化场景域（方案 §2.4 清单 +
// §7-M2 防呆：validated 边界 / default 与常量等价 / guarded 参数化矩阵 / resume
// 派生 / wire 编解码 / mergedPolicy / F-1 五触点分层 / DaemonStatus 兼容 /
// keepAlive 三分支 × 两调用点语境 / R-2 降级机型提前 advance·提前 done 边界 /
// 校准滞留→恢复完成 + 超时中止 → ThermalKeepAliveDomain.swift；doctor thermalConfig
// 组装 → ThermalDoctorDomain.swift——同域拆分，FanDomain/FanDoctorDomain 先例）
//
// ⚠️ 既有 ThermalGuardDomain 热守卫-1…17 场景零改动全绿是验收项（UD-4：默认
// 参数路径与常量逐 case 等价——被牵动即实现走样）。

import CellarCore
import Foundation

/// 热策略场景域入口（Main.main 调用；断言经 MainEntry.swift 的 internal 助手）。
func runThermalPolicyDomainScenarios() throws {
    try runThermalPolicyValidationScenarios()
    try runThermalGuardParameterizedScenarios()
    try runThermalFOneScenarios()
    try runThermalWireScenarios()
    try runThermalStatusCompatibilityScenarios()
}

// MARK: - 场景域内助手（本文件私有；与 MainEntry 的 check/expectEqual 共用）

/// fixture 解包错误（本工具无 XCTest——validated/构造失败 = 测试栈错误上抛不吞，
/// 照 ThermalGuardDomain 的 LimitPolicy 构造分层）。
private enum FixtureError: Error { case invalid }

private func validatedThermal(pauseCentiC: Int, hysteresisCentiC: Int) throws -> ThermalPolicy {
    guard let policy = ThermalPolicy.validated(pauseCentiC: pauseCentiC, hysteresisCentiC: hysteresisCentiC) else {
        throw FixtureError.invalid
    }
    return policy
}

private func validatedFan(
    enabled: Bool, strategy: FanStrategy, thresholdCentiC: Int,
    releaseHysteresisCentiC: Int, speedPercent: Int, stage2Percent: Int, stage2RiseCentiC: Int
) throws -> FanPolicy {
    guard let policy = FanPolicy.validated(
        enabled: enabled, strategy: strategy, thresholdCentiC: thresholdCentiC,
        releaseHysteresisCentiC: releaseHysteresisCentiC, speedPercent: speedPercent,
        stage2Percent: stage2Percent, stage2RiseCentiC: stage2RiseCentiC
    ) else {
        throw FixtureError.invalid
    }
    return policy
}

/// 临时目录 PolicyStore（daemon 为 executable 不可 import——逻辑层以
/// PolicyStore+临时目录模拟重建/回流形态，照 FanDomain F-1 先例）。
private func makeTempPolicyStore() throws -> (store: PolicyStore, url: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cellar-thermal-f1-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (PolicyStore(url: directory.appendingPathComponent("policy.json")), directory)
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - ① validated 边界 / default 等价 / resume 派生（方案 §2.4；4 场景）
private func runThermalPolicyValidationScenarios() throws {
    // 热策-1：默认值定版 + 与 ThermalGuard 常量逐位等价（UD-3 第①级——常量不删，
    // default 由常量派生；热守卫-13 不变式的策略面镜像）。
    do {
        let d = ThermalPolicy.default
        check(d.pauseCentiC == 4000 && d.hysteresisCentiC == 300,
              "热策-1", "默认值定版：4000/300（= 40.0°C 暂停 / 3.0°C 滞回，方案 §2.1）")
        check(Double(d.pauseCentiC) / 100 == ThermalGuard.pauseC,
              "热策-1", "default.pauseCentiC → 40.0 与 ThermalGuard.pauseC 逐位相等（同源钉死）")
        check((Double(d.pauseCentiC) - Double(d.hysteresisCentiC)) / 100 == ThermalGuard.resumeC,
              "热策-1", "default 派生恢复点 → 37.0 与 ThermalGuard.resumeC 逐位相等")
        check(ThermalPolicy.validated(
            pauseCentiC: d.pauseCentiC, hysteresisCentiC: d.hysteresisCentiC
        ) != nil, "热策-1", "默认值整体过 validated（非 nil）")
    }
    // 热策-2：暂停阈值边界——3499/4501 拒；3500/4500 过（35-45°C 钳制，R-1）。
    do {
        let below = ThermalPolicy.validated(pauseCentiC: 3499, hysteresisCentiC: 300)
        let above = ThermalPolicy.validated(pauseCentiC: 4501, hysteresisCentiC: 300)
        let lowEdge = ThermalPolicy.validated(pauseCentiC: 3500, hysteresisCentiC: 300)
        let highEdge = ThermalPolicy.validated(pauseCentiC: 4500, hysteresisCentiC: 300)
        check(below == nil && above == nil && lowEdge != nil && highEdge != nil,
              "热策-2", "pause 边界：3499/4501 → nil，3500/4500 → 合法（保护不可被误配关闭）")
    }
    // 热策-3：滞回边界——99/801 拒；100/800 过（1-8°C）。
    do {
        let below = ThermalPolicy.validated(pauseCentiC: 4000, hysteresisCentiC: 99)
        let above = ThermalPolicy.validated(pauseCentiC: 4000, hysteresisCentiC: 801)
        let lowEdge = ThermalPolicy.validated(pauseCentiC: 4000, hysteresisCentiC: 100)
        let highEdge = ThermalPolicy.validated(pauseCentiC: 4000, hysteresisCentiC: 800)
        check(below == nil && above == nil && lowEdge != nil && highEdge != nil,
              "热策-3", "hysteresis 边界：99/801 → nil，100/800 → 合法")
    }
    // 热策-4：resume 派生（pause − hysteresis，UD-2）+ Codable roundtrip 保真。
    do {
        check(ThermalPolicy.default.resumeCentiC == 3700,
              "热策-4", "default resume 派生：4000 − 300 = 3700（37.0°C）")
        let custom = try validatedThermal(pauseCentiC: 3800, hysteresisCentiC: 500)
        check(custom.resumeCentiC == 3300,
              "热策-4", "自定义 resume 派生：3800 − 500 = 3300（恢复点只展示不可调）")
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(ThermalPolicy.self, from: data)
        check(decoded == custom, "热策-4", "ThermalPolicy Codable roundtrip 保真")
    }
}

// MARK: - ② guarded 参数化矩阵抽查（方案 §2.4；3 场景）
private func runThermalGuardParameterizedScenarios() throws {
    // 守卫参-1：自定义阈值（3800/300 → 38.0/35.0）下六 case 重跑——case 2/5 阈值
    // 随 policy 平移、case 1 限充优先不变。
    do {
        let custom = try validatedThermal(pauseCentiC: 3800, hysteresisCentiC: 300)
        let charging = ChargingContext(percent: 60, externalConnected: true, chargingEnabled: true)
        let stopped = ChargingContext(percent: 60, externalConnected: true, chargingEnabled: false)
        let c2 = ThermalGuard.guarded(base: .noop, context: charging, temperatureC: 38.0, policy: custom)
        check(c2.action == .disableCharging && c2.tempPauseActive == true,
              "守卫参-1", "自定义 38.0：t=38.0（新含入侧）∧ 充电中 → case 2 热停写")
        let c6 = ThermalGuard.guarded(base: .noop, context: charging, temperatureC: 37.99, policy: custom)
        check(c6.action == .noop && c6.tempPauseActive == false,
              "守卫参-1", "自定义 38.0：t=37.99 < 新暂停点 → case 6 透传继续充")
        let c4 = ThermalGuard.guarded(base: .enableCharging, context: stopped, temperatureC: 36.0, policy: custom)
        check(c4.action == .noop && c4.tempPauseActive == true,
              "守卫参-1", "自定义 35.0 恢复点：t=36.0（滞回带内）→ case 4 驻留 noop")
        let c5 = ThermalGuard.guarded(base: .enableCharging, context: stopped, temperatureC: 34.99, policy: custom)
        check(c5.action == .enableCharging && c5.tempPauseActive == false,
              "守卫参-1", "自定义 35.0 恢复点：t=34.99 < 35.0 → case 5 恢复写")
    }
    // 守卫参-2：显式 .default 参数与缺省参数逐 case 等价（UD-4 零行为漂移直接面）。
    do {
        let charging = ChargingContext(percent: 60, externalConnected: true, chargingEnabled: true)
        let stopped = ChargingContext(percent: 60, externalConnected: true, chargingEnabled: false)
        let limit = try LimitPolicy(upperLimit: 80, hysteresis: 2)
        let limitCtx = ChargingContext(percent: 80, externalConnected: true, chargingEnabled: true)
        let base = limit.decide(context: limitCtx)
        let cases: [(ChargingAction, ChargingContext, Double)] = [
            (base, limitCtx, 42),        // case 1 限充透传
            (.noop, charging, 40.0),     // case 2 热停
            (.enableCharging, stopped, 40.5),  // case 3 驻留
            (.enableCharging, stopped, 38.5),  // case 4 滞回带
            (.enableCharging, stopped, 36.99), // case 5 恢复
            (.noop, stopped, 45),        // case 6 透传
        ]
        var allEqual = true
        for (b, ctx, t) in cases {
            let omitted = ThermalGuard.guarded(base: b, context: ctx, temperatureC: t)
            let explicit = ThermalGuard.guarded(base: b, context: ctx, temperatureC: t, policy: .default)
            if omitted != explicit { allEqual = false }
        }
        check(allEqual, "守卫参-2", "显式 .default 与缺省参数六 case 输出逐格相等（默认参数路径无漂移）")
    }
    // 守卫参-3：自定义 policy 下 case 1 限充优先仍最先命中（安全判定序零重排面）。
    do {
        let custom = try validatedThermal(pauseCentiC: 3500, hysteresisCentiC: 100)
        let limit = try LimitPolicy(upperLimit: 80, hysteresis: 2)
        let ctx = ChargingContext(percent: 80, externalConnected: true, chargingEnabled: true)
        let base = limit.decide(context: ctx)
        let guarded = ThermalGuard.guarded(base: base, context: ctx, temperatureC: 45, policy: custom)
        check(base == .disableCharging && guarded.action == .disableCharging && guarded.tempPauseActive == false,
              "守卫参-3", "percent==上限 ∧ 热 ∧ 自定义阈值 → case 1 仍优先透传不误标暂停")
    }
}

// MARK: - ③ F-1 五触点 + 仅丢字段分层（方案 §2.4；6 场景）
private func runThermalFOneScenarios() throws {
    // 热透传-1：load() 保真——带 thermal 的策略落盘再读回逐字段一致。
    do {
        let (store, dir) = try makeTempPolicyStore()
        defer { cleanup(dir) }
        let thermal = try validatedThermal(pauseCentiC: 4200, hysteresisCentiC: 800)
        try store.save(DaemonPolicy(
            mode: "active", upperLimit: 80, hysteresis: 2,
            autoDischargeEnabled: true, thermal: thermal
        ))
        let loaded = store.load()
        check(loaded?.thermal == thermal && loaded?.autoDischargeEnabled == true,
              "热透传-1", "load() 保真：thermal 逐字段一致 + 既有字段不覆盖")
    }
    // 热透传-2：旧 policy.json 无 thermal 键 → nil（decodeIfPresent 兼容）。
    do {
        let (store, dir) = try makeTempPolicyStore()
        defer { cleanup(dir) }
        try """
        {"mode":"active","upperLimit":75,"hysteresis":3}
        """.write(to: store.url, atomically: true, encoding: .utf8)
        let loaded = store.load()
        check(loaded?.thermal == nil && loaded?.upperLimit == 75,
              "热透传-2", "旧 JSON 无 thermal 键 → nil（daemon 恒走 default 40/37）")
    }
    // 热透传-3：thermal 值域非法（pauseCentiC 9999）→ **仅丢该字段**（UD-3 分层，
    // 勿照 fan 整包 nil）；mode/限值/fan 不受连累。
    do {
        let (store, dir) = try makeTempPolicyStore()
        defer { cleanup(dir) }
        let fan = try validatedFan(
            enabled: true, strategy: .constantSpeed, thresholdCentiC: 3700,
            releaseHysteresisCentiC: 200, speedPercent: 60, stage2Percent: 90, stage2RiseCentiC: 300
        )
        try store.save(DaemonPolicy(mode: "active", upperLimit: 80, hysteresis: 2, fan: fan))
        // 手工写非法 thermal（store.save 只收合法形态——回流污染场景）。
        try """
        {"mode":"active","upperLimit":80,"hysteresis":2,"fan":{"enabled":true,"strategy":"constantSpeed","thresholdCentiC":3700,"releaseHysteresisCentiC":200,"speedPercent":60,"stage2Percent":90,"stage2RiseCentiC":300},"thermal":{"pauseCentiC":9999,"hysteresisCentiC":300}}
        """.write(to: store.url, atomically: true, encoding: .utf8)
        let loaded = store.load()
        check(loaded != nil && loaded?.thermal == nil && loaded?.fan == fan && loaded?.upperLimit == 80,
              "热透传-3", "thermal 值域非法 → 仅丢字段（policy 整包存活、fan 保真、回落 default 40/37 保护仍在）")
    }
    // 热透传-4：fan 整包 nil 分层不受新字段影响——fan 非法 + thermal 合法 → 整包 nil。
    do {
        let (store, dir) = try makeTempPolicyStore()
        defer { cleanup(dir) }
        try """
        {"mode":"active","upperLimit":80,"hysteresis":2,"fan":{"enabled":true,"strategy":"constantSpeed","thresholdCentiC":9999,"releaseHysteresisCentiC":200,"speedPercent":60,"stage2Percent":90,"stage2RiseCentiC":300},"thermal":{"pauseCentiC":3800,"hysteresisCentiC":300}}
        """.write(to: store.url, atomically: true, encoding: .utf8)
        check(store.load() == nil,
              "热透传-4", "fan 非法回流仍整包 nil（与 thermal 仅丢字段分层并存、互不稀释）")
    }
    // 热透传-5/6/7：setLimits/disable/enable 三构造点重建形态（daemon 侧显式字段
    // 拷贝）往返保真——漏带 = persistPolicyLocked 覆写丢配置（F-1 强制条款）。
    do {
        let thermal = try validatedThermal(pauseCentiC: 3600, hysteresisCentiC: 200)
        // setLimits 形态：mode 固定 active + 显式字段拷贝。
        let (storeSet, dirSet) = try makeTempPolicyStore()
        defer { cleanup(dirSet) }
        let baseSet = DaemonPolicy(mode: "disabled", upperLimit: 85, hysteresis: 5, thermal: thermal)
        try storeSet.save(DaemonPolicy(
            mode: "active", upperLimit: 85, hysteresis: 5,
            autoDischargeEnabled: baseSet.autoDischargeEnabled,
            fan: baseSet.fan, calibrationSchedule: baseSet.calibrationSchedule,
            thermal: baseSet.thermal
        ))
        check(storeSet.load()?.thermal == thermal,
              "热透传-5", "setLimits 重建形态（active + thermal 透传）往返保真")
        // disable 形态：mode=disabled + 其余字段拷贝。
        let (storeDis, dirDis) = try makeTempPolicyStore()
        defer { cleanup(dirDis) }
        let baseDis = DaemonPolicy(mode: "active", upperLimit: 80, hysteresis: 2, thermal: thermal)
        try storeDis.save(DaemonPolicy(
            mode: "disabled", upperLimit: baseDis.upperLimit, hysteresis: baseDis.hysteresis,
            autoDischargeEnabled: baseDis.autoDischargeEnabled, fan: baseDis.fan,
            calibrationSchedule: baseDis.calibrationSchedule, thermal: baseDis.thermal
        ))
        check(storeDis.load()?.thermal == thermal && storeDis.load()?.mode == "disabled",
              "热透传-6", "disable 重建形态（disabled + thermal 透传）往返保真")
        // enable 形态 + thermal==nil 显式透传仍 nil（重建不误造默认）。
        let (storeEn, dirEn) = try makeTempPolicyStore()
        defer { cleanup(dirEn) }
        let baseEn = DaemonPolicy(mode: "disabled", upperLimit: 70, hysteresis: 1, thermal: thermal)
        try storeEn.save(DaemonPolicy(
            mode: "active", upperLimit: baseEn.upperLimit, hysteresis: baseEn.hysteresis,
            autoDischargeEnabled: baseEn.autoDischargeEnabled, fan: baseEn.fan,
            calibrationSchedule: baseEn.calibrationSchedule, thermal: baseEn.thermal
        ))
        check(storeEn.load()?.thermal == thermal,
              "热透传-7", "enable 重建形态（active + thermal 透传）往返保真")
        let (storeNil, dirNil) = try makeTempPolicyStore()
        defer { cleanup(dirNil) }
        try storeNil.save(DaemonPolicy(mode: "active", upperLimit: 80, hysteresis: 2, thermal: nil))
        check(storeNil.load()?.thermal == nil,
              "热透传-7", "thermal==nil 显式透传 → 往返仍 nil（不误造默认配置）")
    }
}

// MARK: - ④ wire 编解码 / validTherm* / DaemonStatus 兼容（方案 §2.4；4 场景）
private func runThermalWireScenarios() throws {
    // 热线-1：validTherm* 值域矩阵 + 与 validated 同源抽查（XPCServer 臂拒绝 ==
    // 持久化回流拒绝，同一区间常量）。
    do {
        let pauseOK = !ThermalWireKeys.validPause(3499) && ThermalWireKeys.validPause(3500)
            && ThermalWireKeys.validPause(4500) && !ThermalWireKeys.validPause(4501)
        let hysOK = !ThermalWireKeys.validHysteresis(99) && ThermalWireKeys.validHysteresis(100)
            && ThermalWireKeys.validHysteresis(800) && !ThermalWireKeys.validHysteresis(801)
        let sameSource = ThermalWireKeys.validPause(3800)
            && ThermalPolicy.validated(pauseCentiC: 3800, hysteresisCentiC: 300) != nil
        let rejectedBoth = !ThermalWireKeys.validPause(9999)
            && ThermalPolicy.validated(pauseCentiC: 9999, hysteresisCentiC: 300) == nil
        check(pauseOK && hysOK && sameSource && rejectedBoth,
              "热线-1", "validPause/validHysteresis 边界矩阵 + 与 validated 同源（3800 双过 / 9999 双拒）")
    }
    // 热线-2：mergedPolicy 缺席保持合并 + 全空 wire == base + 越界 → nil + 便捷构造。
    do {
        let base = try validatedThermal(pauseCentiC: 4000, hysteresisCentiC: 300)
        let merged = ThermalWire(pause: 3800).mergedPolicy(base: base)
        check(merged != nil && merged?.pauseCentiC == 3800 && merged?.hysteresisCentiC == base.hysteresisCentiC,
              "热线-2", "缺席保持：只改 pause，hysteresis 承 base")
        let empty = ThermalWire().mergedPolicy(base: base)
        check(empty == base, "热线-2", "全空 wire → 合并结果 == base（两键均缺席）")
        let invalid = ThermalWire(hysteresis: 900).mergedPolicy(base: base)
        check(invalid == nil, "热线-2", "合并后越界（hysteresis 900）→ validated 整包 nil")
        let convenience = ThermalWire(try validatedThermal(pauseCentiC: 4200, hysteresisCentiC: 800))
        check(convenience == ThermalWire(pause: 4200, hysteresis: 800),
              "热线-2", "便捷构造 init(_:) 全键展开（下发方不依赖缺席保持）")
    }
    // 热线-3：validateRequest 类型白名单——STRING 混入 thermPauseCentiC → 整包
    // 拒绝；两键 UINT64 → 提取；非 setThermal 命令两键缺席 → thermal nil 兼容。
    do {
        let mixed = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(mixed, DaemonXPC.cmdKey, ThermalWireKeys.command)
        xpc_dictionary_set_uint64(mixed, DaemonXPC.upperKey, 0)
        xpc_dictionary_set_uint64(mixed, DaemonXPC.hysteresisKey, 0)
        xpc_dictionary_set_string(mixed, ThermalWireKeys.pause, "3800")   // STRING 混入 UINT64 键
        check(DaemonXPC.validateRequest(mixed) == nil,
              "热线-3", "thermPauseCentiC 以 STRING 混入 → 整包拒绝（不崩溃）")
        let well = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(well, DaemonXPC.cmdKey, ThermalWireKeys.command)
        xpc_dictionary_set_uint64(well, DaemonXPC.upperKey, 0)
        xpc_dictionary_set_uint64(well, DaemonXPC.hysteresisKey, 0)
        xpc_dictionary_set_uint64(well, ThermalWireKeys.pause, 3800)
        xpc_dictionary_set_uint64(well, ThermalWireKeys.hysteresis, 500)
        let wellParsed = DaemonXPC.validateRequest(well)
        check(wellParsed?.thermal == ThermalWire(pause: 3800, hysteresis: 500),
              "热线-3", "两键 UINT64 → ThermalWire 提取（值域校验在 XPCServer 臂）")
        let plain = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(plain, DaemonXPC.cmdKey, "setLimits")
        xpc_dictionary_set_uint64(plain, DaemonXPC.upperKey, 80)
        xpc_dictionary_set_uint64(plain, DaemonXPC.hysteresisKey, 2)
        let plainOK = DaemonXPC.validateRequest(plain)
        check(plainOK?.thermal == nil && plainOK?.cmd == "setLimits",
              "热线-3", "非 setThermal 命令两键缺席 → thermal nil（既有命令兼容）")
    }
}

/// DaemonStatus 兼容 + doctor 组装（拆出保持各 run* 函数规模）。
private func runThermalStatusCompatibilityScenarios() throws {
    // 热状态-1：旧 daemon 回包 JSON 无 therm 两键 → nil（decodeIfPresent 兼容，
    // 旧客户端升级面判定依据）。
    do {
        let oldJSON = #"{"version":"0.9.0-alpha","mode":"active","upperLimit":80,"hysteresis":2,"timestamp":700000000.0}"#
        let decoded = try JSONDecoder().decode(DaemonStatus.self, from: Data(oldJSON.utf8))
        check(decoded.thermPauseCentiC == nil && decoded.thermHysteresisCentiC == nil,
              "热状态-1", "旧 JSON 无 therm 两键 → nil（App 据此提示升级，UD-7）")
    }
    // 热状态-2：新 daemon 恒填形态 roundtrip 保真 + 显式 null → nil。
    do {
        var status = DaemonStatus(version: "0.10.0-alpha", mode: "active", upperLimit: 80, hysteresis: 2)
        status.thermPauseCentiC = 3800
        status.thermHysteresisCentiC = 500
        let roundtrip = try JSONDecoder().decode(DaemonStatus.self, from: try JSONEncoder().encode(status))
        check(roundtrip.thermPauseCentiC == 3800 && roundtrip.thermHysteresisCentiC == 500,
              "热状态-2", "恒填两键 roundtrip 保真（buildStatusLocked 展开形态）")
        let nullJSON = #"{"version":"0.10.0-alpha","mode":"active","upperLimit":80,"hysteresis":2,"thermPauseCentiC":null,"thermHysteresisCentiC":null,"timestamp":700000000.0}"#
        let nulled = try JSONDecoder().decode(DaemonStatus.self, from: Data(nullJSON.utf8))
        check(nulled.thermPauseCentiC == nil && nulled.thermHysteresisCentiC == nil,
              "热状态-2", "显式 null → nil（可选字段编码语义）")
    }
}
