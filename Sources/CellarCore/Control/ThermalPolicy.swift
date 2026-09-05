import Foundation

// MARK: - Phase 5 v1.5 充电热阈值可配置化（方案 §2.1）—— CellarCore 纯函数/纯值层

/// 充电热暂停策略（daemon 持久化在 policy.json 的 `DaemonPolicy.thermal` 可选字段，
/// 与 fan/calibrationSchedule 并列、互不读写——UD-6 两套配置分离原则落地面）。
///
/// 配置模型 = 暂停点 + 滞回，恢复点派生（UD-2）：`resumeCentiC = pauseCentiC −
/// hysteresisCentiC`——不存独立 resumeC，消除「resume ≥ pause」非法组合面。
/// 形态照 FanPolicy（Int 厘摄氏度 + 区间常量 + validated），与快照
/// `temperatureCentiC: Int` 同精度。
public struct ThermalPolicy: Codable, Equatable, Sendable {
    /// 暂停阈值（厘摄氏度；3500...4500）。上限钳制 45°C = 行业充电窗口上沿——
    /// **保证保护不可被误配关闭**（fail-safe 方向，R-1）。
    public var pauseCentiC: Int
    /// 滞回幅度（厘摄氏度；100...800）。默认 300 = 3°C 滞回（phase4-wp1 设计依据不变）。
    public var hysteresisCentiC: Int

    public init(pauseCentiC: Int, hysteresisCentiC: Int) {
        self.pauseCentiC = pauseCentiC
        self.hysteresisCentiC = hysteresisCentiC
    }

    /// 默认策略（4000/300 = 40.00°C 暂停 / 37.00°C 恢复）。⚠️ 注释钉死：与
    /// `ThermalGuard.pauseC = 40.0` / `resumeC = 37.0` 常量**同源**（UD-3 失败安全
    /// 第①级——常量不删除，热守卫-13 常量不变式场景继续钉死；guarded 默认参数
    /// 路径与常量逐位等价）。
    public static let `default` = ThermalPolicy(pauseCentiC: 4000, hysteresisCentiC: 300)

    /// 值域（与 XPC 线格式 validTherm* 同源——两边共用同一区间常量，照 FanPolicy
    /// 先例：XPCServer 值域校验与 validated 同源，CellarCoreCheck 同源测试）。
    public static let pauseRangeCentiC = 3500...4500
    public static let hysteresisRangeCentiC = 100...800

    /// 恢复点（派生计算属性，UD-2）：pause − hysteresis。默认 4000 − 300 = 3700。
    public var resumeCentiC: Int { pauseCentiC - hysteresisCentiC }

    /// 校验：任何字段越界 → nil（整包拒——绝不半合法，与 FanPolicy.validated 同
    /// 纪律）。⚠️ **策略对象自身整包拒**与 policy.json 字段级「仅丢字段」分层
    ///（UD-3 第②级）：字段解码成功但本函数 nil → PolicyStore.load 丢整字段 +
    /// Logger error 回落 default（非关键配置不连累 mode/限值/风扇）。
    public static func validated(pauseCentiC: Int, hysteresisCentiC: Int) -> ThermalPolicy? {
        guard pauseRangeCentiC.contains(pauseCentiC) else { return nil }
        guard hysteresisRangeCentiC.contains(hysteresisCentiC) else { return nil }
        return ThermalPolicy(pauseCentiC: pauseCentiC, hysteresisCentiC: hysteresisCentiC)
    }
}

/// 充电热暂停状态视图（Phase 5 v1.5；doctor 检查 13 与 App 侧共享的强类型形态，
/// 照 FanStatus 在 FanPolicy.swift 的先例——本域无运行时状态，两字段即配置回显）。
public struct ThermalStatus: Codable, Equatable, Sendable {
    /// 暂停阈值（厘摄氏度；配置回显）。
    public let pauseCentiC: Int
    /// 滞回幅度（厘摄氏度；配置回显；恢复点 = pause − hysteresis 派生）。
    public let hysteresisCentiC: Int

    public init(
        pauseCentiC: Int = ThermalPolicy.default.pauseCentiC,
        hysteresisCentiC: Int = ThermalPolicy.default.hysteresisCentiC
    ) {
        self.pauseCentiC = pauseCentiC
        self.hysteresisCentiC = hysteresisCentiC
    }
}

// MARK: - XPC 线格式（照 FanWire 全套先例：键全 UINT64，缺席 = 保持现值）

/// setThermal 请求载荷（缺席字段 = 保持现值；makeMessage 内 nil 不发键）。
public struct ThermalWire: Equatable, Sendable {
    public var pause: UInt64?
    public var hysteresis: UInt64?

    public init(pause: UInt64? = nil, hysteresis: UInt64? = nil) {
        self.pause = pause
        self.hysteresis = hysteresis
    }

    /// 便捷构造：从具体策略发全键（照 CalibrationScheduleWire.init(_:) 先例；
    /// 缺席保持是 daemon 侧语义，下发方不依赖）。
    public init(_ policy: ThermalPolicy) {
        self.init(
            pause: UInt64(policy.pauseCentiC),
            hysteresis: UInt64(policy.hysteresisCentiC)
        )
    }

    /// 合并进现有策略（缺席保持）：任何字段非 nil 时应用；结果经
    /// `ThermalPolicy.validated` 强校验（非法 → nil，不半合法）。
    public func mergedPolicy(base: ThermalPolicy) -> ThermalPolicy? {
        ThermalPolicy.validated(
            pauseCentiC: pause.flatMap { Int(exactly: $0) } ?? base.pauseCentiC,
            hysteresisCentiC: hysteresis.flatMap { Int(exactly: $0) } ?? base.hysteresisCentiC
        )
    }
}

/// XPC setThermal 键名与值域校验（与 ThermalPolicy.validated 同源：同一区间常量）。
/// 键全部 UINT64——validTherm* 供 XPCServer 臂在 validateRequest 类型白名单之后
/// 做值域校验；缺席（nil）不发键。
public enum ThermalWireKeys {
    public static let pause = "thermPauseCentiC"
    public static let hysteresis = "thermHysteresisCentiC"
    /// XPC 命令字面量（XPCServer 臂 / DaemonXPCClient 共用；独立命令——不并入
    /// setFan/setCalibrationSchedule，UD-6 两套配置分离）。
    public static let command = "setThermal"

    public static func validPause(_ raw: UInt64) -> Bool {
        raw >= UInt64(ThermalPolicy.pauseRangeCentiC.lowerBound)
            && raw <= UInt64(ThermalPolicy.pauseRangeCentiC.upperBound)
    }
    public static func validHysteresis(_ raw: UInt64) -> Bool {
        raw >= UInt64(ThermalPolicy.hysteresisRangeCentiC.lowerBound)
            && raw <= UInt64(ThermalPolicy.hysteresisRangeCentiC.upperBound)
    }
}
