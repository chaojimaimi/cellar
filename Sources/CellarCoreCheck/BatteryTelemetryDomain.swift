// CellarCoreCheck —— Phase 5 v1.11 M2 实时功率遥测域（方案 D-1a/D-1b + T2 偏好位）：
// PowerTelemetryData 提取（正常闭环/缺席/嵌套类型错/UInt64 回绕按位还原——B-4 纪律）
// + AppConfig.windowBatteryIconVisible round-trip（标题栏电池图标偏好，T2）。
// 按域拆独立文件（FanTemperatureSourceDomain 同批，main 不增长）。
import CellarCore
import Foundation

/// 遥测/显示偏好场景域入口（Main.main 调用；断言经 MainEntry.swift 的 internal 助手）。
func runBatteryTelemetryDomainScenarios() throws {
    // ---- fixture 工厂（照 CellarUICheck makeSnapshot 形态——最小必需八字段）----
    func makeProps() -> [String: Any] {
        [
            "CurrentCapacity": 85, "IsCharging": true, "ExternalConnected": true,
            "Voltage": 11_670, "Amperage": -1_800, "Temperature": 3_100,
            "CycleCount": 123, "DesignCapacity": 6_300,
        ]
    }

    // 遥测-1：正常样例闭环——六键全提取；SystemPowerIn ≈ VoltageIn×CurrentIn/1e6
    // （本机 ioreg 实测形态：62767 ≈ 19446×3227/1e6——62.8 W 与 62.7 W 闭环一致）。
    do {
        var props = makeProps()
        props["PowerTelemetryData"] = [
            "SystemPowerIn": 62_767, "SystemLoad": 30_540, "BatteryPower": 32_227,
            "AdapterEfficiencyLoss": 8_000, "SystemVoltageIn": 19_446, "SystemCurrentIn": 3_227,
        ]
        let snapshot = try BatterySnapshotParser.parse(props, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let telemetry = snapshot.telemetry
        check(telemetry?.systemPowerInMW == 62_767 && telemetry?.systemLoadMW == 30_540
                && telemetry?.batteryPowerMW == 32_227 && telemetry?.adapterEfficiencyLossMW == 8_000
                && telemetry?.voltageInMV == 19_446 && telemetry?.currentInMA == 3_227,
              "遥测-1", "PowerTelemetryData 六键全提取（mW/mV/mA 单位）")
        // 闭环一致性（纯算术佐证——功率 = 电压×电流）。
        if let telemetry {
            let product = Double(telemetry.voltageInMV!) * Double(telemetry.currentInMA!) / 1_000_000
            check(abs(product - Double(telemetry.systemPowerInMW!) / 1000) < 0.5,
                  "遥测-1", "闭环：VoltageIn×CurrentIn/1e6 ≈ SystemPowerIn（实测物理一致）")
        } else {
            check(false, "遥测-1", "telemetry 应非 nil")
        }
    }

    // 遥测-2：缺席 → nil（既有 fixture 无键——存量快照场景零回归的机械保证）。
    do {
        let snapshot = try BatterySnapshotParser.parse(makeProps(), timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        check(snapshot.telemetry == nil, "遥测-2", "PowerTelemetryData 缺席 → telemetry=nil（缺席容错）")
    }

    // 遥测-3：嵌套类型错 → 整字段 nil（快照可用性不受影响——B 系纪律）。
    do {
        var props = makeProps()
        props["PowerTelemetryData"] = "not-a-dict"
        let stringSnapshot = try BatterySnapshotParser.parse(props, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        check(stringSnapshot.telemetry == nil, "遥测-3", "PowerTelemetryData 非字典（String 混入）→ nil")
        var arrayProps = makeProps()
        arrayProps["PowerTelemetryData"] = [1, 2, 3]
        let arraySnapshot = try BatterySnapshotParser.parse(arrayProps, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        check(arraySnapshot.telemetry == nil, "遥测-3", "PowerTelemetryData 数组混入 → nil")
        // 字段级类型错 → 该字段 nil、其余字段照提（AdapterInfo 先例）。
        var mixedProps = makeProps()
        mixedProps["PowerTelemetryData"] = ["SystemPowerIn": 62_767, "SystemLoad": "bad"]
        let mixed = try BatterySnapshotParser.parse(mixedProps, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        check(mixed.telemetry?.systemPowerInMW == 62_767 && mixed.telemetry?.systemLoadMW == nil,
              "遥测-3", "字段级类型错 → 该字段 nil、其余照提（字段级容错）")
    }

    // 遥测-4：UInt64 回绕负值按位还原（B-4 纪律——BatteryPower 放电态实测回绕负值）。
    do {
        var props = makeProps()
        // NSNumber(quoted UInt64 bit pattern of -741)——放电态 BatteryPower 实测形态。
        props["PowerTelemetryData"] = ["BatteryPower": NSNumber(value: UInt64(bitPattern: Int64(-741)))]
        let snapshot = try BatterySnapshotParser.parse(props, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        check(snapshot.telemetry?.batteryPowerMW == -741,
              "遥测-4", "BatteryPower UInt64 回绕 → -741 按位还原（B-4：有符号/无符号存储皆按位保留）")
    }

    // 遥测-5（T2）：AppConfig.windowBatteryIconVisible——缺键旧文件 → nil；round-trip
    // 等值；显式 true/false 解码保真（照用例 95 menuBarPercentage 先例）。
    do {
        let legacy = try JSONDecoder().decode(AppConfig.self, from: Data("{\"launchAtLogin\":true}".utf8))
        check(legacy.windowBatteryIconVisible == nil, "遥测-5", "旧文件缺 windowBatteryIconVisible 键 → nil（decodeIfPresent）")
        var config = AppConfig(launchAtLogin: false, onboardingCompleted: true, windowBatteryIconVisible: true)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        check(decoded == config && decoded.windowBatteryIconVisible == true,
              "遥测-5", "windowBatteryIconVisible round-trip 等值（true 保真）")
        config.windowBatteryIconVisible = false
        let offDecoded = try JSONDecoder().decode(AppConfig.self, from: try JSONEncoder().encode(config))
        check(offDecoded.windowBatteryIconVisible == false, "遥测-5", "显式 false round-trip 保真（与 nil 语义可区分）")
    }
}
