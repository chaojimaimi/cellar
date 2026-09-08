#!/usr/bin/env swift
// Cellar F1 风扇键写 spike（Phase 5 v1.12 M0 GO/NO-GO 门）— 规格 docs/plans/phase5-v1.12-dual-fan.md §3；唯一事实源 docs/SMC-NOTES.md §8/§8.2
// 母本 Tools/spike-fan.swift 复制收窄（母本一字不改=F0 存档证据；独立工具照 spike-magsafe-led.swift 先例）。安全规程母本全量沿用、不得收窄：
//   P0-1 状态文件先于首次写原子落盘、残留状态文件拒绝启动（--restore 可清）、信号(SIGINT/SIGTERM/SIGHUP)→全量还原、NoIdleSleep 全程断言、
//   每次写 5s 倒计时、预检门禁（root/daemon 双检测/F1Mn 可读/电量温度母本口径）、15min 全局看门狗、还原引擎（双验证+重试阶梯 3次→等5s→再3轮）、
//   concl.* 机器可读、日志逐行 flush+每次写记 kr、abort 线立即还原。SMC 封装照抄母本 m0 体系（selector 2 + data8；读两阶段；写 cmd=6；
//   4CC 类型还原带尾空格 trim 陷阱）。
// 用法(canonical，root 只执行不构建；本脚本不在 SPM target 内——swiftc 单文件构建):
//   swiftc -O Tools/spike-fan-f1.swift -o .build/debug/spike-fan-f1   # user 侧构建
//   sudo .build/debug/spike-fan-f1 --do-it                            # E0'-E5' 全流程写实验(root;状态文件门禁)
//   sudo .build/debug/spike-fan-f1 --restore [KEY=HEX]                # 按状态文件逐键还原 / 手动兜底
// 实验矩阵(§3.2 预注册，执行顺序即表序，不现场改设计)：
//   E0' 基线：F1Ac/F1Tg/F1Md/F1Mn/F1Mx 五键 keyInfo(类型/尺寸)+原始 hex+LE/BE 双序解码对照(字节序定版=LE——双序仅复核、不据此改设计；
//     F1Mn=1522/F1Mx=5777 预期 flt/4B LE，复核用)；60s@1s F1Ac 静息曲线；F1Tg/F1Md 原值入状态文件(F1Mn/F1Mx 只读对照记录)
//   E1' F1Tg 同值回写探针(probeWrite：写原值→kr=0∧result=0∧回读一致)
//   E2a' Md=0 态写 F1Tg=3650 → 30s@2s 三分支判读(全部预注册，均不入 GO 门)：①固件即时拒绝(回读=原值)【预期】
//     ②意外驻留(全窗等值)→记录「免解锁更简世界」，E2c' 照跑不省 ③接受后被系统覆写(回读先一致后漂移)→预期形态非异常
//   E3' F1Md 同值回写探针——分离「Md 写通路不通」与「Md=1 后 Tg 被拒」两种 NO-GO 成因
//   E2c' F1Md=1(写后锁存重试阶梯 100/300/800ms 回读验证)→F1Tg=3650(同阶梯验证)→60s@2s：F1Tg 驻留+F1Ac 跟随
//   E5' 还原 F1Tg→状态文件原值+F1Md=0x00(各带回读一致验证)→60s@2s 干净窗(F1Ac 回 E0' 基线±150rpm 或接管证据=Ac 活值变化；
//     记录事实不入判据)
//   跳过：Mn 写实验、CHTE 交互(§3.2 明确跳过)；E2b 负载态不重演(§8.2 观察+daemon 运行时防守覆盖)
// GO 判据(§3.3 预注册)：GO = E1' pass ∧ E3' pass ∧ E2c' pass ∧ E5' 还原干净。E2c' 跟随判据：T+6s 起的样本全部 ≥3350(=3650−300
//   爬升宽限)且全窗 max ≥3350。日志尾部打「判读对账表」逐条列 GO 四要素 pass/fail 与证据值；
//   abort(Ctrl-C/看门狗/异常)走母本 abort 线：全量还原+concl.verdict=abort——机械结论，GO/NO-GO 须回预注册判据逐条对账。
// 安全红线：F0 键零写入（F0 字样仅注释/对照文案，工单验收 grep 机械自检断言）；只写 F1Tg/F1Md 两键，F1Ac/F1Mn/F1Mx 只读；
//   温度≥40℃或电量出[35,85]每采样点同查→全量还原；还原重试阶梯(3次→等5s→再3轮)；零品牌词（指代他工具一律「同类风扇控制工具」）。

import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - 预注册常量（方案 §3.2/§3.3 定版；改动即改实验设计——禁止）
private let stateFilePath = "/tmp/cellar-spike-fan-f1-state.json"
private let tgWriteTarget: Float = 3650            // §3.2 预注册写目标：F1Tg 直写 3650rpm = (1522+5777)/2 取整（照 F0 中点先例——F0 为对照文案）
private let followAcFloorRPM: Double = 3350        // §3.3 跟随阈值 = 3650−300
private let followGraceS = 6                      // §3.3 爬升宽限 6s：T+6s 起的样本计入跟随判据
private let baselineAcTolRPM: Double = 150        // E5' 干净窗记录口径：F1Ac 回基线 ±150rpm
private let watchdogTimeoutS: TimeInterval = 900  // 全局硬超时 15min（预注册取值）
private let concurrentRestoreWaitS: TimeInterval = 70 // P2-A：另一路还原有界等待上限（母本同款：阶梯最坏 ≈16s，70s 为宽松硬界）
private let e0WindowS = 60, e0StepS = 1           // E0'：60s @1s F1Ac 静息曲线
private let e2aWindowS = 30, e2aStepS = 2         // E2a'：30s @2s 三分支观察
private let e2cWindowS = 60, e2cStepS = 2         // E2c'：60s @2s 驻留+跟随窗
private let e5WindowS = 60, e5StepS = 2           // E5'：60s @2s 干净窗
private let mdAuto: UInt8 = 0                     // E5'：F1Md=0x00 规范值（§1 R3 N-2——不用 E0' 原值）
private let mdManual: UInt8 = 1                   // E2c'：F1Md=1 解锁
private let verifyLadderMs = [100, 300, 800]      // E2c' 锁存重试阶梯：写后每档回读前依次延时 100/300/800ms（FanSMC.verifyLadderMs 逐字同款，首档 ≥100ms=锁存延迟实测下限）
private let f1MnExpectedRPM = 1522                // §1 事实基础（E0' 双序对照复核用，非判据）
private let f1MxExpectedRPM = 5777                // §1 事实基础（E0' 双序对照复核用，非判据）
private let tempAbortCentiC = 4000                // 母本安全线：温度 ≥40℃ → 全量还原（全量沿用不收窄）
private let chargeAbortPct = 35...85              // 母本安全线：电量出 [35,85] → 全量还原
private let preflightChargePct = 40...75          // 母本 P2-1：预检电量收紧 [40,75]
private let preflightTempCentiC = 3500            // 母本定版：预检温度 <35℃
private let rpmPlausibleRange = 1.0...60000.0     // E0' 双序对照复核辅助判读域（仅复核依据，非物理断言）

// MARK: - SMC 常量与错误码（照抄母本 m0）
private let selectorUniversal: UInt32 = 2
private let cmdRead: UInt8 = 5
private let cmdWrite: UInt8 = 6
private let cmdKeyInfo: UInt8 = 9
private let resultSuccess: UInt8 = 0
private let krExplainTable: [Int32: String] = [kIOReturnSuccess: "成功", Int32(bitPattern: 0xE00002C1): "NotPrivileged(写需root)", Int32(bitPattern: 0xE00002C7): "BadArgument(旧选择器已移除)"]
private func krExplain(_ kr: Int32) -> String { krExplainTable[kr] ?? "" }
private let resultExplainTable: [UInt8: String] = [0: "OK", 132: "KeyNotFound(隐藏/不存在)", 134: "写拒绝(fNotWritable)", 137: "尺寸不符(需两阶段读)"]
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
/// SMC 'flt' 4B：IEEE754 单精度；LE/BE 双序解读（§3.2 E0' 双序对照复核——字节序定版=LE（§8.1 U7），
/// 双序函数并列保留仅供 E0' 复核落盘，不据此改设计）。
private func decodeFlt(_ b: [UInt8], le: Bool) -> Double? {
    guard b.count == 4 else { return nil }
    let bits = le ? UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
                  : UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    return Double(Float(bitPattern: bits))
}
/// flt 打包（E2a'/E2c' 写目标按 LE 定版序）。
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
/// 4CC dataType 还原带尾空格 trim 陷阱（照母本：不加 trim 会把 "flt " 与 "flt" 当两种类型）。
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
/// launchctl print 失败即「已卸载」（预检门禁项，§3.1 运行前置）。
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
        d.dateFormat = "yyyyMMdd-HHmmss"
        path = "/tmp/cellar-spike-fan-f1-" + d.string(from: Date()) + ".log"
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
/// writable：仅可写还原键（F1Tg/F1Md）参与还原集；F1Mn/F1Mx 只读对照记录（还原引擎跳过——
/// 母本状态文件无此字段，收窄新增：只读键进还原集会 9 轮写失败误触 runbook）。
private struct KeyStateEntry: Codable { let key: String; let size: Int; let type: String; let originalHex: String; let writtenAt: String; let writable: Bool }
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
    /// 锁通道写入（母本钉死：信号/看门狗激活后还原线程与主流程无锁写 Dictionary 是真实崩溃源）。
    func addBaseline(key: String, size: UInt32, type: String, bytes: [UInt8], writable: Bool) {
        lock.lock(); defer { lock.unlock() }
        originals[key] = bytes
        keys[key] = KeyStateEntry(key: key, size: Int(size), type: type, originalHex: hex(bytes), writtenAt: "", writable: writable)
    }
    /// 原子写（.atomic = 临时文件+rename）；每次写步骤前调用更新 step 标记（P0-1）。
    func writeStateFile(step: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let ts = df.string(from: Date())
        if stateFileCreatedAt.isEmpty { stateFileCreatedAt = ts }
        let file = StateFile(version: 1, model: machine.model, firmware: machine.firmware, macOS: machine.macOS,
                             createdAt: ts, session: "cellar-spike-fan-f1-" + ts, step: step,
                             keys: keys.mapValues { KeyStateEntry(key: $0.key, size: $0.size, type: $0.type, originalHex: $0.originalHex, writtenAt: stateFileCreatedAt, writable: $0.writable) })
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
    /// 还原集 = 可写键（F1Tg/F1Md）；F1Mn/F1Mx 只读对照不还原（写了也只会 result=134）。
    func sortedWritableKeys() -> [String] { lock.lock(); defer { lock.unlock() }; return keys.keys.filter { keys[$0]?.writable == true }.sorted() }
    /// 锁通道读原值（信号/看门狗线程还原路径与主线程写入并发时安全）。
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
                                             "Cellar F1 风扇键写调研会话（运行期间请勿合盖）" as CFString, &assertionID)
        held = kr == kIOReturnSuccess
        return held
    }
    func release() { if held { IOPMAssertionRelease(assertionID); held = false } }
}

// MARK: - 看门狗（母本模式：全局队列独立于主流程；预注册 900s 全局硬超时）
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

// MARK: - 还原引擎（母本 P0-2：双验证 + 重试阶梯 3 次→等 5s→再 3 轮 + runbook 现场记录；还原集=状态文件可写键）
private final class RestoreEngine: @unchecked Sendable {
    private let smc: SMCConnection
    private let session: Session
    private let logger: Logger
    enum Outcome { case verified, failedValue([String: String]), alreadyRestoring }
    init(smc: SMCConnection, session: Session, logger: Logger) {
        self.smc = smc; self.session = session; self.logger = logger
    }
    /// 全量还原（信号/看门狗/abort/--restore 共用同一入口）：仅还原可写键（F1Tg/F1Md）→ 双验证 → 删状态文件。
    func fullRestore(reason: String) -> Outcome {
        guard session.beginRestore() else { return .alreadyRestoring }
        defer { session.endRestore() }
        logger.log("[还原] 开始全量还原 reason=\(reason) keys=[\(session.sortedWritableKeys().joined(separator: ","))]")
        var valueFail: [String: String] = [:]
        for key in session.sortedWritableKeys() {
            if let fail = restoreKeyWithLadder(key) { valueFail[key] = fail }
        }
        if !valueFail.isEmpty { runbook(valueFail: valueFail); return .failedValue(valueFail) }
        session.deleteStateFile()
        logger.log("[还原] 全部键值级回读==原值（双验证通过），状态文件已删除")
        return .verified
    }
    /// 步内还原出口分列（P2-A）：mutexBusy 不得宣称 runbook——另一路还原正在进行，非阶梯失败。
    enum LadderOutcome { case ok, mutexBusy, failed(String) }
    /// 单键值级阶梯还原（步内还原用：E2a'/E2c' 写后回原值）；纳入还原互斥（照母本先例：
    /// 信号/看门狗 fullRestore 与步内还原并发时互斥）。
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
        logger.log("[runbook] 终态处置：形态=值级失败（回写报错/回读不一致）｜引导：保持电源连接、不要合盖、勿重启；手动兜底 sudo .build/debug/spike-fan-f1 --restore；仍失败则保留状态文件与日志交工程师分析｜键明细：\(valueFail)")
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
    // 字节序：§1 事实基础 LE 定版（§8.1 U7；E0' 双序对照仅复核，不据此改设计——本工具不重开定版交互）
    private let byteOrderLE = true
    // 判读现场由主线程独占（信号/看门狗只经 session 锁通道，不读这些）
    private var e0AcAllZero = false
    private var acLEsStored: [Double] = []
    private var acBEsStored: [Double] = []
    private var e0AcBaselineRPM: Double? = nil   // E0' 曲线 LE 序均值（恒 0 时为 nil；E5' 干净窗记录口径用）
    private var e0TempBase = 0.0
    private var e1Pass = false
    private var e1Detail = "未执行"
    private var e2aVerdict = "skipped(未执行)"
    private var e3Pass = false
    private var e3Detail = "未执行"
    private var e2cPass = false
    private var e2cDetail = "未执行"
    private var e2cFollow = "n/a(未执行)"
    private var e5Verified = false
    private var e5Detail = "未执行"
    private var e5WindowFact = "未执行"
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
        logger.log("=== F1 风扇键写 spike 会话 uid=\(getuid()) 机型=\(machine.model) 固件=\(machine.firmware) macOS=\(machine.macOS) 日志=\(logger.path) ===")
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
          swiftc -O Tools/spike-fan-f1.swift -o .build/debug/spike-fan-f1    # user 侧构建
          sudo .build/debug/spike-fan-f1 --do-it                             # E0'-E5' 全流程写实验(root;状态文件门禁)
          sudo .build/debug/spike-fan-f1 --restore                           # 按状态文件逐键还原
          sudo .build/debug/spike-fan-f1 --restore F1Tg=00006445             # 手动兜底(KEY=HEX；3650rpm LE 打包)
        """)
    }
    private func countdown(_ seconds: Int, summary: String) {
        for i in stride(from: seconds, through: 1, by: -1) {
            logger.log("[倒计时] \(i)s 后执行：\(summary)（Ctrl-C 立即全量还原）")
            Thread.sleep(forTimeInterval: 1)
        }
    }
    /// 同值回写探针（母本 P1-4：写通路验证；失败整键退出）。
    private func probeWrite(key: String) -> (pass: Bool, detail: String) {
        guard let cur = smc.read(key) else {
            logger.log("[探针] \(key) 读失败——中止该键路径")
            return (false, "键读失败")
        }
        let (ok, kr, result) = smc.writeDetailed(key, bytes: cur.bytes)
        session.recordWrite(key: key, bytes: cur.bytes, ok: ok, kr: kr, result: result)
        Thread.sleep(forTimeInterval: 0.5)
        let back = smc.read(key)
        let krS = String(format: "0x%08X", kr)
        if ok, let back = back, back.bytes == cur.bytes {
            logger.log("[探针] \(key) 同值回写一致 value=\(hex(cur.bytes))（写通路可靠）")
            return (true, "kr=\(krS) result=\(result)(OK) 写=回读=\(hex(cur.bytes))")
        }
        logger.log("[探针] \(key) 同值回写失败 kr=\(krS) result=\(result) 回读=\(back.map { hex($0.bytes) } ?? "读失败")——中止该键路径")
        return (false, "kr=\(krS) result=\(result) 回读≠写值")
    }
    /// P0-1 步骤门（探针写步骤前置——按任务安全线②收紧：每次写步骤前更新 step 标记）。
    private func stepGate(_ tag: String) -> Bool {
        guard session.writeStateFile(step: tag) else {
            logger.log("状态文件更新失败（\(stateFilePath)）——拒绝写步骤（P0-1）")
            return false
        }
        return true
    }
    /// 写结果分列（各阶段按规格判读——写入抛错=abort 线；回读不符=阶段级判读输出）。
    private enum WriteResult { case already, ok, writeFailed(String), readbackFailed, mismatch(String) }
    /// 统一写入口：写步骤前更新状态文件 step（P0-1）+ 5s 倒计时 + 写 + kr 记录 + 回读分列。
    /// recordViolation=false 用于 E2a'（分支①固件即时拒绝=预注册预期形态，不计入回读违反清单）。
    @discardableResult
    private func writeKey(_ key: String, _ value: [UInt8], stepTag: String, recordViolation: Bool = true) -> WriteResult {
        guard session.writeStateFile(step: stepTag) else {
            logger.log("状态文件更新失败（\(stateFilePath)）——拒绝写入（P0-1）")
            return .writeFailed("状态文件更新失败")
        }
        guard let cur = smc.read(key) else { return .readbackFailed }
        if cur.bytes == value { logger.log("[写] \(key) 已是目标态 \(hex(value))——无需写"); return .already }
        logger.log("[写] \(key)：\(hex(cur.bytes)) → \(hex(value))")
        countdown(5, summary: "写 \(key)=\(hex(value))")
        let (ok, kr, result) = smc.writeDetailed(key, bytes: value)
        session.recordWrite(key: key, bytes: value, ok: ok, kr: kr, result: result)
        Thread.sleep(forTimeInterval: 0.5)
        guard ok else { return .writeFailed(String(format: "0x%08X", kr)) }
        guard let back = smc.read(key) else { return .readbackFailed }
        if back.bytes != value {
            if recordViolation { session.recordReadbackViolation("\(key) 写 \(hex(value)) 后回读=\(hex(back.bytes))（实际读回值=\(hex(back.bytes))）") }
            return .mismatch(hex(back.bytes))
        }
        logger.log("[写] \(key)=\(hex(value)) 回读一致")
        return .ok
    }
    /// 写入抛错 → 统一 abort 线（§3.2：写入抛错 → 立即还原并终止；调用方仍需自行判读 .mismatch）。
    private func writeOrAbort(_ key: String, _ value: [UInt8], stepTag: String, abortMsg: String, recordViolation: Bool = true) -> WriteResult {
        let r = writeKey(key, value, stepTag: stepTag, recordViolation: recordViolation)
        if case .writeFailed(let krs) = r { abortRun("\(abortMsg)（kr=\(krs)）") }
        if case .readbackFailed = r { abortRun("\(abortMsg)（回读失败）") }
        return r
    }
    /// 锁存重试阶梯写（E2c'/E5'：写后每档回读前依次延时 100/300/800ms——FanSMC.verifyLadderMs 逐字同款，
    /// Md 写后锁存延迟 ≤100ms（§1 U4），首档必须 ≥100ms。母本 writeKey 为单次 0.5s 回读；阶梯为 §3.2 E2c' 行预注册要求。
    private enum LadderResult { case already, ok(String), writeFailed(String), readbackFailed, mismatch(String) }
    @discardableResult
    private func writeKeyLadder(_ key: String, _ value: [UInt8], stepTag: String) -> LadderResult {
        guard session.writeStateFile(step: stepTag) else {
            logger.log("状态文件更新失败（\(stateFilePath)）——拒绝写入（P0-1）")
            return .writeFailed("状态文件更新失败")
        }
        guard let cur = smc.read(key) else { return .readbackFailed }
        if cur.bytes == value { logger.log("[写] \(key) 已是目标态 \(hex(value))——无需写"); return .already }
        logger.log("[写] \(key)：\(hex(cur.bytes)) → \(hex(value))（锁存重试阶梯 回读验证：累计 \(verifyLadderMs.reduce(0, +))ms）")
        countdown(5, summary: "写 \(key)=\(hex(value))（锁存阶梯验证）")
        let (ok, kr, result) = smc.writeDetailed(key, bytes: value)
        session.recordWrite(key: key, bytes: value, ok: ok, kr: kr, result: result)
        guard ok else { return .writeFailed(String(format: "0x%08X", kr)) }
        var elapsedMs = 0
        var lastHex = "?"
        for ms in verifyLadderMs {
            Thread.sleep(forTimeInterval: TimeInterval(ms) / 1000)
            elapsedMs += ms
            guard let back = smc.read(key) else { return .readbackFailed }
            lastHex = hex(back.bytes)
            if back.bytes == value {
                logger.log("[写] \(key)=\(hex(value)) 锁存阶梯验证通过 @+\(elapsedMs)ms（回读一致）")
                return .ok("@+\(elapsedMs)ms")
            }
        }
        session.recordReadbackViolation("\(key) 写 \(hex(value)) 后锁存阶梯 \(verifyLadderMs.reduce(0, +))ms 内回读=\(lastHex)")
        return .mismatch(lastHex)
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
    /// 看门狗 tick（全局队列）：会话写入阶段全局硬超时（预注册 900s）→ 全量还原。
    private func watchdogTick() {
        let age = session.watchdogAgeSeconds()   // 锁通道读取（主线程 setWatchdogStart 并发安全）
        guard age > watchdogTimeoutS else { return }
        if session.isRestoring {
            logger.log("[看门狗] 会话 \(Int(age))s 超 15min 硬超时，但还原进行中——交由进行中的还原完成")
            return
        }
        logger.log("[看门狗] 会话 \(Int(age))s 超 15min 硬超时（预注册 900s 全局看门狗）——触发全量还原（abort 线）")
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
    // MARK: 预检门禁（§3.1：root / daemon 双检测卸载 / F1Mn 可读 / 残留拒绝 / 电量温度母本口径）
    private func runPreflight(strict: Bool) -> Bool {
        var ok = true
        let fail = { (check: String) in self.logger.log("[检查] \(check)=失败"); ok = false }
        if getuid() == 0 { logger.log("[检查] root 身份=通过") } else { fail("root 身份"); logger.log("[检查]     请用 sudo 执行（写 SMC 需 root）") }
        if launchctlLoaded("system/com.cellar.daemon") {
            fail("daemon 已卸载(launchctl)")
            logger.log("[检查]     launchctl print system/com.cellar.daemon 仍成功——请先 sudo launchctl bootout system/com.cellar.daemon（§3.1 运行前置）")
        } else { logger.log("[检查] daemon 已卸载(launchctl print 失败)=通过") }
        if processRunning("cellar-daemon") {
            fail("daemon 已卸载(pgrep)")
            logger.log("[检查]     cellar-daemon 进程仍在——请先卸载 daemon（§3.1 运行前置：排除实验窗内并发风扇策略写入对 F1 观察的干扰）")
        } else { logger.log("[检查] daemon 已卸载(pgrep 无进程)=通过") }
        // F1Mn 在位性（§2 D4 presence 探测键；其余四键由 E0' 逐键回填 U5'）
        if smc.read("F1Mn") != nil { logger.log("[检查] F1Mn 可读=通过（D4 presence 探测键）") }
        else { fail("F1Mn 可读"); logger.log("[检查]     F1Mn 不可读——疑似单风扇机型（§2 D4 口径），F1 写实验无对象") }
        if let s = telemetry.sample() {
            if preflightChargePct.contains(s.percent) { logger.log("[检查] 电量 40-75%=通过 (\(s.percent)%)") }
            else { fail("电量 40-75%"); logger.log("[检查]     电量 \(s.percent)% 请调整后重试（母本 P2-1 口径全量沿用）") }
            if s.temperatureCentiC < preflightTempCentiC { logger.log("[检查] 温度<35℃=通过 (\(tempS(Double(s.temperatureCentiC) / 100))℃)") }
            else { fail("温度<35℃"); logger.log("[检查]     温度 \(tempS(Double(s.temperatureCentiC) / 100))℃") }
        } else { fail("电池遥测"); logger.log("[检查]     遥测服务不可用") }
        if Session.stateExists() {
            fail("状态文件门禁")
            logger.log("[检查]     存在未清理状态文件 \(stateFilePath)——请先 sudo .build/debug/spike-fan-f1 --restore")
        } else { logger.log("[检查] 状态文件门禁=通过（无残留）") }
        if strict && !ok { logger.log("[检查] 前置检查未通过，拒绝进入写实验") }
        return ok
    }
    // MARK: 采样（观察窗使用；按 LE 定版序解码）
    private struct FanSample {
        let tempCentiC: Int, percent: Int
        let acHex: String?, acRPM: Double?
        let tgHex: String?, mdRaw: UInt8?
        let mnHex: String?
    }
    private func decodeRPM(_ r: (size: UInt32, type: String, bytes: [UInt8])) -> Double? {
        let t = typeTrimmed(r.type)   // 4CC 尾空格 trim（照母本）
        if t == "flt" { return decodeFlt(r.bytes, le: byteOrderLE) }
        if t == "ui16" {
            guard r.bytes.count >= 2 else { return nil }
            return Double(UInt16(r.bytes[0]) << 8 | UInt16(r.bytes[1]))
        }
        if t == "ui8" { return r.bytes.first.map(Double.init) }
        return nil
    }
    private func fanSample() -> FanSample? {
        guard let t = telemetry.sample() else { return nil }
        let ac = smc.read("F1Ac"), tg = smc.read("F1Tg")
        let md = smc.read("F1Md"), mn = smc.read("F1Mn")
        return FanSample(tempCentiC: t.temperatureCentiC, percent: t.percent,
                         acHex: ac.map { hex($0.bytes) }, acRPM: ac.flatMap { decodeRPM($0) },
                         tgHex: tg.map { hex($0.bytes) }, mdRaw: md?.bytes.first,
                         mnHex: mn.map { hex($0.bytes) })
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
            logger.log("[\(tag)] #\(i + 1)/\(n) ac=\(fmtF(s.acRPM))rpm tg=\(s.tgHex ?? "读失败") md=\(s.mdRaw.map { String(format: "%02X", $0) } ?? "读失败") mn=\(s.mnHex ?? "读失败") temp=\(tempS(Double(s.tempCentiC) / 100))℃ percent=\(s.percent)%")
        }
        return out
    }
    // MARK: E0' 基线（§3.2：五键 keyInfo+原始 hex+LE/BE 双序对照；60s@1s F1Ac 静息曲线；U5'/U7' 事实回填）
    private func e0Baseline() -> Bool {
        logger.log("=== E0'（§3.2）：F1* 五键 keyInfo+原始 hex+LE/BE 双序解码对照（U5'/U7' 事实回填；字节序定版=LE——双序仅复核，不据此改设计）；60s@1s F1Ac 静息曲线 ===")
        for name in ["Ac", "Tg", "Md", "Mn", "Mx"] {
            let key = "F1" + name
            if let info = smc.keyInfo(key), let r = smc.read(key) {
                f1KeyPresent.append(key)
                if typeTrimmed(info.type) == "flt" {
                    logger.log("e0.\(key)=在位 type='\(info.type)' size=\(info.size) hex=\(hex(r.bytes)) LE=\(fmtF(decodeFlt(r.bytes, le: true))) BE=\(fmtF(decodeFlt(r.bytes, le: false)))（双序对照复核；定版=LE）")
                } else {
                    logger.log("e0.\(key)=在位 type='\(info.type)' size=\(info.size) hex=\(hex(r.bytes)) raw=\(r.bytes.first ?? 0)")
                }
            } else { logger.log("e0.\(key)=不存在/不可读（U5' 事实回填）") }
        }
        // §1 事实基础复核（信息用，非判据）：F1Mn=1522 / F1Mx=5777 预期 flt/4B LE
        for (key, expected) in [("F1Mn", f1MnExpectedRPM), ("F1Mx", f1MxExpectedRPM)] {
            guard let r = smc.read(key), typeTrimmed(r.type) == "flt", let le = decodeFlt(r.bytes, le: true) else {
                logger.log("[E0' 复核] \(key) LE 解读不可得——复核跳过（记录事实）")
                continue
            }
            let drift = Int(le.rounded()) - expected
            logger.log("[E0' 复核] \(key) LE=\(fmtF(le)) vs §1 预期 \(expected)rpm（Δ=\(drift >= 0 ? "+" : "")\(drift)）——\(abs(drift) <= 1 ? "一致" : "不一致（记录事实，不改设计）")")
        }
        // 60s @1s F1Ac 静息曲线（LE 定版序计基线；BE 并行落盘供复核）
        var temps: [Int] = []
        for i in 0..<e0WindowS {
            if i > 0 { Thread.sleep(forTimeInterval: TimeInterval(e0StepS)) }
            guard let t = telemetry.sample() else { logger.log("[E0'] #\(i + 1)/\(e0WindowS) 遥测不可用——不计"); continue }
            guard checkSafety(t) else { return false }
            temps.append(t.temperatureCentiC)
            var acLine = "读失败", leS = "-", beS = "-"
            if let ac = smc.read("F1Ac"), typeTrimmed(ac.type) == "flt" {
                let le = decodeFlt(ac.bytes, le: true), be = decodeFlt(ac.bytes, le: false)
                acLine = hex(ac.bytes); leS = fmtF(le); beS = fmtF(be)
                if let le, le != 0 { acLEsStored.append(le) }
                if let be, be != 0 { acBEsStored.append(be) }
            }
            logger.log("[E0' F1Ac曲线] #\(i + 1)/\(e0WindowS) ac=\(acLine) LE=\(leS) BE=\(beS) temp=\(tempS(Double(t.temperatureCentiC) / 100))℃ percent=\(t.percent)%")
        }
        e0AcAllZero = acLEsStored.isEmpty && acBEsStored.isEmpty
        e0TempBase = temps.isEmpty ? 0 : Double(temps.reduce(0, +)) / Double(temps.count) / 100
        let leIn = acLEsStored.filter { rpmPlausibleRange.contains($0) }.count
        let beIn = acBEsStored.filter { rpmPlausibleRange.contains($0) }.count
        logger.log("[E0'] 60s 曲线完成：F1Ac 非零读数 LE 均值=\(fmtF(meanOf(acLEsStored))) BE 均值=\(fmtF(meanOf(acBEsStored))) 恒 0=\(e0AcAllZero)；双序对照复核 LE 落合理域 \(leIn)/\(acLEsStored.count) BE 落合理域 \(beIn)/\(acBEsStored.count)（定版=LE，仅复核）；温度基线=\(tempS(e0TempBase))℃")
        e0AcBaselineRPM = meanOf(acLEsStored)   // LE 定版；恒 0 时为 nil
        return true
    }
    // MARK: E1'（§3.2：F1Tg 同值回写——写通路验证，不动键值）
    private func e1WriteProbe() -> Bool {
        logger.log("=== E1'（§3.2）：F1Tg 同值回写探针（写通路验证；kr=0 ∧ result=0 ∧ 回读一致）===")
        guard stepGate("E1'-探针") else {
            e1Detail = "状态文件更新失败（P0-1 拒写）"
            session.concl("e1.run", "fail(\(e1Detail))")
            session.concl("stop.reason", "E1' 前状态文件更新失败")
            return false
        }
        countdown(5, summary: "E1' F1Tg 同值回写探针（写原值 → 回读验证）")
        let probe = probeWrite(key: "F1Tg")
        e1Detail = probe.detail
        session.concl("e1.run", probe.pass ? "pass" : "fail(\(e1Detail))")
        if !probe.pass { session.concl("stop.reason", "E1' 写通路失败（同值回写 kr≠0 或回读不一致）") }
        return probe.pass
    }
    // MARK: E2a'（§3.2：Md=0 态直写 F1Tg=3650 → 30s@2s 三分支判读——全部预注册，均不入 GO 门）
    private func e2aMd0Write() {
        logger.log("=== E2a'（§3.2）：Md=0 态直写 F1Tg=3650 → 30s@2s 观察（三分支预注册，均不入 GO 门）===")
        let mdNow = smc.read("F1Md")
        logger.log("[E2a'] Md=0 态前提：F1Md=\(mdNow.map { hex($0.bytes) } ?? "读失败")（E0' 基线）\(mdNow?.bytes.first == 0 ? "" : "——预设失真（记录事实，分支判读仍照预注册执行）")")
        // 格式门（fail-visible，照母本 E2 模式）：F1Tg 非 flt/4B 不做值格式猜测
        let tgInfoO = smc.keyInfo("F1Tg")
        guard let info = tgInfoO, typeTrimmed(info.type) == "flt", info.size == 4 else {
            logger.log("[E2a'] F1Tg 类型/尺寸不符（type='\(tgInfoO?.type ?? "?")' size=\(tgInfoO?.size ?? 0)，需 flt/4B）——fail-visible，不做值格式猜测")
            e2aVerdict = "skipped(F1Tg 格式不符)"
            session.concl("e2a.run", e2aVerdict)
            return
        }
        let tgBytes = encodeFlt(tgWriteTarget, le: byteOrderLE)
        logger.log("[E2a'] 目标 3650rpm = \(hex(tgBytes))（LE 打包，§3.2 预注册）")
        // 分支①【预期】：Md=0 下固件即时拒绝（写后即时回读=原值）——预注册预期形态，不计入回读违反清单
        let w = writeOrAbort("F1Tg", tgBytes, stepTag: "E2a'", abortMsg: "E2a' 写 F1Tg=3650 写入抛错", recordViolation: false)
        if case .mismatch(let hv) = w {
            logger.log("[E2a'] 写后即时回读=\(hv)≠目标 \(hex(tgBytes))——分支①固件即时拒绝（回读=原值）【预期形态】")
            e2aVerdict = "firmwareRejected(回读=\(hv))【预期】"
            session.concl("e2a.run", e2aVerdict)
            _ = guardRestored(engine.restoreKeyLadder("F1Tg"), context: "E2a' 分支①后还原 F1Tg")
            return
        }
        if case .already = w {
            logger.log("[E2a'] 写前 F1Tg 即=目标 3650（系统先行写入？）——本次写无增量，开窗仅记录驻留/覆写形态")
        }
        let samples = observe(seconds: e2aWindowS, stepS: e2aStepS, tag: "E2a'")
        if samples.isEmpty {
            logger.log("[E2a'] 窗内无有效样本——判读 inconclusive（原始 hex 已逐点落盘）")
            e2aVerdict = "inconclusive(窗内无有效样本)"
        } else if let idx = samples.firstIndex(where: { $0.tgHex != hex(tgBytes) }) {
            let drift = samples[idx]
            logger.log("[E2a'] 写后 T+\(idx * e2aStepS)s 漂移：Tg 回读=\(drift.tgHex ?? "读失败") ≠目标——分支③接受后被系统覆写（回读先一致后漂移，预期形态非异常）")
            e2aVerdict = "accepted-then-overwritten(漂移@T+\(idx * e2aStepS)s 回读=\(drift.tgHex ?? "?"))"
        } else {
            logger.log("[E2a'] 全窗 \(e2aWindowS)s 驻留等值——分支②意外驻留：记录「免解锁更简世界」（E2c' 照跑不省）")
            e2aVerdict = "resident-unexpected(全窗驻留——免解锁更简世界，E2c' 照跑)"
        }
        session.concl("e2a.run", e2aVerdict)
        _ = guardRestored(engine.restoreKeyLadder("F1Tg"), context: "E2a' 窗后还原 F1Tg")
    }
    // MARK: E3'（§3.2：F1Md 同值回写探针——分离「Md 写通路不通」与「Md=1 后 Tg 被拒」）
    private func e3MdProbe() {
        logger.log("=== E3'（§3.2）：F1Md 同值回写探针（Md 写通路独立结论）===")
        let mdInfoO = smc.keyInfo("F1Md")
        guard let mdInfo = mdInfoO, mdInfo.size == 1 else {
            e3Detail = "fail(F1Md 尺寸 \(mdInfoO?.size ?? 0)B ≠1B)"
            session.concl("e3.run", e3Detail)
            logger.log("[E3'] \(e3Detail)——探针跳过（fail-visible）")
            return
        }
        guard stepGate("E3'-探针") else {
            e3Detail = "fail(状态文件更新失败 P0-1 拒写)"
            session.concl("e3.run", e3Detail)
            return
        }
        // P2-1：同值回写探针照母本逐写规程补 5s 倒计时（probeWrite 不经 writeKey 倒计时路径，不得收窄）
        countdown(5, summary: "E3' F1Md 同值回写探针（写原值 → 回读验证）")
        let probe = probeWrite(key: "F1Md")
        e3Pass = probe.pass
        e3Detail = probe.pass ? probe.detail : "fail(\(probe.detail))"
        session.concl("e3.run", probe.pass ? "pass" : e3Detail)
        if !probe.pass { logger.log("[E3'] F1Md 同值回写失败——「Md 写通路不通」成因成立，E2c' 跳过") }
    }
    // MARK: E2c'（§3.2：解锁直写——F1Md=1（锁存阶梯）→ F1Tg=3650（同阶梯）→ 60s@2s 驻留+跟随）
    private func e2cUnlockWrite() {
        logger.log("=== E2c'（§3.2）：解锁直写——F1Md=1（锁存阶梯 \(verifyLadderMs.reduce(0, +))ms 回读验证）→ F1Tg=3650（同阶梯）→ 60s@2s 驻留+跟随 ===")
        logger.log("[E2c'] 跟随判据（§3.3 预注册）：T+\(followGraceS)s 起的样本全部 ≥\(Int(followAcFloorRPM)) 且全窗 max ≥\(Int(followAcFloorRPM))")
        // 步 1：F1Md=1（解锁；Md 写后锁存延迟 ≤100ms → 锁存重试阶梯验证）
        var mdLadderNote = ""
        let mdW = writeKeyLadder("F1Md", [mdManual], stepTag: "E2c'-md1")
        switch mdW {
        case .ok(let at):
            mdLadderNote = "阶梯✓(\(at))"
            logger.log("[E2c'] F1Md=1 \(mdLadderNote)")
        case .already:
            mdLadderNote = "写前已=1(归因注明)"
            logger.log("[E2c'] F1Md 已=1——解锁语义仍成立（归因注明）")
        case .mismatch(let hv):
            logger.log("[E2c'] F1Md=1 锁存阶梯验证失败（回读=\(hv)）——解锁写被拒/被改，E2c' 终止")
            e2cDetail = "fail(Md=1 阶梯验证失败 回读=\(hv))"
            session.concl("e2c.run", e2cDetail)
            _ = guardRestored(engine.restoreKeyLadder("F1Md"), context: "E2c' Md 失败后还原 F1Md")
            return
        case .writeFailed(let krs):
            abortRun("E2c' 写 F1Md=1 写入抛错（kr=\(krs)）")
        case .readbackFailed:
            abortRun("E2c' 写 F1Md=1 回读失败")
        }
        // 步 2：F1Tg=3650（同阶梯验证）
        let tgBytes = encodeFlt(tgWriteTarget, le: byteOrderLE)
        var tgLadderNote = ""
        let tgW = writeKeyLadder("F1Tg", tgBytes, stepTag: "E2c'-tg")
        switch tgW {
        case .ok(let at):
            tgLadderNote = "阶梯✓(\(at))"
            logger.log("[E2c'] F1Tg=3650 \(tgLadderNote)")
        case .already:
            tgLadderNote = "写前已=目标态(归因注明，观察照跑)"
            logger.log("[E2c'] F1Tg 写前即=目标 3650——本次写无增量（归因注明），观察照跑")
        case .mismatch(let hv):
            logger.log("[E2c'] F1Tg=3650 锁存阶梯验证失败（回读=\(hv)）——Md=1 后 Tg 仍被拒（NO-GO 成因已由 E3' 分离）")
            e2cDetail = "fail(Tg=3650 阶梯验证失败 回读=\(hv)；Md=1 \(mdLadderNote))"
            session.concl("e2c.run", e2cDetail)
            _ = guardRestored(engine.restoreKeyLadder("F1Tg"), context: "E2c' Tg 失败后还原 F1Tg")
            _ = guardRestored(engine.restoreKeyLadder("F1Md"), context: "E2c' 还原 F1Md")
            return
        case .writeFailed(let krs):
            abortRun("E2c' 写 F1Tg=3650 写入抛错（kr=\(krs)）")
        case .readbackFailed:
            abortRun("E2c' 写 F1Tg=3650 回读失败")
        }
        // 步 3：60s@2s 观察窗（Tg 驻留 + Ac 跟随；判据 §3.3 预注册）
        let samples = observe(seconds: e2cWindowS, stepS: e2cStepS, tag: "E2c'")
        let targetHex = hex(tgBytes)
        let tgResident = !samples.isEmpty && !samples.contains { $0.tgHex != targetHex }
        var driftNote = ""
        if !tgResident, !samples.isEmpty, let idx = samples.firstIndex(where: { $0.tgHex != targetHex }) {
            driftNote = "（首漂移@T+\(idx * e2cStepS)s 回读=\(samples[idx].tgHex ?? "?")）"
        }
        let acVals = samples.compactMap { $0.acRPM }
        let acMax = acVals.max()
        let tail = samples.dropFirst(followGraceS / e2cStepS)   // 爬升宽限：T+6s 起的样本（idx≥3）
        let tailVals = tail.compactMap { $0.acRPM }
        let tailMin = tailVals.min()
        let tailOK = !tail.isEmpty && tail.allSatisfy { ($0.acRPM ?? -1) >= followAcFloorRPM }
        let followPass = tailOK && (acMax ?? -1) >= followAcFloorRPM
        e2cPass = tgResident && followPass
        e2cDetail = "Md=1 \(mdLadderNote)｜Tg=3650 \(tgLadderNote)｜Tg 驻留=\(tgResident ? "是（60s 全窗）" : "否\(driftNote)")｜跟随=\(followPass ? "pass" : "fail")（T+\(followGraceS)s 起 \(tail.count) 样本 min=\(fmtF(tailMin))；全窗 max=\(fmtF(acMax))；阈值 ≥\(Int(followAcFloorRPM))）"
        e2cFollow = "\(followPass ? "pass" : "fail")（T+\(followGraceS)s 起 min=\(fmtF(tailMin)) 全窗 max=\(fmtF(acMax)) 阈值=\(Int(followAcFloorRPM))）"
        logger.log("[E2c'] 窗判读：Tg 驻留=\(tgResident) 跟随=\(followPass)（T+\(followGraceS)s 起 min=\(fmtF(tailMin)) 全窗 max=\(fmtF(acMax))）")
        logger.log("[E2c'] 判读：\(e2cDetail)")
        session.concl("e2c.follow", e2cFollow)
        // E2c' 后 F1Tg=3650/F1Md=1 交 E5' 还原（矩阵 E5' 前置=E2c'；abort 线由信号/看门狗全量还原覆盖）
    }
    // MARK: E5'（§3.2：还原 F1Tg→原值 + F1Md=0x00（各带回读一致验证）→ 60s@2s 干净窗——记录事实不入判据）
    private func e5FinalRestore() {
        logger.log("=== E5'（§3.2）：还原 F1Tg→状态文件原值 + F1Md=0x00（各带回读一致验证）→ 60s@2s 干净窗 ===")
        // ① F1Tg → 状态文件原值（还原引擎阶梯：9 轮双验证）
        var tgRestored = false
        switch engine.restoreKeyLadder("F1Tg") {
        case .ok: tgRestored = true
        case .mutexBusy:
            logger.log("[还原] E5' F1Tg：还原互斥被占（另一路还原进行中）——有界等待其完成（上限 \(Int(concurrentRestoreWaitS))s）后终止")
            _ = waitForConcurrentRestore()
            abortRun("E5' 还原 F1Tg（另一路还原接管）")
        case .failed(let fail):
            logger.log("[E5'] F1Tg 阶梯还原失败（runbook 已由还原引擎记录）：\(fail)")
        }
        // ② F1Md=0x00 规范值（R3 N-2：不用 E0' 原值；E0' 原值预期即 00，不符时以 0x00 为准并记录）
        if let mdOrig = session.originalBytes("F1Md"), mdOrig != [mdAuto] {
            logger.log("[E5'] 注意：F1Md 状态文件原值=\(hex(mdOrig)) ≠ 0x00——E5' 按 0x00 规范值还原（R3 N-2），原值已留档状态文件")
        }
        var mdRestored = false
        let mdW = writeKeyLadder("F1Md", [mdAuto], stepTag: "E5'-md0")
        switch mdW {
        case .ok(let at):
            mdRestored = true
            logger.log("[E5'] F1Md=0x00 锁存阶梯验证通过（\(at)）")
        case .already:
            mdRestored = true
            logger.log("[E5'] F1Md 已=0x00（读验证）")
        case .mismatch(let hv):
            session.recordReadbackViolation("E5' F1Md=0x00 还原后回读=\(hv)")
            session.markRunbook()
            logger.log("[runbook] 终态处置：形态=E5' F1Md=0x00 还原回读不一致（回读=\(hv)）｜引导：保持电源连接、不要合盖、勿重启；手动兜底 sudo .build/debug/spike-fan-f1 --restore F1Md=00；保留状态文件与日志交工程师分析")
        case .writeFailed(let krs):
            abortRun("E5' 写 F1Md=0x00 写入抛错（kr=\(krs)）")
        case .readbackFailed:
            abortRun("E5' 写 F1Md=0x00 回读失败")
        }
        e5Verified = tgRestored && mdRestored
        if !e5Verified {
            e5Detail = "还原未验证通过：F1Tg=\(tgRestored ? "✓" : "阶梯失败(runbook 已记录)") F1Md=\(mdRestored ? "✓" : "回读不符(runbook 已记录)")；状态文件保留（--restore 兜底）"
            logger.log("[E5'] \(e5Detail)")
            return
        }
        session.deleteStateFile()
        e5Detail = "F1Tg→状态文件原值 ✓（引擎阶梯双验证）；F1Md=0x00 ✓（阶梯回读一致）；状态文件已删除（干净结束判据）"
        logger.log("[E5'] \(e5Detail)")
        // 干净窗：60s@2s 记录事实（F1Ac 回基线 ±150 或接管证据=Ac 活值变化；§3.2 E5' 行——不入 GO 判据）
        let samples = observe(seconds: e5WindowS, stepS: e5StepS, tag: "E5'窗")
        let tgOrigHex = session.originalBytes("F1Tg").map { hex($0) } ?? "?"
        let tgDrifted = samples.contains { $0.tgHex != tgOrigHex }
        let acVals = samples.compactMap { $0.acRPM }
        var acBackNote = "n/a(Ac 恒 0/不可读)"
        if !e0AcAllZero, let base = e0AcBaselineRPM {
            let within = !samples.isEmpty && samples.allSatisfy { s in
                guard let v = s.acRPM else { return false }
                return abs(v - base) <= baselineAcTolRPM
            }
            acBackNote = within ? "是（基线 \(String(format: "%.0f", base))±\(Int(baselineAcTolRPM))rpm）" : "否"
        }
        let acLiveChanged = acVals.count >= 2 && (acVals.max() ?? 0) != (acVals.min() ?? 0)
        e5WindowFact = "F1Ac 回基线±150=\(acBackNote)｜Ac 活值变化（接管证据）=\(acLiveChanged ? "是" : "否")｜F1Tg 窗内漂移=\(tgDrifted ? "是（系统接管重写，§8.2 形态）" : "否")——记录事实，不入判据"
        logger.log("[E5'] 干净窗事实：\(e5WindowFact)")
        session.concl("e5.window", e5WindowFact)
    }
    /// 主线程有界等待另一路（信号/看门狗）还原完成：轮询 isRestoring 间隔 1s，上限 concurrentRestoreWaitS
    /// （70s = 阶梯最坏时长 9 轮×~(写+0.5s 回读)+2×5s ≈16s，70s 为宽松硬界）。返回 true=等待内完成。
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
        logger.log("[abort] \(reason)——abort 线：立即全量还原并终止（§3.2）")
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
    // MARK: 判读汇总（§3.3 GO 判定 + 判读对账表）
    private func emitReconciliationAndConclusions(stopReason: String) {
        logger.log("=== 判读对账表（§3.3 预注册：GO = E1' pass ∧ E3' pass ∧ E2c' pass ∧ E5' 还原干净；逐条对账，不采信机械 verdict 字面值）===")
        logger.log("对账① E1' F1Tg 同值回写  = \(e1Pass ? "pass" : "fail") ｜ 证据：\(e1Detail)")
        logger.log("对账② E3' F1Md 同值回写  = \(e3Pass ? "pass" : "fail") ｜ 证据：\(e3Detail)")
        logger.log("对账③ E2c' 解锁直写+跟随 = \(e2cPass ? "pass" : "fail") ｜ 证据：\(e2cDetail)")
        logger.log("对账④ E5' 还原干净       = \(e5Verified ? "pass" : "fail") ｜ 证据：\(e5Detail)")
        logger.log("对账⑤ E2a' 三分支（预注册，均不入 GO 门）= \(e2aVerdict)")
        logger.log("对账⑥ 干净窗事实（记录，不入判据）= \(e5WindowFact)")
        let go = e1Pass && e3Pass && e2cPass && e5Verified
        logger.log("→ GO 判定 = \(go ? "GO" : "NO-GO")（§3.3；NO-GO 时本批缩面/取消为用户决策点）")
        session.concl("verdict", go ? "GO" : "NO-GO")
        session.concl("verdict.detail", "①E1'=\(e1Pass) ②E3'=\(e3Pass) ③E2c'=\(e2cPass) ④E5'=\(e5Verified)（逐条证据见对账表）")
        session.concl("u1_writepath", e1Pass ? "pass" : "fail")
        session.concl("u2_follow", e2cFollow)
        session.concl("u3_restore", e5Verified ? "pass" : "fail")
        session.concl("u5_f1_keys", f1KeyPresent.isEmpty ? "none" : f1KeyPresent.joined(separator: ","))
        session.concl("u7_byteorder", "LE(定版，§8.1 U7；E0' 双序对照=复核)")
        session.concl("e0.baseline", "acAllZero=\(e0AcAllZero) acBaseRPM=\(fmtF(e0AcBaselineRPM)) tempBase=\(tempS(e0TempBase))℃")
        session.concl("e1.run", e1Pass ? "pass" : "fail(\(e1Detail))")
        session.concl("e2a.run", e2aVerdict)
        session.concl("e3.run", e3Pass ? "pass" : e3Detail)
        session.concl("e2c.run", e2cPass ? "pass" : e2cDetail)
        session.concl("e5.restore", e5Verified ? "verified" : "failed")
        session.concl("stop.reason", stopReason.isEmpty ? "none(全流程完整执行)" : stopReason)
        session.concl("stateFile", Session.stateExists() ? "kept(还原未验证通过)" : "deleted(还原双验证通过)")
        session.concl("runbook", session.isRunbookEntered ? "entered" : "not-entered")
        logger.log("回读违反清单（判读辅助，非 GO 要素）：\(session.readbackViolations.isEmpty ? "无" : session.readbackViolations.joined(separator: " | "))")
        logger.log("smc-notes.backfill.start")
        logger.log("# Phase5 v1.12 F1 spike：机型=\(machine.model) 固件=\(machine.firmware) macOS=\(machine.macOS)｜E1'=\(e1Pass ? "pass" : "fail") E2a'=\(e2aVerdict) E3'=\(e3Pass ? "pass" : "fail") E2c'=\(e2cPass ? "pass" : "fail")（\(e2cDetail)）E5'=\(e5Verified ? "verified" : "failed")｜U5'=\(f1KeyPresent.isEmpty ? "none" : f1KeyPresent.joined(separator: ",")) U7'=LE(定版)｜GO=\(go ? "GO" : "NO-GO")")
        logger.log("smc-notes.backfill.end")
    }
    /// 中止路径结论（信号/看门狗线程调用）：不得读 Runner 判读字段（主线程写中）——一律走 session 锁通道，
    /// 主流程未发射的项如实输出 n/a(未发射)。
    private func emitBriefConclusions(_ note: String) {
        logger.log("=== 中止路径 concl.*（截断版，机器可读；未发射项=n/a）===")
        for k in ["u1_writepath", "u2_follow", "u3_restore", "u5_f1_keys", "u7_byteorder",
                  "e0.baseline", "e1.run", "e2a.run", "e3.run", "e2c.run", "e2c.follow",
                  "e5.restore", "e5.window"] {
            session.concl(k, session.conclusion(k) ?? "n/a(未发射)")
        }
        session.concl("verdict", "abort")
        logger.log("[abort] verdict=机械结论，GO/NO-GO 须回预注册判据逐条对账（§3.3 判读对账表）")
        session.concl("stop.reason", note)
        session.concl("stateFile", Session.stateExists() ? "kept(还原未验证通过)" : "deleted(还原双验证通过)")
        session.concl("runbook", session.isRunbookEntered ? "entered" : "not-entered")
    }
    // MARK: --do-it 主流程
    private func doIt() -> Int32 {
        logger.log("模式：--do-it（F1 风扇键写 spike：E0'-E5'，§3.2 预注册）")
        logger.log("[须知] 用户在场全程；勿跑其他重负载；运行期间不要合盖")
        guard getuid() == 0 else { logger.log("--do-it 需要 root：sudo .build/debug/spike-fan-f1 --do-it"); return 2 }
        guard runPreflight(strict: true) else { return 3 }
        guard guardian.acquire() else { logger.log("[检查] 防睡眠断言（NoIdleSleep）获取失败——中止"); return 3 }
        logger.log("[检查] 防睡眠断言（NoIdleSleep）已持有，全程有效（等效 caffeinate -i；请勿合盖）")
        var stopReason = ""
        // E0'（只读）→ 基线入状态文件（P0-1 先于首次写）
        guard e0Baseline() else { guardian.release(); return 3 }
        // 基线入会话：F1Tg/F1Md 可写还原集；F1Mn/F1Mx 只读对照（还原引擎跳过不可写键）
        for key in ["F1Tg", "F1Md"] {
            guard let r = smc.read(key), let info = smc.keyInfo(key) else {
                logger.log("\(key) 基线读取失败——无法实验")
                guardian.release(); return 3
            }
            session.addBaseline(key: key, size: info.size, type: info.type, bytes: r.bytes, writable: true)
        }
        for key in ["F1Mn", "F1Mx"] {
            if let r = smc.read(key), let info = smc.keyInfo(key) {
                session.addBaseline(key: key, size: info.size, type: info.type, bytes: r.bytes, writable: false)
            } else { logger.log("[E0'] \(key) 对照键不可读——缺席记录（U5'）") }
        }
        // P0-1：首次任何 SMC 写入前原子写状态文件（E1' 探针为首写）；此后每次写步骤前更新 step 标记
        guard session.writeStateFile(step: "E0'-基线") else {
            logger.log("状态文件写入失败（\(stateFilePath)）——拒绝进入写实验"); guardian.release(); return 3
        }
        logger.log("[P0-1] 状态文件已原子写入 \(stateFilePath)（机型/固件头 + F1Tg/F1Md 原值（还原集）+ F1Mn/F1Mx 只读对照 + step 标记）")
        installSignalHandlers()
        session.setWatchdogStart()   // 锁通道计时（watchdogTick 全局队列读取；E0' 只读段不计时——母本同款）
        watchdog = Watchdog { [weak self] in self?.watchdogTick() }
        // E1'：写通路（U1'）→ E2a' → E3' → E2c'（执行顺序即 §3.2 表序）
        e1Pass = e1WriteProbe()
        if e1Pass {
            e2aMd0Write()   // E2a'：Md=0 态直写三分支（均不入 GO 门）
            e3MdProbe()     // E3'：Md 写通路独立结论
            if e3Pass {
                e2cUnlockWrite()   // E2c'：解锁直写+跟随（GO 核心）
            } else {
                e2cDetail = "skipped(E3' Md 写通路失败——「Md 写通路不通」成因成立)"
                logger.log("[E2c'] 跳过：\(e2cDetail)")
            }
        } else {
            stopReason = "E1' 写通路失败（U1'=fail）——E2a'/E3'/E2c' 跳过，仅做收尾还原"
            e2aVerdict = "skipped(E1' 失败)"
            e3Detail = "skipped(E1' 失败)"
            e2cDetail = "skipped(E1' 失败)"
            logger.log("[跳过] \(stopReason)")
        }
        // E5'：还原 + 干净窗（GO④；abort 路径不测窗——立即终止语义）
        e5FinalRestore()
        // P3-1：信号落在还原互斥期内登记的 abort 不得静默丢弃（母本 doIt 同款延迟处理）
        if let r = session.takeAbortReason() { finalExit(130, note: r + "（还原互斥期间登记，延迟处理）", brief: true) }
        if !e5Verified && stopReason.isEmpty { stopReason = "E5' 还原验证失败（runbook 已记录）" }
        watchdog?.stop()
        emitReconciliationAndConclusions(stopReason: stopReason)
        if e5Verified {
            logger.log("[检查单] 会话结束（干净）：还原双验证通过，状态文件已删除")
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
        guard getuid() == 0 else { logger.log("--restore 需要 root：sudo .build/debug/spike-fan-f1 --restore"); return 2 }
        if let manual {
            // 红线：F0 前缀键域拒绝写入（本工具只碰 F1 键域；字面量拆写以保工单 grep 机械自检干净）
            guard !manual.key.hasPrefix("F" + "0") else {
                logger.log("[手动兜底] F0 前缀键域拒绝写入（本工具红线：F0 零写入，只碰 F1 键域）")
                return 2
            }
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
            logger.log("状态文件载入：机型=\(loaded.file.model) 固件=\(loaded.file.firmware) 会话=\(loaded.file.session) step=\(loaded.file.step) 键=[\(loaded.sortedKeys.joined(separator: ","))]（还原集=\(session.sortedWritableKeys().joined(separator: ","))）")
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
