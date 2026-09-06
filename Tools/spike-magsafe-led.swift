#!/usr/bin/env swift
// MARK: - Cellar v1.8 MagSafe LED 写 spike（ACLC 键，方案 §7-M0）
//
// ⚠️ 必须用 root 运行（ACLC 写入非 root 被 0xE00002C1 NotPrivileged 拒绝）：
//   sudo swift Tools/spike-magsafe-led.swift
//
// 判据预注册（docs/plans/phase5-v1.8-magsafe-led.md §7-M0，R1 P1-1 重定版）：
//   ① 同值回写 → 回读一致（锁存阶梯 [100,300,800]ms）
//   ② 写 01 → 回读 01 + 目视 LED 灭
//   ③ 写 03/04 → 目视绿/琥珀
//   ④ 恢复 00 → 目视回系统行为 ∧ 回读 ∈ {00,03,04}（记录原值——00 是命令值，
//      系统可能锁存后重写色值，回读色值不判失败）
//   ⑤ 观测：60s 内充放切换（拔/插充电器）后逐次回读，记录系统覆写时点与频率
//     （数据双向挂账：D4 纠偏设计 + D5 driftLatchThreshold 定稿）
//   全部写入仅 ACLC（LED 外观件），零充电路径键触碰；结束恢复 00（系统自动）。

import Foundation
import IOKit

private let selectorUniversal: UInt32 = 2
private let cmdRead: UInt8 = 5
private let cmdWrite: UInt8 = 6
private let cmdKeyInfo: UInt8 = 9
private let resultSuccess: UInt8 = 0
private let aclcKey = "ACLC"
private let ladderMs: [UInt64] = [100, 300, 800]

// MARK: 80 字节参数封包（与 m0-smc-probe.swift 同源，C ABI 手工封包）

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
    var dataType: String {
        let v = Self.u32LE(buf, 32)
        let b = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: b, encoding: .ascii) ?? String(format: "0x%08X", v)
    }
    static func pack(_ key: String) -> UInt32 {
        let b = Array(key.utf8)
        guard b.count == 4 else { return 0 }
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }
    func setBytes(_ values: [UInt8]) {
        for (i, v) in values.enumerated() { buf[48 + i] = v }
    }
}

private final class SMCConnection {
    private let connection: io_connect_t
    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { print("未找到 AppleSMC 服务"); return nil }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else {
            IOObjectRelease(service); print("IOServiceOpen 失败"); return nil
        }
        IOObjectRelease(service)
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
    func keyInfo(_ key: String) -> (size: UInt32, type: String)? {
        let input = SMCParam()
        input.key = SMCParam.pack(key)
        input.data8 = cmdKeyInfo
        let (out, kr) = call(input)
        guard kr == KERN_SUCCESS, out.result == resultSuccess else { return nil }
        return (out.dataSize, out.dataType)
    }
    func read(_ key: String) -> UInt8? {
        guard let info = keyInfo(key) else { return nil }
        let input = SMCParam()
        input.key = SMCParam.pack(key)
        input.data8 = cmdRead
        input.dataSize = info.size
        let (out, kr) = call(input)
        guard kr == KERN_SUCCESS, out.result == resultSuccess else { return nil }
        return out.buf[48]
    }
    @discardableResult
    func write(_ key: String, _ value: UInt8) -> Bool {
        let input = SMCParam()
        input.key = SMCParam.pack(key)
        input.data8 = cmdWrite
        input.dataSize = 1
        input.setBytes([value])
        let (out, kr) = call(input)
        return kr == KERN_SUCCESS && out.result == resultSuccess
    }
}

// MARK: 锁存阶梯回读（照 verifyFanKey [100,300,800]ms 先例）

private func ladderRead(_ smc: SMCConnection, expect: UInt8) -> (matched: Bool, last: UInt8?) {
    var last: UInt8?
    for ms in ladderMs {
        Thread.sleep(forTimeInterval: Double(ms) / 1000)
        last = smc.read(aclcKey)
        if last == expect { return (true, last) }
    }
    return (false, last)
}

private func hex(_ v: UInt8?) -> String { v.map { String(format: "0x%02X", $0) } ?? "读取失败" }
private func ask(_ prompt: String) -> Bool {
    print("\(prompt)（y/n）", terminator: " ")
    guard let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
    return line == "y" || line == "yes"
}

// MARK: 主流程

guard getuid() == 0 else {
    print("✗ 请用 root 运行：sudo swift Tools/spike-magsafe-led.swift（写入需提权）")
    exit(2)
}
guard let smc = SMCConnection() else { exit(2) }
guard let info = smc.keyInfo(aclcKey) else {
    print("✗ ACLC 键不存在（keyInfo 失败）——本机固件不支持，NO-GO")
    exit(1)
}
print("ACLC 在位：type=\(info.type) size=\(info.size)")
guard info.size == 1 else { print("✗ 尺寸异常（期望 1B）——NO-GO"); exit(1) }

var results: [(step: String, pass: Bool, note: String)] = []
let baseline = smc.read(aclcKey)
print("基线值：\(hex(baseline))")
results.append(("基线读取", baseline != nil, "值=\(hex(baseline))"))

// ① 同值回写
if let base = baseline {
    let ok = smc.write(aclcKey, base)
    let (matched, last) = ladderRead(smc, expect: base)
    results.append(("①同值回写", ok && matched, "回读=\(hex(last))"))
    print("① 同值回写 \(hex(base))：写入\(ok ? "成功" : "失败")，回读=\(hex(last)) \(matched ? "✓" : "✗ 不一致")")
}

// ② 写 01（灭）
print("\n② 写入 0x01（常灭）……")
let ok2 = smc.write(aclcKey, 0x01)
let (m2, l2) = ladderRead(smc, expect: 0x01)
print("   回读=\(hex(l2)) \(m2 ? "✓" : "✗")")
let seen2 = m2 && ask("   目视确认：LED 现在灭了吗？")
results.append(("②写01目视灭", ok2 && m2 && seen2, "回读=\(hex(l2))"))

// ③ 写 03/04
print("\n③ 写入 0x03（绿）……")
let ok3 = smc.write(aclcKey, 0x03)
let (m3, l3) = ladderRead(smc, expect: 0x03)
print("   回读=\(hex(l3)) \(m3 ? "✓" : "✗")")
let seen3 = m3 && ask("   目视确认：LED 现在是绿色吗？")
let ok4 = smc.write(aclcKey, 0x04)
let (m4, l4) = ladderRead(smc, expect: 0x04)
print("③b 写入 0x04（琥珀）：回读=\(hex(l4)) \(m4 ? "✓" : "✗")")
let seen4 = m4 && ask("   目视确认：LED 现在是琥珀色吗？")
results.append(("③写03目视绿", ok3 && m3 && seen3, "回读=\(hex(l3))"))
results.append(("③b写04目视琥珀", ok4 && m4 && seen4, "回读=\(hex(l4))"))

// ④ 恢复 00（回读 ∈ {00,03,04} 均不判失败——00 是命令值）
print("\n④ 恢复写入 0x00（交还系统）……")
let ok5 = smc.write(aclcKey, 0x00)
var inSet = false
var lastAfterRestore: UInt8?
for ms in ladderMs {
    Thread.sleep(forTimeInterval: Double(ms) / 1000)
    lastAfterRestore = smc.read(aclcKey)
    if let v = lastAfterRestore, [0x00, 0x03, 0x04].contains(v) { inSet = true; break }
}
print("   回读=\(hex(lastAfterRestore)) \(inSet ? "∈{00,03,04} ✓" : "✗ 越域值")")
let seen5 = inSet && ask("   目视确认：LED 回到系统默认行为了吗？")
results.append(("④恢复00目视系统", ok5 && inSet && seen5, "回读=\(hex(lastAfterRestore))"))

// ⑤ 观测：60s 充放切换覆写记录
print("\n⑤ 观测窗 60s：请在此窗口内拔掉再插回 MagSafe 充电器（触发充放切换）……")
var timeline: [(t: Int, v: UInt8)] = []
let start = Date()
var lastV: UInt8? = nil
while Date().timeIntervalSince(start) < 60 {
    if let v = smc.read(aclcKey) {
        if v != lastV {
            let t = Int(Date().timeIntervalSince(start))
            print("   t+\(零填充(t))s → 0x\(String(format: "%02X", v))\(label(v))")
            timeline.append((t, v))
            lastV = v
        }
    }
    Thread.sleep(forTimeInterval: 2)
}
print("   观测完成：\(timeline.count) 次值变化（含初始）——覆写节奏=充放切换事件驱动 or 周期性，见上时间线")

// 汇总
print("\n================ SPIKE 判据汇总 ================")
var allPass = true
for r in results {
    print("\(r.pass ? "✓" : "✗") \(r.step)（\(r.note)）")
    allPass = allPass && r.pass
}
// 恢复终态：交还系统
smc.write(aclcKey, 0x00)
print("收尾：ACLC 已恢复 0x00（系统自动）")
print(allPass ? "\n结论：①-④ 全过 = GO（观测⑤数据回填方案 §7 后定稿 driftLatchThreshold）"
              : "\n结论：存在失败项 = 按 CHIE 判例登记 NO-GO")
exit(allPass ? 0 : 1)

func label(_ v: UInt8) -> String {
    switch v {
    case 0x00: return "（系统命令值）"
    case 0x01: return "（灭）"
    case 0x03: return "（绿）"
    case 0x04: return "（琥珀）"
    default: return "（越域=他写信号）"
    }
}
func 零填充(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
