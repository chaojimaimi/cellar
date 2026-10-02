import Darwin
import Foundation
import ObjectiveC

// MARK: - 0.21.0 §1.2/§1.3/§1.5 MCL 读回 doctor 探测（只读 GET 面）
//
// 与 App 侧 MCLClient（App/CellarApp/MCLClient.swift，GET+SET 产品化双面）的关系：
// 本类型是 **doctor CLI 专用的一shot只读探针**——doctor 为一次性进程，无 sticky/
// 实例自愈需求；载体论证与签名同源（Tools/spike-ga-jxa-get 路径，S3 §11.6.2 定谳：
// getMCLLimitWithError 返回当前原生限充值、ad-hoc 无签名进程无客户端校验拦截）。
// 只读契约（doctor 全线「不写任何键」）——set 面不入本类型。
//
// 探测必须在 CLI 用户会话执行（DoctorCommand 组装——非 root 读级可用，S3 实证）；
// 失败全部结构化落入 MCLDoctorProbe（检查 17 set 可用分支 / 检查 19 临时放开残留
// / 检查 20 关断残留的数据源），绝不静默。

/// 探测结果（DoctorInputs.mclProbe 载荷；nil limit ∧ readable=false = 通道缺席）。
public struct MCLDoctorProbe: Equatable, Sendable {
    /// GET 通道可读（类在位 + 读调用成功）。
    public let readable: Bool
    /// 当前原生限充读回值（readable=false 时 nil）。
    public let limit: Int?
    /// 失败详情（类缺席/实例化失败/读调用失败——检查面如实呈现，不猜测语义）。
    public let failureDetail: String?

    public init(readable: Bool, limit: Int?, failureDetail: String?) {
        self.readable = readable
        self.limit = limit
        self.failureDetail = failureDetail
    }
}

/// 一shot只读探测执行体（dlsym objc_msgSend 原始指针 + bitcast——Swift 直引
/// variadic 符号 unavailable，spike 同款；签名源自 spike-ga-jxa-methods.swift
/// 全量枚举：getMCLLimitWithError: C24@0:8^@16 — ret uchar）。
public enum MCLReadbackProbe {
    /// 框架路径（PowerUI 为主类宿主；BatteryCenter 兜底拉起依赖链——App MCLClient 同款）。
    private static let frameworkPaths = [
        "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI",
        "/System/Library/PrivateFrameworks/BatteryCenter.framework/BatteryCenter",
    ]

    private typealias MsgSendIdSel = @convention(c) (AnyObject, Selector) -> AnyObject
    private typealias MsgSendIdStr = @convention(c) (AnyObject, Selector, NSString) -> AnyObject
    private typealias MsgSendUCharErr = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> UInt8

    /// 执行只读探测（阻塞 ObjC 调用——DoctorCommand 已在命令行同步上下文）。
    public static func probe() -> MCLDoctorProbe {
        for path in frameworkPaths {
            _ = dlopen(path, RTLD_NOW)   // dlopen 幂等（dyld 缓存）
        }
        guard let cls = objc_getClass("PowerUISmartChargeClient") as AnyObject? else {
            return MCLDoctorProbe(
                readable: false, limit: nil,
                failureDetail: "PowerUISmartChargeClient 类缺席（平台终态——set 路径不可用）"
            )
        }
        guard let msgSendPtr = dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend") else {
            return MCLDoctorProbe(readable: false, limit: nil, failureDetail: "objc_msgSend 符号缺失")
        }
        let msgSendIdSel = unsafeBitCast(msgSendPtr, to: MsgSendIdSel.self)
        let msgSendIdStr = unsafeBitCast(msgSendPtr, to: MsgSendIdStr.self)
        let msgSendUCharErr = unsafeBitCast(msgSendPtr, to: MsgSendUCharErr.self)
        let alloced = msgSendIdSel(cls, sel_registerName("alloc"))
        guard let inst = msgSendIdStr(alloced, sel_registerName("initWithClientName:"), "Cellar" as NSString) as AnyObject? else {
            return MCLDoctorProbe(readable: false, limit: nil, failureDetail: "MCL 客户端实例化失败")
        }
        var error: Unmanaged<NSError>?
        let value = msgSendUCharErr(inst, sel_registerName("getMCLLimitWithError:"), &error)
        if let e = error?.takeUnretainedValue() {
            return MCLDoctorProbe(
                readable: false, limit: nil,
                failureDetail: "getMCLLimitWithError 调用失败（\(e.domain) Code=\(e.code)）"
            )
        }
        guard value > 0 else {
            // 0 = 非法值（原生限充域 60–100）——诚实呈现，不猜测语义（App MCLClient 同纪律）。
            return MCLDoctorProbe(readable: false, limit: nil, failureDetail: "MCL 读回非法值 0")
        }
        return MCLDoctorProbe(readable: true, limit: Int(value), failureDetail: nil)
    }
}
