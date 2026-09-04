// CellarCoreCheck —— CellarCore 的零依赖本地验证工具（无 XCTest 也能跑）。
//
// 背景：本机仅有 Command Line Tools（无 Xcode），`swift test`（XCTest）不可用；
// CI 与装有 Xcode 的环境走 Tests/CellarCoreTests（XCTest）。两边场景一一对应，
// 修改任一侧必须同步另一侧（与 Tests/CellarCoreTests 的 XCTest 用例一一对应）。
//
// 用法：
//   swift run CellarCoreCheck          # 跑全部 mock 场景（WP1 1–16 + WP2 17–35 + WP3 36–46 + WP4 47–59 + 审计回归 60–62 + WP5 63–68 + WP6 69–76 + WP2 daemon 托管 77–83 + WP3 App↔daemon 84–89 + WP4 面板 90–92 + WP5 引导/通知 93–95 + WP2 一次性动作 96–104 + WP3 风格系统 105–107 + WP2' 放电域/健康能力域（DischargeDomain.swift / HealthCapabilitiesDomain.swift）+ WP1 热守卫域（ThermalGuardDomain.swift）+ Phase 5 v1.1 风扇域（FanDomain.swift）+ Phase 5 v1.2 时间估算域（TimeEstimatorDomain.swift）+ Phase 5 v1.3 统计域（StatsDomain.swift）；总数见运行结尾统计）
//   swift run CellarCoreCheck --probe  # 真机探测：makeDefault() + RuntimeProbe.probe（要求 root，探测可靠性实测结论）
//   swift run CellarCoreCheck --smoke  # 真机冒烟：makeDefault() + keyInfo("#KEY")（元数据非 root 可读）
//   swift run CellarCoreCheck --battery  # 真机电池快照：AppleSmartBattery 只读（无需 root），与 ioreg -rc AppleSmartBattery 对照
//   swift run CellarCoreCheck --doctor-report  # doctor 报告生成纯函数演示（内存构造，无需真机）
//
// 注意：本工具使用字面偏移量（规格 §5.3）而非 SMCParam 内部常量——
// 作为对实现常量的独立交叉验证（第二双眼睛）。

import CellarCore
import Foundation
import XPC

// MARK: - 计数器（Swift 6 严格并发下的可变状态盒）

final class FailureCounter: @unchecked Sendable {
    static let shared = FailureCounter()
    private let lock = NSLock()
    private(set) var count = 0
    /// 出现过的场景标签（去重）——总数动态统计，避免每加用例都要手改结尾文案。
    private var scenarios: Set<String> = []
    func increment() { lock.withLock { count += 1 } }
    func record(scenario: String) { lock.withLock { _ = scenarios.insert(scenario) } }
    var scenarioCount: Int { lock.withLock { scenarios.count } }
}

// ⚠️ 以下助手为 internal（S2 场景域按域拆独立文件——WP2' 起跨文件调用；
// executable target 的 internal 仅模块内可见，无泄露面）。
func check(_ condition: Bool, _ scenario: String, _ message: String) {
    FailureCounter.shared.record(scenario: scenario)
    if condition {
        print("  ✓ \(scenario): \(message)")
    } else {
        FailureCounter.shared.increment()
        print("  ✗ \(scenario): \(message)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ scenario: String, _ message: String) {
    check(actual == expected, scenario, actual == expected ? message : "\(message)（实际 \(actual)，期望 \(expected)）")
}

/// 泛化断言：抛出的错误须等于 `expected`（SMCError / BackendError / BatteryMonitorError /
/// LimitPolicyError 均 Equatable）。
/// 前导点成员语法（`.keyNotFound(...)`）无法在泛型参数上解析类型，故提供
/// SMCError/BackendError/BatteryMonitorError/LimitPolicyError 四个具体重载
/// （WP1/WP2 既有调用点保持零改动）；
/// ⚠️ 用例 46 断言 `.serviceNotFound` 时因 SMCError 亦有同名 case，必须写全类型前缀
/// `BatteryMonitorError.serviceNotFound`，否则前导点歧义编译失败。
/// `expected` 为 nil 时仅要求抛错、不校验类型。
func expectThrows<T>(
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

func expectThrows<T>(
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

func expectThrows<T>(
    _ body: @autoclosure () throws -> T,
    as expected: BatteryMonitorError?,
    _ scenario: String,
    _ message: String
) {
    do {
        _ = try body()
        check(false, scenario, "\(message)——但未抛错")
    } catch let error as BatteryMonitorError {
        if let expected {
            check(error == expected, scenario, error == expected ? message : "\(message)——实际 \(error)")
        } else {
            check(true, scenario, message)
        }
    } catch {
        check(false, scenario, "\(message)——实际 \(error)")
    }
}

func expectThrows<T>(
    _ body: @autoclosure () throws -> T,
    as expected: LimitPolicyError?,
    _ scenario: String,
    _ message: String
) {
    do {
        _ = try body()
        check(false, scenario, "\(message)——但未抛错")
    } catch let error as LimitPolicyError {
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

enum Spec {
    static let dataSizeOffset = 28
    static let dataTypeOffset = 32
    static let resultOffset = 40
    static let data8Offset = 42
    static let bytesOffset = 48
    static let keyInfo: UInt8 = 9
    static let read: UInt8 = 5
    static let write: UInt8 = 6
}

final class CheckTransport: SMCTransport, @unchecked Sendable {
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
func reply(
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

// MARK: - WP3 fixture 与 mock（用例 36–46）

/// 用例 46 的注入式 mock 数据源（CheckTransport 无关，直接注入 BatteryMonitor）。
private struct ThrowingPropertySource: BatteryPropertySource {
    let error: BatteryMonitorError
    func properties() throws -> [String: Any] { throw error }
}

// MARK: - WP4 mock（用例 47–59）

/// WP4 内存态后端 mock（评审 E-3 契约：name="tahoe"、keyNames=["CHTE"]）：
/// 可变 enabled 内部态 + 写调用计数 + 可注入"写不生效"故障开关（ignoreWrites）。
/// WP2' 适配器控制（CHIE）同构：adapterControlSupported + adapterEnabledRaw 内部态 +
/// 可注入"适配器写不生效"故障开关（adapterIgnoreAdapterWrites / adapterFailWrites）。
/// 纯内存，不触碰任何 SMC/IOKit 传输。与 Tests/CellarCoreTests/LimitControllerTests.swift
/// 的内联 MockChargingBackend 行为一致，两边必须同步修改。
final class MockChargingBackend: ChargingBackend, @unchecked Sendable {
    var name: String { "tahoe" }
    var keyNames: [String] { ["CHTE"] }
    private(set) var enabled: Bool
    private(set) var writeCount = 0
    var ignoreWrites = false

    // WP2' 适配器控制（CHIE）：语义态 true=使能（0x00）· false=禁用（0x08）。
    var adapterControlSupported = true
    /// 语义态可写（场景域置初态；internal setter 仅测试栈可达）。
    var adapterEnabledRaw: Bool = true
    var adapterIgnoreAdapterWrites = false
    /// 前 N 次适配器写被吞（写不生效模拟）；N 耗尽后写入生效——重试阶梯验证。
    var adapterFailWrites = 0
    private(set) var adapterWriteCount = 0

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func chargingEnabled() throws -> Bool { enabled }

    func setChargingEnabled(_ enabled: Bool) throws {
        writeCount += 1
        if !ignoreWrites { self.enabled = enabled }
    }

    func setAdapterEnabled(_ enabled: Bool) throws {
        guard adapterControlSupported else { throw BackendError.adapterControlUnsupported }
        adapterWriteCount += 1
        if adapterFailWrites > 0 {
            adapterFailWrites -= 1
            return
        }
        if !adapterIgnoreAdapterWrites { adapterEnabledRaw = enabled }
    }

    func adapterEnabled() throws -> Bool? {
        guard adapterControlSupported else { return nil }
        return adapterEnabledRaw
    }
}

/// WP3 fixture 基准字典：与 Tests/CellarCoreTests/BatterySnapshotTests.swift 的
/// makeSampleProps() 值一致（规格 §4），两边必须同步修改。工厂函数而非 static let
/// （评审 C-2：Swift 6 下 static let 存非 Sendable 的 [String: Any] 编译不过）。
func batteryProps() -> [String: Any] {
    [
        "CurrentCapacity": 86,
        "Voltage": 12211,
        "Amperage": -741,
        "Temperature": 3030,
        "DesignCapacity": 8694,
        "CycleCount": 153,
        "ExternalConnected": true,
        "IsCharging": true,
        "MaxCapacity": 100,
        "AppleRawMaxCapacity": 7612,
        "AppleRawCurrentCapacity": 6546,
        "BatteryData": ["CellVoltage": [4072, 4071, 4068], "FccComp1": 7616] as [String: Any],
        "AdapterDetails": [
            "Watts": 140,
            "AdapterVoltage": 28000,
            "Current": 4990,
            "Name": "140W USB-C Power Adapter",
            "Description": "pd charger",
            "IsWireless": false,
        ] as [String: Any],
    ]
}

// MARK: - 场景（§5.5 用例 1–16）

@main
struct Main {
    static func main() async throws {
        if CommandLine.arguments.contains("--dump-input") { dumpInput(); return }
        if CommandLine.arguments.contains("--matrix") { matrixSweep(); return }
        if CommandLine.arguments.contains("--probe") { probe(); return }
        if CommandLine.arguments.contains("--smoke") { smoke(); return }
        if CommandLine.arguments.contains("--write-perm") { writePerm(); return }
        if CommandLine.arguments.contains("--battery") { battery(); return }
        if CommandLine.arguments.contains("--doctor-report") { doctorReport(); return }
        try await runScenarios()
        // WP2'：场景域按域拆独立文件（main.swift 不再增长，评审 P2-9）——放电域 +
        // 健康度/能力域；与 runScenarios 共用 FailureCounter 与断言助手。
        try runDischargeDomainScenarios()
        try runHealthCapabilitiesDomainScenarios()
        // WP2' 验收修正：StatusFailureKind 横幅通道映射（done 剥离失败通道，
        // 改走 success 反馈 + 5s 自动消退——StatusController 侧）
        scenarioStatusFailureKindMapping()
        // WP5：doctor 扩展（进程扫描/BTM/版本矩阵/放电能力）+ 图标 override +
        // DEVICES 设备行场景域（按域拆独立文件，main.swift 不增长）。
        runProcessScanDomainScenarios()
        runIconOverrideDomainScenarios()
        runDoctorExtendedDomainScenarios()
        runDeviceInfoDomainScenarios()
        // WP1：热守卫场景域（充电侧温度暂停，方案 §4.1 九项穷举）。
        try runThermalGuardDomainScenarios()
        // Phase 4 WP2：自动放电（opt-in）场景域（方案 §4.1 九项：触发矩阵/Codable
        // 兼容/线格式/字面量锁存/值域/通知矩阵/事件承载）。
        try runAutoDischargeDomainScenarios()
        // Phase 4 WP3：自动校准（手动触发版）场景域（方案 §4.1 十一项：前置矩阵/
        // 三相位转移/监护缺失门控/Codable/字面量家族/通知矩阵/AppSide 助手/交互拒绝/
        // StatusFailureKind 映射）。
        try runCalibrationDomainScenarios()
        // Phase 5 v1.4：校准调度场景域（方案 §2.4 清单：窗口判定/就绪判定/validated
        // 值域/仅丢字段分层/Codable 兼容/wire 编解码/终态映射/state 文件/下次预估/
        // AppSide 派生助手）。
        try runCalibrationScheduleDomainScenarios()
        // Phase 5 v1.1：风扇智能降温场景域（方案 §9 表：星策略校验/F-1 全构造点
        // 透传/FanGuard 矩阵/能力推进/validFan*/DaemonStatus 兼容/doctor 检查项）。
        try runFanDomainScenarios()
        // Phase 5 v1.2：时间估算场景域（方案 §3.6——充电/放电外推、holding 不
        // 适用、短窗/无变化不可信、钳制上下界、跨 gap 重开、态切换清环（跳变
        // 断段）、斜率反向、恰好到达上限）。
        try runTimeEstimatorDomainScenarios()
        // Phase 5 v1.3：统计域场景（方案 §2.3 十二项：往返/分桶边界/AVG/功率符号
        // 推导/retention prune/损坏重建/user_version 迁移/WAL 并发/空库/同 ts
        // OR REPLACE/NULL 容错/桶末态折叠——StatsStore + StatsBucketing 直测，
        // DB 全临时目录注入）。
        await runStatsDomainScenarios()
        let failures = FailureCounter.shared.count
        print(failures == 0 ? "\n全部 \(FailureCounter.shared.scenarioCount) 个场景通过 ✅" : "\n\(failures) 个场景失败 ❌")
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
            _ = try client.read("CHTE")
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

    // MARK: - 真机电池快照（--battery）
    // AppleSmartBattery 注册表数据（ioreg -rc AppleSmartBattery，无需 root，M0 实测）。
    // 纯只读：本命令不写任何 SMC 键；无电池机型（.serviceNotFound）说明后非零退出（对齐 --probe 写法）。

    static func battery() {
        print("=== CellarCore 电池快照（--battery，只读，无需 root）===")
        let monitor = BatteryMonitor.makeDefault()
        do {
            let s = try monitor.snapshot()
            print("电量：\(s.percent)%\(s.isCharging ? "（充电中）" : "")")
            print("外部电源：\(s.externalConnected ? "已连接" : "未连接")")
            print("电压：\(s.voltageMV) mV")
            print("电流：\(s.amperageMA) mA（⚠️ 符号语义未定，方向以 IsCharging 为准）")
            print("温度：\(s.temperatureCentiC) 厘摄氏度（≈\(String(format: "%.2f", s.temperatureC)) °C）")
            print("循环次数：\(s.cycleCount)")
            print("设计容量：\(s.designCapacityMAh) mAh")
            if let max = s.maxCapacityPercent { print("当前最大容量：\(max)%") }
            if let raw = s.rawMaxCapacityMAh { print("原始最大容量：\(raw) mAh") }
            if let raw = s.rawCurrentCapacityMAh { print("原始当前容量：\(raw) mAh") }
            if let cells = s.cellVoltagesMV { print("电芯电压：\(cells) mV") }
            if let fcc = s.fccMAh { print("FccComp1：\(fcc) mAh") }
            if let adapter = s.adapter {
                var parts: [String] = []
                if let watts = adapter.watts { parts.append("\(watts) W") }
                if let voltage = adapter.voltageMV { parts.append("\(voltage) mV") }
                if let current = adapter.currentMA { parts.append("\(current) mA") }
                if let name = adapter.name { parts.append(name) }
                if let desc = adapter.adapterDescription { parts.append(desc) }
                if let wireless = adapter.isWireless { parts.append("无线充电=\(wireless)") }
                print("适配器：\(parts.isEmpty ? "（空）" : parts.joined(separator: " · "))")
            } else {
                print("适配器：无")
            }
            print("时间戳：\(s.timestamp)")
            print("\n提示：与 `ioreg -rc AppleSmartBattery` 同刻对照——稳定字段应严格一致，波动字段允许容差")
            exit(0)
        } catch BatteryMonitorError.serviceNotFound {
            print("❌ 未找到 AppleSmartBattery 服务——本机可能无电池（桌面/虚拟机）")
            print("   可用 `ioreg -rc AppleSmartBattery` 确认")
            exit(1)
        } catch {
            print("❌ 读取失败：\(error)")
            exit(1)
        }
    }

    /// 穷举扫描：决策矩阵实现 vs 独立期望函数（不同写法），全边界组合逐点比对。
    static func matrixSweep() {
        // 独立期望：与 LimitPolicy.decide 不同的写法（查表式边界三分支）
        func expected(percent: Int, external: Bool, enabled: Bool, upper: Int, resume: Int) -> ChargingAction {
            if !external { return .noop }
            if enabled && percent >= upper { return .disableCharging }
            if !enabled && percent < resume { return .enableCharging }
            return .noop
        }

        var checked = 0
        var mismatches = 0
        let combos: [(upper: Int, hys: Int)] = [(60, 1), (60, 20), (61, 19), (80, 2), (80, 20), (100, 1), (100, 20)]
        let percents = [-5, 0, 1, 39, 40, 41, 58, 59, 60, 61, 77, 78, 79, 80, 81, 85, 99, 100, 105]

        for combo in combos {
            guard let policy = try? LimitPolicy(upperLimit: combo.upper, hysteresis: combo.hys) else {
                print("  ✗ Policy(\(combo.upper), \(combo.hys)) 构造失败"); mismatches += 1; continue
            }
            let resume = combo.upper - combo.hys
            // 聚焦边界：恢复阈值 ±1 与上限 ±1 附近全查 + 少量远点
            let focus = [resume - 1, resume, resume + 1, combo.upper - 1, combo.upper, combo.upper + 1]
            for percent in (focus + percents).sorted() {
                for external in [true, false] {
                    for enabled in [true, false] {
                        let ctx = ChargingContext(percent: percent, externalConnected: external, chargingEnabled: enabled)
                        let actual = policy.decide(context: ctx)
                        let want = expected(percent: percent, external: external,
                                            enabled: enabled, upper: combo.upper, resume: resume)
                        checked += 1
                        if actual != want {
                            mismatches += 1
                            print("  ✗ upper=\(combo.upper) hys=\(combo.hys) percent=\(percent) external=\(external) enabled=\(enabled)：实现=\(actual) 期望=\(want)")
                        }
                    }
                }
            }
        }
        print("穷举 \(checked) 个组合点：\(mismatches == 0 ? "实现与独立期望完全一致 ✅" : "\(mismatches) 处不一致 ❌")")
        exit(mismatches == 0 ? 0 : 1)
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

    static func runScenarios() async throws {
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

        // 用例 24：Legacy 使能（双键读 00/00，审计中-1 后 chargingEnabled 读两键）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 1, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(dataSize: 1, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0x00]), for: Spec.read)
            mock.enqueue(reply(bytes: [0x00]), for: Spec.read)
            let enabled = try LegacyBackend(client: SMCClient(transport: mock)).chargingEnabled()
            check(enabled == true, "用例24", "CH0B/CH0C 00 → chargingEnabled() == true")
        }

        // 用例 25：Legacy 停充（双键读 02/02）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 1, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(dataSize: 1, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0x02]), for: Spec.read)
            mock.enqueue(reply(bytes: [0x02]), for: Spec.read)
            let enabled = try LegacyBackend(client: SMCClient(transport: mock)).chargingEnabled()
            check(enabled == false, "用例25", "CH0B/CH0C 02 → chargingEnabled() == false")
        }

        // 用例 26：Legacy 未知值（双键读 01/01）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 1, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(dataSize: 1, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0x01]), for: Spec.read)
            mock.enqueue(reply(bytes: [0x01]), for: Spec.read)
            expectThrows(try LegacyBackend(client: SMCClient(transport: mock)).chargingEnabled(),
                         as: BackendError.unknownChargingState(key: "CH0B", bytes: [1]),
                         "用例26", "CH0B 01 报 .unknownChargingState")
        }

        // 用例 27：Legacy 长度防御（keyInfo size=0 → 双键读空 → 不越界，按分裂态显式报错）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 0, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(dataSize: 0, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(), for: Spec.read)
            mock.enqueue(reply(), for: Spec.read)
            expectThrows(try LegacyBackend(client: SMCClient(transport: mock)).chargingEnabled(),
                         as: BackendError.legacyKeysInconsistent(ch0b: 255, ch0c: 255),
                         "用例27", "空值报 .legacyKeysInconsistent（不越界）")
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

        // MARK: - 场景（WP3 规格 §4 用例 36–46）
        // CheckTransport 无关：直接调 BatterySnapshotParser（纯函数，timestamp 注入固定值）；
        // 用例 46 用本地 ThrowingPropertySource mock source。fixture 见 batteryProps()。

        let timeZero = Date(timeIntervalSince1970: 0)

        // 用例 36：完整字典 + 固定 timestamp 整值断言。
        do {
            let s = try BatterySnapshotParser.parse(batteryProps(), timestamp: timeZero)
            expectEqual(s.percent, 86, "用例36", "percent=86")
            expectEqual(s.voltageMV, 12211, "用例36", "voltageMV=12211")
            expectEqual(s.amperageMA, -741, "用例36", "amperageMA=-741")
            expectEqual(s.temperatureCentiC, 3030, "用例36", "temperatureCentiC=3030")
            check(abs(s.temperatureC - 30.3) < 0.01, "用例36", "temperatureC ≈ 30.3")
            expectEqual(s.cycleCount, 153, "用例36", "cycleCount=153")
            expectEqual(s.designCapacityMAh, 8694, "用例36", "designCapacityMAh=8694")
            expectEqual(s.maxCapacityPercent, 100, "用例36", "maxCapacityPercent=100")
            expectEqual(s.rawMaxCapacityMAh, 7612, "用例36", "rawMaxCapacityMAh=7612")
            expectEqual(s.rawCurrentCapacityMAh, 6546, "用例36", "rawCurrentCapacityMAh=6546")
            expectEqual(s.cellVoltagesMV, [4072, 4071, 4068], "用例36", "cellVoltagesMV=[4072,4071,4068]")
            expectEqual(s.fccMAh, 7616, "用例36", "fccMAh=7616")
            check(s.isCharging == true && s.externalConnected == true, "用例36", "isCharging/externalConnected=true")
            expectEqual(s.timestamp, timeZero, "用例36", "timestamp 相等")
            expectEqual(s.adapter?.watts, 140, "用例36", "adapter.watts=140")
            expectEqual(s.adapter?.voltageMV, 28000, "用例36", "adapter.voltageMV=28000")
            expectEqual(s.adapter?.currentMA, 4990, "用例36", "adapter.currentMA=4990")
            expectEqual(s.adapter?.name, "140W USB-C Power Adapter", "用例36", "adapter.name 正确")
            expectEqual(s.adapter?.adapterDescription, "pd charger", "用例36", "adapter.adapterDescription 正确")
            check(s.adapter?.isWireless == false, "用例36", "adapter.isWireless=false")
        }

        // 用例 37：Amperage UInt64 回绕（0xFFFF_FFFF_FFFF_FD1B → -741，按位还原）。
        do {
            var props = batteryProps()
            props["Amperage"] = NSNumber(value: UInt64(0xFFFF_FFFF_FFFF_FD1B))
            let s = try BatterySnapshotParser.parse(props, timestamp: timeZero)
            expectEqual(s.amperageMA, -741, "用例37", "UInt64 回绕值按位还原为 -741")
        }

        // 用例 38：Amperage 正值 +2618 原样保留。
        do {
            var props = batteryProps()
            props["Amperage"] = 2618
            let s = try BatterySnapshotParser.parse(props, timestamp: timeZero)
            expectEqual(s.amperageMA, 2618, "用例38", "Amperage=+2618 原样保留")
        }

        // 用例 39：缺 CurrentCapacity → .missingRequiredField。
        do {
            var props = batteryProps()
            props.removeValue(forKey: "CurrentCapacity")
            expectThrows(try BatterySnapshotParser.parse(props, timestamp: timeZero),
                         as: BatteryMonitorError.missingRequiredField("CurrentCapacity"),
                         "用例39", "缺 CurrentCapacity 报 .missingRequiredField")
        }

        // 用例 40：缺 IsCharging → .missingRequiredField。
        do {
            var props = batteryProps()
            props.removeValue(forKey: "IsCharging")
            expectThrows(try BatterySnapshotParser.parse(props, timestamp: timeZero),
                         as: BatteryMonitorError.missingRequiredField("IsCharging"),
                         "用例40", "缺 IsCharging 报 .missingRequiredField")
        }

        // 用例 41：CurrentCapacity="86"（String）→ .invalidFieldType。
        do {
            var props = batteryProps()
            props["CurrentCapacity"] = "86"
            expectThrows(try BatterySnapshotParser.parse(props, timestamp: timeZero),
                         as: BatteryMonitorError.invalidFieldType("CurrentCapacity"),
                         "用例41", "类型不符报 .invalidFieldType")
        }

        // 用例 42：IsCharging=NSNumber(1) → 容错为 true（数值 0/1，评审 B-5）。
        do {
            var props = batteryProps()
            props["IsCharging"] = NSNumber(value: 1)
            let s = try BatterySnapshotParser.parse(props, timestamp: timeZero)
            check(s.isCharging == true, "用例42", "IsCharging=NSNumber(1) 容错为 true")
        }

        // 用例 43：删 AdapterDetails → adapter == nil（单变量，其余字段不变）。
        do {
            var props = batteryProps()
            props.removeValue(forKey: "AdapterDetails")
            let s = try BatterySnapshotParser.parse(props, timestamp: timeZero)
            check(s.adapter == nil, "用例43", "adapter == nil")
            check(s.percent == 86 && s.cycleCount == 153, "用例43", "其余字段不变（抽查 percent/cycleCount）")
        }

        // 用例 44：删 MaxCapacity/AppleRaw*/BatteryData → 对应 nil，不抛错。
        do {
            var props = batteryProps()
            props.removeValue(forKey: "MaxCapacity")
            props.removeValue(forKey: "AppleRawMaxCapacity")
            props.removeValue(forKey: "AppleRawCurrentCapacity")
            props.removeValue(forKey: "BatteryData")
            let s = try BatterySnapshotParser.parse(props, timestamp: timeZero)
            check(s.maxCapacityPercent == nil && s.rawMaxCapacityMAh == nil
                    && s.rawCurrentCapacityMAh == nil && s.cellVoltagesMV == nil && s.fccMAh == nil,
                  "用例44", "可选字段全部 nil 且不抛错")
            check(s.percent == 86, "用例44", "必需字段不受影响")
        }

        // 用例 45：适配器空字典 {} → adapter 存在且全字段 nil。
        do {
            var props = batteryProps()
            props["AdapterDetails"] = [:] as [String: Any]
            let s = try BatterySnapshotParser.parse(props, timestamp: timeZero)
            check(s.adapter != nil, "用例45", "空字典仍解析出 adapter")
            check(s.adapter?.watts == nil && s.adapter?.voltageMV == nil && s.adapter?.currentMA == nil
                    && s.adapter?.name == nil && s.adapter?.adapterDescription == nil && s.adapter?.isWireless == nil,
                  "用例45", "adapter 全字段 nil")
        }

        // 用例 46：Monitor 错误传播——source 抛 .serviceNotFound → snapshot() 原样上抛。
        // ⚠️ 必须写全类型前缀：SMCError 亦有同名 .serviceNotFound，前导点会歧义（编译失败）。
        do {
            let monitor = BatteryMonitor(source: ThrowingPropertySource(error: BatteryMonitorError.serviceNotFound))
            expectThrows(try monitor.snapshot(),
                         as: BatteryMonitorError.serviceNotFound,
                         "用例46", "source 的 .serviceNotFound 原样传播")
        }

        // MARK: - 场景（WP4 规格 §3 用例 47–59）
        // 纯逻辑决策：不经 SMC/IOKit 传输，全部经文件作用域 MockChargingBackend 内存态。

        // 用例 47：合法策略 upperLimit=80, hysteresis=2 → 属性可读。
        do {
            let policy = try LimitPolicy(upperLimit: 80, hysteresis: 2)
            check(policy.upperLimit == 80 && policy.hysteresis == 2, "用例47", "upperLimit=80/hysteresis=2 构造成功且属性可读")
        }

        // 用例 48：构造边界——59→floor；101→ceiling；hys=0 与 21→outOfRange。
        do {
            expectThrows(try LimitPolicy(upperLimit: 59, hysteresis: 2),
                         as: LimitPolicyError.upperLimitBelowFloor(minimum: 60),
                         "用例48", "59 抛 .upperLimitBelowFloor(minimum:60)")
            expectThrows(try LimitPolicy(upperLimit: 101, hysteresis: 2),
                         as: LimitPolicyError.upperLimitAboveCeiling(maximum: 100),
                         "用例48", "101 抛 .upperLimitAboveCeiling(maximum:100)")
            expectThrows(try LimitPolicy(upperLimit: 80, hysteresis: 0),
                         as: LimitPolicyError.hysteresisOutOfRange(validRange: 1...20),
                         "用例48", "hys=0 抛 .hysteresisOutOfRange(1...20)")
            expectThrows(try LimitPolicy(upperLimit: 80, hysteresis: 21),
                         as: LimitPolicyError.hysteresisOutOfRange(validRange: 1...20),
                         "用例48", "hys=21 抛 .hysteresisOutOfRange(1...20)")
        }

        // 用例 49：决策——电池供电（!external, enabled=true, percent=50）→ noop。
        do {
            let policy = try LimitPolicy(upperLimit: 80, hysteresis: 2)
            let action = policy.decide(context: ChargingContext(percent: 50, externalConnected: false, chargingEnabled: true))
            check(action == .noop, "用例49", "电池供电恒 noop（无可控制）")
        }

        // 用例 50：决策停充侧——(external, enabled=true, percent∈{79, 80, 85, 100})：
        // 79→noop（未到上限）；80/85/100→disable（>= 判定，含 percent=100 边界）。
        do {
            let policy = try LimitPolicy(upperLimit: 80, hysteresis: 2)
            check(policy.decide(context: ChargingContext(percent: 79, externalConnected: true, chargingEnabled: true)) == .noop,
                  "用例50", "percent=79（<80）→ noop")
            var ok = true
            for percent in [80, 85, 100] {
                if policy.decide(context: ChargingContext(percent: percent, externalConnected: true, chargingEnabled: true)) != .disableCharging {
                    ok = false
                }
            }
            check(ok, "用例50", "percent∈{80, 85, 100}（>=80）→ disable")
        }

        // 用例 51：决策恢复侧——(external, enabled=false, percent∈{0, 50, 77}) 皆 enable
        // （严格小于恢复阈值 78，含 percent=0 边界）。
        do {
            let policy = try LimitPolicy(upperLimit: 80, hysteresis: 2)
            var ok = true
            for percent in [0, 50, 77] {
                if policy.decide(context: ChargingContext(percent: percent, externalConnected: true, chargingEnabled: false)) != .enableCharging {
                    ok = false
                }
            }
            check(ok, "用例51", "percent∈{0, 50, 77}（<78）→ enable")
        }

        // 用例 52：决策保持侧——(external, enabled=false, percent∈{78, 79}) 皆 noop
        // （percent == 恢复阈值不恢复，边界定版）。
        do {
            let policy = try LimitPolicy(upperLimit: 80, hysteresis: 2)
            var ok = true
            for percent in [78, 79] {
                if policy.decide(context: ChargingContext(percent: percent, externalConnected: true, chargingEnabled: false)) != .noop {
                    ok = false
                }
            }
            check(ok, "用例52", "percent∈{78, 79}（>=78）→ noop（保持区间）")
        }

        // 用例 53：地板角点 upper=60, hys=20（恢复阈值 40，不受 60 地板约束，评审 A-2）：
        // stopped+39→enable；stopped+40→noop；enabled+60→disable。
        do {
            let policy = try LimitPolicy(upperLimit: 60, hysteresis: 20)
            check(policy.decide(context: ChargingContext(percent: 39, externalConnected: true, chargingEnabled: false)) == .enableCharging,
                  "用例53", "upper=60/hys=20：stopped+39（<40）→ enable")
            check(policy.decide(context: ChargingContext(percent: 40, externalConnected: true, chargingEnabled: false)) == .noop,
                  "用例53", "upper=60/hys=20：stopped+40（==40）→ noop")
            check(policy.decide(context: ChargingContext(percent: 60, externalConnected: true, chargingEnabled: true)) == .disableCharging,
                  "用例53", "upper=60/hys=20：enabled+60（>=60）→ disable")
        }

        // 用例 54：sleepAction 三断言——{external+enabled→disable}、{!external→noop}、{external+stopped→noop}。
        do {
            check(PowerEventPolicy.sleepAction(externalConnected: true, currentChargingEnabled: true) == .disableCharging,
                  "用例54", "外接且允许充电 → 停充")
            check(PowerEventPolicy.sleepAction(externalConnected: false, currentChargingEnabled: true) == .noop,
                  "用例54", "电池供电 → noop")
            check(PowerEventPolicy.sleepAction(externalConnected: true, currentChargingEnabled: false) == .noop,
                  "用例54", "外接但已停充 → noop")
        }

        // 用例 55：requiresReevaluation 七种事件皆 true（事件即触发契约，评审 A-1）。
        do {
            let events: [PowerEvent] = [
                .powerConnected, .powerDisconnected,
                .batteryLevelChanged(percent: 50), .periodicTick,
                .systemSleep, .systemWake, .policyChanged,
            ]
            check(events.allSatisfy { PowerEventPolicy.requiresReevaluation(on: $0) },
                  "用例55", "七种事件 requiresReevaluation 恒 true")
        }

        // 用例 56：enforce noop——context=电池供电 → 返回 .noop 且 backend 调用计数 == 0。
        do {
            let controller = LimitController(policy: try LimitPolicy(upperLimit: 80, hysteresis: 2))
            let backend = MockChargingBackend(enabled: true)
            let action = try controller.enforce(
                context: ChargingContext(percent: 50, externalConnected: false, chargingEnabled: true),
                backend: backend
            )
            check(action == .noop && backend.writeCount == 0, "用例56", "noop 返回且零 backend 写调用")
        }

        // 用例 57：enforce disable/enable 两段 context，mock 正常生效——状态翻转 + 回读一致 + 返回对应动作。
        do {
            let controller = LimitController(policy: try LimitPolicy(upperLimit: 80, hysteresis: 2))
            let backend = MockChargingBackend(enabled: true)

            let disable = try controller.enforce(
                context: ChargingContext(percent: 80, externalConnected: true, chargingEnabled: true),
                backend: backend
            )
            check(disable == .disableCharging && backend.enabled == false && backend.writeCount == 1,
                  "用例57", "段一：disable 生效（态翻转 + 回读一致 + 返回 .disableCharging）")

            let enable = try controller.enforce(
                context: ChargingContext(percent: 77, externalConnected: true, chargingEnabled: false),
                backend: backend
            )
            check(enable == .enableCharging && backend.enabled == true && backend.writeCount == 2,
                  "用例57", "段二：enable 生效（态翻转 + 回读一致 + 返回 .enableCharging）")
        }

        // 用例 58：enforce 校验失败（双向）——故障开关下 desired=false/actual=true 与
        // desired=true/actual=false 皆抛 .verifyFailed（key=="CHTE"）。
        do {
            let controller = LimitController(policy: try LimitPolicy(upperLimit: 80, hysteresis: 2))

            let backendDisable = MockChargingBackend(enabled: true)
            backendDisable.ignoreWrites = true
            expectThrows(try controller.enforce(
                context: ChargingContext(percent: 80, externalConnected: true, chargingEnabled: true),
                backend: backendDisable
            ), as: BackendError.verifyFailed(key: "CHTE", desired: false, actual: true),
            "用例58", "写停充不生效 → .verifyFailed(CHTE, desired:false, actual:true)")
            check(backendDisable.writeCount == 1, "用例58", "故障开关只吞生效，写调用已发出")

            let backendEnable = MockChargingBackend(enabled: false)
            backendEnable.ignoreWrites = true
            expectThrows(try controller.enforce(
                context: ChargingContext(percent: 77, externalConnected: true, chargingEnabled: false),
                backend: backendEnable
            ), as: BackendError.verifyFailed(key: "CHTE", desired: true, actual: false),
            "用例58", "写使能不生效 → .verifyFailed(CHTE, desired:true, actual:false)")
            check(backendEnable.writeCount == 1, "用例58", "故障开关只吞生效，写调用已发出")
        }

        // 用例 59：updatePolicy 80→90 后，(external, stopped, 85) 从 noop 变 enable——新策略生效。
        do {
            var controller = LimitController(policy: try LimitPolicy(upperLimit: 80, hysteresis: 2))
            let stoppedAt85 = ChargingContext(percent: 85, externalConnected: true, chargingEnabled: false)
            check(controller.decide(context: stoppedAt85) == .noop, "用例59", "旧策略（阈值 78）：85>=78 → noop")
            try controller.updatePolicy(LimitPolicy(upperLimit: 90, hysteresis: 2))
            check(controller.policy.upperLimit == 90 && controller.decide(context: stoppedAt85) == .enableCharging,
                  "用例59", "新策略（阈值 88）：85<88 → enable，且 policy 已换为 upperLimit=90")
        }

        // ===== 审计修复回归（code-reviewer 中-1 / 中-2，2026-08-31）=====

        // 用例 60：Legacy 双键分裂（CH0B=00、CH0C=02）→ .legacyKeysInconsistent。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(dataSize: 1, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(dataSize: 1, type: "ui8"), for: Spec.keyInfo)
            mock.enqueue(reply(bytes: [0x00]), for: Spec.read)
            mock.enqueue(reply(bytes: [0x02]), for: Spec.read)
            expectThrows(try LegacyBackend(client: SMCClient(transport: mock)).chargingEnabled(),
                         as: BackendError.legacyKeysInconsistent(ch0b: 0, ch0c: 2),
                         "用例60", "双键分裂显式报错（不伪装成正常态）")
        }

        // 用例 61：set 预读失败 → fail-fast（.keyNotFound 原样上抛），零写调用（审计中-1）。
        do {
            let mock = CheckTransport()
            mock.enqueue(reply(result: 132), for: Spec.keyInfo)
            expectThrows(try LegacyBackend(client: SMCClient(transport: mock)).setChargingEnabled(false),
                         as: SMCError.keyNotFound("CH0B"),
                         "用例61", "预读失败拒绝开写")
            let writes = mock.inputs.filter { $0[Spec.data8Offset] == Spec.write }
            check(writes.isEmpty, "用例61", "预读失败后零写调用")
        }

        // 用例 62：perform(.disableCharging) 直通路（睡眠停充共用校验底座，审计中-2）：
        // mock 正常生效 → 状态翻转 + 无抛错。
        do {
            let backend = MockChargingBackend(enabled: true)
            let controller = LimitController(policy: try LimitPolicy(upperLimit: 80, hysteresis: 2))
            try controller.perform(.disableCharging, backend: backend)
            check(backend.enabled == false && backend.writeCount == 1,
                  "用例62", "perform 应用动作且回读一致")
        }

        // MARK: - 场景（WP5 规格 §4 用例 63–68）
        // doctor 报告生成纯函数：DoctorInputs 内存构造，直接调 generate 与 exitCode；
        // ConflictScan.classify 用字面数组（本工具不触碰真实 LaunchDaemons 等目录）。

        // 用例 63：ConflictScan.classify 命中——exact 白名单标识 / generic 词根
        // （大小写不敏感）/ 去重排序 / hasConflict。
        do {
            let result = ConflictScan.classify([
                "com.foo.battery.helper",
                "batt.daemon.plist",
                "com.apphousekitchen.aldente-pro.helper",
                "BaTTERy-mon.plist",
                "org.smc.tool",
                "my.power.monitor",
            ])
            expectEqual(result.exact, ["batt.daemon.plist", "com.apphousekitchen.aldente-pro.helper"],
                        "用例63", "exact 命中条目标识（batt.daemon + apphousekitchen/aldente-pro；按条目名去重排序）")
            expectEqual(result.generic,
                        ["BaTTERy-mon.plist", "com.foo.battery.helper", "my.power.monitor", "org.smc.tool"],
                        "用例63", "generic 词根命中（大小写不敏感，去重排序）")
            check(result.hasConflict, "用例63", "hasConflict == true")
        }

        // 用例 64：classify 排除 com.apple. 前缀（系统条目豁免，零命中）。
        do {
            let result = ConflictScan.classify(["com.apple.powerd.plist", "com.apple.batterd"])
            check(result.exact.isEmpty && result.generic.isEmpty && !result.hasConflict,
                  "用例64", "com.apple. 前缀条目全部豁免（零命中）")
        }

        // 用例 65–68 共用快照 fixture（WP3 fixture 经解析器构造，与 BatterySnapshotTests 一致）。
        let healthySnapshot: BatterySnapshot
        do {
            healthySnapshot = try BatterySnapshotParser.parse(batteryProps(), timestamp: timeZero)
        } catch {
            check(false, "用例65", "快照 fixture 构造失败：\(error)")
            return
        }

        // 用例 65：Doctor 全健康（root + detected + 控制键已知 + 快照 + 零命中）。
        do {
            let inputs = DoctorInputs(
                isRoot: true,
                smcConnected: true,
                probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
                chargingEnabled: false,
                chargingError: nil,
                snapshot: healthySnapshot,
                snapshotError: nil,
                conflict: ConflictScanResult(exact: [], generic: [])
            )
            let report = DoctorReportGenerator.generate(inputs)
            check(report.checks.count == 7 && report.checks.allSatisfy({ $0.status == .pass }),
                  "用例65", "7 checks 全 pass")
            check(report.worstStatus == .pass && report.exitCode == 0,
                  "用例65", "worstStatus==pass && exitCode==0")
        }

        // 用例 66：非 root（其余同 65）——检查 1/7 info，不抬升 worstStatus/退出码。
        do {
            let inputs = DoctorInputs(
                isRoot: false,
                smcConnected: true,
                probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
                chargingEnabled: false,
                chargingError: nil,
                snapshot: healthySnapshot,
                snapshotError: nil,
                conflict: ConflictScanResult(exact: [], generic: [])
            )
            let report = DoctorReportGenerator.generate(inputs)
            check(report.checks[0].status == .info && report.checks[6].status == .info,
                  "用例66", "检查 1/7 为 info")
            check(report.checks[1...5].allSatisfy({ $0.status == .pass }),
                  "用例66", "其余五项 pass")
            check(report.worstStatus == .pass && report.exitCode == 0,
                  "用例66", "info 不抬升 worstStatus/exitCode")
        }

        // 用例 67：共存命中（exact+generic 各一）——检查 6 WARN，
        // detail 含条目名与 generic"疑似"标注（power 词根）。
        do {
            let inputs = DoctorInputs(
                isRoot: true,
                smcConnected: true,
                probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
                chargingEnabled: true,
                chargingError: nil,
                snapshot: healthySnapshot,
                snapshotError: nil,
                conflict: ConflictScanResult(exact: ["batt.daemon"], generic: ["my.power.monitor"])
            )
            let report = DoctorReportGenerator.generate(inputs)
            let check6 = report.checks[5]
            check(check6.status == .warn, "用例67", "检查 6 WARN")
            check(check6.detail.contains("batt.daemon") && check6.detail.contains("my.power.monitor（疑似）"),
                  "用例67", "detail 含条目名与 generic 疑似标注")
            check(report.worstStatus == .warn && report.exitCode == 1,
                  "用例67", "worstStatus==warn && exitCode==1")
        }

        // 用例 68：后端不可用（noneAvailable）+ 控制键失败 + 快照失败——
        // 检查 3 INFO（只读模式；判定规则以规格 §3 表格为准）、检查 4/5 FAIL。
        do {
            let inputs = DoctorInputs(
                isRoot: true,
                smcConnected: true,
                probe: .noneAvailable,
                chargingEnabled: nil,
                chargingError: .transportFailure(kr: badArgumentKR),
                snapshot: nil,
                snapshotError: .serviceNotFound,
                conflict: ConflictScanResult(exact: [], generic: [])
            )
            let report = DoctorReportGenerator.generate(inputs)
            check(report.checks[2].status == .info, "用例68", "检查 3 INFO（noneAvailable → 只读模式）")
            check(report.checks[3].status == .fail && report.checks[4].status == .fail,
                  "用例68", "检查 4/5 FAIL（控制键/快照读取失败）")
            check(report.worstStatus == .fail && report.exitCode == 2,
                  "用例68", "worstStatus==fail && exitCode==2")
        }

        // MARK: - 场景（WP6 规格 §6 用例 69–76）
        // daemon 支持层纯函数/纯内存验证：不触碰真实 XPC 服务、SMC、系统目录
        // （PolicyStore 用临时目录；XPC 消息仅构造与校验，不发包）。

        // 用例 69：Doctor 检查 8「daemon」——运行中（active）→ PASS；已探测但未运行
        // （daemonStatus=nil + daemonProbeAttempted）→ INFO（"cellar install 可启用限充"）；
        // 未探测（缺省参数，既有输入形态）→ 不渲染（计数/下标与 65–68 兼容）。
        do {
            let base = healthySnapshot
            let running = DoctorInputs(
                isRoot: true, smcConnected: true,
                probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
                chargingEnabled: false, chargingError: nil,
                snapshot: base, snapshotError: nil,
                conflict: ConflictScanResult(exact: [], generic: []),
                daemonStatus: DaemonStatus(
                    version: "0.3.0-alpha-dev", mode: "active", upperLimit: 80, hysteresis: 2,
                    lastAction: "enforce:disableCharging", lastPercent: 80,
                    lastExternalConnected: true, lastChargingEnabled: false,
                    timestamp: Date(timeIntervalSince1970: 1234)
                ),
                daemonProbeAttempted: true
            )
            let report = DoctorReportGenerator.generate(running)
            check(report.checks.count == 8 && report.checks[7].name == "daemon" && report.checks[7].status == .pass,
                  "用例69", "运行中 → 检查 8 PASS（追加在索引 7）")
            check(report.checks[7].detail.contains("active") && report.exitCode == 0,
                  "用例69", "PASS detail 含模式且不抬升退出码")

            let notInstalled = DoctorInputs(
                isRoot: true, smcConnected: true,
                probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
                chargingEnabled: false, chargingError: nil,
                snapshot: base, snapshotError: nil,
                conflict: ConflictScanResult(exact: [], generic: []),
                daemonStatus: nil,
                daemonProbeAttempted: true
            )
            let degraded = DoctorReportGenerator.generate(notInstalled)
            check(degraded.checks.count == 8 && degraded.checks[7].status == .info
                    && degraded.checks[7].detail.contains("sudo cellar install 或从 Cellar 面板安装可启用限充"),
                  "用例69", "已探测但未运行 → 检查 8 INFO（双路由文案）")

            let legacy = DoctorReportGenerator.generate(DoctorInputs(
                isRoot: true, smcConnected: true,
                probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
                chargingEnabled: false, chargingError: nil,
                snapshot: base, snapshotError: nil,
                conflict: ConflictScanResult(exact: [], generic: [])
            ))
            check(legacy.checks.count == 7, "用例69", "未探测 → 不渲染检查 8（既有输入形态兼容）")
        }

        // 用例 70：DaemonStatus JSON round-trip（含 version 与全部可选字段；全 nil 形态同测）。
        do {
            let full = DaemonStatus(
                version: "0.3.0-alpha-dev", mode: "active", upperLimit: 80, hysteresis: 2,
                lastAction: "enforce:disableCharging", lastPercent: 80,
                lastExternalConnected: true, lastChargingEnabled: false,
                timestamp: Date(timeIntervalSince1970: 1234)
            )
            let json = DaemonXPC.encodeStatus(full)
            let decoded = json.flatMap { try? DaemonXPC.decodeStatus($0) }
            check(decoded == full, "用例70", "编码→解码 == 原值（含 version 与可选字段）")

            let bare = DaemonStatus(version: "0.3.0-alpha-dev", mode: "disabled", upperLimit: 60, hysteresis: 20)
            let bareRound = DaemonXPC.encodeStatus(bare).flatMap { try? DaemonXPC.decodeStatus($0) }
            check(bareRound == bare, "用例70", "可选字段全 nil 形态 round-trip")
        }

        // 用例 71–74：PolicyStore（临时目录）。
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cellar-policystore-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = PolicyStore(url: directory.appendingPathComponent("policy.json"))

            // 71：save → load == 原值。
            let policy = DaemonPolicy(mode: "active", upperLimit: 85, hysteresis: 3)
            var saveOK = true
            do { try store.save(policy) } catch { saveOK = false }
            check(saveOK && store.load() == policy, "用例71", "save → load == 原值（临时目录）")

            // 72：文件缺失 → nil（不抛错）。
            check(PolicyStore(url: directory.appendingPathComponent("missing.json")).load() == nil,
                  "用例72", "文件缺失 → nil")

            // 73：损坏（非 JSON）→ nil。
            try "not json".write(to: store.url, atomically: true, encoding: .utf8)
            check(store.load() == nil, "用例73", "损坏文件 → nil（不抛错）")

            // 74：语义强校验（A-2 回归：60 地板持久化绕过封堵）。
            let backdoor = #"{"mode":"active","upperLimit":30,"hysteresis":2}"#
            try backdoor.write(to: store.url, atomically: true, encoding: .utf8)
            check(store.load() == nil, "用例74", "upperLimit=30 持久化回流 → nil（60 地板封堵）")
            let badMode = #"{"mode":"foo","upperLimit":80,"hysteresis":2}"#
            try badMode.write(to: store.url, atomically: true, encoding: .utf8)
            check(store.load() == nil, "用例74", "mode=foo → nil")
            try store.save(DaemonPolicy(mode: "disabled", upperLimit: 90, hysteresis: 5))
            check(store.load() == DaemonPolicy(mode: "disabled", upperLimit: 90, hysteresis: 5),
                  "用例74", "合法策略正常读回（对照组）")

            // 0.4.1 安全审计 F-1：load 透传 autoDischargeEnabled（缺失 → 重启/SIGHUP
            // 后开关静默复位）。
            let autoOn = #"{"mode":"active","upperLimit":80,"hysteresis":2,"autoDischargeEnabled":true}"#
            try autoOn.write(to: store.url, atomically: true, encoding: .utf8)
            check(store.load()? .autoDischargeEnabled == true,
                  "用例74", "autoDischargeEnabled=true 持久化读回（F-1 回归）")
            try #"{"mode":"active","upperLimit":80,"hysteresis":2}"#.write(to: store.url, atomically: true, encoding: .utf8)
            check(store.load()? .autoDischargeEnabled == nil,
                  "用例74", "旧格式无键 → nil（decodeIfPresent 兼容）")
        }

        // 用例 75：makeMessage/okReply/errorReply 结构——键存在、类型正确（xpc_get_type）、
        // ok/error 载荷一致（⚠️ xpc 对象由 ARC 管理，勿手动 release）。
        do {
            let message = DaemonXPC.makeMessage(cmd: "setLimits", upper: 80, hysteresis: 2)
            let cmdValue = xpc_dictionary_get_value(message, "cmd")
            let upperValue = xpc_dictionary_get_value(message, "upper")
            let hysValue = xpc_dictionary_get_value(message, "hysteresis")
            let messageOK = xpc_get_type(message) == XPC_TYPE_DICTIONARY
                && cmdValue.map(xpc_get_type) == XPC_TYPE_STRING
                && String(cString: xpc_dictionary_get_string(message, "cmd")!) == "setLimits"
                && upperValue.map(xpc_get_type) == XPC_TYPE_UINT64
                && xpc_dictionary_get_uint64(message, "upper") == 80
                && hysValue.map(xpc_get_type) == XPC_TYPE_UINT64
                && xpc_dictionary_get_uint64(message, "hysteresis") == 2
            check(messageOK, "用例75", "makeMessage 键存在且类型正确（cmd=STRING / upper/hys=UINT64）")

            let statusJSON = #"{"mode":"active"}"#
            let ok = DaemonXPC.okReply(statusJSON)
            let okOK = xpc_get_type(ok) == XPC_TYPE_DICTIONARY
                && xpc_dictionary_get_bool(ok, "ok") == true
                && xpc_dictionary_get_value(ok, "status").map(xpc_get_type) == XPC_TYPE_STRING
                && String(cString: xpc_dictionary_get_string(ok, "status")!) == statusJSON
            check(okOK, "用例75", "okReply 结构（ok=true + status 载荷一致）")

            let err = DaemonXPC.errorReply("需要 root 权限")
            let errOK = xpc_get_type(err) == XPC_TYPE_DICTIONARY
                && xpc_dictionary_get_bool(err, "ok") == false
                && xpc_dictionary_get_value(err, "error").map(xpc_get_type) == XPC_TYPE_STRING
                && String(cString: xpc_dictionary_get_string(err, "error")!) == "需要 root 权限"
            check(errOK, "用例75", "errorReply 结构（ok=false + error 载荷一致）")
        }

        // 用例 76：validateRequest——缺 cmd / 类型混淆（upper 传 string）/ cmd 超 32 字符
        // / 非字典 → nil；合法 → 结构化请求。
        do {
            let good = DaemonXPC.makeMessage(cmd: "setLimits", upper: 80, hysteresis: 2)
            let parsed = DaemonXPC.validateRequest(good)
            check(parsed?.cmd == "setLimits" && parsed?.upper == 80 && parsed?.hysteresis == 2,
                  "用例76", "合法请求 → 结构化结果")

            let noCmd = xpc_dictionary_create(nil, nil, 0)
            check(DaemonXPC.validateRequest(noCmd) == nil, "用例76", "缺 cmd → nil")

            let badUpper = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(badUpper, "cmd", "setLimits")
            xpc_dictionary_set_string(badUpper, "upper", "80")
            check(DaemonXPC.validateRequest(badUpper) == nil, "用例76", "upper 传 STRING → nil")

            let longCmd = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(longCmd, "cmd", String(repeating: "x", count: 33))
            check(DaemonXPC.validateRequest(longCmd) == nil, "用例76", "cmd 33 字符 → nil")

            let string = xpc_string_create("not-a-dict")
            check(DaemonXPC.validateRequest(string) == nil, "用例76", "非字典 → nil")
        }

        // MARK: - 场景（Phase 2 WP2 daemon 托管，用例 77–82）
        // 注册态/迁移/路由为 CellarCore 纯函数（不 import ServiceManagement）；
        // 状态映射矩阵的 adapter 在 App target（3 行 switch，本工具无法 import App），
        // 以独立实现的期望表镜像（与 matrixSweep 双实现同模式）。
        // 嵌入 plist lint 用 #filePath 反推仓库根——不依赖 cwd。

        // 用例 77：状态映射矩阵（SMAppService.Status → RegistrationStatus 规格快照）。
        // App 侧 adapter（DaemonInstaller）为 switch（本 SDK 共 4 态：notFound /
        // notRegistered / requiresApproval / enabled，其中前两者都落入「未注册」安装态），
        // 本工具无法 import App——以独立实现的期望表镜像矩阵并断言互异（matrixSweep 双实现同模式）。
        do {
            func expectedRegistration(_ name: String) -> RegistrationStatus {
                switch name {
                case "notFound", "notRegistered": return .notRegistered
                case "requiresApproval": return .pending
                case "enabled": return .enabled
                default: return .notRegistered   // @unknown default 与 App 侧 adapter 一致
                }
            }
            let rows: [(name: String, expected: RegistrationStatus)] = [
                ("notFound", .notRegistered),
                ("notRegistered", .notRegistered),
                ("requiresApproval", .pending),
                ("enabled", .enabled),
            ]
            var mapped: Set<RegistrationStatus> = []
            var ok = true
            for row in rows {
                mapped.insert(expectedRegistration(row.name))
                if expectedRegistration(row.name) != row.expected { ok = false }
            }
            check(ok, "用例77", "SDK 四态全映射且与 App 侧 adapter 期望一致")
            check(mapped.count == 3, "用例77", "三个注册态桶全部可达（不塌缩为单一态）")
            check(expectedRegistration("unknownFutureCase") == .notRegistered,
                  "用例77", "未知态回落 .notRegistered（@unknown default 语义）")
        }

        // 用例 78：迁移引导四象限（表格逐行）+ pending 过渡态折叠。
        do {
            check(migrationGuidance(legacyPlistExists: false, registration: .notRegistered) == .normalInstall,
                  "用例78", "无旧 plist + 未注册 → 正常安装入口")
            check(migrationGuidance(legacyPlistExists: false, registration: .enabled) == .running,
                  "用例78", "无旧 plist + enabled → 正常（显示运行中）")
            check(migrationGuidance(legacyPlistExists: true, registration: .notRegistered) == .migrateFromLegacy,
                  "用例78", "旧 plist + 未注册 → 迁移引导（App 不执行 root 操作）")
            check(migrationGuidance(legacyPlistExists: true, registration: .enabled) == .cleanMixedState,
                  "用例78", "旧 plist + enabled → 混合态清理引导")
            check(migrationGuidance(legacyPlistExists: false, registration: .pending) == .normalInstall
                    && migrationGuidance(legacyPlistExists: true, registration: .pending) == .migrateFromLegacy,
                  "用例78", "pending 过渡态按未注册象限折叠（授权轮询另有状态行）")
        }

        // 用例 79：daemonRoute 判定（路径含 ".app/" → appManaged；空 → unknown；其余 → manual）。
        do {
            check(daemonRoute(programPath: "/Applications/Cellar.app/Contents/Library/LaunchDaemons/cellar-daemon") == .appManaged,
                  "用例79", ".app 内二进制 → .appManaged")
            check(daemonRoute(programPath: "/private/tmp/Cellar2.app/Contents/Library/LaunchDaemons/cellar-daemon") == .appManaged,
                  "用例79", "任意位置的 .app 形态 → .appManaged")
            check(daemonRoute(programPath: "/Library/PrivilegedHelperTools/com.cellar.daemon") == .manual,
                  "用例79", "手工路线路径 → .manual")
            check(daemonRoute(programPath: "/opt/local/sbin/cellar-daemon") == .manual,
                  "用例79", "其他无 .app/ 路径 → .manual")
            check(daemonRoute(programPath: "") == .unknown,
                  "用例79", "空路径 → .unknown")
        }

        // 用例 79b：verifyRootOwnedDirectory（0.4.1 F-3；0.5.0 修订后语义）。
        // 非 root 测试进程无法构造 root 属主目录——通过路径只覆盖拒绝面：
        // 缺失 / uid≠0 / 组或其他可写位；uid==0 ∧ 0755 的通过路径由真机 install
        // 流程验证（本机 2026-09-03 root:admin 755 事故即该函数的回归现场）。
        // sudo 执行本套件时 uid 门不可达——跳过（P3-2 加固）。
        if geteuid() != 0 {
            do {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cellar-f3-verify-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let path = dir.path

                check(!verifyRootOwnedDirectory(path: path + "/missing"),
                      "用例79b", "路径不存在 → false（stat 失败 fail-secure）")
                // 测试目录属主=当前用户（uid≠0）→ uid 门拒绝，与 mode 无关。
                check(!verifyRootOwnedDirectory(path: path),
                      "用例79b", "uid≠0 → false（root 属主门）")
                try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: path)
                check(!verifyRootOwnedDirectory(path: path),
                      "用例79b", "组/其他可写位（0777）→ false（写面封堵门）")
            }
        }

        // 用例 80：launchctl print 输出解析（防线 c root 路径行）+ 解析→判定全链路。
        do {
            let sample = """
            system/com.cellar.daemon = {
                active count = 1
                path = /Library/LaunchDaemons/com.cellar.daemon.plist
                state = running

                program = /Library/PrivilegedHelperTools/com.cellar.daemon
                arguments = {
            """
            expectEqual(DaemonRoute.programPath(fromPrintOutput: sample),
                        "/Library/PrivilegedHelperTools/com.cellar.daemon",
                        "用例80", "提取 program 行路径（含前置空白与无关行）")

            let embedded = "program = /Applications/Cellar.app/Contents/Library/LaunchDaemons/cellar-daemon\n"
            expectEqual(DaemonRoute.programPath(fromPrintOutput: embedded),
                        "/Applications/Cellar.app/Contents/Library/LaunchDaemons/cellar-daemon",
                        "用例80", "托管形态同样解析")
            check(DaemonRoute.programPath(fromPrintOutput: "Could not find service") == nil,
                  "用例80", "未加载/找不到服务输出 → nil")
            check(DaemonRoute.programPath(fromPrintOutput: "") == nil,
                  "用例80", "空输出 → nil")

            let route = daemonRoute(programPath: DaemonRoute.programPath(fromPrintOutput: embedded) ?? "")
            check(route == .appManaged, "用例80", "解析 + 判定全链路 → .appManaged")
        }

        // 用例 81：锁路径常量（防线 b；daemon main 首个可执行逻辑据此 flock）。
        do {
            expectEqual(DaemonRegistration.daemonLockPath, "/var/run/com.cellar.daemon.lock",
                        "用例81", "锁路径 == /var/run/com.cellar.daemon.lock")
            check(DaemonRegistration.daemonLockPath.hasPrefix("/") && !DaemonRegistration.daemonLockPath.isEmpty,
                  "用例81", "锁路径为绝对路径")
        }

        // 用例 82：嵌入 plist 模板 lint（App/Tools/com.cellar.daemon.plist）——
        // §2.3 保留键逐一核对 + §2.5 自检断言（BundleProgram 字符串/无 ProgramArguments）。
        do {
            // #filePath = …/Sources/CellarCoreCheck/main.swift → 上溯三级到仓库根。
            let repoRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // Sources/CellarCoreCheck
                .deletingLastPathComponent()   // Sources
                .deletingLastPathComponent()   // 仓库根
            let plistURL = repoRoot.appendingPathComponent("App/Tools/com.cellar.daemon.plist")
            var root: [String: Any]?
            do {
                let data = try Data(contentsOf: plistURL)
                let raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                root = raw as? [String: Any]
            } catch {
                root = nil
            }
            check(root != nil, "用例82", "嵌入 plist 存在且可解析为字典（\(plistURL.path)）")
            if let root {
                var ok = true
                // 保留键清单（逐一核对，缺一不可）。
                ok = ok && (root["Label"] as? String) == "com.cellar.daemon"
                ok = ok && (root["RunAtLoad"] as? Bool) == true
                ok = ok && (root["ExitTimeOut"] as? Int) == 10
                ok = ok && (root["ProcessType"] as? String) == "Background"
                if let keepAlive = root["KeepAlive"] as? [String: Any] {
                    ok = ok && (keepAlive["SuccessfulExit"] as? Bool) == false
                } else {
                    ok = false
                }
                if let machServices = root["MachServices"] as? [String: Any] {
                    ok = ok && (machServices["com.cellar.daemon"] as? Bool) == true
                } else {
                    ok = false
                }
                check(ok, "用例82", "保留键逐一核对（Label/RunAtLoad/KeepAlive 字典/ExitTimeOut/MachServices/ProcessType）")
                // 嵌入专属键与删除键（§2.5 自检断言镜像）。
                ok = (root["BundleProgram"] as? String) == "Contents/Library/LaunchDaemons/cellar-daemon"
                ok = ok && root["ProgramArguments"] == nil
                ok = ok && root["StandardErrorPath"] == nil
                check(ok, "用例82", "BundleProgram 字符串正确 / 无 ProgramArguments / 无 StandardErrorPath")
            }
        }

        // 用例 83：route(fromPrintOutput:) 双格式判定（2026-09-01 真机输出 fixture）——
        // SMAppService/BTM 托管任务无 program 行（managed_by 归因），只认 program 行会误判 unknown。
        do {
            let btmManaged = """
            system/com.cellar.daemon = {
                active count = 2
                path = (submitted by smd.26709)
                type = Submitted
                managed_by = com.apple.xpc.ServiceManagement
                state = running

                program identifier = Contents/Library/LaunchDaemons/cellar-daemon (mode: 2)
                parent bundle identifier = com.cellar.app
                pid = 66792
            """
            expectEqual(DaemonRoute.route(fromPrintOutput: btmManaged), .appManaged,
                        "用例83", "BTM 托管格式（managed_by）→ .appManaged")
            check(DaemonRoute.programPath(fromPrintOutput: btmManaged) == nil,
                  "用例83", "BTM 托管格式无 program 行（旧解析路径在此为 nil）")

            let manual = """
            system/com.cellar.daemon = {
                state = running
                program = /Library/PrivilegedHelperTools/com.cellar.daemon
            }
            """
            expectEqual(DaemonRoute.route(fromPrintOutput: manual), .manual,
                        "用例83", "手工格式（program 行）→ .manual")
            expectEqual(DaemonRoute.route(fromPrintOutput: "Could not find service"), .unknown,
                        "用例83", "服务未加载 → .unknown")
            expectEqual(DaemonRoute.route(fromPrintOutput: ""), .unknown,
                        "用例83", "空输出 → .unknown")
        }

        // MARK: - 场景（Phase 2 WP3 App↔daemon 通信层，用例 84–88）
        // App 侧运行态/控制逻辑的可测部分下沉 CellarCore：轮询调度纯函数、
        // 图标映射全序、偏好持久化（注入 URL）。StatusController 本体在 App target
        // （依赖 ObservableObject/SMAppService，本工具不 import App——与用例 77 同模式）。

        // 用例 84：refreshInterval 刷新矩阵（双路线解耦定版）——面板可见 1s /
        // 关闭 60s；轮询与注册态无关（手工路线 daemon 同样服务于面板与图标）。
        do {
            check(refreshInterval(panelVisible: true) == 1,
                  "用例84", "可见 → 1s")
            check(refreshInterval(panelVisible: false) == 60,
                  "用例84", "关闭 → 60s")
        }

        // 用例 85：菜单栏图标映射全序矩阵（规格 §2.5 五条）+ nil 字段矩阵逐行钉死。
        // 独立实现以 switch 全称匹配（与实现的 if 短路链不同写法）——matrixSweep
        // 双实现同模式；nil 字段矩阵四行按规格原文逐字落测，防 WP4 扯皮。
        do {
            func expectedIcon(status: DaemonStatus?, connection: ConnectionState) -> MenuBarIconState {
                switch (connection, status?.mode, status?.lastExternalConnected, status?.lastChargingEnabled) {
                case (.unreachable, _, _, _): return .alert
                case (_, nil, _, _): return .disabled
                case (_, "disabled", _, _): return .disabled
                case (_, _, false, _): return .discharging
                case (_, _, _, true): return .charging
                default: return .holding
                }
            }
            func makeStatus(mode: String, external: Bool?, charging: Bool?) -> DaemonStatus {
                DaemonStatus(
                    version: "fixture", mode: mode, upperLimit: 80, hysteresis: 2,
                    lastExternalConnected: external, lastChargingEnabled: charging
                )
            }

            // 穷举：3 connection ×（nil status + 2 模式 × 3 外接态 × 3 充电态）= 57 点。
            let statuses: [DaemonStatus?] = [nil]
                + ["active", "disabled"].flatMap { mode in
                    [nil, false, true].flatMap { external in
                        [nil, false, true].map { charging in
                            makeStatus(mode: mode, external: external, charging: charging)
                        }
                    }
                }
            var checked = 0
            var mismatches: [String] = []
            for connection in [ConnectionState.connected, .unreachable, .unknown] {
                for status in statuses {
                    let actual = menuBarIconState(status: status, connection: connection)
                    let want = expectedIcon(status: status, connection: connection)
                    checked += 1
                    if actual != want {
                        mismatches.append(
                            "connection=\(connection) mode=\(status?.mode ?? "nil") "
                                + "external=\(status?.lastExternalConnected.map(String.init) ?? "nil") "
                                + "charging=\(status?.lastChargingEnabled.map(String.init) ?? "nil")："
                                + "实现=\(actual) 期望=\(want)"
                        )
                    }
                }
            }
            check(mismatches.isEmpty, "用例85", "穷举 \(checked) 点：实现与独立期望完全一致"
                + (mismatches.isEmpty ? "" : "（\(mismatches.joined(separator: "；")))"))

            // 规格 §2.5 nil 字段矩阵四行：
            // 双 nil（status=nil × 三 connection）、external nil + charging true、
            // disabled + unreachable。
            check(menuBarIconState(status: nil, connection: .unreachable) == .alert,
                  "用例85", "双 nil（status=nil + unreachable）→ .alert")
            check(menuBarIconState(status: nil, connection: .connected) == .disabled,
                  "用例85", "双 nil（status=nil + connected）→ .disabled（规则 2 全称覆盖）")
            check(menuBarIconState(status: nil, connection: .unknown) == .disabled,
                  "用例85", "双 nil（status=nil + unknown）→ .disabled")
            check(menuBarIconState(status: makeStatus(mode: "active", external: nil, charging: nil), connection: .connected) == .holding,
                  "用例85", "双 nil 字段（external=nil + charging=nil）→ .holding（初态语义）")
            check(menuBarIconState(status: makeStatus(mode: "active", external: nil, charging: true), connection: .connected) == .charging,
                  "用例85", "external=nil + charging=true → .charging（nil 不拦截规则 5）")
            check(menuBarIconState(status: makeStatus(mode: "disabled", external: true, charging: false), connection: .unreachable) == .alert,
                  "用例85", "disabled + unreachable → .alert（规则 1 优先于模式）")
        }

        // 用例 86：AppConfig 持久化回环（临时目录注入 URL）——save → load 全字段、
        // 权限 0644、临时文件清理（原子替换证据）、覆盖写。
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cellar-appconfig-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("app-config.json")
            let store = AppConfigStore(url: fileURL)

            let config = AppConfig(launchAtLogin: true, style: "wine")
            var saveOK = true
            do { try await store.save(config) } catch { saveOK = false }
            check(saveOK, "用例86", "save 无抛错（首写自动建父目录）")
            check(await store.load() == config, "用例86", "save → load 回环 == 原值（launchAtLogin + style 全字段）")

            let perms = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.posixPermissions] as? Int
            check(perms == 0o644, "用例86", "文件权限 0644")
            let tempURL = directory.appendingPathComponent(".app-config.json.tmp")
            check(!FileManager.default.fileExists(atPath: tempURL.path), "用例86", "临时文件已清理（rename 原子替换）")

            try await store.save(AppConfig(launchAtLogin: false, style: nil))
            check(await store.load() == AppConfig(launchAtLogin: false, style: nil),
                  "用例86", "覆盖写回环（默认值形态）")
        }

        // 用例 87：AppConfig 缺失/损坏回退默认（os_log 可见化，不抛错）。
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cellar-appconfig-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("app-config.json")
            let store = AppConfigStore(url: fileURL)

            check(await store.load() == .default, "用例87", "文件缺失 → 默认（launchAtLogin=false, style=nil）")
            try "not json{".write(to: fileURL, atomically: true, encoding: .utf8)
            check(await store.load() == .default, "用例87", "写入垃圾 JSON → load 回默认")
            try #"{"launchAtLogin":false,"style":42}"#.write(to: fileURL, atomically: true, encoding: .utf8)
            check(await store.load() == .default, "用例87", "字段类型不符（style=42）→ 解码失败回默认")
        }

        // 用例 88：面板「应用」本地预检矩阵（P1 补测：hysteresis 0/21 经 LimitPolicy
        // 预检拒绝；60 地板组合 60/20 通过作对照组）。
        do {
            expectThrows(try LimitPolicy(upperLimit: 80, hysteresis: 0),
                         as: LimitPolicyError.hysteresisOutOfRange(validRange: 1...20),
                         "用例88", "hys=0 预检拒绝")
            expectThrows(try LimitPolicy(upperLimit: 60, hysteresis: 21),
                         as: LimitPolicyError.hysteresisOutOfRange(validRange: 1...20),
                         "用例88", "hys=21 预检拒绝（含 60 地板组合）")
            check((try? LimitPolicy(upperLimit: 60, hysteresis: 20)) != nil,
                  "用例88", "60/20 通过预检（对照组）")
        }

        // 用例 89：时间戳本地时区渲染（真机验收缺陷回归：Date.description 恒为 UTC，
        // CLI 曾直出 +0000 与系统时钟差 8 小时）。固定时区断言确定性。
        do {
            // 样本取自验收反馈：2026-09-01 06:31:36 UTC == 14:31:36 上海。
            var components = DateComponents()
            components.year = 2026
            components.month = 9
            components.day = 1
            components.hour = 6
            components.minute = 31
            components.second = 36
            var utcCalendar = Calendar(identifier: .gregorian)
            utcCalendar.timeZone = TimeZone(identifier: "UTC")!
            guard let sample = utcCalendar.date(from: components) else {
                check(false, "用例89", "样本日期构造失败（固定 UTC 分量）")
                return
            }
            expectEqual(
                formatTimestamp(sample, timeZone: TimeZone(identifier: "Asia/Shanghai")!),
                "2026-09-01 14:31:36",
                "用例89", "UTC 样本按上海时区渲染为当地时钟")
            expectEqual(
                formatTimestamp(sample, timeZone: TimeZone(identifier: "UTC")!),
                "2026-09-01 06:31:36",
                "用例89", "UTC 时区渲染保持原值（对照旧缺陷输出形态）")
        }

        // MARK: - 场景（Phase 2 WP4 面板，用例 90+）
        // 菜单栏符号映射（规格 §2.2 候选表 + §7.3 图标纪律修订）、遥测采样节奏
        // （§2.1 独立门控）与状态行方向词（§7.2 P2-2 修复）。

        // 用例 90：五态符号映射——首选表逐行钉死 + 回退链逐行钉死 +
        // 首选与回退互异（防复制粘贴错行）+ 非空。
        do {
            let primary: [(MenuBarIconState, String)] = [
                (.charging, "bolt.fill"),
                (.holding, "gauge.with.needle"),
                (.discharging, "arrow.down.circle"),
                // disabled 首选 power.dotted：powerplug.slash 在 macOS 26 不存在
                // （Image 渲染为空 = 图标消失，真机验收事故回归）。
                (.disabled, "power.dotted"),
                (.alert, "exclamationmark.triangle.fill"),
            ]
            var ok = true
            for (state, expected) in primary {
                if menuBarSymbolName(for: state) != expected { ok = false }
            }
            check(ok, "用例90", "首选表逐行一致（charging/holding/discharging/disabled/alert；§7.3 discharging 改 arrow.down.circle）")

            let fallback: [(MenuBarIconState, String)] = [
                (.charging, "bolt.circle.fill"),
                (.holding, "circle.dashed"),
                (.discharging, "minus.circle"),
                (.disabled, "powerplug"),
                (.alert, "exclamationmark.triangle"),
            ]
            ok = true
            for (state, expected) in fallback {
                if menuBarSymbolFallbackName(for: state) != expected { ok = false }
            }
            check(ok, "用例90", "回退链逐行一致（五态）")

            ok = primary.allSatisfy { !$0.1.isEmpty && $0.1 != menuBarSymbolFallbackName(for: $0.0) }
            check(ok, "用例90", "首选非空且与回退互异（防行列错位复制）")
        }

        // 用例 91：遥测采样节奏矩阵（规格 §2.1 P0-2）——面板可见 1s / 关闭 nil；
        // 与 refreshInterval 并行独立（refreshInterval 保持 60s 图标档不回归）。
        do {
            check(telemetrySampleInterval(panelVisible: true) == 1,
                  "用例91", "面板可见 → 1s")
            check(telemetrySampleInterval(panelVisible: false) == nil,
                  "用例91", "面板关闭 → nil（停止采样）")
            check(refreshInterval(panelVisible: false) == 60,
                  "用例91", "对照：status 图标档关闭后仍 60s（遥测档不复用同一循环，互不干扰）")
        }

        // 用例 92：状态行电流方向词（规格 §7.2 P2-2 修复）——三分支
        // （充电/放电/隐藏）+ 全组合边界。修「停充态显示放电 0.00 A」自相矛盾：
        // 外接 + 停充 → nil（方向词隐藏、幅值照显）。
        do {
            check(currentDirectionWord(isCharging: true, externalConnected: true) == "充电",
                  "用例92", "充电中（外接）→ 充电")
            check(currentDirectionWord(isCharging: true, externalConnected: false) == "充电",
                  "用例92", "边界：isCharging 优先（外接断开瞬间仍按充电呈现）")
            check(currentDirectionWord(isCharging: false, externalConnected: false) == "放电",
                  "用例92", "电池供电（未外接）→ 放电")
            check(currentDirectionWord(isCharging: false, externalConnected: true) == nil,
                  "用例92", "外接 + 停充 → nil（方向词隐藏，修「停充显放电 0.00 A」）")
        }

        // 用例 108：CurrentDirection 枚举判定（WP4 §4.3 下沉——判定逻辑唯一真相，
        // 与用例 92 的薄包装中文 token 钉死互为镜像；StatusLineView 消费本枚举）。
        do {
            check(currentDirection(isCharging: true, externalConnected: true) == .charging,
                  "用例108", "充电中（外接）→ .charging")
            check(currentDirection(isCharging: true, externalConnected: false) == .charging,
                  "用例108", "边界：isCharging 优先 → .charging")
            check(currentDirection(isCharging: false, externalConnected: false) == .discharging,
                  "用例108", "电池供电（未外接）→ .discharging")
            check(currentDirection(isCharging: false, externalConnected: true) == nil,
                  "用例108", "外接 + 停充 → nil（方向词隐藏）")
        }

        // MARK: - 场景（Phase 2 WP5 首启引导 + 冲突门 + 通知中心，用例 93+）

        // 用例 93：引导转移矩阵（§2.1 定版）——显式规则逐条钉死 + 全组合穷举
        // （5 步 × 4 gate × 3 registration = 60 点）。done 为终结态：任何组合
        // 继续转移 = 非法 → nil。
        do {
            check(onboardingNext(step: .welcome, gate: .clear, registration: .notRegistered) == .conflictCheck,
                  "用例93", "welcome → conflictCheck（gate/registration 无关）")
            check(onboardingNext(step: .welcome, gate: .exactBlocked, registration: .enabled) == .conflictCheck,
                  "用例93", "welcome 无视 gate/registration（exact×enabled 亦前进冲突步）")
            check(onboardingNext(step: .conflictCheck, gate: .exactBlocked, registration: .notRegistered) == .conflictCheck,
                  "用例93", "exactBlocked 停留（硬阻断待清除）")
            check(onboardingNext(step: .conflictCheck, gate: .genericNeedsConfirm, registration: .pending) == .conflictCheck,
                  "用例93", "genericNeedsConfirm 停留（软警示待确认）")
            check(onboardingNext(step: .conflictCheck, gate: .clear, registration: .notRegistered) == .install,
                  "用例93", "clear → install")
            check(onboardingNext(step: .conflictCheck, gate: .genericConfirmed, registration: .enabled) == .install,
                  "用例93", "genericConfirmed → install")
            check(onboardingNext(step: .install, gate: .clear, registration: .enabled) == .limit,
                  "用例93", "install + enabled → limit（授权完成接续 step 4）")
            check(onboardingNext(step: .install, gate: .clear, registration: .notRegistered) == .install,
                  "用例93", "install + notRegistered 停留（UI 呈现安装入口）")
            check(onboardingNext(step: .install, gate: .exactBlocked, registration: .pending) == .install,
                  "用例93", "install + pending 停留（等待系统授权）")
            check(onboardingNext(step: .limit, gate: .clear, registration: .enabled) == .done,
                  "用例93", "limit → done")
            check(onboardingNext(step: .done, gate: .clear, registration: .enabled) == nil,
                  "用例93", "done 为终结态（继续转移 = 非法 nil）")
            check(onboardingNext(step: .done, gate: .genericConfirmed, registration: .notRegistered) == nil,
                  "用例93", "done 全组合非法（generic×notRegistered 亦 nil）")

            // 穷举：与独立期望实现（不同写法）逐点比对。
            var sweeps = 0
            var mismatches = 0
            let registrations: [RegistrationStatus] = [.notRegistered, .pending, .enabled]
            let gates: [ConflictGateOutcome] = [.clear, .exactBlocked, .genericNeedsConfirm, .genericConfirmed]
            func expected(_ step: OnboardingStep, _ gate: ConflictGateOutcome, _ registration: RegistrationStatus) -> OnboardingStep? {
                switch step {
                case .welcome: return .conflictCheck
                case .conflictCheck:
                    // 停留分支：exact 硬阻断 / generic 待确认；放行分支：clear / 已确认。
                    return (gate == .clear || gate == .genericConfirmed) ? .install : .conflictCheck
                case .install: return registration == .enabled ? .limit : .install
                case .limit: return .done
                case .done: return nil
                }
            }
            for step in OnboardingStep.allCases {
                for gate in gates {
                    for registration in registrations {
                        sweeps += 1
                        let actual = onboardingNext(step: step, gate: gate, registration: registration)
                        if actual != expected(step, gate, registration) {
                            mismatches += 1
                            print("  ✗ 用例93 穷举:\(step)/\(gate)/\(registration)：实际 \(String(describing: actual)) 期望 \(String(describing: expected(step, gate, registration)))")
                        }
                    }
                }
            }
            check(mismatches == 0 && sweeps == 60, "用例93", "全组合穷举 \(sweeps) 点与独立期望一致（含 done→nil 非法段）")
        }

        // 用例 94：通知分类矩阵（§2.3）——lastAction 字面量钉死精确值：
        // enforce:disableCharging / enforce:error / enforce:verifyFailed /
        // sleep:disableCharging / disable / enable / noop 全覆盖；
        // 首样本双例（limitReached 抑制 / writeFailed 破例）。
        do {
            func status(_ lastAction: String?, upper: Int = 90) -> DaemonStatus {
                DaemonStatus(
                    version: "0.3.0-alpha-dev", mode: "active", upperLimit: upper,
                    hysteresis: 2, lastAction: lastAction, lastPercent: 90,
                    lastExternalConnected: true, lastChargingEnabled: false
                )
            }

            // 首样本（previous == nil）双例 + 抑制面。
            check(notificationEvents(previous: nil, current: status("enforce:disableCharging")) == [],
                  "用例94", "首样本 enforce:disableCharging → 抑制（陈旧 lastAction 不触发限充通知）")
            check(notificationEvents(previous: nil, current: status("enforce:error")) == [.writeFailed],
                  "用例94", "首样本 enforce:error 破例产出 writeFailed（持续失败永久静默违红线 5）")
            check(notificationEvents(previous: nil, current: status("enforce:verifyFailed")) == [.conflictSuspected],
                  "用例94", "首样本 enforce:verifyFailed 破例产出 conflictSuspected")
            check(notificationEvents(previous: nil, current: status("enforce:noop")) == [],
                  "用例94", "首样本 enforce:noop → 不通知")
            check(notificationEvents(previous: nil, current: status("sleep:disableCharging")) == [],
                  "用例94", "首样本 sleep:disableCharging → 不通知（睡眠路径语义）")
            check(notificationEvents(previous: nil, current: status("disable")) == [],
                  "用例94", "首样本 disable → 不通知（用户动作）")

            // 转移触发三映射（previous.lastAction != current.lastAction）。
            check(notificationEvents(previous: status("enforce:noop"), current: status("enforce:disableCharging")) == [.limitReached(upperLimit: 90)],
                  "用例94", "转移 enforce:disableCharging → limitReached(90)（上限值取当前 status）")
            check(notificationEvents(previous: status("enforce:noop"), current: status("enforce:error")) == [.writeFailed],
                  "用例94", "转移 enforce:error → writeFailed")
            check(notificationEvents(previous: status("enforce:noop"), current: status("enforce:verifyFailed")) == [.conflictSuspected],
                  "用例94", "转移 enforce:verifyFailed → conflictSuspected")

            // 不报面：sleep:* / disable / enable / noop。
            check(notificationEvents(previous: status("enforce:enableCharging"), current: status("sleep:disableCharging")) == [],
                  "用例94", "sleep:disableCharging 不报（≠ enforce:disableCharging，睡眠停充语义）")
            check(notificationEvents(previous: status("enforce:disableCharging"), current: status("disable")) == [],
                  "用例94", "disable 不报（用户动作）")
            check(notificationEvents(previous: status("disable"), current: status("enable")) == [],
                  "用例94", "enable 不报（用户动作）")
            check(notificationEvents(previous: status("enforce:noop"), current: status("enforce:noop")) == [],
                  "用例94", "noop 不变不报")
            check(notificationEvents(previous: status("enforce:error"), current: status("enforce:error")) == [],
                  "用例94", "持续失败无转移不重报（App 重启后首样本破例兜底，不重复轰炸）")
            check(notificationEvents(previous: status("enforce:disableCharging"), current: status("enforce:noop")) == [],
                  "用例94", "离开限充（disableCharging→noop）不报")
            check(notificationEvents(previous: status("enforce:noop"), current: status("enforce:enableCharging")) == [],
                  "用例94", "恢复充电（noop→enableCharging）不报（不在通知映射）")
        }

        // 用例 95：AppConfig 扩展（§2.4）——缺 key 旧文件兼容 + 全字段解码 +
        // round-trip + encode 恒写新键。
        do {
            // 缺 onboardingCompleted key 的旧文件 → decodeIfPresent ?? false。
            let legacyJSON = "{\"launchAtLogin\":true}"
            let legacy = try JSONDecoder().decode(AppConfig.self, from: Data(legacyJSON.utf8))
            check(legacy.onboardingCompleted == false, "用例95", "旧文件缺 onboardingCompleted 键 → false")
            check(legacy.launchAtLogin == true, "用例95", "旧文件其余字段照常解码")

            let fullJSON = "{\"launchAtLogin\":false,\"style\":\"dark\",\"onboardingCompleted\":true}"
            let full = try JSONDecoder().decode(AppConfig.self, from: Data(fullJSON.utf8))
            check(full.onboardingCompleted == true && full.style == "dark" && full.launchAtLogin == false,
                  "用例95", "全字段解码")

            // round-trip + encode 恒写。
            let encoded = try JSONEncoder().encode(full)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
            check(decoded == full, "用例95", "round-trip：encode 后 decode 等值")
            let encodedText = String(data: encoded, encoding: .utf8) ?? ""
            check(encodedText.contains("onboardingCompleted"), "用例95", "encode 恒写新键（前向兼容）")
            check(decoded.onboardingCompleted == true, "用例95", "round-trip 保留 completed 值")

            // 默认值。
            check(AppConfig.default.onboardingCompleted == false && AppConfig.default.launchAtLogin == false,
                  "用例95", "AppConfig.default：completed 默认 false")
        }

        // MARK: - 场景（Phase 3 WP2 一次性动作「充满一次」，用例 96–104）
        // 纯函数/纯值验证：OneShot 判据、轨道六路径门控（规格 §1.1 表格的语义决策）、
        // 字面量与通知分类（P1-3/P1-4）、DaemonStatus 兼容（合成 Codable decodeIfPresent）、
        // ActionStore（临时目录）。daemon 目标不可 import——六路径的 IO 副作用（写 CHTE/
        // 删文件）在 daemon 调用点依轨道返回值执行（对照规格 §1.1 行）；轨道转移全部钉死。

        // 用例 96：OneShotAction Codable round-trip + kind 承载。
        do {
            let action = OneShotAction(
                kind: "fullOnce", startedAt: timeZero,
                deadline: timeZero.addingTimeInterval(4 * 3600)
            )
            let data = try JSONEncoder().encode(action)
            let decoded = try JSONDecoder().decode(OneShotAction.self, from: data)
            check(decoded == action, "用例96", "OneShotAction round-trip（kind/startedAt/deadline 全字段）")
            let defaulted = OneShotAction(startedAt: timeZero, deadline: timeZero)
            check(defaulted.kind == "fullOnce", "用例96", "kind 默认值 == fullOnce（契约字面量）")
        } catch {
            check(false, "用例96", "OneShotAction 编解码抛错：\(error)")
        }

        // 用例 97：fullOnce 启动前置矩阵（规格 §1.1/§1.3）——start 前置拒绝 ×3 + 放行。
        do {
            expectEqual(fullOnceStartPrecondition(mode: "disabled", externalConnected: true), .modeNotActive,
                        "用例97", "mode=disabled → 拒绝（modeNotActive）")
            expectEqual(fullOnceStartPrecondition(mode: "active", externalConnected: false), .noExternalPower,
                        "用例97", "未外接 → 拒绝（noExternalPower）")
            expectEqual(fullOnceStartPrecondition(mode: "active", externalConnected: nil), .noExternalPower,
                        "用例97", "外接未知（快照失败且无上次已知值）→ 拒绝（noExternalPower）")
            check(fullOnceStartPrecondition(mode: "active", externalConnected: true) == nil,
                  "用例97", "active + 已外接 → 放行")
            let rejection = OneShotStartRejection.noExternalPower
            check(rejection.message.contains("外接电源"), "用例97", "拒绝原文为中文可读文案（XPC errorReply 上屏）")
        }

        // 用例 98：完成判定矩阵（规格 §1.3）——主判据 / 降级 / false 恒不成立。
        do {
            check(OneShot.isFullOnceComplete(fullyCharged: true, isCharging: false, percent: 80),
                  "用例98", "主判据：fullyCharged=true + !isCharging → 完成（percent 不参与）")
            check(!OneShot.isFullOnceComplete(fullyCharged: true, isCharging: true, percent: 100),
                  "用例98", "主判据：isCharging=true → 未完成")
            check(OneShot.isFullOnceComplete(fullyCharged: nil, isCharging: false, percent: 99),
                  "用例98", "降级：fullyCharged=nil + percent=99 + !isCharging → 完成")
            check(OneShot.isFullOnceComplete(fullyCharged: nil, isCharging: false, percent: 100),
                  "用例98", "降级：percent=100 → 完成（边界含 99）")
            check(!OneShot.isFullOnceComplete(fullyCharged: nil, isCharging: false, percent: 98),
                  "用例98", "降级：percent=98（<99）→ 未完成")
            check(!OneShot.isFullOnceComplete(fullyCharged: nil, isCharging: true, percent: 100),
                  "用例98", "降级：充电中 + percent=100 → 未完成")
            check(!OneShot.isFullOnceComplete(fullyCharged: false, isCharging: false, percent: 100),
                  "用例98", "fullyCharged=false（键在位且为 No）→ 恒未完成（主判据/降级都不适用）")
        }

        // 用例 99：去抖推进（连续 2 tick 同条件；中断归零——计数由调用方持有传入）。
        do {
            var step = OneShot.debounceTick(conditionSatisfied: true, counter: 0)
            check(!step.satisfied && step.counter == 1, "用例99", "第 1 个满足 tick → 未达标、计数 1")
            step = OneShot.debounceTick(conditionSatisfied: true, counter: step.counter)
            check(step.satisfied && step.counter == 2, "用例99", "第 2 个连续满足 tick → 达标")
            step = OneShot.debounceTick(conditionSatisfied: false, counter: 1)
            check(!step.satisfied && step.counter == 0, "用例99", "中断（条件不满足）→ 计数归零")
            step = OneShot.debounceTick(conditionSatisfied: false, counter: 0)
            check(step.counter == 0, "用例99", "起始不满足 → 计数保持 0")
        }

        // 用例 100：轨道维护 tick 决策（规格 §1.1 performTickLocked 行）——两 tick 去抖、
        // 超时、完成优先于超时（长睡唤醒场景报 done 而非 timeout）、中断归零。
        do {
            let t0 = Date(timeIntervalSince1970: 0)
            var track = OneShotTrack()
            check(track.startIfIdle(now: t0), "用例100", "空轨 startIfIdle → 启动成功")
            let first = track.tick(now: t0.addingTimeInterval(30), fullyCharged: true, isCharging: false, percent: 100)
            check(first == .keepAlive && track.latchedLiteral == nil && track.debounceTicks == 1,
                  "用例100", "第 1 个完成 tick → keepAlive + 去抖计数 1（未锁存）")
            let second = track.tick(now: t0.addingTimeInterval(60), fullyCharged: true, isCharging: false, percent: 100)
            check(second == .completed && track.action == nil && track.latchedLiteral == OneShotLiteral.done(),
                  "用例100", "第 2 个连续完成 tick → completed + done 锁存 + 动作清空")
            let third = track.tick(now: t0.addingTimeInterval(90), fullyCharged: true, isCharging: false, percent: 100)
            check(third == .idle && track.latchedLiteral == OneShotLiteral.done(),
                  "用例100", "终态后 tick（空轨）→ idle、done 锁存保持（P0-2 常规 tick 不覆盖）")
            check(track.effectiveLastAction("enforce:noop") == OneShotLiteral.done(),
                  "用例100", "锁存生效：构造值 enforce:noop 被 done 覆盖")

            var timed = OneShotTrack()
            _ = timed.startIfIdle(now: t0)
            let out = timed.tick(now: t0.addingTimeInterval(4 * 3600 + 60), fullyCharged: false, isCharging: true, percent: 50)
            check(out == .timedOut && timed.latchedLiteral == OneShotLiteral.timeout() && timed.action == nil,
                  "用例100", "未完成 + now >= deadline → timedOut + timeout 锁存")

            var priority = OneShotTrack()
            _ = priority.startIfIdle(now: t0)
            let late = priority.tick(now: t0.addingTimeInterval(4 * 3600 + 60), fullyCharged: true, isCharging: false, percent: 100)
            check(late == .keepAlive && priority.debounceTicks == 1 && priority.action != nil,
                  "用例100", "同 tick 完成成立 + 已过 deadline → 完成优先（不超时、去抖推进）")

            var inter = OneShotTrack()
            _ = inter.startIfIdle(now: t0)
            _ = inter.tick(now: t0.addingTimeInterval(30), fullyCharged: true, isCharging: false, percent: 100)
            _ = inter.tick(now: t0.addingTimeInterval(60), fullyCharged: false, isCharging: true, percent: 99)
            let re = inter.tick(now: t0.addingTimeInterval(90), fullyCharged: true, isCharging: false, percent: 100)
            check(re == .keepAlive && inter.debounceTicks == 1,
                  "用例100", "去抖中断归零：完成→中断→完成 → 重新从 1 累计")

            var degraded = OneShotTrack()
            _ = degraded.startIfIdle(now: t0)
            _ = degraded.tick(now: t0.addingTimeInterval(30), fullyCharged: nil, isCharging: false, percent: 99)
            let deg = degraded.tick(now: t0.addingTimeInterval(60), fullyCharged: nil, isCharging: false, percent: 99)
            check(deg == .completed && degraded.latchedLiteral == OneShotLiteral.done(),
                  "用例100", "降级判据经两 tick 去抖 → completed（done 锁存）")

            let started = OneShot.onshotStart(now: t0)
            check(started.kind == OneShot.fullOnceKind && started.deadline == t0.addingTimeInterval(OneShot.fullOnceTimeout),
                  "用例100", "onshotStart：deadline = now + 4h（绝对 Date，SIGHUP 不重算）")
        }

        // 用例 101：六路径门控轨道语义（规格 §1.1 表格）——幂等三分支、用户动作清锁存、
        // SIGHUP 两分支（deadline 不重算）、崩溃恢复两态。
        do {
            let t0 = Date(timeIntervalSince1970: 0)
            var track = OneShotTrack()
            check(track.startIfIdle(now: t0), "用例101", "空轨启动成功")
            check(!track.startIfIdle(now: t0.addingTimeInterval(10)), "用例101", "已活跃时再次启动 → 拒绝（幂等一：回当前状态）")
            let cancelLiteral = track.cancel()
            check(cancelLiteral == OneShotLiteral.cancel() && track.action == nil && track.latchedLiteral == nil,
                  "用例101", "用户取消 → cancel 字面量（不锁存）+ 动作清空 + 清锁存")
            check(track.cancel() == nil, "用例101", "无动作取消 → nil（幂等二：XPC 幂等成功）")

            var latch = OneShotTrack()
            _ = latch.startIfIdle(now: t0)
            _ = latch.tick(now: t0.addingTimeInterval(30), fullyCharged: true, isCharging: false, percent: 100)
            _ = latch.tick(now: t0.addingTimeInterval(60), fullyCharged: true, isCharging: false, percent: 100)
            check(latch.latchedLiteral == OneShotLiteral.done(), "用例101", "完成 → done 锁存就位")
            _ = latch.startIfIdle(now: t0.addingTimeInterval(120))
            check(latch.latchedLiteral == nil && latch.isActive, "用例101", "新动作启动（用户动作）→ 清除终态锁存")

            var reload = OneShotTrack()
            _ = reload.startIfIdle(now: t0)
            let deadlineBefore = reload.action?.deadline
            check(reload.reload(cancelled: false) == nil && reload.isActive && reload.action?.deadline == deadlineBefore,
                  "用例101", "SIGHUP 重载（未 disabled）→ 动作存活、deadline 不重算")
            check(reload.reload(cancelled: true) == OneShotLiteral.cancel() && !reload.isActive,
                  "用例101", "SIGHUP 重载（disabled）→ 取消动作（cancel 字面量）")

            var crash = OneShotTrack()
            _ = crash.startIfIdle(now: t0)
            let crashLiteral = crash.cancelForCrashRecovery()
            check(crashLiteral == OneShotLiteral.cancelCrashRecovery()
                    && crash.action == nil && crash.latchedLiteral == OneShotLiteral.cancelCrashRecovery(),
                  "用例101", "崩溃恢复 → 一律取消 + crash-recovery 字面量锁存（P0-2 首 tick 不覆盖）")
            var emptyTrack = OneShotTrack()
            check(emptyTrack.cancelForCrashRecovery() == nil, "用例101", "崩溃恢复（无动作文件语义）→ nil（无动作启动）")
            check(track.effectiveLastAction("enforce:noop") == "enforce:noop",
                  "用例101", "无锁存时生效值 = 构造值（常规 tick 原样）")
        }

        // 用例 102：fullOnce 字面量与通知分类（P1-3/P1-4）——start 首样本无事件、
        // 终态三映射、cancel 无事件、P1-4 抑制（终态后恢复停充不误报 limitReached）、
        // 锁存期重复样本无重复、既有字面量回归。
        do {
            func status(_ lastAction: String?, upper: Int = 90) -> DaemonStatus {
                DaemonStatus(
                    version: "fixture", mode: "active", upperLimit: upper,
                    hysteresis: 2, lastAction: lastAction, lastPercent: 90,
                    lastExternalConnected: true, lastChargingEnabled: false
                )
            }
            check(notificationEvents(previous: nil, current: status("fullOnce:start")) == [],
                  "用例102", "首样本 fullOnce:start → 无事件（previous==nil 既有语义）")
            check(notificationEvents(previous: status("fullOnce:start"), current: status("fullOnce:done")) == [.actionCompleted(kind: "fullOnce")],
                  "用例102", "start→done 转移 → actionCompleted(kind: fullOnce)")
            check(notificationEvents(previous: status("fullOnce:start"), current: status("fullOnce:timeout")) == [.actionTimeout(kind: "fullOnce")],
                  "用例102", "start→timeout 转移 → actionTimeout")
            check(notificationEvents(previous: status("fullOnce:start"), current: status("fullOnce:cancel(crash-recovery)")) == [.actionInterrupted(kind: "fullOnce")],
                  "用例102", "start→cancel(crash-recovery) 转移 → actionInterrupted")
            check(notificationEvents(previous: status("fullOnce:start"), current: status("fullOnce:cancel")) == [],
                  "用例102", "start→cancel 转移 → 无事件（用户/隐式取消不打扰）")
            check(notificationEvents(previous: status("fullOnce:done"), current: status("fullOnce:done")) == [],
                  "用例102", "锁存期重复样本（done→done）→ 无重复事件")
            check(notificationEvents(previous: status("fullOnce:timeout"), current: status("fullOnce:timeout")) == [],
                  "用例102", "锁存期重复样本（timeout→timeout）→ 无重复事件")
            check(notificationEvents(previous: status("fullOnce:done"), current: status("enforce:disableCharging")) == [],
                  "用例102", "P1-4：done 终态后恢复停充 → 不产 limitReached")
            check(notificationEvents(previous: status("fullOnce:cancel(crash-recovery)"), current: status("enforce:disableCharging")) == [],
                  "用例102", "P1-4：crash-recovery 终态后恢复停充 → 不产 limitReached")
            check(notificationEvents(previous: status("enforce:noop"), current: status("enforce:disableCharging")) == [.limitReached(upperLimit: 90)],
                  "用例102", "回归：普通 enforce 转移 → limitReached 照旧（P1-4 仅抑制 fullOnce 前缀）")
            check(notificationEvents(previous: status("fullOnce:done"), current: status("enforce:error")) == [.writeFailed],
                  "用例102", "回归：终态后写失败 → writeFailed 照旧（失败类不受 P1-4 抑制）")
            check(notificationEvents(previous: status("fullOnce:done"), current: status("disable")) == [],
                  "用例102", "回归：终态后用户 disable → 无事件（用户动作语义不变）")
        }

        // 用例 103：DaemonStatus.action 兼容（合成 Codable decodeIfPresent）——
        // 旧 JSON 无 action 键 → 解码 nil + 既有字段照常；新 JSON 往返含 action。
        do {
            let legacyJSON = #"{"version":"legacy-version","mode":"active","upperLimit":80,"hysteresis":2,"lastAction":"enforce:disableCharging","lastPercent":80,"lastExternalConnected":true,"lastChargingEnabled":false,"timestamp":123.0}"#
            let legacy = try? JSONDecoder().decode(DaemonStatus.self, from: Data(legacyJSON.utf8))
            check(legacy?.action == nil && legacy?.mode == "active" && legacy?.upperLimit == 80 && legacy?.lastAction == "enforce:disableCharging",
                  "用例103", "旧 JSON（无 action 键）解码 → action=nil 且既有字段照常（升级窗口兼容）")

            let newStatus = DaemonStatus(
                version: "0.3.0-alpha-dev", mode: "active", upperLimit: 80, hysteresis: 2,
                lastAction: "fullOnce:start", lastPercent: 96,
                lastExternalConnected: true, lastChargingEnabled: true,
                action: OneShotAction(
                    kind: "fullOnce",
                    startedAt: Date(timeIntervalSince1970: 100),
                    deadline: Date(timeIntervalSince1970: 100 + 4 * 3600)
                ),
                timestamp: Date(timeIntervalSince1970: 120)
            )
            let round = DaemonXPC.encodeStatus(newStatus).flatMap { try? DaemonXPC.decodeStatus($0) }
            check(round == newStatus, "用例103", "新 JSON 往返（action 非 nil 全字段保留）")
        }

        // 用例 104：ActionStore 原子写/读/删（临时目录；独立于 policy.json 格式红线）。
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cellar-actionstore-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = ActionStore(url: directory.appendingPathComponent("action.json"))

            check(store.load() == nil && !store.fileExists, "用例104", "文件缺失 → nil（无动作启动语义）")

            let action = OneShotAction(
                kind: "fullOnce", startedAt: timeZero,
                deadline: timeZero.addingTimeInterval(4 * 3600)
            )
            try store.save(action)
            check(store.load() == action, "用例104", "save → load 回环 == 原值")
            let perms = (try? FileManager.default.attributesOfItem(atPath: store.url.path))?[.posixPermissions] as? Int
            check(perms == 0o644, "用例104", "文件权限 0644")
            let tempURL = directory.appendingPathComponent(".action.json.tmp")
            check(!FileManager.default.fileExists(atPath: tempURL.path), "用例104", "临时文件已清理（rename 原子替换）")

            try "not json".write(to: store.url, atomically: true, encoding: .utf8)
            check(store.load() == nil && store.fileExists, "用例104", "损坏文件 → nil + 文件仍在（启动按损坏处置：删 + 无动作）")
            try store.delete()
            check(!store.fileExists && store.load() == nil, "用例104", "delete → 文件消失 + load nil")
            try store.delete()
            check(!store.fileExists, "用例104", "幂等删除（缺失视为成功，双删不抛）")

            try store.save(action)
            let unknownKind = OneShotAction(
                kind: "discharge", startedAt: timeZero,
                deadline: timeZero.addingTimeInterval(3600)
            )
            try JSONEncoder().encode(unknownKind).write(to: store.url)
            check(store.load() == nil && store.fileExists, "用例104", "kind != fullOnce → nil（未知动作 treat-as-absent）")
        }

        // MARK: - 场景（Phase 3 WP3 风格系统，用例 105–107）
        // PanelStyle.validating 矩阵（§3.1：nil=未设置 vs 未知串语义分界在调用方日志）、
        // vocabularyKey 完整性（§3.5 对账表 2 风格 × 7 词条）、AppConfigStore.update
        // 原子读改写（评审 P0-1：字段互不覆盖矩阵 + 写失败上抛）。

        // 用例 105：validating 矩阵——nil/空串/未知串 → nil；"native"/"amber" 合法；
        // 大小写敏感（"Amber" 必须未知——手改 JSON 不猜意图）。
        do {
            check(PanelStyle.validating(nil) == nil, "用例105", "nil → nil（未设置 = 默认合法态，调用方不记日志）")
            check(PanelStyle.validating("") == nil, "用例105", "空串 → nil（未知值路径，调用方须 os_log）")
            check(PanelStyle.validating("native") == .native, "用例105", "\"native\" → .native")
            check(PanelStyle.validating("amber") == .amber, "用例105", "\"amber\" → .amber")
            check(PanelStyle.validating("Amber") == nil, "用例105", "\"Amber\" → nil（大小写敏感）")
            check(PanelStyle.validating("dark") == nil, "用例105", "\"dark\" → nil（未知串）")
        }

        // 用例 106：vocabularyKey 完整性——2 风格 × 全词条产出合法 key
        // （非空 + 前缀 vocabulary.<style>. + 词条名落尾）+ 词条集合钉死 7 个
        // （延后词条不建死键，§3.5）。
        do {
            var allOK = true
            for style in [PanelStyle.native, .amber] {
                for word in VocabularyWord.allCases {
                    let key = PanelStyle.vocabularyKey(style: style, word: word)
                    if key.isEmpty { allOK = false }
                    if !key.hasPrefix("vocabulary.\(style.rawValue).") { allOK = false }
                    if !key.hasSuffix(word.rawValue) { allOK = false }
                }
            }
            check(allOK, "用例106", "2 风格 × 全词条 key 非空且含正确前缀/词条名落尾")
            check(
                PanelStyle.vocabularyKey(style: .amber, word: .statusHoldingExternal)
                    == "vocabulary.amber.statusHoldingExternal",
                "用例106", "key 形态钉死：vocabulary.<style>.<word>（§3.6 示例 = 真实词条名）"
            )
            check(VocabularyWord.allCases.count == 16, "用例106", "词条数 = 16（对账表定版 7 成员 + WP2' 新增 4：powerFlow×3 + health×1 + 走查批 F1 新增 5：dashboard*×5，不多不少）")
        }

        // 用例 107：AppConfigStore.update 原子读改写（评审 P0-1 定版）——
        // 单字段改写不覆盖其余字段（互不覆盖矩阵三行）+ 读缺失回退默认再改写 +
        // 写失败原样上抛。
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cellar-appconfig-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("app-config.json")
            let store = AppConfigStore(url: fileURL)

            // 预置全字段非默认初值（style 取合法存储值形态）。
            try await store.save(AppConfig(launchAtLogin: false, style: "amber", onboardingCompleted: false))

            var updated = try await store.update { $0.launchAtLogin = true }
            check(updated.launchAtLogin && updated.style == "amber" && !updated.onboardingCompleted,
                  "用例107", "改 launchAtLogin → style/onboardingCompleted 保持（互不覆盖一）")
            check(await store.load() == updated, "用例107", "update 返回值 == 磁盘状态（RMW 落盘）")

            updated = try await store.update { $0.onboardingCompleted = true }
            check(updated.onboardingCompleted && updated.launchAtLogin && updated.style == "amber",
                  "用例107", "改 onboardingCompleted → launchAtLogin/style 保持（互不覆盖二）")

            updated = try await store.update { $0.style = "native" }
            check(updated.style == "native" && updated.launchAtLogin && updated.onboardingCompleted,
                  "用例107", "改 style → launchAtLogin/onboardingCompleted 保持（互不覆盖三）")

            // 读失败（文件缺失）→ 回退默认再改写（与 load 同语义）。
            try FileManager.default.removeItem(at: fileURL)
            updated = try await store.update { $0.style = "amber" }
            check(updated == AppConfig(launchAtLogin: false, style: "amber", onboardingCompleted: false),
                  "用例107", "读失败（文件缺失）→ 回退默认再改写")

            // 写失败上抛：父路径置为普通文件——save 建目录必失败，错误不得被吞。
            try "x".write(to: directory.appendingPathComponent("blocker"), atomically: true, encoding: .utf8)
            let blockedStore = AppConfigStore(
                url: directory.appendingPathComponent("blocker").appendingPathComponent("app-config.json")
            )
            do {
                _ = try await blockedStore.update { $0.launchAtLogin = true }
                check(false, "用例107", "写失败须上抛——但未抛错")
            } catch {
                check(true, "用例107", "写失败原样上抛（父路径为普通文件，建目录失败）")
            }
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

    // MARK: - doctor 报告生成演示（--doctor-report）
    // DoctorInputs 内存构造（与场景 65/67 相同构造），直接调 DoctorReportGenerator；
    // 渲染格式与 cellar doctor 可执行层一致。纯函数演示，无需真机、不触碰任何系统状态。

    static func doctorReport() {
        print("=== doctor 报告生成演示（内存构造，只读）===")
        let healthy = DoctorInputs(
            isRoot: true,
            smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false,
            chargingError: nil,
            snapshot: try? BatterySnapshotParser.parse(batteryProps(), timestamp: Date()),
            snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: [])
        )
        renderDoctorDemo(DoctorReportGenerator.generate(healthy))

        let coexisting = DoctorInputs(
            isRoot: false,
            smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false,
            chargingError: nil,
            snapshot: try? BatterySnapshotParser.parse(batteryProps(), timestamp: Date()),
            snapshotError: nil,
            conflict: ConflictScanResult(exact: ["batt.daemon"], generic: ["my.power.monitor"])
        )
        renderDoctorDemo(DoctorReportGenerator.generate(coexisting))
        exit(0)
    }

    private static func renderDoctorDemo(_ report: DoctorReport) {
        for check in report.checks {
            print("[\(check.status.rawValue.uppercased())] \(check.name)：\(check.detail)")
        }
        print("worstStatus=\(report.worstStatus.rawValue) · exitCode=\(report.exitCode)\n")
    }
}
