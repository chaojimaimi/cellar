#!/usr/bin/env swift
// Cellar macOS 27 GA 风扇写路径 spike（S5）— 方案 docs/plans/phase5-0.20-macos27-ga-spike.md §7/§8 v3 定稿；唯一事实源 docs/SMC-NOTES.md §8
// 镜像 Tools/spike-fan.swift（四要素流程）与 Tools/spike-fan-f1.swift（锁存延迟阶梯 [100,300,800]ms = FanSMC.verifyLadderMs）。
// 步骤绑定（§7）：preflight（R2：bootout 为唯一可接受态——通用页关闭编排开关不算过）→ e0（F0 五键基线 + Ftst 探测负样本）→
//   e2c（Md=0 负探针〔U4 证据〕→ F0Md=1 阶梯 → F0Tg=3350 阶梯 → 60s 驻留 + Ac 跟随〔Ac≥目标−300 满窗判读，§10 T+6s 爬升宽限先例〕）→
//   e3（Tg→原值 + Md=0 还原阶梯双验证 → 干净窗 60s）→ f1-stretch（F1 镜像，独立可选）→ concl（§8.1 U1–U4 四条镜像判定）。
// 红线：不写 F0Mn/F1Mn（result=134 已知拒写，SMC-NOTES §8.1 U6）；还原阶梯双验证；温度/电量窗照 §8 纪律（40–75 / <35℃）。
// 用法：
//   swift Tools/spike-ga-fan.swift preflight          # 只读前置（daemon bootout 唯一可接受态检查）
//   sudo swift Tools/spike-ga-fan.swift e0            # F0 五键基线 + Ftst keyInfo 探测 + Ac 静息曲线
//   sudo swift Tools/spike-ga-fan.swift e2c           # 解锁直写实验（结束时风扇处于 Md=1+Tg=3350——立即接 e3）
//   sudo swift Tools/spike-ga-fan.swift e3            # 还原 + 干净窗
//   sudo swift Tools/spike-ga-fan.swift f1-stretch    # F1 镜像（可选 stretch，自含还原）
//   sudo swift Tools/spike-ga-fan.swift restore       # 按状态文件还原
//   swift Tools/spike-ga-fan.swift concl              # U1–U4 汇总 + GO/NO-GO

import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - 预注册常量（方案 §7/§8 + SMC-NOTES §8 定版；改动即改实验设计——禁止）
private let stateFilePath = "/tmp/spike-ga-state-fan.json"
private let resultsFilePath = "/tmp/spike-ga-results-fan.json"
private let verifyLadderMs = [100, 300, 800]      // 锁存延迟阶梯（FanSMC.verifyLadderMs 逐字同款；F0Md/F1Md 锁存 ∈(100,400]ms，§10.1）
private let tgTargetF0: Float = 3350              // §7 E2c：F0Tg 直写目标（(1350+5349)/2，母本 §2.2 同值）
private let tgTargetF1: Float = 3650              // §10 F1 先例目标（F1Mn 1522–F1Mx 5777 中值域）
private let followAcFloorRPM = 300.0              // §8.1 U2：Ac ≥ 目标−300rpm
private let followGraceSamples = 3                // 爬升宽限 = 前 3 样本（6s；§10 先例 T+6s 起 27 样本判读；预注册，不现场改）
private let baselineAcTolRPM = 150.0              // §8.1 U3/母本 E5：Ac 回基线 ±150rpm
private let e2cWindowS = 60, e2cStepS = 2         // §7 E2c：60s 驻留 @2s
private let cleanWindowS = 60, cleanStepS = 2     // §7 E3：干净窗 60s @2s
private let f1CleanWindowS = 20, f1CleanStepS = 2 // f1-stretch 自含还原后的缩短干净窗（stretch 项，预注册取值）
private let preflightPct = 40...75                // §7 红线：温度/电量窗照 §8 纪律
private let preflightTempCentiC = 3500            // 预检温度 <35℃（母本定版）
private let tempAbortCentiC = 4000                // 安全线：温度 ≥40℃ → 全量还原
private let chargeAbortPct = 35...85              // 安全线：电量出 [35,85] → 全量还原（采样期，宽于预检窗）
private let rpmPlausibleRange = 1.0...60000.0     // LE 合理域辅助判读（母本 §2.2 U7 辅助）

// MARK: - SMC 常量与错误码（照抄 m0 体系）
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

// MARK: - SMCParam（80B 固定偏移手工封包，照 m0；dataType 尾空格 trim）
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
    var dataType: String {
        let v = Self.u32LE(buf, 32)
        let b = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: b, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
            ?? String(format: "0x%08X", v)
    }
    var result: UInt8 { buf[40] }
    var data8: UInt8 { get { buf[42] } set { buf[42] = newValue } }
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

// MARK: - SMCConnection（m0 传输；内部锁串行化）
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
        input.key = SMCParam.pack(key); input.data8 = cmdKeyInfo
        let (out, kr) = call(input)
        guard kr == KERN_SUCCESS, out.result == resultSuccess else { return nil }
        return (out.dataSize, out.dataType)
    }
    /// 两阶段读：先 getKeyInfo 取 dataSize 再带尺寸读；按请求尺寸切片（回复不回填 dataSize）。
    func read(_ key: String) -> (size: UInt32, type: String, bytes: [UInt8])? {
        guard let info = keyInfo(key) else { return nil }
        let input = SMCParam()
        input.key = SMCParam.pack(key); input.data8 = cmdRead; input.dataSize = info.size
        let (out, kr) = call(input)
        guard kr == KERN_SUCCESS, out.result == resultSuccess else { return nil }
        let n = Int(min(info.size, 32))
        return (info.size, info.type, Array(out.buf[48..<(48 + n)]))
    }
    func writeDetailed(_ key: String, bytes values: [UInt8]) -> (ok: Bool, kr: kern_return_t, result: UInt8) {
        let input = SMCParam()
        input.key = SMCParam.pack(key); input.data8 = cmdWrite
        input.dataSize = UInt32(values.count); input.setBytes(values)
        let (out, kr) = call(input)
        return (kr == KERN_SUCCESS && out.result == resultSuccess, kr, out.result)
    }
}

// MARK: - 电池遥测（进程内 IOKit 直读 AppleSmartBattery；§8 纪律：温度/电量）
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
    private static func entryProps(_ name: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let props else { return nil }
        return props.takeRetainedValue() as? [String: Any]
    }
    /// GA 迁移实测（macOS 27.0 本机）：Temperature 已不在 AppleSmartBattery 顶层——
    /// 回退 AppleSmartBatteryPack → BatteryData 子层；仍不可得 = nil（温度安全线如实失效）。
    func sample() -> (percent: Int, isCharging: Bool, externalConnected: Bool, temperatureCentiC: Int?)? {
        guard let dict = Self.entryProps("AppleSmartBattery") else { return nil }
        guard let percent = Self.intVal(dict["CurrentCapacity"]),
              let isCharging = Self.boolVal(dict["IsCharging"]),
              let external = Self.boolVal(dict["ExternalConnected"]) else { return nil }
        var pack: [String: Any] = [:]
        if let packDict = Self.entryProps("AppleSmartBatteryPack"),
           let bd = packDict["BatteryData"] as? [String: Any] { pack = bd }
        let temp = Self.intVal(dict["Temperature"]) ?? Self.intVal(pack["Temperature"])
        return (percent, isCharging, external, temp)
    }
}

// MARK: - 小工具
private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
private func tempS(_ c: Double) -> String { String(format: "%.1f", c) }
private func fmtF(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "-" }
private func meanOf(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
/// 风扇键 flt 4B：IEEE754 单精度，U7 定版 LE（SMC-NOTES §8.1 U7：双序对照 LE 合理、BE=0）。
private func decodeFltLE(_ b: [UInt8]) -> Double? {
    guard b.count == 4 else { return nil }
    let bits = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    return Double(Float(bitPattern: bits))
}
private func encodeFltLE(_ v: Float) -> [UInt8] {
    let bits = v.bitPattern
    return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24)]
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
        out.append(v); i = j
    }
    return out
}
private func runTool(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return (-1, "") }
    p.waitUntilExit()
    return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}
private func processRunning(_ name: String) -> Bool { runTool("/usr/bin/pgrep", ["-x", name]).code == 0 }
private func launchctlLoaded(_ label: String) -> Bool { runTool("/bin/launchctl", ["print", label]).code == 0 }

// MARK: - 机型/固件头
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
                if let s = dict["model"] as? String { model = s }
                if let s = dict["IOFirmwareVersion"] as? String { firmware = s }
            }
            IOObjectRelease(expert)
        }
        let os = runTool("/usr/bin/sw_vers", ["-productVersion"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        return MachineInfo(model: model, firmware: firmware, macOS: os)
    }
}

// MARK: - Logger（线程安全；逐行 flush + stdout 双写）
private final class Logger: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?
    private let df = DateFormatter()
    let path: String
    init() {
        let d = DateFormatter()
        d.dateFormat = "yyyyMMdd-HHmmss"
        path = "/tmp/spike-ga-fan-" + d.string(from: Date()) + ".log"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        df.dateFormat = "HH:mm:ss.SSS"
    }
    func log(_ msg: String) {
        let line = "[\(df.string(from: Date()))] \(msg)\n"
        lock.lock(); defer { lock.unlock() }
        if let h = handle, let data = line.data(using: .utf8) { h.write(data); try? h.synchronize() }
        if let data = line.data(using: .utf8) { FileHandle.standardOutput.write(data) }
    }
}

// MARK: - 状态与结果持久化（R3：状态文件先于首写原子落盘；结果文件独立存活）
private struct KeyStateEntry: Codable { let key: String; let size: Int; let type: String; let originalHex: String }
private struct StateFile: Codable {
    let version: Int
    var model: String
    var firmware: String
    var macOS: String
    var createdAt: String
    var written: [String]
    var keys: [String: KeyStateEntry]
}
private struct ResultsFile: Codable {
    var model: String = "?"
    var firmware: String = "?"
    var macOS: String = "?"
    var e0: [String: String] = [:]
    var e2c: [String: String] = [:]
    var e3: [String: String] = [:]
    var f1: [String: String] = [:]
    var restore: [String: String] = [:]
}
private final class Store: @unchecked Sendable {
    private let lock = NSLock()
    let logger: Logger
    init(logger: Logger) { self.logger = logger }
    static func stateExists() -> Bool { FileManager.default.fileExists(atPath: stateFilePath) }
    func writeState(_ s: StateFile) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return writeStateLocked(s)
    }
    private func writeStateLocked(_ s: StateFile) -> Bool {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(s) else { return false }
        do { try data.write(to: URL(fileURLWithPath: stateFilePath), options: .atomic); return true } catch { return false }
    }
    func loadState() -> StateFile? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: stateFilePath)) else { return nil }
        return try? JSONDecoder().decode(StateFile.self, from: data)
    }
    /// 合并写状态文件（保留已录键并登记 written；写步前置条件）。
    func mergeState(machine: MachineInfo, addKeys: [String: KeyStateEntry], written: [String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var state = loadStateLocked() ?? StateFile(version: 1, model: machine.model, firmware: machine.firmware,
                                                   macOS: machine.macOS, createdAt: "", written: [], keys: [:])
        if state.createdAt.isEmpty {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            state.createdAt = df.string(from: Date())
            state.model = machine.model; state.firmware = machine.firmware; state.macOS = machine.macOS
        }
        for (k, v) in addKeys { state.keys[k] = v }
        for k in written where !state.written.contains(k) { state.written.append(k) }
        return writeStateLocked(state)   // Locked 版本：本方法已持锁（NSLock 不可重入）
    }
    /// 写步后登记 written 键（restore 依据；幂等）。
    func markWritten(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        guard var state = loadStateLocked() else { return }
        if !state.written.contains(key) { state.written.append(key) }
        _ = writeStateLocked(state)
    }
    func deleteState() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(atPath: stateFilePath)
        logger.log("[R3] 状态文件已删除 \(stateFilePath)（还原双验证通过的干净结束判据）")
    }
    func loadResults() -> ResultsFile {
        lock.lock(); defer { lock.unlock() }
        return loadResultsLocked()
    }
    func updateResults(_ mutate: (inout ResultsFile) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var r = loadResultsLocked()
        mutate(&r)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(r) else { logger.log("[结果] 结果文件编码失败（concl 将缺料——如实记录）"); return }
        do { try data.write(to: URL(fileURLWithPath: resultsFilePath), options: .atomic) } catch { logger.log("[结果] 结果文件写入失败：\(error)") }
    }
    private func loadResultsLocked() -> ResultsFile {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resultsFilePath)) else { return ResultsFile() }
        return (try? JSONDecoder().decode(ResultsFile.self, from: data)) ?? ResultsFile()
    }
    private func loadStateLocked() -> StateFile? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: stateFilePath)) else { return nil }
        return try? JSONDecoder().decode(StateFile.self, from: data)
    }
}

// MARK: - 防睡眠断言（母本 P1-6：写实验窗全程持有 NoIdleSleep）
private final class SleepGuardian: @unchecked Sendable {
    private var assertionID: IOPMAssertionID = 0
    private var held = false
    func acquire() -> Bool {
        let kr = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Cellar GA 风扇 spike（运行期间请勿合盖）" as CFString, &assertionID)
        held = kr == kIOReturnSuccess
        return held
    }
    func release() { if held { IOPMAssertionRelease(assertionID); held = false } }
}

// MARK: - Spike 主体
private final class FanSpike: @unchecked Sendable {
    private let logger: Logger
    private let machine: MachineInfo
    private let store: Store
    private let telemetry = Telemetry()
    private let smc: SMCConnection
    private let guardian = SleepGuardian()
    private let restoringLock = NSLock()
    private var restoring = false
    private var signalSources: [DispatchSourceSignal] = []
    init?(logger: Logger, machine: MachineInfo, smc: SMCConnection?, store: Store) {
        self.logger = logger
        self.machine = machine
        self.store = store
        if let smc { self.smc = smc } else {
            FileHandle.standardError.write("无法连接 SMC 用户客户端——拒绝启动\n".data(using: .utf8)!)
            return nil
        }
    }
    func run(_ cmd: String) -> Int32 {
        logger.log("=== GA 风扇 spike（S5）uid=\(getuid()) 机型=\(machine.model) 固件=\(machine.firmware) macOS=\(machine.macOS) 日志=\(logger.path) ===")
        switch cmd {
        case "preflight": return preflight()
        case "e0": return e0()
        case "ac": return acSnapshot()
        case "e2c": return e2c()
        case "e3": return e3()
        case "f1-stretch": return f1Stretch()
        case "restore": return restoreStep()
        case "concl": return concl()
        default:
            logger.log("""
            用法（读优先非 root；e0/e2c/e3/f1-stretch/restore 写需 root——显式 sudo）:
              swift Tools/spike-ga-fan.swift preflight        # 只读前置（bootout 唯一可接受态）
              swift Tools/spike-ga-fan.swift ac               # 只读快照：F0/F1 Ac·Tg·Md + 温度/电量（§11.3 判别实验取样器，无门禁）
              sudo swift Tools/spike-ga-fan.swift e0          # F0 五键基线 + Ftst 探测 + Ac 静息曲线
              sudo swift Tools/spike-ga-fan.swift e2c         # 解锁直写（结束仍 Md=1+Tg=3350——立即接 e3）
              sudo swift Tools/spike-ga-fan.swift e3          # 还原 + 干净窗
              sudo swift Tools/spike-ga-fan.swift f1-stretch  # F1 镜像（可选，自含还原）
              sudo swift Tools/spike-ga-fan.swift restore     # 按状态文件还原
              swift Tools/spike-ga-fan.swift concl            # U1–U4 汇总
            """)
            return cmd == "help" || cmd == "--help" ? 0 : 2
        }
    }
    /// ac：只读快照（F0/F1 Ac·Tg·Md + 温度/电量 + CPU 参考温度）——§11.3「系统模式 Ac=0」判别实验的取样器。
    /// 免 root（SMC 读非 root 可用，§1.3）、无门禁、零写入；静息/负载皆可采样，配合负载窗对照判读。
    /// CPU 参考温度 = Tp00（CPU 集群温度，v1.11 实测语义；GA 可读性运行时探测）——风扇起转判据看它而非电池温度
    /// （电池热质量大、短负载滞后数度，28→28.6℃ 的读数会误导负载强度判断——2026-09-30 首跑教训）。
    private func acSnapshot() -> Int32 {
        logger.log("=== ac 只读快照：F0/F1 Ac·Tg·Md + 温度/电量 + CPU 参考温度（无门禁；§11.3 判别实验取样器）===")
        for fan in ["F0", "F1"] {
            var parts: [String] = []
            for name in ["Ac", "Tg", "Md"] {
                let key = "\(fan)\(name)"
                guard let r = smc.read(key) else { parts.append("\(key)=读失败"); continue }
                if name == "Md" {
                    parts.append("\(key)=\(r.bytes.first.map { String(format: "%02X", $0) } ?? "-")")
                } else {
                    parts.append("\(key)=\(fmtF(decodeFltLE(r.bytes)))rpm")
                }
            }
            logger.log("[ac] " + parts.joined(separator: "  "))
        }
        // CPU 参考温度（Tp00/Tp01 flt ℃；不可读时如实标注——判读退化为「满载时长≥4min+耳听风扇声」）
        var cpuParts: [String] = []
        for key in ["Tp00", "Tp01"] {
            if let r = smc.read(key), r.type == "flt", let c = decodeFltLE(r.bytes) {
                cpuParts.append("\(key)=\(tempS(c))℃")
            } else {
                cpuParts.append("\(key)=不可读")
            }
        }
        logger.log("[ac] CPU参考温度 " + cpuParts.joined(separator: "  "))
        if let t = telemetry.sample() {
            logger.log("[ac] 电池温度=\(t.temperatureCentiC.map { tempS(Double($0) / 100) } ?? "-")℃ 电量=\(t.percent)% isCharging=\(t.isCharging ? "Yes" : "No")")
        } else {
            logger.log("[ac] 遥测不可用（温度/电量略）")
        }
        logger.log("[ac] verdict=done（只读；判别采样须在「CPU 参考温度显著升高且耳听风扇已转」时取——否则只证明风扇未起转）")
        return 0
    }
    private func emitConclLine(_ key: String, _ value: String) { logger.log("concl.fan.\(key)=\(value)") }
    private func requireRoot(_ step: String) -> Bool {
        guard getuid() == 0 else {
            logger.log("[权限] \(step) 写 SMC 需 root——请显式 sudo 执行")
            return false
        }
        return true
    }
    private func countdown(_ seconds: Int, summary: String) {
        for i in stride(from: seconds, through: 1, by: -1) {
            logger.log("[倒计时] \(i)s 后执行：\(summary)（Ctrl-C 立即还原）")
            Thread.sleep(forTimeInterval: 1)
        }
    }
    /// R7 信号安全网：写实验期间收到信号 → 按状态文件全量还原后退出。
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.global())
            src.setEventHandler { [weak self] in self?.restoreOnSignal(sig) }
            src.resume()
            signalSources.append(src)
        }
    }
    private func restoreOnSignal(_ sig: Int32) {
        restoringLock.lock()
        if restoring { restoringLock.unlock(); return }
        restoring = true
        restoringLock.unlock()
        logger.log("[中断] 收到信号 \(sig)——立即全量还原（R7）")
        _ = fullRestore()
        emitConclLine("interrupt", "signal-\(sig)-restored")
        exit(130)
    }
    /// 采样点安全线（母本全量沿用）：温度 ≥40℃ 或电量出 [35,85] → 全量还原并中止（触发即 exit，永不返回）。
    @discardableResult
    private func checkSafety(_ s: (percent: Int, isCharging: Bool, externalConnected: Bool, temperatureCentiC: Int?)) -> Bool {
        var trip = ""
        if let tc = s.temperatureCentiC, tc >= tempAbortCentiC { trip = "温度 \(tempS(Double(tc) / 100))℃ 达 40℃" }
        if !chargeAbortPct.contains(s.percent) { trip += (trip.isEmpty ? "" : "；") + "电量 \(s.percent)% 出 [35,85]" }
        if !trip.isEmpty {
            logger.log("[安全] 触发：\(trip)——全量还原并中止")
            _ = fullRestore()
            emitConclLine("abort", "safety(\(trip))")
            exit(130)
        }
        return true
    }
    /// 阶梯还原单键（9 轮：3 次→等 5s→再 3 轮）。true = 值级还原验证通过。
    private func ladderRestore(key: String) -> Bool {
        guard let state = store.loadState(), let entry = state.keys[key] else {
            logger.log("[还原] 无 \(key) 原始值记录——无法还原")
            return false
        }
        guard let original = parseHexBytes(entry.originalHex) else { logger.log("[还原] \(key) 原值解析失败"); return false }
        for round in 0..<9 {
            if round == 3 || round == 6 { logger.log("[还原] \(key) 阶梯第 \(round + 1) 轮前等 5s"); Thread.sleep(forTimeInterval: 5) }
            let (ok, kr, result) = smc.writeDetailed(key, bytes: original)
            logger.log("SMC写(还原) key=\(key) value=\(entry.originalHex) kr=\(String(format: "0x%08X", kr))(\(krExplain(kr))) result=\(result)(\(resultExplain(result)))")
            Thread.sleep(forTimeInterval: 0.5)
            guard ok, let back = smc.read(key), back.bytes == original else { continue }
            logger.log("[还原] \(key) 回读一致 value=\(entry.originalHex)")
            return true
        }
        logger.log("[还原] \(key) 9 轮重试后仍无法还原——如实记录，不粉饰")
        return false
    }
    /// 全量还原 written 键。true = 全部值级还原验证通过。
    private func fullRestore() -> Bool {
        guard let state = store.loadState() else { logger.log("[还原] 无状态文件——无需还原"); return true }
        var ok = true
        for key in state.written.sorted() { if !ladderRestore(key: key) { ok = false } }
        store.updateResults { $0.restore["last"] = ok ? "verified" : "failed-value" }
        return ok
    }
    /// 锁存重试阶梯写（写后每档回读前依次延时 100/300/800ms——FanSMC.verifyLadderMs 逐字同款，§10.1）。
    private func writeKeyLadder(_ key: String, _ value: [UInt8], step: String) -> (ok: Bool, at: String, readback: String) {
        guard let cur = smc.read(key) else { logger.log("[\(step)] \(key) 读取失败——中止"); return (false, "", "read-fail") }
        if cur.bytes == value { logger.log("[\(step)] \(key) 已是目标态 \(hex(value))"); return (true, "already", hex(cur.bytes)) }
        logger.log("[\(step)] \(key)：\(hex(cur.bytes)) → \(hex(value))（锁存阶梯 \(verifyLadderMs.reduce(0, +))ms）")
        countdown(5, summary: "写 \(key)=\(hex(value))（\(step)）")
        let (ok, kr, result) = smc.writeDetailed(key, bytes: value)
        logger.log("SMC写 key=\(key) value=\(hex(value)) kr=\(String(format: "0x%08X", kr))(\(krExplain(kr))) result=\(result)(\(resultExplain(result)))")
        guard ok else { return (false, "", String(format: "kr=0x%08X result=%d", kr, result)) }
        var elapsedMs = 0
        var lastHex = "?"
        for ms in verifyLadderMs {
            Thread.sleep(forTimeInterval: TimeInterval(ms) / 1000)
            elapsedMs += ms
            guard let back = smc.read(key) else { return (false, "", "read-fail") }
            lastHex = hex(back.bytes)
            if back.bytes == value {
                logger.log("[\(step)] \(key)=\(hex(value)) 锁存阶梯验证通过 @+\(elapsedMs)ms")
                return (true, "@+\(elapsedMs)ms", lastHex)
            }
        }
        logger.log("[\(step)] \(key) 锁存阶梯 \(verifyLadderMs.reduce(0, +))ms 内回读=\(lastHex) ≠期望——如实记录")
        return (false, "", lastHex)
    }
    private struct FanSample {
        let tempCentiC: Int?, percent: Int
        let acHex: String?, acRPM: Double?
        let tgHex: String?, mdRaw: UInt8?
    }
    private func sampleFan(prefix: String) -> FanSample? {
        guard let t = telemetry.sample() else { return nil }
        let ac = smc.read("\(prefix)Ac"), tg = smc.read("\(prefix)Tg"), md = smc.read("\(prefix)Md")
        return FanSample(tempCentiC: t.temperatureCentiC, percent: t.percent,
                         acHex: ac.map { hex($0.bytes) }, acRPM: ac.flatMap { b in
                             b.type == "flt" ? decodeFltLE(b.bytes) : b.bytes.first.map(Double.init)
                         },
                         tgHex: tg.map { hex($0.bytes) }, mdRaw: md?.bytes.first)
    }
    // MARK: preflight（R2：bootout 唯一可接受态；§8 温度/电量窗）
    private func preflight() -> Int32 {
        logger.log("=== preflight：R2 daemon 卸载检查（S5——bootout 为唯一可接受态，关闭编排开关不算过）+ 温度/电量窗 ===")
        var ok = true
        // §10.1 教训：pgrep 双名（com.cellar.daemon 安装名 / cellar-daemon 构建名）+ launchctl 腿
        if processRunning("com.cellar.daemon") || processRunning("cellar-daemon") {
            logger.log("[检查] daemon 卸载(pgrep 双名)=失败——进程仍在：sudo launchctl bootout system/com.cellar.daemon")
            ok = false
        } else { logger.log("[检查] daemon 卸载(pgrep com.cellar.daemon + cellar-daemon)=通过") }
        if launchctlLoaded("system/com.cellar.daemon") {
            logger.log("[检查] daemon 卸载(launchctl)=失败——服务仍注册。S5 必须完全卸载：bootout 是唯一路径（R2）；「通用页关闭编排开关」只断编排决策域，不断风扇执法域与退出恢复写，不算过")
            ok = false
        } else { logger.log("[检查] daemon 卸载(launchctl print)=通过（bootout 唯一可接受态成立）") }
        guard let s = telemetry.sample() else {
            logger.log("[检查] 电池遥测=失败")
            emitConclLine("preflight", "fail(telemetry-unavailable)")
            return 3
        }
        if preflightPct.contains(s.percent) { logger.log("[检查] 电量 40–75%=通过 (\(s.percent)%)") } else {
            logger.log("[检查] 电量 40–75%=失败——当前 \(s.percent)%（§8 纪律）"); ok = false
        }
        if let tc = s.temperatureCentiC {
            if tc < preflightTempCentiC {
                logger.log("[检查] 温度<35℃=通过 (\(tempS(Double(tc) / 100))℃)")
            } else {
                logger.log("[检查] 温度<35℃=失败——当前 \(tempS(Double(tc) / 100))℃（热态下 Md=0 系统会重写 Tg，污染观测）"); ok = false
            }
        } else {
            logger.log("[检查] 温度=不可得（顶层与 Pack 层均无 Temperature——GA 迁移；温度门禁失效，如实记录）"); ok = false
        }
        emitConclLine("preflight", ok ? "pass" : "fail(见日志逐项)")
        logger.log(ok ? "preflight 结论：就绪（S5 无 R2 备选——未 bootout 不得进入写实验）" : "preflight 结论：未就绪")
        return ok ? 0 : 3
    }
    // MARK: e0（§7 E0：F0 五键基线 + Ftst 探测负样本 + Ac 静息曲线）
    private func e0() -> Int32 {
        logger.log("=== E0：F0Ac/F0Mn/F0Mx/F0Md/F0Tg 五键 keyInfo+基线（U7 LE 解读）+ Ftst keyInfo 探测 + 60s Ac 静息曲线 ===")
        guard requireRoot("e0") else { return 2 }   // P3-3：防生成用户属主状态文件（与写步同身份）
        var keys: [String: KeyStateEntry] = [:]
        var e0r: [String: String] = [:]
        for name in ["Ac", "Mn", "Mx", "Tg", "Md"] {
            let key = "F0\(name)"
            guard let info = smc.keyInfo(key), let r = smc.read(key) else {
                e0r[key] = "absent"
                logger.log("[E0] \(key)=不存在/不可读")
                continue
            }
            let le = decodeFltLE(r.bytes)
            e0r[key] = "type=\(info.type) size=\(info.size) hex=\(hex(r.bytes)) LE=\(fmtF(le))"
            logger.log("[E0] \(key)=在位 type=\(info.type) size=\(info.size) hex=\(hex(r.bytes)) LE=\(fmtF(le))rpm\(rpmPlausibleRange.contains(le ?? -1) ? "" : "（LE 不在合理域——如实记录）")")
            if name == "Tg" || name == "Md" {
                keys[key] = KeyStateEntry(key: key, size: Int(info.size), type: info.type, originalHex: hex(r.bytes))
            }
        }
        // Ftst 探测（§7 E0：M2 Max 预期不存在/无效——记负样本；M3+ 参数不在本机验证）
        if let info = smc.keyInfo("Ftst") {
            e0r["ftst"] = "present type=\(info.type) size=\(info.size)"
            logger.log("[E0] Ftst=存在 type=\(info.type) size=\(info.size)（负样本预期落空——行为验证不在本机做，仅成档）")
        } else {
            e0r["ftst"] = "absent(M2 Max 预期负样本成立)"
            logger.log("[E0] Ftst=不存在/无效（M2 Max 预期负样本——记入键世代表）")
        }
        // 60s Ac 静息曲线（e3 干净窗「Ac 回基线」判据的基线）
        var acs: [Double] = []
        for i in 0..<30 {
            if i > 0 { Thread.sleep(forTimeInterval: 2) }
            guard let t = telemetry.sample() else { logger.log("[E0] #\(i + 1)/30 遥测不可用——跳过"); continue }
            checkSafety(t)
            if let ac = smc.read("F0Ac"), ac.type == "flt", let rpm = decodeFltLE(ac.bytes), rpm != 0 { acs.append(rpm) }
        }
        let base = meanOf(acs)
        e0r["acBaselineRPM"] = base.map { String(format: "%.0f", $0) } ?? "n/a"
        e0r["done"] = "true"
        logger.log("[E0] Ac 静息基线=\(fmtF(base))rpm（n=\(acs.count)）；温度/电量=\(telemetry.sample().map { "\($0.temperatureCentiC.map { tempS(Double($0) / 100) } ?? "-")℃/\($0.percent)%" } ?? "n/a")")
        guard store.mergeState(machine: machine, addKeys: keys, written: []) else {
            logger.log("[E0] 状态文件写入失败（\(stateFilePath)）——拒绝（R3 先于首写）")
            return 3
        }
        logger.log("[E0] 状态文件就绪 \(stateFilePath)（F0Tg/F0Md 原值已录）")
        store.updateResults {
            $0.model = self.machine.model; $0.firmware = self.machine.firmware; $0.macOS = self.machine.macOS
            $0.e0 = e0r
        }
        emitConclLine("e0", "done acBaseline=\(fmtF(base))rpm ftst=\(e0r["ftst"] ?? "?")")
        return 0
    }
    // MARK: e2c（§7：Md=0 负探针〔U4〕→ Md=1 阶梯 → Tg=3350 阶梯 → 60s 驻留+Ac 跟随）
    private func e2c() -> Int32 {
        logger.log("=== E2c（F0）：Md=0 负探针 → F0Md=1（锁存阶梯）→ F0Tg=3350（同阶梯）→ 60s@2s 驻留+跟随 ===")
        guard requireRoot("e2c") else { return 2 }
        guard Store.stateExists() else { logger.log("[E2c] 状态文件不存在——请先 sudo … e0（R3）"); return 3 }
        guard let state = store.loadState(), let tgOrig = state.keys["F0Tg"], let mdOrig = state.keys["F0Md"] else {
            logger.log("[E2c] 状态文件缺 F0Tg/F0Md 原值——请先 e0"); return 3
        }
        guard let curMd = smc.read("F0Md"), curMd.bytes == parseHexBytes(mdOrig.originalHex) ?? [] else {
            logger.log("[E2c] F0Md 现值≠基线（残留？）——请先 sudo … restore"); return 3
        }
        installSignalHandlers()
        guard guardian.acquire() else { logger.log("[E2c] 防睡眠断言获取失败——中止"); return 3 }
        defer { guardian.release() }
        guard let tgOrigBytes = parseHexBytes(tgOrig.originalHex) else { logger.log("[E2c] F0Tg 原值解析失败"); return 3 }
        // U4 负探针：Md=0（系统自动）态写 Tg——§8.1 U4：固件即时拒绝（读后 1s 回读=原值）
        logger.log("[U4] Md=0 负探针：写 F0Tg=3350（预期固件拒写）")
        let probe = writeKeyLadder("F0Tg", encodeFltLE(tgTargetF0), step: "E2c-md0probe")
        var md0Rejected = false
        if probe.ok {
            logger.log("[U4] Md=0 态 Tg 写入被接受（回读=\(probe.readback)）——与 §8 U4 相悖，如实记录")
            md0Rejected = false
            if !ladderRestore(key: "F0Tg") { logger.log("[U4] 负探针后 Tg 还原失败——中止"); return 1 }
        } else {
            md0Rejected = true
            logger.log("[U4] Md=0 态 Tg 被拒（写后 \(verifyLadderMs.reduce(0, +))ms 内回读=\(probe.readback) ≠目标）——U4 拒写证据成立")
            // 负探针的写 kr 可能成功但值未变（固件级拒绝）——核对现值仍为原值
            if let now = smc.read("F0Tg"), now.bytes != tgOrigBytes {
                logger.log("[U4] Tg 现值已被改动——阶梯还原")
                if !ladderRestore(key: "F0Tg") { return 1 }
            }
        }
        // 解锁：F0Md=1（锁存阶梯）
        let mdWrite = writeKeyLadder("F0Md", [0x01], step: "E2c-md1")
        store.markWritten("F0Md")   // R3：写已发生——信号/异常还原与 restore 的依据
        guard mdWrite.ok else {
            logger.log("[E2c] F0Md=1 锁存阶梯失败——还原并终止")
            _ = fullRestore()
            store.updateResults { $0.e2c["mdLadder"] = "fail" }
            emitConclLine("e2c", "fail(md-ladder)")
            return 1
        }
        // F0Tg=3350（Md=1 解锁态）
        let tgWrite = writeKeyLadder("F0Tg", encodeFltLE(tgTargetF0), step: "E2c-tg")
        store.markWritten("F0Tg")   // R3：写已发生——登记 written
        guard tgWrite.ok else {
            logger.log("[E2c] F0Tg=3350 锁存阶梯失败（Md=1 态仍拒写？）——还原并终止")
            _ = fullRestore()
            store.updateResults { $0.e2c["tgLadder"] = "fail" }
            emitConclLine("e2c", "fail(tg-ladder)")
            return 1
        }
        // 60s 驻留 + Ac 跟随（满窗判读，前 3 样本=6s 爬升宽限，§10 先例）
        let targetHex = hex(encodeFltLE(tgTargetF0))
        var samples: [FanSample] = []
        for i in 0..<(e2cWindowS / e2cStepS) {
            if i > 0 { Thread.sleep(forTimeInterval: TimeInterval(e2cStepS)) }
            guard let s = sampleFan(prefix: "F0"), let t = telemetry.sample() else { logger.log("[E2c] #\(i + 1) 采样失败——跳过"); continue }
            checkSafety(t)
            samples.append(s)
            logger.log("[E2c] #\(i + 1) ac=\(fmtF(s.acRPM))rpm tg=\(s.tgHex ?? "读失败") md=\(s.mdRaw.map { String(format: "%02X", $0) } ?? "读失败") temp=\(s.tempCentiC.map { tempS(Double($0) / 100) } ?? "-")℃ percent=\(s.percent)%")
        }
        let resident = !samples.isEmpty && samples.allSatisfy { $0.tgHex == targetHex }
        let evaluated = samples.dropFirst(followGraceSamples)
        let floor = Double(tgTargetF0) - followAcFloorRPM
        let followAll = !evaluated.isEmpty && evaluated.allSatisfy { ($0.acRPM ?? 0) >= floor }
        let followMax = samples.compactMap { $0.acRPM }.max()
        let acVals = evaluated.compactMap { $0.acRPM }
        let followMin = acVals.min()
        logger.log("[E2c] 判读：Tg 驻留=\(resident)（\(samples.count) 样本）；Ac 跟随=\(followAll)（宽限 \(followGraceSamples) 样本不计；评估段 min=\(fmtF(followMin)) max=\(fmtF(followMax))；阈 ≥\(Int(floor))rpm）")
        store.updateResults {
            $0.e2c["md0Probe"] = md0Rejected ? "rejected(U4 证据成立)" : "accepted(unexpected)"
            $0.e2c["mdLadder"] = "ok\(mdWrite.at)"
            $0.e2c["tgLadder"] = "ok\(tgWrite.at)"
            $0.e2c["tgResident"] = resident ? "true" : "false"
            $0.e2c["acFollow"] = followAll ? "true" : "false"
            $0.e2c["acMin"] = fmtF(followMin)
            $0.e2c["acMax"] = fmtF(followMax)
            $0.e2c["graceSamples"] = "\(followGraceSamples)"
        }
        emitConclLine("e2c", "done md0=\(md0Rejected ? "rejected" : "accepted") resident=\(resident) follow=\(followAll) acMin=\(fmtF(followMin))")
        logger.log("[警示] 风扇仍处于 Md=1 + Tg=3350 手动态——立即 sudo … e3 还原；异常情况 sudo … restore")
        return resident && followAll ? 0 : 1
    }
    // MARK: e3（§7：Tg→原值 + Md=0 还原阶梯双验证 + 干净窗 60s）
    private func e3() -> Int32 {
        logger.log("=== E3（F0）：F0Tg→原值 + F0Md=0（还原阶梯双验证）→ 干净窗 60s@2s ===")
        guard requireRoot("e3") else { return 2 }
        guard Store.stateExists() else { logger.log("[E3] 状态文件不存在——请先 sudo … e0（R3）"); return 3 }
        installSignalHandlers()
        guard guardian.acquire() else { logger.log("[E3] 防睡眠断言获取失败——中止"); return 3 }
        defer { guardian.release() }
        guard let state = store.loadState(), let tgOrig = state.keys["F0Tg"], let mdOrig = state.keys["F0Md"],
              let tgBytes = parseHexBytes(tgOrig.originalHex), let mdBytes = parseHexBytes(mdOrig.originalHex) else {
            logger.log("[E3] 状态文件缺 F0Tg/F0Md 原值——无法还原"); return 3
        }
        // 还原阶梯双验证（Tg 先、Md 后——释放序列 = F0Tg 还原 + F0Md=0，§8.1 U4）
        let tgOK = ladderRestore(key: "F0Tg")
        let mdOK = ladderRestore(key: "F0Md")
        let verified = tgOK && mdOK
            && smc.read("F0Tg").map { $0.bytes == tgBytes } == true
            && smc.read("F0Md").map { $0.bytes == mdBytes } == true
        logger.log("[E3] 还原双验证：Tg=\(tgOK) Md=\(mdOK) 复核=\(verified ? "通过" : "失败")")
        // 干净窗：Ac 回基线 ±150rpm 或 Tg 被系统接管（Md=0 热态重写，§8.2）；Tg 无漂移=仍在原值
        let results = store.loadResults()
        let baseline = Double(results.e0["acBaselineRPM"] ?? "n/a") ?? nil
        var tgDrifted = false
        var clean = false
        var note = ""
        var acs: [Double] = []
        for i in 0..<(cleanWindowS / cleanStepS) {
            if i > 0 { Thread.sleep(forTimeInterval: TimeInterval(cleanStepS)) }
            guard let s = sampleFan(prefix: "F0"), let t = telemetry.sample() else { continue }
            checkSafety(t)
            if let tgHex = s.tgHex, tgHex != hex(tgBytes) { tgDrifted = true }
            if let rpm = s.acRPM { acs.append(rpm) }
            logger.log("[E3窗] #\(i + 1) ac=\(fmtF(s.acRPM))rpm tg=\(s.tgHex ?? "读失败") md=\(s.mdRaw.map { String(format: "%02X", $0) } ?? "读失败") temp=\(t.temperatureCentiC.map { tempS(Double($0) / 100) } ?? "-")℃")
        }
        // 全窗判读（母本 E5 同款）：全程 Ac 回基线 ±150rpm；或 Tg 被系统接管（§8.2）
        if let base = baseline, !acs.isEmpty {
            if acs.allSatisfy({ abs($0 - base) <= baselineAcTolRPM }) {
                clean = true; note = "Ac 全窗回基线 \(String(format: "%.0f", base))±\(Int(baselineAcTolRPM))rpm 内（n=\(acs.count)）"
            } else if tgDrifted {
                clean = true; note = "Ac 出基线但 Tg 被系统接管改写（Md=0 接管证据，§8.2）"
            } else {
                clean = false; note = "Ac 出基线且 Tg 未变——不可解释态（如实记录）"
            }
        } else {
            clean = true
            note = "e0 基线缺失——降级为 Tg 判读：\(tgDrifted ? "被系统接管（接管证据）" : "全程驻留原值（无残留）")"
        }
        store.updateResults {
            $0.e3["verified"] = verified ? "true" : "false"
            $0.e3["clean"] = clean ? "true" : "false"
            $0.e3["note"] = note
        }
        emitConclLine("e3", "\(verified ? "verified" : "FAILED") clean=\(clean ? "pass" : "fail")（\(note)）")
        if verified {
            store.deleteState()
            logger.log("[检查单] 还原双验证通过——请 sudo launchctl bootstrap system /Library/LaunchDaemons/com.cellar.daemon.plist 恢复 daemon 并以 cellar doctor 三方 PASS 收尾（R2）")
            return clean ? 0 : 1
        }
        logger.log("[检查单] 还原未验证通过：保留状态文件与日志，勿重启，按 runbook 处置（手动兜底 sudo … restore）")
        return 1
    }
    // MARK: f1-stretch（§7 stretch：F1 镜像，自含还原；红线：不写 F1Mn）
    private func f1Stretch() -> Int32 {
        logger.log("=== F1-stretch：F1 镜像（基线 → Md=0 负探针 → Md=1 阶梯 → Tg=3650 → 60s 窗 → 还原 + \(f1CleanWindowS)s 干净窗）===")
        guard requireRoot("f1-stretch") else { return 2 }
        // F1 五键在位性（U5' 信息）+ 原值入状态文件（P0-1）
        var keys: [String: KeyStateEntry] = [:]
        var present: [String] = []
        for name in ["Ac", "Mn", "Mx", "Tg", "Md"] {
            let key = "F1\(name)"
            guard let info = smc.keyInfo(key), let r = smc.read(key) else { logger.log("[F1] \(key)=不存在/不可读"); continue }
            present.append(key)
            logger.log("[F1] \(key)=在位 type=\(info.type) hex=\(hex(r.bytes)) LE=\(fmtF(decodeFltLE(r.bytes)))")
            if name == "Tg" || name == "Md" { keys[key] = KeyStateEntry(key: key, size: Int(info.size), type: info.type, originalHex: hex(r.bytes)) }
        }
        guard keys["F1Tg"] != nil, keys["F1Md"] != nil else {
            logger.log("[F1] F1Tg/F1Md 不全在位——stretch 放弃（如实记录）")
            store.updateResults { $0.f1["run"] = "skipped(keys-missing)" }
            emitConclLine("f1.stretch", "skipped(F1Tg/F1Md 缺)")
            return 3
        }
        guard store.mergeState(machine: machine, addKeys: keys, written: []) else { logger.log("[F1] 状态文件写入失败——拒绝（R3）"); return 3 }
        installSignalHandlers()
        guard guardian.acquire() else { return 3 }
        defer { guardian.release() }
        // Md=0 负探针
        let probe = writeKeyLadder("F1Tg", encodeFltLE(tgTargetF1), step: "F1-md0probe")
        store.markWritten("F1Tg")   // R3：写已发生——登记 written
        let md0Rejected = !probe.ok
        if probe.ok, !ladderRestore(key: "F1Tg") { return 1 }
        // 解锁 + 直写
        let f1md = writeKeyLadder("F1Md", [0x01], step: "F1-md1")
        store.markWritten("F1Md")
        guard f1md.ok else {
            _ = fullRestore(); store.updateResults { $0.f1["run"] = "fail(md-ladder)" }
            emitConclLine("f1.stretch", "fail(md-ladder)")
            return 1
        }
        let f1tg = writeKeyLadder("F1Tg", encodeFltLE(tgTargetF1), step: "F1-tg")
        guard f1tg.ok else {
            _ = fullRestore(); store.updateResults { $0.f1["run"] = "fail(tg-ladder)" }
            emitConclLine("f1.stretch", "fail(tg-ladder)")
            return 1
        }
        let targetHex = hex(encodeFltLE(tgTargetF1))
        var samples: [FanSample] = []
        for i in 0..<(e2cWindowS / e2cStepS) {
            if i > 0 { Thread.sleep(forTimeInterval: TimeInterval(e2cStepS)) }
            guard let s = sampleFan(prefix: "F1"), let t = telemetry.sample() else { continue }
            checkSafety(t)
            samples.append(s)
            logger.log("[F1窗] #\(i + 1) ac=\(fmtF(s.acRPM))rpm tg=\(s.tgHex ?? "读失败") md=\(s.mdRaw.map { String(format: "%02X", $0) } ?? "读失败") temp=\(s.tempCentiC.map { tempS(Double($0) / 100) } ?? "-")℃")
        }
        let resident = !samples.isEmpty && samples.allSatisfy { $0.tgHex == targetHex }
        let evaluated = samples.dropFirst(followGraceSamples)
        let floor = Double(tgTargetF1) - followAcFloorRPM
        let follow = !evaluated.isEmpty && evaluated.allSatisfy { ($0.acRPM ?? 0) >= floor }
        let tgOK = ladderRestore(key: "F1Tg")
        let mdOK = ladderRestore(key: "F1Md")
        let verified = tgOK && mdOK
        var cleanNote = "n/a"
        if verified {
            var tgDrifted = false
            for i in 0..<(f1CleanWindowS / f1CleanStepS) {
                if i > 0 { Thread.sleep(forTimeInterval: TimeInterval(f1CleanStepS)) }
                if let s = sampleFan(prefix: "F1"), let hexOrig = keys["F1Tg"].map({ $0.originalHex }), s.tgHex != hexOrig { tgDrifted = true }
            }
            cleanNote = tgDrifted ? "Tg 被系统接管（接管证据）" : "Tg 全程驻留原值（无残留）"
        }
        store.updateResults {
            $0.f1["run"] = verified ? "done" : "restore-fail"
            $0.f1["md0Probe"] = md0Rejected ? "rejected" : "accepted(unexpected)"
            $0.f1["resident"] = resident ? "true" : "false"
            $0.f1["follow"] = follow ? "true" : "false"
            $0.f1["keys"] = present.joined(separator: ",")
            $0.f1["clean"] = cleanNote
        }
        emitConclLine("f1.stretch", "\(verified ? "done" : "restore-fail") md0=\(md0Rejected ? "rejected" : "accepted") resident=\(resident) follow=\(follow)")
        logger.log("[F1] stretch 完成：驻留=\(resident) 跟随=\(follow) 还原=\(verified)（\(cleanNote)）")
        return verified && resident ? 0 : 1
    }
    // MARK: restore
    private func restoreStep() -> Int32 {
        logger.log("=== restore：按状态文件逐键还原 ===")
        guard requireRoot("restore") else { return 2 }
        guard let state = store.loadState() else { logger.log("无状态文件（\(stateFilePath)）——无需还原"); return 0 }
        logger.log("状态文件载入：createdAt=\(state.createdAt) written=[\(state.written.joined(separator: ","))]")
        installSignalHandlers()
        if fullRestore() {
            store.deleteState()
            emitConclLine("restore.last", "verified")
            logger.log("[检查单] 还原验证通过——请 bootstrap 恢复 daemon 并以 cellar doctor 三方 PASS 收尾（R2）")
            return 0
        }
        emitConclLine("restore.last", "failed-value")
        logger.log("[检查单] 还原失败：保留状态文件与日志，勿合盖，按 runbook 处置")
        return 1
    }
    // MARK: concl（§8.1 U1–U4 四条镜像判定 + GO/NO-GO）
    private func concl() -> Int32 {
        logger.log("=== concl：§8.1 U1–U4 镜像判定（结果文件 /tmp/spike-ga-results-fan.json）===")
        let r = store.loadResults()
        guard r.e0["done"] == "true" else {
            logger.log("结果文件缺 E0 记录——实验未执行或不完整，无法判定")
            emitConclLine("go", "no-go(缺 E0)")
            return 1
        }
        emitConclLine("e0.ftst", r.e0["ftst"] ?? "未记录")
        emitConclLine("e0.acBaseline", "\(r.e0["acBaselineRPM"] ?? "?")rpm")
        // U1 写通路：Md=1 解锁写 + Tg 直写的锁存阶梯回读一致
        let mdLadder = r.e2c["mdLadder"]?.hasPrefix("ok") == true
        let tgLadder = r.e2c["tgLadder"]?.hasPrefix("ok") == true
        let u1 = mdLadder && tgLadder
        emitConclLine("u1.writepath", u1 ? "pass(Md\(r.e2c["mdLadder"] ?? "?") Tg\(r.e2c["tgLadder"] ?? "?"))" : "fail")
        // U2 解锁直写+跟随：Tg 60s 驻留 + Ac≥目标−300（宽限 3 样本预注册）
        let u2 = r.e2c["tgResident"] == "true" && r.e2c["acFollow"] == "true"
        emitConclLine("u2.unlockfollow", u2 ? "pass(resident + acMin=\(r.e2c["acMin"] ?? "?")≥目标−300)" : "fail(resident=\(r.e2c["tgResident"] ?? "?") follow=\(r.e2c["acFollow"] ?? "?"))")
        // U3 恢复干净：还原阶梯双验证 + 干净窗
        let u3 = r.e3["verified"] == "true" && r.e3["clean"] == "true"
        emitConclLine("u3.restore", u3 ? "pass(\(r.e3["note"] ?? ""))" : "fail(\(r.e3["note"] ?? "未执行"))")
        // U4 Md 语义：Md=0 态 Tg 被固件拒 + Md=1 态可写驻留
        let u4 = r.e2c["md0Probe"]?.hasPrefix("rejected") == true && r.e2c["tgResident"] == "true"
        emitConclLine("u4.md_semantics", u4 ? "pass(Md=0 拒写 + Md=1 直写驻留)" : "fail(md0=\(r.e2c["md0Probe"] ?? "?"))")
        // F1 stretch（信息项，不进判定）
        emitConclLine("f1.stretch", r.f1["run"] ?? "未执行")
        if r.f1["run"] != nil && r.f1["run"] != "未执行" {
            emitConclLine("f1.detail", "md0=\(r.f1["md0Probe"] ?? "?") resident=\(r.f1["resident"] ?? "?") follow=\(r.f1["follow"] ?? "?") keys=\(r.f1["keys"] ?? "?")")
        }
        emitConclLine("restore.last", r.restore["last"] ?? "未执行")
        let go = u1 && u2 && u3 && u4
        emitConclLine("go", go ? "GO(风扇 GA 维持——U1–U4 四条镜像全 pass)" : "NO-GO(27 上风扇维持只读诚实化——详见逐条判定)")
        logger.log("=== 判定汇总：\(go ? "GO" : "NO-GO") ===")
        return go ? 0 : 1
    }
}

// MARK: - 主入口
private let argumentsFan = Array(CommandLine.arguments.dropFirst())
private let commandFan = argumentsFan.first ?? "help"
private let loggerFan = Logger()
private let machineFan = MachineInfo.gather()
private let storeFan = Store(logger: loggerFan)
private let smcFan = SMCConnection()
guard let spike = FanSpike(logger: loggerFan, machine: machineFan, smc: smcFan, store: storeFan) else { exit(1) }
exit(spike.run(commandFan))
