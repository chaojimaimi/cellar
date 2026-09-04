import CellarCore
import Foundation
import IOKit.ps

/// IOPS 电源事件订阅（WP5 §2.4 菜单栏图标插拔电即时化：数据源 = App 侧实时电源态，
/// 不再受 daemon 30s tick 与轮询档位约束）。
///
/// 实现要点（评审 P1-4）：
/// - `IOPSNotificationCreateRunLoopSource` 为 create-rule 所有权：`takeRetainedValue()`
///   交 ARC 持有，本对象释放 = CFRunLoopRemoveSource + ARC 自动 CFRelease（deinit）。
/// - C 函数指针回调不能捕获 self：context 经 `Unmanaged` 盒子传递（本对象持有盒子，
///   回调期内指针恒有效；回调内 `takeUnretainedValue` 取回）。
/// - 事件源挂主 RunLoop：回调在主线程派发 → `MainActor.assumeIsolated` 入 actor。
/// - ≥1s 节流 + 电源态未变 no-op（IOPS 对电量百分比变化也触发）——两条丢弃路径
///   与读 nil 均置一次性延迟复查（1.5s 重跑，F4 自愈：IOPS 通知先行于注册表更新
///   的竞态由复查覆盖）；`apply(powerOverride:)` 无条件执行（纯 @Published 赋值
///   与 XPC 无冲突），`refreshNow()` 保留 busy 门（在途不抢，内部自带 guard）。
///
/// macOS 26 键位实证（2026-09-02 实测）：运行时字典已无 ExternalConnected 键，
/// 外接态以 `Power Source State == "AC Power"` 判定（旧 IOPSKeys.h 常量值语义，
/// 实测 Battery Power 形态）；充电态取 `Is Charging`（CFBoolean 桥接 NSNumber）。
@MainActor
final class PowerSourceMonitor {
    /// 弱引用控制器（回调经盒子取回；控制器先亡则事件丢弃——源随本对象释放）。
    weak var controller: StatusController?

    /// create-rule 所有权事件源（属性持有）。
    /// ⚠️ nonisolated(unsafe)：deinit（非隔离）需摘源；属性仅在主 actor 方法或
    /// deinit 中访问（单一持有者，无数据竞争面——StatusController 同款模式）。
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    /// C 回调 context 盒子（本对象持有 = 回调期间不透明指针恒有效）。
    private var callbackBox: CallbackBox?
    /// 最近事件时刻（≥1s 节流基准）。
    private var lastEventAt = Date.distantPast
    /// 最近 override（电源态未变 no-op 基准）。
    private var lastOverride: PowerOverride?
    /// 延迟复查旗标（F4：一次性——置位后仅调度一次 1.5s 复查；复查执行前清除，
    /// 防事件风暴叠排与复查自循环）。
    private var pendingRecheck = false

    /// 安装订阅（幂等：重复调用直接返回）。安装即种子一次——首图标态直接用实时
    /// 电源数据，不等首个事件。
    func install() {
        guard runLoopSource == nil else { return }
        let box = CallbackBox()
        box.monitor = self
        callbackBox = box
        let context = Unmanaged.passUnretained(box).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(Self.iopsCallback, context)?.takeRetainedValue() else {
            // 创建失败（极边缘环境）：回退 daemonStatus 快照数据源，不告警不崩溃。
            callbackBox = nil
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        handlePowerSourceEvent()
    }

    deinit {
        // 先摘源再放盒子：摘源后主 RunLoop 不再派发回调，context 指针安全
        // （ARC 对 create-rule 源的释放随属性析构）。
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    /// 电源事件处理（主 RunLoop 派发 → assumeIsolated 主 actor，v1.2 走查批 F4
    /// 自愈改造）：`apply(powerOverride:)` **无条件执行**（纯 @Published 主线程
    /// 赋值——图标即时翻转数据源，与 XPC 控制无冲突，busy 门拦它没有道理；
    /// `refreshNow()` 保留 busy 门控（在途不抢 XPC，内部自带 guard））。
    /// ≥1s 节流 → 电源态未变 no-op → 更新 override + 触发一次刷新。
    /// 三条丢弃路径（节流拦截 / 读 nil / 与 lastOverride 相同——IOPS 通知先行于
    /// 注册表更新的竞态）→ 置一次性 pendingRecheck 旗标 + 1.5s 后重跑一次
    /// （1.5s > 1s 节流窗保证复查可过节流；复查仍无变化则终止——旗标防循环）。
    private func handlePowerSourceEvent(isRecheck: Bool = false) {
        guard let controller else { return }
        let now = Date()
        guard now.timeIntervalSince(lastEventAt) >= 1 else {
            scheduleRecheckIfNeeded(fromRecheck: isRecheck)
            return
        }
        lastEventAt = now
        guard let override = Self.readPowerOverride() else {
            scheduleRecheckIfNeeded(fromRecheck: isRecheck)
            return
        }
        guard override != lastOverride else {
            scheduleRecheckIfNeeded(fromRecheck: isRecheck)
            return
        }
        lastOverride = override
        controller.apply(powerOverride: override)
        controller.refreshNow()
    }

    /// 延迟复查调度（F4 §2.3 一次性旗标防循环）：复查发起方（isRecheck == true）
    /// 不再重排——「复查仍无变化则终止」；旗标在复查执行前清除，正常事件流
    /// 不受残留影响。
    private func scheduleRecheckIfNeeded(fromRecheck isRecheck: Bool) {
        guard !isRecheck, !pendingRecheck else { return }
        pendingRecheck = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            self.pendingRecheck = false
            self.handlePowerSourceEvent(isRecheck: true)
        }
    }

    /// C 回调（静态属性置类作用域：可访问类私有成员）。context = 盒子不透明指针，
    /// 回调在主 RunLoop 派发——MainActor.assumeIsolated 的隔离证明成立。
    /// 类型按本 SDK 导入形态内联声明（typedef 名不导出）。
    private static let iopsCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
        guard let context else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
            box.monitor?.handlePowerSourceEvent()
        }
    }

    /// IOPS 实时电源态读取（非 root 可用；任何读取失败 → nil → 保持既有
    /// daemonStatus 数据源——不误报不崩溃）。非隔离（不触碰 actor 状态）。
    /// 描述字典为**借用引用**（系统持有）：takeUnretainedValue，不可 takeRetainedValue。
    private static func readPowerOverride() -> PowerOverride? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else { return nil }
        var externalConnected: Bool?
        var isCharging: Bool?
        for index in 0..<CFArrayGetCount(sources) {
            guard let rawSource = CFArrayGetValueAtIndex(sources, index) else { continue }
            let source = unsafeBitCast(rawSource, to: CFTypeRef.self)
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() else { continue }
            let dictionary = description as NSDictionary
            if let state = dictionary["Power Source State"] as? String {
                externalConnected = state == "AC Power"
            }
            if let charging = dictionary["Is Charging"] as? NSNumber {
                isCharging = charging.boolValue
            }
        }
        guard let externalConnected, let isCharging else { return nil }
        return PowerOverride(externalConnected: externalConnected, isCharging: isCharging)
    }
}

/// C 回调 context 盒子：不透明指针 → 对象（C 回调不可 ARC 捕获 self；盒子由
/// monitor 持有，回调期恒有效）。弱引用 monitor——控制器先亡时事件丢弃。
@MainActor
private final class CallbackBox {
    weak var monitor: PowerSourceMonitor?
}