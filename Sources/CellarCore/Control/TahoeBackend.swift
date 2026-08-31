/// Tahoe 代充电后端：单键 `CHTE`（ui32/4B，实测）。
///
/// 值协议（本机 M0 实测）：`00 00 00 00`=充电使能 · `01 00 00 00`=停充；写入即时生效。
public struct TahoeBackend: ChargingBackend, Sendable {
    private let client: SMCClient

    public init(client: SMCClient) {
        self.client = client
    }

    public var name: String { "tahoe" }

    public var keyNames: [String] { ["CHTE"] }

    public func chargingEnabled() throws -> Bool {
        let bytes = try client.read("CHTE")
        switch bytes {
        case [0x00, 0x00, 0x00, 0x00]:
            return true
        case [0x01, 0x00, 0x00, 0x00]:
            return false
        default:
            // 红线：未知状态显式报错（含长度 ≠4 的防御），禁止猜测语义。
            throw BackendError.unknownChargingState(key: "CHTE", bytes: bytes)
        }
    }

    public func setChargingEnabled(_ enabled: Bool) throws {
        try client.write("CHTE", bytes: enabled ? [0x00, 0x00, 0x00, 0x00] : [0x01, 0x00, 0x00, 0x00])
    }
}