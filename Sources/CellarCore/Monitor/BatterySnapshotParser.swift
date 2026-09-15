import Foundation

/// `BatterySnapshot` 的纯函数解析器：AppleSmartBattery 注册表属性字典
/// （`ioreg -rc AppleSmartBattery` 的桥接结果，规格 §0 事实源）→ 快照。
///
/// - 必需 8 字段（CurrentCapacity / IsCharging / ExternalConnected / Voltage /
///   Amperage / Temperature / CycleCount / DesignCapacity）：缺失 →
///   `.missingRequiredField`，类型不符 → `.invalidFieldType`（评审 B-3）。
/// - 其余字段全部可选容错：缺席/类型不符 → nil，不抛错（MaxCapacity 语义漂移、
///   BatteryData / AdapterDetails 结构变化均不影响快照可用性）。
/// - 数字统一转换（评审 B-4）：NSNumber 一律 `Int(Int64(bitPattern: .uint64Value))`，
///   有符号/无符号存储皆按位保留还原（-741 的 UInt64 回绕 → -741）。
///   已登记取舍：浮点值按 NSNumber 的 C 语义静默截断（当前事实源全为整数）。
/// - Bool 值域（评审 B-5）：仅接受 Bool 与数值 0/1（其余值 → 必需 `.invalidFieldType` /
///   可选 nil）；禁止依赖 `boolValue` 对非零一律 true 的桥接行为。
/// - Amperage 符号语义未定（实测互相矛盾）：原值保留，方向判定一律以 IsCharging 为准。
public enum BatterySnapshotParser {
    /// 纯函数解析。`timestamp` 由调用方注入（评审 D-1），保持无外部状态的纯函数语义。
    ///
    /// `temperatureFallbackCentiC`（v0.19.8 macOS 27 兼容，方案 §3.1.1）：ioreg 顶层
    /// `Temperature` 键缺失时的回退值（调用方经 SMC TB1T/TB2T 供给）；缺省 nil →
    /// 既有行为零变化（键缺失 → `.missingRequiredField`，既有调用/场景零改动）。
    public static func parse(
        _ props: [String: Any],
        timestamp: Date,
        temperatureFallbackCentiC: Int? = nil
    ) throws -> BatterySnapshot {
        let batteryData = props["BatteryData"] as? [String: Any]
        // ChargerData 子字典（v1.7 原生限充运行态签名 NotChargingReason 的来源；
        // 提取模式照 BatteryData 先例——缺席/类型不符 → 整字段 nil 容错）。
        let chargerData = props["ChargerData"] as? [String: Any]
        // v0.19.9 macOS 27 兼容：gauge 字段族（DesignCapacity/NominalChargeCapacity/
        // RemainingCapacity 等）自顶层迁入 BatteryData 子字典——查找顺序恒「顶层优先
        // （macOS 26 语义零变化）→ BatteryData 回退（27）」，对全部必需/相关可选字段
        // 生效，防后续迁移再断。Temperature 不在节点 BatteryData（spike 0/10），
        // 走独立的 SMC TB1T/TB2T 回退链（v0.19.8）。
        let dicts: [[String: Any]] = batteryData.map { [props, $0] } ?? [props]
        return BatterySnapshot(
            percent: try requiredInt(dicts, "CurrentCapacity"),
            isCharging: try requiredBool(dicts, "IsCharging"),
            externalConnected: try requiredBool(dicts, "ExternalConnected"),
            voltageMV: try requiredInt(dicts, "Voltage"),
            amperageMA: try requiredInt(dicts, "Amperage"),
            temperatureCentiC: try temperature(props, fallback: temperatureFallbackCentiC),
            cycleCount: try requiredInt(dicts, "CycleCount"),
            designCapacityMAh: try requiredInt(dicts, "DesignCapacity"),
            maxCapacityPercent: intValue(props["MaxCapacity"]),
            fullyCharged: boolValue(props["FullyCharged"]),
            rawMaxCapacityMAh: intValue(props["AppleRawMaxCapacity"]),
            rawCurrentCapacityMAh: intValueAcross(dicts, "AppleRawCurrentCapacity"),
            // ⚠️ 键名以真机 ioreg 实测为准（2026-09-03）：NominalChargeCapacity——
            // 无 Apple 前缀（曾误写 AppleNominalChargeCapacity 致解析恒空、
            // 健康度静默回退 rawMax 口径，面板 86% vs 系统 90% 的差异来源）。
            // v0.19.9：27 迁入 BatteryData，跨字典查找。
            nominalChargeCapacityMAh: intValueAcross(dicts, "NominalChargeCapacity"),
            cellVoltagesMV: batteryData.flatMap { cellVoltages(from: $0) },
            fccMAh: batteryData.flatMap { intValue($0["FccComp1"]) },
            adapter: adapter(from: props["AdapterDetails"]),
            notChargingReason: chargerData.flatMap { uint64Value($0["NotChargingReason"]) },
            // PowerTelemetryData 嵌套字典（v1.11 T1）：提取模式照 AdapterDetails
            // 先例——缺席/类型不符 → 整字段 nil 容错，不影响快照可用性。
            telemetry: props["PowerTelemetryData"].flatMap { powerTelemetry(from: $0) },
            timestamp: timestamp
        )
    }

    // MARK: - 必需字段提取

    /// 必需 Int（v0.19.9 跨字典）：按序取首个命中字典；缺失 → `.missingRequiredField`；
    /// 类型不符 → `.invalidFieldType`（命中字典内类型不符不继续找后续字典——类型错误
    /// 是数据损坏信号，跨字典重试会掩盖）。
    private static func requiredInt(_ dicts: [[String: Any]], _ key: String) throws -> Int {
        for dict in dicts {
            guard let raw = dict[key] else { continue }
            guard let value = intValue(raw) else { throw BatteryMonitorError.invalidFieldType(key) }
            return value
        }
        throw BatteryMonitorError.missingRequiredField(key)
    }

    /// 必需 Bool（v0.19.9 跨字典，语义同 requiredInt）。
    private static func requiredBool(_ dicts: [[String: Any]], _ key: String) throws -> Bool {
        for dict in dicts {
            guard let raw = dict[key] else { continue }
            guard let value = boolValue(raw) else { throw BatteryMonitorError.invalidFieldType(key) }
            return value
        }
        throw BatteryMonitorError.missingRequiredField(key)
    }

    /// 温度取值三分支（v0.19.8 macOS 27 兼容，方案 §3.1.1——Temperature 是唯一
    /// 带回退面的必需字段，故不走 requiredInt 通径）：
    /// - 键在位（经既有 `intValue` 助手）→ 用之（macOS 26 主路，G2）；
    /// - 键缺失且 fallback 非 nil → 用 fallback（macOS 27 回退，G1——顶层
    ///   `Temperature` 键消失，SMC TB1T/TB2T 承接）；
    /// - 键缺失且 fallback nil → `.missingRequiredField`（G3 错误原文不变）。
    /// ⚠️ 键在位但类型不符保持既有 `.invalidFieldType` 抛出——回退仅覆盖
    /// 「键缺失」，不吞类型错误（R2 P3）。
    private static func temperature(_ props: [String: Any], fallback: Int?) throws -> Int {
        guard let raw = props["Temperature"] else {
            guard let fallback else { throw BatteryMonitorError.missingRequiredField("Temperature") }
            return fallback
        }
        guard let value = intValue(raw) else { throw BatteryMonitorError.invalidFieldType("Temperature") }
        return value
    }

    /// 可选 Int 跨字典查找（v0.19.9）：顶层优先；键缺失**与类型不符**均回退
    /// BatteryData（可选字段 nil 容错语义无错误面可掩——与必需字段的「类型错误
    /// 不跨字典」是有意的不对称）。
    private static func intValueAcross(_ dicts: [[String: Any]], _ key: String) -> Int? {
        for dict in dicts {
            if let value = intValue(dict[key]) { return value }
        }
        return nil
    }

    // MARK: - 统一数值 / Bool 转换

    /// 统一数字转换（评审 B-4）：按位保留还原有符号值。
    /// 浮点值会被静默截断（NSNumber 的 C 语义）；当前事实源全为整数，小数支持待有真实需求再加。
    private static func intValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return Int(Int64(bitPattern: number.uint64Value))
    }

    /// 统一 UInt64 转换（v1.7 NotChargingReason 位集专用）：uint64Value 按位保留，
    /// 位 63 置位等超 Int64 正域的值不回绕不失真（位集必须 UInt64 全域）。
    private static func uint64Value(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        return number.uint64Value
    }

    /// Bool 值域（评审 B-5）：Bool 直收；数值 NSNumber 仅接受 0/1（0→false、1→true），
    /// 其余值返回 nil（必需字段由调用方映射为 `.invalidFieldType`）。
    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        guard let number = value as? NSNumber else { return nil }
        if number.uint64Value == 0 { return false }
        if number.uint64Value == 1 { return true }
        return nil
    }

    // MARK: - 嵌套结构（可选字段）

    /// BatteryData.CellVoltage：元素逐一按统一数字转换；任一元素非数值 → 整字段按
    /// 类型不符容错为 nil（可选字段不抛错）。
    private static func cellVoltages(from batteryData: [String: Any]) -> [Int]? {
        guard let raw = batteryData["CellVoltage"] as? [Any] else { return nil }
        var result: [Int] = []
        result.reserveCapacity(raw.count)
        for element in raw {
            guard let value = intValue(element) else { return nil }
            result.append(value)
        }
        return result
    }

    /// AdapterDetails 直接字典（规格 §0 实测形状）→ AdapterInfo。
    /// 缺席/类型不符 → nil；字段级类型不符 → 该字段 nil。
    private static func adapter(from value: Any?) -> AdapterInfo? {
        guard let dict = value as? [String: Any] else { return nil }
        return AdapterInfo(
            watts: intValue(dict["Watts"]),
            voltageMV: intValue(dict["AdapterVoltage"]),
            currentMA: intValue(dict["Current"]),
            name: dict["Name"] as? String,
            adapterDescription: dict["Description"] as? String,
            isWireless: boolValue(dict["IsWireless"])
        )
    }

    /// PowerTelemetryData 直接字典（v1.11 T1 本机 ioreg 实测形状）→ PowerTelemetry。
    /// 缺席/类型不符 → nil；字段级类型不符 → 该字段 nil（照 adapter(from:) 先例）。
    /// 数值统一走 intValue（B-4 按位保留——BatteryPower 放电态回绕负值还原）。
    private static func powerTelemetry(from value: Any?) -> PowerTelemetry? {
        guard let dict = value as? [String: Any] else { return nil }
        return PowerTelemetry(
            systemPowerInMW: intValue(dict["SystemPowerIn"]),
            systemLoadMW: intValue(dict["SystemLoad"]),
            batteryPowerMW: intValue(dict["BatteryPower"]),
            adapterEfficiencyLossMW: intValue(dict["AdapterEfficiencyLoss"]),
            voltageInMV: intValue(dict["SystemVoltageIn"]),
            currentInMA: intValue(dict["SystemCurrentIn"])
        )
    }
}