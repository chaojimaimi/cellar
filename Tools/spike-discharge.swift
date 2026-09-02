#!/usr/bin/env swift
// Cellar 放电重调 spike（Phase 3 WP1.5，CHIE 0x8 修正假设 + 功率遥测键标定）— 规格 docs/plans/phase3-wp15-discharge-respike.md v1.1；唯一事实源 docs/SMC-NOTES.md
// SMC 封装照抄 Tools/m0-charge-test.swift（selector 2 + data8、80B 封包、key 小端 uint32、两阶段读、回复不回填 dataSize）
// 用法(canonical，root 只执行不构建。本脚本不在 SPM target 内——swift build 不产出该二进制，用 swiftc 单文件构建，产物路径对齐方案 §1.8):
//   swiftc -O Tools/spike-discharge.swift -o .build/debug/spike-discharge   # user 侧构建
//   sudo .build/debug/spike-discharge --do-it              # E0–E6 全流程写实验(root;状态文件门禁)
//   sudo .build/debug/spike-discharge --restore            # 按状态文件逐键还原
//   sudo .build/debug/spike-discharge --restore CHIE=0x00  # 手动兜底(KEY=HEX)
//   .build/debug/spike-discharge --calibrate-power         # 功率键标定(只读,无需 root)
//   swift Tools/spike-discharge.swift --enumerate          # 只读预检(无需 sudo,免构建)
//   .build/debug/spike-discharge --help
// 实验矩阵(v1.1 §2): E0 基线60s(嵌P1标定) / E1 CHIE 写0x8+判读表(回读必须恰为0x8,实际读回值必录;kr≠0→回写原值判no-go不对0x8重试) /
//   E2 观察窗(cycle1 保守30s、cycle2 放满50s;三分支判读,幅值阈值有意弃用) / E3 写0x0恢复+60s三要素窗(还原互斥;未齐+30s重验一次) /
//   E4 第二循环 / E5 CHTE 同值回写+pmset 复核+CHIE 终值==0x0 复核 / E6 仅 0x8 成立:CHTE×CHIE 两格+双恢复序各验一次 / P1–P2 功率标定。
// 安全(母本全量沿用,不得收窄): P0-1 状态文件先于首次写原子落盘,还原双验证通过后删; 同值回写探针先行; 每次写 5s 倒计时;
//   放电-on≤60s 看门狗硬界(每段不变)+CHIE 单键预算≤240s(E6 计入,P1-1 放宽); 温度≥40℃或电量出[35,85]每采样点同查→全量还原;
//   预检电量收紧[40,75](P2-1); 信号→全量还原; NoIdleSleep 断言全程; 还原双验证+重试阶梯(3次→等5s→再3轮)+runbook 值级/行为级分列;
//   残留状态文件拒绝启动; 手动兜底 --restore CHIE=0x00; 日志逐行 flush+每次写记 kr; 结论 key=value; 零品牌词。

import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - SMC 常量与错误码（照抄 m0）
private let selectorUniversal: UInt32 = 2
private let cmdRead: UInt8 = 5
private let cmdWrite: UInt8 = 6
private let cmdKeyInfo: UInt8 = 9
private let resultSuccess: UInt8 = 0
private func krExplain(_ kr: Int32) -> String {
    switch kr {
    case kIOReturnSuccess: return "成功"
    case Int32(bitPattern: 0xE00002C1): return "NotPrivileged(写需root)"
    case Int32(bitPattern: 0xE00002C7): return "BadArgument(旧选择器已移除)"
    default: return ""
    }
}
private func resultExplain(_ r: UInt8) -> String {
    switch r {
    case 0: return "OK"
    case 132: return "KeyNotFound(隐藏/不存在)"
    case 137: return "尺寸不符(需两阶段读)"
    default: return ""
    }
}

// MARK: - SMCParam（80B 固定偏移手工封包，照抄 m0；dataType 还原取 m0-smc-probe 同款）
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
    var key: UInt32 { get { Self.u32LE(buf, 0) } set { Self.setU32LE(&buf, 0, newValue) } }
    var dataSize: UInt32 { get { Self.u32LE(buf, 28) } set { Self.setU32LE(&buf, 28, newValue) } }
    var dataTypeRaw: UInt32 { Self.u32LE(buf, 32) }   // 回复 dataType 缓冲内反转，重组还原 4CC
    var dataType: String {
        let v = dataTypeRaw
        let b = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: b, encoding: .ascii) ?? String(format: "0x%08X", v)
    }
    var result: UInt8 { buf[40] }
    var data8: UInt8 { get { buf[42] } set { buf[42] = newValue } }
    var bytes: [UInt8] {
        let n = Int(min(dataSize, 32))
        return Array(buf[48..<(48 + n)])
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

// MARK: - SMCConnection（m0 传输；内部锁串行化——信号/看门狗全局队列与主流程并发调用）
private final class SMCConnection: @unchecked Sendable {
    private let connection: io_connect_t
    private let lock = NSLock()
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
        lock.lock(); defer { lock.unlock() }
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
    /// 两阶段读（macOS 26 必需）：先 getKeyInfo 取 dataSize 再带尺寸读；按请求尺寸切片。
    func read(_ key: String) -> (size: UInt32, type: String, bytes: [UInt8])? {
        guard let info = keyInfo(key) else { return nil }
        let input = SMCParam()
        input.key = SMCParam.pack(key)
        input.data8 = cmdRead
        input.dataSize = info.size
        let (out, kr) = call(input)
        guard kr == KERN_SUCCESS, out.result == resultSuccess else { return nil }
        let n = Int(min(info.size, 32))
        return (info.size, info.type, Array(out.buf[48..<(48 + n)]))
    }
    /// 写；返回 ok + kr/result 原始码（P2-2：每次写必记）。
    func writeDetailed(_ key: String, bytes values: [UInt8]) -> (ok: Bool, kr: kern_return_t, result: UInt8) {
        let input = SMCParam()
        input.key = SMCParam.pack(key)
        input.data8 = cmdWrite
        input.dataSize = UInt32(values.count)
        input.setBytes(values)
        let (out, kr) = call(input)
        return (kr == KERN_SUCCESS && out.result == resultSuccess, kr, out.result)
    }
}

// MARK: - 电池遥测（进程内 IOKit 直读 AppleSmartBattery，无需 root，SMC-NOTES §4）
// Amperage 按位还原有符号值（Int64/UInt64 wrap）；方向判定以 isCharging 为准。
private struct TelemetrySample {
    let percent: Int
    let isCharging: Bool
    let externalConnected: Bool
    let amperageMA: Int
    let voltageMV: Int?
    let temperatureCentiC: Int
    let watts: Int?
    let adapterAmpsMA: Int?
    let adapterVoltsMV: Int?
    let timestamp: Date
    var temperatureC: Double { Double(temperatureCentiC) / 100 }
}
private final class Telemetry: @unchecked Sendable {
    private static func intVal(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber else { return nil }
        return Int(Int64(bitPattern: n.uint64Value))
    }
    private static func boolVal(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        guard let n = v as? NSNumber else { return nil }
        if n.uint64Value == 0 { return false }
        if n.uint64Value == 1 { return true }
        return nil
    }
    func sample() -> TelemetrySample? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let props, let dict = props.takeRetainedValue() as? [String: Any] else { return nil }
        guard let percent = Self.intVal(dict["CurrentCapacity"]),
              let isCharging = Self.boolVal(dict["IsCharging"]),
              let external = Self.boolVal(dict["ExternalConnected"]),
              let amperage = Self.intVal(dict["Amperage"]),
              let temp = Self.intVal(dict["Temperature"]) else { return nil }
        var watts: Int?
        var adapterAmpsMA: Int?
        var adapterVoltsMV: Int?
        if let adapter = dict["AdapterDetails"] as? [String: Any] {
            watts = Self.intVal(adapter["Watts"])
            adapterAmpsMA = Self.intVal(adapter["Amperage"])
            adapterVoltsMV = Self.intVal(adapter["Voltage"])
        }
        return TelemetrySample(percent: percent, isCharging: isCharging, externalConnected: external,
                               amperageMA: amperage, voltageMV: Self.intVal(dict["Voltage"]),
                               temperatureCentiC: temp, watts: watts,
                               adapterAmpsMA: adapterAmpsMA, adapterVoltsMV: adapterVoltsMV, timestamp: Date())
    }
}

// MARK: - 小工具
private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }
private func tempS(_ c: Double) -> String { String(format: "%.1f", c) }
private func fmtFlt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }
private func fmtInt(_ v: Int?) -> String { v.map(String.init) ?? "-" }
private func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
/// SMC 'flt' 4B = IEEE754 单精度、大端字节序（SMC-NOTES §2 已录：PDTR/ID0R/VD0R/PPBR=flt/4B）。
private func decodeFltBE(_ b: [UInt8]) -> Double? {
    guard b.count == 4 else { return nil }
    let bits = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    return Double(Float(bitPattern: bits))
}
/// SMC 'si16' 2B 大端有符号（B0AC，SMC-NOTES §2 实测修正）。
private func decodeSi16BE(_ b: [UInt8]) -> Int? {
    guard b.count >= 2 else { return nil }
    return Int(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1])))
}
/// SMC 'ui16' 2B 大端无符号（B0AV，SMC-NOTES §2 实测修正）。
private func decodeUi16BE(_ b: [UInt8]) -> Int? {
    guard b.count >= 2 else { return nil }
    return Int(UInt16(b[0]) << 8 | UInt16(b[1]))
}
/// 运行外部只读工具并返回 stdout（失败返回空串）。
private func runTool(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}
private func runPmset() -> String { runTool("/usr/bin/pmset", ["-g", "batt"]) }
private func processRunning(_ name: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", name]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}
private func parseHexBytes(_ raw: String) -> [UInt8]? {
    var s = raw
    if s.hasPrefix("0x") || s.hasPrefix("0X") { s = String(s.dropFirst(2)) }
    guard !s.isEmpty, s.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        guard let v = UInt8(s[i..<j], radix: 16) else { return nil }
        out.append(v)
        i = j
    }
    return out
}

// MARK: - 机型/固件头（状态文件与日志；Intel 走 IOFirmwareVersion，AS 回退 system_profiler——macOS 26 起在 /usr/sbin）
private struct MachineInfo {
    let model: String
    let firmware: String
    let macOS: String
    static func gather() -> MachineInfo {
        var model = "?", firmware = "?"
        let expert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if expert != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(expert, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let props, let dict = props.takeRetainedValue() as? [String: Any] {
                model = propString(dict["model"]) ?? "?"
                firmware = propString(dict["IOFirmwareVersion"]) ?? firmwareFromProfiler()
            }
            IOObjectRelease(expert)
        }
        return MachineInfo(model: model, firmware: firmware, macOS: runTool("/usr/bin/sw_vers", ["-productVersion"]).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private static func propString(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let d = v as? Data { return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespaces) }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    private static func firmwareFromProfiler() -> String {
        for line in runTool("/usr/sbin/system_profiler", ["SPHardwareDataType"]).components(separatedBy: "\n")
        where line.contains("System Firmware Version") {
            if let range = line.range(of: ": ") {
                let v = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
        return "?"
    }
}

// MARK: - Logger（线程安全；逐行 flush，P2-2）
private final class Logger: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?
    private let df = DateFormatter()
    let path: String
    init() {
        let d = DateFormatter()
        d.dateFormat = "yyyy-MM-dd"
        path = "/tmp/cellar-spike-" + d.string(from: Date()) + ".log"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        df.dateFormat = "HH:mm:ss.SSS"
    }
    func log(_ msg: String) {
        let line = "[\(df.string(from: Date()))] \(msg)\n"
        lock.lock(); defer { lock.unlock() }
        if let h = handle, let data = line.data(using: .utf8) {
            h.write(data)
            try? h.synchronize()
        }
        if let data = line.data(using: .utf8) { FileHandle.standardOutput.write(data) }
    }
}

// MARK: - 状态持久化（P0-1）
private let stateFilePath = "/tmp/cellar-spike-state.json"
private struct KeyStateEntry: Codable { let key: String; let size: Int; let type: String; let originalHex: String; let writtenAt: String }
private struct StateFile: Codable {
    let version: Int
    let model: String
    let firmware: String
    let macOS: String
    let createdAt: String
    let session: String
    var keys: [String: KeyStateEntry]
}

// MARK: - 会话状态（跨线程字段加锁；实验事实主流程独占）
private final class Session: @unchecked Sendable {
    private let lock = NSLock()
    let logger: Logger
    let machine: MachineInfo
    private let df = DateFormatter()
    var keys: [String: KeyStateEntry] = [:]
    var originals: [String: [UInt8]] = [:]
    private var stateFileCreatedAt = ""
    var baselineIsCharging: Bool?
    var baselineAmperageMA: Int?
    private var dischargeOnSince: Date?
    private var dischargeOnKey: String?
    private var perKeyOnTime: [String: Double] = [:]
    private var sessionOnTime: Double = 0
    private var restoring = false
    private var abortReason: String?
    private var writeEvents: [(t: String, key: String, hex: String, ok: Bool, kr: String)] = []
    var readbackViolations: [String] = []
    var conclusions: [String: String] = [:]
    var candidatePresent: [String: (size: UInt32, type: String, origHex: String)] = [:]
    var establishedKeys: [String: [UInt8]] = [:]
    var restoreOutcomes: [String] = []
    var matrixNotes: [String] = []
    var runbookEntered = false
    init(logger: Logger, machine: MachineInfo) {
        self.logger = logger
        self.machine = machine
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }
    static func stateExists() -> Bool { FileManager.default.fileExists(atPath: stateFilePath) }
    func addBaseline(key: String, size: UInt32, type: String, bytes: [UInt8]) {
        originals[key] = bytes
        keys[key] = KeyStateEntry(key: key, size: Int(size), type: type, originalHex: hex(bytes), writtenAt: "")
    }
    /// 基线充电态锚定（E0 产出；behaviorExpectation 与恢复验证期望值来源）。
    func setBaseline(isCharging: Bool?, amperage: Int?) {
        baselineIsCharging = isCharging
        baselineAmperageMA = amperage
    }
    /// 首次任何 SMC 写入前调用：原子写（.atomic = 临时文件+rename）。
    func writeStateFile() -> Bool {
        let ts = df.string(from: Date())
        if stateFileCreatedAt.isEmpty { stateFileCreatedAt = ts }
        let file = StateFile(version: 1, model: machine.model, firmware: machine.firmware, macOS: machine.macOS, createdAt: ts, session: "cellar-spike-" + ts, keys: keys.mapValues { KeyStateEntry(key: $0.key, size: $0.size, type: $0.type, originalHex: $0.originalHex, writtenAt: stateFileCreatedAt) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: stateFilePath), options: .atomic)
            return true
        } catch { return false }
    }
    func deleteStateFile() {
        try? FileManager.default.removeItem(atPath: stateFilePath)
        stateFileCreatedAt = ""
        logger.log("[P0-1] 状态文件已删除 \(stateFilePath)（还原验证通过的干净结束判据）")
    }
    func loadStateFile() -> (file: StateFile, sortedKeys: [String])? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: stateFilePath)),
              let file = try? JSONDecoder().decode(StateFile.self, from: data) else { return nil }
        for (k, e) in file.keys {
            originals[k] = parseHexBytes(e.originalHex)
            keys[k] = e
        }
        return (file, file.keys.keys.sorted())
    }
    func sortedKeys() -> [String] { keys.keys.sorted() }
    /// 行为期望：基线 isCharging 优先；--restore 无基线时按 CHTE 原值推导。
    func behaviorExpectation() -> Bool? {
        if let b = baselineIsCharging { return b }
        if let chte = originals["CHTE"] {
            if chte == [0, 0, 0, 0] { return true }
            if chte == [1, 0, 0, 0] { return false }
        }
        return nil
    }
    func beginDischarge(_ key: String) { lock.lock(); defer { lock.unlock() }; dischargeOnSince = Date(); dischargeOnKey = key }
    /// 结束放电并累计预算；返回本次 on-time 秒。
    func endDischarge() -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let since = dischargeOnSince, let key = dischargeOnKey else { return 0 }
        let t = Date().timeIntervalSince(since)
        perKeyOnTime[key, default: 0] += t
        sessionOnTime += t
        dischargeOnSince = nil
        dischargeOnKey = nil
        return t
    }
    func onTimeNow() -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let since = dischargeOnSince else { return 0 }
        return Date().timeIntervalSince(since)
    }
    var isRestoring: Bool { lock.lock(); defer { lock.unlock() }; return restoring }
    /// 还原互斥入口；顺带结算未结束的放电 on-time（看门狗/信号路径同走此门）。
    func beginRestore() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !restoring else { return false }
        restoring = true
        if let since = dischargeOnSince, let key = dischargeOnKey {
            let t = Date().timeIntervalSince(since)
            perKeyOnTime[key, default: 0] += t
            sessionOnTime += t
            dischargeOnSince = nil
            dischargeOnKey = nil
        }
        return true
    }
    func endRestore() { lock.lock(); defer { lock.unlock() }; restoring = false }
    func requestAbort(_ reason: String) { lock.lock(); defer { lock.unlock() }; if abortReason == nil { abortReason = reason } }
    func takeAbortReason() -> String? { lock.lock(); defer { lock.unlock() }; let r = abortReason; abortReason = nil; return r }
    /// 单键累计预算（WP1.5：CHIE ≤240s，E6 计入——评审 P1-1；每段 on 仍受 60s 看门狗硬界）。
    func budgetExceeded(_ key: String, limitS: Double = 240) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (perKeyOnTime[key] ?? 0) >= limitS
    }
    func recentBudgetSnapshot() -> [String: Double] { lock.lock(); defer { lock.unlock() }; return perKeyOnTime }
    func sessionOnTimeTotal() -> Double { lock.lock(); defer { lock.unlock() }; return sessionOnTime }
    func recordWrite(key: String, bytes: [UInt8], ok: Bool, kr: Int32, result: UInt8) {
        let t = df.string(from: Date())
        let krS = String(format: "0x%08X", kr)
        lock.lock()
        writeEvents.append((t: t, key: key, hex: hex(bytes), ok: ok, kr: krS))
        if writeEvents.count > 300 { writeEvents.removeFirst(writeEvents.count - 300) }
        lock.unlock()
        logger.log("SMC写 key=\(key) value=\(hex(bytes)) kr=\(krS)(\(krExplain(kr))) result=\(result)(\(resultExplain(result)))")
    }
    func recentWriteEvents(_ n: Int) -> [(t: String, key: String, hex: String, ok: Bool, kr: String)] {
        lock.lock(); defer { lock.unlock() }
        return Array(writeEvents.suffix(n))
    }
    // 以下集合会被看门狗全局队列线程（runbook/还原路径）与主线程并发访问——
    // 一律经锁写入（评审 P1-2：无锁并发写 Dictionary/Array 是真实崩溃源）。
    func recordReadbackViolation(_ msg: String) { lock.lock(); defer { lock.unlock() }; readbackViolations.append(msg) }
    func markRunbook() { lock.lock(); defer { lock.unlock() }; runbookEntered = true }
    func noteMatrix(_ s: String) { lock.lock(); defer { lock.unlock() }; matrixNotes.append(s) }
    func concl(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        conclusions[key] = value
        logger.log("concl.\(key)=\(value)")
    }
    /// 锁通道读取（评审 MEDIUM：报告发射期间信号仍可能并发写 conclusions）。
    func conclusion(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return conclusions[key] }
    func appendRestoreOutcome(_ s: String) { lock.lock(); defer { lock.unlock() }; restoreOutcomes.append(s) }
    func restoreOutcomesSnapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return restoreOutcomes }
    var isRunbookEntered: Bool { lock.lock(); defer { lock.unlock() }; return runbookEntered }
    func logBudget(key: String) {
        lock.lock()
        let perKey = Int(perKeyOnTime[key] ?? 0)
        let session = Int(sessionOnTime)
        lock.unlock()
        logger.log("预算：单键累计 \(key)=\(perKey)s / 上限240s（WP1.5 P1-1 放宽；每段 on 仍受 60s 看门狗硬界）；会话累计 \(session)s")
    }
}

// MARK: - 防睡眠断言（P1-6：全程持有 NoIdleSleep，等效 caffeinate -i）
private final class SleepGuardian: @unchecked Sendable {
    private var assertionID: IOPMAssertionID = 0
    private var held = false
    func acquire() -> Bool {
        let type = kIOPMAssertionTypeNoIdleSleep as CFString
        let name = "Cellar 放电键调研会话（运行期间请勿合盖）" as CFString
        let kr = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &assertionID)
        held = kr == kIOReturnSuccess
        return held
    }
    func release() { if held { IOPMAssertionRelease(assertionID); held = false } }
}

// MARK: - 看门狗（P1-9：全局队列 dispatch，独立于主流程；主流程卡死时超时仍生效）
private final class Watchdog {
    private let timer: DispatchSourceTimer
    init(handler: @escaping () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { handler() }
        timer.resume()
    }
    func stop() { timer.cancel() }
}

// MARK: - 还原引擎（P0-2：双验证 + 重试阶梯 + runbook 值级/行为级分列 + 现场记录）
private final class RestoreEngine: @unchecked Sendable {
    private let smc: SMCConnection
    private let telemetry: Telemetry
    private let session: Session
    private let logger: Logger
    enum Outcome { case verified, failedValue([String: String]), failedBehavior, alreadyRestoring }
    init(smc: SMCConnection, telemetry: Telemetry, session: Session, logger: Logger) {
        self.smc = smc; self.telemetry = telemetry; self.session = session; self.logger = logger
    }
    /// 全量还原（多键泛化，m0 单键闭包的边界差异）：值级阶梯 → 行为验证 → 通过删状态文件。
    func fullRestore(reason: String) -> Outcome {
        guard session.beginRestore() else { return .alreadyRestoring }
        defer { session.endRestore() }
        logger.log("[还原] 开始全量还原 reason=\(reason) keys=[\(session.sortedKeys().joined(separator: ","))]")
        var valueFail: [String: String] = [:]
        for key in session.sortedKeys() {
            if let fail = restoreKeyWithLadder(key) { valueFail[key] = fail }
        }
        if !valueFail.isEmpty { session.markRunbook(); runbookValue(valueFail: valueFail); return .failedValue(valueFail) }
        guard behaviorVerified(expectCharging: session.behaviorExpectation(), graceS: 30, retried: false) else {
            session.markRunbook(); runbookBehavior(); return .failedBehavior
        }
        session.deleteStateFile()
        logger.log("[还原] 还原双验证通过（值回读==原值 且 行为恢复）")
        return .verified
    }
    /// 实验步内单键还原；false = 会话中止（runbook 已触发）。
    func restoreOneKeyVerified(_ key: String) -> Bool {
        guard session.originals[key] != nil else { return false }
        if let fail = restoreKeyWithLadder(key) { session.markRunbook(); runbookValue(valueFail: [key: fail]); return false }
        guard behaviorVerified(expectCharging: session.behaviorExpectation(), graceS: 30, retried: false) else {
            session.markRunbook(); runbookBehavior(); return false
        }
        return true
    }
    /// 单键阶梯还原，不做行为验证（E3 专用）：E3 自带 60s 三要素观察窗 = 判据③「恢复语义
    /// 完整」的测量窗；behaviorVerified 的 30s 宽限 = 还原后的安全验证窗——两者语义不同、
    /// 可共存、互不替代（评审观察 2）。nil = 值级成功。
    func restoreKeyLadder(_ key: String) -> String? { restoreKeyWithLadder(key) }
    /// 重试阶梯：3 次 → 等 5s → 再 3 轮（共 9 轮）。nil = 成功。
    private func restoreKeyWithLadder(_ key: String) -> String? {
        guard let original = session.originals[key] else { return "无 \(key) 原始值记录" }
        let h = hex(original)
        for round in 0..<9 {
            if round == 3 || round == 6 { logger.log("[还原] \(key) 阶梯第 \(round + 1) 轮前等 5s"); Thread.sleep(forTimeInterval: 5) }
            let (ok, kr, result) = smc.writeDetailed(key, bytes: original)
            session.recordWrite(key: key, bytes: original, ok: ok, kr: kr, result: result)
            Thread.sleep(forTimeInterval: 0.5)
            guard ok, let back = smc.read(key), back.bytes == original else { continue }
            logger.log("[还原] \(key) 回读一致 value=\(h)")
            return nil
        }
        return "\(key) 9 轮重试后仍无法还原到 \(h)"
    }
    /// 行为验证：外部电源恢复 + isCharging 与期望一致；30s 宽限轮询（2s），超时重验一次（P2-4）。
    func behaviorVerified(expectCharging: Bool?, graceS: Int, retried: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(graceS))
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 2)
            guard let s = telemetry.sample() else { continue }
            let chargeOK = expectCharging == nil || s.isCharging == expectCharging
            logger.log("[验证] ext=\(s.externalConnected) isCharging=\(s.isCharging) amp=\(s.amperageMA)mA temp=\(tempS(s.temperatureC))℃ percent=\(s.percent)% 期望isCharging=\(expectCharging.map { $0 ? "true" : "false" } ?? "不限")")
            if s.externalConnected && chargeOK {
                logger.log("[验证] 行为恢复成立；pmset: \(runPmset().replacingOccurrences(of: "\n", with: " | "))")
                return true
            }
        }
        if !retried {
            logger.log("[验证] \(graceS)s 宽限未恢复，5s 后重验一次（P2-4）")
            Thread.sleep(forTimeInterval: 5)
            return behaviorVerified(expectCharging: expectCharging, graceS: graceS, retried: true)
        }
        return false
    }
    private func runbookValue(valueFail: [String: String]) {
        logger.log("[runbook] 终态处置：形态=值级失败（回写报错/回读不一致）\n[runbook] 引导：保持适配器连接、不要合盖、勿重启（重启是否清除键状态属未知）\n[runbook] 引导：手动兜底 sudo .build/debug/spike-discharge --restore\n[runbook] 引导：仍失败则保留状态文件与日志交工程师分析\n[runbook] 键明细：\(valueFail)")
        dumpScene()
    }
    private func runbookBehavior() {
        logger.log("[runbook] 终态处置：形态=行为级失败（值回读一致但行为滞留）\n[runbook] 引导 1：物理重插适配器（闩锁语义候选处置）\n[runbook] 引导 2：重插后重跑 sudo .build/debug/spike-discharge --restore\n[runbook] 引导 3：仍不恢复则保留状态文件与日志交工程师分析")
        dumpScene()
    }
    private func dumpScene() {
        logger.log("[现场] === 现场记录开始 ===")
        for key in session.sortedKeys() {
            let current = smc.read(key).map { hex($0.bytes) } ?? "读失败"
            logger.log("[现场] key=\(key) original=\(session.originals[key].map(hex) ?? "?") current=\(current)")
        }
        for e in session.recentWriteEvents(40) {
            logger.log("[现场] \(e.t) 写 \(e.key)=\(e.hex) ok=\(e.ok) kr=\(e.kr)")
        }
        logger.log("[现场] === 现场记录结束 ===")
        session.concl("reboot.clearState", "unknown(实验记录项，不得断言)")
    }
}

// MARK: - WP1.5 放电重调 spike 常量（方案 v1.1 定版）
// CHIE 值集固定 {0x8}（Tahoe 代 disable 语义，batt adapter.go/consts_arm64.go 佐证；0x1 属旧代
// 键语义、WP1 已实测无效）。禁用旧值扫描与 CH0I/CH0C 重枚举——两键 WP1 已录 getKeyInfo 132
// 已删除（§7.1），getKeyInfo 不可读自动跳过逻辑保留。恢复值 0x0（=基线原值）。
private let spikeKeys = ["CHIE", "CHTE"]
private let chieDisable: [UInt8] = [0x08]

// MARK: - 功率键读值（P1 标定；类型以 SMC-NOTES §2 已录为准——评审 P1-6，getKeyInfo 为复核而非发现）
private struct PowerSMC {
    let pdtr: Double?    // W（flt 4B）
    let id0r: Double?    // 输入电流 mA（flt 4B）
    let vd0r: Double?    // 电压 mV（flt 4B）
    let ppbr: Double?    // 电池功率 W（flt 4B）
    let b0ac: Int?       // 电池电流（si16 2B BE）
    let b0av: Int?       // 电池电压 mV（ui16 2B BE）
    static func read(smc: SMCConnection) -> PowerSMC {
        PowerSMC(pdtr: smc.read("PDTR").flatMap { decodeFltBE($0.bytes) },
                 id0r: smc.read("ID0R").flatMap { decodeFltBE($0.bytes) },
                 vd0r: smc.read("VD0R").flatMap { decodeFltBE($0.bytes) },
                 ppbr: smc.read("PPBR").flatMap { decodeFltBE($0.bytes) },
                 b0ac: smc.read("B0AC").flatMap { decodeSi16BE($0.bytes) },
                 b0av: smc.read("B0AV").flatMap { decodeUi16BE($0.bytes) })
    }
}
/// 一组背靠背配对样本（SMC 功率键 + ioreg 遥测同循环）。
private struct PowerPair {
    let smc: PowerSMC
    let ioregAmpMA: Int
    let ioregVoltMV: Int?
    let adapterWatts: Int?
    let adapterAmpsMA: Int?
    let adapterVoltsMV: Int?
}

// MARK: - Runner（四模式：--enumerate / --do-it / --restore / --calibrate-power）
private final class Runner: @unchecked Sendable {
    private let logger: Logger
    private let machine: MachineInfo
    private let telemetry = Telemetry()
    private let smc: SMCConnection
    private let session: Session
    private let engine: RestoreEngine
    private let guardian = SleepGuardian()
    private var watchdog: Watchdog?
    private var signalSources: [DispatchSourceSignal] = []
    private let sampleDF = DateFormatter()
    /// 判据④预注册判读表逐条记录（步骤:写入值→实际读回值）。
    private var readbackTable: [String] = []
    init?() {
        logger = Logger()
        machine = MachineInfo.gather()
        guard let smc = SMCConnection() else { return nil }
        self.smc = smc
        session = Session(logger: logger, machine: machine)
        engine = RestoreEngine(smc: smc, telemetry: telemetry, session: session, logger: logger)
        sampleDF.dateFormat = "HH:mm:ss.SSS"
    }
    func run(_ args: [String]) -> Int32 {
        logger.log("=== 放电重调 spike 会话 uid=\(getuid()) 机型=\(machine.model) 固件=\(machine.firmware) macOS=\(machine.macOS) 日志=\(logger.path) ===")
        if args.contains("--help") || args.contains("-h") { printUsage(); return 0 }
        if args.contains("--enumerate") { return enumerate() }
        if args.contains("--calibrate-power") { return calibratePowerMode() }
        if args.contains("--do-it") { return doIt() }
        if args.contains("--restore") {
            var manuals: [(key: String, bytes: [UInt8])] = []
            for a in args where a.contains("=") && !a.hasPrefix("--") {
                let parts = a.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let k = String(parts[0])
                guard k.count == 4, let b = parseHexBytes(String(parts[1])) else { continue }
                manuals.append((k, b))
            }
            guard manuals.count <= 1 else { logger.log("--restore 手动兜底一次仅接受一个 KEY=HEX"); return 2 }
            return restore(manual: manuals.first)
        }
        printUsage()
        return 2
    }
    private func printUsage() {
        logger.log("""
        用法（canonical：user 侧构建 → sudo 只执行不构建，方案 §1.8。本脚本不在 SPM target 内，
        swift build 不产出该二进制——用 swiftc 单文件构建）:
          swiftc -O Tools/spike-discharge.swift -o .build/debug/spike-discharge   # user 侧构建
          sudo .build/debug/spike-discharge --do-it              # E0–E6 全流程写实验(root;状态文件门禁)
          sudo .build/debug/spike-discharge --restore            # 按状态文件逐键还原
          sudo .build/debug/spike-discharge --restore CHIE=0x00  # 手动兜底(KEY=HEX)
          .build/debug/spike-discharge --calibrate-power         # 功率键标定(只读,无需 root)
          swift Tools/spike-discharge.swift --enumerate          # 只读预检(无需 sudo,免构建)
          .build/debug/spike-discharge --help                    # 本帮助
        """)
    }
    private func countdown(_ seconds: Int, summary: String) {
        for i in stride(from: seconds, through: 1, by: -1) {
            logger.log("[倒计时] \(i)s 后执行：\(summary)（Ctrl-C 立即全量还原）")
            Thread.sleep(forTimeInterval: 1)
        }
    }
    /// 同值回写探针（P1-4：写通路验证；失败整键退出）。
    private func probeWrite(key: String) -> Bool {
        guard let cur = smc.read(key) else { return false }
        let (ok, kr, result) = smc.writeDetailed(key, bytes: cur.bytes)
        session.recordWrite(key: key, bytes: cur.bytes, ok: ok, kr: kr, result: result)
        Thread.sleep(forTimeInterval: 0.5)
        guard ok, let back = smc.read(key), back.bytes == cur.bytes else {
            logger.log("[探针] \(key) 同值回写失败（写/回读不一致）——中止该键路径")
            return false
        }
        logger.log("[探针] \(key) 同值回写一致 value=\(hex(cur.bytes))（写通路可靠）")
        return true
    }
    /// 写期望值：已是目标态跳过；否则 5s 倒计时 + 写 + kr 记录 + 回读验证（判据④；任何
    /// 不一致必须记录实际读回值——补 WP1 §7.1 未记 0x1 实际读回值的缺憾）。
    @discardableResult
    private func writeExpect(key: String, value: [UInt8], expected: [UInt8], skipCountdown: Bool = false, step: String = "-") -> Bool {
        guard let cur = smc.read(key) else { return false }
        if cur.bytes == value { logger.log("[写] \(key) 已是目标态 \(hex(value))——无需写"); return true }
        logger.log("[写] \(key)：\(hex(cur.bytes)) → \(hex(value))")
        if !skipCountdown { countdown(5, summary: "写 \(key)=\(hex(value))") }
        let (ok, kr, result) = smc.writeDetailed(key, bytes: value)
        session.recordWrite(key: key, bytes: value, ok: ok, kr: kr, result: result)
        Thread.sleep(forTimeInterval: 0.5)
        guard ok, let back = smc.read(key) else {
            session.recordReadbackViolation("\(key) 写 \(hex(value)) 写入失败(kr=\(String(format: "0x%08X", kr)))或回读失败（判据④违反）")
            logger.log("[写] \(key)=\(hex(value)) 写入/回读失败——判据④违反")
            return false
        }
        if back.bytes != expected {
            session.recordReadbackViolation("\(key) 写 \(hex(value)) 后回读=\(hex(back.bytes))≠期望 \(hex(expected))（判据④违反，实际读回值=\(hex(back.bytes))）")
            logger.log("[写] \(key)=\(hex(value)) 回读=\(hex(back.bytes)) ≠期望——判据④违反（实际读回值已记录）")
            return false
        }
        readbackTable.append("\(step):\(hex(value))→\(hex(back.bytes))")
        logger.log("[写] \(key)=\(hex(value)) 回读一致（判据④ ✓）")
        return true
    }
    /// 安全阈值（§1.5 母本定版）：温度 ≥40°C 或电量出 [35,85] → 全量还原并中止。
    /// 每个采样点与温度同查（checkSafety 语义不变）。
    private func checkSafety(_ s: TelemetrySample) -> Bool {
        var trip = ""
        if s.temperatureCentiC >= 4000 { trip = "温度 \(s.temperatureC)℃ 达 40℃ 阈值" }
        if s.percent < 35 || s.percent > 85 { trip += (trip.isEmpty ? "" : "；") + "电量 \(s.percent)% 出 [35,85] 区间" }
        if !trip.isEmpty {
            logger.log("[安全] 触发阈值：\(trip)——全量还原并中止")
            _ = session.endDischarge()
            let o = engine.fullRestore(reason: "安全阈值超限：" + trip)
            reportRestoreOutcome(o)
            finalExit(130, note: "安全阈值超限")
        }
        return trip.isEmpty
    }
    private func finalExit(_ code: Int32, note: String) -> Never {
        logger.log("=== 会话中止：\(note)（退出码 \(code)）===")
        guardian.release()
        exit(code)
    }
    private func reportRestoreOutcome(_ o: RestoreEngine.Outcome) {
        switch o {
        case .verified: session.concl("restore.last", "verified")
        case .alreadyRestoring: logger.log("[还原] 另一路还原进行中，跳过")
        case .failedValue(let fail): session.concl("restore.last", "failed-value"); logger.log("[还原] 值级失败 keys=\(fail)")
        case .failedBehavior: session.concl("restore.last", "failed-behavior"); logger.log("[还原] 行为级失败（值回读一致但行为滞留）")
        }
    }
    // MARK: 信号安全网 + 看门狗（m0 DispatchSourceSignal 模式；采样循环不被阻塞）
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.global())
            src.setEventHandler { [weak self] in self?.handleSignal(sig) }
            src.resume()
            signalSources.append(src)
        }
    }
    private func handleSignal(_ sig: Int32) {
        let reason = "收到信号 \(sig)"
        logger.log("[中断] \(reason)——触发全量还原")
        if session.isRestoring {
            logger.log("[中断] 还原互斥中——登记中止请求，主流程完成后退出")
            session.requestAbort(reason)
            return
        }
        _ = session.endDischarge()
        let o = engine.fullRestore(reason: reason)
        reportRestoreOutcome(o)
        finalExit(130, note: reason)
    }
    /// 看门狗 tick（全局队列，独立于主流程）：放电-on 每段超 60s 硬上限 → 全量还原。
    /// WP1.5 预算放宽只作用于单键累计（240s），每段 60s 硬界不变（评审 P1-1）。
    private func watchdogTick() {
        let on = session.onTimeNow()
        guard on > 60 else { return }
        if session.isRestoring {
            logger.log("[看门狗] 放电-on \(Int(on))s 超 60s，但还原进行中——交由进行中的还原完成")
            return
        }
        logger.log("[看门狗] 放电-on \(Int(on))s 超 60s 硬上限——触发全量还原（P1-9）")
        _ = session.endDischarge()
        let o = engine.fullRestore(reason: "看门狗：放电-on 超过 60s 硬上限")
        reportRestoreOutcome(o)
        finalExit(131, note: "看门狗 60s 硬上限")
    }
    // MARK: 只读预检（enumerate 宽松报告 / do-it 严格门禁共用）
    private func runPreflight(strict: Bool) -> Bool {
        var ok = true
        let fail = { (check: String) in self.logger.log("[检查] \(check)=失败"); ok = false }
        if let s = telemetry.sample() {
            if s.externalConnected { logger.log("[检查] 外接电源=通过") } else { fail("外接电源"); logger.log("[检查]     请插电后重试") }
            // P2-1：预检电量收紧 [40,80]→[40,75]（daemon 卸载后 CHTE=0 自由充电 ~+0.6%/min，
            // E0–E6 约 8–10 min，从 80% 起跑可能上穿 85% 触发中止、实验作废）。
            if (40...75).contains(s.percent) {
                logger.log("[检查] 电量 40-75%=通过 (\(s.percent)%)")
            } else {
                fail("电量 40-75%")
                logger.log("[检查]     电量 \(s.percent)% 请调整后重试（P2-1：防卸载后自由充电上穿 85%）")
            }
            if s.temperatureC < 35 { logger.log("[检查] 温度<35℃=通过 (\(tempS(s.temperatureC))℃)") } else { fail("温度<35℃"); logger.log("[检查]     温度 \(tempS(s.temperatureC))℃") }
        } else { fail("电池遥测"); logger.log("[检查]     遥测服务不可用") }
        if smc.read("CHTE") != nil { logger.log("[检查] CHTE 可读=通过") } else { fail("CHTE 可读") }
        if smc.read("CHIE") != nil { logger.log("[检查] CHIE 可读=通过") } else { fail("CHIE 可读") }
        // 仅检查 root 写入者（cellar-daemon 精确名）。⚠️ 不检查菜单栏 App（"Cellar"）：
        // App 是用户态面板，不写 SMC，spike 期间本就该运行（用户还要用它卸载/重装）——
        // 把它算作冲突是真机验收事故（2026-09-02：App 常驻导致预检永远失败）。
        if processRunning("cellar-daemon") {
            fail("daemon 停用")
            logger.log("[检查]     daemon 运行中——请经 App 面板停用/卸载（禁止 launchctl，保持用户态合规）")
        } else { logger.log("[检查] daemon 未运行=通过") }
        if Session.stateExists() {
            fail("状态文件门禁")
            logger.log("[检查]     存在未清理状态文件 \(stateFilePath)——请先 sudo .build/debug/spike-discharge --restore")
        } else { logger.log("[检查] 状态文件门禁=通过（无残留）") }
        if strict && !ok { logger.log("[检查] 前置检查未通过，拒绝进入写实验") }
        return ok
    }
    /// 键元数据扫描（WP1.5 键集 = CHIE/CHTE；旧代键重枚举禁用，getKeyInfo 不可读自动跳过保留）。
    private func scanKeys(recordBaseline: Bool) {
        for k in spikeKeys {
            if let info = smc.keyInfo(k), let r = smc.read(k) {
                session.candidatePresent[k] = (info.size, info.type, hex(r.bytes))
                if recordBaseline { session.addBaseline(key: k, size: info.size, type: info.type, bytes: r.bytes) }
                logger.log("enumerate.\(k)=存在 type=\(info.type) size=\(info.size) 原值=\(hex(r.bytes))")
            } else { logger.log("enumerate.\(k)=不存在（getKeyInfo 132 自动跳过）") }
        }
    }
    // MARK: --enumerate（只读预检）
    private func enumerate() -> Int32 {
        logger.log("模式：--enumerate（只读预检）")
        logger.log("--- 键元数据（getKeyInfo；WP1.5 键集=CHIE/CHTE，旧代键重枚举已禁用）---")
        scanKeys(recordBaseline: false)
        logger.log("--- 只读预检 ---")
        let ready = runPreflight(strict: false)
        p1KeyInfoCheck()
        if let s = telemetry.sample() {
            logger.log("telemetry.baseline=amperageMA=\(s.amperageMA) voltageMV=\(fmtInt(s.voltageMV)) isCharging=\(s.isCharging) externalConnected=\(s.externalConnected) temperatureC=\(tempS(s.temperatureC)) percent=\(s.percent)%\(s.watts.map { " watts=\($0)" } ?? "")")
        }
        logger.log(ready ? "预检结论：就绪（可执行 --do-it）" : "预检结论：未就绪（--enumerate 为只读，键清单已输出）")
        logger.log("提示：功率键标定可运行 --calibrate-power（只读，无需 root）")
        return 0
    }
    // MARK: P1 功率键标定（只读；--calibrate-power 与 E0 窗共用）
    /// P1 前半：功率键 getKeyInfo 复核 ×6（类型/尺寸对照 §2 已录；复核而非发现——P1-6）。
    private func p1KeyInfoCheck() {
        let expect: [String: (String, UInt32)] = ["PDTR": ("flt", 4), "ID0R": ("flt", 4), "VD0R": ("flt", 4),
                                                  "PPBR": ("flt", 4), "B0AC": ("si16", 2), "B0AV": ("ui16", 2)]
        for (k, e) in expect.sorted(by: { $0.key < $1.key }) {
            if let info = smc.keyInfo(k) {
                let match = info.type == e.0 && info.size == e.1
                logger.log("P1.keyInfo.\(k)=\(info.type)/\(info.size)B 期望 \(e.0)/\(e.1)B \(match ? "一致" : "不符(以实测为准记录)")")
            } else { logger.log("P1.keyInfo.\(k)=不可读（getKeyInfo 132 自动跳过语义保留）") }
        }
    }
    /// 背靠背配对采样（P1）：SMC 功率键读与 ioreg 遥测读同一循环紧邻完成。
    private func pairedOnce() -> PowerPair? {
        let s = PowerSMC.read(smc: smc)
        guard let t = telemetry.sample() else { return nil }
        return PowerPair(smc: s, ioregAmpMA: t.amperageMA, ioregVoltMV: t.voltageMV,
                         adapterWatts: t.watts, adapterAmpsMA: t.adapterAmpsMA, adapterVoltsMV: t.adapterVoltsMV)
    }
    private func pairedSamples(count: Int, intervalS: Double) -> [PowerPair] {
        var out: [PowerPair] = []
        for i in 0..<count {
            if i > 0 { Thread.sleep(forTimeInterval: intervalS) }
            if let p = pairedOnce() {
                out.append(p)
                logger.log("[P1] #\(i + 1)/\(count) \(pairLine(p))")
            } else { logger.log("[P1] #\(i + 1)/\(count) 遥测不可用——跳过") }
        }
        return out
    }
    private func pairLine(_ p: PowerPair) -> String {
        "smc{PDTR=\(fmtFlt(p.smc.pdtr))W ID0R=\(fmtFlt(p.smc.id0r))mA VD0R=\(fmtFlt(p.smc.vd0r))mV PPBR=\(fmtFlt(p.smc.ppbr))W B0AC=\(fmtInt(p.smc.b0ac)) B0AV=\(fmtInt(p.smc.b0av))} ioreg{amp=\(p.ioregAmpMA)mA volt=\(fmtInt(p.ioregVoltMV))mV adapter=\(fmtInt(p.adapterWatts))W}"
    }
    /// 界检查（方案 §3）：0 < 值 ≤ 同量纲适配器能力上界；无上界记录时只查正值。
    private func boundOK(_ v: Double?, _ cap: Int?) -> Bool {
        guard let v, v > 0 else { return false }
        guard let cap, cap > 0 else { return true }
        return v <= Double(cap)
    }
    /// P1 标定产出（锚点表，方案 §3）：B0AC↔Amperage(mA)、B0AV↔Voltage(mV)、
    /// PPBR↔Amperage×Voltage 换算功率 W（容差 ±10%）；PDTR/ID0R/VD0R 只做界检查——
    /// AdapterDetails 是协商档位（65W/3250mA），禁止等值对照。
    private func emitCalibration(_ pairs: [PowerPair]) {
        func stat(_ xs: [Double]) -> String {
            guard let m = mean(xs) else { return "n/a" }
            return String(format: "%.3f(n=%d)", m, xs.count)
        }
        let pdtrVals = pairs.compactMap { $0.smc.pdtr }
        let id0rVals = pairs.compactMap { $0.smc.id0r }
        let vd0rVals = pairs.compactMap { $0.smc.vd0r }
        session.concl("calibration.pdtr", "smc=\(stat(pdtrVals))W bounds=0<v≤adapterWatts \(pairs.allSatisfy { boundOK($0.smc.pdtr, $0.adapterWatts) } ? "pass" : "fail")")
        session.concl("calibration.id0r", "smc=\(stat(id0rVals))mA bounds=0<v≤adapterAmps \(pairs.allSatisfy { boundOK($0.smc.id0r, $0.adapterAmpsMA) } ? "pass" : "fail")")
        session.concl("calibration.vd0r", "smc=\(stat(vd0rVals))mV bounds=0<v≤adapterVolts \(pairs.allSatisfy { boundOK($0.smc.vd0r, $0.adapterVoltsMV) } ? "pass" : "fail")")
        emitCalibrationAnchors(pairs, stat: stat)
    }
    private func emitCalibrationAnchors(_ pairs: [PowerPair], stat: ([Double]) -> String) {
        var deltas = [Double]()
        for p in pairs {
            guard let ppbr = p.smc.ppbr, p.ioregAmpMA > 0, let v = p.ioregVoltMV, v > 0 else { continue }
            let w = Double(p.ioregAmpMA) * Double(v) / 1_000_000
            if w > 0 { deltas.append((ppbr - w) / w * 100) }
        }
        if let md = mean(deltas) {
            let ok = deltas.allSatisfy { abs($0) <= 10 }
            session.concl("calibration.ppbr", "smc=\(stat(pairs.compactMap { $0.smc.ppbr }))W vs ioreg-amp×volt meanDelta=\(String(format: "%+.1f", md))% 容差±10% \(ok ? "pass" : "fail")")
        } else {
            session.concl("calibration.ppbr", "smc=\(stat(pairs.compactMap { $0.smc.ppbr }))W vs ioreg-amp×volt 无有效配对（P2 退化为充电态标定可接受）")
        }
        // B0AC/B0AV：无既定单位断言，raw + ioreg 配对 + 比例入表（S4 判读刻度）。
        let acRatios = pairs.compactMap { p -> Double? in
            guard let raw = p.smc.b0ac, p.ioregAmpMA != 0 else { return nil }
            return Double(raw) / Double(p.ioregAmpMA)
        }
        let avRatios = pairs.compactMap { p -> Double? in
            guard let raw = p.smc.b0av, let v = p.ioregVoltMV, v != 0 else { return nil }
            return Double(raw) / Double(v)
        }
        session.concl("calibration.b0ac", "raw=[\(pairs.compactMap { $0.smc.b0ac }.map(String.init).joined(separator: "/"))] ioregAmp=[\(pairs.map { String($0.ioregAmpMA) }.joined(separator: "/"))] ratio=\(stat(acRatios))")
        session.concl("calibration.b0av", "raw=[\(pairs.compactMap { $0.smc.b0av }.map(String.init).joined(separator: "/"))] ioregVolt=[\(pairs.compactMap { $0.ioregVoltMV }.map(String.init).joined(separator: "/"))] ratio=\(stat(avRatios))")
    }
    // MARK: --calibrate-power（只读标定，不写任何 SMC 键）
    private func calibratePowerMode() -> Int32 {
        logger.log("模式：--calibrate-power（只读标定；无需 root；不写任何 SMC 键、无状态文件）")
        guard let s0 = telemetry.sample() else { logger.log("电池遥测不可用——中止"); return 1 }
        logger.log("telemetry=amp=\(s0.amperageMA)mA volt=\(fmtInt(s0.voltageMV))mV percent=\(s0.percent)% ext=\(s0.externalConnected) isCharging=\(s0.isCharging) adapter=\(fmtInt(s0.watts))W")
        p1KeyInfoCheck()
        let pairs = pairedSamples(count: 10, intervalS: 2)
        guard !pairs.isEmpty else { logger.log("无有效配对样本——中止"); return 1 }
        emitCalibration(pairs)
        logger.log("标定完成：锚点表与 calibration.* 结论见上方（AdapterDetails=协商档位，禁止等值对照；建议充电态大幅值窗口运行以定刻度——P2）")
        return 0
    }
    // MARK: --do-it（E0–E6 + P1/P2 全流程）
    /// 全量落盘字段行（任务 ⑦）：时间戳/电量/电流/电压/温度/CHTE 回读/CHIE 回读/
    /// ExternalConnected/isCharging/功率键读值/ioreg 配对值。
    private func fullSampleLine(tag: String, s: TelemetrySample) -> String {
        let p = PowerSMC.read(smc: smc)
        let chte = smc.read("CHTE").map { hex($0.bytes) } ?? "读失败"
        let chie = smc.read("CHIE").map { hex($0.bytes) } ?? "读失败"
        return "[\(tag)] ts=\(sampleDF.string(from: s.timestamp)) amp=\(s.amperageMA)mA volt=\(fmtInt(s.voltageMV))mV percent=\(s.percent)% temp=\(tempS(s.temperatureC))℃ ext=\(s.externalConnected) isCharging=\(s.isCharging) CHTE=\(chte) CHIE=\(chie) PDTR=\(fmtFlt(p.pdtr))W ID0R=\(fmtFlt(p.id0r))mA VD0R=\(fmtFlt(p.vd0r))mV PPBR=\(fmtFlt(p.ppbr))W B0AC=\(fmtInt(p.b0ac)) B0AV=\(fmtInt(p.b0av)) adapter=\(fmtInt(s.watts))W"
    }
    /// E0 基线 60s（插电、daemon 已卸载、CHTE=0、CHIE=0）；嵌 P1 标定主采样（P2：充电态窗为主）。
    private func e0Baseline() -> Bool {
        logger.log("=== E0：基线采集 60s（嵌 P1 功率键标定，充电态窗）===")
        p1KeyInfoCheck()
        var pairs: [PowerPair] = []
        var last: TelemetrySample?
        for i in 0..<30 {   // 2s × 30 = 60s
            if i > 0 { Thread.sleep(forTimeInterval: 2) }
            if pairs.count < 10, let p = pairedOnce() {
                pairs.append(p)
                logger.log("[P1] #\(pairs.count)/10 \(pairLine(p))")
            }
            guard let s = telemetry.sample() else { logger.log("[E0] #\(i + 1)/30 遥测不可用——不计"); continue }
            if !checkSafety(s) { return false }
            last = s
            logger.log(fullSampleLine(tag: "E0 #\(i + 1)/30", s: s))
        }
        guard let base = last else { logger.log("[E0] 基线遥测全程不可用——中止"); return false }
        session.setBaseline(isCharging: base.isCharging, amperage: base.amperageMA)
        session.concl("e0.baseline", "amp=\(base.amperageMA)mA volt=\(fmtInt(base.voltageMV))mV percent=\(base.percent)% temp=\(tempS(base.temperatureC))℃ ext=\(base.externalConnected) isCharging=\(base.isCharging)")
        emitCalibration(pairs)
        for k in spikeKeys {
            let cur = smc.read(k).map { hex($0.bytes) } ?? "读失败"
            logger.log("[E0] \(k)=\(cur)（基线，原值 \(session.originals[k].map(hex) ?? "?")）")
        }
        return true
    }
    // MARK: E1–E3 单循环（E4 = 第二次调用）
    private struct CycleResult { let cycle: Int; let branch: String; let branchDetail: String; let recoveryOK: Bool }
    private enum CycleVerdict { case done(CycleResult); case writeNoGo; case readbackViolated(actual: String); case aborted }
    private func runCycle(cycle: Int) -> CycleVerdict {
        let samples = cycle == 1 ? 15 : 25   // 2s/采样：cycle1 保守 30s，cycle2 放满 50s（P2-4；50s 为 60s 看门狗留 ≥10s 余量）
        logger.log("=== E1–E3 cycle\(cycle)/2：CHIE 写 08 → 观察 \(samples * 2)s → 恢复 00 ===")
        // E1 前置：getKeyInfo 复核（§2 已录 hex_/1B；复核而非发现）
        guard let info = smc.keyInfo("CHIE") else { logger.log("[E1] CHIE getKeyInfo 不可读——中止循环"); return .aborted }
        logger.log("[E1] keyInfo 复核：type=\(info.type) size=\(info.size)（期望 hex_/1B）")
        guard info.size == 1 else { logger.log("[E1] CHIE 尺寸 \(info.size)B 与 §2 记录不符——拒绝写入"); return .aborted }
        guard let cur = smc.read("CHIE") else { logger.log("[E1] CHIE 当前值读取失败——中止循环"); return .aborted }
        logger.log("[E1] 当前=\(hex(cur.bytes))（期望基线 00）")
        // 同值回写探针先行（失败整键退出——还原保证）
        countdown(5, summary: "CHIE 同值回写探针（写 \(hex(cur.bytes)) → 回读验证）")
        guard probeWrite(key: "CHIE") else { return .aborted }
        // 写 0x8：kr≠0 → 回写原值验证后判 no-go；不对 0x8 重试，重试仅限还原方向（P2-3）
        countdown(5, summary: "CHIE 写 08（适配器禁用，Tahoe 代语义）")
        let (ok, kr, result) = smc.writeDetailed("CHIE", bytes: chieDisable)
        session.recordWrite(key: "CHIE", bytes: chieDisable, ok: ok, kr: kr, result: result)
        Thread.sleep(forTimeInterval: 0.5)
        if !ok {
            logger.log("[E1] 写 08 kr=\(String(format: "0x%08X", kr)) result=\(result)≠0——按 P2-3 不对 0x8 重试；回写原值验证后判 no-go")
            readbackTable.append("E1.c\(cycle):08→write-kr-nonzero")
            guard engine.restoreOneKeyVerified("CHIE") else { return .aborted }
            session.appendRestoreOutcome("CHIE.cycle\(cycle)=restored-after-kr-nonzero")
            return .writeNoGo
        }
        guard let back = smc.read("CHIE") else {
            session.recordReadbackViolation("CHIE 写 08 后回读失败（判据④违反，实际读回值=读失败）")
            readbackTable.append("E1.c\(cycle):08→read-fail")
            logger.log("[E1] 回读失败——判据④违反（终止条件），立即还原并结束")
            guard engine.restoreOneKeyVerified("CHIE") else { return .aborted }
            session.appendRestoreOutcome("CHIE.cycle\(cycle)=restored-after-readback-violation")
            return .readbackViolated(actual: "读失败")
        }
        if back.bytes != chieDisable {
            session.recordReadbackViolation("CHIE 写 08 后回读=\(hex(back.bytes))（判据④违反，实际读回值=\(hex(back.bytes))）")
            readbackTable.append("E1.c\(cycle):08→\(hex(back.bytes))(violated)")
            logger.log("[E1] 回读=\(hex(back.bytes)) ≠08——判据④违反（终止条件），立即还原并结束")
            guard engine.restoreOneKeyVerified("CHIE") else { return .aborted }
            session.appendRestoreOutcome("CHIE.cycle\(cycle)=restored-after-readback-violation")
            return .readbackViolated(actual: hex(back.bytes))
        }
        readbackTable.append("E1.c\(cycle):08→08")
        logger.log("[E1] 回读恰为 08——判读表 0x8→0x8 ✓")
        session.beginDischarge("CHIE")
        // E2 观察窗 + 三分支判读（幅值阈值有意弃用——§1.4，实现不得自行恢复幅值判定）
        let st = observeWindow(samples: samples, tag: "E2 c\(cycle)")
        let onTime = session.endDischarge()
        session.logBudget(key: "CHIE")
        logger.log("[E2] cycle\(cycle) 判读=\(st.branch)（\(st.detail)）；本次 on-time=\(Int(onTime))s")
        session.concl("criterion.2.cycle\(cycle)", "\(st.branch) \(st.detail)")
        // E3：写 0x0 恢复（还原互斥内）+ 60s 三要素窗
        let recovery = e3Restore(cycle: cycle)
        if session.isRunbookEntered { return .aborted }
        return .done(CycleResult(cycle: cycle, branch: st.branch, branchDetail: st.detail, recoveryOK: recovery))
    }
    /// E2 观察窗逐点统计（三分支判读原料）。
    private struct WindowStats {
        var samples = 0
        var consec3 = 0, maxConsec3 = 0        // 分支(a)：!ext ∧ amp<0 ∧ !isCharging 连续计数
        var consecNeg = 0, maxConsecNeg = 0    // 分支(c)原料：amp<0 ∧ !isCharging 连续计数
        var extFalseCount = 0
        var ampPositiveAll = true
        var chargingFalseCount = 0
        var branch = "mixed(未归类)"
        var detail = ""
    }
    /// E2 观察窗：2s 采样 ×N，逐点全量落盘 + checkSafety；不早退（窗口时长即规格定版）。
    private func observeWindow(samples: Int, tag: String) -> WindowStats {
        var st = WindowStats()
        for i in 0..<samples {
            Thread.sleep(forTimeInterval: 2)
            guard let s = telemetry.sample() else { logger.log("[\(tag)] #\(i + 1)/\(samples) 遥测不可用——不计"); continue }
            guard checkSafety(s) else { break }   // 超限内部已全量还原并退出，不会正常到达
            st.samples += 1
            logger.log(fullSampleLine(tag: "\(tag) #\(i + 1)/\(samples)", s: s))
            let cond3 = !s.externalConnected && s.amperageMA < 0 && !s.isCharging
            let condNeg = s.amperageMA < 0 && !s.isCharging
            st.consec3 = cond3 ? st.consec3 + 1 : 0
            st.consecNeg = condNeg ? st.consecNeg + 1 : 0
            st.maxConsec3 = max(st.maxConsec3, st.consec3)
            st.maxConsecNeg = max(st.maxConsecNeg, st.consecNeg)
            if !s.externalConnected { st.extFalseCount += 1 }
            if s.amperageMA <= 0 { st.ampPositiveAll = false }
            if !s.isCharging { st.chargingFalseCount += 1 }
        }
        classify(&st)
        return st
    }
    /// 三分支判读（§1.4 定版）：(a) 连续 ≥5 个 2s 采样点逐点三条件成立=持续放电；
    /// (b) Amperage 恒正 + 仅 isCharging 短暂 false=停充漂浮/瞬态（WP1 26s 型）；
    /// (c) Amperage 持续负 + isCharging=false 而 ext 恒 true=电池侧放电签名/待解释态——
    /// 单独记录并入判据⑤评估。幅值阈值不恢复（无幅值判定代码）。
    private func classify(_ st: inout WindowStats) {
        if st.maxConsec3 >= 5 {
            st.branch = "a(持续放电)"
            st.detail = "连续 \(st.maxConsec3) 点逐点三条件成立（ext=false ∧ amp<0 ∧ isCharging=false）"
        } else if st.maxConsecNeg >= 5 && st.extFalseCount == 0 {
            st.branch = "c(电池侧放电签名/待解释)"
            st.detail = "amp 持续负 \(st.maxConsecNeg) 点 + isCharging=false 而 ext 恒 true——单独记录，并入判据⑤评估"
        } else if st.ampPositiveAll && st.chargingFalseCount > 0 {
            st.branch = "b(停充漂浮/瞬态)"
            st.detail = "amp 恒正 + 仅 isCharging 短暂 false \(st.chargingFalseCount)/\(st.samples) 点（WP1 26s 型）"
        } else {
            st.branch = "mixed(未归类)"
            st.detail = "maxConsec3=\(st.maxConsec3) maxConsecNeg=\(st.maxConsecNeg) extFalse=\(st.extFalseCount) chargingFalse=\(st.chargingFalseCount) ampPositiveAll=\(st.ampPositiveAll)（原始数据已落盘）"
        }
    }
    /// 三要素窗：ext=true ∧ Amperage>0 ∧ isCharging=true 在同一样本齐备（判据③测量窗）。
    private func threeElementWindow(_ seconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 2)
            guard let s = telemetry.sample() else { continue }
            guard checkSafety(s) else { return false }
            logger.log("[E3窗] amp=\(s.amperageMA)mA ext=\(s.externalConnected) isCharging=\(s.isCharging) temp=\(tempS(s.temperatureC))℃ percent=\(s.percent)%")
            if s.externalConnected && s.amperageMA > 0 && s.isCharging { return true }
        }
        return false
    }
    /// E3：CHIE 写 0x0 恢复（纳入还原互斥——评审 P1-1）+ 60s 三要素观察窗
    /// （60s 未齐 → +30s 重验一次再判负——P2-2）。
    /// 注记（评审观察 2）：本函数 60s 观察窗 = 判据③「恢复语义完整」的测量窗（三要素需在
    /// 同一样本齐备）；RestoreEngine.behaviorVerified 的 30s 宽限 = 还原后的安全验证窗——
    /// 两者语义不同、可共存，互不替代。
    private func e3Restore(cycle: Int) -> Bool {
        logger.log("=== E3 cycle\(cycle)：CHIE 写 00 恢复 + 60s 三要素观察窗（还原互斥内）===")
        guard session.beginRestore() else { logger.log("[E3] 还原互斥被占——异常，中止"); return false }
        defer { session.endRestore() }
        guard let orig = session.originals["CHIE"] else { logger.log("[E3] 缺 CHIE 原值——中止"); return false }
        logger.log("[E3] 恢复值=0x0（状态文件原值 \(hex(orig))）")
        if let fail = engine.restoreKeyLadder("CHIE") {
            session.markRunbook()
            logger.log("[E3] CHIE 恢复阶梯失败：\(fail)")
            return false
        }
        let expectHex = hex(orig)
        let rb = smc.read("CHIE").map { hex($0.bytes) } ?? "读失败"
        if rb == expectHex {
            readbackTable.append("E3.c\(cycle):\(expectHex)→\(rb)")
            logger.log("[E3] 恢复回读恰为 \(rb)——判读表 0x0→0x0 ✓")
        } else {
            session.recordReadbackViolation("CHIE 恢复写 \(expectHex) 后回读=\(rb)（判据④违反，实际读回值=\(rb)）")
            readbackTable.append("E3.c\(cycle):\(expectHex)→\(rb)(violated)")
        }
        var ok = threeElementWindow(60)
        if !ok {
            logger.log("[E3] 60s 三要素未齐——+30s 重验一次（P2-2）")
            ok = threeElementWindow(30)
        }
        logger.log("[E3] cycle\(cycle) 三要素窗判定：\(ok ? "成立（恢复语义完整，判据③ ✓）" : "未成立（判负——不可解释态，终止后续实验）")；pmset: \(runPmset().replacingOccurrences(of: "\n", with: " | "))")
        session.appendRestoreOutcome("CHIE.cycle\(cycle)=\(ok ? "e3-verified" : "recovery-failed")")
        session.concl("criterion.3.cycle\(cycle)", ok ? "pass" : "fail")
        return ok
    }
    /// E5：CHTE 同值回写对照 + pmset 充电状态复核 + CHIE 终值==0x0 复核（判据⑤无残留态）。
    private func e5FinalCheck() {
        logger.log("=== E5：CHTE 同值回写对照 + pmset 复核 + CHIE 终值复核 ===")
        guard session.originals["CHTE"] != nil else { session.noteMatrix("e5.chte-original-missing(unexplainable)"); return }
        countdown(5, summary: "E5 CHTE 同值回写对照（写原值）")
        guard probeWrite(key: "CHTE") else { session.noteMatrix("e5.chte-probe-fail(unexplainable)"); return }
        logger.log("[E5] pmset 复核: \(runPmset().replacingOccurrences(of: "\n", with: " | "))")
        let chie = smc.read("CHIE").map { hex($0.bytes) } ?? "读失败"
        let finalOK = chie == "00"
        logger.log("[E5] CHIE 终值=\(chie)（期望 00）——\(finalOK ? "无残留态（判据⑤ ✓）" : "残留异常（判据⑤ 记录）")")
        session.noteMatrix("e5.chieFinal=\(chie) \(finalOK ? "clean" : "residue(unexplainable)")")
        if !finalOK { session.recordReadbackViolation("E5 CHIE 终值=\(chie)≠00（实际读回值=\(chie)）") }
    }
    // MARK: E6 交互最小集（仅当 0x8 成立——评审 P1-4）
    private func e6Gate(_ cycles: [CycleResult]) -> (ok: Bool, reason: String) {
        guard cycles.count == 2 else { return (false, "双循环未完整执行") }
        guard cycles.allSatisfy({ $0.branch.hasPrefix("a") }) else { return (false, "0x8 未在双循环建立持续放电（仅 0x8 成立时执行）") }
        guard session.readbackViolations.isEmpty else { return (false, "判据④存在违反记录") }
        return (true, "")
    }
    private func e6Interaction() {
        logger.log("=== E6：CHTE×CHIE 交互两格 + 双恢复序各验一次 ===")
        guard let chieOrig = session.originals["CHIE"], let chteOrig = session.originals["CHTE"] else {
            session.concl("criterion.e6", "skipped(缺基线原值)")
            return
        }
        countdown(5, summary: "E6 前置 CHTE 同值回写探针")
        guard probeWrite(key: "CHTE") else { session.concl("criterion.e6", "aborted(CHTE 探针失败)"); return }
        var results: [String] = []
        // 格 1：CHTE=01000000（停充）× CHIE=0x8 → 恢复序 A（先 CHIE 后 CHTE）
        let r1 = e6Cell(label: "cell1", chteValue: [1, 0, 0, 0], chieOrig: chieOrig, chteOrig: chteOrig,
                        orderFirst: ("CHIE", chieOrig), orderSecond: ("CHTE", chteOrig))
        results.append(r1)
        if r1.hasSuffix("restore-fail") {
            results.append("cell2=skipped(cell1 恢复未验证通过，不做下一刀)")
            session.concl("criterion.e6", results.joined(separator: ";"))
            return
        }
        if session.budgetExceeded("CHIE") {
            logger.log("[E6] CHIE 单键预算 ≥240s——格 2 跳过（预算放宽边界，P1-1）")
            results.append("cell2=skipped-budget")
            session.concl("criterion.e6", results.joined(separator: ";"))
            return
        }
        // 格 2：CHTE=00000000（使能）× CHIE=0x8 → 恢复序 B（先 CHTE 后 CHIE）
        let r2 = e6Cell(label: "cell2", chteValue: [0, 0, 0, 0], chieOrig: chieOrig, chteOrig: chteOrig,
                        orderFirst: ("CHTE", chteOrig), orderSecond: ("CHIE", chieOrig))
        results.append(r2)
        session.concl("criterion.e6", results.joined(separator: ";"))
    }
    /// 单格：写 CHTE 目标值 → CHIE=0x8（放电-on）→ 2s×5 记电流方向/pmset/双键回读 →
    /// 按指定恢复序还原 + 行为验证。
    private func e6Cell(label: String, chteValue: [UInt8], chieOrig: [UInt8], chteOrig: [UInt8],
                        orderFirst: (key: String, bytes: [UInt8]), orderSecond: (key: String, bytes: [UInt8])) -> String {
        logger.log("[E6] \(label)：CHTE=\(hex(chteValue)) × CHIE=08")
        guard writeExpect(key: "CHTE", value: chteValue, expected: chteValue, step: "E6.\(label).CHTE") else { e6Abort(label) }
        session.beginDischarge("CHIE")
        guard writeExpect(key: "CHIE", value: chieDisable, expected: chieDisable, step: "E6.\(label).CHIE") else {
            _ = session.endDischarge()
            e6Abort(label)
        }
        for i in 0..<5 {   // 2s × 5：电流方向/pmset/双键回读
            Thread.sleep(forTimeInterval: 2)
            guard let s = telemetry.sample() else { continue }
            guard checkSafety(s) else { break }
            let chteBack = smc.read("CHTE").map { hex($0.bytes) } ?? "读失败"
            let chieBack = smc.read("CHIE").map { hex($0.bytes) } ?? "读失败"
            let dir = s.amperageMA < 0 ? "放电" : (s.amperageMA > 0 ? "充电" : "零")
            logger.log("[E6] \(label) #\(i + 1) amp=\(s.amperageMA)mA(方向=\(dir)) ext=\(s.externalConnected) isCharging=\(s.isCharging) 回读 CHTE=\(chteBack) CHIE=\(chieBack) pmset=\(runPmset().replacingOccurrences(of: "\n", with: " | "))")
            session.noteMatrix("e6.\(label) amp=\(s.amperageMA) chte=\(chteBack) chie=\(chieBack)")
        }
        let onTime = session.endDischarge()
        session.logBudget(key: "CHIE")
        logger.log("[E6] \(label) on-time=\(Int(onTime))s；恢复序：先 \(orderFirst.key) 后 \(orderSecond.key)")
        let ok = restoreOrder(firstKey: orderFirst.key, firstBytes: orderFirst.bytes,
                              secondKey: orderSecond.key, secondBytes: orderSecond.bytes)
        session.noteMatrix("e6.\(label).restore=\(ok ? "ok" : "fail")")
        logger.log("[E6] \(label) 完成：恢复序验证=\(ok ? "ok" : "fail")（收尾全量还原再做值级+行为级双验证）")
        return "\(label)=\(ok ? "ok" : "restore-fail")"
    }
    private func e6Abort(_ label: String) -> Never {
        logger.log("[E6] \(label) 写/回读失败——全量还原并结束")
        let o = engine.fullRestore(reason: "E6 \(label) 写失败中止")
        reportRestoreOutcome(o)
        finalExit(130, note: "E6 写失败")
    }
    /// 恢复序验证：两键按序回原值（还原方向写免倒计时）+ 行为验证（30s 宽限）。
    private func restoreOrder(firstKey: String, firstBytes: [UInt8], secondKey: String, secondBytes: [UInt8]) -> Bool {
        guard writeExpect(key: firstKey, value: firstBytes, expected: firstBytes, skipCountdown: true, step: "E6.restore.\(firstKey)") else { return false }
        Thread.sleep(forTimeInterval: 2)
        guard writeExpect(key: secondKey, value: secondBytes, expected: secondBytes, skipCountdown: true, step: "E6.restore.\(secondKey)") else { return false }
        return engine.behaviorVerified(expectCharging: session.behaviorExpectation(), graceS: 30, retried: false)
    }
    // MARK: --do-it 主流程
    private func doIt() -> Int32 {
        logger.log("模式：--do-it（WP1.5 放电重调：CHIE 0x8 修正假设，E0–E6 + P1/P2）")
        logger.log("[须知] 用户在场全程；适配器连接且负载已知；勿跑其他重负载；运行期间不要合盖\n[须知] 预期噪声（正常非故障）：适配器禁用期外接 Hub/硬盘可能瞬断重枚举、屏幕亮度可能 dip、PD 重协商期充电图标闪烁；合盖外显时 adapter disable 可能因电源丢失而睡眠（batt 社区已知副作用）")
        guard getuid() == 0 else { logger.log("--do-it 需要 root：sudo .build/debug/spike-discharge --do-it"); return 2 }
        guard runPreflight(strict: true) else { return 3 }
        guard guardian.acquire() else { logger.log("[检查] 防睡眠断言（NoIdleSleep）获取失败——中止"); return 3 }
        logger.log("[检查] 防睡眠断言（NoIdleSleep）已持有，全程有效（等效 caffeinate -i；请勿合盖）")
        // 基线：仅 CHIE + CHTE（WP1.5 值集固定 {0x8}；旧代键重枚举禁用，132 自动跳过保留）
        logger.log("--- 基线键元数据 + 原值（P0-1：写前必记）---")
        scanKeys(recordBaseline: true)
        guard session.candidatePresent["CHIE"] != nil else {
            logger.log("CHIE 不可读——无法实验（WP1.5 唯一实验键）")
            guardian.release()
            return 3
        }
        // E0 基线 60s（只读，嵌 P1 标定；此后才有任何写）
        guard e0Baseline() else { guardian.release(); return 3 }
        // P0-1：首次任何 SMC 写入前原子写状态文件（E1 探针为首写）
        guard session.writeStateFile() else { logger.log("状态文件写入失败（\(stateFilePath)）——拒绝进入写实验"); guardian.release(); return 3 }
        logger.log("[P0-1] 状态文件已原子写入 \(stateFilePath)（机型/固件头 + 每键 {key,size,type,originalHex,writtenAt}）")
        installSignalHandlers()
        watchdog = Watchdog { [weak self] in self?.watchdogTick() }
        // E1–E3 ×2（E4=第二循环）；终止条件：温度/电量界（checkSafety 内部处理）、
        // 判据④违反、不可解释态、预算触顶——任一触发立即还原并结束
        var cycles: [CycleResult] = []
        var stopReason = ""
        cycleLoop: for n in 1...2 {
            if session.budgetExceeded("CHIE") { stopReason = "CHIE 单键预算 ≥240s 触顶（E6 计入）"; break }
            switch runCycle(cycle: n) {
            case .done(let c):
                cycles.append(c)
                if let r = session.takeAbortReason() { finalExit(130, note: r + "（还原互斥期间登记，延迟处理）") }
                if !c.recoveryOK { stopReason = "cycle\(n) E3 三要素窗判负（不可解释态）"; break cycleLoop }
            case .writeNoGo:
                stopReason = "E1 写 08 kr≠0——判 no-go（P2-3：不对 0x8 重试）"; break cycleLoop
            case .readbackViolated(let actual):
                stopReason = "判据④违反：CHIE 写 08 实际读回=\(actual)"; break cycleLoop
            case .aborted:
                stopReason = "还原路径失败（runbook 已记录现场）"; break cycleLoop
            }
        }
        // E5 + E6（仅正常完成时；提前终止路径只做终值记录后进入收尾还原）
        var e6Executed = false
        if stopReason.isEmpty {
            e5FinalCheck()
            let gate = e6Gate(cycles)
            if gate.ok {
                if session.budgetExceeded("CHIE") {
                    session.concl("criterion.e6", "skipped(CHIE 预算 ≥240s 触顶)")
                } else {
                    e6Executed = true
                    e6Interaction()
                }
            } else {
                session.concl("criterion.e6", "skipped(\(gate.reason))")
            }
        } else {
            logger.log("=== 提前终止：\(stopReason)——跳过 E5/E6，进入会话收尾还原 ===")
            session.concl("criterion.e6", "skipped(会话提前终止)")
            for k in spikeKeys {
                logger.log("[终值] \(k)=\(smc.read(k).map { hex($0.bytes) } ?? "读失败")（原值 \(session.originals[k].map(hex) ?? "?")）")
            }
        }
        // 会话结束：全量还原（双验证收尾：值回读==原值 且 行为恢复；通过则删状态文件）
        logger.log("=== 会话结束：全量还原（双验证收尾）===")
        let finalOutcome = engine.fullRestore(reason: stopReason.isEmpty ? "会话正常结束" : "提前终止：\(stopReason)")
        reportRestoreOutcome(finalOutcome)
        watchdog?.stop()
        emitConclusions(cycles: cycles, stopReason: stopReason, e6Executed: e6Executed)
        if case .verified = finalOutcome {
            logger.log("[检查单] 会话结束：经 App 面板重新启用 Cellar daemon（禁止 launchctl）；目视确认充电指示/pmset")
            guardian.release()
            logger.log("=== 会话结束（干净）：双验证通过，状态文件已删除 ===")
            return 0
        }
        logger.log("[检查单] 还原未验证通过：保留状态文件与日志，勿合盖，按 runbook 处置")
        guardian.release()
        return 1
    }
    // MARK: --restore
    private func restore(manual: (key: String, bytes: [UInt8])?) -> Int32 {
        logger.log("模式：--restore（按状态文件逐键还原 / 手动兜底）")
        guard getuid() == 0 else { logger.log("--restore 需要 root：sudo .build/debug/spike-discharge --restore"); return 2 }
        if let manual {
            logger.log("[手动兜底] 写 \(manual.key)=\(hex(manual.bytes))")
            countdown(5, summary: "手动兜底写 \(manual.key)=\(hex(manual.bytes))")
            guard smc.keyInfo(manual.key) != nil else { logger.log("[手动兜底] 键不存在或不可读"); return 2 }
            let (ok, kr, result) = smc.writeDetailed(manual.key, bytes: manual.bytes)
            session.recordWrite(key: manual.key, bytes: manual.bytes, ok: ok, kr: kr, result: result)
            Thread.sleep(forTimeInterval: 0.5)
            guard ok, let back = smc.read(manual.key), back.bytes == manual.bytes else {
                logger.log("[手动兜底] 写/回读不一致——请勿合盖，保留日志交工程师分析")
                session.concl("restore.manual.\(manual.key)", "failed")
                return 1
            }
            session.concl("restore.manual.\(manual.key)", "verified")
            logger.log("[手动兜底] \(manual.key)=\(hex(manual.bytes)) 回读一致；若状态文件仍在可再执行 --restore 全量还原")
        } else {
            guard Session.stateExists() else { logger.log("无状态文件（\(stateFilePath)）——无需还原"); return 0 }
            guard let loaded = session.loadStateFile() else { logger.log("状态文件解析失败——请勿合盖，保留现场交工程师分析"); return 1 }
            logger.log("状态文件载入：机型=\(loaded.file.model) 固件=\(loaded.file.firmware) 会话=\(loaded.file.session) 键=[\(loaded.sortedKeys.joined(separator: ","))]")
            installSignalHandlers()
            let o = engine.fullRestore(reason: "--restore 会话")
            reportRestoreOutcome(o)
            if session.takeAbortReason() != nil { finalExit(130, note: "还原期间收到中断信号") }
            switch o {
            case .verified: logger.log("还原完成：逐键双验证通过，状态文件已删除（干净结束）"); return 0
            case .failedValue, .failedBehavior: logger.log("还原失败：runbook 已记录现场与处置引导；状态文件保留"); return 1
            case .alreadyRestoring: return 1
            }
        }
        return 0
    }
    // MARK: 阶段 5 结论（key=value 机器可读 + SMC-NOTES 回填摘要模板）
    /// concl.* 键映射（WP1.5 重定义）：criterion.1/3/5 沿用；criterion.2 = 三条件 2 循环
    /// （含三分支结果）；criterion.4 = 预注册判读表（0x8→0x8、0x0→0x0、实际读回值）；
    /// criterion.e6 = 交互格结果；calibration.* = 标定字段（E0 窗内已发射）。
    private func emitConclusions(cycles: [CycleResult], stopReason: String, e6Executed: Bool) {
        logger.log("=== 阶段 5：五判据结论（key=value 机器可读）===")
        for k in spikeKeys {
            if let p = session.candidatePresent[k] {
                session.concl("criterion.1.\(k)", "pass type=\(p.type) size=\(p.size) 原值=\(p.origHex)")
            } else { session.concl("criterion.1.\(k)", "fail(不存在或不可读)") }
        }
        session.concl("criterion.1.any", session.candidatePresent.count >= 2 ? "pass" : "fail")
        // criterion.2 = 三条件 2 循环（含三分支结果）
        let bothA = cycles.count == 2 && cycles.allSatisfy { $0.branch.hasPrefix("a") }
        session.concl("criterion.2", bothA ? "pass(三条件 2 循环成立)" : "fail(需双循环 branch-a)")
        for c in cycles { session.concl("criterion.2.cycle\(c.cycle)", "\(c.branch) \(c.branchDetail)") }
        // criterion.3 沿用：逐循环恢复语义 + 全量还原
        let restores = session.restoreOutcomesSnapshot()
        let allRestoresOK = !restores.isEmpty && restores.allSatisfy { !$0.contains("fail") }
        session.concl("criterion.3", allRestoresOK ? "pass" : "fail")
        session.concl("criterion.3.restores", restores.isEmpty ? "无实验还原" : restores.joined(separator: ","))
        // criterion.4 = 预注册判读表（0x8→0x8、0x0→0x0、其他值=违反+实际读回值字段）
        session.concl("criterion.4.table", readbackTable.isEmpty ? "无写入步" : readbackTable.joined(separator: ","))
        session.concl("criterion.4", session.readbackViolations.isEmpty ? "pass(0x8→0x8; 0x0→0x0)" : "violated:" + session.readbackViolations.joined(separator: "|"))
        // §1.6 特例单列：行为面②成立但④违反 → 「键可写、行为有效、态不可读」
        let anyA = cycles.contains { $0.branch.hasPrefix("a") }
        if anyA && !session.readbackViolations.isEmpty {
            session.concl("criterion.4.special", "key-writable-behavior-valid-state-unreadable(②过④不过——WP2 回读安全验证路径受限，单独评估)")
        }
        // criterion.5 沿用：无不可解释态；branch(c) 电池侧放电签名并入评估
        let unexplainable = session.matrixNotes.filter { $0.contains("unexplainable") }
        let branchC = cycles.filter { $0.branch.hasPrefix("c") }.map { "cycle\($0.cycle)=电池侧放电签名(待解释)" }
        session.concl("criterion.5", unexplainable.isEmpty && branchC.isEmpty ? "pass(无不可解释态/无残留)" : "note:" + (unexplainable + branchC).joined(separator: ","))
        if !e6Executed && stopReason.isEmpty { session.concl("criterion.e6.effective", "not-executed(门控未过或预算不足)") }
        session.concl("stop.reason", stopReason.isEmpty ? "none(双循环+收尾完整执行)" : stopReason)
        session.concl("session.onTime.totalS", "\(Int(session.sessionOnTimeTotal()))")
        for (k, v) in session.recentBudgetSnapshot() { session.concl("session.onTime.\(k)", "\(Int(v))") }
        session.concl("runbook", session.isRunbookEntered ? "entered" : "not-entered")
        session.concl("stateFile", Session.stateExists() ? "kept(还原未验证通过)" : "deleted(还原验证通过)")
        session.concl("reboot.clearState", "unknown(实验记录项，不得断言)")
        // 结论读取走锁通道（评审 MEDIUM）：报告发射期间信号仍可能写 conclusions。
        let c1 = session.conclusion("criterion.1.any")
        let c2 = session.conclusion("criterion.2")
        let c3 = session.conclusion("criterion.3")
        let c4 = session.conclusion("criterion.4")
        let c5 = session.conclusion("criterion.5")
        let go = c1 == "pass" && c2?.hasPrefix("pass") == true && c3 == "pass"
            && c4?.hasPrefix("pass") == true && c5?.hasPrefix("pass") == true
        session.concl("go", go ? "go" : "no-go(详见上方逐条判定)")
        logger.log("SMC-NOTES 回填摘要模板（WP1.5 §7 修订素材）：")
        logger.log("smc-notes.backfill.start")
        logger.log("# WP1.5 放电重调会话：机型=\(machine.model) 固件=\(machine.firmware) macOS=\(machine.macOS)")
        for k in spikeKeys {
            if let p = session.candidatePresent[k] {
                logger.log("- \(k)：存在 type=\(p.type) size=\(p.size)B 原值=\(p.origHex)")
            } else { logger.log("- \(k)：不存在") }
        }
        for c in cycles {
            logger.log("- cycle\(c.cycle)：E2 判读=\(c.branch)（\(c.branchDetail)）；E3 恢复=\(c.recoveryOK ? "成立" : "判负")")
        }
        logger.log("- 判读表：\(readbackTable.isEmpty ? "无" : readbackTable.joined(separator: "; "))")
        for n in session.matrixNotes where n.hasPrefix("e5.") || n.hasPrefix("e6.") { logger.log("  - \(n)") }
        logger.log("- 待实测回填：重启是否清除键状态 = unknown（不得断言）")
        logger.log("smc-notes.backfill.end")
    }
}

// MARK: - 主入口
guard let runner = Runner() else {
    FileHandle.standardError.write("无法连接 SMC 用户客户端——拒绝启动\n".data(using: .utf8)!)
    exit(1)
}
exit(runner.run(Array(CommandLine.arguments.dropFirst())))
