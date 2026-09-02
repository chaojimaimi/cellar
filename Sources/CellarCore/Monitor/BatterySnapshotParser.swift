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
    public static func parse(_ props: [String: Any], timestamp: Date) throws -> BatterySnapshot {
        let batteryData = props["BatteryData"] as? [String: Any]
        return BatterySnapshot(
            percent: try requiredInt(props, "CurrentCapacity"),
            isCharging: try requiredBool(props, "IsCharging"),
            externalConnected: try requiredBool(props, "ExternalConnected"),
            voltageMV: try requiredInt(props, "Voltage"),
            amperageMA: try requiredInt(props, "Amperage"),
            temperatureCentiC: try requiredInt(props, "Temperature"),
            cycleCount: try requiredInt(props, "CycleCount"),
            designCapacityMAh: try requiredInt(props, "DesignCapacity"),
            maxCapacityPercent: intValue(props["MaxCapacity"]),
            fullyCharged: boolValue(props["FullyCharged"]),
            rawMaxCapacityMAh: intValue(props["AppleRawMaxCapacity"]),
            rawCurrentCapacityMAh: intValue(props["AppleRawCurrentCapacity"]),
            cellVoltagesMV: batteryData.flatMap { cellVoltages(from: $0) },
            fccMAh: batteryData.flatMap { intValue($0["FccComp1"]) },
            adapter: adapter(from: props["AdapterDetails"]),
            timestamp: timestamp
        )
    }

    // MARK: - 必需字段提取

    /// 必需 Int：缺失 → `.missingRequiredField`；类型不符 → `.invalidFieldType`。
    private static func requiredInt(_ props: [String: Any], _ key: String) throws -> Int {
        guard let raw = props[key] else { throw BatteryMonitorError.missingRequiredField(key) }
        guard let value = intValue(raw) else { throw BatteryMonitorError.invalidFieldType(key) }
        return value
    }

    /// 必需 Bool：缺失 → `.missingRequiredField`；非 Bool / 非 0/1 数值 → `.invalidFieldType`。
    private static func requiredBool(_ props: [String: Any], _ key: String) throws -> Bool {
        guard let raw = props[key] else { throw BatteryMonitorError.missingRequiredField(key) }
        guard let value = boolValue(raw) else { throw BatteryMonitorError.invalidFieldType(key) }
        return value
    }

    // MARK: - 统一数值 / Bool 转换

    /// 统一数字转换（评审 B-4）：按位保留还原有符号值。
    /// 浮点值会被静默截断（NSNumber 的 C 语义）；当前事实源全为整数，小数支持待有真实需求再加。
    private static func intValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return Int(Int64(bitPattern: number.uint64Value))
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
}