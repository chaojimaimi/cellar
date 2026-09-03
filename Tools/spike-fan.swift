#!/usr/bin/env swift
// Cellar 风扇键写 spike（Phase 5 v1.1 WP0 前置 gate）— 规格 docs/plans/phase5-v1.1-fan-control.md §2 v1.2；唯一事实源 docs/SMC-NOTES.md
// 母本 Tools/spike-discharge.swift 安全规程全量沿用、不得收窄（母本头注 :15 同款）：P0-1 状态文件先于首次写原子落盘、
//   残留状态文件拒绝启动、--restore 逐键还原+手动兜底、信号(SIGINT/SIGTERM/SIGHUP)→全量还原、NoIdleSleep 全程断言、
//   每次写 5s 倒计时、预检门禁、全局看门狗、concl.* 机器可读、日志逐行 flush+每次写记 kr、abort 线立即还原。
// SMC 封装照抄母本 m0 体系（selector 2 + data8；读两阶段；写 cmd=6；4CC 类型还原带尾空格 trim 陷阱照 /tmp/fanprobe.swift）。
// 用法(canonical，root 只执行不构建；本脚本不在 SPM target 内——swiftc 单文件构建):
//   swiftc -O Tools/spike-fan.swift -o .build/debug/spike-fan       # user 侧构建
//   sudo .build/debug/spike-fan --do-it                             # E0–E6 全流程写实验(root;状态文件门禁)
//   sudo .build/debug/spike-fan --restore [KEY=HEX]                 # 按状态文件逐键还原 / 手动兜底
// 实验矩阵(§2.2 预注册，不现场改设计)：E0 基线(F0*/F1* 全键 keyInfo+原始hex+LE/BE 双序对照—U7 定版；60s@1s F0Ac 曲线；
//   电池温度基线；F0Tg/F0Md/F0Mn 原值入状态文件) / E1 F0Tg 同值回写(写通路) / E2 写 F0Tg=3350→60s@2s 三态判读
//   (固件拒绝/竞争态/直写候选) / E2b 负载态复验 90s@2s(用户双路 yes 负载+回车确认) / E3 Md 探索(同值回写→写0→观察15s→
//   非直写 go 时写1→观察→E2c 重测 3350) / E4 F0Mn=2000 写→30s 观察→还原(信息收集) / E5 全量还原+60s@2s 干净度窗 /
//   E6(仅 GO 预判成立) F0Tg 直写驻留+CHTE=01000000 停充→30s 双读→CHTE 还原双读验证 / 收尾 TC0P/Tp01 只读归档。
// 安全红线(母本全量沿用)：温度≥40℃或电量出[35,85]每采样点同查→全量还原；还原重试阶梯(3次→等5s→再3轮)；
//   看门狗全局硬超时 15min；残留状态文件拒绝启动；零品牌词（指代他工具一律「同类风扇控制工具」）。

import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - 预注册常量（方案 §2.2/§2.3 定版；改动即改实验设计——禁止）
private let stateFilePath = "/tmp/cellar-spike-fan-state.json"
private let tgWriteTarget: Float = 3350            // §2.2 E2：F0Tg 直写目标，(1350+5349)/2 取整
private let mnWriteTarget: Float = 2000            // §2.2 E4：F0Mn 抬升目标（U6 信息收集，v1.1 不实现策略②）
private let followAcFloorRPM: Double = 300         // §2.3 GO③ 路径 A：Ac ≥ 写入目标 −300rpm
private let baselineAcTolRPM: Double = 150         // §2.2 E5：F0Ac 回基线 ±150rpm
private let watchdogTimeoutS: TimeInterval = 900   // §2.1 工具项 2 只定机制（全局硬超时）；900s 为本工具预注册取值（建议 15 分钟）
private let concurrentRestoreWaitS: TimeInterval = 70 // P2-A：另一路还原有界等待上限（阶梯最坏时长 9 轮×~(写+0.5s 回读)+2×5s ≈16s，70s 为宽松硬界）
private let e0WindowS = 60, e0StepS = 1            // §2.2 E0：60s @1s F0Ac 静息曲线
private let e2WindowS = 60, e2StepS = 2            // §2.2 E2：60s @2s（T+30s 内漂移=竞争态判读点）
private let e2bWindowS = 90, e2bStepS = 2          // §2.2 E2b：90s @2s（负载态复验）
private let e3ObserveS = 15, e3StepS = 2           // §2.2 E3：写 0/写 1 后观察 15s
private let e2cWindowS = 60, e2cStepS = 2          // §2.2 E3/E2c：Md=1 态重测 F0Tg 直写 60s 驻留
private let e4WindowS = 30, e4StepS = 2            // §2.2 E4：30s @2s
private let e5WindowS = 60, e5StepS = 2            // §2.2 E5：60s @2s 干净度窗
private let e6WindowS = 30, e6StepS = 2            // §2.2 E6：30s 双读（F0Tg 与 CHTE）
private let mdAuto: UInt8 = 0                      // §2.2 E3 假说：F0Md 0=系统自动（U4 待验证）
private let mdManual: UInt8 = 1                    // §2.2 E3 假说：F0Md 1=手动/强制直写模式（解锁假设，U4）
private let chteStopCharging = [UInt8(1), 0, 0, 0] // §2.2 E6：CHTE 01000000=停充（4 字节，LE 打包键名字节序坑照母本）
private let chteEnable = [UInt8](repeating: 0, count: 4) // §2.2 E6：CHTE 00000000=使能
private let tempAbortCentiC = 4000                 // 母本安全线：温度 ≥40℃ → 全量还原（全量沿用不收窄）
private let chargeAbortPct = 35...85               // 母本安全线：电量出 [35,85] → 全量还原
private let preflightChargePct = 40...75           // 母本 P2-1：预检电量收紧 [40,75]
private let preflightTempCentiC = 3500             // 母本定版：预检温度 <35℃
private let rpmPlausibleRange = 1.0...60000.0      // §2.2 E0：U7 双序定版辅助判读域（仅推荐依据，非物理断言）

// MARK: - SMC 常量与错误码（照抄母本 m0）
private let selectorUniversal: UInt32 = 2
private let cmdRead: UInt8 = 5
private let cmdWrite: UInt8 = 6
private let cmdKeyInfo: UInt8 = 9
private let resultSuccess: UInt8 = 0
private let krExplainTable: [Int32: String] = [kIOReturnSuccess: "成功", Int32(bitPattern: 0xE00002C1): "NotPrivileged(写需root)", Int32(bitPattern: 0xE00002C7): "BadArgument(旧选择器已移除)"]
private func krExplain(_ kr: Int32) -> String { krExplainTable[kr] ?? "" }
private let resultExplainTable: [UInt8: String] = [0: "OK", 132: "KeyNotFound(隐藏/不存在)", 137: "尺寸不符(需两阶段读)"]
private func resultExplain(_ r: UInt8) -> String { resultExplainTable[r] ?? "" }

// MARK: - SMCParam（80B 固定偏移手工封包，照抄母本 m0；dataType 还原为 4CC）
private final class SMCParam {
    static let length = 80
    var buf = [UInt8](repeating: 0, count: SMCParam.length)
    private static func u32LE(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
    }
    private static func setU32LE(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        b[off] = UInt8(v & 0xFF); b[off + 1] = UInt8((v >> 8) & 0xFF); b[off + 2] = UInt8((v >> 16) & 0xFF); b[off + 3] = UInt8((v >> 24) & 0xFF)
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
    var bytes: [UInt8] { Array(buf[48..<(48 + Int(min(dataSize, 32)))]) }
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

// MARK: - SMCConnection（母本 m0 传输；内部锁串行化——信号/看门狗全局队列与主流程并发调用）
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
        var inCnt = SMCParam.length, outCnt = SMCParam.length   // 母本同款：outCnt 须为 var（inout 参数），static let 不可取址
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
    /// 两阶段读（macOS 26 必需）：先 getKeyInfo 取 dataSize 再带尺寸读；按请求尺寸切片。
    func read(_ key: String) -> (size: UInt32, type: String, bytes: [UInt8])? {
        guard let info = keyInfo(key) else { return nil }
        let input = SMCParam()
        input.key = SMCParam.pack(key); input.data8 = cmdRead; input.dataSize = info.size
        let (out, kr) = call(input)
        guard kr == KERN_SUCCESS, out.result == resultSuccess else { return nil }
        let n = Int(min(info.size, 32))
        return (info.size, info.type, Array(out.buf[48..<(48 + n)]))
    }
    /// 写；返回 ok + kr/result 原始码（母本 P2-2：每次写必记）。
    func writeDetailed(_ key: String, bytes values: [UInt8]) -> (ok: Bool, kr: kern_return_t, result: UInt8) {
        let input = SMCParam()
        input.key = SMCParam.pack(key); input.data8 = cmdWrite
        input.dataSize = UInt32(values.count); input.setBytes(values)
        let (out, kr) = call(input)
        return (kr == KERN_SUCCESS && out.result == resultSuccess, kr, out.result)
    }
}

// MARK: - 电池遥测（进程内 IOKit 直读 AppleSmartBattery；照母本遥测段——电池温度厘摄氏度）
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
    /// 采样：电量/充电态/温度（AppleSmartBattery Temperature = 厘摄氏度）。
    func sample() -> (percent: Int, isCharging: Bool, externalConnected: Bool, temperatureCentiC: Int)? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let props, let dict = props.takeRetainedValue() as? [String: Any] else { return nil }
        guard let percent = Self.intVal(dict["CurrentCapacity"]),
              let isCharging = Self.boolVal(dict["IsCharging"]),
              let external = Self.boolVal(dict["ExternalConnected"]),
              let temp = Self.intVal(dict["Temperature"]) else { return nil }
        return (percent, isCharging, external, temp)
    }
}

// MARK: - 小工具
private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
private func tempS(_ c: Double) -> String { String(format: "%.1f", c) }
private func fmtF(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "-" }
private func meanOf(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
/// SMC 'flt' 4B：IEEE754 单精度；LE/BE 双序解读（§2.2 E0 双序对照定版 U7——本机 fanprobe 的 LE 解读
/// 与母本 decodeFltBE 大端断言互斥，E0 定版前不得写死，故双序解读函数并列保留）。
private func decodeFlt(_ b: [UInt8], le: Bool) -> Double? {
    guard b.count == 4 else { return nil }
    let bits = le ? UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
                  : UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    return Double(Float(bitPattern: bits))
}
/// flt 打包（E2/E2c/E4 写目标按 U7 定版字节序）。
private func encodeFlt(_ v: Float, le: Bool) -> [UInt8] {
    let bits = v.bitPattern
    if le { return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24)] }
    return [UInt8(bits >> 24), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF)]
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
/// 4CC dataType 还原带尾空格 trim 陷阱（照 /tmp/fanprobe.swift：不加 trim 会把 "flt " 与 "flt" 当两种类型）。
private func typeTrimmed(_ type: String) -> String { type.trimmingCharacters(in: .whitespaces) }
private func runCmd(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
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
private func processRunning(_ name: String) -> Bool { runCmd("/usr/bin/pgrep", ["-x", name]).code == 0 }
/// launchctl print 失败即「已卸载」（预检门禁项，§2.1 运行前置）。
private func launchctlLoaded(_ label: String) -> Bool { runCmd("/bin/launchctl", ["print", label]).code == 0 }

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
                model = propString(dict["model"]) ?? "?"
                firmware = propString(dict["IOFirmwareVersion"]) ?? firmwareFromProfiler()   // AS 无此键：回退 system_profiler（母本同款）
            }
            IOObjectRelease(expert)
        }
        return MachineInfo(model: model, firmware: firmware,
                           macOS: runCmd("/usr/bin/sw_vers", ["-productVersion"]).out.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    /// 母本 propString 三型兼容（macOS 26 上 IOFirmwareVersion 为 String；Data/NSNumber 亦须兜底）。
    private static func propString(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let d = v as? Data { return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespaces) }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    private static func firmwareFromProfiler() -> String {
        for line in runCmd("/usr/sbin/system_profiler", ["SPHardwareDataType"]).out.components(separatedBy: "\n")
        where line.contains("System Firmware Version") {
            if let range = line.range(of: ": ") {
                let v = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
        return "?"
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
        d.dateFormat = "yyyyMMdd-HHmm"
        path = "/tmp/cellar-spike-fan-" + d.string(from: Date()) + ".log"
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

// MARK: - 状态持久化与会话（P0-1：先于首次写原子落盘；每次写步骤前更新 step 标记；残留拒绝启动）
private struct KeyStateEntry: Codable { let key: String; let size: Int; let type: String; let originalHex: String; let writtenAt: String }
private struct StateFile: Codable {
    let version: Int; let model: String; let firmware: String; let macOS: String
    let createdAt: String; let session: String; let step: String
    var keys: [String: KeyStateEntry]
}
private final class Session: @unchecked Sendable {
    private let lock = NSLock()
    let logger: Logger
    let machine: MachineInfo
    private let df = DateFormatter()
    var keys: [String: KeyStateEntry] = [:]
    var originals: [String: [UInt8]] = [:]
    private var stateFileCreatedAt = ""
    private var restoring = false
    private var abortReason: String?
    private var runbookEntered = false
    private var writeEvents: [(t: String, key: String, hex: String, ok: Bool, kr: String)] = []
    var readbackViolations: [String] = []
    var conclusions: [String: String] = [:]
    var restoreOutcomes: [String] = []
    init(logger: Logger, machine: MachineInfo) {
        self.logger = logger; self.machine = machine
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }
    static func stateExists() -> Bool { FileManager.default.fileExists(atPath: stateFilePath) }
    /// 锁通道写入（母本 :461-463 钉死：addBaseline 在信号/看门狗激活后仍可能被 E6 调用，与还原线程无锁写 Dictionary 是真实崩溃源）。
    func addBaseline(key: String, size: UInt32, type: String, bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        originals[key] = bytes
        keys[key] = KeyStateEntry(key: key, size: Int(size), type: type, originalHex: hex(bytes), writtenAt: "")
    }
    /// 原子写（.atomic = 临时文件+rename）；每次写步骤前调用更新 step 标记（P0-1）。
    func writeStateFile(step: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let ts = df.string(from: Date())
        if stateFileCreatedAt.isEmpty { stateFileCreatedAt = ts }
        let file = StateFile(version: 1, model: machine.model, firmware: machine.firmware, macOS: machine.macOS,
                             createdAt: ts, session: "cellar-spike-fan-" + ts, step: step,
                             keys: keys.mapValues { KeyStateEntry(key: $0.key, size: $0.size, type: $0.type, originalHex: $0.originalHex, writtenAt: stateFileCreatedAt) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return false }
        do { try data.write(to: URL(fileURLWithPath: stateFilePath), options: .atomic); return true } catch { return false }
    }
    func deleteStateFile() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(atPath: stateFilePath)
        stateFileCreatedAt = ""
        logger.log("[P0-1] 状态文件已删除 \(stateFilePath)（还原双验证通过的干净结束判据）")
    }
    func loadStateFile() -> (file: StateFile, sortedKeys: [String])? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: stateFilePath)),
              let file = try? JSONDecoder().decode(StateFile.self, from: data) else { return nil }
        lock.lock(); defer { lock.unlock() }
        for (k, e) in file.keys {
            originals[k] = parseHexBytes(e.originalHex)
            keys[k] = e
        }
        return (file, file.keys.keys.sorted())
    }
    func sortedKeys() -> [String] { lock.lock(); defer { lock.unlock() }; return keys.keys.sorted() }
    /// 锁通道读原值（信号/看门狗线程还原路径与主线程 E6 写入并发时安全）。
    func originalBytes(_ key: String) -> [UInt8]? { lock.lock(); defer { lock.unlock() }; return originals[key] }
    func conclusion(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return conclusions[key] }
    /// 看门狗计时入锁通道（Date 由主线程写、看门狗队列读，避免未同步访问）。
    private var watchdogSince = Date.distantPast
    func setWatchdogStart() { lock.lock(); defer { lock.unlock() }; watchdogSince = Date() }
    func watchdogAgeSeconds() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(watchdogSince) }
    /// 还原互斥入口（信号/看门狗/fullRestore/步内还原同走此门——三条还原路径统一）。
    func beginRestore() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !restoring else { return false }
        restoring = true
        return true
    }
    func endRestore() { lock.lock(); defer { lock.unlock() }; restoring = false }
    var isRestoring: Bool { lock.lock(); defer { lock.unlock() }; return restoring }
    func requestAbort(_ reason: String) { lock.lock(); defer { lock.unlock() }; if abortReason == nil { abortReason = reason } }
    func takeAbortReason() -> String? { lock.lock(); defer { lock.unlock() }; let r = abortReason; abortReason = nil; return r }
    func markRunbook() { lock.lock(); defer { lock.unlock() }; runbookEntered = true }
    var isRunbookEntered: Bool { lock.lock(); defer { lock.unlock() }; return runbookEntered }
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
    func recordReadbackViolation(_ msg: String) { lock.lock(); defer { lock.unlock() }; readbackViolations.append(msg) }
    func concl(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        conclusions[key] = value
        logger.log("concl.\(key)=\(value)")
    }
    func appendRestoreOutcome(_ s: String) { lock.lock(); defer { lock.unlock() }; restoreOutcomes.append(s) }
}

// MARK: - 防睡眠断言（母本 P1-6 全量沿用：全程持有 NoIdleSleep，等效 caffeinate -i）
private final class SleepGuardian: @unchecked Sendable {
    private var assertionID: IOPMAssertionID = 0
    private var held = false
    func acquire() -> Bool {
        let kr = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Cellar 风扇键调研会话（运行期间请勿合盖）" as CFString, &assertionID)
        held = kr == kIOReturnSuccess
        return held
    }
    func release() { if held { IOPMAssertionRelease(assertionID); held = false } }
}

// MARK: - 看门狗（母本模式：全局队列独立于主流程；本工具为全局硬超时——§2.1 工具项 2 建议 15 分钟）
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

// MARK: - 还原引擎（母本 P0-2：双验证 + 重试阶梯 3 次→等 5s→再 3 轮 + runbook 现场记录）
private final class RestoreEngine: @unchecked Sendable {
    private let smc: SMCConnection
    private let session: Session
    private let logger: Logger
    enum Outcome { case verified, failedValue([String: String]), alreadyRestoring }
    init(smc: SMCConnection, session: Session, logger: Logger) {
        self.smc = smc; self.session = session; self.logger = logger
    }
    /// 全量还原（信号/看门狗/abort/收尾/--restore 共用同一入口）：逐键值级阶梯 → 双验证 → 删状态文件。
    func fullRestore(reason: String) -> Outcome {
        guard session.beginRestore() else { return .alreadyRestoring }
        defer { session.endRestore() }
        logger.log("[还原] 开始全量还原 reason=\(reason) keys=[\(session.sortedKeys().joined(separator: ","))]")
        var valueFail: [String: String] = [:]
        for key in session.sortedKeys() {
            if let fail = restoreKeyWithLadder(key) { valueFail[key] = fail }
        }
        if !valueFail.isEmpty { runbook(valueFail: valueFail); return .failedValue(valueFail) }
        session.deleteStateFile()
        logger.log("[还原] 全部键值级回读==原值（双验证通过），状态文件已删除")
        return .verified
    }
    /// 步内还原出口分列（P2-A）：mutexBusy 不得宣称 runbook——另一路还原正在进行，非阶梯失败。
    enum LadderOutcome { case ok, mutexBusy, failed(String) }
    /// 单键值级阶梯还原（步内还原用：E3/E2c/E4/E6 写后回原值）；纳入还原互斥（照母本 e3Restore
    /// beginRestore 先例：信号/看门狗 fullRestore 与步内还原并发时互斥）。
    func restoreKeyLadder(_ key: String) -> LadderOutcome {
        guard session.beginRestore() else { return .mutexBusy }
        defer { session.endRestore() }
        if let fail = restoreKeyWithLadder(key) { runbook(valueFail: [key: fail]); return .failed(fail) }
        return .ok
    }
    /// 重试阶梯：3 次 → 等 5s → 再 3 轮（共 9 轮）。nil = 成功。
    private func restoreKeyWithLadder(_ key: String) -> String? {
        guard let original = session.originalBytes(key) else { return "无 \(key) 原始值记录" }
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
    private func runbook(valueFail: [String: String]) {
        session.markRunbook()
        logger.log("[runbook] 终态处置：形态=值级失败（回写报错/回读不一致）｜引导：保持电源连接、不要合盖、勿重启；手动兜底 sudo .build/debug/spike-fan --restore；仍失败则保留状态文件与日志交工程师分析｜键明细：\(valueFail)")
        logger.log("[现场] === 现场记录开始 ===")
        for key in session.sortedKeys() {
            logger.log("[现场] key=\(key) original=\(session.originalBytes(key).map(hex) ?? "?") current=\(smc.read(key).map { hex($0.bytes) } ?? "读失败")")
        }
        for e in session.recentWriteEvents(40) {
            logger.log("[现场] \(e.t) 写 \(e.key)=\(e.hex) ok=\(e.ok) kr=\(e.kr)")
        }
        logger.log("[现场] === 现场记录结束 ===")
        session.concl("reboot.clearState", "unknown(实验记录项，不得断言)")
    }
}

// MARK: - Runner（--do-it / --restore 两模式）
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
    // 判读现场由主线程独占（信号/看门狗只经 session 锁通道，不读这些）
    private var u7LE = false                     // U7 定版（E0 双序对照后用户定版；E2/E2c/E4 打包依赖）
    private var e0AcAllZero = false
    private var acLEsStored: [Double] = []
    private var acBEsStored: [Double] = []
    private var e0AcBaselineRPM: Double? = nil   // E0 曲线均值（u7 序；仅非恒 0 时有效，E5 干净度判据用）
    private var e0TempBase = 0.0
    private var e1Pass = false
    private enum E2Verdict { case firmwareRejected(String), contested(String), candidate }
    private var e2Verdict: E2Verdict = .firmwareRejected("未执行")
    private var e2bTgResident = false            // E2b 负载窗 Tg 驻留（直写候选路径）
    private var e2cTgResident = false            // E2c（Md=1）60s Tg 驻留（解锁路径）
    private var e2cAttempted = false
    private var followVerdict = "n/a(未执行)"
    private var u4mdDescription = "未执行"
    private var u6mnWrite = "skipped"
    private var f1KeyPresent: [String] = []
    init?() {
        logger = Logger()
        machine = MachineInfo.gather()
        guard let smc = SMCConnection() else { return nil }
        self.smc = smc
        session = Session(logger: logger, machine: machine)
        engine = RestoreEngine(smc: smc, session: session, logger: logger)
    }
    func run(_ args: [String]) -> Int32 {
        logger.log("=== 风扇键写 spike 会话 uid=\(getuid()) 机型=\(machine.model) 固件=\(machine.firmware) macOS=\(machine.macOS) 日志=\(logger.path) ===")
        if args.contains("--help") || args.contains("-h") { printUsage(); return 0 }
        if args.contains("--do-it") { return doIt() }
        if args.contains("--restore") {
            var manuals: [(key: String, bytes: [UInt8])] = []
            for a in args where a.contains("=") && !a.hasPrefix("--") {
                let parts = a.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parts[0].count == 4, let b = parseHexBytes(String(parts[1])) else { continue }
                manuals.append((String(parts[0]), b))
            }
            guard manuals.count <= 1 else { logger.log("--restore 手动兜底一次仅接受一个 KEY=HEX"); return 2 }
            return restore(manual: manuals.first)
        }
        printUsage()
        return 2
    }
    private func printUsage() {
        logger.log("""
        用法（canonical：user 侧构建 → sudo 只执行不构建。本脚本不在 SPM target 内——swiftc 单文件构建）:
          swiftc -O Tools/spike-fan.swift -o .build/debug/spike-fan    # user 侧构建
          sudo .build/debug/spike-fan --do-it                          # E0–E6 全流程写实验(root;状态文件门禁)
          sudo .build/debug/spike-fan --restore                        # 按状态文件逐键还原
          sudo .build/debug/spike-fan --restore F0Tg=44A89000          # 手动兜底(KEY=HEX)
        """)
    }
    private func countdown(_ seconds: Int, summary: String) {
        for i in stride(from: seconds, through: 1, by: -1) {
            logger.log("[倒计时] \(i)s 后执行：\(summary)（Ctrl-C 立即全量还原）")
            Thread.sleep(forTimeInterval: 1)
        }
    }
    /// 同值回写探针（母本 P1-4：写通路验证；失败整键退出）。
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
    /// 写结果分列（各阶段按规格判读——写入抛错=abort 线；回读不符=阶段级判读输出）。
    private enum WriteResult { case already, ok, writeFailed(String), readbackFailed, mismatch(String) }
    /// 统一写入口：写步骤前更新状态文件 step（P0-1）+ 5s 倒计时 + 写 + kr 记录 + 回读分列。
    @discardableResult
    private func writeKey(_ key: String, _ value: [UInt8], stepTag: String, skipCountdown: Bool = false) -> WriteResult {
        guard session.writeStateFile(step: stepTag) else {
            logger.log("状态文件更新失败（\(stateFilePath)）——拒绝写入（P0-1）")
            return .writeFailed("状态文件更新失败")
        }
        guard let cur = smc.read(key) else { return .readbackFailed }
        if cur.bytes == value { logger.log("[写] \(key) 已是目标态 \(hex(value))——无需写"); return .already }
        logger.log("[写] \(key)：\(hex(cur.bytes)) → \(hex(value))")
        if !skipCountdown { countdown(5, summary: "写 \(key)=\(hex(value))") }
        let (ok, kr, result) = smc.writeDetailed(key, bytes: value)
        session.recordWrite(key: key, bytes: value, ok: ok, kr: kr, result: result)
        Thread.sleep(forTimeInterval: 0.5)
        guard ok else { return .writeFailed(String(format: "0x%08X", kr)) }
        guard let back = smc.read(key) else { return .readbackFailed }
        if back.bytes != value {
            session.recordReadbackViolation("\(key) 写 \(hex(value)) 后回读=\(hex(back.bytes))（实际读回值=\(hex(back.bytes))）")
            return .mismatch(hex(back.bytes))
        }
        logger.log("[写] \(key)=\(hex(value)) 回读一致（判据④ ✓）")
        return .ok
    }
    /// 写入抛错 → 统一 abort 线（§2.2：写入抛错 → 立即 E5 还原并终止；调用方仍需自行判读 .mismatch）。
    private func writeOrAbort(_ key: String, _ value: [UInt8], stepTag: String, abortMsg: String) -> WriteResult {
        let r = writeKey(key, value, stepTag: stepTag)
        if case .writeFailed(let krs) = r { abortRun("\(abortMsg)（kr=\(krs)）") }
        if case .readbackFailed = r { abortRun("\(abortMsg)（回读失败）") }
        return r
    }
    /// 采样点安全线（母本全量沿用）：温度 ≥40℃ 或电量出 [35,85] → 全量还原并中止。
    private func checkSafety(_ s: (percent: Int, isCharging: Bool, externalConnected: Bool, temperatureCentiC: Int)) -> Bool {
        var trip = ""
        if s.temperatureCentiC >= tempAbortCentiC { trip = "温度 \(tempS(Double(s.temperatureCentiC) / 100))℃ 达 40℃ 阈值" }
        if !chargeAbortPct.contains(s.percent) { trip += (trip.isEmpty ? "" : "；") + "电量 \(s.percent)% 出 [35,85] 区间" }
        if !trip.isEmpty {
            logger.log("[安全] 触发阈值：\(trip)——全量还原并中止")
            let o = engine.fullRestore(reason: "安全阈值超限：" + trip)
            // P2-A：主线程被信号/看门狗还原抢占——不得 exit 杀死进行中的还原；有界等待其完成后再退出
            if case .alreadyRestoring = o {
                logger.log("[安全] 另一路（信号/看门狗）还原进行中——有界等待其完成（上限 \(Int(concurrentRestoreWaitS))s）后退出")
                _ = waitForConcurrentRestore()
            }
            reportRestoreOutcome(o)
            finalExit(130, note: "安全阈值超限", brief: true)
        }
        return trip.isEmpty
    }
    private func finalExit(_ code: Int32, note: String, brief: Bool) -> Never {
        if brief { emitBriefConclusions(note) }
        logger.log("=== 会话中止：\(note)（退出码 \(code)）===")
        guardian.release()
        exit(code)
    }
    private func reportRestoreOutcome(_ o: RestoreEngine.Outcome) {
        switch o {
        case .verified: session.concl("restore.last", "verified")
        case .alreadyRestoring: logger.log("[还原] 另一路还原进行中，跳过")
        case .failedValue(let fail): session.concl("restore.last", "failed-value"); logger.log("[还原] 值级失败 keys=\(fail)")
        }
    }
    // MARK: 信号安全网 + 看门狗（母本 DispatchSourceSignal 模式；采样循环不被阻塞）
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
        let o = engine.fullRestore(reason: reason)
        // P2-A：竞态窗口内被主线程还原抢占（alreadyRestoring）——不得退出（exit 会杀死进行中的还原），
        // 登记延迟中止请求，还原完成后主流程在 takeAbortReason 出口处理（母本延迟语义）。
        if case .alreadyRestoring = o {
            logger.log("[中断] 全量还原被主线程还原抢占（alreadyRestoring）——登记中止请求，由进行中的还原完成后退出")
            session.requestAbort(reason)
            return
        }
        reportRestoreOutcome(o)
        finalExit(130, note: reason, brief: true)
    }
    /// 看门狗 tick（全局队列）：会话写入阶段全局硬超时（§2.1 工具项 2；900s 预注册值）→ 全量还原。
    private func watchdogTick() {
        let age = session.watchdogAgeSeconds()   // 锁通道读取（主线程 setWatchdogStart 并发安全）
        guard age > watchdogTimeoutS else { return }
        if session.isRestoring {
            logger.log("[看门狗] 会话 \(Int(age))s 超 15min 硬超时，但还原进行中——交由进行中的还原完成")
            return
        }
        logger.log("[看门狗] 会话 \(Int(age))s 超 15min 硬超时（§2.1 全局看门狗）——触发全量还原（abort 线）")
        let o = engine.fullRestore(reason: "看门狗 15min 全局硬超时")
        // P2-A：竞态窗口内被主线程还原抢占——不得退出，登记延迟中止
        if case .alreadyRestoring = o {
            logger.log("[看门狗] 全量还原被主线程还原抢占（alreadyRestoring）——登记中止请求，由进行中的还原完成后退出")
            session.requestAbort("看门狗 15min 硬超时（还原进行中，延迟处理）")
            return
        }
        reportRestoreOutcome(o)
        finalExit(131, note: "看门狗 15min 硬超时", brief: true)
    }
    // MARK: 预检门禁（§2.1 工具项 9：root / daemon 双检测卸载 / 键可读 / 残留拒绝 / 电量温度母本口径）
    private func runPreflight(strict: Bool) -> Bool {
        var ok = true
        let fail = { (check: String) in self.logger.log("[检查] \(check)=失败"); ok = false }
        if getuid() == 0 { logger.log("[检查] root 身份=通过") } else { fail("root 身份"); logger.log("[检查]     请用 sudo 执行（写 SMC 需 root）") }
        if launchctlLoaded("system/com.cellar.daemon") {
            fail("daemon 已卸载(launchctl)")
            logger.log("[检查]     launchctl print system/com.cellar.daemon 仍成功——请先 sudo launchctl bootout system/com.cellar.daemon（§2.1 运行前置）")
        } else { logger.log("[检查] daemon 已卸载(launchctl print 失败)=通过") }
        if processRunning("cellar-daemon") {
            fail("daemon 已卸载(pgrep)")
            logger.log("[检查]     cellar-daemon 进程仍在——请先卸载 daemon（§2.1 运行前置：排除 CHTE 执法写入对 E6 干扰）")
        } else { logger.log("[检查] daemon 已卸载(pgrep 无进程)=通过") }
        if smc.read("FNum") != nil { logger.log("[检查] FNum 可读=通过") } else { fail("FNum 可读") }
        if smc.read("F0Tg") != nil && smc.read("F0Md") != nil && smc.read("F0Mn") != nil {
            logger.log("[检查] F0 键组(F0Tg/F0Md/F0Mn)可读=通过")
        } else { fail("F0 键组可读") }
        if smc.read("CHTE") != nil {
            logger.log("[检查] CHTE 可读=通过（E6 交互键——开场即知，勿让 E0-E5 白跑）")
        } else { fail("CHTE 可读"); logger.log("[检查]     CHTE 不可读——E6 无法执行（记 E6=skipped 依据）") }
        if let s = telemetry.sample() {
            if preflightChargePct.contains(s.percent) { logger.log("[检查] 电量 40-75%=通过 (\(s.percent)%)") }
            else { fail("电量 40-75%"); logger.log("[检查]     电量 \(s.percent)% 请调整后重试（母本 P2-1 口径全量沿用）") }
            if s.temperatureCentiC < preflightTempCentiC { logger.log("[检查] 温度<35℃=通过 (\(tempS(Double(s.temperatureCentiC) / 100))℃)") }
            else { fail("温度<35℃"); logger.log("[检查]     温度 \(tempS(Double(s.temperatureCentiC) / 100))℃") }
        } else { fail("电池遥测"); logger.log("[检查]     遥测服务不可用") }
        if Session.stateExists() {
            fail("状态文件门禁")
            logger.log("[检查]     存在未清理状态文件 \(stateFilePath)——请先 sudo .build/debug/spike-fan --restore")
        } else { logger.log("[检查] 状态文件门禁=通过（无残留）") }
        if strict && !ok { logger.log("[检查] 前置检查未通过，拒绝进入写实验") }
        return ok
    }
    // MARK: 采样（E1+ 使用；按 U7 定版序解码；E0 期间 u7 未定，E0 用自带双序采样）
    private struct FanSample {
        let tempCentiC: Int, percent: Int
        let acHex: String?, acRPM: Double?
        let tgHex: String?, mdRaw: UInt8?
        let mnHex: String?, mnRPM: Double?
        let chteHex: String?
    }
    private func decodeRPM(_ r: (size: UInt32, type: String, bytes: [UInt8])) -> Double? {
        let t = typeTrimmed(r.type)   // 4CC 尾空格 trim（照 /tmp/fanprobe.swift）
        if t == "flt" { return decodeFlt(r.bytes, le: u7LE) }
        if t == "ui16" {
            guard r.bytes.count >= 2 else { return nil }
            return Double(UInt16(r.bytes[0]) << 8 | UInt16(r.bytes[1]))
        }
        if t == "ui8" { return r.bytes.first.map(Double.init) }
        return nil
    }
    private func fanSample() -> FanSample? {
        guard let t = telemetry.sample() else { return nil }
        let ac = smc.read("F0Ac"), tg = smc.read("F0Tg"), md = smc.read("F0Md")
        let mn = smc.read("F0Mn"), chte = smc.read("CHTE")
        return FanSample(tempCentiC: t.temperatureCentiC, percent: t.percent,
                         acHex: ac.map { hex($0.bytes) }, acRPM: ac.flatMap { decodeRPM($0) },
                         tgHex: tg.map { hex($0.bytes) }, mdRaw: md?.bytes.first,
                         mnHex: mn.map { hex($0.bytes) }, mnRPM: mn.flatMap { decodeRPM($0) },
                         chteHex: chte.map { hex($0.bytes) })
    }
    /// 统一观察窗（预注册时长/间隔）：逐点采样+全量落盘+安全线；返回样本序列供阶段判读。
    private func observe(seconds: Int, stepS: Int, tag: String) -> [FanSample] {
        var out: [FanSample] = []
        let n = (seconds + stepS - 1) / stepS
        for i in 0..<n {
            if i > 0 { Thread.sleep(forTimeInterval: TimeInterval(stepS)) }
            guard let s = fanSample(), let t = telemetry.sample(), checkSafety(t) else {
                logger.log("[\(tag)] #\(i + 1)/\(n) 采样失败——跳过"); continue
            }
            out.append(s)
            logger.log("[\(tag)] #\(i + 1)/\(n) ac=\(fmtF(s.acRPM))rpm tg=\(s.tgHex ?? "读失败") md=\(s.mdRaw.map { String(format: "%02X", $0) } ?? "读失败") mn=\(fmtF(s.mnRPM))rpm chte=\(s.chteHex ?? "读失败") temp=\(tempS(Double(s.tempCentiC) / 100))℃ percent=\(s.percent)%")
        }
        return out
    }
    // MARK: E0 基线（§2.2：全键 keyInfo+原始hex+LE/BE 双序对照·U7 定版；60s@1s Ac 曲线；电池温度基线）
    private func e0Baseline() -> Bool {
        logger.log("=== E0：基线（§2.2）F0*/F1* 全键 keyInfo + 原始 hex + LE/BE 双序对照（U7 定版）；60s@1s F0Ac 曲线；电池温度基线 ===")
        for suffix in ["0", "1"] {
            for name in ["Ac", "Mn", "Mx", "Tg", "Md"] {
                let key = "F\(suffix)\(name)"
                if let info = smc.keyInfo(key), let r = smc.read(key) {
                    if suffix == "1" { f1KeyPresent.append(key) }
                    if typeTrimmed(info.type) == "flt" {
                        logger.log("e0.\(key)=在位 type='\(info.type)' hex=\(hex(r.bytes)) LE=\(fmtF(decodeFlt(r.bytes, le: true))) BE=\(fmtF(decodeFlt(r.bytes, le: false)))（U7 双序对照）")
                    } else {
                        logger.log("e0.\(key)=在位 type='\(info.type)' hex=\(hex(r.bytes)) raw=\(r.bytes.first ?? 0)")
                    }
                } else { logger.log("e0.\(key)=不存在/不可读（U5 在位性回填）") }
            }
        }
        // 60s @1s F0Ac 静息曲线 + 电池温度基线（u7 未定：LE/BE 双序列都采，定版后取对应序）
        var temps: [Int] = []
        for i in 0..<e0WindowS {
            if i > 0 { Thread.sleep(forTimeInterval: TimeInterval(e0StepS)) }
            guard let t = telemetry.sample() else { logger.log("[E0] #\(i + 1)/\(e0WindowS) 遥测不可用——不计"); continue }
            guard checkSafety(t) else { return false }
            temps.append(t.temperatureCentiC)
            var acLine = "读失败", leS = "-", beS = "-"
            if let ac = smc.read("F0Ac"), typeTrimmed(ac.type) == "flt" {
                let le = decodeFlt(ac.bytes, le: true), be = decodeFlt(ac.bytes, le: false)
                acLine = hex(ac.bytes); leS = fmtF(le); beS = fmtF(be)
                if let le, le != 0 { acLEsStored.append(le) }
                if let be, be != 0 { acBEsStored.append(be) }
            }
            logger.log("[E0 Ac曲线] #\(i + 1)/\(e0WindowS) ac=\(acLine) LE=\(leS) BE=\(beS) temp=\(tempS(Double(t.temperatureCentiC) / 100))℃ percent=\(t.percent)%")
        }
        e0AcAllZero = acLEsStored.isEmpty && acBEsStored.isEmpty
        e0TempBase = temps.isEmpty ? 0 : Double(temps.reduce(0, +)) / Double(temps.count) / 100
        logger.log("[E0] 60s 曲线完成：AC 非零读数 LE 均值=\(fmtF(meanOf(acLEsStored))) BE 均值=\(fmtF(meanOf(acBEsStored))) 恒 0=\(e0AcAllZero)；温度基线=\(tempS(e0TempBase))℃")
        return true
    }
    /// U7 定版（§2.2 E0）：双序对照打印后由用户现场判读输入；回车采纳推荐（推荐依据：转速键双序解读
    /// 落在 rpm 合理域的序；本机历史 fanprobe 为 LE 解读，与母本 BE 断言互斥——必须本次定版）。
    private func settleU7ByteOrder() -> Bool {
        var recLE = true
        var seen = 0, leOK = 0, beOK = 0
        for key in ["F0Ac", "F0Mn", "F0Mx", "F0Tg", "F1Ac", "F1Mn", "F1Mx"] {
            guard let r = smc.read(key), typeTrimmed(r.type) == "flt", let le = decodeFlt(r.bytes, le: true),
                  let be = decodeFlt(r.bytes, le: false), le.isFinite, be.isFinite else { continue }
            seen += 1
            if rpmPlausibleRange.contains(le) { leOK += 1 }
            if rpmPlausibleRange.contains(be) { beOK += 1 }
        }
        var recText = "LE（默认，本机 fanprobe 历史输出 1350rpm 为 LE 解读）"
        if seen == 0 { /* 无 flt 键可判——保持默认 */ }
        else if beOK > leOK { recLE = false; recText = "BE（按 SMC 惯例，母本 decodeFltBE 同款）" }
        if leOK > 0 && beOK == 0 { recLE = true; recText = "LE（唯一落在合理域）" }
        if beOK > 0 && leOK == 0 { recLE = false; recText = "BE（唯一落在合理域）" }
        logger.log("[U7] 双序对照统计：flt 键 n=\(seen)（LE 合理=\(leOK) BE 合理=\(beOK)）；推荐：\(recText)")
        logger.log("[U7] 请输入定版字节序（LE 或 BE，回车=采纳推荐 [\(recLE ? "LE" : "BE")]）：")
        // P2-3：首个空输入即采纳推荐并跳出（消除「按两次回车」歧义）；仅非空非法输入做一次重试提示
        var choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if choice.isEmpty {
            choice = recLE ? "le" : "be"
        } else if choice != "le" && choice != "be" {
            logger.log("[U7] 输入无效（\(choice)）——回车采纳推荐 [\(recLE ? "LE" : "BE")]")
            let again = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if again == "le" || again == "be" { choice = again }
            else if again.isEmpty { choice = recLE ? "le" : "be" }
            else {
                logger.log("[U7] 再次无效——拒绝进入写实验（U7 定版必须人工确认）")
                return false
            }
        }
        u7LE = choice == "le"
        if !e0AcAllZero { e0AcBaselineRPM = u7LE ? meanOf(acLEsStored) : meanOf(acBEsStored) }
        logger.log("[U7] 定版：\(u7LE ? "LE" : "BE")（E2/E2c/E4 写目标打包依此序；E5 干净度窗基线依此序）")
        return true
    }
    // MARK: E1（§2.2：F0Tg 同值回写——写通路验证，不动键值）
    private func e1WriteProbe() -> Bool {
        logger.log("=== E1（§2.2）：F0Tg 同值回写探针（写通路验证；kr=0 ∧ 回读一致）===")
        countdown(5, summary: "E1 F0Tg 同值回写探针（写原值 → 回读验证）")
        let pass = probeWrite(key: "F0Tg")
        session.concl("e1.run", pass ? "pass" : "fail")
        if !pass { session.concl("stop.reason", "E1 写通路失败（同值回写 kr≠0 或回读不一致）") }
        return pass
    }
    // MARK: E2（§2.2：写 F0Tg=3350 → 60s@2s 三态判读：固件拒绝/竞争态/直写候选）
    private func e2DirectWrite() -> E2Verdict {
        logger.log("=== E2（§2.2）：直写实验（Md 原值态）写 F0Tg=3350 → 60s@2s 观察 ===")
        // keyInfo 先在 guard 外取：失败臂不得引用 guard 绑定（编译要求）
        let tgInfo = smc.keyInfo("F0Tg")
        guard let info = tgInfo, typeTrimmed(info.type) == "flt", info.size == 4 else {
            logger.log("[E2] F0Tg 类型/尺寸不符（type='\(tgInfo?.type ?? "?")' size=\(tgInfo?.size ?? 0)，需 flt/4B）——fail-visible，不做值格式猜测")
            session.concl("e2.run", "firmwareRejected(F0Tg 格式不符)")
            return .firmwareRejected("F0Tg 非 flt/4B，直写不可行")
        }
        let tgBytes = encodeFlt(tgWriteTarget, le: u7LE)
        // 写后约 0.5s 内回读不符 → 固件拒绝/clamp（判读分列第一态，§2.2 三态之一，不可用）
        if case .mismatch(let hv) = writeOrAbort("F0Tg", tgBytes, stepTag: "E2", abortMsg: "E2 写 F0Tg=3350 写入抛错") {
            logger.log("[E2] 写后 1s 内回读=\(hv)≠\(hex(tgBytes))——固件拒绝/clamp")
            session.concl("e2.run", "firmwareRejected(回读=\(hv))")
            _ = guardRestored(engine.restoreKeyLadder("F0Tg"), context: "E2 固件拒绝后还原 F0Tg")
            return .firmwareRejected("写后回读=\(hv)，固件拒绝/clamp")
        }
        let samples = observe(seconds: e2WindowS, stepS: e2StepS, tag: "E2")
        if let idx = samples.firstIndex(where: { $0.tgHex != hex(tgBytes) }) {
            let drift = samples[idx]
            // 漂移时刻 = idx * e2StepS（idx=0 为写后即时；P3-3：不得 +1 高报 2s，该值进 SMC-NOTES 回填）
            logger.log("[E2] 写后 T+\(idx * e2StepS)s 漂移：Tg 回读=\(drift.tgHex ?? "读失败") ≠目标 \(hex(tgBytes))——竞争态")
            session.concl("e2.run", "contested(漂移@T+\(idx * e2StepS)s 回读=\(drift.tgHex ?? "?"))")
            return .contested("T+\(idx * e2StepS)s 被覆写，回读=\(drift.tgHex ?? "?")")
        }
        session.concl("e2.run", "candidate(60s 驻留)")
        logger.log("[E2] 60s 全程驻留——直写候选（判读分列第三态）")
        return .candidate
    }
    // MARK: E2b（§2.2：负载态复验 90s@2s；用户双路 yes 负载 + 回车确认；GO③ 主判据来源）
    private func e2bLoadTest() {
        logger.log("=== E2b（§2.2）：负载态复验（仅 E2 直写候选时执行）===")
        logger.log("[E2b] 请用户在另一终端开启可控 CPU 负载（例：两路 yes > /dev/null &）；负载就绪后按回车确认，开始 \(e2bWindowS)s@\(e2bStepS)s 负载态观察（覆写时延 / F0Ac 是否开始更新 / 温度走向）（等待输入的时间计入 15 分钟硬超时，看门狗不暂停）……")
        _ = readLine()
        let tgBytes = encodeFlt(tgWriteTarget, le: u7LE)
        let samples = observe(seconds: e2bWindowS, stepS: e2bStepS, tag: "E2b")
        e2bTgResident = !samples.contains { $0.tgHex != hex(tgBytes) }
        let acVals = samples.compactMap { $0.acRPM }
        let acMax = acVals.max()
        let acAnyNonZero = acVals.contains { $0 > 0 }   // 路径 B 前置（§2.3）：仅「Ac 恒 0」允许旁证
        let tempDelta = samples.first.map { (Double(samples.last!.tempCentiC) - Double($0.tempCentiC)) / 100 }
        logger.log("[E2b] 观察结束——请用户停掉负载（kill %1 %2，实验继续）")
        logger.log("[E2b] 判读原料：Tg 驻留=\(e2bTgResident) acMax=\(fmtF(acMax))rpm acAnyNonZero=\(acAnyNonZero) 温度走向=\(tempDelta.map { String(format: "%+.1f", $0) } ?? "-")℃")
        session.concl("e2b.run", e2bTgResident ? "tg-resident" : "contested(负载窗 Tg 被覆写)")
        if !e2bTgResident {
            followVerdict = "fail(负载 90s 窗 Tg 被覆写——竞争态，§2.3 一律 NO-GO)"
        } else if let acMax, acMax >= Double(tgWriteTarget) - followAcFloorRPM {
            followVerdict = "pass(负载态 F0Ac 更新且 ≥ 目标−300rpm——§2.3 GO③ 路径 A)"
            session.concl("e2b.run", "follow-pathA(acMax=\(String(format: "%.0f", acMax))rpm)")
        } else if acAnyNonZero {
            // §2.3 预注册：路径 B 仅限「Ac 恒 0 时」——Ac 有更新但未达目标−300rpm 不得放宽判旁证，直接 fail（原始读数已逐点落盘供 v1.x 评估）
            followVerdict = "fail(Ac 有更新读数但未达目标−300rpm（max=\(fmtF(acMax))rpm）——§2.3 路径 B 前置不满足，判 fail)"
            session.concl("e2b.run", "ac-below-pathA-floor(max=\(fmtF(acMax))rpm)")
        } else {
            logger.log("[旁证] F0Ac 恒 0/不可读——§2.3 GO③ 路径 B 复合旁证需人工判读：① 听音是否起转？② 温度走势是否回落/增速放缓？③ Tg 驻留=\(e2bTgResident)？（等待输入的时间计入 15 分钟硬超时，看门狗不暂停）")
            logger.log("[旁证] 三项成立请输入 y（确认后判 pass；SMC-NOTES §8 标定后路径 B 方可作运行时降级证据）:")
            if readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "y" {
                followVerdict = "pass(负载态复合旁证：听音起转+温度回落/平缓+Tg 驻留——路径 B，待 SMC-NOTES §8 标定)"
                session.concl("e2b.run", "follow-pathB(人工旁证确认)")
            } else {
                followVerdict = "fail(无任何跟随证据——Ac 死且复合旁证未确认，§2.3 NO-GO)"
            }
        }
        session.concl("e2b.tempDelta", tempDelta.map { String(format: "%.1f", $0) } ?? "-")
    }
    // MARK: E3（§2.2：Md 探索——同值回写→写 0→观察 15s；非直写 go 时写 1→观察→E2c）
    private func e3MdExplore(needUnlock: Bool) {
        logger.log("=== E3（§2.2）：Md 探索（解锁假设 U4）===")
        let mdInfoO = smc.keyInfo("F0Md")
        guard let mdInfo = mdInfoO, mdInfo.size == 1 else {
            u4mdDescription = "F0Md 尺寸 \(mdInfoO?.size ?? 0)B ≠1B，未探索"
            return
        }
        // P2-1：同值回写探针照母本逐写规程补 5s 倒计时（probeWrite 不经 writeKey 倒计时路径，不得收窄）
        countdown(5, summary: "E3 F0Md 同值回写探针（写原值 → 回读验证）")
        guard probeWrite(key: "F0Md") else {
            u4mdDescription = "Md 同值回写失败（写不可用）"
            return
        }
        if case .mismatch(let hv) = writeOrAbort("F0Md", [mdAuto], stepTag: "E3-md0", abortMsg: "E3 写 F0Md=0 写入抛错") {
            logger.log("[E3] 写 0 后回读=\(hv)——Md 写 0 被固件拒绝（U4 记录）")
            u4mdDescription = "Md 写0 被固件拒绝(回读=\(hv))"
            _ = guardRestored(engine.restoreKeyLadder("F0Md"), context: "E3 写 0 拒绝后还原 F0Md")
            return
        }
        // 窗内 Tg 变化检测（而非「≠原值」）：E2 写入的 3350 在 E3 期间仍驻留属预期，接管证据 = 窗内 Tg 出现变化值。
        // 注（P3-B）：接管先于首样本发生或读失败时判据失效（窗内仅 1 个有效样本时 Set.count 无变化信息量），原始 hex 已逐点落盘供人工复核。
        let md0TakenOver = Set(observe(seconds: e3ObserveS, stepS: e3StepS, tag: "E3-md0").compactMap { $0.tgHex }).count > 1
        logger.log("[E3] Md=0 观察 15s：Tg 窗内被改写=\(md0TakenOver)（U4：0=系统自动的假设证据）")
        if !needUnlock {
            u4mdDescription = "Md0：Tg 接管=\(md0TakenOver ? "是" : "否")；E2 直写候选，未探索 Md=1"
        } else {
            if case .mismatch(let hv) = writeOrAbort("F0Md", [mdManual], stepTag: "E3-md1", abortMsg: "E3 写 F0Md=1 写入抛错") {
                logger.log("[E3] 写 1 后回读=\(hv)——Md 写 1 被固件拒绝（U4 记录）")
                u4mdDescription = "Md0：接管=\(md0TakenOver ? "是" : "否")；Md1：被固件拒绝(回读=\(hv))"
                _ = guardRestored(engine.restoreKeyLadder("F0Md"), context: "E3 写 1 拒绝后还原 F0Md")
                return
            }
            let md1TgResident = Set(observe(seconds: e3ObserveS, stepS: e3StepS, tag: "E3-md1").compactMap { $0.tgHex }).count == 1   // 同 P3-B：样本不足/读失败时判据失效，原始 hex 已逐点落盘供人工复核
            logger.log("[E3] Md=1 观察 15s：Tg 窗内驻留=\(md1TgResident)（U4：1=手动直写模式的假设证据）")
            e2cAttempted = true
            // E2c 前置格式门（照 E4 模式 fail-visible）：F0Tg 非 flt/4B 则跳过并按 u4 记录
            let tgInfoC = smc.keyInfo("F0Tg")
            guard let tgInfoC, typeTrimmed(tgInfoC.type) == "flt", tgInfoC.size == 4 else {
                logger.log("[E2c] F0Tg 类型/尺寸不符（type='\(tgInfoC?.type ?? "?")' size=\(tgInfoC?.size ?? 0)，需 flt/4B）——E2c 跳过（fail-visible，u4 记录）")
                followVerdict = "fail(E2c 未执行：F0Tg 非 flt/4B)"
                session.concl("e2c.run", "skipped(F0Tg 格式不符)")
                u4mdDescription = "Md0：接管=\(md0TakenOver ? "是" : "否")；Md1：驻留=\(md1TgResident ? "是" : "否")；E2c：跳过(F0Tg 格式不符)"
                _ = guardRestored(engine.restoreKeyLadder("F0Md"), context: "E3 还原 F0Md")
                return
            }
            let tgBytes = encodeFlt(tgWriteTarget, le: u7LE)
            if case .mismatch(let hv) = writeOrAbort("F0Tg", tgBytes, stepTag: "E2c", abortMsg: "E2c 写 F0Tg=3350（Md=1 态）写入抛错") {
                logger.log("[E2c] Md=1 态写 3350 后回读=\(hv)——固件拒绝（Md 全值域不可直写方向）")
                e2cTgResident = false
                followVerdict = "fail(Md=1 态直写被固件拒绝，回读=\(hv))"
                session.concl("e2c.run", "firmwareRejected(回读=\(hv))")
                _ = guardRestored(engine.restoreKeyLadder("F0Tg"), context: "E2c 固件拒绝后还原 F0Tg")
                u4mdDescription = "Md0：接管=\(md0TakenOver ? "是" : "否")；Md1：驻留=\(md1TgResident ? "是" : "否")；E2c 固件拒绝=是"
                _ = guardRestored(engine.restoreKeyLadder("F0Md"), context: "E3 还原 F0Md")
                return
            }
            let s2 = observe(seconds: e2cWindowS, stepS: e2cStepS, tag: "E2c")
            e2cTgResident = !s2.contains { $0.tgHex != hex(tgBytes) }
            let acVals2 = s2.compactMap { $0.acRPM }
            let acMax2 = acVals2.max()
            let acAnyNonZero2 = acVals2.contains { $0 > 0 }   // 路径 B 前置（§2.3）：仅「Ac 恒 0」允许旁证
            logger.log("[E2c] Md=1 态 60s 驻留=\(e2cTgResident) acMax=\(fmtF(acMax2))rpm acAnyNonZero=\(acAnyNonZero2)")
            session.concl("e2c.run", e2cTgResident ? "resident" : "contested(60s 窗 Tg 被覆写)")
            if e2cTgResident, let acMax2, acMax2 >= Double(tgWriteTarget) - followAcFloorRPM {
                followVerdict = "pass(E2c Md=1 直写 60s 驻留且 F0Ac 更新 ≥ 目标−300rpm——§2.3 GO③)"
            } else if e2cTgResident && acAnyNonZero2 {
                // §2.3 预注册：路径 B 仅限「Ac 恒 0 时」——Ac 有更新但未达目标不得放宽判旁证（原始读数已逐点落盘）
                followVerdict = "fail(E2c 驻留但 Ac 有更新读数未达目标−300rpm（max=\(fmtF(acMax2))rpm）——§2.3 路径 B 前置不满足，判 fail)"
                session.concl("e2c.run", "ac-below-pathA-floor(max=\(fmtF(acMax2))rpm)")
            } else if e2cTgResident {
                logger.log("[旁证] E2c 直写驻留但 F0Ac 恒 0/不可读——路径 B 复合旁证（听音起转 + 温度回落 + Tg 驻留）成立请输入 y（等待输入的时间计入 15 分钟硬超时，看门狗不暂停）:")
                if readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "y" {
                    followVerdict = "pass(E2c 直写驻留 + 人工复合旁证——路径 B，待 SMC-NOTES §8 标定)"
                } else {
                    followVerdict = "fail(E2c 驻留但无跟随证据——Ac 死且旁证未确认，§2.3 NO-GO)"
                }
            } else {
                followVerdict = "fail(E2c Md=1 态 Tg 仍被覆写——竞争态，§2.3 一律 NO-GO)"
            }
            u4mdDescription = "Md0：接管=\(md0TakenOver ? "是" : "否")；Md1：驻留=\(md1TgResident ? "是" : "否")；E2c 60s驻留=\(e2cTgResident ? "是" : "否")"
            _ = guardRestored(engine.restoreKeyLadder("F0Tg"), context: "E2c 后还原 F0Tg")
        }
        _ = guardRestored(engine.restoreKeyLadder("F0Md"), context: "E3 还原 F0Md")
        session.appendRestoreOutcome("E3/E2c=Md/Tg 还原验证通过")
        session.concl("u4.md_semantics_detail", u4mdDescription)
    }
    // MARK: E4（§2.2：Mn 抬升——信息收集；写 2000 → 30s@2s → 还原）
    private func e4MnRaise() {
        logger.log("=== E4（§2.2）：Mn 抬升实验（U6 信息收集，v1.1 不实现策略②）===")
        guard let info = smc.keyInfo("F0Mn"), typeTrimmed(info.type) == "flt", info.size == 4 else {
            u6mnWrite = "fail(格式不符)"
            return
        }
        let mnBytes = encodeFlt(mnWriteTarget, le: u7LE)
        if case .mismatch(let hv) = writeOrAbort("F0Mn", mnBytes, stepTag: "E4", abortMsg: "E4 写 F0Mn=2000 写入抛错") {
            u6mnWrite = "fail(回读=\(hv)，Mn 不可写)"
            logger.log("[E4] 写 2000 后回读=\(hv)——Mn 不可写（U6 记录）")
            _ = guardRestored(engine.restoreKeyLadder("F0Mn"), context: "E4 还原 F0Mn")
            return
        }
        u6mnWrite = "pass"
        let s = observe(seconds: e4WindowS, stepS: e4StepS, tag: "E4")
        let mnResident = !s.contains { $0.mnHex != hex(mnBytes) }
        let acMax = s.compactMap { $0.acRPM }.max()
        logger.log("[E4] 30s 窗：Mn 回读驻留=\(mnResident) acMax=\(fmtF(acMax))rpm temp 走向=\(s.first.map { String(format: "%+.1f", (Double(s.last!.tempCentiC) - Double($0.tempCentiC)) / 100) } ?? "-")℃")
        session.concl("u6.mn_detail", "30s 窗 Mn 驻留=\(mnResident) acMax=\(fmtF(acMax))rpm")
        _ = guardRestored(engine.restoreKeyLadder("F0Mn"), context: "E4 还原 F0Mn")
        session.appendRestoreOutcome("E4=Mn 还原验证通过")
    }
    // MARK: E6（§2.2：仅 GO 预判成立时——Tg 直写驻留 + CHTE 停充 30s 双读 → CHTE 还原双读验证）
    private func e6Interaction() {
        logger.log("=== E6（§2.2）：交互矩阵——F0Tg 直写驻留 + CHTE=01000000 停充 → 30s 双读 → CHTE 还原 ===")
        // CHTE 将入还原键集：写前把原值记入状态文件（状态文件 = 全部还原步的唯一依据，§2.1 风扇增补）
        if let chte = smc.read("CHTE"), let info = smc.keyInfo("CHTE") {
            session.addBaseline(key: "CHTE", size: info.size, type: info.type, bytes: chte.bytes)
            logger.log("[E6] CHTE 原值入状态文件=\(hex(chte.bytes))（若为 00000000 则与 §2.2 协议预期一致）")
        } else {
            logger.log("[E6] CHTE 不可读——E6 跳过")
            session.concl("e6.run", "skipped(CHTE 不可读)")
            return
        }
        let tgBytes = encodeFlt(tgWriteTarget, le: u7LE)
        if case .mismatch(let hv) = writeOrAbort("F0Tg", tgBytes, stepTag: "E6-tg", abortMsg: "E6 写 F0Tg=3350 失败") {
            session.recordReadbackViolation("E6 Tg 写后回读=\(hv)≠目标")
        }
        if case .mismatch(let hv) = writeOrAbort("CHTE", chteStopCharging, stepTag: "E6-chte", abortMsg: "E6 写 CHTE=01000000 失败") {
            logger.log("[E6] CHTE 写 01000000 后回读=\(hv)——写入被拒/被改（记录）")
            session.recordReadbackViolation("E6 CHTE 写后回读=\(hv)≠01000000")
        }
        let s = observe(seconds: e6WindowS, stepS: e6StepS, tag: "E6")
        let tgResident = !s.contains { $0.tgHex != hex(tgBytes) }
        let chteResident = s.allSatisfy { $0.chteHex == "01000000" }
        logger.log("[E6] 30s 双读：F0Tg 驻留=\(tgResident) CHTE 全窗驻留=\(chteResident)（充电控制与风扇控制不同键域互不干扰背书）")
        session.concl("e6.run", "tg=\(tgResident ? "resident" : "drifted") chte=\(chteResident ? "resident" : "drifted")")
        _ = guardRestored(engine.restoreKeyLadder("CHTE"), context: "E6 还原 CHTE")
        // 还原双读验证（§2.2：CHTE 还原双读验证——以状态文件原值为准；预检保证 daemon 卸载语境下原值=00000000）
        let expectedHex = session.originalBytes("CHTE").map(hex) ?? hex(chteEnable)
        let backHex = smc.read("CHTE").map { hex($0.bytes) } ?? "读失败"
        logger.log("[E6] CHTE 还原回读=\(backHex)（期望 \(expectedHex)）——\(backHex == expectedHex ? "双读验证通过" : "双读验证失败（runbook 现场已记录）")")
        if backHex != expectedHex { session.recordReadbackViolation("E6 CHTE 还原后回读=\(backHex)≠\(expectedHex)") }
        session.appendRestoreOutcome("E6=CHTE 还原双读验证" + (backHex == expectedHex ? "通过" : "失败"))
    }
    // MARK: E5（§2.2：全量还原 + 60s@2s 干净度窗；GO④ 测量）
    private func e5FinalRestore() -> (verified: Bool, clean: Bool, note: String) {
        logger.log("=== E5（§2.2）：全量还原 + 60s@2s 干净度窗（F0Ac 回基线 ±150rpm 或停写后 F0Tg 系统接管证据）===")
        let o = engine.fullRestore(reason: "会话正常收尾（E5）")
        reportRestoreOutcome(o)
        let verified = {
            if case .verified = o { return true }
            return false
        }()
        if !verified { return (false, false, "还原值级失败（runbook 已记录）") }
        let tgOrigHex = session.originalBytes("F0Tg").map(hex) ?? "?"
        let samples = observe(seconds: e5WindowS, stepS: e5StepS, tag: "E5窗")
        let tgDrifted = samples.contains { $0.tgHex != tgOrigHex }
        var clean = false, note = ""
        if !e0AcAllZero, let base = e0AcBaselineRPM {
            let acOK = samples.allSatisfy { ($0.acRPM ?? 0) <= base + baselineAcTolRPM && ($0.acRPM ?? 0) >= base - baselineAcTolRPM }
            if acOK {
                clean = true
                note = "F0Ac 全程在基线 \(String(format: "%.0f", base))±\(Int(baselineAcTolRPM))rpm 内（§2.2 E5 判据）"
            } else if tgDrifted {
                clean = true
                note = "F0Ac 出基线但 Tg 被系统接管改写（停写后系统接管证据，U3 机制成立）"
            } else {
                clean = false
                note = "F0Ac 出基线且 Tg 未变——不可解释态（runbook 记录）"
                session.recordReadbackViolation("E5 干净度窗：Ac 偏离基线且无 Tg 接管证据")
            }
        } else {
            clean = true
            note = "Ac 恒 0 机型：干净度判据降级——Tg \(tgDrifted ? "被系统接管（接管证据）" : "全程驻留原值（无残留）")"
        }
        logger.log("[E5] 干净度窗判定：\(clean ? "pass" : "fail")——\(note)")
        session.concl("e5.detail", note)
        return (verified, clean, note)
    }
    /// 收尾（§2.2 阶段表末行）：TC0P/Tp01 只读读值归档（仅信息用，不构成 v1.1 依赖）。
    private func archiveTempKeys() {
        logger.log("=== 收尾归档：TC0P/Tp01 只读读值（§1.1 表补全，仅信息用）===")
        for key in ["TC0P", "Tp01"] {
            if let r = smc.read(key) {
                if typeTrimmed(r.type) == "flt" {
                    logger.log("archive.\(key)=在位 type='\(r.type)' hex=\(hex(r.bytes)) LE=\(fmtF(decodeFlt(r.bytes, le: true))) BE=\(fmtF(decodeFlt(r.bytes, le: false)))（U7 定版序=\(fmtF(decodeFlt(r.bytes, le: u7LE)))）")
                } else {
                    logger.log("archive.\(key)=在位 type='\(r.type)' hex=\(hex(r.bytes)) raw=\(r.bytes.first ?? 0)")
                }
            } else { logger.log("archive.\(key)=不存在/不可读") }
        }
    }
    // MARK: abort 线（§2.2：回读不一致且无法还原/写入抛错/看门狗 → 立即 E5 还原并终止）
    /// 主线程有界等待另一路（信号/看门狗）还原完成：轮询 isRestoring 间隔 1s，上限 concurrentRestoreWaitS
    /// （70s = 阶梯最坏时长 9 轮×~(写+0.5s 回读)+2×5s ≈16s，70s 为宽松硬界）。返回 true=等待内完成
    /// （状态文件由该路径删除）；false=超时（超时即异常，退出时保留状态文件，--restore 兜底）。
    private func waitForConcurrentRestore() -> Bool {
        let deadline = Date().addingTimeInterval(concurrentRestoreWaitS)
        while session.isRestoring && Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
        }
        return !session.isRestoring
    }
    /// 步内还原统一出口（P2-A）：.ok 继续；.mutexBusy（互斥被占）不得宣称 runbook——有界等待后交 abortRun；
    /// .failed 阶梯真失败（runbook 已由引擎记录）→ abortRun。
    private func guardRestored(_ outcome: RestoreEngine.LadderOutcome, context: String) -> Bool {
        switch outcome {
        case .ok: return true
        case .mutexBusy:
            logger.log("[还原] \(context)：还原互斥被占（另一路还原进行中）——有界等待其完成（上限 \(Int(concurrentRestoreWaitS))s）后终止")
            _ = waitForConcurrentRestore()
            abortRun("\(context)（另一路还原接管）")   // Never：调用后不可达（编译识别）
        case .failed(let fail):
            abortRun("\(context)（阶梯还原失败，runbook 已记录：\(fail)）")   // Never：调用后不可达
        }
    }
    private func abortRun(_ reason: String) -> Never {
        logger.log("[abort] \(reason)——abort 线：立即 E5 全量还原并终止（§2.2）")
        let o = engine.fullRestore(reason: reason)
        // P2-A：主线程被信号/看门狗还原抢占——有界等待其完成（还原由该路径完成，状态文件由该路径删除）后再退出
        if case .alreadyRestoring = o {
            logger.log("[abort] 另一路还原进行中——有界等待其完成（上限 \(Int(concurrentRestoreWaitS))s）后退出")
            _ = waitForConcurrentRestore()
        }
        reportRestoreOutcome(o)
        watchdog?.stop()
        finalExit(130, note: reason, brief: true)
    }
    // MARK: 判读汇总（§2.3 GO 判定）
    /// E2/E2c 任一观察窗出现 Tg 被覆写 → 竞争态（§0.5c/§2.3：一律 NO-GO）。
    private func anyContestedWindow() -> Bool {
        switch e2Verdict {
        case .contested: return true
        case .candidate: return !e2bTgResident
        case .firmwareRejected: return e2cAttempted && !e2cTgResident
        }
    }
    /// GO②直写生效：E2（+E2b 负载窗）或 E2c 的写后即时回读一致 ∧ 全观察窗 Tg 不被覆写。
    private func computeDirectWriteOK() -> Bool {
        switch e2Verdict {
        case .candidate: return e2bTgResident
        case .firmwareRejected, .contested: return e2cAttempted && e2cTgResident
        }
    }
    /// GO 预判（①②③）——E6 门控；④E5 在收尾窗测量后并入终判。
    private func goGatePassed() -> Bool {
        let directOK = computeDirectWriteOK()
        let followOK = followVerdict.hasPrefix("pass")
        let g = e1Pass && directOK && followOK
        logger.log("[GO 预判] ①E1=\(e1Pass) ②直写生效=\(directOK) ③跟随=\(followOK) → E6 \(g ? "执行" : "跳过")（§2.3 GO①②③；④E5 收尾窗测量）")
        return g
    }
    private func e2VerdictText() -> String {
        switch e2Verdict {
        case .firmwareRejected(let d): return "firmwareRejected(\(d))"
        case .contested(let d): return "contested(\(d))"
        case .candidate: return "candidate(60s 驻留)"
        }
    }
    private func emitConclusions(stopReason: String, e5: (verified: Bool, clean: Bool, note: String)) {
        logger.log("=== concl.* 结论（key=value 机器可读）===")
        session.concl("u1_writepath", e1Pass ? "pass" : "fail")
        session.concl("u2_follow", followVerdict)
        let u3 = e5.verified && e5.clean ? "pass" : "fail"
        session.concl("u3_restore", u3)
        session.concl("u4_md_semantics", u4mdDescription)
        session.concl("u5_f1_keys", f1KeyPresent.isEmpty ? "none" : f1KeyPresent.joined(separator: ","))
        session.concl("u6_mn_write", u6mnWrite)
        session.concl("u7_byteorder", u7LE ? "LE" : "BE")
        // GO 判定（§2.3 四条件；竞争态一律 NO-GO——§0.5c）
        let directOK = computeDirectWriteOK()
        let followOK = followVerdict.hasPrefix("pass")
        let contested = anyContestedWindow()
        let go = e1Pass && directOK && followOK && u3 == "pass" && !contested
        session.concl("verdict", go ? "GO" : "NO-GO")
        session.concl("verdict.detail", "①E1=\(e1Pass) ②直写生效=\(directOK)（E2=\(e2VerdictText()) E2b驻留=\(e2bTgResident) E2c驻留=\(e2cTgResident)） ③跟随=\(followOK) ④E5干净=\(u3 == "pass") 竞争窗=\(contested)")
        session.concl("stop.reason", stopReason.isEmpty ? "none(全流程完整执行)" : stopReason)
        session.concl("e0.baseline", "acAllZero=\(e0AcAllZero) acBaseRPM=\(fmtF(e0AcBaselineRPM)) tempBase=\(tempS(e0TempBase))℃")
        session.concl("stateFile", Session.stateExists() ? "kept(还原未验证通过)" : "deleted(还原双验证通过)")
        session.concl("runbook", session.isRunbookEntered ? "entered" : "not-entered")
        logger.log("smc-notes.backfill.start")
        logger.log("# Phase5 v1.1 风扇 spike：机型=\(machine.model) 固件=\(machine.firmware) macOS=\(machine.macOS)｜E2=\(e2VerdictText()) E2b驻留=\(e2bTgResident) follow=\(followVerdict) E2c驻留=\(e2cTgResident)｜U1=\(e1Pass ? "pass" : "fail") U3=\(u3)（\(e5.note)） U4=\(u4mdDescription) U5=\(f1KeyPresent.isEmpty ? "none" : f1KeyPresent.joined(separator: ",")) U6=\(u6mnWrite) U7=\(u7LE ? "LE" : "BE")｜判据④：\(session.readbackViolations.isEmpty ? "无违反" : session.readbackViolations.joined(separator: " | "))")
        logger.log("smc-notes.backfill.end")
    }
    /// 中止路径结论（信号/看门狗线程调用）：不得读 Runner 判读字段（主线程写中）——一律走 session 锁通道，
    /// 主流程未发射的 u* 项如实输出 n/a(未发射)。
    private func emitBriefConclusions(_ note: String) {
        logger.log("=== 中止路径 concl.*（截断版，机器可读；u* 未发射项=n/a）===")
        session.concl("u1_writepath", session.conclusion("u1_writepath") ?? "n/a(未发射)")
        session.concl("u2_follow", session.conclusion("u2_follow") ?? "n/a(未发射)")
        session.concl("u4_md_semantics", session.conclusion("u4_md_semantics") ?? "n/a(未发射)")
        session.concl("u5_f1_keys", session.conclusion("u5_f1_keys") ?? "n/a(未发射)")
        session.concl("u6_mn_write", session.conclusion("u6_mn_write") ?? "n/a(未发射)")
        session.concl("u7_byteorder", session.conclusion("u7_byteorder") ?? "n/a(未发射)")
        session.concl("verdict", "NO-GO")
        session.concl("stop.reason", note)
        session.concl("stateFile", Session.stateExists() ? "kept(还原未验证通过)" : "deleted(还原双验证通过)")
    }
    // MARK: --do-it 主流程
    private func doIt() -> Int32 {
        logger.log("模式：--do-it（风扇键写 spike：E0–E6，§2.2 预注册）")
        logger.log("[须知] 用户在场全程；勿跑其他重负载；运行期间不要合盖；听风扇声音是 E2b 跟随判据的旁证之一")
        guard getuid() == 0 else { logger.log("--do-it 需要 root：sudo .build/debug/spike-fan --do-it"); return 2 }
        guard runPreflight(strict: true) else { return 3 }
        guard guardian.acquire() else { logger.log("[检查] 防睡眠断言（NoIdleSleep）获取失败——中止"); return 3 }
        logger.log("[检查] 防睡眠断言（NoIdleSleep）已持有，全程有效（等效 caffeinate -i；请勿合盖）")
        var stopReason = ""
        // E0（只读）+ U7 定版（E2/E2c/E4 打包前置；定版前不落任何写码语义）
        guard e0Baseline() else { guardian.release(); return 3 }
        guard settleU7ByteOrder() else { guardian.release(); return 3 }
        for key in ["F0Tg", "F0Md", "F0Mn"] {
            guard let r = smc.read(key), let info = smc.keyInfo(key) else {
                logger.log("\(key) 基线读取失败——无法实验")
                guardian.release(); return 3
            }
            session.addBaseline(key: key, size: info.size, type: info.type, bytes: r.bytes)
        }
        // P0-1：首次任何 SMC 写入前原子写状态文件（E1 探针为首写）；此后每次写步骤前更新 step 标记
        guard session.writeStateFile(step: "E0-基线") else {
            logger.log("状态文件写入失败（\(stateFilePath)）——拒绝进入写实验"); guardian.release(); return 3
        }
        logger.log("[P0-1] 状态文件已原子写入 \(stateFilePath)（机型/固件头 + F0Tg/F0Md/F0Mn 原值 + step 标记）")
        installSignalHandlers()
        session.setWatchdogStart()   // 锁通道计时（watchdogTick 全局队列读取）
        watchdog = Watchdog { [weak self] in self?.watchdogTick() }
        // E1：写通路（u1）
        e1Pass = e1WriteProbe()
        if !e1Pass {
            stopReason = "E1 写通路失败（u1=fail）——E2/E2b/E3 写实验与 E4 跳过，仅做收尾还原"
        } else {
            e2Verdict = e2DirectWrite()   // E2：直写 3350 三态判读
            switch e2Verdict {
            case .candidate:
                e2bLoadTest()             // E2b：负载态复验（仅直写候选执行）
            case .firmwareRejected(let d):
                logger.log("[E2] 固件拒绝（\(d)）——继续 E3 探索 Md=1 解锁路径（U4）")
            case .contested(let d):
                logger.log("[E2] 竞争态（\(d)）——§0.5c 不接受；继续 E3 探索 Md=1 解锁路径，但 verdict 终判 NO-GO")
            }
            // E3：Md 探索（needUnlock = E2/E2b 非直写 go 时才写 1 + E2c）
            let needUnlock: Bool
            if case .candidate = e2Verdict { needUnlock = !e2bTgResident } else { needUnlock = true }
            e3MdExplore(needUnlock: needUnlock)
            e4MnRaise()                   // E4：Mn 抬升信息收集（仅 E1 pass 时执行）
        }
        // GO 预判（①②③）→ E6（仅 GO 预判成立时执行）
        if goGatePassed() { e6Interaction() } else { session.concl("e6.run", "skipped(GO 预判未成立)") }
        // E5：全量还原 + 60s 干净度窗（GO④ 测量；abort 路径不测窗——立即终止语义）
        let e5 = e5FinalRestore()
        // P3-1：信号落在还原互斥期内登记的 abort 不得静默丢弃（母本 doIt 同款延迟处理）
        if let r = session.takeAbortReason() { finalExit(130, note: r + "（还原互斥期间登记，延迟处理）", brief: true) }
        if !e5.verified && stopReason.isEmpty { stopReason = "E5 收尾还原值级失败（runbook 已记录）" }
        archiveTempKeys()
        watchdog?.stop()
        emitConclusions(stopReason: stopReason, e5: e5)
        if e5.verified {
            logger.log("[检查单] 会话结束（干净）：双验证通过，状态文件已删除")
            guardian.release()
            return 0
        }
        logger.log("[检查单] 还原未验证通过：保留状态文件与日志，勿合盖，按 runbook 处置")
        guardian.release()
        return 1
    }
    // MARK: --restore
    private func restore(manual: (key: String, bytes: [UInt8])?) -> Int32 {
        logger.log("模式：--restore（按状态文件逐键还原 / 手动兜底）")
        guard getuid() == 0 else { logger.log("--restore 需要 root：sudo .build/debug/spike-fan --restore"); return 2 }
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
            logger.log("状态文件载入：机型=\(loaded.file.model) 固件=\(loaded.file.firmware) 会话=\(loaded.file.session) step=\(loaded.file.step) 键=[\(loaded.sortedKeys.joined(separator: ","))]")
            installSignalHandlers()
            let o = engine.fullRestore(reason: "--restore 会话")
            reportRestoreOutcome(o)
            if session.takeAbortReason() != nil { finalExit(130, note: "还原期间收到中断信号", brief: false) }
            switch o {
            case .verified: logger.log("还原完成：逐键双读验证通过，状态文件已删除（干净结束）"); return 0
            case .failedValue: logger.log("还原失败：runbook 已记录现场与处置引导；状态文件保留"); return 1
            case .alreadyRestoring: return 1
            }
        }
        return 0
    }
}

// MARK: - 主入口
guard let runner = Runner() else {
    FileHandle.standardError.write("无法连接 SMC 用户客户端——拒绝启动\n".data(using: .utf8)!)
    exit(1)
}
exit(runner.run(Array(CommandLine.arguments.dropFirst())))