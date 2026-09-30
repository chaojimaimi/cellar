#!/usr/bin/env swift
// Cellar macOS 27 GA JXA spike（S3）——Swift 载体调用器（E1/E2/E4 执行体；E0 已由 spike-ga-jxa-methods.swift 定谳）。
// 背景与载体论证（2026-09-30）：
//   1. JXA 桥对无 bridgesupport 的私有框架（PowerUI/BatteryCenter 均 "nothing found to import"）不做运行时方法回退——
//      alloc 后的 initWithClientName / setMCLLimitError 在桥里 "Object is not a function"（-2700），set 85 首跑实锤。
//   2. 本工具用 objc_msgSend 按枚举到的精确签名直调（dlsym 取符号指针，规避 Swift 对 variadic objc_msgSend 的
//      unavailable 标注），绕开桥限制；机制与载体论证：0.21 产品化时 Cellar App（ad-hoc 签名用户态进程）即以此
//      路径调用——Swift/ad-hoc 载体是产品代表性载体，osascript（PR #480 同款）反而是旁支。若 PowerUIAgent 存在
//      客户端签名校验，本载体先暴露它（这正是实验目的）。
// API 面（来自 Tools/spike-ga-jxa-methods.swift 全量枚举，2026-09-29）：
//   setMCLLimit:error:   B28@0:8C16^@20   — ret BOOL, uchar limit, NSError**
//   getMCLLimitWithError: C24@0:8^@16     — ret uchar
//   isMCLSupported       B16@0:8          — ret BOOL
//   isMCLCurrentlyEnabled: Q24@0:8^@16    — ret ulong
//   currentChargeLimit:  Q24@0:8^@16      — ret ulong
//   实例化唯一路径：alloc → initWithClientName:（无 shared 单例；裸 init 不在方法表）
// 用法：
//   swift Tools/spike-ga-jxa-set.swift info          # 只读：isMCLSupported/CurrentlyEnabled/currentChargeLimit
//   swift Tools/spike-ga-jxa-set.swift get           # 只读：getMCLLimitWithError 回读
//   swift Tools/spike-ga-jxa-set.swift set <n>       # 写：setMCLLimit:error: n + 回读（n<80 预期拒绝/异常，照实记录）
// 只读子命令（info/get）无门禁；set 由 spike-ga-jxa.sh 包装驱动（R1/R2/R3 门禁 + 崩溃隔离在包装层）。
// 输出：kv 行（probe.class_found / probe.class / set85.* 等）与 spike-ga-jxa.js 同格式，包装器 concl 直接消费。

import Foundation
import ObjectiveC
import Darwin

// ── 框架加载 ────────────────────────────────────────────────────────
let fwPaths = [
    "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI",
    "/System/Library/PrivateFrameworks/BatteryCenter.framework/BatteryCenter",
]
for p in fwPaths { _ = dlopen(p, RTLD_NOW) }   // PowerUI 为主（类宿主）；BatteryCenter 兜底（依赖链亦可拉起）

guard let clsObj = objc_getClass("PowerUISmartChargeClient") else {
    print("probe.class_found=no")
    print("set85.verdict=class-not-found")
    exit(3)
}
let cls = clsObj as AnyObject
print("probe.class_found=yes")
print("probe.class=PowerUISmartChargeClient")

// ── objc_msgSend 按签名特化（dlsym 原始指针 → bitcast；Swift 直引 variadic 符号被标 unavailable）───
let mainHandle = dlopen(nil, RTLD_LAZY)!
guard let msgSendPtr = dlsym(mainHandle, "objc_msgSend") else {
    print("set85.verdict=objc_msgSend-not-found")
    exit(3)
}
typealias MsgSendIdSel = @convention(c) (AnyObject, Selector) -> AnyObject
typealias MsgSendBool = @convention(c) (AnyObject, Selector) -> Bool
typealias MsgSendIdStr = @convention(c) (AnyObject, Selector, NSString) -> AnyObject
typealias MsgSendBoolUCharErr = @convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Bool
typealias MsgSendUCharErr = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> UInt8
typealias MsgSendULongErr = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> UInt

let msgSendIdSel = unsafeBitCast(msgSendPtr, to: MsgSendIdSel.self)
let msgSendBool = unsafeBitCast(msgSendPtr, to: MsgSendBool.self)
let msgSendIdStr = unsafeBitCast(msgSendPtr, to: MsgSendIdStr.self)
let msgSendBoolUCharErr = unsafeBitCast(msgSendPtr, to: MsgSendBoolUCharErr.self)
let msgSendUCharErr = unsafeBitCast(msgSendPtr, to: MsgSendUCharErr.self)
let msgSendULongErr = unsafeBitCast(msgSendPtr, to: MsgSendULongErr.self)

let selAlloc = sel_registerName("alloc")
let selInitClient = sel_registerName("initWithClientName:")
let selIsSupported = sel_registerName("isMCLSupported")
let selSetMCL = sel_registerName("setMCLLimit:error:")
let selGetMCL = sel_registerName("getMCLLimitWithError:")
let selIsEnabled = sel_registerName("isMCLCurrentlyEnabled:")
let selCurrentLimit = sel_registerName("currentChargeLimit:")

// ── 实例化（唯一路径：alloc → initWithClientName:）─────────────────
let alloced = msgSendIdSel(cls, selAlloc)
if alloced is NSNull {
    print("set85.verdict=alloc-failed")
    exit(3)
}
let inst = msgSendIdStr(alloced, selInitClient, "Cellar" as NSString)
print("set85.accessor=alloc/initWithClientName:\"Cellar\"")

func describeError(_ err: Unmanaged<NSError>?) -> String {
    guard let e = err?.takeUnretainedValue() else { return "none" }
    return "\(e.domain) Code=\(e.code) \(e.localizedDescription)"
}

func readBackLimit() -> String {
    var err: Unmanaged<NSError>?
    let v = msgSendUCharErr(inst, selGetMCL, &err)
    return "\(v)（error=\(describeError(err))）"
}

// ── 子命令 ─────────────────────────────────────────────────────────
let argv = Array(CommandLine.arguments.dropFirst())
let cmd = argv.first ?? "info"

switch cmd {
case "info":
    let supported = msgSendBool(inst, selIsSupported)
    var errE: Unmanaged<NSError>?
    let enabled = msgSendULongErr(inst, selIsEnabled, &errE)
    var errC: Unmanaged<NSError>?
    let cur = msgSendULongErr(inst, selCurrentLimit, &errC)
    print("info.isMCLSupported=\(supported)")
    print("info.isMCLCurrentlyEnabled=\(enabled)（error=\(describeError(errE))）")
    print("info.currentChargeLimit=\(cur)（error=\(describeError(errC))）")
    print("info.verdict=done")
case "get":
    print("get.mclLimit=\(readBackLimit())")
    print("get.verdict=done")
case "set":
    guard let nStr = argv.dropFirst().first, let n = Int(nStr), (0...100).contains(n) else {
        print("set85.verdict=invalid-arg")
        exit(2)
    }
    if n < 80 { print("set85.warn=n<80——PR #480 预期拒绝/异常；形态照实记录（包装捕获）") }
    var err: Unmanaged<NSError>?
    let ok = msgSendBoolUCharErr(inst, selSetMCL, UInt8(n), &err)
    print("set85.called=setMCLLimit:error:")
    print("set85.return=\(ok)")
    print("set85.error=\(describeError(err))")
    print("set85.readback.mclLimit=\(readBackLimit())")
    print("set85.verdict=called(观察面：battlimit/充电行为——包装器负责采样)")
default:
    print("用法：spike-ga-jxa-set.swift info | get | set <n>")
    exit(2)
}
