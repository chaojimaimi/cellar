/// 电池属性数据源抽象（评审 A-1：与 WP1 SMCTransport 同款注入缝，可被 mock）。
///
/// - 实现须线程安全（可能被并发调用）；IOKit 实现每次调用重取服务、即取即放。
/// - `properties()` 返回 AppleSmartBattery 注册表属性字典（原始桥接，未经解析）。
public protocol BatteryPropertySource: Sendable {
    func properties() throws -> [String: Any]
}

#if canImport(IOKit)
import Foundation
import IOKit

/// IOKit 真机数据源：AppleSmartBattery 服务的注册表属性（只读，无需 root，M0 实测）。
///
/// 生命周期（评审 E-1）：每次 `properties()` 重取服务 → 0 则 `.serviceNotFound` →
/// `defer { IOObjectRelease(service) }`（mach port 泄漏防御，WP1 IOKitSMCTransport 先例）
/// → `IORegistryEntryCreateCFProperties` kr≠0 → `.readFailed(kr:)`；
/// kr=0 但桥接 `[String: Any]` 失败（现实不可达）→ `.readFailed(kr: 0)` 封口。
public struct IOKitBatteryPropertySource: BatteryPropertySource, Sendable {
    private static let serviceName = "AppleSmartBattery"

    public init() {}

    public func properties() throws -> [String: Any] {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(Self.serviceName)
        )
        guard service != 0 else { throw BatteryMonitorError.serviceNotFound }
        defer { _ = IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS else { throw BatteryMonitorError.readFailed(kr: kr) }
        // Create 语义 +1：takeRetainedValue 承接所有权，桥接为 Swift 字典后由 Swift 管理。
        guard let props, let dict = props.takeRetainedValue() as? [String: Any] else {
            // kr=0 但桥接失败（含 props 为空）：现实不可达，封口为 readFailed(kr: 0)（规格 §3.1）。
            throw BatteryMonitorError.readFailed(kr: 0)
        }
        return dict
    }
}
#else
/// 无 IOKit 平台（Linux 等）兜底：只读监测不可用，`properties()` 恒抛 `.serviceNotFound`。
public struct UnavailableBatteryPropertySource: BatteryPropertySource, Sendable {
    public init() {}

    public func properties() throws -> [String: Any] {
        throw BatteryMonitorError.serviceNotFound
    }
}
#endif