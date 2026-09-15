import Foundation

/// 电池监测门面：数据源注入（评审 A-1：与 WP1 SMCTransport 同款注入缝）+ 快照。
///
/// 纯只读：本类型不写任何 SMC 键（读路径无需 root，M0 实测）。
public struct BatteryMonitor: Sendable {
    private let source: any BatteryPropertySource
    /// 温度回退读取器注入缝（v0.19.8 macOS 27 兼容，方案 §3.1）：ioreg 顶层
    /// `Temperature` 键缺失（macOS 27 消失，M0 spike 实证）时经 SMC TB1T/TB2T
    /// 承接，厘摄氏度；nil = 未挂回退（缺省形态）——快照错误语义与既有完全一致。
    /// Sendable struct：闭包须 `@Sendable`（生产接线捕获不可变连接盒，R1 P2-C）。
    private let smcTemperatureFallbackCentiC: (@Sendable () -> Int?)?

    /// `smcTemperatureFallbackCentiC` 缺省 nil：既有构造点/场景零改动；测试场景
    /// 经本参注入假 reader（CellarCoreCheck 用例 117/118）。
    public init(
        source: any BatteryPropertySource,
        smcTemperatureFallbackCentiC: (@Sendable () -> Int?)? = nil
    ) {
        self.source = source
        self.smcTemperatureFallbackCentiC = smcTemperatureFallbackCentiC
    }

    #if canImport(IOKit)
    /// IOKit 真机数据源（AppleSmartBattery）。构造期不取服务（惰性）——
    /// 服务缺失/读取失败在 `snapshot()` 时以 `BatteryMonitorError` 暴露（非 throws 构造）。
    ///
    /// 温度回退读取器生产接线（仅 IOKit 平台挂载，非 IOKit 兜底平台不挂）：连接盒
    /// 惰性构造 + 单连接缓存（CpuFanMonitor smcClient 生命周期先例）——macOS 26
    /// 机器 `Temperature` 主源恒命中、闭包零调用 = 零 SMC 读调用（G2 钉死为零
    /// 调用而非零开销），27 上避免 1s 采样档每秒 IOServiceOpen。
    public static func makeDefault() -> BatteryMonitor {
        let connection = LazySMCTemperatureConnection()
        return BatteryMonitor(
            source: IOKitBatteryPropertySource(),
            smcTemperatureFallbackCentiC: {
                Self.smcBatteryTemperatureCentiC(client: connection.client())
            }
        )
    }
    #else
    /// 无 IOKit 平台兜底：数据源 `properties()` 恒抛 `.serviceNotFound`。
    /// 兜底平台不挂温度回退（快照错误语义与既有完全一致）。
    public static func makeDefault() -> BatteryMonitor {
        BatteryMonitor(source: UnavailableBatteryPropertySource())
    }
    #endif

    /// 取最新快照：`source.properties()` → parser（timestamp 注入当前时刻）。
    ///
    /// catch-specific 重试（方案 §3.1.2）：仅「缺 `Temperature`」触发回退重解析
    /// 一次（预读 SMC 再传参会使 macOS 26 每快照多一次 SMC 调用——R1 P3 备选
    /// 权衡留痕，弃）；回退未命中/未挂载 → 原错误原样上抛（G3 错误原文不变）。
    public func snapshot() throws -> BatterySnapshot {
        do {
            return try BatterySnapshotParser.parse(source.properties(), timestamp: Date())
        } catch let e as BatteryMonitorError where e == .missingRequiredField("Temperature") {
            guard let fallback = smcTemperatureFallbackCentiC?() else { throw e }
            return try BatterySnapshotParser.parse(
                source.properties(), timestamp: Date(), temperatureFallbackCentiC: fallback
            )
        }
    }

    #if canImport(IOKit)
    /// SMC TB1T/TB2T 温度读值（只读，flt LE °C，CpuSkinSensor 同一 LE 打包定版）：
    /// 双键均值 `Int((mean * 100).rounded())`（R1 P3 舍入钉死）；单只缺失用另一只；
    /// 合理域门 10...90 °C（°C 口径判定，照 CpuSkinSensor.swift 既有纪律——
    /// `temperatureCentiC` 下游直连 ThermalGuard/Calibration 守卫，域外值按该键
    /// 缺失处理，防异常值污染充电控制输入面 R1 P1-B）；连接 nil（构造失败）或
    /// 全无命中 → nil（非抛——回退是尽力而为面，传输故障按键缺失吞掉继续）。
    private static func smcBatteryTemperatureCentiC(client: SMCClient?) -> Int? {
        guard let client else { return nil }
        var readings: [Double] = []
        for key in ["TB1T", "TB2T"] {
            guard let bytes = try? client.read(key),
                  let valueC = FanSMC.decodeTemperatureC(bytes),
                  valueC.isFinite, valueC >= 10, valueC <= 90 else { continue }
            readings.append(Double(valueC))
        }
        guard !readings.isEmpty else { return nil }
        let mean = readings.reduce(0, +) / Double(readings.count)
        return Int((mean * 100).rounded())
    }
    #endif
}

#if canImport(IOKit)
/// 温度回退 SMC 连接盒：惰性构造 + 单连接缓存（CpuFanMonitor smcClient 生命周期
/// 先例）。`SMCClient` 为 Sendable 值类型，NSLock 串行化保护可选槽位的竞态填充；
/// 构造失败（无 AppleSMC 等）→ 本次 nil、下次再试（照 CpuFanMonitor「面板重开
/// 再试」语义）——恒不抛，调用方按「无回退」处理（工单：构造失败 → 恒 nil 不抛）。
private final class LazySMCTemperatureConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: SMCClient?

    /// 取连接（首次调用惰性建立；nil = 构造失败）。
    func client() -> SMCClient? {
        lock.withLock {
            if let storage { return storage }
            let created = try? SMCClient.makeDefault()
            storage = created
            return created
        }
    }
}
#endif
