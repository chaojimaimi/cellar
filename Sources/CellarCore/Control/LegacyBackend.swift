/// Legacy 代充电后端：双键 `CH0B`/`CH0C` 同值（1B，外部参考，未实测）。
///
/// 值协议（外部参考）：`0x00`=充电使能 · `0x02`=停充。本机固件已删除此二键
/// （getKeyInfo 返回 132），仅 mock 可验证；真机行为待 <26 设备验证。
///
/// 双键写 + 失败补偿（评审 P1-4 定版）：预读 CH0B 旧值 → 固定顺序写 CH0B → CH0C；
/// CH0C 失败时尽力回写 CH0B 旧值并以 `.partialWrite` 类型化上报。
public struct LegacyBackend: ChargingBackend, Sendable {
    private let client: SMCClient

    public init(client: SMCClient) {
        self.client = client
    }

    public var name: String { "legacy" }

    public var keyNames: [String] { ["CH0B", "CH0C"] }

    public func chargingEnabled() throws -> Bool {
        let bytes = try client.read("CH0B")
        // 防御：先验证长度恰为 1 再取下标（长度异常按未知状态显式报错，禁止越界/猜测）。
        guard bytes.count == 1 else {
            throw BackendError.unknownChargingState(key: "CH0B", bytes: bytes)
        }
        switch bytes[0] {
        case 0x00:
            return true
        case 0x02:
            return false
        default:
            throw BackendError.unknownChargingState(key: "CH0B", bytes: bytes)
        }
    }

    public func setChargingEnabled(_ enabled: Bool) throws {
        let value: UInt8 = enabled ? 0x00 : 0x02
        // 1. 预读 CH0B 旧值：仅用于失败补偿；读失败不阻断主流程（try?，评审 P1-4）。
        let previous = try? client.read("CH0B")
        // 2. 固定顺序写：先 CH0B 后 CH0C（各写同值）。
        //    CH0B 自身失败 → 原样上抛 SMCError（无补偿必要）。
        try client.write("CH0B", bytes: [value])
        do {
            try client.write("CH0C", bytes: [value])
        } catch let cause as SMCError {
            // 3. CH0C 失败 → 尽力回写 CH0B 旧值（回写本身失败不覆盖主错误，
            //    仍以 .partialWrite 上报第一键已写 + 第二键失败的事实）。
            if let previous {
                _ = try? client.write("CH0B", bytes: previous)
            }
            throw BackendError.partialWrite(failedKey: "CH0C", cause: cause)
        }
    }
}