import Foundation

#if canImport(IOKit)
import IOKit
#endif

// MARK: - 0.20 M1a 合盖拒绝闸（方案 §2.2 合盖管道；工单内嵌 mini-spike 定谳）

/// 合盖状态只读探测 + 拒绝/中止判定（纯只读：不写任何键/属性）。
///
/// **mini-spike 探测结论（2026-09-30，Mac14,6 · macOS 27.0.1 GA 26A434，ioreg 实测）**：
/// - 方案预注册的 `AppleSmartBattery.ClamshellState` **不存在**（该服务全字典 grep
///   clamshell 命中 0——GA 上 AppleSmartBattery 不承载合盖语义）；
/// - **等价字段可得**：`IOPMrootDomain` 服务的 `AppleClamshellState`（Bool）与
///   `AppleClamshellCausesSleep` 在位且**非 root 可读**（用户态 ioreg 直接命中），
///   另有 `IOPMUserIsActive`（Bool）可作屏幕唤醒代理——本类型即挂载该字段；
/// - **作用域（0.20 P1 评审修法 (a)）：合盖闸仅 27 终态生效**（daemon 侧
///   `backendUnavailableTerminal` 同源门控）——26 及更早 clamshell-mode 手动放电/
///   运行续行零变化；每 tick 只读探测保留（DaemonStatus.clamshellClosed 数据源）；
/// - 局限登记（docs/DEVICES.md 键世代表同步）：强字段读取失败（非 GA/未来系统
///   变更）时降级「ext=true ∧ 用户活跃」弱检查——弱检查仅在启动路径生效，运行中
///   30s 粒度中止依赖强字段（nil 时诚实缺席不中止，防误伤开盖息屏的合法放电）。
public struct ClamshellProbe: Sendable {
    public init() {}

    #if canImport(IOKit)
    /// IOPMrootDomain 注册表属性只读（照 IOKitBatteryPropertySource 生命周期纪律：
    /// 每次调用重取服务 → 0 则 nil → defer IOObjectRelease——mach port 泄漏防御）。
    private static func rootDomainBool(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != 0 else { return nil }
        defer { _ = IOObjectRelease(service) }
        guard let cfValue = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        return cfValue as? Bool
    }
    #endif

    /// 合盖状态：true = 合盖（启动拒绝/运行中止判据）；false = 开盖放行；
    /// nil = 字段不可读（降级弱检查，局限见文件头）。
    public func clamshellClosed() -> Bool? {
        #if canImport(IOKit)
        return Self.rootDomainBool("AppleClamshellState")
        #else
        return nil
        #endif
    }

    /// 屏幕唤醒代理（IOPMUserIsActive；弱检查「屏幕唤醒」半边——用户活跃断言在位
    /// ≈ 屏幕唤醒。代理性质如实标注：不精确等价显示态，仅弱检查降级路使用）。
    public func userIsActive() -> Bool? {
        #if canImport(IOKit)
        return Self.rootDomainBool("IOPMUserIsActive")
        #else
        return nil
        #endif
    }
}

/// 合盖闸判定（纯函数——CellarCoreCheck 场景域钉死；daemon 只消费不内联）。
///
/// **作用域（0.20 P1 评审修法 (a)）：仅 27 终态生效**——`gateActive` 由 daemon 侧
/// `backendUnavailableTerminal` 同源判别式传入；26 及更早平台 gateActive 恒 false →
/// 启动放行/运行续行零变化（clamshell-mode 手动放电照旧，26 行为不变量回归钉死）。
public enum ClamshellGate {
    /// 启动拒绝判定（dischargeToLimitLocked 前置段；方案 §2.2「启动前置 clamshell
    /// 闭合 → 拒绝（诚实原因）」）：
    /// - `gateActive == false`（26 及更早）→ 恒放行（26 零变化——P1 评审修法 (a)）；
    /// - `closed == true` → 拒绝（强检查命中）；
    /// - `closed == nil`（强字段不可得）→ 弱检查：ext=true（externalConnected）∧
    ///   屏幕唤醒代理（userActive）——任一明确不满足 → 拒绝；两者均未知 → 放行
    ///   （fail-open + 局限登记：用户手点按钮的 manual 路径屏幕恒唤醒，实际保护
    ///   面不受损；auto 路径局限见 DEVICES.md）；
    /// - `closed == false` → 放行。
    public static func startRejected(
        gateActive: Bool, closed: Bool?, userActive: Bool?, externalConnected: Bool?
    ) -> Bool {
        guard gateActive else { return false }
        if closed == true { return true }
        if closed == nil {
            if externalConnected == false { return true }
            if userActive == false { return true }
        }
        return false
    }

    /// 运行中止判定（维护 tick 30s 粒度；方案 §2.2「运行中 tick 检出 → 中止还原 +
    /// 通知」）：`gateActive == false`（26 及更早）→ 恒不中止；仅强检查——
    /// closed == nil 不中止（息屏 ≠ 合盖，防误伤开盖息屏的合法放电；弱检查局限
    /// 登记 DEVICES.md）。
    public static func shouldAbort(gateActive: Bool, closed: Bool?) -> Bool {
        guard gateActive else { return false }
        return closed == true
    }
}
