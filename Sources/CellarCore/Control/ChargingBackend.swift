/// 充电控制后端抽象：一次探测，处处使用（CLI/daemon 不感知键位代际）。
///
/// 键位代际（键位代际实测与外部参考）：macOS 26+/Tahoe 固件为 `CHTE`（ui32/4B，本机实测）；
/// <26 旧系统为 `CH0B`/`CH0C`（1B，外部参考未实测）。由 RuntimeProbe 按运行时探测选定实现。
public protocol ChargingBackend: Sendable {
    /// 后端标识（doctor/status 诊断输出用）：`"tahoe"` / `"legacy"`。
    var name: String { get }
    /// 该后端读写的控制键名列表（诊断输出用）。
    /// Tahoe = ["CHTE"]；Legacy = ["CH0B", "CH0C"]（双键写，评审 P2-1）。
    var keyNames: [String] { get }
    /// 当前是否允许充电。
    /// ⚠️ 结果仅在 root 下可信（非 root 读值可为空/不可见，实测）。
    func chargingEnabled() throws -> Bool
    /// 允许/停止充电。不含回读验证（回读与状态校对由 WP4/WP6 负责）。
    func setChargingEnabled(_ enabled: Bool) throws
}

/// 后端域错误（与 SMCError 分域：SMCError 原样透传，不包装）。
public enum BackendError: Error, Equatable, Sendable {
    /// 控制键值不在已知语义集合内（含长度不符的防御；红线：未知状态显式报错，禁止猜测）。
    case unknownChargingState(key: String, bytes: [UInt8])
    /// CHTE 与 CH0B 均不可用。预期调用方据此**降级为只读模式**（监测仍可用），而非致命退出。
    case noBackendAvailable
    /// Legacy 双键写部分失败：第一键已写、第二键失败且已尽力回滚第一键旧值。
    case partialWrite(failedKey: String, cause: SMCError)
    /// Legacy 双键状态分裂：CH0B 与 CH0C 读值不一致（审计中-1 补充；显式报错，禁止只读单键掩盖）
    case legacyKeysInconsistent(ch0b: UInt8, ch0c: UInt8)
    /// 写后回读校验不一致（enforce 红线 5）：写入 desired 后回读得 actual。
    /// ⚠️ 外部写者（同类工具/手动 smc）在写读之间翻转状态时触发是期望行为（冲突显式化，
    /// WP6 不得误诊为协议故障）。
    case verifyFailed(key: String, desired: Bool, actual: Bool)
}