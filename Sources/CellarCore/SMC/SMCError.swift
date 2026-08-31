/// SMC 封装层的类型化错误。
///
/// 红线：禁止吞错——除 `keyExists` 对 `keyNotFound` 的既定语义（→ false）外，
/// 所有错误一律原样向上抛出。
public enum SMCError: Error, Equatable, Sendable {
    /// 未找到 AppleSMC 服务（IOServiceGetMatchingService 返回 0）。
    case serviceNotFound
    /// IOServiceOpen 失败。
    case openFailed(kr: Int32)
    /// 传输调用返回非零 IOReturn（如 0xE00002C7 = kIOReturnBadArgument）。
    case transportFailure(kr: Int32)
    /// key 非法（必须为 4 个 ASCII 可打印字符）。
    case invalidKey(String)
    /// 写入载荷越界（必须为 1...32 字节）。
    case invalidPayload(count: Int)
    /// 键不存在 / 对当前身份不可见（驱动结果码 132）。
    case keyNotFound(String)
    /// 驱动返回未预期结果码（含 137 = 缺期望尺寸等）。
    case unexpectedResult(key: String, command: UInt8, result: UInt8)
    /// 回包长度不足以承载按请求尺寸的读结果（读值从 offset 48 切片需 48+size 字节）。
    case malformedReply(key: String, expected: UInt32, actual: Int)
}
