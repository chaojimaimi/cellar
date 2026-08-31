#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 运行时后端探测（macOS 26 实测定版）：CHTE → CH0B 顺序，选定 Tahoe / Legacy。
///
/// ⚠️ 可靠探测必须 root（非 root 的键可见性不稳定，实测）；
/// 调用方用 `isRunningAsRoot` 判断探测可信度提示。
public enum RuntimeProbe {
    /// root 助手（CLI/daemon 用于探测可信度提示）。
    public static var isRunningAsRoot: Bool {
        getuid() == 0
    }

    /// 探测顺序：CHTE → CH0B（以 CH0B 为 Legacy 代表键，CH0C 不单独判定——评审 P2-8）。
    ///
    /// - 两者皆 132（键不存在）→ `.noBackendAvailable`（调用方据此降级为只读模式，监测仍可用）。
    /// - 传输故障（kr≠0 等非 132 错误）原样上抛，绝不降级为 `.noBackendAvailable`（评审 P1-7）。
    public static func probe(client: SMCClient) throws -> any ChargingBackend {
        if try client.keyExists("CHTE") {
            return TahoeBackend(client: client)
        }
        if try client.keyExists("CH0B") {
            return LegacyBackend(client: client)
        }
        throw BackendError.noBackendAvailable
    }
}