/// SMC 参数缓冲区（固定 80 字节）的手工封包/解包工具。
///
/// ⚠️ 禁止用 Swift struct 复刻 C ABI 布局：实测 Swift 嵌套结构为 76 字节 ≠ C 的 80 字节
/// （macOS 26 实测 76B≠80B），一律以 `[UInt8]` + 本类型的偏移常量手工封包。
///
/// ⚠️ 字节序（2026-08-31 二次实测修正）：`key` 与 `dataType` 4CC 均以**小端 uint32** 传输，
/// 缓冲内字符序与字符串相反（"CHTE" → 缓冲 `45 54 48 43`）；正序打包驱动一律返回 132。
/// 键值 bytes 为原始字节，无字节序变换。
///
/// 偏移表：
///
///     key@0(4B, LE uint32) · vers@4(6B) · padding@10(2B) · pLimitData@12(16B)
///     dataSize@28(UInt32, LE) · dataType@32(4B, LE 4CC) · attributes@36(存在但忽略)
///     result@40 · status@41 · data8@42 · data32@44 · bytes[32]@48
///
/// 所有出站输入以全零缓冲为基线构造：vers / padding / pLimitData / status /
/// result / data32 等字段天然置零（出站 result@40 必须为零，评审 B-1）。
public enum SMCParam {
    /// 缓冲区固定长度（C ABI 80 字节；Swift struct 布局陷阱的回归锚点）。
    public static let size = 80

    static let keyRange = 0..<4
    static let dataSizeOffset = 28
    static let dataTypeRange = 32..<36
    static let resultOffset = 40
    static let statusOffset = 41
    static let data8Offset = 42
    static let data32Offset = 44
    static let bytesOffset = 48

    // MARK: - 出站输入构造

    /// 键字符 → LE uint32 缓冲字节（字符序反转："CHTE" → [45, 54, 48, 43]）。
    static func keyWireBytes(_ key: [UInt8]) -> [UInt8] {
        key.reversed()
    }

    /// 全零 80 字节缓冲（出站字段的基线）。
    static func zeroed() -> [UInt8] {
        [UInt8](repeating: 0, count: size)
    }

    /// data8=9（getKeyInfo）输入：offset28=0，result=0。
    static func keyInfoInput(key: [UInt8]) -> [UInt8] {
        precondition(key.count == 4, "key 必须先经 SMCClient 校验为 4 字节")
        var buffer = zeroed()
        buffer.replaceSubrange(keyRange, with: keyWireBytes(key))
        buffer[data8Offset] = SMCCommand.keyInfo.rawValue
        return buffer
    }

    /// data8=5（读）输入：offset28 必须携带 keyInfo 返回的尺寸（缺失 → 驱动返回 result=137）。
    static func readInput(key: [UInt8], dataSize: UInt32) -> [UInt8] {
        precondition(key.count == 4, "key 必须先经 SMCClient 校验为 4 字节")
        var buffer = zeroed()
        buffer.replaceSubrange(keyRange, with: keyWireBytes(key))
        setUInt32(dataSize, at: dataSizeOffset, in: &buffer)
        buffer[data8Offset] = SMCCommand.read.rawValue
        return buffer
    }

    /// data8=6（写）输入：offset28=载荷字节数，载荷（≤32B，调用方校验）写入 bytes@48。
    static func writeInput(key: [UInt8], payload: [UInt8]) -> [UInt8] {
        precondition(key.count == 4, "key 必须先经 SMCClient 校验为 4 字节")
        precondition((1...32).contains(payload.count), "payload 必须先经 SMCClient 校验为 1...32 字节")
        var buffer = zeroed()
        buffer.replaceSubrange(keyRange, with: keyWireBytes(key))
        setUInt32(UInt32(payload.count), at: dataSizeOffset, in: &buffer)
        buffer[data8Offset] = SMCCommand.write.rawValue
        buffer.replaceSubrange(bytesOffset..<(bytesOffset + payload.count), with: payload)
        return buffer
    }

    // MARK: - 回包解析

    /// 驱动结果码（offset 40）。
    static func result(of reply: [UInt8]) -> UInt8 {
        reply[resultOffset]
    }

    /// keyInfo 回复的键值尺寸（offset 28，UInt32 LE）。
    /// 仅 keyInfo 回复有效；read 回复恒为 0（不回填，macOS 26 实测）。
    static func dataSize(of reply: [UInt8]) -> UInt32 {
        uint32(at: dataSizeOffset, in: reply)
    }

    /// keyInfo 回复的 4CC 类型（offset 32..36，LE uint32；读出后按字符序还原，如 "ui32"）。
    static func dataType(of reply: [UInt8]) -> String {
        String(decoding: reply[dataTypeRange].reversed(), as: UTF8.self)
    }

    // MARK: - 字节序原语
    // UInt32 字段（dataSize/data32）与 C 结构字段一致取小端；key 与 4CC 为 BE 字符序。

    static func setUInt32(_ value: UInt32, at offset: Int, in buffer: inout [UInt8]) {
        buffer[offset] = UInt8(value & 0xFF)
        buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 2] = UInt8((value >> 16) & 0xFF)
        buffer[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    static func uint32(at offset: Int, in buffer: [UInt8]) -> UInt32 {
        UInt32(buffer[offset])
            | (UInt32(buffer[offset + 1]) << 8)
            | (UInt32(buffer[offset + 2]) << 16)
            | (UInt32(buffer[offset + 3]) << 24)
    }
}
