// CellarCoreCheck —— 0.21.0 §4 温度 Pack 层解析场景域（方案 §4；S4 实证输入）
//
// 按域拆独立文件（CHHysteresisDomain 先例）。覆盖清单（M2 工单验收门禁钉死项）：
// ①27 形态——顶层无 Temperature ∧ Pack 层命中（BatteryData 子字典 = S4 实证主形态；
//   Pack 顶层 = 防迁移再断的兜底查找位）
// ②优先级——顶层 > Pack（26 形态零变化）；Pack > SMC 回退（v0.19.8 既有回退保留）
// ③26 回退——Pack 缺席（nil）∧ fallback 命中 → SMC 兜底（0.19.8 语义逐值不变）；
//   Pack 缺席 ∧ SMC 未挂 → 错误原文不变（G3）
// ④容错——Pack 层类型不符按缺席处理继续降级（回退层尽力而为面，不吞顶层类型错误
//   语义——顶层类型错误仍 .invalidFieldType 原样抛出，R2 P3 语义保持）
// ⑤Monitor 重试链——26 顶层命中 → Pack/SMC 闭包零调用（零 IO——26 红线）；27 顶层
//   缺失 → Pack 命中且 SMC 零调用；Pack 未命中 → SMC 兜底；首读绑定复用（P3-3——
//   回退链/主路 properties() 恰一次）
//
// 全部纯函数面 + 注入缝 mock（StaticPropertySource 同款——MainEntry 场景 117/118
// 先例），不触碰真实 SMC/IOKit。

import CellarCore
import Foundation

/// Pack 域注入式静态数据源（MainEntry 场景 117/118 的 StaticPropertySource 为
/// private——本域自带同款；`[String: Any]` 非 Sendable → `@unchecked` 先例同评审 C-2）。
private struct PackStaticPropertySource: BatteryPropertySource, @unchecked Sendable {
    let props: [String: Any]
    func properties() throws -> [String: Any] { props }
}

/// 闭包调用计数盒（@Sendable 闭包内可变捕获——Swift 6 严格并发，FailureCounter
/// 同款 @unchecked Sendable 模式）。
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    var value = 0
    func increment() { lock.withLock { value += 1 } }
}

/// properties() 调用计数源（review P3-3 首读绑定复用钉面——CallCounter 同款模式）。
private final class CountingPropertySource: BatteryPropertySource, @unchecked Sendable {
    let props: [String: Any]
    let counter: CallCounter
    init(props: [String: Any], counter: CallCounter) {
        self.props = props
        self.counter = counter
    }
    func properties() throws -> [String: Any] {
        counter.increment()
        return props
    }
}

/// Pack 域场景入口（Main.main 调用）。
func runPackTemperatureDomainScenarios() throws {
    try runPackParserScenarios()
    try runPackMonitorScenarios()
}

/// Pack 域测试时间锚（MainEntry 用例 113–118 的 timeZero 同值）。
private let packTimeZero = Date(timeIntervalSince1970: 0)

/// 27 形态顶层 fixture（batteryProps() 去 Temperature——27 GA 顶层键消失）。
private func packProps27() -> [String: Any] {
    var props = batteryProps()
    props.removeValue(forKey: "Temperature")
    return props
}

/// Pack 层 fixture（S4 实证形态：Temperature 位于 BatteryData 子字典）。
private func packDict(batteryDataTemperature: Int? = 3350, topLevelTemperature: Int? = nil,
                      batteryDataTypeMismatch: Bool = false) -> [String: Any] {
    var pack: [String: Any] = [:]
    if let topLevelTemperature {
        pack["Temperature"] = topLevelTemperature
    }
    if batteryDataTypeMismatch {
        pack["BatteryData"] = ["Temperature": "hot"] as [String: Any]
    } else if let batteryDataTemperature {
        pack["BatteryData"] = ["Temperature": batteryDataTemperature] as [String: Any]
    }
    return pack
}

// MARK: - ①-④ 解析器四分支链（顶层 > Pack > SMC）

private func runPackParserScenarios() throws {
    // Pack-1：27 主形态——顶层缺失 ∧ Pack.BatteryData.Temperature 命中
    //（S4 实证：GA 上 Temperature 仅 Pack 层可见）。
    do {
        let s = try BatterySnapshotParser.parse(
            packProps27(), timestamp: packTimeZero,
            packProperties: packDict(batteryDataTemperature: 3350))
        expectEqual(s.temperatureCentiC, 3350, "Pack-1",
                    "顶层缺失 + Pack.BatteryData.Temperature=3350 → 3350（27 主回退层）")
        expectEqual(s.percent, 86, "Pack-1", "其余必需字段不受影响（抽查 percent）")
    }

    // Pack-2：Pack 顶层 Temperature 命中（BatteryData 缺席形态——防字段迁移再断
    // 的第二查找位；spike 工具读取形态同源）。
    do {
        let s = try BatterySnapshotParser.parse(
            packProps27(), timestamp: packTimeZero,
            packProperties: packDict(batteryDataTemperature: nil, topLevelTemperature: 3360))
        expectEqual(s.temperatureCentiC, 3360, "Pack-2",
                    "Pack 顶层 Temperature=3360 → 3360（无 BatteryData 亦命中）")
    }

    // Pack-3：优先级——顶层在位 ∧ Pack 同时在位 → 顶层赢（26 形态零变化钉死）。
    do {
        let s = try BatterySnapshotParser.parse(
            batteryProps(), timestamp: packTimeZero,
            packProperties: packDict(batteryDataTemperature: 3350))
        expectEqual(s.temperatureCentiC, 3030, "Pack-3",
                    "顶层 3030 在位 → Pack 3350 不生效（优先级：顶层 > Pack——26 零变化）")
    }

    // Pack-4：Pack 层内部序——Pack 顶层 > Pack.BatteryData（两处同在时的确定性）。
    do {
        let s = try BatterySnapshotParser.parse(
            packProps27(), timestamp: packTimeZero,
            packProperties: packDict(batteryDataTemperature: 3350, topLevelTemperature: 3370))
        expectEqual(s.temperatureCentiC, 3370, "Pack-4",
                    "Pack 顶层 3370 ∧ BatteryData 3350 → 3370（Pack 节点内顶层优先）")
    }

    // Pack-5：SMC 回退保留——Pack 缺席（nil）∧ fallback 命中 → fallback
    //（v0.19.8 既有语义逐值不变——G1 臂回归锚）。
    do {
        let s = try BatterySnapshotParser.parse(
            packProps27(), timestamp: packTimeZero, temperatureFallbackCentiC: 2950)
        expectEqual(s.temperatureCentiC, 2950, "Pack-5",
                    "Pack 缺席 + fallback=2950 → 2950（SMC 回退保留—— packProperties 缺省 nil 既有构造零 diff）")
    }

    // Pack-6：三层链——Pack 在位但无 Temperature ∧ fallback 在位 → SMC 兜底。
    do {
        let s = try BatterySnapshotParser.parse(
            packProps27(), timestamp: packTimeZero, temperatureFallbackCentiC: 2950,
            packProperties: packDict(batteryDataTemperature: nil))
        expectEqual(s.temperatureCentiC, 2950, "Pack-6",
                    "Pack 无 Temperature 键 → 落 SMC fallback=2950（顶层 > Pack > SMC 链序）")
    }

    // Pack-7：全缺——顶层/Pack/SMC 三层皆无 → .missingRequiredField 错误原文不变
    //（G3——Pack 层扩展不改变错误面）。
    do {
        expectThrows(
            try BatterySnapshotParser.parse(
                packProps27(), timestamp: packTimeZero,
                packProperties: packDict(batteryDataTemperature: nil)),
            as: BatteryMonitorError.missingRequiredField("Temperature"),
            "Pack-7", "三层全缺 → .missingRequiredField(\"Temperature\") 原文不变")
    }

    // Pack-8：Pack 层类型不符容错——值非 0/1 数值按该层缺席处理继续降级（回退层
    // 尽力而为面：严格抛错会让监控整体退化 vs 现行 SMC 路径——诚实降级取舍）。
    do {
        let s = try BatterySnapshotParser.parse(
            packProps27(), timestamp: packTimeZero, temperatureFallbackCentiC: 2950,
            packProperties: packDict(batteryDataTypeMismatch: true))
        expectEqual(s.temperatureCentiC, 2950, "Pack-8",
                    "Pack.BatteryData.Temperature 类型不符 → 按缺席降级 SMC 2950（回退层容错）")
    }

    // Pack-9：顶层类型错误语义保持——顶层键在位但类型不符 → .invalidFieldType
    // 原样抛出（Pack/SMC 回退不吞顶层类型错误——R2 P3 语义保持，v0.19.8 用例 116
    // 同款钉面 + Pack 层在位形态）。
    do {
        var props = batteryProps()
        props["Temperature"] = "hot"
        expectThrows(
            try BatterySnapshotParser.parse(
                props, timestamp: packTimeZero, temperatureFallbackCentiC: 2950,
                packProperties: packDict(batteryDataTemperature: 3350)),
            as: BatteryMonitorError.invalidFieldType("Temperature"),
            "Pack-9", "顶层类型不符 → .invalidFieldType（回退层在位也不吞顶层类型错误）")
    }
}

// MARK: - ⑤ Monitor 重试链（注入缝——零 IO 断言）

private func runPackMonitorScenarios() throws {
    // Pack-10：26 主路——顶层命中 → Pack/SMC 闭包零调用（零 IOKit 子树读/零 SMC
    // 读——26 红线：正常路径零额外 IO）。
    do {
        let packCalls = CallCounter()
        let smcCalls = CallCounter()
        let monitor = BatteryMonitor(
            source: PackStaticPropertySource(props: batteryProps()),
            smcTemperatureFallbackCentiC: { smcCalls.increment(); return 2950 },
            packPropertiesSource: { packCalls.increment(); return packDict() })
        let s = try monitor.snapshot()
        expectEqual(s.temperatureCentiC, 3030, "Pack-10", "26 顶层命中 → 温度 3030")
        check(packCalls.value == 0 && smcCalls.value == 0,
              "Pack-10", "顶层命中拍 Pack/SMC 闭包零调用（26 零额外 IO——红线）")
    }

    // Pack-11：27 主链——顶层缺失 → Pack 命中（3350）且 SMC 零调用（优先级：
    // Pack > SMC——§4 钉死）。
    do {
        let smcCalls = CallCounter()
        let monitor = BatteryMonitor(
            source: PackStaticPropertySource(props: packProps27()),
            smcTemperatureFallbackCentiC: { smcCalls.increment(); return 2950 },
            packPropertiesSource: { packDict(batteryDataTemperature: 3350) })
        let s = try monitor.snapshot()
        expectEqual(s.temperatureCentiC, 3350, "Pack-11", "27 顶层缺失 + Pack 命中 → 3350")
        check(smcCalls.value == 0, "Pack-11", "Pack 命中拍 SMC 闭包零调用（Pack > SMC 优先级）")
    }

    // Pack-12：Pack 未命中 → SMC 兜底（v0.19.8 路径——三层链第二降级）。
    do {
        let monitor = BatteryMonitor(
            source: PackStaticPropertySource(props: packProps27()),
            smcTemperatureFallbackCentiC: { 2950 },
            packPropertiesSource: { packDict(batteryDataTemperature: nil) })
        let s = try monitor.snapshot()
        expectEqual(s.temperatureCentiC, 2950, "Pack-12",
                    "Pack 未命中 → SMC 兜底 2950（26 平台无 Pack 层自动回退现路径——行为不变）")
    }

    // Pack-13：Pack 读取失败（nil）→ SMC 兜底（回退面尽力而为——子树服务缺失
    // 按缺席处理，非抛）。
    do {
        let monitor = BatteryMonitor(
            source: PackStaticPropertySource(props: packProps27()),
            smcTemperatureFallbackCentiC: { 2950 },
            packPropertiesSource: { nil })
        let s = try monitor.snapshot()
        expectEqual(s.temperatureCentiC, 2950, "Pack-13",
                    "Pack 读取器返回 nil → SMC 兜底 2950（尽力而为面非抛）")
    }

    // Pack-14：三层全缺 → 原错误原样上抛（G3 错误原文不变——Monitor 注入缝形态）。
    do {
        let monitor = BatteryMonitor(
            source: PackStaticPropertySource(props: packProps27()),
            smcTemperatureFallbackCentiC: { nil },
            packPropertiesSource: { packDict(batteryDataTemperature: nil) })
        expectThrows(try monitor.snapshot(),
                     as: BatteryMonitorError.missingRequiredField("Temperature"),
                     "Pack-14", "三层全缺 → .missingRequiredField 原文（回退未命中不吞错）")
    }

    // Pack-15：首读绑定复用（review P3-3）——回退链全程 source.properties() 恰一次
    //（ioreg 全量属性读是最贵一跳，回退重解析共用同一份 props；26 主路同样恰一次）。
    do {
        let readCalls = CallCounter()
        let monitor = BatteryMonitor(
            source: CountingPropertySource(props: packProps27(), counter: readCalls),
            smcTemperatureFallbackCentiC: { 2950 },
            packPropertiesSource: { packDict(batteryDataTemperature: nil) })
        let s = try monitor.snapshot()
        expectEqual(s.temperatureCentiC, 2950, "Pack-15", "回退链（Pack 未命中 → SMC）温度 2950（语义不变）")
        check(readCalls.value == 1, "Pack-15", "回退路径 properties() 恰一次（首读绑定复用——review P3-3）")
    }
    do {
        let readCalls = CallCounter()
        let monitor = BatteryMonitor(
            source: CountingPropertySource(props: batteryProps(), counter: readCalls),
            smcTemperatureFallbackCentiC: { 2950 },
            packPropertiesSource: { packDict() })
        let s = try monitor.snapshot()
        expectEqual(s.temperatureCentiC, 3030, "Pack-15", "26 主路顶层命中温度 3030（语义不变）")
        check(readCalls.value == 1, "Pack-15", "26 主路 properties() 恰一次（既有行为保持）")
    }
}
