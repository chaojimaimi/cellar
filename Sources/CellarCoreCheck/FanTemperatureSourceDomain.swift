// CellarCoreCheck —— Phase 5 v1.11 M2 风扇双温度源场景域（方案 D-3a..D-3h）：
// FanPolicy 手写 Codable 兼容（R1 P0）/ validated 双域 / source round-trip / 未知
// source 解码炸 / FanGuard effective*（battery 零回归 + cpuSkin 新值 + targetRPM
// 双域档位）/ wire 值域与缺席保持 / FanStatus 兼容 / doctor 分支。
// 独立文件拆分（FanDoctorDomain 同款先例——FanDomain.swift 保持在 800 行硬上限内）。
import CellarCore
import Foundation

/// 温度源场景域入口（Main.main 调用；断言经 MainEntry.swift 的 internal 助手）。
func runFanTemperatureSourceDomainScenarios() throws {
    /// 测试策略构造（默认：开启/恒速/电池阈值 3700/滞回 200/转速 50%——battery 域
    /// 现状形态；cpuSkin 参数显式传参才落）。
    func policy(
        source: FanTemperatureSource = .battery,
        threshold: Int = 3700,
        hysteresis: Int = 200,
        cpuThreshold: Int = 5500,
        cpuHysteresis: Int = 400,
        strategy: FanStrategy = .constantSpeed
    ) -> FanPolicy {
        FanPolicy(
            enabled: true, strategy: strategy,
            thresholdCentiC: threshold, releaseHysteresisCentiC: hysteresis,
            speedPercent: 50, stage2Percent: 80, stage2RiseCentiC: 300,
            temperatureSource: source, cpuSkinThresholdCentiC: cpuThreshold,
            cpuSkinHysteresisCentiC: cpuHysteresis
        )
    }

    // ---- ① FanPolicy 手写 Codable（R1 P0 升级兼容）----

    // 风扇源-1（P0 钉死）：存量 policy.json 旧 7 字段 → 解码兼容 + 新字段落默认 +
    // 既有字段全保留（升级即静默重置的回归防护）。
    do {
        let json = "{\"enabled\":true,\"strategy\":\"twoStage\",\"thresholdCentiC\":4200," +
            "\"releaseHysteresisCentiC\":200,\"speedPercent\":70,\"stage2Percent\":85,\"stage2RiseCentiC\":300}"
        let decoded = try JSONDecoder().decode(FanPolicy.self, from: Data(json.utf8))
        check(decoded.enabled && decoded.strategy == .twoStage && decoded.thresholdCentiC == 4200
                && decoded.releaseHysteresisCentiC == 200 && decoded.speedPercent == 70
                && decoded.stage2Percent == 85 && decoded.stage2RiseCentiC == 300,
              "风扇源-1", "旧 7 字段解码：既有字段全保留（升级不重置策略）")
        check(decoded.temperatureSource == .battery && decoded.cpuSkinThresholdCentiC == 5500
                && decoded.cpuSkinHysteresisCentiC == 400,
              "风扇源-1", "新字段落默认：battery / 5500 / 400（P0 兼容定版）")
        check(FanPolicy.default.temperatureSource == .battery
                && FanPolicy.default.cpuSkinThresholdCentiC == 5500
                && FanPolicy.default.cpuSkinHysteresisCentiC == 400,
              "风扇源-1", "FanPolicy.default 新字段默认值钉死（battery/5500/400）")
    }

    // 风扇源-2：validated 双域——cpuSkin 阈值/滞回越界 → nil；两端点与默认过校验；
    // 既有 7 参数调用点（不传新参）不受影响。
    do {
        let below = FanPolicy.validated(
            enabled: true, strategy: .constantSpeed, thresholdCentiC: 3700,
            releaseHysteresisCentiC: 200, speedPercent: 50, stage2Percent: 90,
            stage2RiseCentiC: 300, temperatureSource: .cpuSkin, cpuSkinThresholdCentiC: 3999
        )
        let above = FanPolicy.validated(
            enabled: true, strategy: .constantSpeed, thresholdCentiC: 3700,
            releaseHysteresisCentiC: 200, speedPercent: 50, stage2Percent: 90,
            stage2RiseCentiC: 300, temperatureSource: .cpuSkin, cpuSkinThresholdCentiC: 7001
        )
        let hysBad = FanPolicy.validated(
            enabled: true, strategy: .constantSpeed, thresholdCentiC: 3700,
            releaseHysteresisCentiC: 200, speedPercent: 50, stage2Percent: 90,
            stage2RiseCentiC: 300, temperatureSource: .cpuSkin, cpuSkinThresholdCentiC: 5500,
            cpuSkinHysteresisCentiC: 801
        )
        let endpoints = FanPolicy.validated(
            enabled: true, strategy: .constantSpeed, thresholdCentiC: 3700,
            releaseHysteresisCentiC: 200, speedPercent: 50, stage2Percent: 90,
            stage2RiseCentiC: 300, temperatureSource: .cpuSkin, cpuSkinThresholdCentiC: 4000,
            cpuSkinHysteresisCentiC: 300
        ) != nil && FanPolicy.validated(
            enabled: true, strategy: .constantSpeed, thresholdCentiC: 3700,
            releaseHysteresisCentiC: 200, speedPercent: 50, stage2Percent: 90,
            stage2RiseCentiC: 300, temperatureSource: .cpuSkin, cpuSkinThresholdCentiC: 7000,
            cpuSkinHysteresisCentiC: 800
        ) != nil
        let legacyCall = FanPolicy.validated(
            enabled: true, strategy: .constantSpeed, thresholdCentiC: 3700,
            releaseHysteresisCentiC: 200, speedPercent: 50, stage2Percent: 90,
            stage2RiseCentiC: 300
        )
        check(below == nil && above == nil && hysBad == nil, "风扇源-2",
              "cpuSkin 阈值 3999/7001、滞回 801 越界 → nil（validated 双域强校验）")
        check(endpoints && legacyCall != nil, "风扇源-2",
              "cpuSkin 两端点（4000/300、7000/800）合法 + 既有 7 参调用零改动（默认参防破编译）")
    }

    // 风扇源-3：source round-trip——cpuSkin 策略编码解码等值；battery 默认也恒写
    // 新键（encode 恒写——R2 P2-1，防「缺席键 → 回读落默认」歧义）。
    do {
        let cpuSkin = policy(source: .cpuSkin, cpuThreshold: 6000, cpuHysteresis: 500)
        let data = try JSONEncoder().encode(cpuSkin)
        let decoded = try JSONDecoder().decode(FanPolicy.self, from: data)
        check(decoded == cpuSkin, "风扇源-3", "cpuSkin 策略 Codable roundtrip 等值")
        let batteryData = try JSONEncoder().encode(policy())
        let batteryText = String(data: batteryData, encoding: .utf8) ?? ""
        check(batteryText.contains("temperatureSource") && batteryText.contains("cpuSkinThresholdCentiC"),
              "风扇源-3", "battery 默认策略恒写新键（encode 非可选存储——R2 P2-1 定版）")
    }

    // 风扇源-4：未知 source 解码炸钉死——"cpuDie" 非法 rawValue → decode 抛错
    // （PolicyStore 整包 nil 落默认的前置语义，照 FanStrategy 退役值纪律）。
    do {
        let json = "{\"enabled\":true,\"strategy\":\"constantSpeed\",\"thresholdCentiC\":3700," +
            "\"releaseHysteresisCentiC\":200,\"speedPercent\":50,\"stage2Percent\":90," +
            "\"stage2RiseCentiC\":300,\"temperatureSource\":\"cpuDie\"}"
        let decodeBombed = (try? JSONDecoder().decode(FanPolicy.self, from: Data(json.utf8))) == nil
        check(decodeBombed, "风扇源-4", "未知 source \"cpuDie\" 解码抛错（整包 nil 纪律，只追加不重排）")
    }

    // ---- ② FanGuard effective* 双域 ----

    // 风扇源-5：battery 零回归——effective*/effectiveHysteresis 返回既有字段原值。
    do {
        let p = policy()
        check(FanGuard.effectiveThreshold(policy: p) == 3700 && FanGuard.effectiveHysteresis(policy: p) == 200,
              "风扇源-5", "battery 源 effective* = 既有字段原值（threshold/releaseHysteresis 零回归）")
    }

    // 风扇源-6：cpuSkin 新值——effective* 返回 cpuSkin* 字段值。
    do {
        let p = policy(source: .cpuSkin, cpuThreshold: 6000, cpuHysteresis: 500)
        check(FanGuard.effectiveThreshold(policy: p) == 6000 && FanGuard.effectiveHysteresis(policy: p) == 500,
              "风扇源-6", "cpuSkin 源 effective* = cpuSkin 字段值（6000/500）")
    }

    // 风扇源-7：decide cpuSkin 进入/驻留/释放（battery 域阈值不参与判定）。
    do {
        let p = policy(source: .cpuSkin, cpuThreshold: 5500, cpuHysteresis: 400)
        // 进入：t = 55.0（cpuSkin 阈值含入侧）→ enterBoost（若仍用 battery 域 3700
        // 会在更低温度进入——回归防护）。
        check(FanGuard.decided(temperatureC: 55.0, policy: p, modeActive: true, capability: .verified,
                               boostActive: false, boostTicks: 0, currentTargetRPM: nil,
                               facts: FanFacts(minRPM: 1500, maxRPM: 4000), sampleHealthy: true)
                == .enterBoost(targetRPM: 2000),
              "风扇源-7", "cpuSkin 进入：t=55.0 ≥ 5500 → enterBoost（battery 域 37°C 不误触发）")
        // 静息：t = 54.9（阈值下沿）→ idle。
        check(FanGuard.decided(temperatureC: 54.9, policy: p, modeActive: true, capability: .verified,
                               boostActive: false, boostTicks: 0, currentTargetRPM: nil,
                               facts: FanFacts(minRPM: 1500, maxRPM: 4000), sampleHealthy: true)
                == .idle(stateWord: .automatic),
              "风扇源-7", "cpuSkin 下沿：t=54.9 < 55.0 → idle（automatic）")
        // 带内驻留/释放：boost 期 t=51.0（=5500−400 含入侧）→ hold；t=50.9 → release。
        check(FanGuard.decided(temperatureC: 51.0, policy: p, modeActive: true, capability: .verified,
                               boostActive: true, boostTicks: 0, currentTargetRPM: nil,
                               facts: FanFacts(minRPM: 1500, maxRPM: 4000), sampleHealthy: true) == .hold,
              "风扇源-7", "cpuSkin 带内下界：t=51.0 == 阈值−滞回（含入侧）→ hold")
        check(FanGuard.decided(temperatureC: 50.9, policy: p, modeActive: true, capability: .verified,
                               boostActive: true, boostTicks: 0, currentTargetRPM: nil,
                               facts: FanFacts(minRPM: 1500, maxRPM: 4000), sampleHealthy: true)
                == .release(stateWord: .automatic),
              "风扇源-7", "cpuSkin 释放：t=50.9 < 阈值−滞回 → release（双域滞回独立）")
    }

    // 风扇源-8：targetRPM 双域档位（stage2Cross 随源——R1 P1-1 漏改 :118 会档位错配）。
    do {
        let facts = FanFacts(minRPM: 1500, maxRPM: 4000)
        let cpuTwoStage = policy(source: .cpuSkin, cpuThreshold: 5500, strategy: .twoStage)
        // cpuSkin：t=58.0 ≥ 5500+300=5800（含入侧）→ stage2 3200；t=57.9 → stage1 2000。
        check(FanGuard.targetRPM(policy: cpuTwoStage, facts: facts, temperatureC: 58.0) == 3200,
              "风扇源-8", "targetRPM cpuSkin：t=58.0 ≥ cpuSkin 阈值+rise → stage2（3200）")
        check(FanGuard.targetRPM(policy: cpuTwoStage, facts: facts, temperatureC: 57.9) == 2000,
              "风扇源-8", "targetRPM cpuSkin：t=57.9 < 升档线 → stage1（2000，档位不越域）")
        // battery 同输入不跨档（37.0+3.0=40.0 才升档——值域隔离的镜像断言）。
        let batteryTwoStage = policy(strategy: .twoStage)
        check(FanGuard.targetRPM(policy: batteryTwoStage, facts: facts, temperatureC: 58.0) == 3200
                && FanGuard.targetRPM(policy: batteryTwoStage, facts: facts, temperatureC: 39.9) == 2000,
              "风扇源-8", "targetRPM battery 域照旧：40.0 升档线（39.9 → stage1）——零回归")
    }

    // ---- ③ wire 三键 ----

    // 风扇源-9：fanSource 值域——0/1 合法，2/0xFFFFFFFF 拒绝；映射往返同构。
    do {
        check(FanWireKeys.validSource(0) && FanWireKeys.validSource(1)
                && !FanWireKeys.validSource(2) && !FanWireKeys.validSource(0xFFFFFFFF),
              "风扇源-9", "fanSource 白名单 0/1（越界拒绝——UINT64 全值域防呆）")
        check(FanWire.temperatureSource(fromWire: 0) == .battery
                && FanWire.temperatureSource(fromWire: 1) == .cpuSkin
                && FanWire.temperatureSource(fromWire: 9) == nil,
              "风扇源-9", "fromWire 映射：0=battery 1=cpuSkin 未知=nil")
        check(FanWire.wireValue(.battery) == 0 && FanWire.wireValue(.cpuSkin) == 1,
              "风扇源-9", "wireValue 同构映射（0/1）——SMC-PROTOCOL 登记同源")
    }

    // 风扇源-10：cpuThreshold/cpuHysteresis 值域（4000...7000 / 300...800）。
    do {
        check(!FanWireKeys.validCpuThreshold(3999) && FanWireKeys.validCpuThreshold(4000)
                && FanWireKeys.validCpuThreshold(7000) && !FanWireKeys.validCpuThreshold(7001),
              "风扇源-10", "fanCpuThreshold 值域 4000..7000（厘摄氏度）")
        check(!FanWireKeys.validCpuHysteresis(299) && FanWireKeys.validCpuHysteresis(300)
                && FanWireKeys.validCpuHysteresis(800) && !FanWireKeys.validCpuHysteresis(801),
              "风扇源-10", "fanCpuHysteresis 值域 300..800（厘摄氏度）")
    }

    // 风扇源-11：wire 缺席保持——source/cpuThreshold/cpuHysteresis 缺席合并保留 base；
    // 在场应用 + validated 同源拒绝（越界合并 → nil）。
    do {
        let base = policy()
        let absent = FanWire(enabled: 1).mergedPolicy(base: base)
        check(absent?.temperatureSource == .battery && absent?.cpuSkinThresholdCentiC == 5500
                && absent?.cpuSkinHysteresisCentiC == 400 && absent?.thresholdCentiC == 3700,
              "风扇源-11", "三新键缺席 → base 全保留（缺席保持语义覆盖新键）")
        let merged = FanWire(source: 1, cpuThreshold: 6000).mergedPolicy(base: base)
        check(merged?.temperatureSource == .cpuSkin && merged?.cpuSkinThresholdCentiC == 6000
                && merged?.cpuSkinHysteresisCentiC == 400,
              "风扇源-11", "source+cpuThreshold 在场应用、cpuHysteresis 缺席保持")
        let rejected = FanWire(cpuThreshold: 7001).mergedPolicy(base: base)
        check(rejected == nil, "风扇源-11", "cpuThreshold 7001 合并 → validated 整包 nil（不半合法）")
    }

    // 风扇源-12：validateRequest 类型白名单扩面——fanSource STRING 混入整包拒绝；
    // UINT64 正常提取。
    do {
        let mixed = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(mixed, DaemonXPC.cmdKey, "setFan")
        xpc_dictionary_set_uint64(mixed, DaemonXPC.upperKey, 80)
        xpc_dictionary_set_uint64(mixed, DaemonXPC.hysteresisKey, 2)
        xpc_dictionary_set_string(mixed, FanWireKeys.source, "1")   // STRING 混入 UINT64 键
        let plain = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(plain, DaemonXPC.cmdKey, "setFan")
        xpc_dictionary_set_uint64(plain, DaemonXPC.upperKey, 80)
        xpc_dictionary_set_uint64(plain, DaemonXPC.hysteresisKey, 2)
        xpc_dictionary_set_uint64(plain, FanWireKeys.source, 1)
        xpc_dictionary_set_uint64(plain, FanWireKeys.cpuThreshold, 6000)
        let mixedRejected = DaemonXPC.validateRequest(mixed) == nil
        let plainFan = DaemonXPC.validateRequest(plain)?.fan
        check(mixedRejected, "风扇源-12", "fanSource STRING 混入 → 整包拒绝（类型白名单扩面）")
        check(plainFan?.source == 1 && plainFan?.cpuThreshold == 6000,
              "风扇源-12", "UINT64 fanSource/fanCpuThreshold 正常提取（新键独立发键）")
    }

    // 风扇源-13：FanStatus 兼容——旧 daemon 回包无 cpuSkin 键 → nil（App 门控升级
    // 提示的判定依据）+ 新字段 roundtrip 保真。
    do {
        let status = DaemonStatus(
            version: "0.5.0-alpha", mode: "active", upperLimit: 80, hysteresis: 2
        )
        var withFan = status
        withFan.fan = FanStatus(
            enabled: true, strategy: .twoStage, state: .boost,
            targetRPM: 3200, currentRPM: 3185, thresholdCentiC: 3700, conflictFlag: false,
            temperatureSource: 1, cpuSkinTempC: 57.5, cpuSkinSupported: true,
            cpuSkinThresholdCentiC: 5500, cpuSkinHysteresisCentiC: 400
        )
        let data = try JSONEncoder().encode(withFan)
        let decoded = try JSONDecoder().decode(DaemonStatus.self, from: data)
        check(decoded.fan == withFan.fan, "风扇源-13", "FanStatus 新五字段 roundtrip 保真")
        let oldJSON = #"{"version":"0.16.0-alpha","mode":"active","upperLimit":80,"hysteresis":2,"timestamp":700000000.0,"fan":{"enabled":true,"strategy":"twoStage","state":"hold","targetRPM":3200,"currentRPM":null,"thresholdCentiC":3700,"conflictFlag":false,"speedPercent":50,"stage2Percent":80,"stage2RiseCentiC":300}}"#
        let oldDecoded = try JSONDecoder().decode(DaemonStatus.self, from: Data(oldJSON.utf8))
        check(oldDecoded.fan?.temperatureSource == nil && oldDecoded.fan?.cpuSkinSupported == nil
                && oldDecoded.fan?.cpuSkinTempC == nil && oldDecoded.fan?.cpuSkinThresholdCentiC == nil
                && oldDecoded.fan?.cpuSkinHysteresisCentiC == nil,
              "风扇源-13", "旧 daemon 回包（0.16 形态）新五键缺席 → 全 nil（App 门控升级提示）")
    }

    // 风扇源-14：doctor 分支——cpuSkin 配置扩显示（源/探测/温度）；旧形态字段 nil
    // 行零回归（不出现温度源词）。
    do {
        func doctorDetail(_ fan: FanStatus?) -> String? {
            let inputs = DoctorInputs(
                isRoot: true, smcConnected: true,
                probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
                chargingEnabled: false, chargingError: nil,
                snapshot: nil, snapshotError: nil,
                conflict: ConflictScanResult(exact: [], generic: []),
                fanProbe: FanDoctorProbe(
                    keysPresent: ["F0Tg", "F0Md", "F0Ac", "F0Mn", "F0Mx"],
                    mdValue: 0, tgRPM: 1350,
                    config: fan
                )
            )
            return DoctorReportGenerator.generate(inputs).checks
                .first { $0.name == "风扇控制" }?.detail
        }
        let cpuSkinDetail = doctorDetail(FanStatus(
            enabled: false, strategy: .constantSpeed, state: .off,
            targetRPM: nil, currentRPM: nil, thresholdCentiC: 3700, conflictFlag: false,
            temperatureSource: 1, cpuSkinTempC: 52.5, cpuSkinSupported: false,
            cpuSkinThresholdCentiC: 5500, cpuSkinHysteresisCentiC: 400
        ))
        check(cpuSkinDetail?.contains("温度源=CPU 表面") == true
                && cpuSkinDetail?.contains("CPU 表面探测=不支持") == true
                && cpuSkinDetail?.contains("52.5°C") == true,
              "风扇源-14", "doctor：源=CPU 表面 + 探测不支持 + 当前源温度 52.5°C 全呈现")
        let batteryDetail = doctorDetail(FanStatus(
            enabled: false, strategy: .constantSpeed, state: .off,
            targetRPM: nil, currentRPM: nil, thresholdCentiC: 3700, conflictFlag: false,
            temperatureSource: 0, cpuSkinTempC: nil, cpuSkinSupported: true,
            cpuSkinThresholdCentiC: 5500, cpuSkinHysteresisCentiC: 400
        ))
        check(batteryDetail?.contains("温度源=电池") == true
                && batteryDetail?.contains("CPU 表面探测=支持") == true
                && batteryDetail?.contains("当前源温度") == false,
              "风扇源-14", "doctor：battery 源呈现 + 无 cpuSkin 温度行（温度仅 cpuSkin 采样）")
        let legacyDetail = doctorDetail(FanStatus(
            enabled: false, strategy: .constantSpeed, state: .off,
            targetRPM: nil, currentRPM: nil, thresholdCentiC: 3700, conflictFlag: false
        ))
        check(legacyDetail?.contains("温度源") == false,
              "风扇源-14", "doctor：旧 daemon 形态（键缺席）不渲染温度源词——行零回归")
    }
}
