import Foundation

// MARK: - Phase 5 v1.8 MagSafe LED（M1，方案 §2）—— CellarCore 纯函数/纯值层
//
// 事实源（2026-09-06 本机实测，MagSafe 3 端口机型；MagHue 协议事实提取同源交叉印证）：
// SMC 键 `ACLC`（ui8 / 1B）在位，非 root 可读、写需 root；值语义
// 0x00=system（跟随系统）/ 0x01=off（常灭）/ 0x03=green（常绿）/ 0x04=amber（常琥珀）。
// ⚠️ **本层只依赖读侧事实，零 IOKit 代码**（写侧 spike 归 M0，判据方案 §7-M0）：
// SMC 字节读写编解码归 M2 daemon 侧接线，本文件全部为纯函数 + 值注入风格
// （照 NativeChargeLimit.swift 先例）。
//
// 值域事实补记（方案 §1）：`0x00` 是命令值非锁存态——寄存器常态是色值，写入 00
// 后系统可能在下次充放转换重写为色值；因此 system 态不存在「期望单值」可比，
// 回读非四值 = 他写信号（通道 A 值域判据输入，方案 §0-D5）。

/// MagSafe LED 模式（rawValue = SMC ACLC 字节值；**只追加不重排**——rawValue 即
/// policy.json uint / XPC 白名单值，重排即旧数据静默错配，照 FanStrategy 同款纪律）。
/// Codable 合成形态 = 单值 UInt8（rawValue 解码，未知值抛 dataCorrupted）——
/// policy.json 侧因此以 UInt8 原值承载后再校验（见 DaemonPolicy.magSafeLedMode 注记）。
public enum MagSafeLEDMode: UInt8, Codable, Sendable, Equatable, CaseIterable {
    /// 跟随系统（出厂行为；opt-in 默认，零行为变化，方案 §0-D1）。
    case system = 0x00
    /// 常灭（覆盖充放两态，方案 §6 off 语义）。
    case off = 0x01
    /// 常绿。
    case green = 0x03
    /// 常琥珀。
    case amber = 0x04
}

/// MagSafe LED 状态载荷（wire 形态，方案 §2；M2 接线为 DaemonStatus.magSafeLed
/// 可选字段恒填——旧 daemon 回包缺席 → nil，App 提示升级，照 nativeLimit/fan 先例）。
public struct MagSafeLEDStatus: Codable, Sendable, Equatable {
    /// 当前配置模式（nil = system 未设或未知——policy 缺席/字段被丢弃的 opt-in 形态）。
    public var mode: MagSafeLEDMode?
    /// 键域能力位（true = ACLC 在位；unsupported(sticky) 与 undecided 未决在 wire 上
    /// 共用 false——三态分流（方案 §0-D6）在 daemon 探测侧，展示降级由消费侧承担）。
    public var supported: Bool
    /// 最近一次回读原始字节（nil = 未读过——R1 P3-3：不用 Mode? 表达回读，
    /// 防「未读过」与「他写」混叠）。
    public var readbackRaw: UInt8?
    /// 冲突锁存（R2 P3-N3：daemon 侧 driftCount ≥ 阈值的锁存态——App 节警告行与
    /// doctor 冲突态的判定源；false = 无锁存）。
    public var conflict: Bool

    public init(
        mode: MagSafeLEDMode?, supported: Bool, readbackRaw: UInt8?, conflict: Bool = false
    ) {
        self.mode = mode
        self.supported = supported
        self.readbackRaw = readbackRaw
        self.conflict = conflict
    }

    private enum CodingKeys: String, CodingKey {
        case mode, supported, readbackRaw, conflict
    }

    /// 容错解码（R3 补：conflict 为 v1.8 M2 新增位——旧 JSON/旧 daemon 回包缺席
    /// → false，decodeIfPresent 而非合成 keyNotFound 抛错；照 DaemonStatus 可选
    /// 字段缺席保持先例）。Encodable 仍走合成。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(MagSafeLEDMode.self, forKey: .mode)
        supported = try container.decodeIfPresent(Bool.self, forKey: .supported) ?? false
        readbackRaw = try container.decodeIfPresent(UInt8.self, forKey: .readbackRaw)
        conflict = try container.decodeIfPresent(Bool.self, forKey: .conflict) ?? false
    }

    /// 回读三态（派生只读——不进 Codable 编码，按 mode 期望值比对）。
    public enum ReadbackState: Equatable, Sendable {
        /// 回读 == 期望值。system 态（mode == nil）：合法四值均视为一致——寄存器
        /// 常态是色值，系统自管理下无「期望单值」可比（方案 §1 值域事实，勿把
        /// 系统自身覆写误报为他写）。
        case match
        /// 回读 ≠ 期望（他写合法值 ∨ 越域值；system 态下仅越域值落此态）。
        case foreign
        /// 未读过（readbackRaw == nil）。
        case unknown
    }

    public var readbackState: ReadbackState {
        guard let byte = readbackRaw else { return .unknown }
        guard let expected = mode?.rawValue else {
            // 跟随系统态：合法四值 = 系统管理常态（一致）；越域值 = 他写信号。
            return MagSafeLED.interpreting(byte) != nil ? .match : .foreign
        }
        return byte == expected ? .match : .foreign
    }
}

/// MagSafe LED 模型层（方案 §2）：模式白名单 + 回读解释 + tick 纠偏决策纯函数 +
/// wire 映射。全部纯函数——决策下沉照 FanGuard.decided 先例（daemon 只做副作用，
/// CellarCoreCheck 矩阵穷举钉死语义），无 os_log 面（纯函数层，日志归 M2 接线侧）。
public enum MagSafeLED {
    /// SMC 键名（M2 daemon 读写通道使用；M1 钉常量防漂移）。
    public static let aclcKey = "ACLC"

    /// 冲突锁存阈值（方案 §0-D5）：driftCount ≥ 本值 → 冲突锁存（停纠偏 + doctor
    /// 冲突态）。⚠️ 具名常量挂 M0 观测⑤（充放切换覆写时点/频率实测）定稿——
    /// 数据到位后可上调；「≥ 判定 + 计费 gating」语义不随数值改动。
    public static let driftLatchThreshold = 2

    /// 自动解除 streak（方案 §0-D5）：锁存期连续 3 次干净回读（==期望）→ 自动解除
    /// 且计数器清零（防永久卡死；**用户改模式的解除由调用方重置计数器承担**）。
    public static let cleanUnlockStreak = 3

    /// 能力探测分流（方案 §0-D6）：keyNotFound → .unsupported（sticky，整个生命
    /// 周期隐藏）；传输失败 → .undecided（心跳 tick 重探，SMC client 重建后重探）。
    public enum SupportState: Equatable, Sendable {
        case supported, unsupported, undecided
    }

    /// 上一 tick 纠偏动作（correctionDecision 输入回路——M2 daemon 每 tick 回传）。
    /// 通道 B 计费判据「写成功后再现才计事件」与「写失败旧值读数不计数」均依赖它
    /// （方案 §0-D5 / R2 N1）。
    public enum CorrectionAction: Equatable, Sendable {
        /// 本 tick 未执行 LED 动作（门槛 .idle 对应 / 尚未进入纠偏）。
        case none
        /// 上一 tick 写入成功且写后回读确认 == 写入值。
        case writeVerified
        /// 上一 tick 写入失败（未确认——其后的旧值读数不计数）。
        case writeFailed
        /// 上一 tick 无写动作（.skip / .conflictLatch 输出的对应回传；锁存期动作
        /// 恒 skipped——解除后首 tick 不被计费）。
        case skipped
    }

    /// 冲突锁存跨 tick 状态（daemon 内存持有、随 tick 回传；方案 §0-D5）。
    public struct LatchState: Equatable, Sendable {
        /// 漂移/事件累计——通道 A（回读越域）事件与通道 B（写成功后再现外来值）
        /// 漂移累入同一计数（R3：避免持续写非法值者陷入无锁存消耗战）；仅用户改
        /// 模式（调用方重置）或锁存自动解除时清零，干净回读不衰减。
        public var driftCount: Int
        /// 连续干净回读计数（锁存自动解除凭据；任何非干净回读断链清零）。
        public var cleanReadbackStreak: Int
        /// 冲突锁存（true = 停纠偏，doctor 冲突态）。
        public var latched: Bool

        public init(driftCount: Int = 0, cleanReadbackStreak: Int = 0, latched: Bool = false) {
            self.driftCount = driftCount
            self.cleanReadbackStreak = cleanReadbackStreak
            self.latched = latched
        }
    }

    /// 纠偏决策输出（daemon 依此执行副作用，照 FanDecision 分层）。
    public enum CorrectionOutcome: Equatable, Sendable {
        /// 写入期望值（M2：单次写 + ~100ms 延迟回读，锁预算 R1 P2-1——时序归 daemon）。
        case write(expected: MagSafeLEDMode)
        /// 本 tick 无写（干净回读无动作 / 未读过无凭据 / 锁存停纠偏）。
        case skip
        /// 不介入（跟随系统 / 未激活 / 能力未决或不支持）——计数器保留。
        case idle
        /// 冲突锁存入口 tick（停纠偏 + doctor 冲突态；后续 tick 落 .skip）。
        case conflictLatch
    }

    /// 配置值域校验（policy.json uint / M2 XPC 白名单同源）：0/1/3/4 → 模式；
    /// 其余（含 nil 缺席）→ nil。nil = 未设置（跟随系统），opt-in 零行为变化由
    /// 消费侧承载（DaemonPolicy.magSafeLedMode 注记）。
    public static func validating(_ raw: UInt8?) -> MagSafeLEDMode? {
        raw.flatMap(MagSafeLEDMode.init(rawValue:))
    }

    /// 回读解释（读侧事实，方案 §1）：四值 → 模式；其他字节 → nil（= 他写信号，
    /// 通道 A 值域判据输入；不做格式猜测，未知降级由能力探测分流承担，D6）。
    public static func interpreting(_ byte: UInt8) -> MagSafeLEDMode? {
        MagSafeLEDMode(rawValue: byte)
    }

    /// 纠偏决策纯函数（照 FanGuard 下沉先例，供 CellarCoreCheck 矩阵穷举；方案 §0-D5）。
    /// **求值序钉死（先命中先输出）**：①门槛 → ②锁存期 → ③常规期。
    ///
    /// - Parameters:
    ///   - mode: policy 配置模式（system 已被①拦截——到达②③恒为 off/green/amber）。
    ///   - modeActive: daemon 执法活跃（disabled/停用期为 false）。
    ///   - lastReadbackRaw: 本 tick 回读原值；nil = 未读过（无凭据：不动作不计数，
    ///     计数器原样——勿与「他写」混叠，R1 P3-3 同源纪律）。
    ///   - lastTickAction: 上一 tick 动作回路。计费 gating：仅 .writeVerified（上一
    ///     tick 写成功且回读确认）后本 tick 再现脏值才计事件；.writeFailed 的旧值
    ///     读数与残留读数不计费，但仍回收写（.write(expected)）。
    ///   - latchState: 跨 tick 计数器（driftCount / cleanReadbackStreak / latched）。
    /// - Returns: 决策 + 新 LatchState（.idle 路径计数器原样保留）。
    /// - Note: **用户改模式的计数器重置职责在调用方**——setMagSafeLed 落新值时
    ///   清零 LatchState（改模式 = 新意图，照 FanGuard.resetRequired 判例）；本函数
    ///   .idle 路径不代行重置。
    public static func correctionDecision(
        mode: MagSafeLEDMode,
        modeActive: Bool,
        supportState: SupportState,
        lastReadbackRaw: UInt8?,
        lastTickAction: CorrectionAction,
        latchState: LatchState
    ) -> (outcome: CorrectionOutcome, latchState: LatchState) {
        // ① 门槛（先于一切）：跟随系统 / 未激活 / 能力未决或不支持 → 不介入，
        //    计数器保留（含锁存态——解除交用户改模式的调用方重置路径）。
        if mode == .system || !modeActive || supportState != .supported {
            return (.idle, latchState)
        }
        // ② 锁存期：停纠偏（.skip 恒定），仅以回读维护自动解除 streak。
        if latchState.latched {
            return latchedTick(lastReadbackRaw, mode: mode, latchState: latchState)
        }
        // ③ 常规期：干净回读养 streak；脏回读按计费 gating 分流。
        return activeTick(lastReadbackRaw, mode: mode, lastTickAction: lastTickAction, latchState: latchState)
    }

    /// 锁存期 tick（②；.skip 恒定——动作语义 skipped，解除后首 tick 不被计费）：
    /// 干净回读（==期望）→ streak+1，达 cleanUnlockStreak 自动解除且计数器清零
    /// （防永久卡死，D5）；脏回读 → streak 清零、保持锁存；未读过 → 无新证据，
    /// 计数器原样。
    private static func latchedTick(
        _ readback: UInt8?, mode: MagSafeLEDMode, latchState: LatchState
    ) -> (outcome: CorrectionOutcome, latchState: LatchState) {
        guard let byte = readback else { return (.skip, latchState) }
        guard interpreting(byte) == mode else {
            // 脏回读：连续干净证据链断裂，保持锁存（driftCount 为既存证据不改动）。
            return (.skip, LatchState(
                driftCount: latchState.driftCount, cleanReadbackStreak: 0, latched: true))
        }
        let streak = latchState.cleanReadbackStreak + 1
        if streak >= cleanUnlockStreak {
            // 自动解除：driftCount 一并清零（新观察窗，防旧事件复燃误锁）。
            return (.skip, LatchState())
        }
        return (.skip, LatchState(
            driftCount: latchState.driftCount, cleanReadbackStreak: streak, latched: true))
    }

    /// 常规期 tick（③；未锁存）：干净回读 → streak+1 无动作（.skip——本 tick 无写，
    /// 与 lastTickAction 无关）；脏回读（外来合法值 ∨ 越域值，同尺）→ streak 断链 +
    /// lastTickAction 分流：writeVerified 计费（drift+1，达阈值 → conflictLatch 停纠偏；
    /// 未达 → 仍回收写纠偏），非 writeVerified（none 残留 / skipped / writeFailed
    /// 旧值）不计费但仍回收写（D4：回读≠期望 → 重写）。
    private static func activeTick(
        _ readback: UInt8?, mode: MagSafeLEDMode,
        lastTickAction: CorrectionAction, latchState: LatchState
    ) -> (outcome: CorrectionOutcome, latchState: LatchState) {
        guard let byte = readback else { return (.skip, latchState) }
        guard interpreting(byte) != mode else {
            // 干净回读：无动作，streak 养连击（若日后锁存即为解除凭据）。
            return (.skip, LatchState(
                driftCount: latchState.driftCount,
                cleanReadbackStreak: latchState.cleanReadbackStreak + 1,
                latched: false))
        }
        if lastTickAction == .writeVerified {
            let drift = latchState.driftCount + 1
            if drift >= driftLatchThreshold {
                // 达阈值：冲突锁存（本 tick 即停纠偏，不写——doctor 冲突态入口）。
                return (.conflictLatch, LatchState(driftCount: drift, cleanReadbackStreak: 0, latched: true))
            }
            return (.write(expected: mode), LatchState(driftCount: drift, cleanReadbackStreak: 0, latched: false))
        }
        // 非 writeVerified：不计费（残留/写失败旧值），streak 断链，仍回收写。
        return (.write(expected: mode), LatchState(
            driftCount: latchState.driftCount, cleanReadbackStreak: 0, latched: false))
    }

    /// wire 映射（纯函数，方案 §2）：SupportState → supported Bool（仅 .supported 为
    /// true）；readback 以 UInt8 原值承载 + 派生三态（readbackState），不用 Mode?
    /// 表达（防「未读过」与「他写」混叠，R1 P3-3）。conflict 由 daemon 侧填
    /// （锁存态内存缓存——M2 接线，纯函数默认 false 保持 M1 场景兼容）。
    public static func wireStatus(
        mode: MagSafeLEDMode?, supportState: SupportState, readbackRaw: UInt8?,
        conflict: Bool = false
    ) -> MagSafeLEDStatus {
        MagSafeLEDStatus(
            mode: mode,
            supported: supportState == .supported,
            readbackRaw: readbackRaw,
            conflict: conflict
        )
    }

    /// XPC 命令名（setMagSafeLed；DaemonXPC 命令分发与客户端同源引用）。
    public static let commandName = "setMagSafeLed"
}
