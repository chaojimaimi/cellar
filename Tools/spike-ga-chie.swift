#!/usr/bin/env swift
// Cellar macOS 27 GA CHIE spike（S1）— 方案 docs/plans/phase5-0.20-macos27-ga-spike.md §3 v3 定稿；唯一事实源 docs/SMC-NOTES.md
// 镜像 Tools/spike-discharge.swift：SMCParam 80B 手工封包（Swift struct 复刻 76B≠80B 的坑）/ selector 2 + data8 /
// key 小端 uint32 打包 / 两阶段读（回复包不回填 dataSize——按 getKeyInfo 尺寸切片）/ dataType 尾空格 trim / 还原阶梯 / concl.* 机器可读。
// 步骤绑定（§3）：preflight(R2 daemon 卸载双腿+launchctl、R1 电量窗 40–75、R6 AC) → e0(基线+ioreg 快照+状态文件) →
//   e1(同值回写——forceWrite 真实写+回读验证) → e2(写 0x08→10min 窗 30s×20 点，窗末 ladderRestore 还原 00；
//   raw 不可得降级 15min×30 点) → e3(恢复写 00——e2 已还原时为同值 no-op，真实写证据=e2 写读表；三要素窗 60s) →
//   restore(还原+双验证) → concl(判据①–⑤汇总，§3 判定 GO/NO-GO)。
// 红线内建：R3 状态文件先于首写、R4 amp 仅记录不进判据、R7 异常即还原、信号→还原；写必须 root（读优先非 root）。
// 用法：
//   swift Tools/spike-ga-chie.swift preflight        # 只读前置检查（无需 root）
//   sudo swift Tools/spike-ga-chie.swift e0 [fresh]  # E0 基线+状态文件（已有残留状态文件时需 fresh 覆盖）
//   sudo swift Tools/spike-ga-chie.swift e1          # E1 CHIE 同值回写
//   sudo swift Tools/spike-ga-chie.swift e2          # E2 写 0x08 + 10min 观察窗（窗末 ladderRestore 已还原 00；异常未还原见日志 restore 行）
//   sudo swift Tools/spike-ga-chie.swift e3 [confirm]# E3 恢复写 00 + 三要素窗（CHIE 非 00/非 08 的不可解释态才需 confirm）
//   sudo swift Tools/spike-ga-chie.swift restore     # 还原+双验证
//   swift Tools/spike-ga-chie.swift concl            # 判据①–⑤ + GO/NO-GO（无需 root）

import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - 预注册常量（方案 §3 v3；改动即改实验设计——禁止）
private let stateFilePath = "/tmp/spike-ga-state-chie.json"
private let resultsFilePath = "/tmp/spike-ga-results-chie.json"
private let spikeKeys = ["CHTE", "CHIE"]              // E0 基线 + 还原键
private let bfProbeKeys = ["bfD0", "bfE0", "bfF0"]    // §3 判据①信息项：keyInfo 成档，不写不还原
private let chieDisable: [UInt8] = [0x08]             // §3 E2：适配器禁用（SMC-NOTES §7.5 实证 ext 翻转 + 回读一致）
private let chieEnable: [UInt8] = [0x00]              // §3 E3：恢复值（=基线原值）
private let e2StepS = 30.0                            // §3 E2：30s 采样
private let e2Points = 20                             // §3 E2：10 分钟窗 20 点
private let e2PointsExtended = 30                     // §3 判据②降级：AppleRawCurrentCapacity 不可得 → 15 分钟 30 点
private let rawDropThresholdMAh = 80.0                // §3 判据②：AppleRawCurrentCapacity 窗口净下降 ≥80 mAh
private let threeElementWindowS = 60                  // §3 E3：三要素窗 60s
private let preflightPct = 40...75                    // R1：S1 恒用 40–75 窗
private let tempAbortCentiC = 4000                    // 母本安全线：温度 ≥40℃ → 还原中止
private let verifyGraceS = 30                         // 还原后行为验证宽限（母本 P2-4）

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

// MARK: - SMCParam（80B 固定偏移手工封包，照 m0；dataType 还原为 4CC）
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
    var dataTypeRaw: UInt32 { Self.u32LE(buf, 32) }
    var dataType: String {   // dataType 尾随空格 trim 陷阱：比较一律用 trim 后 ==
        let v = dataTypeRaw
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
    static func pack(_ key: String) -> UInt32 {   // key 传输字节序 = 小端 uint32（缓冲内字符序反转）
        let b = Array(key.utf8)
        guard b.count == 4 else { return 0 }
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }
}

// MARK: - SMCConnection（m0 传输；内部锁串行化——信号线程与主流程并发调用）
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
    /// CHTE 零尺寸占位探测：§3 判据⑤ N/A 分支的依据。
    func zeroSizePlaceholder(_ key: String) -> Bool {
        guard let info = keyInfo(key) else { return false }
        return info.size == 0
    }
    func writeDetailed(_ key: String, bytes values: [UInt8]) -> (ok: Bool, kr: kern_return_t, result: UInt8) {
        let input = SMCParam()
        input.key = SMCParam.pack(key); input.data8 = cmdWrite
        input.dataSize = UInt32(values.count); input.setBytes(values)
        let (out, kr) = call(input)
        return (kr == KERN_SUCCESS && out.result == resultSuccess, kr, out.result)
    }
}

// MARK: - 电池遥测（进程内 IOKit 直读；含 AppleRawCurrentCapacity 判据②字段）
// GA 迁移实测（macOS 27.0 本机）：Temperature / AppleRawCurrentCapacity / DesignCapacity 已不在
// AppleSmartBattery 顶层——回退 AppleSmartBatteryPack → BatteryData 子层读取（§6 预注册映射的活体证据）。
private struct BatterySample {
    let percent: Int
    let isCharging: Bool
    let externalConnected: Bool
    let amperageMA: Int                 // R4：仅记录，不进判据
    let voltageMV: Int?
    let temperatureCentiC: Int?         // GA 层迁移：顶层缺失时取 Pack.BatteryData（仍不可得 = nil，温度安全线如实失效）
    let rawCurrentMAh: Int?             // AppleRawCurrentCapacity（不可得 → 判据②降级）
    let designCapacityMAh: Int?
    let timestamp: Date
    var temperatureC: Double? { temperatureCentiC.map { Double($0) / 100 } }
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
    private static func entryProps(_ name: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let props else { return nil }
        return props.takeRetainedValue() as? [String: Any]
    }
    func sample() -> BatterySample? {
        guard let dict = Self.entryProps("AppleSmartBattery") else { return nil }
        guard let percent = Self.intVal(dict["CurrentCapacity"]),
              let isCharging = Self.boolVal(dict["IsCharging"]),
              let external = Self.boolVal(dict["ExternalConnected"]),
              let amperage = Self.intVal(dict["Amperage"]) else { return nil }
        // Pack 层回退（GA：Temperature/AppleRawCurrentCapacity/DesignCapacity 常驻 Pack.BatteryData）
        var pack: [String: Any] = [:]
        if let packDict = Self.entryProps("AppleSmartBatteryPack"),
           let bd = packDict["BatteryData"] as? [String: Any] { pack = bd }
        let temp = Self.intVal(dict["Temperature"]) ?? Self.intVal(pack["Temperature"])
        let raw = Self.intVal(dict["AppleRawCurrentCapacity"]) ?? Self.intVal(pack["AppleRawCurrentCapacity"])
        let design = Self.intVal(dict["DesignCapacity"]) ?? Self.intVal(pack["DesignCapacity"])
        return BatterySample(percent: percent, isCharging: isCharging, externalConnected: external,
                             amperageMA: amperage, voltageMV: Self.intVal(dict["Voltage"]),
                             temperatureCentiC: temp, rawCurrentMAh: raw, designCapacityMAh: design,
                             timestamp: Date())
    }
}

// MARK: - 小工具
private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
private func tempS(_ c: Double) -> String { String(format: "%.1f", c) }
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
private func runPmset() -> String { runTool("/usr/bin/pmset", ["-g", "batt"]).out }
/// pmset 充电状态解析："83%; charging; ..." → "charging"（discharging 不含 "%; charging" 不会误判）。
private func pmsetChargingStatus() -> String? {
    for line in runPmset().components(separatedBy: "\n") {
        guard let r = line.range(of: "%; ") else { continue }
        let tail = line[r.upperBound...]
        if let end = tail.range(of: ";") { return String(tail[..<end.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return tail.trimmingCharacters(in: .whitespaces)
    }
    return nil
}
private func processRunning(_ name: String) -> Bool { runTool("/usr/bin/pgrep", ["-x", name]).code == 0 }
private func launchctlLoaded(_ label: String) -> Bool { runTool("/bin/launchctl", ["print", label]).code == 0 }
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

// MARK: - 机型/固件头（状态文件与日志）
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

// MARK: - Logger（线程安全；逐行 flush + stdout 双写，母本同款）
private final class Logger: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?
    private let df = DateFormatter()
    let path: String
    init() {
        let d = DateFormatter()
        d.dateFormat = "yyyyMMdd-HHmmss"
        path = "/tmp/spike-ga-chie-" + d.string(from: Date()) + ".log"
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

// MARK: - 状态与结果持久化（R3/P0-1：状态文件先于首写原子落盘；结果文件独立存活——restore 删状态不删结果）
private struct KeyStateEntry: Codable { let key: String; let size: Int; let type: String; let originalHex: String }
private struct StateFile: Codable {
    let version: Int
    let model: String
    let firmware: String
    let macOS: String
    let createdAt: String
    var written: [String]
    var keys: [String: KeyStateEntry]
}
private struct ResultsFile: Codable {
    var model: String = "?"
    var firmware: String = "?"
    var macOS: String = "?"
    var e0: [String: String] = [:]
    var e1: [String: String] = [:]
    var e2: [String: String] = [:]
    var e3: [String: String] = [:]
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
    /// 写步后登记 written 键（restore 依据；幂等）。已在锁内时走 Locked 版本防 NSLock 重入死锁。
    func markWritten(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        guard var state = loadStateLocked() else { return }
        if !state.written.contains(key) { state.written.append(key) }
        _ = writeStateLocked(state)
    }
    func loadState() -> StateFile? {
        lock.lock(); defer { lock.unlock() }
        return loadStateLocked()
    }
    private func loadStateLocked() -> StateFile? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: stateFilePath)) else { return nil }
        return try? JSONDecoder().decode(StateFile.self, from: data)
    }
    func deleteState() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(atPath: stateFilePath)
        logger.log("[R3] 状态文件已删除 \(stateFilePath)（还原双验证通过的干净结束判据）")
    }
    func loadResults() -> ResultsFile {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resultsFilePath)) else { return ResultsFile() }
        return (try? JSONDecoder().decode(ResultsFile.self, from: data)) ?? ResultsFile()
    }
    func updateResults(_ mutate: (inout ResultsFile) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var r = loadResultsLocked()
        mutate(&r)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(r) else { logger.log("[结果] 结果文件编码失败（判定汇总将缺料——如实记录）"); return }
        do { try data.write(to: URL(fileURLWithPath: resultsFilePath), options: .atomic) } catch { logger.log("[结果] 结果文件写入失败：\(error)") }
    }
    private func loadResultsLocked() -> ResultsFile {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resultsFilePath)) else { return ResultsFile() }
        return (try? JSONDecoder().decode(ResultsFile.self, from: data)) ?? ResultsFile()
    }
}

// MARK: - 防睡眠断言（母本 P1-6：观察窗全程持有 NoIdleSleep，等效 caffeinate -i）
private final class SleepGuardian: @unchecked Sendable {
    private var assertionID: IOPMAssertionID = 0
    private var held = false
    func acquire() -> Bool {
        let kr = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Cellar GA CHIE spike 观察窗（运行期间请勿合盖）" as CFString, &assertionID)
        held = kr == kIOReturnSuccess
        return held
    }
    func release() { if held { IOPMAssertionRelease(assertionID); held = false } }
}

// MARK: - Spike 主体
private final class ChieSpike: @unchecked Sendable {
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
    func run(_ cmd: String, _ rest: [String]) -> Int32 {
        logger.log("=== GA CHIE spike（S1）uid=\(getuid()) 机型=\(machine.model) 固件=\(machine.firmware) macOS=\(machine.macOS) 日志=\(logger.path) ===")
        switch cmd {
        case "preflight": return preflight()
        case "e0": return e0(fresh: rest.contains("fresh"))
        case "e1": return e1()
        case "e2": return e2()
        case "e3": return e3(confirm: rest.contains("confirm"))
        case "restore": return restoreStep()
        case "concl": return concl()
        default: printUsage(); return cmd == "help" || cmd == "--help" ? 0 : 2
        }
    }
    private func printUsage() {
        logger.log("""
        用法（SMC 读优先非 root；e1–e3 写必须 root——显式 sudo）:
          swift Tools/spike-ga-chie.swift preflight         # 只读前置检查
          sudo swift Tools/spike-ga-chie.swift e0 [fresh]   # E0 基线+状态文件
          sudo swift Tools/spike-ga-chie.swift e1           # E1 同值回写
          sudo swift Tools/spike-ga-chie.swift e2           # E2 写 0x08 + 10min 窗
          sudo swift Tools/spike-ga-chie.swift e3 [confirm] # E3 写 0x00 + 三要素窗
          sudo swift Tools/spike-ga-chie.swift restore      # 还原+双验证
          swift Tools/spike-ga-chie.swift concl             # 判据①–⑤汇总
        """)
    }
    private func requireRoot(_ step: String) -> Bool {
        guard getuid() == 0 else {
            logger.log("[权限] \(step) 写 SMC 需 root——请显式 sudo 执行（读路径优先非 root，写路径 0xE00002C1 NotPrivileged）")
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
    /// R7 信号安全网：任何写步期间收到 SIGINT/SIGTERM/SIGHUP → 还原 CHIE 后退出。
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
        logger.log("[中断] 收到信号 \(sig)——立即还原 CHIE（R7）")
        _ = ladderRestore(key: "CHIE")
        emitConclLine("interrupt", "signal-\(sig)-restored(还原结果见 restore 键记录)")
        exit(130)
    }
    private func emitConclLine(_ key: String, _ value: String) {
        logger.log("concl.chie.\(key)=\(value)")
    }
    // MARK: preflight（R2 双名 pgrep + launchctl 腿；R1 电量窗；R6 AC）
    private func preflight() -> Int32 {
        logger.log("=== preflight：R2 daemon 卸载检查（pgrep 双名 + launchctl）+ R1 电量窗 40–75 + R6 AC ===")
        var ok = true
        // §10.1 教训：进程名 com.cellar.daemon（安装态）vs cellar-daemon（SPM 构建名）双腿都要查
        if processRunning("com.cellar.daemon") {
            logger.log("[检查] daemon 卸载(pgrep com.cellar.daemon)=失败——进程仍在运行")
            ok = false
        } else { logger.log("[检查] daemon 卸载(pgrep com.cellar.daemon)=通过") }
        if processRunning("cellar-daemon") {
            logger.log("[检查] daemon 卸载(pgrep cellar-daemon)=失败——SPM 构建名进程仍在")
            ok = false
        } else { logger.log("[检查] daemon 卸载(pgrep cellar-daemon)=通过") }
        if launchctlLoaded("system/com.cellar.daemon") {
            logger.log("[检查] daemon 卸载(launchctl)=失败——服务仍注册：sudo launchctl bootout system/com.cellar.daemon")
            ok = false
        } else { logger.log("[检查] daemon 卸载(launchctl print)=通过") }
        if !ok {
            logger.log("[提示] S1 属 R2 备选适用面（通用页关闭编排开关）——但本工具门禁以完全卸载为准（最安全）；走备选请自行确认编排开关已关并在场监督")
        }
        guard let s = telemetry.sample() else {
            logger.log("[检查] 电池遥测=失败——遥测服务不可用")
            emitConclLine("preflight", "fail(telemetry-unavailable)")
            return 3
        }
        if s.externalConnected { logger.log("[检查] AC 已连接(R6)=通过") } else {
            logger.log("[检查] AC 已连接(R6)=失败——无 AC 时限充/放电动作无任何可观察输出，请插电")
            ok = false
        }
        if preflightPct.contains(s.percent) {
            logger.log("[检查] 电量 40–75%(R1)=通过 (\(s.percent)%)")
        } else {
            logger.log("[检查] 电量 40–75%(R1)=失败——当前 \(s.percent)%，请调整后重试")
            ok = false
        }
        logger.log("[信息] 温度=\(s.temperatureC.map(tempS) ?? "-")℃ amp=\(s.amperageMA)mA（R4：amp 仅记录）")
        emitConclLine("preflight", ok ? "pass" : "fail(见日志逐项)")
        logger.log(ok ? "preflight 结论：就绪" : "preflight 结论：未就绪——处置后重跑")
        return ok ? 0 : 3
    }
    // MARK: e0（§3 E0：键 keyInfo+基线 + bf 系探测 + ioreg 快照 + 状态文件）
    private func e0(fresh: Bool) -> Int32 {
        logger.log("=== E0：CHTE/CHIE keyInfo+基线 + bfD0/bfE0/bfF0 keyInfo 探测（判据①信息项）+ ioreg 快照 + 状态文件 ===")
        guard requireRoot("e0") else { return 2 }   // P3-3：防生成用户属主状态文件（与 e1–e3 写步同身份）
        if Store.stateExists() && !fresh {
            let old = store.loadState()
            logger.log("[E0] 残留状态文件存在（createdAt=\(old?.createdAt ?? "?")）——拒绝覆盖（R3；确认无在途实验请加参数 fresh）")
            emitConclLine("e0", "refused(state-file-exists)")
            return 3
        }
        guard let s = telemetry.sample() else { logger.log("[E0] 电池遥测不可用——中止"); return 3 }
        var keys: [String: KeyStateEntry] = [:]
        var e0r: [String: String] = [:]
        for k in spikeKeys {
            guard let info = smc.keyInfo(k), let r = smc.read(k) else {
                logger.log("[E0] \(k) keyInfo/读值不可读（getKeyInfo 132 语义）")
                e0r[k.lowercased()] = "absent"
                if k == "CHIE" {
                    logger.log("[E0] CHIE 不可读——判据① fail，实验无从进行")
                    emitConclLine("e0", "fail(CHIE-unreadable)")
                    return 3
                }
                continue
            }
            e0r[k.lowercased()] = "type=\(info.type) size=\(info.size) value=\(hex(r.bytes))"
            if k == "CHTE" { e0r["chte_original"] = hex(r.bytes) }   // P1-2：判据⑤活体对照用独立字段（复合串 last 分词取错）
            // P2-1：零尺寸占位键（GA 的 CHTE 预期形态）不入还原键集——空 hex 原值会让 restore 假 fail
            if info.size > 0 {
                keys[k] = KeyStateEntry(key: k, size: Int(info.size), type: info.type, originalHex: hex(r.bytes))
            } else {
                logger.log("[E0] \(k) 零尺寸占位——不入还原键集（方案 E0：不作为数值基线）")
            }
            logger.log("[E0] \(k)=在位 type=\(info.type) size=\(info.size) 原值=\(hex(r.bytes))")
        }
        // CHTE 零尺寸占位探测（§3 判据⑤ N/A 分支依据）
        if let info = smc.keyInfo("CHTE") {
            e0r["chte_placeholder"] = info.size == 0 ? "yes(零尺寸占位——读值无意义)" : "no"
            logger.log("[E0] CHTE 形态：\(info.size == 0 ? "零尺寸占位（GA 预期）——判据⑤记 N/A 不影响判定" : "常规键 size=\(info.size)")")
        }
        for k in bfProbeKeys {
            if let info = smc.keyInfo(k) {
                var line = "keyInfo type=\(info.type) size=\(info.size)"
                if info.size > 0, let r = smc.read(k) { line += " value=\(hex(r.bytes))" }
                e0r["bf.\(k.lowercased())"] = line
                logger.log("[E0] \(k)=\(line)（判据①信息项，喂 DEVICES.md 键世代表）")
            } else {
                e0r["bf.\(k.lowercased())"] = "absent(getKeyInfo 132)"
                logger.log("[E0] \(k)=不存在/不可读（信息项）")
            }
        }
        e0r["percent"] = "\(s.percent)"
        e0r["ext"] = s.externalConnected ? "true" : "false"
        e0r["isCharging"] = s.isCharging ? "true" : "false"
        e0r["amp"] = "\(s.amperageMA)"
        e0r["temp"] = s.temperatureC.map(tempS) ?? "n/a"
        e0r["pmset"] = pmsetChargingStatus() ?? "unparseable"
        if let raw = s.rawCurrentMAh {
            e0r["rawCurrentMAh"] = "\(raw)"
            e0r["rawAvailable"] = "true"
        } else {
            e0r["rawAvailable"] = "false"
            logger.log("[E0] AppleRawCurrentCapacity 不可得（GA 层迁移）——判据②降级：观察窗延至 15 分钟 + percent×DesignCapacity 折算")
        }
        if let dc = s.designCapacityMAh { e0r["designCapacityMAh"] = "\(dc)" }
        logger.log("[E0] ioreg 快照：percent=\(s.percent)% ext=\(s.externalConnected) isCharging=\(s.isCharging) amp=\(s.amperageMA)mA temp=\(s.temperatureC.map(tempS) ?? "-")℃ rawCurrent=\(s.rawCurrentMAh.map(String.init) ?? "不可得") design=\(s.designCapacityMAh.map(String.init) ?? "?")mAh pmset=\(e0r["pmset"]!)")
        e0r["done"] = "true"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let state = StateFile(version: 1, model: machine.model, firmware: machine.firmware, macOS: machine.macOS,
                              createdAt: df.string(from: Date()), written: [], keys: keys)
        guard store.writeState(state) else { logger.log("[E0] 状态文件写入失败（\(stateFilePath)）——拒绝（R3 先于首写）"); return 3 }
        logger.log("[E0] 状态文件已原子写入 \(stateFilePath)（\(keys.keys.sorted().joined(separator: ",")) 原值）")
        store.updateResults {
            $0.model = self.machine.model; $0.firmware = self.machine.firmware; $0.macOS = self.machine.macOS
            $0.e0 = e0r; $0.e1 = [:]; $0.e2 = [:]; $0.e3 = [:]
        }
        emitConclLine("e0", "done raw=\(e0r["rawAvailable"]!) bf=[\(bfProbeKeys.map { e0r["bf.\($0.lowercased())"]?.hasPrefix("keyInfo") == true ? $0 : "-" }.joined(separator: ","))]")
        return 0
    }
    // MARK: 统一写入口（5s 倒计时 + kr 记录 + 0.5s 后回读验证——判据④）
    /// forceWrite=true 时跳过「已是目标态」early-return（E1 同值回写必须发起真实写——母本 probeWrite 语义）。
    private func writeExpect(key: String, value: [UInt8], step: String, forceWrite: Bool = false) -> (ok: Bool, readback: String) {
        guard let cur = smc.read(key) else { logger.log("[\(step)] \(key) 当前值读取失败——中止"); return (false, "read-fail") }
        if cur.bytes == value && !forceWrite {
            logger.log("[\(step)] \(key) 已是目标态 \(hex(value))——无需写（no-op，未发起真实写；真实写证据见前置步骤记录）")
            return (true, hex(cur.bytes))
        }
        logger.log("[\(step)] \(key)：\(hex(cur.bytes)) → \(hex(value))")
        countdown(5, summary: "写 \(key)=\(hex(value))（\(step)）")
        let (ok, kr, result) = smc.writeDetailed(key, bytes: value)
        logger.log("SMC写 key=\(key) value=\(hex(value)) kr=\(String(format: "0x%08X", kr))(\(krExplain(kr))) result=\(result)(\(resultExplain(result)))")
        Thread.sleep(forTimeInterval: 0.5)
        guard ok, let back = smc.read(key) else {
            logger.log("[\(step)] \(key)=\(hex(value)) 写入(kr=\(String(format: "0x%08X", kr))/result=\(result))或回读失败——判据④违反（实际读回值=读失败）")
            return (false, "write-or-read-fail")
        }
        if back.bytes != value {
            logger.log("[\(step)] \(key)=\(hex(value)) 回读=\(hex(back.bytes)) ≠期望——判据④违反（实际读回值已记录）")
            return (false, hex(back.bytes))
        }
        logger.log("[\(step)] \(key)=\(hex(value)) 回读一致（判据④ ✓）")
        return (true, hex(back.bytes))
    }
    /// 阶梯还原（母本 9 轮：3 次→等 5s→再 3 轮）。true = 值级还原验证通过。
    private func ladderRestore(key: String) -> Bool {
        guard let state = store.loadState(), let entry = state.keys[key] else {
            logger.log("[还原] 无 \(key) 原始值记录（状态文件缺失）——无法还原")
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
        logger.log("[还原] \(key) 9 轮重试后仍无法还原到 \(entry.originalHex)——如实记录，不粉饰")
        return false
    }
    // MARK: e1（§3 E1：CHIE 同值回写——写通路）
    private func e1() -> Int32 {
        logger.log("=== E1：CHIE 同值回写（写通路；判据④素材）===")
        guard requireRoot("e1") else { return 2 }
        guard Store.stateExists() else { logger.log("[E1] 状态文件不存在——请先 sudo … e0（R3）"); return 3 }
        installSignalHandlers()
        guard let cur = smc.read("CHIE") else { logger.log("[E1] CHIE 读取失败——中止"); return 3 }
        // forceWrite：同值也必须发起真实写+回读验证（母本 probeWrite 语义——E1 是写通路实验，no-op 即无证据）
        let (ok, readback) = writeExpect(key: "CHIE", value: cur.bytes, step: "E1", forceWrite: true)
        store.markWritten("CHIE")   // R3：写已发生——restore 依据必须先于后续任何步骤登记
        let pass = ok && readback == hex(cur.bytes)
        store.updateResults {
            $0.e1["readback"] = "\(hex(cur.bytes))→\(readback)"
            $0.e1["pass"] = pass ? "true" : "false"
        }
        emitConclLine("e1", pass ? "pass(\(hex(cur.bytes))→\(readback))" : "fail(\(hex(cur.bytes))→\(readback))")
        if !pass {
            logger.log("[E1] 写通路失败——立即还原 CHIE（R7）")
            let restored = ladderRestore(key: "CHIE")
            store.updateResults { $0.restore["last"] = restored ? "restored-after-e1-fail" : "failed-after-e1-fail" }
            return 1
        }
        logger.log("[E1] 写通路可靠——可进入 e2")
        return 0
    }
    // MARK: e2（§3 E2：写 0x08 → 10min 窗 30s×20 点；raw 不可得降级 15min×30 点；R4 amp 仅记录）
    private func e2() -> Int32 {
        logger.log("=== E2：CHIE 写 0x08（适配器禁用）→ 观察窗（R4：amp 仅记录不进判据）===")
        guard requireRoot("e2") else { return 2 }
        guard Store.stateExists() else { logger.log("[E2] 状态文件不存在——请先 sudo … e0（R3）"); return 3 }
        guard let cur = smc.read("CHIE") else { logger.log("[E2] CHIE 读取失败——中止"); return 3 }
        if cur.bytes == chieDisable {
            logger.log("[E2] CHIE 已=08（上轮残留）——拒绝重复写入，请先 sudo … restore（R7）")
            emitConclLine("e2", "refused(already-08)")
            return 3
        }
        let results = store.loadResults()
        let rawAvailable = results.e0["rawAvailable"] == "true"
        let points = rawAvailable ? e2Points : e2PointsExtended
        let windowMin = rawAvailable ? 10 : 15
        logger.log("[E2] 判据②路径=\(rawAvailable ? "AppleRawCurrentCapacity 直读（10 分钟窗）" : "降级：N/A + 15 分钟窗（percent 折算候选）")（§3 判据②降级分支）")
        installSignalHandlers()
        guard guardian.acquire() else { logger.log("[E2] 防睡眠断言获取失败——中止"); return 3 }
        defer { guardian.release() }
        let (ok, readback) = writeExpect(key: "CHIE", value: chieDisable, step: "E2")
        store.markWritten("CHIE")   // R3：写已发生——登记 written（信号/异常还原与 restore 的依据）
        guard ok, readback == hex(chieDisable) else {
            logger.log("[E2] 写 08 写入/回读失败——立即还原（R7）")
            let restored = ladderRestore(key: "CHIE")
            store.updateResults {
                $0.e2["writeback"] = "08→\(readback)(violated)"
                $0.restore["last"] = restored ? "restored-after-e2-write-fail" : "failed-after-e2-write-fail"
            }
            emitConclLine("e2", "fail(write-readback \(readback))")
            return 1
        }
        var maxConsecExtFalse = 0, consec = 0
        var percents: [Int] = []
        var rawFirst: Int?, rawLast: Int?
        var tempMax = 0.0
        var chieResident = true
        var chteNotes: [String] = []
        var aborted = false
        var abortReason = ""
        let origCHTE = store.loadState()?.keys["CHTE"].map { $0.originalHex }
        for i in 0..<points {
            if i > 0 { Thread.sleep(forTimeInterval: e2StepS) }
            guard let s = telemetry.sample() else { logger.log("[E2] #\(i + 1)/\(points) 遥测不可用——跳过"); continue }
            percents.append(s.percent)
            rawFirst = rawFirst ?? s.rawCurrentMAh
            if s.rawCurrentMAh != nil { rawLast = s.rawCurrentMAh }
            if let tc = s.temperatureC { tempMax = max(tempMax, tc) }
            consec = s.externalConnected ? 0 : consec + 1
            maxConsecExtFalse = max(maxConsecExtFalse, consec)
            let chie = smc.read("CHIE").map { hex($0.bytes) } ?? "读失败"
            if chie != "08" { chieResident = false }
            var chteNote = "N/A"
            if let info = smc.keyInfo("CHTE") {
                if info.size == 0 { chteNote = "placeholder(零尺寸) 无变化" }   // §3 E2：恒零尺寸仅记录占位态无变化
                else if let r = smc.read("CHTE") {
                    // P2-1：e0 零尺寸占位键不在还原键集——此时无 e0 原值可对照，如实标注而非误报「无变化」
                    if let orig = origCHTE {
                        let changed = orig != hex(r.bytes)
                        chteNote = "\(hex(r.bytes))\(changed ? "（被固件清/改——记录）" : "（无变化）")"
                    } else {
                        chteNote = "\(hex(r.bytes))（e0 为零尺寸占位、无原值可对照）"
                    }
                }
            } else { chteNote = "keyInfo 不可读" }
            chteNotes.append(chteNote)
            logger.log("[E2] #\(i + 1)/\(points) ts=\(s.timestamp) percent=\(s.percent)% ext=\(s.externalConnected) isCharging=\(s.isCharging) amp=\(s.amperageMA)mA(R4 仅记录) temp=\(s.temperatureC.map(tempS) ?? "-")℃ raw=\(s.rawCurrentMAh.map(String.init) ?? "n/a") CHIE=\(chie) CHTE=\(chteNote)")
            // R1：S1 恒用 40–75 窗；跌出即终止还原（R7）
            var trip = ""
            if !preflightPct.contains(s.percent) { trip = "电量 \(s.percent)% 出 [40,75]（R1）" }
            if let tc = s.temperatureCentiC, tc >= tempAbortCentiC { trip += (trip.isEmpty ? "" : "；") + "温度 \(tempS(Double(tc) / 100))℃ 达 40℃" }
            if !trip.isEmpty {
                logger.log("[安全] 触发：\(trip)——还原并中止")
                aborted = true
                abortReason = trip
                break
            }
        }
        let restored = ladderRestore(key: "CHIE")
        store.updateResults {
            $0.e2["points"] = "\(percents.count)/\(points)"
            $0.e2["windowMin"] = "\(windowMin)"
            $0.e2["maxConsecExtFalse"] = "\(maxConsecExtFalse)"
            $0.e2["percentFirst"] = percents.first.map(String.init) ?? "n/a"
            $0.e2["percentLast"] = percents.last.map(String.init) ?? "n/a"
            $0.e2["percentMonotonic"] = Self.nonIncreasing(percents) ? "true" : "false"
            $0.e2["rawAvailable"] = rawAvailable ? "true" : "false"
            $0.e2["rawFirst"] = rawFirst.map(String.init) ?? "n/a"
            $0.e2["rawLast"] = rawLast.map(String.init) ?? "n/a"
            $0.e2["rawDeltaMAh"] = (rawFirst != nil && rawLast != nil) ? "\((rawLast! - rawFirst!))" : "n/a"
            $0.e2["chieResident"] = chieResident ? "true" : "false"
            $0.e2["chteObservation"] = chteNotes.joined(separator: " | ")
            $0.e2["tempMax"] = tempS(tempMax)
            $0.e2["aborted"] = aborted ? "true(\(abortReason))" : "false"
            $0.restore["last"] = restored ? "restored-after-e2-window" : "failed-after-e2-window"
        }
        emitConclLine("e2", "done points=\(percents.count)/\(points) maxConsecExtFalse=\(maxConsecExtFalse) rawDelta=\((rawFirst != nil && rawLast != nil) ? "\(rawLast! - rawFirst!)" : "n/a") CHIE驻留=\(chieResident ? "是" : "否") 还原=\(restored ? "verified" : "FAILED")")
        if aborted || !restored { return 1 }
        logger.log("[E2] 观察窗完成且 CHIE 已还原——三要素恢复语义在 e3 专步验证（§3 E3）")
        return 0
    }
    private static func nonIncreasing(_ xs: [Int]) -> Bool {
        guard xs.count >= 2 else { return xs.isEmpty }
        for i in 1..<xs.count where xs[i] > xs[i - 1] { return false }
        return true
    }
    // MARK: e3（§3 E3：写 0x00 → 三要素窗 60s：amp 转正 / isCharging=true / pmset charging）
    private func e3(confirm: Bool) -> Int32 {
        logger.log("=== E3：CHIE 写 0x00 恢复 → 三要素窗 \(threeElementWindowS)s（判据③测量窗）===")
        guard requireRoot("e3") else { return 2 }
        guard Store.stateExists() else { logger.log("[E3] 状态文件不存在——请先 sudo … e0（R3）"); return 3 }
        guard let cur = smc.read("CHIE") else { logger.log("[E3] CHIE 读取失败——中止"); return 3 }
        var alreadyEnabled = false
        if cur.bytes == chieEnable {
            // e2 窗末 ladderRestore 已还原——00 是正常序列态；恢复写为同值 no-op（判据④ 真实写证据在 e2）
            alreadyEnabled = true
            logger.log("[E3] CHIE 已=00（e2 窗末 ladderRestore 已还原——正常序列）——恢复写不发起（已是目标态未写，真实写证据见 e2 末尾 ladderRestore 与 e2 写读表）")
        } else if cur.bytes != chieDisable {
            if !confirm {
                logger.log("[E3] CHIE 当前=\(hex(cur.bytes))（非 08 非 00——状态不可解释）——确认继续请追加参数 confirm")
                emitConclLine("e3", "refused(unexpected-state)")
                return 3
            }
            logger.log("[E3] CHIE 当前=\(hex(cur.bytes))（confirm 已给）——继续恢复写 00")
        }
        installSignalHandlers()
        guard guardian.acquire() else { logger.log("[E3] 防睡眠断言获取失败——中止"); return 3 }
        defer { guardian.release() }
        let (ok, readback) = writeExpect(key: "CHIE", value: chieEnable, step: "E3")
        store.markWritten("CHIE")   // R3：写已发生——登记 written
        guard ok, readback == hex(chieEnable) else {
            logger.log("[E3] 恢复写 00 失败（回读=\(readback)）——阶梯还原（R7）")
            let restored = ladderRestore(key: "CHIE")
            store.updateResults {
                $0.e3["readback"] = "00→\(readback)(violated)"
                $0.restore["last"] = restored ? "restored-after-e3-write-fail" : "failed-after-e3-write-fail"
            }
            emitConclLine("e3", "fail(write-readback \(readback))")
            return 1
        }
        // 三要素窗：ext ∧ amp>0 ∧ isCharging ∧ pmset charging 在同一样本齐备（60s @2s；母本 §7.5 E3 镜像）
        var pass = false, elapsed = 0
        let deadline = Date().addingTimeInterval(TimeInterval(threeElementWindowS))
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 2); elapsed += 2
            guard let s = telemetry.sample() else { continue }
            let pmset = pmsetChargingStatus() ?? "?"
            logger.log("[E3窗] t+\(elapsed)s amp=\(s.amperageMA)mA ext=\(s.externalConnected) isCharging=\(s.isCharging) pmset=\(pmset)")
            if s.externalConnected && s.amperageMA > 0 && s.isCharging && pmset == "charging" {
                pass = true
                break
            }
        }
        store.updateResults {
            $0.e3["readback"] = alreadyEnabled ? "00→\(readback)(already-at-target-no-op)" : "00→\(readback)"
            $0.e3["threeElement"] = pass ? "pass(t+\(elapsed)s)" : "fail(60s 未齐)"
        }
        emitConclLine("e3", pass ? "pass(t+\(elapsed)s 齐备)" : "fail(三要素 60s 未齐)")
        logger.log("[E3] 三要素窗判定：\(pass ? "成立（判据③ ✓）" : "未成立（判负）")；pmset=\(runPmset().replacingOccurrences(of: "\n", with: " | "))")
        return pass ? 0 : 1
    }
    // MARK: restore（E4/E5：还原 + 双验证：值级回读==原值 + 行为恢复；通过删状态文件）
    private func restoreStep() -> Int32 {
        logger.log("=== restore：逐键还原 + 双验证（值级 + 行为级）===")
        guard requireRoot("restore") else { return 2 }
        guard let state = store.loadState() else { logger.log("无状态文件（\(stateFilePath)）——无需还原"); return 0 }
        logger.log("状态文件载入：createdAt=\(state.createdAt) written=[\(state.written.joined(separator: ","))] keys=[\(state.keys.keys.sorted().joined(separator: ","))]")
        installSignalHandlers()
        var valueOK = true
        for key in state.keys.keys.sorted() {
            guard let entry = state.keys[key] else { continue }
            guard parseHexBytes(entry.originalHex) != nil else { valueOK = false; continue }
            // 只还原实际写过的键；未写键仅核对现值==原值（避免无谓写）
            if state.written.contains(key) {
                if !ladderRestore(key: key) { valueOK = false }
            } else if let cur = smc.read(key), hex(cur.bytes) != entry.originalHex {
                logger.log("[还原] \(key) 未写但现值=\(hex(cur.bytes)) ≠原值 \(entry.originalHex)——如实记录")
                valueOK = false
            }
        }
        // 行为验证：ext ∧ isCharging ∧ pmset charging 在 \(verifyGraceS)s 宽限内齐备
        var behaviorOK = false
        let deadline = Date().addingTimeInterval(TimeInterval(verifyGraceS))
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 2)
            guard let s = telemetry.sample() else { continue }
            let pmset = pmsetChargingStatus() ?? "?"
            logger.log("[验证] ext=\(s.externalConnected) isCharging=\(s.isCharging) pmset=\(pmset)")
            if s.externalConnected && s.isCharging && pmset == "charging" { behaviorOK = true; break }
        }
        if !behaviorOK { logger.log("[验证] \(verifyGraceS)s 宽限内充电行为未恢复——如实记录（不粉饰）") }
        let verified = valueOK && behaviorOK
        store.updateResults {
            $0.restore["value"] = valueOK ? "verified" : "failed"
            $0.restore["behavior"] = behaviorOK ? "verified" : "failed"
            $0.restore["last"] = verified ? "verified" : (valueOK ? "failed-behavior" : "failed-value")
        }
        emitConclLine("restore.last", verified ? "verified" : (valueOK ? "failed-behavior" : "failed-value"))
        if verified {
            store.deleteState()
            logger.log("[检查单] 还原双验证通过——请经 App 面板 bootstrap 恢复 daemon 并以 cellar doctor 三方 PASS 收尾（R2）")
            return 0
        }
        logger.log("[检查单] 还原未完全通过：保留状态文件与日志，勿合盖，按方案 §3 兜底（重启；重启后 CHIE 残留 27 上未验证——如实记录）")
        return 1
    }
    // MARK: concl（§3 判据①–⑤ + GO/NO-GO；结果文件 + 活体终值复核）
    private func concl() -> Int32 {
        logger.log("=== concl：§3 判据①–⑤（结果文件 /tmp/spike-ga-results-chie.json + 活体复核）===")
        let r = store.loadResults()
        guard r.e0["done"] == "true" else {
            logger.log("结果文件缺 E0 记录——实验未执行或不完整，无法判定")
            emitConclLine("go", "no-go(结果文件缺 E0)")
            return 1
        }
        // ① CHIE 存在且 keyInfo 可读；bf 系三键 keyInfo 成档（信息项不影响判定）
        let chieRec = r.e0["chie"] ?? "absent"
        let c1 = chieRec.hasPrefix("type=")
        emitConclLine("criterion.1", c1 ? "pass(\(chieRec))" : "fail(CHIE 不可读)")
        for k in bfProbeKeys { emitConclLine("criterion.1.bf.\(k)", r.e0["bf.\(k.lowercased())"] ?? "未记录") }
        // ② ext=false 驻留 ≥2 连续采样 ∧ percent 单调不升 ∧ 容量净下降 ≥80 mAh（三路径）
        let e2 = r.e2
        let extOK = (Int(e2["maxConsecExtFalse"] ?? "0") ?? 0) >= 2
        let pctOK = e2["percentMonotonic"] == "true"
        var capacityPath = "n/a", capacityOK = false
        if e2["rawAvailable"] == "true", let d = Int(e2["rawDeltaMAh"] ?? ""), d <= -Int(rawDropThresholdMAh) {
            capacityPath = "raw(Δ=\(d)mAh ≤ -80)"; capacityOK = true
        } else if e2["rawAvailable"] == "true" {
            capacityPath = "raw(Δ=\(e2["rawDeltaMAh"] ?? "?")mAh 未达 -80)"
        } else if let dc = Int(r.e0["designCapacityMAh"] ?? ""),
                  let pf = Int(e2["percentFirst"] ?? ""), let pl = Int(e2["percentLast"] ?? "") {
            let converted = Double(pf - pl) * Double(dc) / 100.0
            if converted >= rawDropThresholdMAh { capacityPath = "converted(\(String(format: "%.0f", converted))mAh≥80)"; capacityOK = true }
            else { capacityPath = "converted(\(String(format: "%.0f", converted))mAh 未达 80)" }
        } else if e2["windowMin"] == "15" {
            capacityPath = "na(无 DesignCapacity——N/A + 窗延 15 分钟分支)"; capacityOK = true
        }
        let c2 = extOK && pctOK && capacityOK && e2["aborted"]?.hasPrefix("true") != true
        emitConclLine("criterion.2", "\(c2 ? "pass" : "fail") extDwell=\(extOK)(maxConsec=\(e2["maxConsecExtFalse"] ?? "?")) percentMonotonic=\(pctOK)(\(e2["percentFirst"] ?? "?")%→\(e2["percentLast"] ?? "?")%) capacity=\(capacityPath) aborted=\(e2["aborted"] ?? "?")")
        emitConclLine("criterion.2.chteObservation", e2["chteObservation"] ?? "未记录")
        // ③ E3 三要素窗
        let e3 = r.e3
        let c3 = e3["threeElement"]?.hasPrefix("pass") == true
        emitConclLine("criterion.3", c3 ? "pass(\(e3["threeElement"] ?? ""))" : "fail(\(e3["threeElement"] ?? "未执行"))")
        // ④ E1/E2/E3 回读与写入严格一致
        let e1OK = r.e1["pass"] == "true"
        let e2WriteOK = e2["chieResident"] == "true" && (r.e2["writeback"] ?? "").contains("violated") == false
        let e3WriteOK = e3["readback"]?.hasPrefix("00→00") == true
        let c4 = e1OK && e2WriteOK && e3WriteOK
        emitConclLine("criterion.4", "\(c4 ? "pass" : "fail") E1=\(r.e1["readback"] ?? "未执行") E2驻留=\(e2["chieResident"] ?? "?") E3=\(e3["readback"] ?? "未执行")")
        // ⑤ 终态无残留：CHIE=0x00 + pmset 正常充电；CHTE 零尺寸→N/A 不影响；可读→终值==E0 原值
        var chieFinal = "n/a(活体读失败)"
        if let cur = smc.read("CHIE") { chieFinal = hex(cur.bytes) }
        let pmsetStatus = pmsetChargingStatus() ?? "unparseable"
        let chieOK = chieFinal == "00"
        let pmsetOK = pmsetStatus == "charging" || pmsetStatus == "finishing charge"
        var chteOK = true
        var chteNote = ""
        if let info = smc.keyInfo("CHTE") {
            if info.size == 0 { chteNote = "N/A(零尺寸占位——不影响判定)" }
            else if let cur = smc.read("CHTE"), let orig = r.e0["chte_original"], !orig.isEmpty {
                chteOK = hex(cur.bytes) == orig
                chteNote = "终值=\(hex(cur.bytes)) 期望=\(orig) \(chteOK ? "一致" : "不一致")"
            } else { chteNote = "读失败或缺 e0 原值(如实记录)" }
        } else { chteNote = "keyInfo 不可读(如实记录)" }
        let c5 = chieOK && pmsetOK && chteOK
        emitConclLine("criterion.5", "\(c5 ? "pass" : "fail") CHIE终值=\(chieFinal) pmset=\(pmsetStatus) CHTE=\(chteNote)")
        emitConclLine("restore.last", r.restore["last"] ?? "未执行")
        // §3 判定：①–⑤ 全 pass = GO；② fail 且重开一轮仍 fail = 放电通道 NO-GO（人工最多重开一轮）；④ fail = 值语义变化，记录后重估
        let all = c1 && c2 && c3 && c4 && c5
        let verdict: String
        if all { verdict = "GO(0.20 放电后端复活——判据①–⑤ 全 pass)" }
        else if !c2 { verdict = "NO-GO-candidate(判据② fail——按 §3 可原样重开一轮，最多一轮)" }
        else if !c4 { verdict = "REASSESS(判据④ fail——值语义变化，记录后重估)" }
        else { verdict = "NO-GO(详见逐条判定)" }
        emitConclLine("go", all ? "GO" : verdict)
        logger.log("=== 判定汇总：\(verdict) ===")
        return all ? 0 : 1
    }
}

// MARK: - 主入口
private let arguments = Array(CommandLine.arguments.dropFirst())
private let command = arguments.first ?? "help"
private let logger0 = Logger()
private let machine0 = MachineInfo.gather()
private let store0 = Store(logger: logger0)
private let smc0 = SMCConnection()
guard let spike = ChieSpike(logger: logger0, machine: machine0, smc: smc0, store: store0) else { exit(1) }
exit(spike.run(command, Array(arguments.dropFirst())))
