/// 传输层抽象：一切 IOKit 调用收敛于此，可被 mock。
/// selector 固定为 2，由实现内部保证；协议层面不暴露 selector。
///
/// 生命周期（评审 B-2）：协议不含 `close()`——连接关闭是传输实现内部细节
/// （IOKitSMCTransport 的 deinit → IOServiceClose），调用方随作用域释放即回收，
/// 因此不存在 call-after-close 状态。
public protocol SMCTransport: AnyObject, Sendable {
    /// 执行一次统一调用。输入/输出均为 80 字节缓冲。
    func call(input: [UInt8]) -> (output: [UInt8], kr: Int32)
}
