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
        // 双键一致性校验（审计中-1）：CH0B 与 CH0C 分裂时显式报错，
        // 禁止只读 CH0B 把分裂状态伪装成正常态（enforce 回读会被误导）。
        let b = try client.read("CH0B")
        let c = try client.read("CH0C")
        guard b.count == 1, c.count == 1, b[0] == c[0] else {
            throw BackendError.legacyKeysInconsistent(ch0b: b.first ?? 0xFF,
                                                      ch0c: c.first ?? 0xFF)
        }
        switch b[0] {
        case 0x00:
            return true
        case 0x02:
            return false
        default:
            throw BackendError.unknownChargingState(key: "CH0B", bytes: [b[0]])
        }
    }

    public func setChargingEnabled(_ enabled: Bool) throws {
        let value: UInt8 = enabled ? 0x00 : 0x02
        // 1. 预读 CH0B 旧值：补偿的前提条件。预读失败 → fail-fast 拒绝双键写
        //    （审计中-1：无旧值就没有回滚能力，不允许在无补偿条件下开写）。
        let previous = try client.read("CH0B")
        // 2. 固定顺序写：先 CH0B 后 CH0C（各写同值）。
        try client.write("CH0B", bytes: [value])
        do {
            try client.write("CH0C", bytes: [value])
        } catch let cause as SMCError {
            // 3. CH0C 失败 → 回写 CH0B 旧值（补偿）。回写本身失败不覆盖主错误，
            //    仍以 .partialWrite 上报第一键已写 + 第二键失败的事实。
            _ = try? client.write("CH0B", bytes: previous)
            throw BackendError.partialWrite(failedKey: "CH0C", cause: cause)
        }
    }
}