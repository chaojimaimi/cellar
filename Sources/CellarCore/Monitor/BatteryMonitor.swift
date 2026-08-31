import Foundation

/// 电池监测门面：数据源注入（评审 A-1：与 WP1 SMCTransport 同款注入缝）+ 快照。
///
/// 纯只读：本类型不写任何 SMC 键（读路径无需 root，M0 实测）。
public struct BatteryMonitor: Sendable {
    private let source: any BatteryPropertySource

    public init(source: any BatteryPropertySource) {
        self.source = source
    }

    #if canImport(IOKit)
    /// IOKit 真机数据源（AppleSmartBattery）。构造期不取服务（惰性）——
    /// 服务缺失/读取失败在 `snapshot()` 时以 `BatteryMonitorError` 暴露（非 throws 构造）。
    public static func makeDefault() -> BatteryMonitor {
        BatteryMonitor(source: IOKitBatteryPropertySource())
    }
    #else
    /// 无 IOKit 平台兜底：数据源 `properties()` 恒抛 `.serviceNotFound`。
    public static func makeDefault() -> BatteryMonitor {
        BatteryMonitor(source: UnavailableBatteryPropertySource())
    }
    #endif

    /// 取最新快照：`source.properties()` → parser（timestamp 注入当前时刻）。
    public func snapshot() throws -> BatterySnapshot {
        try BatterySnapshotParser.parse(source.properties(), timestamp: Date())
    }
}