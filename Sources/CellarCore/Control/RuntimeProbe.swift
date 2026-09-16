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

    /// discharge 能力探测（WP2' §2.1，评审 P1-1 fail-closed）：backend == "tahoe"
    /// **且** CHIE getKeyInfo 在位 → true。Legacy 后端 / CHIE 缺席机器 / CHIE 探测
    /// 失败（传输错误经 try? 折叠为 false）→ false——能力恒不出现在不满足条件处。
    public static func supportsDischarge(backend: any ChargingBackend, client: SMCClient) -> Bool {
        guard backend.name == "tahoe" else { return false }
        return (try? client.keyExists("CHIE")) == true
    }

    /// 后端平台终态处置（0.19.10 WP-A；v0.19.20 编排批扩展）：`.noBackendAvailable`
    /// 命中后的固定决策，纯函数钉语义——daemon 的 establishBackendLocked catch
    /// 分支只消费本函数、不内联字面量。
    ///
    /// 三元语义（macOS 27 实证：CHTE/CH0B 键族被系统删除，进程内重试无意义）：
    /// - `retainClient: true`——新建的 SMCClient 必须保留：风扇/LED/Ts 探测等
    ///   观察面与充电后端无关，不应陪葬（只读模式收窄为「限充执法停用」）。
    /// - `reportedCapabilities: ["orchestration"]`——能力上报**非 nil**：App 侧
    ///   三态消费面（nil=未上报瞬态/旧 daemon / []/含值=已上报）据此分流；27 终态
    ///   不再上报空数组——编排（Shortcuts 通道）是 27 唯一执法路径，上报编排能力
    ///   即「27 终态」标记本体：App 据此显隐通用页编排节 + fullOnce 拒绝启动
    ///   （WP-5），daemon 据此在观测段驱动编排链（R2 P2 门控钉死）。
    /// - `retryWithinProcess: false`——进程内不再重探（sticky 终态）：消除每 tick
    ///   makeDefault+日志+clientGeneration 换代抖动；键族恢复伴随系统更新/重装
    ///   （必然重启 daemon），进程重启即唯一清除路径。
    public static func noBackendTerminalDisposition(
    ) -> (retainClient: Bool, reportedCapabilities: [String], retryWithinProcess: Bool) {
        (retainClient: true, reportedCapabilities: [DaemonXPC.capabilityOrchestration],
         retryWithinProcess: false)
    }
}