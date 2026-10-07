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
    /// 0.20 M1a 探测序修订（方案 §2.1）：CHTE（26 完整）→ CH0B（Legacy 完整，27 恒
    /// 缺席自然落空）→ **CHIE（27 放电面，`dischargeControlPlane` 第三级）** → 无。
    /// 本函数仍只负责充电执法后端选定：CHIE 控制面不构成 ChargingBackend（无充电
    /// 执法键），由调用方在 `.noBackendAvailable` 命中后另测（establishBackendLocked
    /// 终态臂）。
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

    // MARK: - CHIE 放电控制面探测（0.20 M1a §2.1）

    /// CHIE 放电控制面探测结论（探测序第三级：CHTE/CH0B 落空后的 27 放电面）。
    public enum DischargeControlPlane: Equatable, Sendable {
        /// keyInfo 在位 + 读成功 + 同值写探针通过（0x00→0x00 回读一致，S1 E1 实证
        /// 幂等安全）——放电控制面可用。
        case writable
        /// keyInfo 在位 + 读成功，写探针未执行（非 root——写需 root；可写性未知，
        /// 如实上报，fail-closed 消费方按不可用处理）。
        case writabilityUnknown
        /// 键缺席 / 读失败 / 写探针失败——放电控制面不可用。
        case unavailable
    }

    /// CHIE 探测（0.20 M1a）：keyInfo 在位 + 读成功 + 同值写探针（0x00→0x00，幂等
    /// 安全——写探针需 root，探测运行于 daemon root 上下文；非 root 按在位但可写性
    /// 未知处理并如实上报）。探测只读读路径 + 单次同值写（0x00 = 适配器使能 resting
    /// 态，探测点无在轨放电——establishBackendLocked 先于崩溃恢复执行）。
    ///
    /// **`writeProbe: false`（0.20 P2 评审修法）：跳过同值写探针**——只读契约面
    /// （doctor 检查 4/11 采集专用：doctor「不写任何 SMC 键」契约，P0-3），在位可读
    /// 即返回 `.writabilityUnknown`（如实「可写性未探测」）；daemon establish 路径
    /// 保持缺省 true（写探针裁定可写性）不变。
    ///
    /// - `keyNotFound`（132）→ `.unavailable`（键缺席，非故障）。
    /// - 读失败（键在位但读取异常）→ `.unavailable`（fail-closed：读不通即不可用）。
    /// - 写探针失败（root 写/回读不一致）→ `.unavailable`（fail-closed；写探针失败
    ///   折叠为不可用而非上抛——探测点每 30s 重探会造成 CHIE 写抖动，sticky 终态
    ///   吞掉重试，残留交巡检兜底）。
    /// - 传输故障（keyInfo kr≠0）原样上抛，绝不折叠为 `.unavailable`（P1-7 纪律
    ///   同款——坏连接 ≠ 平台结论）。
    public static func dischargeControlPlane(
        client: SMCClient, isRoot: Bool = isRunningAsRoot, writeProbe: Bool = true
    ) throws -> DischargeControlPlane {
        guard try client.keyExists("CHIE") else { return .unavailable }
        guard (try? DischargeAdapterControl.adapterState(client: client)) != nil else {
            return .unavailable
        }
        guard writeProbe else { return .writabilityUnknown }
        guard isRoot else { return .writabilityUnknown }
        return DischargeAdapterControl.sameValueWriteProbe(client: client) ? .writable : .unavailable
    }

    /// discharge 能力探测（WP2' §2.1，评审 P1-1 fail-closed）：backend == "tahoe"
    /// **且** CHIE getKeyInfo 在位 → true。Legacy 后端 / CHIE 缺席机器 / CHIE 探测
    /// 失败（传输错误经 try? 折叠为 false）→ false——能力恒不出现在不满足条件处。
    public static func supportsDischarge(backend: any ChargingBackend, client: SMCClient) -> Bool {
        guard backend.name == "tahoe" else { return false }
        return (try? client.keyExists("CHIE")) == true
    }

    /// 后端平台终态处置（0.19.10 WP-A；v0.19.20 编排批扩展；0.20 M1a capabilities
    /// 矩阵扩展）：`.noBackendAvailable` 命中后的固定决策，纯函数钉语义——daemon
    /// 的 establishBackendLocked catch 分支只消费本函数、不内联字面量。
    ///
    /// 三元语义（macOS 27 实证：CHTE/CH0B 键族被系统删除，进程内重试无意义）：
    /// - `retainClient: true`——新建的 SMCClient 必须保留：风扇/LED/Ts 探测等
    ///   观察面与充电后端无关，不应陪葬（只读模式收窄为「限充执法停用」）。
    /// - `reportedCapabilities`——能力上报**非 nil**：App 侧三态消费面（nil=未上报
    ///   瞬态/旧 daemon / []/含值=已上报）据此分流。0.20 M1a 矩阵（方案 §2.1，
    ///   R1-P1 处置）+ **0.23.2 校准 27 适配**（方案 §4.1——CHIE 可写臂追加
    ///   `calibration`：27 充电执法经 topoff 域承载通道、CHIE 经 DischargeAdapterControl，
    ///   校准三相位（chargeFull 域写 100 / hold 浮充 / discharge CHIE 0x8）全链在
    ///   27 可达，原生守卫随批平台判别绕过（M1 同论证——域写 100 覆写 MCL））：
    ///   - CHIE 可写 → `[orchestration, discharge, autoDischarge, calibration, sub80]`——必含
    ///     orchestration（编排链/fullOnce 拒绝判定/App 编排节显隐依赖）；含
    ///     autoDischarge 使 daemon 自动触发门与 App 开关门对称；含 calibration
    ///     （0.23.2——App 校准按钮与调度卡数据驱动放行）；含 sub80（27 终态
    ///     即报无条件——域存在性不作上报条件，防干净机器假阴性隐藏功能，R2-P2）。
    ///   - 无 CHIE → `[orchestration, sub80]`（0.23.2 不变——无 CHIE 无放电面亦无
    ///     校准 discharge 相，校准能力不放开）。
    ///   "sub80" 上报先行于 topoff 通道落地（M1b）——能力表达域存在性，执法由
    ///   M1b 补齐；26 及更早平台清单不变（两参都不触及成功路径——26 成功路径
    ///   `[discharge, autoDischarge, calibration]` 由 establishBackendLocked 承载）。
    /// - `retryWithinProcess: false`——进程内不再重探（sticky 终态）：消除每 tick
    ///   makeDefault+日志+clientGeneration 换代抖动；键族恢复伴随系统更新/重装
    ///   （必然重启 daemon），进程重启即唯一清除路径。**27（含 CHIE 在位）仍进
    ///   终态 sticky（R1-P1）**——仅 reportedCapabilities 按 CHIE 探测结果扩展。
    public static func noBackendTerminalDisposition(
        chieWritable: Bool
    ) -> (retainClient: Bool, reportedCapabilities: [String], retryWithinProcess: Bool) {
        let capabilities: [String]
        if chieWritable {
            // 0.23.2 校准 27 适配：CHIE 可写臂追加 capabilityCalibration（无 CHIE 臂
            // /26 成功路径不变——红线）。
            capabilities = [
                DaemonXPC.capabilityOrchestration,
                DaemonXPC.capabilityDischarge,
                DaemonXPC.capabilityAutoDischarge,
                DaemonXPC.capabilityCalibration,
                DaemonXPC.capabilitySub80,
            ]
        } else {
            capabilities = [DaemonXPC.capabilityOrchestration, DaemonXPC.capabilitySub80]
        }
        return (retainClient: true, reportedCapabilities: capabilities, retryWithinProcess: false)
    }
}