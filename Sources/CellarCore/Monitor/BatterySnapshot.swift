import Foundation

/// 电池快照（AppleSmartBattery 注册表属性的一次解析结果，纯值类型）。
///
/// 字段语义以真机实测（2026-08-31，AppleSmartBattery 注册表）为准，
/// 禁止用训练记忆中的 macOS/IOKit 知识改判字段行为。
public struct BatterySnapshot: Equatable, Sendable {
    /// 电量百分比（CurrentCapacity，直读）。
    public let percent: Int
    /// 是否充电（IsCharging）。
    public let isCharging: Bool
    /// 外部电源是否连接（ExternalConnected）。
    public let externalConnected: Bool
    /// 电池电压 mV（Voltage）。
    public let voltageMV: Int
    /// 电池电流 mA（Amperage）。⚠️ 符号语义未定（实测互相矛盾），方向判定一律以 isCharging 为准。
    public let amperageMA: Int
    /// 电池温度（Temperature，厘摄氏度）。
    public let temperatureCentiC: Int
    /// 温度摄氏换算（厘摄氏度 ÷ 100）。
    public var temperatureC: Double { Double(temperatureCentiC) / 100 }
    /// 循环次数（CycleCount）。
    public let cycleCount: Int
    /// 设计容量 mAh（DesignCapacity）。
    public let designCapacityMAh: Int
    /// 当前最大容量 %（MaxCapacity；语义随系统版本漂移，缺席/类型不符 → nil 容错）。
    public let maxCapacityPercent: Int?
    /// 是否已充满（FullyCharged；WP2 fullOnce 完成判定主判据。缺键/类型不符 → nil
    /// 容错——调用方按降级判据处理。本机 2026-09-02 实测：91% 时 = No，语义正确）。
    public let fullyCharged: Bool?
    /// 原始最大容量 mAh（AppleRawMaxCapacity，缺席 → nil）。
    public let rawMaxCapacityMAh: Int?
    /// 原始当前容量 mAh（AppleRawCurrentCapacity，缺席 → nil）。
    public let rawCurrentCapacityMAh: Int?
    /// 标称容量 mAh（AppleNominalChargeCapacity，缺席 → nil）。
    /// WP2' 健康度口径：与 DesignCapacity 同源 Apple 官方（系统设置同源）；
    /// 缺席时消费侧回落 rawMaxCapacityMAh（方案 §4.3）。
    public let nominalChargeCapacityMAh: Int?
    /// 电芯电压 mV（BatteryData.CellVoltage，缺席 → nil）。
    public let cellVoltagesMV: [Int]?
    /// 全充满补偿容量 mAh（BatteryData.FccComp1，缺席 → nil）。
    public let fccMAh: Int?
    /// 适配器信息（AdapterDetails 直接字典；缺席 → nil）。
    /// AppleRawAdapterDetails 数组形状 WP3 不解析（登记，风险表）。
    public let adapter: AdapterInfo?
    /// 快照时刻（调用方注入，见 BatterySnapshotParser.parse）。
    public let timestamp: Date
}

/// 电池健康度（WP2' §4.3）：Nominal/Design 官方口径百分比。
///
/// - `design <= 0` → nil（DesignCapacity 必需字段理论上 >0，防御 guard）；
/// - `nominal == nil` → nil（消费侧先经 rawMaxCapacityMAh 兜底再调用本函数——
///   两级缺席均 nil，UI 仅显示循环次数零回归）；
/// - 结果 clamp 0...100（标称高于设计等异常源不穿透显示，评审 P2-8）。
public func batteryHealthPercent(nominal: Int?, design: Int) -> Int? {
    guard design > 0, let nominal else { return nil }
    let percent = Int((Double(nominal) / Double(design) * 100).rounded())
    return min(max(percent, 0), 100)
}

/// 适配器信息（AdapterDetails 字典的字段级提取；缺席/结构变化 → 整个 nil 或字段级 nil）。
public struct AdapterInfo: Equatable, Sendable {
    /// 适配器功率 W（Watts）。
    public let watts: Int?
    /// 适配器电压 mV（AdapterVoltage）。
    public let voltageMV: Int?
    /// 适配器电流 mA（Current）。
    public let currentMA: Int?
    /// 适配器名称（Name，如 "140W USB-C Power Adapter"）。
    public let name: String?
    /// 适配器描述（Description；命名 adapterDescription 避让 CustomStringConvertible 惯用名，评审 A-4）。
    public let adapterDescription: String?
    /// 无线充电标记（IsWireless）。
    public let isWireless: Bool?
}

/// 电池监测层的类型化错误。
///
/// 红线：与 SMC 层一致，错误一律原样向上抛出，禁止吞错/猜测降级。
public enum BatteryMonitorError: Error, Equatable, Sendable {
    /// AppleSmartBattery 服务不存在 / 平台无 IOKit（IOServiceGetMatchingService 返回 0）。
    case serviceNotFound
    /// IORegistryEntryCreateCFProperties 失败（kr≠0）；kr=0 仅封口桥接失败的不可达路径。
    case readFailed(kr: Int32)
    /// 必需字段缺失。
    case missingRequiredField(String)
    /// 必需字段类型不符。
    case invalidFieldType(String)
}