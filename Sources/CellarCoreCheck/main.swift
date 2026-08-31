// CellarCoreCheck —— CellarCore 的零依赖本地验证工具（无 XCTest 也能跑）。
//
// 背景：本机仅有 Command Line Tools（无 Xcode），`swift test`（XCTest）不可用；
// CI 与装有 Xcode 的环境走 Tests/CellarCoreTests（XCTest）。两边场景一一对应，
// 修改任一侧必须同步另一侧（与 Tests/CellarCoreTests 的 XCTest 用例一一对应）。
//
// 用法：
//   swift run CellarCoreCheck          # 跑全部 16 个 mock 场景
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

private func expectThrows<T>(_ body: @autoclosure () throws -> T, as expected: SMCError?, _ scenario: String, _ message: String) {
    do {
        _ = try body()
        check(false, scenario, "\(message)——但未抛错")
    } catch {
        if let expected {
            check((error as? SMCError) == expected, scenario, (error as? SMCError) == expected ? message : "\(message)——实际 \(error)")
        } else {
            check(true, scenario, message)
        }
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
            var queue = queues[data8] ?? []
            return queue.isEmpty
                ? (output: [UInt8](repeating: 0, count: 80), kr: 0)
                : queue.removeFirst()
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
        for (i, b) in Array(type.utf8.prefix(4)).enumerated() { r[Spec.dataTypeOffset + i] = b }
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
        if CommandLine.arguments.contains("--smoke") { smoke(); return }
        try runScenarios()
        let failures = FailureCounter.shared.count
        print(failures == 0 ? "\n全部场景通过 ✅" : "\n\(failures) 个场景失败 ❌")
        exit(failures == 0 ? 0 : 1)
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
            expectEqual(Array(mock.inputs[0][0..<4]), [0x43, 0x48, 0x54, 0x45], "用例2", "CHTE 大端打包正确")
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
    }

    // MARK: - 真机冒烟（--smoke）
    // 非 root 的键可见性不稳定（同一会话内曾出现 CHTE 元数据时可见时不可见，实测），
    // 故分级：非 root = 信息模式（连接成功即通过，细节供参考）；root = 严格断言。

    static func smoke() {
        print("=== CellarCore WP1 真机冒烟 ===")
        let isRoot = getuid() == 0
        print("uid=\(getuid())(\(isRoot ? "root：严格断言" : "非 root：信息模式（严格断言请用 sudo）"))")
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
}
