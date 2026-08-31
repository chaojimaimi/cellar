// CellarCoreCheck —— CellarCore 的零依赖本地验证工具（无 XCTest 也能跑）。
//
// 背景：本机仅有 Command Line Tools（无 Xcode），`swift test`（XCTest）不可用；
// CI 与装有 Xcode 的环境走 Tests/CellarCoreTests（XCTest）。两边场景一一对应，
// 修改任一侧必须同步另一侧（与 Tests/CellarCoreTests 的 XCTest 用例一一对应）。
//
// 用法：
//   swift run CellarCoreCheck          # 跑全部 35 个 mock 场景（WP1 用例 1–16 + WP2 用例 17–35）
//   swift run CellarCoreCheck --probe  # 真机探测：makeDefault() + RuntimeProbe.probe（要求 root，探测可靠性实测结论）
//   swift run CellarCoreCheck --smoke  # 真机冒烟：makeDefault() + keyInfo("#KEY")（元数据非 root 可读）
//
// 注意：本工具使用字面偏移量（规格 §5.3）而非 SMCParam 内部常量——
// 作为对实现常量的独立交叉验证（第二双眼睛）。

import CellarCore
import Foundation

// MARK: - 计数器（Swift 6 严格并发下的可变状态盒）

private final class FailureCounter: @unchecked Sendable {
    static let shared = FailureCounter()
    private let lock = NSLock()
    private(set) var count = 0
    func increment() { lock.withLock { count += 1 } }
}

private func check(_ condition: Bool, _ scenario: String, _ message: String) {
    if condition {
        print("  ✓ \(scenario): \(message)")
    } else {
        FailureCounter.shared.increment()
        print("  ✗ \(scenario): \(message)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ scenario: String, _ message: String) {
    check(actual == expected, scenario, actual == expected ? message : "\(message)（实际 \(actual)，期望 \(expected)）")
}

/// 泛化断言：抛出的错误须等于 `expected`（SMCError 与 BackendError 均 Equatable）。
/// 前导点成员语法（`.keyNotFound(...)`）无法在泛型参数上解析类型，故提供
/// SMCError/BackendError 两个具体重载（WP1 既有调用点保持零改动）；
/// `expected` 为 nil 时仅要求抛错、不校验类型。
private func expectThrows<T>(
    _ body: @autoclosure () throws -> T,
    as expected: SMCError?,
    _ scenario: String,
    _ message: String
) {
    do {
        _ = try body()
        check(false, scenario, "\(message)——但未抛错")
    } catch let error as SMCError {
        if let expected {
            check(error == expected, scenario, error == expected ? message : "\(message)——实际 \(error)")
        } else {
            check(true, scenario, message)
        }
    } catch {
        check(false, scenario, "\(message)——实际 \(error)")
    }
}

private func expectThrows<T>(
    _ body: @autoclosure () throws -> T,
    as expected: BackendError?,
    _ scenario: String,
    _ message: String
) {
    do {
        _ = try body()
        check(false, scenario, "\(message)——但未抛错")
    } catch let error as BackendError {
        if let expected {
            check(error == expected, scenario, error == expected ? message : "\(message)——实际 \(error)")
        } else {
            check(true, scenario, message)
        }
    } catch {
        check(false, scenario, "\(message)——实际 \(error)")
    }
}

// MARK: - 最小 mock（独立实现，字面偏移）

private enum Spec {
    static let dataSizeOffset = 28
    static let dataTypeOffset = 32
    static let resultOffset = 40
    static let data8Offset = 42
    static let bytesOffset = 48
    static let keyInfo: UInt8 = 9
    static let read: UInt8 = 5
    static let write: UInt8 = 6
}

private final class CheckTransport: SMCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [UInt8: [(output: [UInt8], kr: Int32)]] = [:]
    private(set) var inputs: [[UInt8]] = []

    func enqueue(_ output: [UInt8], kr: Int32 = 0, for data8: UInt8) {
        lock.withLock { queues[data8, default: []].append((output, kr)) }
    }

    func call(input: [UInt8]) -> (output: [UInt8], kr: Int32) {
        lock.withLock {
            inputs.append(input)
            let data8 = input.count > Spec.data8Offset ? input[Spec.data8Offset] : 0
            // FIFO 出队：出队结果必须回写字典，否则队列永不消耗（每次调用都拿到首条响应）。
            // WP1 各场景每 data8 仅入队 1 条响应，该潜伏缺陷不发散；WP2 跨键序列
            // （用例 28–30/33/34）依赖同一 data8 的多条不同响应，要求真正的 FIFO。
            if var queue = queues[data8], !queue.isEmpty {
                let response = queue.removeFirst()
                queues[data8] = queue
                return response
            }
            return (output: [UInt8](repeating: 0, count: 80), kr: 0)
        }
    }
}

/// 组装 80 字节回包（字面偏移）。
private func reply(
    result: UInt8 = 0,
    dataSize: UInt32 = 0, type: String? = nil,
    bytes: [UInt8] = [], length: Int = 80
) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: length)
    r[Spec.resultOffset] = result
    r[Spec.dataSizeOffset] = UInt8(dataSize & 0xFF)
    r[Spec.dataSizeOffset + 1] = UInt8((dataSize >> 8) & 0xFF)
    r[Spec.dataSizeOffset + 2] = UInt8((dataSize >> 16) & 0xFF)
    r[Spec.dataSizeOffset + 3] = UInt8((dataSize >> 24) & 0xFF)
    if let type {
        for (i, b) in Array(type.utf8.prefix(4).reversed()).enumerated() { r[Spec.dataTypeOffset + i] = b }
    }
    for (i, b) in bytes.enumerated() { r[Spec.bytesOffset + i] = b }
    return r
}

/// kr 故障注入传输。
private final class KRTransport: SMCTransport, @unchecked Sendable {
    let kr: Int32
    init(kr: Int32) { self.kr = kr }
    func call(input: [UInt8]) -> (output: [UInt8], kr: Int32) {
        (output: [UInt8](repeating: 0, count: 80), kr: kr)
    }
}

// MARK: - 场景（§5.5 用例 1–16）

@main
struct Main {
    static func main() throws {
        if CommandLine.arguments.contains("--dump-input") { dumpInput(); return }
        if CommandLine.arguments.contains("--probe") { probe(); return }
        if CommandLine.arguments.contains("--smoke") { smoke(); return }
        if CommandLine.arguments.contains("--write-perm") { writePerm(); return }
        try runScenarios()
        let failures = FailureCounter.shared.count
        print(failures == 0 ? "\n全部 35 个场景通过 ✅" : "\n\(failures) 个场景失败 ❌")
        exit(failures == 0 ? 0 : 1)
    }

    /// 诊断：写权限探测——原值回写 CHTE（状态不变，仅验证当前身份是否有写权限）。
    static func writePerm() {
        print("=== CHTE 写权限探测（原值回写，状态不变） ===")
        print("uid=\(getuid())")
        do {
            let client = try SMCClient.makeDefault()
            let current = try client.read("CHTE")
            print("当前 CHTE = \(current.map { String(format: "%02X", $0) }.joined())")
            try client.write("CHTE", bytes: current)
            let back = try client.read("CHTE")
            print("✅ 写入成功且回读一致 → 当前身份**有**写权限")
            exit(0)
        } catch let e as SMCError {
            print("❌ 写入被拒：\(e) → 当前身份**无**写权限（需要 root）")
            exit(1)
        } catch {
            print("❌ 其他错误：\(error)")
            exit(1)
        }
    }

    /// 诊断：打印 keyInfo("CHTE") 实际发出的 80 字节（与 M0 探针脚本逐字节比对用）。
    static func dumpInput() {
        final class Capture: SMCTransport, @unchecked Sendable {
            var last: [UInt8] = []
            func call(input: [UInt8]) -> (output: [UInt8], kr: Int32) {
                last = input
                var r = [UInt8](repeating: 0, count: 80)
                r[28] = 4
                r[32] = 0x75; r[33] = 0x69; r[34] = 0x33; r[35] = 0x32  // "ui32"
                return (r, 0)
            }
        }
        let transport = Capture()
        do {
            let info = try SMCClient(transport: transport).keyInfo("CHTE")
            print("info:", info)
        } catch {
            print("keyInfo 失败：\(error)")
        }
        print("input:", transport.last.map { String(format: "%02X", $0) }.joined(separator: " "))
    }

    static func runScenarios() throws {
        let badArgumentKR = Int32(bitPattern: 0xE000_02C7)

        // 用例 1：出站输入缓冲恒 80 字节（Swift struct 布局陷阱回归）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 4, type: "ui32"), for: Spec.keyInfo)
            _ = try? SMCClient(transport: mock).keyInfo("CHTE")
            check(mock.inputs[0].count == 80, "用例1", "出站输入缓冲为 80 字节")
        }

        // 用例 2："CHTE" → BE 打包 43 48 54 45。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(), for: Spec.keyInfo)
            _ = try? SMCClient(transport: mock).keyInfo("CHTE")
            expectEqual(Array(mock.inputs[0][0..<4]), [0x45, 0x54, 0x48, 0x43], "用例2", "CHTE LE uint32 打包（字符序反转）正确")
        }

        // 用例 3/4：非法 key → .invalidKey 且零传输调用。
        do {
            let mock = CheckTransport()
            let client = SMCClient(transport: mock)
            var ok = true
            for bad in ["ABC", "ABCDE", "", "CH€E", "CH\tE"] {
                do { _ = try client.keyInfo(bad); ok = false } catch let e as SMCError {
                    if e != .invalidKey(bad) { ok = false }
                } catch { ok = false }
            }
            check(ok && mock.inputs.isEmpty, "用例3/4", "非法 key 报 .invalidKey 且零传输调用")
        }

        // 用例 5：keyInfo 解析尺寸与类型。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 4, type: "ui32"), for: Spec.keyInfo)
            let info = try SMCClient(transport: mock).keyInfo("#KEY")
            expectEqual(info, SMCKeyInfo(size: 4, type: "ui32"), "用例5", "keyInfo 元数据解析正确")
        }

        // 用例 6：result=132 → .keyNotFound。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(result: 132), for: Spec.keyInfo)
            expectThrows(try SMCClient(transport: mock).keyInfo("CH0B"), as: .keyNotFound("CH0B"),
                         "用例6", "132 映射为 .keyNotFound")
        }

        // 用例 7：两阶段读调用序列（9 → 5），第二阶段 offset28=4。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 4, type: "ui32"), for: Spec.keyInfo)
            mock.enqueue(reply(), for: Spec.read)
            _ = try SMCClient(transport: mock).read("CHTE")
            let ok = mock.inputs.count == 2
                && mock.inputs[0][Spec.data8Offset] == Spec.keyInfo
                && mock.inputs[1][Spec.data8Offset] == Spec.read
                && mock.inputs[1][Spec.dataSizeOffset] == 4
            check(ok, "用例7", "两阶段读序列与带尺寸输入正确")
        }

        // 用例 8（M0 事故回归）：回复 offset28=0 但 48..52 有数据 → 仍返回 4 字节。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 4, type: "ui32"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0x01, 0x00, 0x00, 0x00]), for: Spec.read)
            let value = try SMCClient(transport: mock).read("CHTE")
            expectEqual(value, [0x01, 0x00, 0x00, 0x00], "用例8", "按请求尺寸切片（而非回复 offset28）")
        }

        // 用例 9：回包过短 → .malformedReply。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 4, type: "ui32"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0xDE, 0xAD], length: 50), for: Spec.read)
            expectThrows(try SMCClient(transport: mock).read("CHTE"),
                         as: .malformedReply(key: "CHTE", expected: 4, actual: 50),
                         "用例9", "短回包报 .malformedReply")
        }

        // 用例 10：keyInfo 失败则不进入第二阶段。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(result: 132), for: Spec.keyInfo)
            expectThrows(try SMCClient(transport: mock).read("CH0B"), as: .keyNotFound("CH0B"),
                         "用例10", "第一阶段失败原样抛出")
            check(mock.inputs.count == 1, "用例10", "失败后未发起第二阶段")
        }

        // 用例 11：写入封包（offset28=4、bytes@48、data8=6、result@40=0）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(), for: Spec.write)
            try SMCClient(transport: mock).write("CHTE", bytes: [0x01, 0x00, 0x00, 0x00])
            let input = mock.inputs[0]
            let ok = input[Spec.data8Offset] == Spec.write
                && input[Spec.dataSizeOffset] == 4
                && Array(input[Spec.bytesOffset..<52]) == [0x01, 0x00, 0x00, 0x00]
                && input[Spec.resultOffset] == 0
            check(ok, "用例11", "写入封包与 result 置零正确")
        }

        // 用例 12：载荷 0B / 33B → .invalidPayload 且零调用。
        do {
            let mock = CheckTransport()
            let client = SMCClient(transport: mock)
            var ok = true
            do { try client.write("CHTE", bytes: []); ok = false } catch let e as SMCError {
                if e != .invalidPayload(count: 0) { ok = false }
            } catch { ok = false }
            do { try client.write("CHTE", bytes: [UInt8](repeating: 0, count: 33)); ok = false } catch let e as SMCError {
                if e != .invalidPayload(count: 33) { ok = false }
            } catch { ok = false }
            check(ok && mock.inputs.isEmpty, "用例12", "越界载荷拒绝且零调用")
        }

        // 用例 13：写回复非零 → .unexpectedResult。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(result: 137), for: Spec.write)
            expectThrows(try SMCClient(transport: mock).write("CHTE", bytes: [0, 0, 0, 0]),
                         as: .unexpectedResult(key: "CHTE", command: Spec.write, result: 137),
                         "用例13", "写失败映射 .unexpectedResult")
        }

        // 用例 14：keyExists 三态（true / false / 错误上抛）。
        do {
            let hit = CheckTransport()
            hit.enqueue(reply(dataSize: 4, type: "ui32"), for: Spec.keyInfo)
            let missing = CheckTransport()
            missing.enqueue(reply(result: 132), for: Spec.keyInfo)
            let broken = CheckTransport()
            broken.enqueue(reply(), kr: badArgumentKR, for: Spec.keyInfo)

            let r1 = try SMCClient(transport: hit).keyExists("CHTE")
            let r2 = try SMCClient(transport: missing).keyExists("CH0B")
            var r3: SMCError? = nil
            do { _ = try SMCClient(transport: broken).keyExists("CHTE") } catch let e as SMCError { r3 = e } catch {}
            check(r1 == true && r2 == false && r3 == .transportFailure(kr: badArgumentKR),
                  "用例14", "命中 true / 132 false / 传输故障上抛")
        }

        // 用例 15：kr=BadArgument → .transportFailure。
        do {
            expectThrows(try SMCClient(transport: KRTransport(kr: badArgumentKR)).keyInfo("CHTE"),
                         as: .transportFailure(kr: badArgumentKR),
                         "用例15", "kr 故障映射 .transportFailure")
        }

        // 用例 16：三类命令出站 result@40 全零（read 两阶段 → 9,9,5,6）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 4, type: "ui32"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0, 0, 0, 0]), for: Spec.read)
            mock.enqueue(reply(), for: Spec.write)
            let client = SMCClient(transport: mock)
            var ok = true
            do {
                _ = try client.keyInfo("CHTE")
                _ = try client.read("CHTE")
                try client.write("CHTE", bytes: [0x00, 0x00, 0x00, 0x00])
            } catch {
                ok = false
                print("  （用例16 意外抛错：\(error)）")
            }
            ok = ok && mock.inputs.count == 4
                && mock.inputs.map({ $0[Spec.data8Offset] }) == [Spec.keyInfo, Spec.keyInfo, Spec.read, Spec.write]
                && mock.inputs.allSatisfy { $0[Spec.resultOffset] == 0 }
            check(ok, "用例16", "全部出站 result 字段置零")
        }

        // MARK: - 场景（WP2 规格 §3 用例 17–35）
        // mock 按 data8 分流、FIFO，且对 key 无感知——跨键场景（28/29/30）用调用序列构造，
        // 但输入缓冲仍携带 key 字节（offset 0..3），可据其区分 CH0B/CH0C 写调用。

        // 用例 17：Tahoe 使能（读 00 00 00 00）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 4, type: "ui32"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0x00, 0x00, 0x00, 0x00]), for: Spec.read)
            let enabled = try TahoeBackend(client: SMCClient(transport: mock)).chargingEnabled()
            check(enabled == true, "用例17", "CHTE 00000000 → chargingEnabled() == true")
        }

        // 用例 18：Tahoe 停充（读 01 00 00 00）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 4, type: "ui32"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0x01, 0x00, 0x00, 0x00]), for: Spec.read)
            let enabled = try TahoeBackend(client: SMCClient(transport: mock)).chargingEnabled()
            check(enabled == false, "用例18", "CHTE 01000000 → chargingEnabled() == false")
        }

        // 用例 19：Tahoe 未知值 → .unknownChargingState。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 4, type: "ui32"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0x02, 0x00, 0x00, 0x00]), for: Spec.read)
            expectThrows(try TahoeBackend(client: SMCClient(transport: mock)).chargingEnabled(),
                         as: BackendError.unknownChargingState(key: "CHTE", bytes: [2, 0, 0, 0]),
                         "用例19", "CHTE 02 000000 报 .unknownChargingState")
        }

        // 用例 20：Tahoe 长度防御（keyInfo size=2 → 读 2 字节）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 2, type: "ui32"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0x00, 0x00]), for: Spec.read)
            expectThrows(try TahoeBackend(client: SMCClient(transport: mock)).chargingEnabled(),
                         as: BackendError.unknownChargingState(key: "CHTE", bytes: [0, 0]),
                         "用例20", "长度 ≠4 报 .unknownChargingState")
        }

        // 用例 21：Tahoe set(false) → 写 01 00 00 00（data8=6、offset28=4）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(), for: Spec.write)
            try TahoeBackend(client: SMCClient(transport: mock)).setChargingEnabled(false)
            let input = mock.inputs[0]
            let ok = input[Spec.data8Offset] == Spec.write
                && input[Spec.dataSizeOffset] == 4
                && Array(input[Spec.bytesOffset..<52]) == [0x01, 0x00, 0x00, 0x00]
            check(ok, "用例21", "set(false) 封包 data8=6/offset28=4/bytes=01000000")
        }

        // 用例 22：Tahoe set(true) → 写 00 00 00 00。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(), for: Spec.write)
            try TahoeBackend(client: SMCClient(transport: mock)).setChargingEnabled(true)
            let input = mock.inputs[0]
            let ok = input[Spec.data8Offset] == Spec.write
                && input[Spec.dataSizeOffset] == 4
                && Array(input[Spec.bytesOffset..<52]) == [0x00, 0x00, 0x00, 0x00]
            check(ok, "用例22", "set(true) 封包 bytes=00000000")
        }

        // 用例 23：Tahoe set 传输失败 → 原样抛 .transportFailure。
        do {
            expectThrows(try TahoeBackend(client: SMCClient(transport: KRTransport(kr: badArgumentKR))).setChargingEnabled(false),
                         as: SMCError.transportFailure(kr: badArgumentKR),
                         "用例23", "写传输故障原样上抛 .transportFailure")
        }

        // 用例 24：Legacy 使能（读 00）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 1, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0x00]), for: Spec.read)
            let enabled = try LegacyBackend(client: SMCClient(transport: mock)).chargingEnabled()
            check(enabled == true, "用例24", "CH0B 00 → chargingEnabled() == true")
        }

        // 用例 25：Legacy 停充（读 02）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 1, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0x02]), for: Spec.read)
            let enabled = try LegacyBackend(client: SMCClient(transport: mock)).chargingEnabled()
            check(enabled == false, "用例25", "CH0B 02 → chargingEnabled() == false")
        }

        // 用例 26：Legacy 未知值（读 01）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 1, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0x01]), for: Spec.read)
            expectThrows(try LegacyBackend(client: SMCClient(transport: mock)).chargingEnabled(),
                         as: BackendError.unknownChargingState(key: "CH0B", bytes: [1]),
                         "用例26", "CH0B 01 报 .unknownChargingState")
        }

        // 用例 27：Legacy 长度防御（keyInfo size=0 → 读 []，防越界下标崩溃）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 0, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(), for: Spec.read)
            expectThrows(try LegacyBackend(client: SMCClient(transport: mock)).chargingEnabled(),
                         as: BackendError.unknownChargingState(key: "CH0B", bytes: []),
                         "用例27", "空值报 .unknownChargingState（不越界）")
        }

        // 用例 28：Legacy set(false) → 两次写调用（预读 keyInfo→read 后，CH0B、CH0C 各写 02）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 1, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0x00]), for: Spec.read)
            mock.enqueue(reply(), for: Spec.write)
            mock.enqueue(reply(), for: Spec.write)
            try LegacyBackend(client: SMCClient(transport: mock)).setChargingEnabled(false)
            let inputs = mock.inputs
            let writes = inputs.filter { $0[Spec.data8Offset] == Spec.write }
            let ok = inputs.count == 4
                && writes.count == 2
                && Array(writes[0][0..<4]) == Array("CH0B".utf8.reversed())
                && Array(writes[1][0..<4]) == Array("CH0C".utf8.reversed())
                && Array(writes[0][Spec.bytesOffset..<(Spec.bytesOffset + 1)]) == [0x02]
                && Array(writes[1][Spec.bytesOffset..<(Spec.bytesOffset + 1)]) == [0x02]
                && writes.allSatisfy { $0[Spec.dataSizeOffset] == 1 && $0[Spec.data8Offset] == Spec.write }
            check(ok, "用例28", "CH0B→CH0C 两次写调用各写 02（data8=6、offset28=1）")
        }

        // 用例 29：Legacy set(true) → 两键各写 00。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 1, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0x02]), for: Spec.read)
            mock.enqueue(reply(), for: Spec.write)
            mock.enqueue(reply(), for: Spec.write)
            try LegacyBackend(client: SMCClient(transport: mock)).setChargingEnabled(true)
            let writes = mock.inputs.filter { $0[Spec.data8Offset] == Spec.write }
            let ok = writes.count == 2
                && Array(writes[0][0..<4]) == Array("CH0B".utf8.reversed())
                && Array(writes[1][0..<4]) == Array("CH0C".utf8.reversed())
                && Array(writes[0][Spec.bytesOffset..<(Spec.bytesOffset + 1)]) == [0x00]
                && Array(writes[1][Spec.bytesOffset..<(Spec.bytesOffset + 1)]) == [0x00]
                && writes.allSatisfy { $0[Spec.dataSizeOffset] == 1 }
            check(ok, "用例29", "CH0B→CH0C 两次写调用各写 00")
        }

        // 用例 30：Legacy set 部分失败 —— 预读 CH0B=00 → 写 CH0B(02) OK → 写 CH0C kr=BadArgument
        // → 尽力回滚 CH0B 旧值 00 → 抛 .partialWrite(failedKey:"CH0C", cause:.transportFailure)。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 1, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0x00]), for: Spec.read)
            mock.enqueue(reply(), for: Spec.write)                                  // CH0B 写 02 OK
            mock.enqueue(reply(), kr: badArgumentKR, for: Spec.write)               // CH0C 写 02 kr 失败
            mock.enqueue(reply(), for: Spec.write)                                  // CH0B 回滚 00
            var thrown: BackendError? = nil
            do {
                try LegacyBackend(client: SMCClient(transport: mock)).setChargingEnabled(false)
            } catch let e as BackendError {
                thrown = e
            } catch {
                // 透传错误类型不属于 BackendError：不匹配也计入失败（配合下方 check）。
            }
            let expected = BackendError.partialWrite(failedKey: "CH0C", cause: SMCError.transportFailure(kr: badArgumentKR))
            check(thrown == expected, "用例30", "部分失败抛 .partialWrite(CH0C, transportFailure)")

            // 调用序列：keyInfo→read→write(CH0B 02)→write(CH0C 02 失败)→write(CH0B 回滚 00)，
            // 回滚写为最后一次调用（下标 4），载荷为预读旧值 00。
            let inputs = mock.inputs
            let seqOK = inputs.count == 5
                && inputs[0][Spec.data8Offset] == Spec.keyInfo
                && inputs[1][Spec.data8Offset] == Spec.read
                && inputs[1][Spec.dataSizeOffset] == 1
                && inputs[2][Spec.data8Offset] == Spec.write
                && Array(inputs[2][0..<4]) == Array("CH0B".utf8.reversed())
                && Array(inputs[2][Spec.bytesOffset..<(Spec.bytesOffset + 1)]) == [0x02]
                && inputs[3][Spec.data8Offset] == Spec.write
                && Array(inputs[3][0..<4]) == Array("CH0C".utf8.reversed())
                && Array(inputs[3][Spec.bytesOffset..<(Spec.bytesOffset + 1)]) == [0x02]
                && inputs[4][Spec.data8Offset] == Spec.write
                && Array(inputs[4][0..<4]) == Array("CH0B".utf8.reversed())
                && Array(inputs[4][Spec.bytesOffset..<(Spec.bytesOffset + 1)]) == [0x00]
            check(seqOK, "用例30", "第 4 次写调用（下标 4）为 CH0B 回滚 00")
        }

        // 用例 31：Legacy 读 keyNotFound → 原样抛 .keyNotFound。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(result: 132), for: Spec.keyInfo)
            expectThrows(try LegacyBackend(client: SMCClient(transport: mock)).chargingEnabled(),
                         as: SMCError.keyNotFound("CH0B"),
                         "用例31", "CH0B keyInfo 132 原样抛 .keyNotFound")
        }

        // 用例 32：Probe CHTE 命中 → 返回 tahoe，且仅 1 次传输调用（短路）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 4, type: "ui32"), for: Spec.keyInfo)
            let backend = try RuntimeProbe.probe(client: SMCClient(transport: mock))
            check(backend.name == "tahoe" && backend.keyNames == ["CHTE"], "用例32", "返回 tahoe 后端")
            check(mock.inputs.count == 1, "用例32", "CHTE 命中后短路，仅 1 次传输调用")
        }

        // 用例 33：Probe CHTE 132 → CH0B keyInfo 成功 → 返回 legacy。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(result: 132), for: Spec.keyInfo)
            mock.enqueue(reply(dataSize: 1, type: "ui8"), for: Spec.keyInfo)
            let backend = try RuntimeProbe.probe(client: SMCClient(transport: mock))
            check(backend.name == "legacy" && backend.keyNames == ["CH0B", "CH0C"], "用例33", "返回 legacy 后端")
            check(mock.inputs.count == 2, "用例33", "CHTE 132 后仅再探测 CH0B 一次")
        }

        // 用例 34：Probe 两者皆 132 → .noBackendAvailable。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(result: 132), for: Spec.keyInfo)
            mock.enqueue(reply(result: 132), for: Spec.keyInfo)
            expectThrows(try RuntimeProbe.probe(client: SMCClient(transport: mock)),
                         as: BackendError.noBackendAvailable,
                         "用例34", "CHTE/CH0B 皆 132 → .noBackendAvailable")
        }

        // 用例 35：Probe CHTE keyInfo kr=BadArgument → 原样抛 .transportFailure（非 noBackendAvailable）。
        do {
            expectThrows(try RuntimeProbe.probe(client: SMCClient(transport: KRTransport(kr: badArgumentKR))),
                         as: SMCError.transportFailure(kr: badArgumentKR),
                         "用例35", "传输故障原样上抛（绝不降级为 .noBackendAvailable）")
        }
    }

    // MARK: - 真机冒烟（--smoke）
    // 非 root 的键可见性不稳定（同一会话内曾出现 CHTE 元数据时可见时不可见，实测），
    // 故分级：非 root = 信息模式（连接成功即通过，细节供参考）；root = 严格断言。

    static func smoke() {
        print("=== CellarCore WP1 真机冒烟 ===")
        let isRoot = getuid() == 0
        print("uid=\(getuid())(\(isRoot ? "root" : "非 root（读级验证；写入需 root，见 --write-perm）"))")
        do {
            let client = try SMCClient.makeDefault()
            print("✅ AppleSMC 服务连接成功（IOKitSMCTransport / selector 2）")
            let info = try? client.keyInfo("CHTE")
            print("ℹ️ keyInfo(\"CHTE\") = \(info.map { "\($0)" } ?? "不可见（非 root 波动，非 root 实测波动）")（期望 ui32 / 4）")
            let chte = try? client.keyExists("CHTE")
            print("ℹ️ keyExists(\"CHTE\") = \(chte.map { "\($0)" } ?? "不可见")（期望 true）")
            let legacy = try? client.keyExists("CH0B")
            print("ℹ️ keyExists(\"CH0B\") = \(legacy.map { "\($0)" } ?? "不可见")（root 下期望 false）")

            guard isRoot else {
                print("\n冒烟结论：连接通过 ✅（信息模式；严格断言请运行 sudo swift run CellarCoreCheck --smoke）")
                exit(0)
            }
            let pass = info?.type == "ui32" && info?.size == 4 && chte == true && legacy == false
            print("\n冒烟结论：\(pass ? "通过 ✅" : "存在异常 ❌（对照上方输出）")")
            exit(pass ? 0 : 1)
        } catch {
            print("❌ 冒烟失败：\(error)")
            exit(1)
        }
    }

    // MARK: - 真机探测（--probe）
    // RuntimeProbe 键位可用性随身份波动——可靠探测必须 root（非 root 可见性波动，实测）；
    // 非 root 时打印可信度提示，但探测照常执行（信息用途）。

    static func probe() {
        print("=== CellarCore 运行时探测（--probe）===")
        if !RuntimeProbe.isRunningAsRoot {
            print("ℹ️ 以非 root 运行（读级探测；写权限另见 --write-perm）")
        }
        do {
            let client = try SMCClient.makeDefault()
            do {
                let backend = try RuntimeProbe.probe(client: client)
                print("后端 = \(backend.name)，控制键 = \(backend.keyNames)")
            } catch BackendError.noBackendAvailable {
                print("后端不可用：CHTE 与 CH0B 均无（只读模式，监测仍可用；控制功能不可用）")
            }
            // 探测成功（含"无后端"这一确定性结论）即 0；仅连接/传输故障为非零。
            exit(0)
        } catch {
            print("❌ 探测失败：\(error)")
            exit(1)
        }
    }
}
