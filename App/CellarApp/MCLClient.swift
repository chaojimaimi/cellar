import CellarCore
import Darwin
import Foundation
import ObjectiveC
import os

// MARK: - 原生限充读回客户端（0.20 WP3 §4；Tools/spike-ga-jxa-set.swift GET 路径
// 产品化——S3 §11.6.2 定谳：getMCLLimitWithError 返回当前原生限充值且与系统设置
// UI 一致、ad-hoc 无签名进程无客户端校验拦截、JXA 载体退役 Swift 载体唯一）

/// PowerUI 框架 GET 读回（只读——本类型**零写面**，set 通道 0.21 独立子进程形态）。
///
/// 生命周期纪律（照 0.19.10 daemon smcClient 模式）：
/// - **类缺席 = 平台终态 sticky**（`objc_getClass` nil——<26/未来系统删除类族，
///   进程内不自愈，进程重启唯一清除路径）；
/// - **实例级失败 = 自愈重建**（alloc/init/读调用失败——连接可能失效，实例丢弃，
///   下次调用重建再试，不 sticky）。
///
/// 线程纪律：`readLimit()` 内部持 NSLock 串行化 ObjC 调用（实例态保护），**调用
/// 方必须在后台线程**（Task.detached 包裹——CpuFanMonitor 先例，主线程永不阻塞；
/// dlopen/ObjC 消息派发为同步调用）。
final class MCLClient: @unchecked Sendable {
    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "mcl-readback")

    private let lock = NSLock()
    /// PowerUISmartChargeClient 实例（nil = 未建/上次失败——下次调用重建自愈）。
    private var instance: AnyObject?
    /// 类缺席 sticky（平台终态——进程内不重探）。
    private(set) var classMissing = false

    /// 读回通道可用性（类在位；实例级失败不改变本判定——重建自愈）。
    /// 持锁读（M2 评审 P2-1：classMissing 写侧持锁，本读必须同锁——@unchecked Sendable 下的手工同步点）。
    var readbackAvailable: Bool { lock.withLock { !classMissing } }

    // objc_msgSend 按签名特化（dlsym 原始指针 → bitcast；Swift 直引 variadic
    // 符号被标 unavailable——spike 同款）。签名源自 spike-ga-jxa-methods.swift
    // 全量枚举（§11.6）：getMCLLimitWithError: C24@0:8^@16 — ret uchar。
    private typealias MsgSendIdSel = @convention(c) (AnyObject, Selector) -> AnyObject
    private typealias MsgSendIdStr = @convention(c) (AnyObject, Selector, NSString) -> AnyObject
    private typealias MsgSendUCharErr = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> UInt8

    private static let selAlloc = sel_registerName("alloc")
    private static let selInitClient = sel_registerName("initWithClientName:")
    private static let selGetMCL = sel_registerName("getMCLLimitWithError:")

    private static let msgSendIdSel: MsgSendIdSel = unsafeBitCast(
        dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend"), to: MsgSendIdSel.self)
    private static let msgSendIdStr: MsgSendIdStr = unsafeBitCast(
        dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend"), to: MsgSendIdStr.self)
    private static let msgSendUCharErr: MsgSendUCharErr = unsafeBitCast(
        dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend"), to: MsgSendUCharErr.self)

    /// 框架路径（spike 同款：PowerUI 为主类宿主；BatteryCenter 兜底拉起依赖链）。
    private nonisolated static let frameworkPaths = [
        "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI",
        "/System/Library/PrivateFrameworks/BatteryCenter.framework/BatteryCenter",
    ]

    /// 读回当前原生限充（阻塞——后台线程调用）。nil = 类缺席/实例化失败/调用失败
    /// /非法值（调用方按「读回不可用」如实呈现，不猜测语义）。
    func readLimit() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if classMissing { return nil }
        if instance == nil {
            for path in Self.frameworkPaths {
                _ = dlopen(path, RTLD_NOW)   // dlopen 幂等（dyld 缓存）；已加载零开销
            }
            guard let cls = objc_getClass("PowerUISmartChargeClient") as AnyObject? else {
                // 类缺席 = 平台终态 sticky（进程重启唯一清除路径——0.19.10 WP-A 先例）。
                classMissing = true
                Self.log.info("PowerUISmartChargeClient 类缺席——读回通道 sticky 停用")
                return nil
            }
            let alloced = Self.msgSendIdSel(cls, Self.selAlloc)
            guard !(alloced is NSNull), let created = Self.msgSendIdStr(alloced, Self.selInitClient, "Cellar" as NSString) as AnyObject? else {
                // 实例化失败（类在位但 alloc/init 异常）→ 不置 sticky，下次重建自愈。
                Self.log.info("MCL 客户端实例化失败——下次调用重建（自愈）")
                return nil
            }
            instance = created
        }
        guard let inst = instance else { return nil }
        var error: Unmanaged<NSError>?
        let value = Self.msgSendUCharErr(inst, Self.selGetMCL, &error)
        if error != nil {
            // 调用失败 → 丢弃实例（连接可能失效），下次重建（0.19.10 smcClient 自愈）。
            let e = error!.takeUnretainedValue()
            Self.log.info("MCL 读回调用失败（\(e.domain, privacy: .public) Code=\(e.code))——实例已丢弃重建")
            instance = nil
            return nil
        }
        // 0 = 非法值（原生限充域 60–100；0 从未实测出现——防御面不猜测语义）。
        guard value > 0 else {
            Self.log.info("MCL 读回非法值 0——按不可用处理")
            return nil
        }
        return Int(value)
    }
}
