#!/usr/bin/env swift
// Cellar 放电键调研 spike（Phase 3 WP1）— 规格 docs/plans/phase3-wp1-discharge-spike.md v1.1；唯一事实源 docs/SMC-NOTES.md
// SMC 封装照抄 Tools/m0-charge-test.swift（selector 2 + data8、80B 封包、key 小端 uint32、两阶段读、回复不回填 dataSize）
// 用法: --enumerate(阶段0+1只读预检,无需sudo) / --do-it(全流程写实验,root) / --restore [KEY=HEX](逐键还原/手动兜底)
// 安全(§4): P0-1 状态文件先于首次写原子落盘,还原双验证通过后删; P0-2 双验证+重试阶梯(3次→等5s→再3轮)+runbook 值级/行为级分列+现场记录(重启清除键状态=unknown 不断言);
// 同值回写探针先行; 放电-on≤60s看门狗(全局队列,独立主流程)+单键≤2min预算; 温度≥40℃或电量出[35,85]→全量还原; 信号→全量还原; NoIdleSleep断言全程持有;
// 日志逐行flush+每次写记kr; 结论 key=value; 零品牌词。

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
    let temperatureCentiC: Int
    let watts: Int?
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
        if let adapter = dict["AdapterDetails"] as? [String: Any] { watts = Self.intVal(adapter["Watts"]) }
        return TelemetrySample(percent: percent, isCharging: isCharging, externalConnected: external,
                               amperageMA: amperage, temperatureCentiC: temp, watts: watts, timestamp: Date())
    }
}

// MARK: - 小工具
private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }
private func tempS(_ c: Double) -> String { String(format: "%.1f", c) }
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
    var thresholdMA = 300
    var noiseMA = 0
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
    var chteStopWithin10 = false
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
    func setCalibration(noise: Int, threshold: Int, baselineIsCharging: Bool?, baselineAmperage: Int?) {
        noiseMA = noise; thresholdMA = threshold
        self.baselineIsCharging = baselineIsCharging
        baselineAmperageMA = baselineAmperage
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
    func budgetExceeded(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return (perKeyOnTime[key] ?? 0) >= 120 }
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
        logger.log("预算：单键累计 \(key)=\(perKey)s / 上限120s；会话累计 \(session)s")
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
        logger.log("[runbook] 终态处置：形态=值级失败（回写报错/回读不一致）\n[runbook] 引导：保持适配器连接、不要合盖、勿重启（重启是否清除键状态属未知）\n[runbook] 引导：手动兜底 sudo swift Tools/spike-discharge.swift --restore\n[runbook] 引导：仍失败则保留状态文件与日志交工程师分析\n[runbook] 键明细：\(valueFail)")
        dumpScene()
    }
    private func runbookBehavior() {
        logger.log("[runbook] 终态处置：形态=行为级失败（值回读一致但行为滞留）\n[runbook] 引导 1：物理重插适配器（闩锁语义候选处置）\n[runbook] 引导 2：重插后重跑 sudo swift Tools/spike-discharge.swift --restore\n[runbook] 引导 3：仍不恢复则保留状态文件与日志交工程师分析")
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

// MARK: - 候选与值域（规格 §2）：有佐证（CH0I，内核注释+外部参考）1B {0x02,0x00,0x01}（0x02=外部
// 参考旧代停充值佐证最强优先）；无佐证 1B {0x01,0x00}（翻转当前态优先）；4B CHTE 同构
// {01000000,00000000}（命令态先试）。候选集 = 值集 − 原值，按佐证强度排序逐试。
private let candidateKeys = ["CHIE", "CH0I", "CH0C", "BFCL", "BF0B"]
private let evidenceKeys: Set<String> = ["CH0I"]
private func candidateValues(size: UInt32, hasEvidence: Bool, original: [UInt8]) -> [[UInt8]] {
    switch size {
    case 1:
        let domain: [UInt8] = hasEvidence ? [0x02, 0x00, 0x01] : [0x01, 0x00]
        return domain.map { [$0] }.filter { $0 != original }
    case 4:
        return [[0x01, 0, 0, 0], [0, 0, 0, 0]].filter { $0 != original }
    default:
        return []
    }
}
private enum Paradigm { case adapter, battery }
private struct AttemptResult { let established: Bool; let maxDischargeMA: Int; let extFlipped: Bool }
private enum KeyOutcome { case established(value: [UInt8]), notEstablished, unconfirmed, skipped(reason: String), probeFailed, aborted }

// MARK: - Runner（三模式）
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
    init?() {
        logger = Logger()
        machine = MachineInfo.gather()
        guard let smc = SMCConnection() else { return nil }
        self.smc = smc
        session = Session(logger: logger, machine: machine)
        engine = RestoreEngine(smc: smc, telemetry: telemetry, session: session, logger: logger)
    }
    func run(_ args: [String]) -> Int32 {
        logger.log("=== 放电键调研 spike 会话 uid=\(getuid()) 机型=\(machine.model) 固件=\(machine.firmware) macOS=\(machine.macOS) 日志=\(logger.path) ===")
        if args.contains("--enumerate") { return enumerate() }
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
        logger.log("用法：\n  swift Tools/spike-discharge.swift --enumerate             # 阶段0+1只读预检(无需sudo)\n  sudo swift Tools/spike-discharge.swift --do-it            # 全流程(写实验;状态文件门禁)\n  sudo swift Tools/spike-discharge.swift --restore          # 按状态文件逐键还原\n  sudo swift Tools/spike-discharge.swift --restore CHIE=0x00  # 手动兜底(KEY=HEX)")
        return 2
    }
    private func countdown(_ seconds: Int, summary: String) {
        for i in stride(from: seconds, through: 1, by: -1) {
            logger.log("[倒计时] \(i)s 后执行：\(summary)（Ctrl-C 立即全量还原）")
            Thread.sleep(forTimeInterval: 1)
        }
    }
    private func calibrate(samples: Int, intervalS: Int) -> (noise: Int, threshold: Int, isCharging: Bool?, amperage: Int?) {
        var maxAmp = 0
        var charging: Bool?
        var amp: Int?
        for i in 0..<samples {
            Thread.sleep(forTimeInterval: TimeInterval(intervalS))
            if let s = telemetry.sample() {
                maxAmp = max(maxAmp, abs(s.amperageMA))
                charging = s.isCharging
                amp = s.amperageMA
                logger.log("[标定] 样本 \(i + 1)/\(samples)：amp=\(s.amperageMA)mA isCharging=\(s.isCharging)")
            } else { logger.log("[标定] 样本 \(i + 1)/\(samples)：遥测不可用") }
        }
        return (maxAmp, max(300, maxAmp * 2), charging, amp)
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
    /// 写期望值：已是目标态跳过；否则 5s 倒计时 + 写 + kr 记录 + 回读验证（判据 4）。
    @discardableResult
    private func writeExpect(key: String, value: [UInt8], expected: [UInt8], skipCountdown: Bool = false) -> Bool {
        guard let cur = smc.read(key) else { return false }
        if cur.bytes == value { logger.log("[写] \(key) 已是目标态 \(hex(value))——无需写"); return true }
        logger.log("[写] \(key)：\(hex(cur.bytes)) → \(hex(value))")
        if !skipCountdown { countdown(5, summary: "写 \(key)=\(hex(value))") }
        let (ok, kr, result) = smc.writeDetailed(key, bytes: value)
        session.recordWrite(key: key, bytes: value, ok: ok, kr: kr, result: result)
        Thread.sleep(forTimeInterval: 0.5)
        guard ok, let back = smc.read(key), back.bytes == expected else {
            session.recordReadbackViolation("\(key) 写 \(hex(value)) 后回读不一致（判据 4 违反）")
            logger.log("[写] \(key)=\(hex(value)) 回读不一致——判据 4 违反")
            return false
        }
        logger.log("[写] \(key)=\(hex(value)) 回读一致（判据 4 ✓）")
        return true
    }
    /// 安全阈值（§4）：温度 ≥40°C 或电量出 [35,85] → 全量还原并中止。
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
    private func waitPmsetNotCharging(_ seconds: Int) -> Bool {
        for _ in 0..<seconds {
            Thread.sleep(forTimeInterval: 1)
            let pm = runPmset()
            if pm.contains("not charging") || pm.contains("discharging") { return true }
        }
        return false
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
    /// 看门狗 tick（全局队列，独立于主流程）：放电-on 超 60s 硬上限 → 全量还原。
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
    // MARK: 阶段 0 只读预检（enumerate 宽松报告 / do-it 严格门禁共用）
    private func runPreflight(strict: Bool) -> Bool {
        var ok = true
        let fail = { (check: String) in self.logger.log("[检查] \(check)=失败"); ok = false }
        if let s = telemetry.sample() {
            if s.externalConnected { logger.log("[检查] 外接电源=通过") } else { fail("外接电源"); logger.log("[检查]     请插电后重试") }
            if (40...80).contains(s.percent) { logger.log("[检查] 电量 40-80%=通过 (\(s.percent)%)") } else { fail("电量 40-80%"); logger.log("[检查]     电量 \(s.percent)% 请调整后重试") }
            if s.temperatureC < 35 { logger.log("[检查] 温度<35℃=通过 (\(tempS(s.temperatureC))℃)") } else { fail("温度<35℃"); logger.log("[检查]     温度 \(tempS(s.temperatureC))℃") }
        } else { fail("电池遥测"); logger.log("[检查]     遥测服务不可用") }
        if smc.read("CHTE") != nil { logger.log("[检查] CHTE 可读=通过") } else { fail("CHTE 可读") }
        if processRunning("cellar-daemon") || processRunning("Cellar") {
            fail("daemon 停用")
            logger.log("[检查]     daemon 运行中——请经 App 面板停用/卸载（禁止 launchctl，保持用户态合规）")
        } else { logger.log("[检查] daemon 未运行=通过") }
        if Session.stateExists() {
            fail("状态文件门禁")
            logger.log("[检查]     存在未清理状态文件 \(stateFilePath)——请先 sudo swift Tools/spike-discharge.swift --restore")
        } else { logger.log("[检查] 状态文件门禁=通过（无残留）") }
        if strict && !ok { logger.log("[检查] 前置检查未通过，拒绝进入写实验") }
        return ok
    }
    /// 候选键枚举（enumerate 只读 / doIt 记基线共用）。
    private func scanKeys(recordBaseline: Bool) {
        for k in candidateKeys {
            if let info = smc.keyInfo(k), let r = smc.read(k) {
                session.candidatePresent[k] = (info.size, info.type, hex(r.bytes))
                if recordBaseline { session.addBaseline(key: k, size: info.size, type: info.type, bytes: r.bytes) }
                logger.log("enumerate.\(k)=存在 type=\(info.type) size=\(info.size) 原值=\(hex(r.bytes))")
            } else { logger.log("enumerate.\(k)=不存在（getKeyInfo 不可读）") }
        }
    }
    // MARK: --enumerate（只读预检）
    private func enumerate() -> Int32 {
        logger.log("模式：--enumerate（只读预检）")
        logger.log("--- 阶段 1 键元数据（getKeyInfo）---")
        scanKeys(recordBaseline: false)
        let chte = smc.read("CHTE")
        logger.log("enumerate.CHTE=\(chte.map { "存在 type=\($0.type) size=\($0.size) 原值=\(hex($0.bytes))" } ?? "不可读")")
        logger.log("--- 阶段 0 只读预检 ---")
        let ready = runPreflight(strict: false)
        let cal = calibrate(samples: 5, intervalS: 2)
        logger.log("[标定] 基线噪声 max|Amperage|=\(cal.noise)mA；幅值阈值=max(300, 噪声×2)=\(cal.threshold)mA；锚定 isCharging=\(cal.isCharging ?? false) amp=\(cal.amperage ?? 0)mA")
        if let s = telemetry.sample() {
            logger.log("telemetry.baseline=amperageMA=\(s.amperageMA) isCharging=\(s.isCharging) externalConnected=\(s.externalConnected) temperatureC=\(tempS(s.temperatureC)) percent=\(s.percent)%\(s.watts.map { " watts=\($0)" } ?? "")")
        }
        logger.log(ready ? "预检结论：就绪（可执行 --do-it）" : "预检结论：未就绪（--enumerate 为只读，键清单已输出）")
        return 0
    }
    // MARK: --do-it（全流程）
    private func doIt() -> Int32 {
        logger.log("模式：--do-it（全流程写实验）")
        logger.log("[须知] 用户在场全程；适配器连接且负载已知；勿跑其他重负载；运行期间不要合盖\n[须知] 预期噪声（正常非故障）：适配器禁用期外接 Hub/硬盘可能瞬断重枚举、屏幕亮度可能 dip、PD 重协商期充电图标闪烁")
        guard getuid() == 0 else { logger.log("--do-it 需要 root：sudo swift Tools/spike-discharge.swift --do-it"); return 2 }
        guard runPreflight(strict: true) else { return 3 }
        guard guardian.acquire() else { logger.log("[检查] 防睡眠断言（NoIdleSleep）获取失败——中止"); return 3 }
        logger.log("[检查] 防睡眠断言（NoIdleSleep）已持有，全程有效（等效 caffeinate -i；请勿合盖）")
        // 阶段 0：Amperage 符号标定（基线充电态锚定并记录）
        logger.log("--- Amperage 符号标定（基线充电态锚定）---")
        let cal = calibrate(samples: 6, intervalS: 2)
        session.setCalibration(noise: cal.noise, threshold: cal.threshold, baselineIsCharging: cal.isCharging, baselineAmperage: cal.amperage)
        logger.log("[标定] 噪声=\(cal.noise)mA 阈值=\(cal.threshold)mA 锚定 isCharging=\(cal.isCharging ?? false) amp=\(cal.amperage ?? 0)mA")
        logger.log("[标定] 符号约定：方向以 isCharging 为准；放电成立 = isCharging==false 且 |Amperage|≥阈值，连续 ≥5 个 2s 采样")
        session.concl("calibration.thresholdMA", "\(cal.threshold)")
        session.concl("calibration.noiseMA", "\(cal.noise)")
        // 阶段 1：枚举 + 基线原值（写前必记，P0-1）
        logger.log("--- 阶段 1 键元数据 + 基线原值 ---")
        if let chte = smc.read("CHTE") {
            session.addBaseline(key: "CHTE", size: chte.size, type: chte.type, bytes: chte.bytes)
            logger.log("enumerate.CHTE=存在 type=\(chte.type) size=\(chte.size) 原值=\(hex(chte.bytes))")
        }
        scanKeys(recordBaseline: true)
        // P0-1：首次任何 SMC 写入前原子写状态文件
        guard session.writeStateFile() else { logger.log("状态文件写入失败（\(stateFilePath)）——拒绝进入写实验"); guardian.release(); return 3 }
        logger.log("[P0-1] 状态文件已原子写入 \(stateFilePath)（机型/固件头 + 每键 {key,size,type,originalHex,writtenAt}）")
        // 信号安全网 + 看门狗（先于任何写实验）
        installSignalHandlers()
        watchdog = Watchdog { [weak self] in self?.watchdogTick() }
        // 阶段 2：CHIE 适配器禁用范式
        logger.log("=== 阶段 2：CHIE（适配器禁用范式二）===")
        var established: [String: [UInt8]] = [:]
        if let o = tryKey(key: "CHIE", paradigm: .adapter, hasEvidence: false) {
            handleOutcome(o, key: "CHIE", into: &established)
        }
        // 还原验证失败（runbook）→ 跳过其余实验（评审 P1-1：继续写实验会误判成立键
        // 并延长放电滞留——危险态不做下一刀），落到会话收尾（全量还原+结论）
        var runbookAbort = false
        if session.isRunbookEntered {
            logger.log("=== runbook 已进入——中止其余实验，按处置指引操作 ===")
            runbookAbort = true
        }
        // 阶段 3：电池侧候选（列表 − CHIE），同流程
        if !runbookAbort { logger.log("=== 阶段 3：电池侧候选键（阶段 1 列表 − CHIE）===") }
        if !runbookAbort {
            for k in candidateKeys where k != "CHIE" {
                if session.isRunbookEntered { logger.log("=== runbook 已进入——中止剩余候选实验 ==="); runbookAbort = true; break }
                if let o = tryKey(key: k, paradigm: .battery, hasEvidence: evidenceKeys.contains(k)) {
                    handleOutcome(o, key: k, into: &established)
                }
                if session.isRunbookEntered { logger.log("=== runbook 已进入——中止剩余候选实验 ==="); runbookAbort = true; break }
            }
        }
        // 阶段 4：CHTE × 成立键交互矩阵
        if runbookAbort {
            logger.log("=== runbook 已进入——跳过交互矩阵 ===")
        } else if established.isEmpty {
            logger.log("=== 阶段 4：无成立键，跳过交互矩阵 ===")
        } else {
            for (k, v) in established { matrixFor(key: k, dischargeValue: v) }
        }
        // 会话结束：全量还原（双验证；通过则删状态文件）
        logger.log("=== 会话结束：全量还原 ===")
        let finalOutcome = engine.fullRestore(reason: "会话正常结束")
        reportRestoreOutcome(finalOutcome)
        watchdog?.stop()
        emitConclusions(established: established)
        if case .verified = finalOutcome {
            logger.log("[检查单] 会话结束：经 App 面板重新启用 Cellar daemon（禁止 launchctl）")
            guardian.release()
            logger.log("=== 会话结束（干净）：双验证通过，状态文件已删除 ===")
            return 0
        }
        logger.log("[检查单] 还原未验证通过：保留状态文件与日志，勿合盖，按 runbook 处置")
        guardian.release()
        return 1
    }
    private func handleOutcome(_ o: KeyOutcome, key: String, into established: inout [String: [UInt8]]) {
        switch o {
        case .established(let v):
            established[key] = v
            session.establishedKeys[key] = v
            session.concl("criterion.2.\(key)", "established")
        case .notEstablished: session.concl("criterion.2.\(key)", "not-established")
        case .unconfirmed: session.concl("criterion.2.\(key)", "unconfirmed(重复性缺失)")
        case .skipped(let r): session.concl("criterion.2.\(key)", "skipped(\(r))")
        case .probeFailed: session.concl("criterion.2.\(key)", "skipped(写通路探针失败)")
        case .aborted: session.concl("criterion.2.\(key)", "aborted")
        }
    }
    private func tryKey(key: String, paradigm: Paradigm, hasEvidence: Bool) -> KeyOutcome? {
        guard let present = session.candidatePresent[key] else { logger.log("[\(key)] 枚举未发现——跳过"); return .skipped(reason: "键不存在") }
        guard present.size == 1 || present.size == 4 else { logger.log("[\(key)] 尺寸 \(present.size)B 无定义值域（规格 §2 仅 1B/4B）——不做写实验"); return .skipped(reason: "尺寸值域未定义") }
        guard let current = smc.read(key) else { logger.log("[\(key)] 原值读取失败——跳过"); return .skipped(reason: "原值读取失败") }
        let original = current.bytes
        logger.log("[\(key)] 原值=\(hex(original))")
        countdown(5, summary: "\(key) 写通路探针（写原值 \(hex(original)) → 回读验证）")
        guard probeWrite(key: key) else { return .probeFailed }
        let candidates = candidateValues(size: present.size, hasEvidence: hasEvidence, original: original)
        guard !candidates.isEmpty else { logger.log("[\(key)] 候选值集为空（原值覆盖全部值集）——跳过"); return .skipped(reason: "候选集为空") }
        logger.log("[\(key)] 候选值（按佐证强度排序）=[\(candidates.map(hex).joined(separator: ", "))]（值集−原值）")
        for (i, v) in candidates.enumerated() {
            if session.budgetExceeded(key) { logger.log("[\(key)] 单键累计预算 ≥120s——停止该键（P1-9）"); break }
            logger.log("[\(key)] 候选 \(i + 1)/\(candidates.count)：value=\(hex(v))")
            guard let first = runAttempt(key: key, value: v, paradigm: paradigm) else { return .aborted }
            if !first.established { continue }
            if session.budgetExceeded(key) { logger.log("[\(key)] 成立但预算不足以支撑确认——记录未确认"); return .unconfirmed }
            guard let confirm = runAttempt(key: key, value: v, paradigm: paradigm) else { return .aborted }
            if confirm.established { logger.log("[\(key)] 确认实验重复成立——记录成立键 value=\(hex(v))"); return .established(value: v) }
            logger.log("[\(key)] 确认实验未重复成立——重复性缺失（判据 5 预注册：不可解释）")
            return .unconfirmed
        }
        logger.log("[\(key)] 全部候选值尝试完毕，未成立")
        return .notEstablished
    }
    /// 单次候选值实验：写候选 → 2s×10 采样 → 判定（早退 P2-7）→ 驻留 ≤30s → 还原双验证。nil=会话中止。
    private func runAttempt(key: String, value: [UInt8], paradigm: Paradigm) -> AttemptResult? {
        countdown(5, summary: "\(key) 写候选值 \(hex(value))（范式=\(paradigm == .adapter ? "适配器禁用" : "电池侧")）")
        logger.log("[\(key)] 写入候选值 \(hex(value))")
        let (ok, kr, result) = smc.writeDetailed(key, bytes: value)
        session.recordWrite(key: key, bytes: value, ok: ok, kr: kr, result: result)
        Thread.sleep(forTimeInterval: 0.5)
        let notEstablished = AttemptResult(established: false, maxDischargeMA: 0, extFlipped: false)
        guard ok else {
            logger.log("[\(key)] 写入失败（kr 已记录）——还原后跳过该值")
            guard engine.restoreOneKeyVerified(key) else { session.concl("restore.\(key)", "failed——会话中止"); return nil }
            return notEstablished
        }
        guard let back = smc.read(key), back.bytes == value else {
            session.recordReadbackViolation("\(key) 写 \(hex(value)) 后回读不一致（判据 4 违反）")
            logger.log("[\(key)] 回读不一致（判据 4 违反）——还原后跳过该值")
            guard engine.restoreOneKeyVerified(key) else { return nil }
            return notEstablished
        }
        logger.log("[\(key)] 回读一致 value=\(hex(value))（判据 4 ✓）")
        session.beginDischarge(key)
        let writeTime = Date()
        var consecutive = 0
        var maxDischarge = 0
        var extFlipped = false
        var established = false
        for i in 0..<10 {   // 2s × 10 = 20s 观察窗（规格 §3）
            Thread.sleep(forTimeInterval: 2)
            guard let s = telemetry.sample() else { logger.log("[样本] \(key) #\(i + 1) 遥测不可用——不计"); continue }
            if !checkSafety(s) { return nil }
            logger.log("[样本] \(key) #\(i + 1) on=+\(Int(Date().timeIntervalSince(writeTime)))s amp=\(s.amperageMA) isCharging=\(s.isCharging) ext=\(s.externalConnected) watts=\(s.watts.map(String.init) ?? "-") temp=\(tempS(s.temperatureC))℃ percent=\(s.percent)%")
            let discharging = !s.isCharging && abs(s.amperageMA) >= session.thresholdMA
            consecutive = discharging ? consecutive + 1 : 0
            if discharging { maxDischarge = max(maxDischarge, abs(s.amperageMA)) }
            if paradigm == .adapter && !s.externalConnected { extFlipped = true }
            if consecutive >= 5 || extFlipped {
                established = true
                logger.log("[\(key)] 判据达成（连续放电样本=\(consecutive) ≥5；适配器断开=\(extFlipped)）——早退进入还原（P2-7)")
                break
            }
        }
        if established {
            let dwellEnd = min(Date().addingTimeInterval(30), writeTime.addingTimeInterval(50))   // 驻留≤30s；60s 硬上限看门狗兜底
            logger.log("[\(key)] 已成立：驻留观察 ≤30s")
            while Date() < dwellEnd {
                Thread.sleep(forTimeInterval: 2)
                guard let s = telemetry.sample() else { continue }
                if !checkSafety(s) { return nil }
                logger.log("[驻留] \(key) amp=\(s.amperageMA) isCharging=\(s.isCharging) ext=\(s.externalConnected)")
            }
        }
        let onTime = session.endDischarge()
        session.logBudget(key: key)
        logger.log("[\(key)] 本次 on-time=\(Int(onTime))s")
        guard engine.restoreOneKeyVerified(key) else { session.concl("restore.\(key)", "failed——runbook 已记录现场，会话中止"); return nil }
        session.appendRestoreOutcome("\(key)=verified")
        session.concl("criterion.3.\(key)", "pass")
        if let reason = session.takeAbortReason() { finalExit(130, note: reason + "（还原互斥期间登记，延迟处理）") }
        logger.log("[\(key)] 还原双验证通过——回写原值且行为恢复")
        return AttemptResult(established: established, maxDischargeMA: maxDischarge, extFlipped: extFlipped)
    }
    // MARK: 阶段 4 交互矩阵（CHTE × 成立键；四格 + 两恢复顺序）
    private func matrixFor(key: String, dischargeValue: [UInt8]) {
        logger.log("=== 阶段 4：CHTE × \(key) 交互矩阵 ===")
        let enable: [UInt8] = [0, 0, 0, 0]
        let stop: [UInt8] = [1, 0, 0, 0]
        guard let dOrig = session.originals[key], let chteOrig = session.originals["CHTE"] else { logger.log("[矩阵] 缺基线原值——跳过"); return }
        guard probeWrite(key: "CHTE") else { logger.log("[矩阵] CHTE 写通路探针失败——跳过矩阵"); return }
        // 四格：CHTE=使能/停充 × D=off/on；每格写 + kr 记录 + 回读验证（判据 4）+ 电流方向/pmset 证据
        let cells: [(label: String, chte: [UInt8], d: [UInt8])] = [("cell1", enable, dOrig), ("cell2", stop, dOrig), ("cell3", enable, dischargeValue), ("cell4", stop, dischargeValue)]
        var onTime = 0.0
        for (i, cell) in cells.enumerated() {
            if i == 2 { session.beginDischarge(key) }   // 单元格 3 起放电-on（预算/看门狗计时起点）
            let ok = writeExpect(key: "CHTE", value: cell.chte, expected: cell.chte)
                && writeExpect(key: key, value: cell.d, expected: cell.d)
            if !ok {
                if i >= 2 { _ = session.endDischarge() }
                restoreMatrixAbort(key: key)
            }
            recordCell(key: key, label: cell.label, chte: cell.chte, d: cell.d)
            if i == 1 {   // 单元格 2 后：pmset ≤10s 证据（判据 3）
                session.chteStopWithin10 = waitPmsetNotCharging(10)
                session.concl("criterion.3.pmsetNotCharging10s", session.chteStopWithin10 ? "pass" : "fail")
            }
            if i == 3 { onTime = session.endDischarge() }
        }
        session.logBudget(key: key)
        logger.log("[矩阵] 单元格 3/4 放电-on 累计=\(Int(onTime))s")
        logger.log("[矩阵] 恢复顺序 A：先 \(key) 回原值 → 后 CHTE 回原值")
        let orderA = restoreOrder(firstKey: key, firstBytes: dOrig, secondKey: "CHTE", secondBytes: chteOrig)
        logger.log("[矩阵] 恢复顺序 B：先 CHTE 回原值 → 后 \(key) 回原值")
        let orderB = restoreOrder(firstKey: "CHTE", firstBytes: chteOrig, secondKey: key, secondBytes: dOrig)
        session.noteMatrix("\(key).restoreOrderA=\(orderA ? "ok" : "fail")")
        session.noteMatrix("\(key).restoreOrderB=\(orderB ? "ok" : "fail")")
        let clean = orderA && orderB
        session.concl("criterion.5.matrix.\(key)", clean ? "clean" : "unexplainable(两向恢复顺序结果不一致)")
        logger.log("[矩阵] \(key) 完成：两恢复顺序\(clean ? "一致通过" : "结果不一致——判据 5 记不可解释")")
    }
    private func restoreOrder(firstKey: String, firstBytes: [UInt8], secondKey: String, secondBytes: [UInt8]) -> Bool {
        guard writeExpect(key: firstKey, value: firstBytes, expected: firstBytes, skipCountdown: true) else { return false }
        Thread.sleep(forTimeInterval: 2)
        guard writeExpect(key: secondKey, value: secondBytes, expected: secondBytes, skipCountdown: true) else { return false }
        return engine.behaviorVerified(expectCharging: session.behaviorExpectation(), graceS: 30, retried: false)
    }
    private func restoreMatrixAbort(key: String) -> Never {
        let o = engine.fullRestore(reason: "矩阵 \(key) 写失败中止")
        reportRestoreOutcome(o)
        finalExit(130, note: "矩阵写失败")
    }
    private func recordCell(key: String, label: String, chte: [UInt8], d: [UInt8]) {
        Thread.sleep(forTimeInterval: 2)
        guard let s = telemetry.sample() else { return }
        if !checkSafety(s) { return }   // 超限时内部已全量还原并退出
        let chteBack = smc.read("CHTE").map { hex($0.bytes) } ?? "读失败"
        let dBack = smc.read(key).map { hex($0.bytes) } ?? "读失败"
        logger.log("[矩阵] \(label) CHTE=\(hex(chte)) \(key)=\(hex(d)) 回读=chte:\(chteBack) \(key):\(dBack) amp=\(s.amperageMA) isCharging=\(s.isCharging) watts=\(s.watts.map(String.init) ?? "-") pmset=\(runPmset().replacingOccurrences(of: "\n", with: " | "))")
        session.noteMatrix("\(key).\(label) amp=\(s.amperageMA) isCharging=\(s.isCharging) chte回读=\(chteBack) d回读=\(dBack)")
    }
    // MARK: --restore
    private func restore(manual: (key: String, bytes: [UInt8])?) -> Int32 {
        logger.log("模式：--restore（按状态文件逐键还原 / 手动兜底）")
        guard getuid() == 0 else { logger.log("--restore 需要 root：sudo swift Tools/spike-discharge.swift --restore"); return 2 }
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
    private func emitConclusions(established: [String: [UInt8]]) {
        logger.log("=== 阶段 5：五判据结论（key=value 机器可读）===")
        for k in candidateKeys {
            if let p = session.candidatePresent[k] {
                session.concl("criterion.1.\(k)", "pass type=\(p.type) size=\(p.size) 原值=\(p.origHex)")
            } else { session.concl("criterion.1.\(k)", "fail(不存在或不可读)") }
        }
        session.concl("criterion.1.any", session.candidatePresent.isEmpty ? "fail" : "pass")
        let anyEstablished = !established.isEmpty
        session.concl("criterion.2.any", anyEstablished ? "pass" : "fail")
        let allRestoresVerified = session.restoreOutcomesSnapshot().allSatisfy { $0.hasSuffix("=verified") }
        let criterion3 = (session.restoreOutcomesSnapshot().isEmpty || allRestoresVerified) && (!anyEstablished || session.chteStopWithin10)
        session.concl("criterion.3", criterion3 ? "pass" : "fail")
        session.concl("criterion.3.restores", session.restoreOutcomesSnapshot().isEmpty ? "无实验还原" : session.restoreOutcomesSnapshot().joined(separator: ","))
        session.concl("criterion.4", session.readbackViolations.isEmpty ? "pass(每步回读==写入值)" : "violated:" + session.readbackViolations.joined(separator: "|"))
        let unexplainable = session.matrixNotes.filter { $0.contains("unexplainable") }
        session.concl("criterion.5", unexplainable.isEmpty ? "pass(重复性/清除滞留/恢复顺序均无异常记录)" : "fail:" + unexplainable.joined(separator: ","))
        session.concl("established.keys", established.isEmpty ? "none" : established.map { "\($0)=\(hex($1))" }.joined(separator: ","))
        session.concl("session.onTime.totalS", "\(Int(session.sessionOnTimeTotal()))")
        for (k, v) in session.recentBudgetSnapshot() { session.concl("session.onTime.\(k)", "\(Int(v))") }
        session.concl("runbook", session.isRunbookEntered ? "entered" : "not-entered")
        session.concl("stateFile", Session.stateExists() ? "kept(还原未验证通过)" : "deleted(还原验证通过)")
        session.concl("reboot.clearState", "unknown(实验记录项，不得断言)")
        // 结论读取走锁通道（评审 MEDIUM）：报告发射期间信号仍可能写 conclusions。
        let c1 = session.conclusion("criterion.1.any")
        let c2 = session.conclusion("criterion.2.any")
        let c3 = session.conclusion("criterion.3")
        let c4 = session.conclusion("criterion.4")
        let c5 = session.conclusion("criterion.5")
        let go = c1 == "pass" && c2 == "pass" && c3 == "pass"
            && c4?.hasPrefix("pass") == true && c5?.hasPrefix("pass") == true
        session.concl("go", go ? "go" : "no-go(详见上方逐条判定)")
        logger.log("SMC-NOTES 回填摘要模板：")
        logger.log("smc-notes.backfill.start")
        logger.log("# WP1 放电键调研会话：机型=\(machine.model) 固件=\(machine.firmware) macOS=\(machine.macOS)")
        for k in candidateKeys {
            if let p = session.candidatePresent[k] {
                logger.log("- \(k)：存在 type=\(p.type) size=\(p.size)B 原值=\(p.origHex)")
            } else { logger.log("- \(k)：不存在") }
        }
        if established.isEmpty {
            logger.log("- 成立键：无（双范式均未成立或键缺失）")
        } else {
            for (k, v) in established {
                logger.log("- 成立键 \(k) 放电值=\(hex(v))")
                for n in session.matrixNotes where n.hasPrefix(k + ".") { logger.log("  - 矩阵 \(n)") }
            }
            logger.log("- 交互矩阵结论：\(c5 ?? "?")；CHTE 停充 pmset≤10s 证据：\(session.conclusion("criterion.3.pmsetNotCharging10s") ?? "?")")
        }
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