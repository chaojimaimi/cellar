#!/usr/bin/env swift
// MARK: - Cellar M0 只读 SMC 探针 v2（macOS 26 新调用约定）
//
// ⚠️ 请用 root 运行（键位表对非 root 进程隐藏，返回 132=KeyNotFound）：
//   sudo swift Tools/m0-smc-probe.swift        # 键位探测
//   sudo swift Tools/m0-smc-probe.swift --enum # 全量键枚举（较慢）
//
// v2 关键结论（2026-08-31 实测，详见内部实测记录）：
//   1. macOS 26 移除了旧版 selector 5/6/9 直接调用（一律 kIOReturnBadArgument）
//   2. 统一入口 = selector 2（经典 KERNEL_INDEX_SMC），操作由 data8 区分：
//      5=读 6=写 8=按索引枚举 9=getKeyInfo
//   3. 参数结构仍为 80 字节固定布局（Swift struct 布局不符，必须手工封包）

import Foundation
import IOKit

private let selectorUniversal: UInt32 = 2      // 统一 SMC 入口
private let cmdRead: UInt8 = 5
private let cmdWrite: UInt8 = 6
private let cmdReadIndex: UInt8 = 8
private let cmdKeyInfo: UInt8 = 9
private let resultSuccess: UInt8 = 0
private let resultKeyNotFound: UInt8 = 132

private let resultNames: [UInt8: String] = [
    0: "OK", 132: "KeyNotFound(隐藏/不存在)", 137: "缺期望尺寸(需两阶段读)",
]

// MARK: 80 字节参数结构（固定偏移封包，与 C ABI 一致）

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
    var bytes: [UInt8] {
        let n = Int(min(dataSize, 32))
        return Array(buf[(48)..<(48 + n)])
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
    func setByteAt(_ index: Int, _ value: UInt8) { buf[48 + index] = value }
}

// MARK: SMC 连接

private final class SMCConnection {
    private let connection: io_connect_t

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            FileHandle.standardError.write("未找到 AppleSMC 服务\n".data(using: .utf8)!)
            return nil
        }
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard kr == KERN_SUCCESS else {
            FileHandle.standardError.write(String(format: "IOServiceOpen 失败 kr=0x%08X\n", kr).data(using: .utf8)!)
            return nil
        }
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

    /// 两阶段读（macOS 26 必需）：先 getKeyInfo 取 dataSize，再带尺寸发起读。
    /// 注意：回复包不回填 dataSize 字段，必须按请求尺寸切片 bytes。
    func read(_ key: String) -> (size: UInt32, type: String, bytes: [UInt8])? {
        guard let info = keyInfo(key) else { return nil }
        let input = SMCParam()
        input.key = SMCParam.pack(key)
        input.data8 = cmdRead
        input.dataSize = info.size
        let (out, kr) = call(input)
        guard kr == KERN_SUCCESS, out.result == resultSuccess else { return nil }
        let n = Int(min(info.size, 32))
        return (info.size, info.type, Array(out.buf[48..<48 + n]))
    }

    /// 底层调用，返回驱动 result 码（诊断用）
    func rawResult(key: String, cmd: UInt8, inSize: UInt32 = 0) -> UInt8 {
        let input = SMCParam()
        input.key = SMCParam.pack(key)
        input.data8 = cmd
        input.dataSize = inSize
        let (out, kr) = call(input)
        return kr == KERN_SUCCESS ? out.result : 255
    }

    /// 枚举键位：经典技法 key = idx<<24。root 下可用。
    func enumerate(limit: Int = 2048) -> [(key: String, type: String, size: UInt32)] {
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
            } else {
                keys.append((name, "?", out.dataSize))
            }
        }
        return keys
    }
}

// MARK: 解码

private func interpret(key: String, type: String, bytes: [UInt8]) -> String {
    func i16(_ b: [UInt8]) -> Int16 { Int16(b[0]) << 8 | Int16(b[1]) }
    func u16(_ b: [UInt8]) -> UInt16 { UInt16(b[0]) << 8 | UInt16(b[1]) }
    func u32(_ b: [UInt8]) -> UInt32 {
        UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
    let raw = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    var meaning = ""
    if key == "CHTE" && bytes.count == 4 {
        meaning = bytes.elementsEqual([0, 0, 0, 0]) ? "→ 充电使能" : (bytes[0] == 1 ? "→ 充电禁用" : "→ 未知状态")
        return raw + "  " + meaning
    }
    switch type {
    case "flt " where bytes.count >= 4, "flts" where bytes.count >= 4:
        meaning = String(format: "%.3f", bytes.prefix(4).withUnsafeBytes { $0.load(as: Float32.self) })
    case "sp78" where bytes.count >= 2:
        meaning = String(format: "%.2f", Double(i16(bytes)) / 256.0)
    case "fpe2" where bytes.count >= 2:
        meaning = String(format: "%.1f", Double(i16(bytes)) / 256.0)
    case "si16" where bytes.count >= 2:
        meaning = "s16=\(i16(bytes))"
    case "ui16" where bytes.count >= 2:
        meaning = "u16=\(u16(bytes))"
    case "ui32" where bytes.count >= 4:
        meaning = "u32=\(u32(bytes))"
    case "ui8" where bytes.count >= 1:
        meaning = "u8=\(bytes[0])"
    default:
        break
    }
    return meaning.isEmpty ? raw : raw + "  → " + meaning
}

private func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

// MARK: 主流程

guard let smc = SMCConnection() else {
    print("❌ 无法连接 AppleSMC 用户客户端")
    exit(1)
}
print("uid=\(getuid())\(getuid() == 0 ? " (root ✅)" : " ⚠️ 非 root，键位表将被隐藏（全部 132）")")

if CommandLine.arguments.contains("--enum") {
    let keys = smc.enumerate()
    print("枚举到 \(keys.count) 个键：")
    for k in keys.sorted(by: { $0.key < $1.key }) {
        print(pad(k.key, 6) + pad(k.type, 8) + pad(String(k.size), 4))
    }
    exit(0)
}

private let probeKeys: [(key: String, desc: String)] = [
    // 控制侧：Tahoe 新代键（macOS 26+）
    ("CHTE", "Tahoe 充电控制 4B ★"), ("CHIE", "Tahoe 适配器控制 4B"),
    // 控制侧：旧代键（对照）
    ("CH0B", "legacy 停充位 B"), ("CH0C", "legacy 停充位 C"),
    ("bfD0", "固件充电上限 %"), ("bfE0", "固件充电下限 %"), ("bfF0", "固件策略激活"),
    // 读侧：遥测键（Tahoe + 经典）
    ("ID0R", "输入电流 mA"), ("VD0R", "输入电压 mV"), ("PDTR", "输入功率"),
    ("PPBR", "电池功率"), ("BUIC", "电池充电量"),
    ("B0AC", "电池电流 mA"), ("B0AV", "电池电压 mV"),
    ("B0AT", "电池温度(候选)"), ("TB1T", "电池温度传感器1"), ("TB2T", "电池温度传感器2"),
    ("PSTR", "系统总功率 W"), ("ACEN", "适配器使能(候选)"), ("ACFP", "适配器功率(候选)"),
    ("#KEY", "键位总数(旧枚举键)"),
]

print("----------------------------------------------------------------")
print(pad("KEY", 6) + pad("TYPE", 8) + pad("SIZE", 4) + pad("原始(hex)", 24) + "解释")
print("----------------------------------------------------------------")

var tahoeControl = [String](), legacyControl = [String]()
for probe in probeKeys {
        if let info = smc.keyInfo(probe.key), let read = smc.read(probe.key) {
            let raw = read.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            print(pad(probe.key, 6) + pad(info.type, 8) + pad(String(info.size), 4) + pad(raw, 24) + interpret(key: probe.key, type: info.type, bytes: read.bytes) + " (\(probe.desc))")
        if ["CHTE", "CHIE"].contains(probe.key) { tahoeControl.append(probe.key) }
        if ["CH0B", "CH0C"].contains(probe.key) { legacyControl.append(probe.key) }
    } else {
        let ir = smc.rawResult(key: probe.key, cmd: cmdKeyInfo)
        let rr = smc.rawResult(key: probe.key, cmd: cmdRead, inSize: 4)
        print(pad(probe.key, 6) + pad("-", 8) + pad("-", 4) + pad("-", 24) +
              "不可读 [info:\(ir) read(4B):\(rr)] (\(probe.desc))")
    }
}
print("----------------------------------------------------------------")
print("后端判定：Tahoe 控制键 = [\(tahoeControl.joined(separator: ", "))]；旧代控制键 = [\(legacyControl.joined(separator: ", "))]")
print(tahoeControl.count == 1
      ? "结论：✅ Tahoe 控制通路可用（CHTE）→ 读取/写入验证继续"
      : "结论：⚠️ 见上方逐键 result 码（132=对当前身份隐藏或不存在；root 下仍 132 则键名需继续考证）")
