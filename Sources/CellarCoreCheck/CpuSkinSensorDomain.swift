// CellarCoreCheck —— 0.18 M2 CPU 表面温度共享探测域（方案 D-5b）：
// CpuSkinSensor.probe 探测矩阵（命中首键短路/键序推进/type 尾随空格/size 不符/
// 值域越界/全不命中）+ read flt LE 单位约定（°C）。照 SMC mock 矩阵先例
// （MainEntry.swift 用例 17-35：CheckTransport 按 data8 FIFO 分流）。
// 按域拆独立文件（BatteryTelemetryDomain 同款，main 不增长）。
import CellarCore
import Foundation

/// CpuSkinSensor 场景域入口（Main.main 调用；断言经 MainEntry.swift 的 internal 助手）。
func runCpuSkinSensorDomainScenarios() {
    // fixture：flt LE 字节构造（FanSMC.encodeRPM 同一 LE 打包定版——温度/转速同源）。
    func flt(_ value: Float) -> [UInt8] { FanSMC.encodeRPM(value) }

    // 探-1：命中首键 Ts0C（flt/4B/值 36.5 ∈ 10...90 域）→ 返回 "Ts0C" 且短路
    // （每键探测 = 门 keyInfo + read 两阶段内含的第二次 keyInfo + read——
    // SMCClient.read 两阶段语义；命中后后续候选键零调用）。
    do {
        let mock = CheckTransport()
        mock.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)   // Ts0C 门 keyInfo
        mock.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)   // read 阶段 keyInfo
        mock.enqueue(reply(bytes: flt(36.5)), for: Spec.read)
        let key = CpuSkinSensor.probe(connection: SMCClient(transport: mock))
        expectEqual(key, "Ts0C", "探-1", "命中首键 Ts0C")
        check(mock.inputs.count == 3, "探-1", "命中短路：门 keyInfo + 两阶段 read（3 次调用），后续键零调用")
    }

    // 探-2：首键 size 不符（2B）→ 跳过，次键 Ts0D 命中（键序推进语义）。
    do {
        let mock = CheckTransport()
        mock.enqueue(reply(dataSize: 2, type: "flt "), for: Spec.keyInfo)   // Ts0C 门：尺寸不符
        mock.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)   // Ts0D 门 keyInfo
        mock.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)   // Ts0D read 阶段
        mock.enqueue(reply(bytes: flt(41.2)), for: Spec.read)
        expectEqual(CpuSkinSensor.probe(connection: SMCClient(transport: mock)),
                    "Ts0D", "探-2", "首键 size≠4 跳过 → 次键 Ts0D 命中")
    }

    // 探-3：type trim 语义——"flt "（实测尾随空格）命中；"ui32"（非 flt）跳过。
    do {
        let padded = CheckTransport()
        padded.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)
        padded.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)
        padded.enqueue(reply(bytes: flt(55.0)), for: Spec.read)
        expectEqual(CpuSkinSensor.probe(connection: SMCClient(transport: padded)),
                    "Ts0C", "探-3", "type \"flt \" 尾随空格 trim 后命中")
        let wrongType = CheckTransport()
        wrongType.enqueue(reply(dataSize: 4, type: "ui32"), for: Spec.keyInfo)   // Ts0C 门：非 flt
        wrongType.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)   // Ts0D 门 keyInfo
        wrongType.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)   // Ts0D read 阶段
        wrongType.enqueue(reply(bytes: flt(55.0)), for: Spec.read)
        expectEqual(CpuSkinSensor.probe(connection: SMCClient(transport: wrongType)),
                    "Ts0D", "探-3", "type 非 flt 跳过 → 次键命中")
    }

    // 探-4：值域越界（9.5 < 10 / 90.5 > 90）→ 该键跳过；键序照常推进。
    do {
        let below = CheckTransport()
        below.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)   // Ts0C 门
        below.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)   // Ts0C read 阶段
        below.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)   // Ts0D 门
        below.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)   // Ts0D read 阶段
        below.enqueue(reply(bytes: flt(9.5)), for: Spec.read)
        below.enqueue(reply(bytes: flt(45.0)), for: Spec.read)
        expectEqual(CpuSkinSensor.probe(connection: SMCClient(transport: below)),
                    "Ts0D", "探-4", "值 9.5 < 10 越下界跳过 → 次键命中")
        let above = CheckTransport()
        above.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)   // Ts0C 门
        above.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)   // Ts0C read 阶段
        above.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)   // Ts0D 门
        above.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)   // Ts0D read 阶段
        above.enqueue(reply(bytes: flt(90.5)), for: Spec.read)
        above.enqueue(reply(bytes: flt(45.0)), for: Spec.read)
        expectEqual(CpuSkinSensor.probe(connection: SMCClient(transport: above)),
                    "Ts0D", "探-4", "值 90.5 > 90 越上界跳过 → 次键命中")
    }

    // 探-5：全不命中（keyNotFound ×4）→ nil（机型事实结论，调用方 sticky 收口）。
    do {
        let mock = CheckTransport()
        mock.enqueue(reply(result: 132), for: Spec.keyInfo)
        mock.enqueue(reply(result: 132), for: Spec.keyInfo)
        mock.enqueue(reply(result: 132), for: Spec.keyInfo)
        mock.enqueue(reply(result: 132), for: Spec.keyInfo)
        check(CpuSkinSensor.probe(connection: SMCClient(transport: mock)) == nil && mock.inputs.count == 4,
              "探-5", "四候选键全不命中 → nil（探测传输调用恰 4 次，不多探）")
    }

    // 读-1：read flt LE 单位约定（工单定：°C Double——Ts flt 原始值即 °C，
    // 不做厘度换算）：36.5 字节 → 36.5；nil 路径 = 键缺席 / 尺寸 ≠4。
    do {
        let hit = CheckTransport()
        hit.enqueue(reply(dataSize: 4, type: "flt "), for: Spec.keyInfo)
        hit.enqueue(reply(bytes: flt(36.5)), for: Spec.read)
        let value = CpuSkinSensor.read(connection: SMCClient(transport: hit), key: "Ts0C")
        check(value != nil, "读-1", "flt LE 解码成功")
        if let value {
            check(abs(value - 36.5) < 0.001, "读-1", "单位约定 °C：36.5 字节 → 36.5（无 ×100 换算）")
        }
        let missing = CheckTransport()
        missing.enqueue(reply(result: 132), for: Spec.keyInfo)
        check(CpuSkinSensor.read(connection: SMCClient(transport: missing), key: "Ts0C") == nil,
              "读-1", "键缺席 → nil（非抛，降级由 nil 语义承载）")
        let wrongSize = CheckTransport()
        wrongSize.enqueue(reply(dataSize: 2, type: "flt "), for: Spec.keyInfo)
        wrongSize.enqueue(reply(bytes: [0x00, 0x42]), for: Spec.read)
        check(CpuSkinSensor.read(connection: SMCClient(transport: wrongSize), key: "Ts0C") == nil,
              "读-1", "字节数 ≠4 → nil（不做格式猜测）")
    }
}
