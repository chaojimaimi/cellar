#!/usr/bin/env swift
// MARK: - Cellar macOS 27 SMC/电池兼容探针（只读诊断，0.19.8 兼容批 M0）
//
// ⚠️ 请用 root 运行：
//   sudo swift Tools/spike-macos27-smc.swift
//   sudo swift Tools/spike-macos27-smc.swift --enum   # 全量键枚举（慢，仅定向扫描无果时用）
//
// 背景（2026-09-15 升级 macOS 27.0 后事故，方案 docs/plans/v0.19.8-macos27-compat.md）：
//   ① daemon(root) 后端探测降只读——RuntimeProbe CHTE→CH0B 均不可用；
//     doctor 控制键「读取异常」（传输级错误而非 132 键不存在）。
//   ② AppleSmartBattery 顶层 Temperature 键消失（解析器必填炸整个快照）；
//     疑似迁至子节点 AppleSmartBatteryPack 的 BatteryData 内（且时有时无）。
//
// 预注册判据（GO/NO-GO 机械对账）：
//   [判据一] CHTE keyInfo 错误码 == ZZZZ 基线（132）   → 键已删除/改名 → 第二轮键表猎取
//   [判据一] CHTE 异码/可读                            → 键在但访问受限 → SMC 客户端访问适配
//   [判据二] BatteryData.Temperature 采样在场率 ≥80%   → 子节点可作温度新源
//   [判据二] 在场率 <80%                               → 温度源改 SMC TB1T/TB2T（读数须 25–45 °C 合理域）
//   [判据三] 遥测键族（ID0R/PSTR 等）可读              → 兼容破坏仅限控制键族；不可读 → 面扩大
//
// 安全：全程只读（cmdWrite 不存在于本工具）。

import Foundation
import IOKit

private let selectorUniversal: UInt32 = 2
private let cmdRead: UInt8 = 5
private let cmdReadIndex: UInt8 = 8
private let cmdKeyInfo: UInt8 = 9
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
    var dataTypeRaw: UInt32 { Self.u32LE(buf, 32) }
    var dataType: String {
        let v = dataTypeRaw
        let b = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: b, encoding: .ascii) ?? String(format: "0x%08X", v)
    }
    var result: UInt8 { buf[40] }
    var data8: UInt8 {
        get { buf[42] } set { buf[42] = newValue }
    }
    var keyBytes: [UInt8] {
        let v = key
        return [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
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
    /// 诊断口径：kr 与驱动 result 码都保留（27 上的异常形态要靠原始码分辨）。
    func rawInfo(_ key: String) -> (kr: kern_return_t, result: UInt8, size: UInt32, type: String) {
        let input = SMCParam()
        input.key = SMCParam.pack(key)
        input.data8 = cmdKeyInfo
        let (out, kr) = call(input)
        return (kr, out.result, out.dataSize, out.dataType)
    }
    func rawRead(_ key: String, size: UInt32) -> (kr: kern_return_t, result: UInt8, bytes: [UInt8]) {
        let input = SMCParam()
        input.key = SMCParam.pack(key)
        input.data8 = cmdRead
        input.dataSize = size
        let (out, kr) = call(input)
        let n = Int(min(size, 32))
        return (kr, out.result, Array(out.buf[48..<48 + n]))
    }
    func keyInfo(_ key: String) -> (size: UInt32, type: String)? {
        let r = rawInfo(key)
        guard r.kr == KERN_SUCCESS, r.result == resultSuccess else { return nil }
        return (r.size, r.type)
    }
    func read(_ key: String) -> (size: UInt32, type: String, bytes: [UInt8])? {
        guard let info = keyInfo(key) else { return nil }
        let r = rawRead(key, size: info.size)
        guard r.kr == KERN_SUCCESS, r.result == resultSuccess else { return nil }
        return (info.size, info.type, r.bytes)
    }
    /// 枚举键位：经典技法 key = idx<<24（macOS 26 实测 >7 分钟，仅 --enum 手动档）。
    func enumerate(limit: Int) -> [(key: String, type: String, size: UInt32)] {
        var keys: [(key: String, type: String, size: UInt32)] = []
        for idx in 0..<limit {
            let input = SMCParam()
            input.key = UInt32(idx) << 24
            input.data8 = cmdReadIndex
            let (out, kr) = call(input)
            guard kr == KERN_SUCCESS, out.result == resultSuccess else { continue }
            let name = String(bytes: out.keyBytes, encoding: .ascii) ?? "?"
            guard name != "    " else { continue }
            if let info = keyInfo(name) {
                keys.append((name, info.type, info.size))
            }
        }
        return keys
    }
}

private func flt(_ bytes: [UInt8]) -> String {
    guard bytes.count >= 4 else { return "-" }
    return String(format: "%.2f", bytes.prefix(4).withUnsafeBytes { $0.load(as: Float32.self) })
}

private func pad2(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

/// AppleSmartBattery 子节点（AppleSmartBatteryPack）BatteryData.Temperature。
/// 27 上顶层属性不再暴露温度；子节点逐个翻属性找 BatteryData（多包机型取首个命中）。
func readPackTemperature() -> Double? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    var iterator: io_iterator_t = 0
    guard IORegistryEntryGetChildEntry(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var result: Double?
    while true {
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { break }
        defer { IOObjectRelease(entry) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { continue }
        if let bd = dict["BatteryData"] as? [String: Any], let t = bd["Temperature"] as? Int {
            result = Double(t) / 100.0
        }
    }
    return result
}

guard let smc = SMCConnection() else {
    print("❌ 无法连接 AppleSMC 用户客户端")
    exit(1)
}
print("uid=\(getuid())\(getuid() == 0 ? " (root ✅)" : " ⚠️ 非 root——键可见性不可靠，请用 sudo 重跑")")

if CommandLine.arguments.contains("--enum") {
    print("全量键枚举（macOS 26 实测 >7 分钟，Ctrl+C 可中断）……")
    let keys = smc.enumerate(limit: 65535)
    print("枚举到 \(keys.count) 个键：")
    for k in keys.sorted(by: { $0.key < $1.key }) {
        print(pad2(k.key, 6) + pad2(k.type, 8) + String(k.size))
    }
    exit(0)
}

// MARK: E1 错误码三方校准（好键 / 不存在基线 / 控制键族）

let calibration: [(key: String, desc: String)] = [
    ("F0Ac", "已知好键：风扇转速（对照-可读）"),
    ("TB1T", "已知好键：电池温度传感器（对照-可读）"),
    ("ZZZZ", "不存在键基线（对照-132）"),
    ("CHTE", "★ Tahoe 充电控制（生产依赖）"),
    ("CHIE", "★ Tahoe 适配器控制（放电依赖）"),
    ("CH0B", "legacy 停充位（回退后端）"),
    ("CH0C", "legacy 停充位（回退后端）"),
    ("ACLC", "MagSafe LED（v1.8 在产控制键）"),
]
print("---- E1 错误码三方校准 ----")
print(pad2("KEY", 6) + pad2("kr(info)", 12) + pad2("result", 8) + pad2("size", 6) + pad2("type", 8) + "desc")
var chteAbsent = false
for c in calibration {
    let r = smc.rawInfo(c.key)
    let rr = smc.rawRead(c.key, size: r.size == 0 ? 4 : r.size)
    print(pad2(c.key, 6) + pad2(String(format: "0x%08X", r.kr), 12) + pad2(String(r.result), 8) + pad2(String(r.size), 6) + pad2(r.type, 8) + c.desc + (rr.result == 132 ? " [read=132]" : ""))
    if c.key == "CHTE" { chteAbsent = (r.result == 132 || rr.result == 132) }
}
for k in ["F0Ac", "TB1T", "TB2T"] {
    if let v = smc.read(k) {
        print("值对照 \(k) [\(v.type)] = " + flt(v.bytes) + (k.hasPrefix("TB") ? " °C（候选温度源合理性 25–45）" : " rpm"))
    }
}

// MARK: E1b 控制键改名候选族（bounded 模式试探，秒级）

print("---- E1b 控制键改名候选族扫描 ----")
let candidates = ["CHTA", "CHTB", "CHTC", "CHTD", "CHTF", "CHTG", "CHTH", "CHTI", "CHTJ",
                  "CH1E", "CH1B", "CH2E", "CHWE", "CHBI", "CHSC", "CHAC", "CHFC",
                  "BFCL", "BF0B", "BF1B", "CHWA", "CHWD"]
var found: [String] = []
for k in candidates {
    let r = smc.rawInfo(k)
    if r.kr == KERN_SUCCESS, r.result == resultSuccess {
        found.append(k)
        let v = smc.read(k)
        print("命中 \(k) [\(r.type)] size=\(r.size) 值=" + (v.map { flt($0.bytes) } ?? "?"))
    }
}
print("候选族命中：\(found.isEmpty ? "（无）" : found.joined(separator: ", "))")

// MARK: E3 遥测键族健全性（读侧是否被波及）

print("---- E3 遥测键族（读侧面） ----")
for k in ["ID0R", "VD0R", "PSTR", "PDTR", "PPBR", "B0AC", "B0AT"] {
    if let v = smc.read(k) {
        print("可读 \(k) [\(v.type)] = " + flt(v.bytes))
    } else {
        let r = smc.rawInfo(k)
        print("不可读 \(k) [kr=0x\(String(r.kr, radix: 16)) result=\(r.result)]")
    }
}

// MARK: E2 温度新源采样（子节点 BatteryData.Temperature 在场率，10 次 / 1s）

print("---- E2 AppleSmartBatteryPack.BatteryData.Temperature 采样（10 次 / 1s 间隔） ----")
var present = 0
var samples: [Double] = []
for i in 1...10 {
    let v = readPackTemperature()
    if let v { present += 1; samples.append(v) }
    print("t\(i): " + (v.map { String(format: "%.2f °C", $0) } ?? "ABSENT"))
    if i < 10 { Thread.sleep(forTimeInterval: 1.0) }
}
let ratio = Double(present) / 10.0
print(String(format: "在场率：%.0f%%（判据二阈值 80%%）", ratio * 100))
if !samples.isEmpty {
    print(String(format: "采样域：%.2f–%.2f °C（合理性 25–45 °C）", samples.min()!, samples.max()!))
}

// MARK: 判据机械输出

print("---- 预注册判据对账 ----")
print("[判据一] CHTE = " + (chteAbsent ? "132（与不存在基线同码）" : "非 132（异码/在位）"))
print(chteAbsent ? "  → 键已删除/改名：第二轮键表猎取（--enum 或社区键名情报）" : "  → 键在但访问受限或可读：SMC 客户端适配/生产接线排查")
print("[判据二] 温度新源 = " + (ratio >= 0.8 ? "子节点 BatteryData（在场率达标）" : "SMC TB1T/TB2T（在场率不足，按读值合理性复核）"))
print("[判据三] 遥测键族见 E3 逐键输出（可读=面仅限控制键；不可读=兼容面扩大）")
