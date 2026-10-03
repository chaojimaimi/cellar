#!/usr/bin/env swift
// Cellar 0.21.0 B 路 mini-spike（方案 §1.4）——PowerUIChargingController set 面探测。
// 背景与决策树：S3 已 GO 的默认路线 = SmartChargeClient（setMCLLimit:error:，产品化于
// App/CellarApp/MCLClient.swift）；B 路（PowerUIChargingController）仅在判据 ①②③ 显示
// 实质增益时升级为主路线，否则登记留档（SMC-NOTES）。本工具**入库不执行**——由用户
// 真机运行（R1/R2 门禁与崩溃隔离由人工把控；写入臂显式子命令，默认只读）。
//
// 载体惯例：与 Tools/spike-ga-jxa-set.swift 同款——dlsym objc_msgSend 原始指针 +
// bitcast（Swift 直引 variadic 符号 unavailable）；PowerUI 为主类宿主、BatteryCenter
// 兜底拉起依赖链。
//
// API 面（方案 §1.4 钉定；签名在位未知——本工具运行时 method_getTypeEncoding 全量
// 枚举 + 按编码分发，不猜测）：
//   PowerUIChargingController +sharedInstance
//   setChargeLimitTo:forLimitType:            （写入臂——limitType 语义未知，默认 0）
//   clearAllChargeLimits                      （判据③ 副作用与恢复可控性）
//   loadChargeLimitTokenForPreferenceKey:     （token 读面）
//   读回对照 = PowerUISmartChargeClient getMCLLimitWithError:（S3 已定谳的已知-good 面）
//
// 用法：
//   swift Tools/spike-0.21-bpath.swift info          # 只读：类/方法枚举 + sharedInstance + 两面读回对照
//   swift Tools/spike-0.21-bpath.swift token <key>   # 只读：loadChargeLimitTokenForPreferenceKey:
//   swift Tools/spike-0.21-bpath.swift set <n>       # 写入臂①：setChargeLimitTo: n + 两面读回（判据①②）
//   swift Tools/spike-0.21-bpath.swift set <n> <t>   # 写入臂①：显式 limitType（默认 0——语义未知照实登记）
//   swift Tools/spike-0.21-bpath.swift clear         # 写入臂③：clearAllChargeLimits + 读回 + 恢复指引
//   swift Tools/spike-0.21-bpath.swift c5            # 判据⑤ 状态装配：set 80 + 指引（域 75 对照观察，见下）
//
// 判据输出（方案 §1.4 钉死 ①-⑤，kv 行与 spike-ga-jxa-set.swift 同格式）：
//   ① 可写性：set 85 → 两面读回 85（criterion1）
//   ② 80 下限是否同样存在：set <80（如 75）→ 拒绝/异常形态照实记录（criterion2）
//   ③ clearAllChargeLimits 副作用与恢复可控性：clear 后读回 + setMCLLimit 恢复验证（criterion3）
//   ④ 与 SmartChargeClient 冲突性：B 路写后 S3 面读回一致性（criterion4）
//   ⑤ MCL 80 ∧ 域 75 并存时的实际停充点：本工具只装配状态（MCL=80），域值在
//      /var/root/Library/Preferences/com.apple.smartcharging.topoffprotection（root 域，
//      用户态不可读）——**停充点为充电行为观察项**：需 daemon topoff 承载 75 ∧ 本工具
//      set 80 后插电观察实际停充百分比（§7.4 走查判定项联动；criterion5 输出装配结果 + 观察指引）

import Darwin
import Foundation
import ObjectiveC

// ── 框架加载 ────────────────────────────────────────────────────────
let fwPaths = [
    "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI",
    "/System/Library/PrivateFrameworks/BatteryCenter.framework/BatteryCenter",
]
for p in fwPaths { _ = dlopen(p, RTLD_NOW) }

// ── objc_msgSend 按签名特化（dlsym 原始指针 → bitcast；Swift 直引 variadic 符号
//    被标 unavailable——spike-ga-jxa-set.swift 同款）─────────────────────────
let mainHandle = dlopen(nil, RTLD_LAZY)!
guard let msgSendPtr = dlsym(mainHandle, "objc_msgSend") else {
    print("bpath.verdict=objc_msgSend-not-found")
    exit(3)
}
typealias MsgSendIdSel = @convention(c) (AnyObject, Selector) -> AnyObject
typealias MsgSendVoidIntInt = @convention(c) (AnyObject, Selector, Int32, Int32) -> Void
typealias MsgSendVoidLongLong = @convention(c) (AnyObject, Selector, Int64, Int64) -> Void
typealias MsgSendBoolIntInt = @convention(c) (AnyObject, Selector, Int32, Int32) -> Bool
typealias MsgSendBoolLongLong = @convention(c) (AnyObject, Selector, Int64, Int64) -> Bool
typealias MsgSendVoidNoArg = @convention(c) (AnyObject, Selector) -> Void
typealias MsgSendIdStr = @convention(c) (AnyObject, Selector, NSString) -> AnyObject
typealias MsgSendUCharErr = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> UInt8
typealias MsgSendBoolErr = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Bool
typealias MsgSendBoolUCharErr = @convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Bool

let msgSendIdSel = unsafeBitCast(msgSendPtr, to: MsgSendIdSel.self)
let msgSendVoidIntInt = unsafeBitCast(msgSendPtr, to: MsgSendVoidIntInt.self)
let msgSendVoidLongLong = unsafeBitCast(msgSendPtr, to: MsgSendVoidLongLong.self)
let msgSendBoolIntInt = unsafeBitCast(msgSendPtr, to: MsgSendBoolIntInt.self)
let msgSendBoolLongLong = unsafeBitCast(msgSendPtr, to: MsgSendBoolLongLong.self)
let msgSendVoidNoArg = unsafeBitCast(msgSendPtr, to: MsgSendVoidNoArg.self)
let msgSendIdStr = unsafeBitCast(msgSendPtr, to: MsgSendIdStr.self)
let msgSendUCharErr = unsafeBitCast(msgSendPtr, to: MsgSendUCharErr.self)
let msgSendBoolErr = unsafeBitCast(msgSendPtr, to: MsgSendBoolErr.self)
let msgSendBoolUCharErr = unsafeBitCast(msgSendPtr, to: MsgSendBoolUCharErr.self)

// ── 已知-good 读回面（S3 定谳）：PowerUISmartChargeClient ────────────
func classAsAny(_ p: Any) -> AnyObject { p as AnyObject }
guard let s3Cls = objc_getClass("PowerUISmartChargeClient") else {
    print("bpath.verdict=smartcharge-class-not-found")
    exit(3)
}
let s3Alloc = msgSendIdSel(classAsAny(s3Cls), sel_registerName("alloc"))
guard let s3 = msgSendIdStr(s3Alloc, sel_registerName("initWithClientName:"), "Cellar" as NSString) as AnyObject? else {
    print("bpath.verdict=smartcharge-init-failed")
    exit(3)
}
let selS3Get = sel_registerName("getMCLLimitWithError:")
let selS3Set = sel_registerName("setMCLLimit:error:")
let selS3Supported = sel_registerName("isMCLSupported")

func s3Readback() -> Int? {
    var err: Unmanaged<NSError>?
    let v = msgSendUCharErr(s3, selS3Get, &err)
    if err != nil || v == 0 { return nil }
    return Int(v)
}

func s3Set(_ n: Int) -> (ok: Bool, error: String) {
    var err: Unmanaged<NSError>?
    let ok = msgSendBoolUCharErr(s3, selS3Set, UInt8(n), &err)
    let e = err?.takeUnretainedValue()
    return (ok, e.map { "\($0.domain) Code=\($0.code) \($0.localizedDescription)" } ?? "none")
}

// ── B 路类：PowerUIChargingController ───────────────────────────────
guard let bCls = objc_getClass("PowerUIChargingController") else {
    print("bpath.verdict=chargingcontroller-class-not-found")
    print("criterion1.verdict=inconclusive(类缺席)")
    exit(3)
}
print("bpath.class_found=yes")
print("bpath.class=PowerUIChargingController")

// 方法枚举 + 编码抓取（method_getTypeEncoding——运行时签名事实源，不猜测）。
func encodingOf(_ cls: AnyObject, _ name: String, meta: Bool) -> String? {
    var count: UInt32 = 0
    let list = meta
        ? class_copyMethodList(object_getClass(cls)!, &count)
        : class_copyMethodList(unsafeBitCast(cls, to: AnyClass.self), &count)
    defer { if list != nil { free(list!) } }
    for j in 0..<Int(count) {
        let m = list![j]
        if String(cString: sel_getName(method_getName(m))) == name {
            guard let enc = method_getTypeEncoding(m) else { continue }
            return String(cString: enc)
        }
    }
    return nil
}

let selShared = sel_registerName("sharedInstance")
let selSetLimitTo = sel_registerName("setChargeLimitTo:forLimitType:")
let selClearAll = sel_registerName("clearAllChargeLimits")
let selLoadToken = sel_registerName("loadChargeLimitTokenForPreferenceKey:")

print("bpath.enc.sharedInstance=\(encodingOf(classAsAny(bCls), "sharedInstance", meta: true) ?? "ABSENT")")
print("bpath.enc.setChargeLimitTo=\(encodingOf(classAsAny(bCls), "setChargeLimitTo:forLimitType:", meta: false) ?? "ABSENT")")
print("bpath.enc.clearAllChargeLimits=\(encodingOf(classAsAny(bCls), "clearAllChargeLimits", meta: false) ?? "ABSENT")")
print("bpath.enc.loadChargeLimitToken=\(encodingOf(classAsAny(bCls), "loadChargeLimitTokenForPreferenceKey:", meta: false) ?? "ABSENT")")
print("bpath.s3.isMCLSupported=\(msgSendBoolErr(s3, selS3Supported, nil))")

// +sharedInstance（类方法——msgSend 直打 Class）。
let shared = msgSendIdSel(classAsAny(bCls), selShared)
if shared is NSNull {
    print("bpath.verdict=sharedinstance-failed")
    exit(3)
}
print("bpath.sharedInstance=ok")

/// 双面读回对照（判据④ 输入）：B 路写后 S3 面读回一致性。
func dualReadback(tag: String) {
    print("\(tag).readback.s3_getMCLLimit=\(s3Readback().map(String.init) ?? "nil")")
}

/// 按运行时编码分发写入（仅覆盖合理形态：4 字节整型 ×2 / 8 字节整型 ×2 ×
/// Void|BOOL 返回；其余形态如实报 unsupported——不猜测）。
func bpathSet(_ value: Int, limitType: Int, encoding: String?) {
    guard let enc = encoding else {
        print("bpath.set.verdict=selector-absent")
        return
    }
    // 帧形：ret@0:8arg1... ——取 ':' 之后的自符（args）。
    let args = String(enc.drop { $0 != ":" }.dropFirst())
    let argChars = args.filter { !"0123456789@".contains($0) }
    let returnsBool = enc.hasPrefix("B") || enc.hasPrefix("c")
    let wideArgs = argChars.contains("q") || argChars.contains("Q")
        || argChars.contains("l") || argChars.contains("L")
    print("bpath.set.encoding=\(enc) argChars=\(argChars) wide=\(wideArgs) boolRet=\(returnsBool)")
    if wideArgs {
        if returnsBool {
            print("bpath.set.return=\(msgSendBoolLongLong(shared, selSetLimitTo, Int64(value), Int64(limitType)))")
        } else {
            msgSendVoidLongLong(shared, selSetLimitTo, Int64(value), Int64(limitType))
            print("bpath.set.return=void")
        }
    } else {
        if returnsBool {
            print("bpath.set.return=\(msgSendBoolIntInt(shared, selSetLimitTo, Int32(value), Int32(limitType)))")
        } else {
            msgSendVoidIntInt(shared, selSetLimitTo, Int32(value), Int32(limitType))
            print("bpath.set.return=void")
        }
    }
    print("bpath.set.verdict=dispatched(观察面：两面读回 + 充电行为)")
}

// ── 子命令 ─────────────────────────────────────────────────────────
let argv = Array(CommandLine.arguments.dropFirst())
let cmd = argv.first ?? "info"

switch cmd {
case "info":
    print("bpath.s3.getMCLLimit=\(s3Readback().map(String.init) ?? "nil")")
    dualReadback(tag: "bpath.info")
    print("bpath.verdict=done(只读)")
case "token":
    guard let key = argv.dropFirst().first else {
        print("bpath.verdict=invalid-arg(用法: token <key>)")
        exit(2)
    }
    let token = msgSendIdStr(shared, selLoadToken, key as NSString)
    print("bpath.token.key=\(key)")
    print("bpath.token.value=\(token is NSNull ? "nil" : String(describing: token))")
    print("bpath.verdict=done(只读)")
case "set":
    guard let nStr = argv.dropFirst().first, let n = Int(nStr), (1...100).contains(n) else {
        print("bpath.verdict=invalid-arg(用法: set <n> [limitType])")
        exit(2)
    }
    let limitType = argv.dropFirst(2).first.flatMap(Int.init) ?? 0
    print("bpath.set.limitType=\(limitType)（语义未知——默认 0，照实登记）")
    let before = s3Readback()
    print("criterion4.before.s3_readback=\(before.map(String.init) ?? "nil")")
    bpathSet(n, limitType: limitType, encoding: encodingOf(classAsAny(bCls), "setChargeLimitTo:forLimitType:", meta: false))
    dualReadback(tag: "bpath.set")
    if n == 85 {
        let rb = s3Readback()
        print("criterion1.verdict=\(rb == 85 ? "PASS(set 85 两面读回 85)" : "UNCONFIRMED(读回 \(rb.map(String.init) ?? "nil"))")")
    }
    if n < 80 {
        print("criterion2.verdict=observe(set \(n) <80——拒绝/异常/放行形态照实观察；对照 S3 面 Code=4 先验)")
    }
    print("bpath.verdict=called")
case "clear":
    print("bpath.clear.before.s3_readback=\(s3Readback().map(String.init) ?? "nil")")
    msgSendVoidNoArg(shared, selClearAll)
    print("bpath.clear.called=clearAllChargeLimits")
    dualReadback(tag: "bpath.clear")
    print("criterion3.verdict=observe(clear 后读回 + 恢复可控性——恢复臂：s3Set(prev) 或系统设置重设)")
    print("bpath.verdict=called")
case "c5":
    // 判据⑤ 装配：MCL=80（B 路写；失败回退 S3 面写）——域 75 由 daemon topoff 承载，
    // 停充点为充电行为观察项（root 域用户态不可读——观察指引输出）。
    bpathSet(80, limitType: 0, encoding: encodingOf(classAsAny(bCls), "setChargeLimitTo:forLimitType:", meta: false))
    let rb = s3Readback()
    print("criterion5.mcl_set=\(rb.map(String.init) ?? "nil")（期望 80）")
    if rb != 80 {
        let s3 = s3Set(80)
        print("criterion5.s3_fallback=\(s3.ok ? "set ok" : "set failed（\(s3.error)）")")
    }
    print("criterion5.observe=插电观察实际停充点——若停在 75 附近 = 域主导（MCL 80 ∧ 域 75 并存无害假设 R2-P2-1 成立）；若停在 80 附近 = 原生 MCL 独立执法（假设不成立——<80 恢复分支需重评估）")
    print("bpath.verdict=assembled")
default:
    print("用法：spike-0.21-bpath.swift info | token <key> | set <n> [limitType] | clear | c5")
    exit(2)
}
