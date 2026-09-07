import Foundation

// MARK: - XPC 线格式（方案 §8：键全 UINT64，缺席 = 保持现值；类型混淆整包拒绝）
//
// v1.11 M2 自 FanPolicy.swift 迁出（温度源扩面后原文件触 400 行上限——纯移动
// 零语义变化）；本文件承载 setFan 请求载荷、线值映射与键值域校验。

/// setFan 请求载荷（缺席字段 = 保持现值，照 auto 键缺席保持语义）。
/// v1.11 T3 +3 键全 UINT64（保全「键全 UINT64」不变量，R2 P2-6——禁 String）：
/// source 数值映射 0=battery / 1=cpuSkin（新键独立映射，照 FanStrategy 数值先例）。
public struct FanWire: Equatable, Sendable {
    public var enabled: UInt64?
    public var strategy: UInt64?
    public var threshold: UInt64?
    public var hysteresis: UInt64?
    public var speed: UInt64?
    public var stage2: UInt64?
    public var stage2Rise: UInt64?
    /// 温度源（0=battery, 1=cpuSkin；缺席 = 保持现值）。
    public var source: UInt64?
    /// CPU 表面温度阈值（厘摄氏度；4000...7000；缺席 = 保持现值）。
    public var cpuThreshold: UInt64?
    /// CPU 表面温度释放滞回（厘摄氏度；300...800；缺席 = 保持现值）。
    public var cpuHysteresis: UInt64?

    public init(
        enabled: UInt64? = nil, strategy: UInt64? = nil, threshold: UInt64? = nil,
        hysteresis: UInt64? = nil, speed: UInt64? = nil, stage2: UInt64? = nil,
        stage2Rise: UInt64? = nil, source: UInt64? = nil,
        cpuThreshold: UInt64? = nil, cpuHysteresis: UInt64? = nil
    ) {
        self.enabled = enabled
        self.strategy = strategy
        self.threshold = threshold
        self.hysteresis = hysteresis
        self.speed = speed
        self.stage2 = stage2
        self.stage2Rise = stage2Rise
        self.source = source
        self.cpuThreshold = cpuThreshold
        self.cpuHysteresis = cpuHysteresis
    }
}

extension FanWire {
    /// 合并进现有策略（缺席保持）：任何字段非 nil 时应用；结果经
    /// `FanPolicy.validated` 强校验（非法 → nil，不半合法）。
    public func mergedPolicy(base: FanPolicy) -> FanPolicy? {
        FanPolicy.validated(
            enabled: enabled.map { $0 == 1 } ?? base.enabled,
            strategy: strategy.flatMap(FanWire.strategy(fromWire:)) ?? base.strategy,
            thresholdCentiC: threshold.flatMap { Int(exactly: $0) } ?? base.thresholdCentiC,
            releaseHysteresisCentiC: hysteresis.flatMap { Int(exactly: $0) } ?? base.releaseHysteresisCentiC,
            speedPercent: speed.flatMap { Int(exactly: $0) } ?? base.speedPercent,
            stage2Percent: stage2.flatMap { Int(exactly: $0) } ?? base.stage2Percent,
            stage2RiseCentiC: stage2Rise.flatMap { Int(exactly: $0) } ?? base.stage2RiseCentiC,
            temperatureSource: source.flatMap(FanWire.temperatureSource(fromWire:)) ?? base.temperatureSource,
            cpuSkinThresholdCentiC: cpuThreshold.flatMap { Int(exactly: $0) } ?? base.cpuSkinThresholdCentiC,
            cpuSkinHysteresisCentiC: cpuHysteresis.flatMap { Int(exactly: $0) } ?? base.cpuSkinHysteresisCentiC
        )
    }

    /// fanStrategy 线格式映射（定版：0=constantSpeed, 2=twoStage, 3=emergency；
    /// **1 = 退役洞，永久 reserved 不重排不填补**——写入 SMC-PROTOCOL 公共协议段；
    /// 退役值与未知值同语义返回 nil，调用方按值域白名单拒绝）。
    public static func strategy(fromWire raw: UInt64) -> FanStrategy? {
        switch raw {
        case 0: return .constantSpeed
        case 2: return .twoStage
        case 3: return .emergency
        default: return nil
        }
    }

    public static func wireValue(_ strategy: FanStrategy) -> UInt64 {
        switch strategy {
        case .constantSpeed: return 0
        case .twoStage: return 2
        case .emergency: return 3
        }
    }

    /// fanSource 线格式映射（v1.11 T3 定版：0=battery, 1=cpuSkin——独立新键不与
    /// fanStrategy 共表；登记 SMC-PROTOCOL 公共协议段。未知值 nil → 白名单拒绝）。
    public static func temperatureSource(fromWire raw: UInt64) -> FanTemperatureSource? {
        switch raw {
        case 0: return .battery
        case 1: return .cpuSkin
        default: return nil
        }
    }

    public static func wireValue(_ source: FanTemperatureSource) -> UInt64 {
        switch source {
        case .battery: return 0
        case .cpuSkin: return 1
        }
    }
}

/// XPC setFan 键名与值域校验（与 FanPolicy.validated 同源：同一区间常量）。
/// 键全部 UINT64——validFan* 供 XPCServer 臂在 validateRequest 类型白名单之后
/// 做值域校验；缺席（nil）不发键。
public enum FanWireKeys {
    public static let enabled = "fanEnabled"
    public static let strategy = "fanStrategy"
    public static let threshold = "fanThreshold"
    public static let hysteresis = "fanHysteresis"
    public static let speed = "fanSpeed"
    public static let stage2 = "fanStage2"
    public static let stage2Rise = "fanStage2Rise"
    /// v1.11 T3 温度源三键（全 UINT64——R2 P2-6 保全不变量）。
    public static let source = "fanSource"
    public static let cpuThreshold = "fanCpuThreshold"
    public static let cpuHysteresis = "fanCpuHysteresis"
    /// XPC 命令字面量（XPCServer 臂 / DaemonXPCClient 共用）。
    public static let command = "setFan"

    public static func validEnabled(_ raw: UInt64) -> Bool { raw <= 1 }
    public static func validStrategy(_ raw: UInt64) -> Bool { FanWire.strategy(fromWire: raw) != nil }
    public static func validSource(_ raw: UInt64) -> Bool { FanWire.temperatureSource(fromWire: raw) != nil }
    public static func validThreshold(_ raw: UInt64) -> Bool {
        raw >= UInt64(FanPolicy.thresholdRangeCentiC.lowerBound) && raw <= UInt64(FanPolicy.thresholdRangeCentiC.upperBound)
    }
    public static func validHysteresis(_ raw: UInt64) -> Bool {
        raw >= UInt64(FanPolicy.hysteresisRangeCentiC.lowerBound) && raw <= UInt64(FanPolicy.hysteresisRangeCentiC.upperBound)
    }
    public static func validSpeed(_ raw: UInt64) -> Bool {
        raw >= UInt64(FanPolicy.speedRangePercent.lowerBound) && raw <= UInt64(FanPolicy.speedRangePercent.upperBound)
    }
    public static func validStage2(_ raw: UInt64) -> Bool {
        raw >= UInt64(FanPolicy.stage2RangePercent.lowerBound) && raw <= UInt64(FanPolicy.stage2RangePercent.upperBound)
    }
    public static func validStage2Rise(_ raw: UInt64) -> Bool {
        raw >= UInt64(FanPolicy.stage2RiseRangeCentiC.lowerBound) && raw <= UInt64(FanPolicy.stage2RiseRangeCentiC.upperBound)
    }
    public static func validCpuThreshold(_ raw: UInt64) -> Bool {
        raw >= UInt64(FanPolicy.cpuSkinThresholdRangeCentiC.lowerBound) && raw <= UInt64(FanPolicy.cpuSkinThresholdRangeCentiC.upperBound)
    }
    public static func validCpuHysteresis(_ raw: UInt64) -> Bool {
        raw >= UInt64(FanPolicy.cpuSkinHysteresisRangeCentiC.lowerBound) && raw <= UInt64(FanPolicy.cpuSkinHysteresisRangeCentiC.upperBound)
    }
}
