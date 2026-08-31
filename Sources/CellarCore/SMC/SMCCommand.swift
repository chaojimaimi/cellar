/// SMC 统一入口内的操作码，经输入缓冲 offset 42（data8）传递。
///
/// 统一入口 selector = 2 由 IOKitSMCTransport 内部固定（协议层不暴露）；
/// 经典直接选择器 5/6/9 在 macOS 26 已移除——一律返回 kIOReturnBadArgument，
/// （macOS 26 实测定版）。
enum SMCCommand: UInt8 {
    /// 读键值。
    case read = 5
    /// 写键值。
    case write = 6
    /// 查询键元数据（dataSize / dataType）。
    case keyInfo = 9
}
