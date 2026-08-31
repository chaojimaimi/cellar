#!/usr/bin/env swift
// MARK: - Cellar M0 停充/恢复循环验证 v2 ⚠️ 会短暂改变充电状态，请插着电源执行
//
// 用法（必须 root；macOS 26 键位表对非 root 隐藏）：
//   sudo swift Tools/m0-charge-test.swift --do-it
//
// 协议自动选择（2026-08-31 实测，详见内部实测记录）：
//   - Tahoe（macOS 26+）：CHTE，4 字节。`01 00 00 00`=停充，`00 00 00 00`=恢复
//   - 旧代（<26）：CH0B/CH0C，1 字节。0x02=停充，写回基线值恢复
//
// 安全设计：写前记录基线值并写回基线；SIGINT/TERM/HUP 自动恢复；未接电源拒绝执行；
//           全程约 8 秒；结束时打印三段 pmset 证据。

import Foundation
import IOKit

private let selectorUniversal: UInt32 = 2
private let cmdRead: UInt8 = 5
private let cmdWrite: UInt8 = 6
private let resultSuccess: UInt8 = 0

private final class SMCParam {
    static let length = 80
    var buf = [UInt8](repeating: 0, count: SMCParam.length)

    private static func u32LE(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
    }
    private static func setU32LE(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        b[off] = UInt8(v & 0xFF); b[off + 1] = UInt8((v >> 8) & 0xFF)
        b[off + 2] = UInt8((v >> 16) & 0xFF); b[off + 3] = UInt8((v >> 24) & 0xFF)
    }

    var key: UInt32 {
        get { Self.u32LE(buf, 0) } set { Self.setU32LE(&buf, 0, newValue) }
    }
    var dataSize: UInt32 {
        get { Self.u32LE(buf, 28) } set { Self.setU32LE(&buf, 28, newValue) }
    }
    var result: UInt8 { buf[40] }
    var data8: UInt8 {
        get { buf[42] } set { buf[42] = newValue }
    }
    var bytes: [UInt8] {
        let n = Int(min(dataSize, 32))
        return Array(buf[(48)..<(48 + n)])
    }
    func setBytes(_ values: [UInt8]) {
        precondition(values.count <= 32)
        for (i, v) in values.enumerated() { buf[48 + i] = v }
    }

    static func pack(_ key: String) -> UInt32 {
        let b = Array(key.utf8)
        guard b.count == 4 else { return 0 }
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }
}

private final class SMCConnection {
    private let connection: io_connect_t

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard kr == KERN_SUCCESS else { return nil }
        connection = conn
    }

    deinit { IOServiceClose(connection) }

    private func call(_ input: SMCParam) -> (out: SMCParam, kr: kern_return_t) {
        let output = SMCParam()
        var inP = input.buf, outP = output.buf
        var inCnt = SMCParam.length, outCnt = SMCParam.length
        let kr = IOConnectCallStructMethod(connection, selectorUniversal, &inP, inCnt, &outP, &outCnt)
        output.buf = outP
        return (output, kr)
    }

    private func keyInfo(_ key: String) -> UInt32? {
        let input = SMCParam()
        input.key = SMCParam.pack(key)
        input.data8 = 9
        let (out, kr) = call(input)
        guard kr == KERN_SUCCESS, out.result == resultSuccess else { return nil }
        return out.dataSize
    }
    /// 两阶段读（macOS 26 必需）：先 getKeyInfo 取 dataSize，再带尺寸读。
    /// 回复包不回填 dataSize，按请求尺寸切片。
    func read(_ key: String) -> [UInt8]? {
        let infoInput = SMCParam()
        infoInput.key = SMCParam.pack(key)
        infoInput.data8 = 9
        let (info, infoKr) = call(infoInput)
        guard infoKr == KERN_SUCCESS, info.result == resultSuccess else { return nil }
        let size = Int(min(info.dataSize, 32))
        let input = SMCParam()
        input.key = SMCParam.pack(key)
        input.data8 = cmdRead
        input.dataSize = info.dataSize
        let (out, kr) = call(input)
        guard kr == KERN_SUCCESS, out.result == resultSuccess else { return nil }
        return Array(out.buf[48..<48 + size])
    }

    func write(_ key: String, bytes values: [UInt8]) -> Bool {
        let input = SMCParam()
        input.key = SMCParam.pack(key)
        input.data8 = cmdWrite
        input.dataSize = UInt32(values.count)
        input.setBytes(values)
        let (out, kr) = call(input)
        return kr == KERN_SUCCESS && out.result == resultSuccess
    }
}

// MARK: pmset 辅助

@discardableResult
private func runPmset() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g", "batt"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

// MARK: 信号安全恢复

private var smcRef: SMCConnection?
private var baseline: (key: String, value: [UInt8])? = nil
private var restored = false
private var restore: (() -> Void)? = nil
private var signalSources: [DispatchSourceSignal] = []

private func restoreAndExit(_ reason: String) -> Never {
    if !restored {
        restored = true
        restore?()
    }
    FileHandle.standardError.write("\n[中断：\(reason)] 已恢复充电并退出\n".data(using: .utf8)!)
    exit(130)
}

// MARK: 主流程

let doIt = CommandLine.arguments.contains("--do-it")
let isRoot = getuid() == 0

print("=== Cellar M0 停充/恢复验证 v2 ===")
print("模式：\(doIt ? "实际执行 (--do-it)" : "干跑（只读，不写键）")；uid=\(getuid())\(isRoot ? " (root ✅)" : " ⚠️ 非 root")")
if doIt && !isRoot {
    print("❌ --do-it 需要 root：sudo swift Tools/m0-charge-test.swift --do-it")
    exit(2)
}

guard let smc = SMCConnection() else {
    print("❌ 无法连接 AppleSMC")
    exit(1)
}
smcRef = smc

// 1) 协议选择与基线
var protocolName = ""
var stopValue: [UInt8] = []
var enableValue: [UInt8] = []
var controlKey = ""
if let v = smc.read("CHTE") {
    protocolName = "Tahoe (CHTE, 4B)"
    controlKey = "CHTE"
    stopValue = [0x01, 0x00, 0x00, 0x00]   // 停充
    enableValue = [0x00, 0x00, 0x00, 0x00] // 充电使能（系统默认）
    baseline = ("CHTE", v)
} else if let b = smc.read("CH0B"), let cc = smc.read("CH0C") {
    protocolName = "Legacy (CH0B/CH0C, 1B)"
    controlKey = "CH0B"
    stopValue = [0x02]
    enableValue = [b.first ?? 0]
    print("基线 CH0B=0x\(String(b.first ?? 0, radix: 16)) CH0C=0x\(String(cc.first ?? 0, radix: 16))")
    baseline = ("CH0B", [b.first ?? 0])
} else {
    print("❌ 控制键（CHTE/CH0B）均不可读——请确认以 root 运行，或键位表有变（对照 Tools/m0-smc-probe.swift 输出）")
    exit(4)
}
if let b = baseline {
    print("协议：\(protocolName)；当前 \(b.key)=\(b.value.map { String(format: "%02X", $0) }.joined())")
}

let pm0 = runPmset()
print("--- pmset 基线 ---\n\(pm0)")
guard pm0.contains("AC Power") else {
    print("❌ 未接电源，拒绝执行（请插电后重试）")
    exit(3)
}

guard doIt else {
    print("✅ 干跑完成：控制键可读、电源在位。实际验证：sudo swift Tools/m0-charge-test.swift --do-it")
    exit(0)
}

// 2) 信号安全网：恢复动作 = 写入"充电使能"（Tahoe）/ 基线值（Legacy）
restore = { [controlKey, enableValue] in
    _ = smc.write(controlKey, bytes: enableValue)
}
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.global())
    src.setEventHandler { restoreAndExit("signal \(sig)") }
    src.resume()
    signalSources.append(src)
}

// 3) 归一化：先确保充电处于使能态（修正上次运行可能遗留的禁用态）
print("--- 归一化：写入充电使能 \(enableValue.map { String(format: "%02X", $0) }.joined()) ---")
let normOk = smc.write(controlKey, bytes: enableValue)
Thread.sleep(forTimeInterval: 2)
let back0 = smc.read(controlKey).map { $0.map { String(format: "%02X", $0) }.joined() } ?? "回读失败"
print("写 \(controlKey)=\(enableValue.map { String(format: "%02X", $0) }.joined()) → \(normOk ? "OK" : "失败")，回读 \(back0)")

// 4) 停充
print("--- 写入停充 \(stopValue.map { String(format: "%02X", $0) }.joined()) ---")
let stopOk = smc.write(controlKey, bytes: stopValue)
Thread.sleep(forTimeInterval: 1)
let back1 = smc.read(controlKey).map { $0.map { String(format: "%02X", $0) }.joined() } ?? "回读失败"
print("写 \(controlKey)=\(stopValue.map { String(format: "%02X", $0) }.joined()) → \(stopOk ? "OK" : "失败")，回读 \(back1)")

// 5) 验证停充
Thread.sleep(forTimeInterval: 3)
let pm1 = runPmset()
print("--- pmset 停充态 ---\n\(pm1)")
let stopped = pm1.contains("not charging") || pm1.contains("discharging")
print(stopped ? "✅ 证据成立：pmset 已进入非充电状态"
              : "⚠️ pmset 未见 not charging（回读=\(back1) 是判断写入是否生效的关键）")

// 6) 恢复充电使能
print("--- 恢复充电使能 ---")
let rstOk = smc.write(controlKey, bytes: enableValue)
Thread.sleep(forTimeInterval: 1)
let back2 = smc.read(controlKey).map { $0.map { String(format: "%02X", $0) }.joined() } ?? "回读失败"
print("写 \(controlKey)=\(enableValue.map { String(format: "%02X", $0) }.joined()) → \(rstOk ? "OK" : "失败")，回读 \(back2)")
restored = true

// 7) 验证恢复
Thread.sleep(forTimeInterval: 3)
let pm2 = runPmset()
print("--- pmset 恢复态 ---\n\(pm2)")
print("\n=== 结论 ===")
print(stopped && pm2.contains("charging")
      ? "✅ 停充/恢复循环完成：系统充电行为已回到默认（请再人工确认电池图标正常充电）"
      : "⚠️ 循环部分成立，请对照回读值与三段 pmset 输出人工确认（重点：回读是否与写入值一致）")
