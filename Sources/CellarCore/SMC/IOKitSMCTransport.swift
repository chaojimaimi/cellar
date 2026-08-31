#if canImport(IOKit)
import Foundation
import IOKit

/// 真机传输层：AppleSMC 用户客户端的统一入口调用。
///
/// - 统一入口 selector = 2（经典 KERNEL_INDEX_SMC），操作由输入 data8 区分；
///   经典直接选择器 5/6/9 在 macOS 26 已移除（macOS 26 实测）。
/// - 80 字节 `[UInt8]` 缓冲直传内核（禁止 Swift struct 复刻 C 布局，实测 76B≠80B）。
/// - 并发（评审 E-2）：`final class` + `NSLock` 串行化，连接字段由锁保护，
///   `@unchecked Sendable`。
/// - 生命周期：连接在 deinit 中关闭（协议不含 close，评审 B-2）。
public final class IOKitSMCTransport: SMCTransport, @unchecked Sendable {
    /// 统一入口选择器：一切读写/元数据操作都经此入口，由本实现内部固定。
    private static let unifiedSelector: UInt32 = 2
    private static let serviceName = "AppleSMC"
    private static let serviceType: UInt32 = 0

    private let lock = NSLock()
    /// 用户客户端连接（由 lock 保护）。
    private var connection: io_connect_t

    /// 打开 AppleSMC 服务：IOServiceGetMatchingService → IOServiceOpen(type: 0)。
    ///
    /// - Throws: `SMCError.serviceNotFound`（服务不存在）· `SMCError.openFailed(kr:)`。
    public init() throws {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(Self.serviceName)
        )
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { _ = IOObjectRelease(service) }

        var connect: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, Self.serviceType, &connect)
        guard kr == KERN_SUCCESS, connect != 0 else {
            throw SMCError.openFailed(kr: kr)
        }
        connection = connect
    }

    deinit {
        // 连接关闭是实现内部细节；deinit 期间无其他调用方，取锁仅为形式上的一致性。
        lock.lock()
        let connect = connection
        connection = 0
        lock.unlock()
        if connect != 0 {
            _ = IOServiceClose(connect)
        }
    }

    public func call(input: [UInt8]) -> (output: [UInt8], kr: Int32) {
        lock.lock()
        defer { lock.unlock() }

        var output = [UInt8](repeating: 0, count: SMCParam.size)
        var outputSize = SMCParam.size
        let kr = input.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                IOConnectCallStructMethod(
                    connection,
                    Self.unifiedSelector,
                    inputBuffer.baseAddress,
                    input.count,
                    outputBuffer.baseAddress,
                    &outputSize
                )
            }
        }
        return (output: output, kr: kr)
    }
}
#endif
