/// 键元数据（getKeyInfo 解析结果）。
public struct SMCKeyInfo: Equatable, Sendable {
    /// 键值字节尺寸（来自 getKeyInfo 回复 offset 28）。
    public let size: UInt32
    /// 4CC 类型（如 "ui32"，来自 getKeyInfo 回复 offset 32）。
    public let type: String

    public init(size: UInt32, type: String) {
        self.size = size
        self.type = type
    }
}

/// SMC 高层客户端：封包、两阶段读、写与错误映射（规格 §5.4）。
///
/// 不可变值类型（`Sendable`）；并发安全由传输实现的内部串行化保证。
/// 协议行为为 macOS 26 实测定版，勿凭记忆修改。
public struct SMCClient: Sendable {
    private let transport: any SMCTransport

    public init(transport: any SMCTransport) {
        self.transport = transport
    }

    #if canImport(IOKit)
    /// IOKit 传输 + AppleSMC 服务（真机路径）。
    /// 测试与 CI 一律走 mock，禁止调用本方法（规格 §5.5）。
    public static func makeDefault() throws -> SMCClient {
        SMCClient(transport: try IOKitSMCTransport())
    }
    #endif

    // MARK: - API

    /// 查询键元数据（data8=9）。
    public func keyInfo(_ key: String) throws -> SMCKeyInfo {
        let keyBytes = try validatedKeyBytes(key)
        let (output, kr) = transport.call(input: SMCParam.keyInfoInput(key: keyBytes))
        try checkReply(kr: kr, output: output, key: key, command: .keyInfo)
        return SMCKeyInfo(size: SMCParam.dataSize(of: output), type: SMCParam.dataType(of: output))
    }

    /// 读键值。两阶段（macOS 26 实测）：先 keyInfo 取 dataSize，再带尺寸读。
    public func read(_ key: String) throws -> [UInt8] {
        // 第一阶段：getKeyInfo（失败原样抛出）。
        let info = try keyInfo(key)
        let keyBytes = try validatedKeyBytes(key)

        // 第二阶段：读输入 offset28 必须携带该尺寸（缺失 → 驱动 result=137）。
        let (output, kr) = transport.call(input: SMCParam.readInput(key: keyBytes, dataSize: info.size))
        try checkReply(kr: kr, output: output, key: key, command: .read)

        // 读回复 offset 28 恒为 0（不回填 dataSize）——必须按 keyInfo 尺寸从 offset 48 切片；
        // 按回复 offset28 切片会得到空数组（M0 踩过的真实陷阱）。
        let expected = Int(info.size)
        guard output.count >= SMCParam.bytesOffset + expected else {
            throw SMCError.malformedReply(key: key, expected: info.size, actual: output.count)
        }
        return Array(output[SMCParam.bytesOffset..<(SMCParam.bytesOffset + expected)])
    }

    /// 写键值（载荷 1...32 字节，越界拒绝且不发传输调用）。
    public func write(_ key: String, bytes: [UInt8]) throws {
        let keyBytes = try validatedKeyBytes(key)
        guard (1...32).contains(bytes.count) else {
            throw SMCError.invalidPayload(count: bytes.count)
        }
        let (output, kr) = transport.call(input: SMCParam.writeInput(key: keyBytes, payload: bytes))
        try checkReply(kr: kr, output: output, key: key, command: .write)
    }

    /// 键是否存在：仅 `keyNotFound` → false；其余错误（含传输故障）原样上抛（评审 B-3）。
    public func keyExists(_ key: String) throws -> Bool {
        do {
            _ = try keyInfo(key)
            return true
        } catch SMCError.keyNotFound {
            return false
        }
    }

    // MARK: - 内部

    /// key 校验：4 字符且全为 ASCII 可打印（0x20...0x7E）；非法时抛错、不发传输调用。
    private func validatedKeyBytes(_ key: String) throws -> [UInt8] {
        let bytes = Array(key.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            throw SMCError.invalidKey(key)
        }
        return bytes
    }

    /// 统一的 kr / 结果码检查：kr≠0 → transportFailure；132 → keyNotFound；
    /// 其余非零（含 137=缺期望尺寸）→ unexpectedResult。
    private func checkReply(kr: Int32, output: [UInt8], key: String, command: SMCCommand) throws {
        guard kr == 0 else { throw SMCError.transportFailure(kr: kr) }
        // 防御：SMCTransport 契约保证 80 字节回包；短回包连结果码都放不下，
        // 按畸形回包处理而非越界崩溃（正常实现不会走到这里）。
        guard output.count > SMCParam.resultOffset else {
            throw SMCError.malformedReply(key: key, expected: UInt32(SMCParam.size), actual: output.count)
        }
        let result = SMCParam.result(of: output)
        if result == SMCResult.keyNotFound {
            throw SMCError.keyNotFound(key)
        }
        guard result == SMCResult.success else {
            throw SMCError.unexpectedResult(key: key, command: command.rawValue, result: result)
        }
    }
}
