import Foundation

// MARK: - Phase 5 v1.1 风扇智能降温（方案 §4-§8）—— CellarCore 纯函数/纯值层

/// 风扇策略目录（方案 §4；rawValue 定版**只追加不重排**——fanStrategy 线格式映射
/// 0...3 同源，重排即旧客户端静默错配，R1 P3-3）。
public enum FanStrategy: String, Codable, Sendable, CaseIterable {
    /// 恒速降温【默认】：t ≥ 阈值 → 恒定 speedPercent% × F0Mx。
    case constantSpeed
    /// 抬升下限（**v1.1 仅保留枚举**：UI 灰显「即将支持」+ setFan 拒绝 + FanGuard
    /// C 行拦截，方案 §0.5b——U6 实测 F0Mn 写被固件 result=134 拒绝，基线持久化
    /// sidecar 设计完成后在 v1.x 放开）。
    case minRaise
    /// 两级分段：t ≥ 阈值 → stage1；t ≥ 阈值+rise → stage2（升档写、降档不写）。
    case twoStage
    /// 全速应急：t ≥ 阈值 → F0Mx。
    case emergency
}

/// 风扇策略（daemon 持久化在 policy.json 的 DaemonPolicy.fan 下，不新建文件，
/// 方案 §4）。阈值与充电热暂停（ThermalGuard 40/37）是两套独立配置项——同值
/// 不同义、独立演化（照 pauseC 与 Discharge.temperatureLimitC 先例），UI 脚注
/// 明示互不影响。
public struct FanPolicy: Codable, Equatable, Sendable {
    /// opt-in 开关（默认关）。
    public var enabled: Bool
    public var strategy: FanStrategy
    /// 温度阈值（厘摄氏度；3000...5500）。默认 3700 = 37.00°C——与
    /// `ThermalGuard.resumeC = 37.0` 同值**不同义**（独立演化，方案 §4 注记）。
    public var thresholdCentiC: Int
    /// 释放滞回（厘摄氏度；100...500）：t < 阈值−滞回才释放（防阈值边界抖动）。
    public var releaseHysteresisCentiC: Int
    /// 恒速/一级转速（百分数；40...100）。
    public var speedPercent: Int
    /// 两级分段第二级转速（百分数；60...100；仅 twoStage 使用）。
    public var stage2Percent: Int
    /// 两级分段升档温差（厘摄氏度；100...500）：t ≥ 阈值+rise 升到 stage2。
    public var stage2RiseCentiC: Int

    public init(
        enabled: Bool,
        strategy: FanStrategy,
        thresholdCentiC: Int,
        releaseHysteresisCentiC: Int,
        speedPercent: Int,
        stage2Percent: Int,
        stage2RiseCentiC: Int
    ) {
        self.enabled = enabled
        self.strategy = strategy
        self.thresholdCentiC = thresholdCentiC
        self.releaseHysteresisCentiC = releaseHysteresisCentiC
        self.speedPercent = speedPercent
        self.stage2Percent = stage2Percent
        self.stage2RiseCentiC = stage2RiseCentiC
    }

    /// 默认策略（方案 §4 定版：恒速 60% / 阈值 37.00°C / 滞回 2.00°C）。
    public static let `default` = FanPolicy(
        enabled: false, strategy: .constantSpeed,
        thresholdCentiC: 3700, releaseHysteresisCentiC: 200,
        speedPercent: 60, stage2Percent: 90, stage2RiseCentiC: 300
    )

    /// 值域（与 XPC 线格式 validFan* 同源——两边共用同一区间常量，方案 §8：
    /// XPCServer 值域校验与 validated 同源，CellarCoreCheck 同源测试）。
    public static let thresholdRangeCentiC = 3000...5500
    public static let hysteresisRangeCentiC = 100...500
    public static let speedRangePercent = 40...100
    public static let stage2RangePercent = 60...100
    public static let stage2RiseRangeCentiC = 100...500

    /// 校验：任何字段越界 → nil（绝不半合法——与 DaemonPolicy.validated 同纪律，
    /// 评审 A-2 同型：持久化回流/线格式全程必须经本强校验）。
    public static func validated(
        enabled: Bool,
        strategy: FanStrategy,
        thresholdCentiC: Int,
        releaseHysteresisCentiC: Int,
        speedPercent: Int,
        stage2Percent: Int,
        stage2RiseCentiC: Int
    ) -> FanPolicy? {
        guard thresholdRangeCentiC.contains(thresholdCentiC) else { return nil }
        guard hysteresisRangeCentiC.contains(releaseHysteresisCentiC) else { return nil }
        guard speedRangePercent.contains(speedPercent) else { return nil }
        guard stage2RangePercent.contains(stage2Percent) else { return nil }
        guard stage2RiseRangeCentiC.contains(stage2RiseCentiC) else { return nil }
        return FanPolicy(
            enabled: enabled, strategy: strategy,
            thresholdCentiC: thresholdCentiC, releaseHysteresisCentiC: releaseHysteresisCentiC,
            speedPercent: speedPercent, stage2Percent: stage2Percent, stage2RiseCentiC: stage2RiseCentiC
        )
    }
}

// MARK: - 能力/事实/决策/状态行词汇（方案 §5/§7/§8）

/// 风扇控制能力（sticky，方案 §5.2 纯函数推进；仅用户关→开开关时 daemon 重置
/// 为 unverified 重探——本类型自身不回落）。
public enum FanCapability: String, Codable, Sendable, Equatable {
    /// 尚未获得写跟随证据（启动/重置后的初始态）。
    case unverified
    /// 写跟随路径 A 证据成立（Ac ≥ 目标−300rpm，方案 §5.2 路径 A 实测可用）。
    case verified
    /// 本机不可用（观察窗到期无证据 / 键类型尺寸与预期不符 / 进入写连续失败——
    /// 诚实停用，不盲维持 boost；doctor「本机无法自动验证风扇控制」）。
    case unavailable
}

/// 本机风扇事实（F0Mn/F0Mx 运行时探测缓存；**不硬编码机型数值**，方案 §6.2）。
public struct FanFacts: Equatable, Sendable {
    /// F0Mn 下界 rpm（clamp 下界；F0Mn 只读——U6 实测写必被拒，方案 §2.4 条 5）。
    public let minRPM: Float
    /// F0Mx 上界 rpm（clamp 上界）。
    public let maxRPM: Float

    public init(minRPM: Float, maxRPM: Float) {
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }
}

/// 状态行词汇（方案 §7 九态；wire 格式永不本地化，App 侧同源映射展示词）。
/// 机内态 idle/boost/hold/release/degraded 由决策承载，本词汇仅为展示面。
public enum FanStateWord: String, Codable, Sendable, Equatable {
    /// 已关闭（开关关闭 / daemon 停用的交还路径）。
    case off
    /// 探测中（facts 未探测成功，非 boost 期每 tick 重探）。
    case probing
    /// 自动（静息正常态）。
    case automatic
    /// 加速中（→目标 rpm，boost 活跃）。
    case boost
    /// 保持（带内驻留，t 在 [阈值−滞回, ∞) 但未跨越升档条件）。
    case hold
    /// 已暂停介入（采样异常，方案 §6.6 F 行）。
    case degraded
    /// 本机不支持（能力不可用）。
    case unsupported
    /// 暂不支持该策略（minRaise，v1.1 拒绝）。
    case strategyUnsupported
    /// 检测到其他风扇控制写入者（冲突漂移检测，方案 §5.3）。
    case conflict
}

/// 风扇决策（方案 §5.1 求值序 A→B→F→C'→C→G→D→E→S 的输出；daemon 依此执行
/// 副作用——进入为两步写（Md=1→Tg）、释放为两步（Tg→原值快照→Md=0），各带
/// 写后回读校验，方案 §2.4 条 2/3）。
public enum FanDecision: Equatable, Sendable {
    /// 静息不写（word = 状态行词）。boostActive 输入下落本 case 不可达
    /// （不变量条款，方案 §5.1）。
    case idle(stateWord: FanStateWord)
    /// 进入 boost（仅 !boostActive 可达；daemon 副作用 = 两步写，失败不进入）。
    case enterBoost(targetRPM: Float)
    /// 带内驻留不写（boostActive 恒 true：G 观察窗到期 / D 常规带内）。
    case hold
    /// 带内重写（boostActive 恒 true：D 例外族——twoStage 升档跨越 ⊕ boost 期
    /// setFan 配置变更——立即按新目标重算重写，方案 §5.1 D）。
    case rewrite(targetRPM: Float)
    /// 交还系统（boostActive 恒 true；daemon 副作用 = 两步释放，次态 idle）。
    case release(stateWord: FanStateWord)
}

/// daemon 风扇状态载荷（DaemonStatus.fan 可选字段；旧 daemon 回包缺席 → nil，
/// App 提示升级，照 capabilities/autoDischargeEnabled 先例，方案 §8）。
/// 字段集 = 方案 §8 定版七字段 + 配置回显三字段（speedPercent/stage2Percent/
/// stage2RiseCentiC——设置区滑杆播种的单一真相；旧客户端解码忽略未知键，向后兼容）。
public struct FanStatus: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let strategy: FanStrategy
    /// 状态行词（方案 §7 九态）。
    public let state: FanStateWord
    /// 加速目标 rpm（boost/hold 期最近一次写入目标；nil = 未进入过 boost）。
    public let targetRPM: Float?
    /// 当前实际转速 rpm（F0Ac 活值回读——spike 定版：Ac 在 Md=0/1 下都活跃，
    /// 方案 §2.4 条 4；仅 boost 期采样，nil = 无）。
    public let currentRPM: Float?
    /// 温度阈值（厘摄氏度；App 状态行与配置回显共用）。
    public let thresholdCentiC: Int
    /// 冲突标志（方案 §5.3：外部写者漂移检测命中 → 会话内暂停介入）。
    public let conflictFlag: Bool
    /// 配置回显：恒速/一级转速（百分数；设置区滑杆播种）。
    public let speedPercent: Int
    /// 配置回显：第二级转速（百分数；twoStage 滑杆播种）。
    public let stage2Percent: Int
    /// 配置回显：升档温差（厘摄氏度；twoStage 滑杆播种）。
    public let stage2RiseCentiC: Int

    public init(
        enabled: Bool,
        strategy: FanStrategy,
        state: FanStateWord,
        targetRPM: Float?,
        currentRPM: Float?,
        thresholdCentiC: Int,
        conflictFlag: Bool,
        speedPercent: Int = FanPolicy.default.speedPercent,
        stage2Percent: Int = FanPolicy.default.stage2Percent,
        stage2RiseCentiC: Int = FanPolicy.default.stage2RiseCentiC
    ) {
        self.enabled = enabled
        self.strategy = strategy
        self.state = state
        self.targetRPM = targetRPM
        self.currentRPM = currentRPM
        self.thresholdCentiC = thresholdCentiC
        self.conflictFlag = conflictFlag
        self.speedPercent = speedPercent
        self.stage2Percent = stage2Percent
        self.stage2RiseCentiC = stage2RiseCentiC
    }
}

// MARK: - XPC 线格式（方案 §8：键全 UINT64，缺席 = 保持现值；类型混淆整包拒绝）

/// setFan 请求载荷（缺席字段 = 保持现值，照 auto 键缺席保持语义）。
public struct FanWire: Equatable, Sendable {
    public var enabled: UInt64?
    public var strategy: UInt64?
    public var threshold: UInt64?
    public var hysteresis: UInt64?
    public var speed: UInt64?
    public var stage2: UInt64?
    public var stage2Rise: UInt64?

    public init(
        enabled: UInt64? = nil, strategy: UInt64? = nil, threshold: UInt64? = nil,
        hysteresis: UInt64? = nil, speed: UInt64? = nil, stage2: UInt64? = nil,
        stage2Rise: UInt64? = nil
    ) {
        self.enabled = enabled
        self.strategy = strategy
        self.threshold = threshold
        self.hysteresis = hysteresis
        self.speed = speed
        self.stage2 = stage2
        self.stage2Rise = stage2Rise
    }
}

extension FanWire {
    /// 合并进现有策略（缺席保持）：任何字段非 nil 时应用；结果经
    /// `FanPolicy.validated` 强校验（非法 → nil，不半合法）。
    public func mergedPolicy(base: FanPolicy) -> FanPolicy? {
        FanPolicy.validated(
            enabled: enabled.map { $0 == 1 } ?? base.enabled,
            strategy: strategy.flatMap(FanWire.strategy(fromWire:)) ?? base.strategy,
            thresholdCentiC: threshold.flatMap { Int(exactly: $0) } ?? base.thresholdCentiC,
            releaseHysteresisCentiC: hysteresis.flatMap { Int(exactly: $0) } ?? base.releaseHysteresisCentiC,
            speedPercent: speed.flatMap { Int(exactly: $0) } ?? base.speedPercent,
            stage2Percent: stage2.flatMap { Int(exactly: $0) } ?? base.stage2Percent,
            stage2RiseCentiC: stage2Rise.flatMap { Int(exactly: $0) } ?? base.stage2RiseCentiC
        )
    }

    /// fanStrategy 线格式映射（方案 §8 定版：0=constantSpeed, 1=minRaise,
    /// 2=twoStage, 3=emergency；**只追加不重排**——写入 SMC-PROTOCOL 公共协议段）。
    public static func strategy(fromWire raw: UInt64) -> FanStrategy? {
        switch raw {
        case 0: return .constantSpeed
        case 1: return .minRaise
        case 2: return .twoStage
        case 3: return .emergency
        default: return nil
        }
    }

    public static func wireValue(_ strategy: FanStrategy) -> UInt64 {
        switch strategy {
        case .constantSpeed: return 0
        case .minRaise: return 1
        case .twoStage: return 2
        case .emergency: return 3
        }
    }
}

/// XPC setFan 键名与值域校验（与 FanPolicy.validated 同源：同一区间常量）。
/// 键全部 UINT64——validFan* 供 XPCServer 臂在 validateRequest 类型白名单之后
/// 做值域校验；缺席（nil）不发键。
public enum FanWireKeys {
    public static let enabled = "fanEnabled"
    public static let strategy = "fanStrategy"
    public static let threshold = "fanThreshold"
    public static let hysteresis = "fanHysteresis"
    public static let speed = "fanSpeed"
    public static let stage2 = "fanStage2"
    public static let stage2Rise = "fanStage2Rise"
    /// XPC 命令字面量（XPCServer 臂 / DaemonXPCClient 共用）。
    public static let command = "setFan"

    /// setFan 不在 v1.1 可执行集内的策略（minRaise）→ daemon 拒绝原文
    /// （fail-visible，方案 §0.5b）。
    public static let strategyUnsupportedMessage = "该策略在当前版本暂未开放"

    public static func validEnabled(_ raw: UInt64) -> Bool { raw <= 1 }
    public static func validStrategy(_ raw: UInt64) -> Bool { FanWire.strategy(fromWire: raw) != nil }
    public static func validThreshold(_ raw: UInt64) -> Bool {
        raw >= UInt64(FanPolicy.thresholdRangeCentiC.lowerBound) && raw <= UInt64(FanPolicy.thresholdRangeCentiC.upperBound)
    }
    public static func validHysteresis(_ raw: UInt64) -> Bool {
        raw >= UInt64(FanPolicy.hysteresisRangeCentiC.lowerBound) && raw <= UInt64(FanPolicy.hysteresisRangeCentiC.upperBound)
    }
    public static func validSpeed(_ raw: UInt64) -> Bool {
        raw >= UInt64(FanPolicy.speedRangePercent.lowerBound) && raw <= UInt64(FanPolicy.speedRangePercent.upperBound)
    }
    public static func validStage2(_ raw: UInt64) -> Bool {
        raw >= UInt64(FanPolicy.stage2RangePercent.lowerBound) && raw <= UInt64(FanPolicy.stage2RangePercent.upperBound)
    }
    public static func validStage2Rise(_ raw: UInt64) -> Bool {
        raw >= UInt64(FanPolicy.stage2RiseRangeCentiC.lowerBound) && raw <= UInt64(FanPolicy.stage2RiseRangeCentiC.upperBound)
    }
}

// MARK: - SMC flt 键编解码（U7 定版，方案 §2.4 条 1）

/// flt 类键编解码（IEEE754 单精度，**LE 打包定版**——spike 双序对照 7/7 键 LE
/// 合理、BE=0，方案 §2.4 条 1）。daemon 风扇状态机与 CLI/doctor 只读探测共用；
/// 单元测试钉死字节序（防回退 BE 的回归防护）。F0Mn/F0Mx/F0Tg/F0Ac 全部 flt/4B。
public enum FanSMC {
    /// 解码 flt LE（字节数 ≠ 4 → nil——调用方按格式不符 fail-visible，不做值格式猜测）。
    public static func decodeRPM(_ bytes: [UInt8]) -> Float? {
        guard bytes.count == 4 else { return nil }
        let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        return Float(bitPattern: bits)
    }

    /// 编码 flt LE。
    public static func encodeRPM(_ rpm: Float) -> [UInt8] {
        let bits = rpm.bitPattern
        return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF),
                UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24)]
    }

    /// 写后回读锁存重试阶梯（ms；0.5.1-alpha 热修）——daemon verifyFanKey 的
    /// 每次回读前延时表：先延时再回读，依次 [100, 300, 800]ms，共三次机会，
    /// 任一次读值 == 写入值即通过。
    ///
    /// 真机验证路径：2026-09-04 探针实测 F0Md 写入（kr=0 result=0）后 T+10ms
    /// 回读仍是旧值 0、T+100ms 已锁存为新值 1——模式寄存器有 ≤100ms 量级的
    /// 锁存延迟，写后立即回读必然撞在锁存完成之前（能力误判根因）。首档因此
    /// 必须 ≥ 100ms。真机验证在部署后由 daemon 写路径（F0Md/F0Tg 两步写/还原）
    /// 承担；本常量语义由 CellarCoreCheck 钉死（非空/首档 ≥100/严格单调递增），
    /// 时序本身不做纯函数模拟。
    public static let verifyLadderMs: [UInt32] = [100, 300, 800]
}