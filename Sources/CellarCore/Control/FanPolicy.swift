import Foundation

// MARK: - Phase 5 v1.1 风扇智能降温（方案 §4-§8）—— CellarCore 纯函数/纯值层

/// 风扇策略目录（方案 §4；rawValue 映射定版：**0=constantSpeed, 2=twoStage,
/// 3=emergency；1 = 退役洞，永久 reserved 不得赋予任何未来策略**——fanStrategy
/// 线格式映射同源，重排/填补退役洞都会让曾按旧目录发值的客户端静默错配）。
public enum FanStrategy: String, Codable, Sendable, CaseIterable {
    /// 恒速降温【默认】：t ≥ 阈值 → 恒定 speedPercent% × F0Mx。
    case constantSpeed
    /// 两级分段：t ≥ 阈值 → stage1；t ≥ 阈值+rise → stage2（升档写、降档不写）。
    case twoStage
    /// 全速应急：t ≥ 阈值 → F0Mx。
    case emergency
}

/// 风扇温度源（v1.11 T3 双源定版：电池【默认现状】+ CPU 表面温度 Ts proximity——
/// 本机压测实证：Ts 表面传感器平滑无尖峰与负载强相关；Tp 核心瞬时基线即 ±14°C
/// 跳变不可用；电池温度对短时负载零响应）。String rawValue 直存照 FanStrategy
/// 先例（未知字符串 → 解码炸 → PolicyStore 整包 nil 落默认——既有已钉死纪律）；
/// **只追加不重排**（重排即存量 policy.json 错配）。
public enum FanTemperatureSource: String, Codable, Sendable {
    /// 电池温度（BatterySnapshot.temperatureC，与充电热暂停同源——默认现状零变化）。
    case battery
    /// CPU 表面温度（SMC Ts 系 proximity 传感器，daemon 惰性探测 sticky）。
    case cpuSkin
}

/// 风扇策略（daemon 持久化在 policy.json 的 DaemonPolicy.fan 下，不新建文件，
/// 方案 §4）。阈值与充电热暂停（ThermalGuard 40/37）是两套独立配置项——同值
/// 不同义、独立演化（照 pauseC 与 Discharge.temperatureLimitC 先例），UI 脚注
/// 明示互不影响。
///
/// ⚠️ 手写 Codable（v1.11 R1 P0）：合成 Codable 全字段非可选——存量 policy.json
/// 缺 v1.11 新键 → keyNotFound 整包 nil → 升级即静默重置全部策略（含充电限值）。
/// decode：7 既有字段保持 required（既有字段缺失仍整包炸——绝不半合法语义不变），
/// 3 新字段 decodeIfPresent + 默认值；encode：全字段恒写（新字段非可选存储——
/// 旧客户端合成解码忽略未知键，恒写等价）。
public struct FanPolicy: Codable, Equatable, Sendable {
    /// opt-in 开关（默认关）。
    public var enabled: Bool
    public var strategy: FanStrategy
    /// 电池温度阈值（厘摄氏度；3000...5500——**语义收窄为 battery 域**，v1.11 T3：
    /// cpuSkin 域阈值独立字段。默认 3700 = 37.00°C——与 `ThermalGuard.resumeC =
    /// 37.0` 同值**不同义**（独立演化，方案 §4 注记）。
    public var thresholdCentiC: Int
    /// 电池温度释放滞回（厘摄氏度；100...500——**battery 域**）：t < 阈值−滞回才
    /// 释放（防阈值边界抖动）。
    public var releaseHysteresisCentiC: Int
    /// 恒速/一级转速（百分数；40...100）。
    public var speedPercent: Int
    /// 两级分段第二级转速（百分数；60...100；仅 twoStage 使用——**两源共用**）。
    public var stage2Percent: Int
    /// 两级分段升档温差（厘摄氏度；100...500；**两源共用**）：t ≥ 阈值+rise 升到
    /// stage2（升档线随 effectiveThreshold 走当前源）。
    public var stage2RiseCentiC: Int
    /// 温度源（默认 battery = 现状零变化；v1.11 T3）。
    public var temperatureSource: FanTemperatureSource
    /// CPU 表面温度阈值（厘摄氏度；4000...7000）。默认 5500 = 55.0°C。
    public var cpuSkinThresholdCentiC: Int
    /// CPU 表面温度释放滞回（厘摄氏度；300...800）。默认 400 = 4.0°C。
    public var cpuSkinHysteresisCentiC: Int

    public init(
        enabled: Bool,
        strategy: FanStrategy,
        thresholdCentiC: Int,
        releaseHysteresisCentiC: Int,
        speedPercent: Int,
        stage2Percent: Int,
        stage2RiseCentiC: Int,
        temperatureSource: FanTemperatureSource = .battery,
        cpuSkinThresholdCentiC: Int = 5500,
        cpuSkinHysteresisCentiC: Int = 400
    ) {
        self.enabled = enabled
        self.strategy = strategy
        self.thresholdCentiC = thresholdCentiC
        self.releaseHysteresisCentiC = releaseHysteresisCentiC
        self.speedPercent = speedPercent
        self.stage2Percent = stage2Percent
        self.stage2RiseCentiC = stage2RiseCentiC
        self.temperatureSource = temperatureSource
        self.cpuSkinThresholdCentiC = cpuSkinThresholdCentiC
        self.cpuSkinHysteresisCentiC = cpuSkinHysteresisCentiC
    }

    /// 默认策略（方案 §4 定版：恒速 60% / 电池阈值 37.00°C / 滞回 2.00°C；v1.11
    /// 新字段落 init 默认——battery / 5500 / 400，升级零回归）。
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
    /// cpuSkin 域（v1.11 T3 定版：阈值 40-70°C / 滞回 3-8°C——Ts 表面温度贴近
    /// die、静息基线高于电池温度，域与电池域独立）。
    public static let cpuSkinThresholdRangeCentiC = 4000...7000
    public static let cpuSkinHysteresisRangeCentiC = 300...800

    /// 校验：任何字段越界 → nil（绝不半合法——与 DaemonPolicy.validated 同纪律，
    /// 评审 A-2 同型：持久化回流/线格式全程必须经本强校验）。新参数带默认值——
    /// 既有调用点（PolicyStore.load/mergedPolicy/FanDomain helper）零改动不破编译。
    public static func validated(
        enabled: Bool,
        strategy: FanStrategy,
        thresholdCentiC: Int,
        releaseHysteresisCentiC: Int,
        speedPercent: Int,
        stage2Percent: Int,
        stage2RiseCentiC: Int,
        temperatureSource: FanTemperatureSource = .battery,
        cpuSkinThresholdCentiC: Int = 5500,
        cpuSkinHysteresisCentiC: Int = 400
    ) -> FanPolicy? {
        guard thresholdRangeCentiC.contains(thresholdCentiC) else { return nil }
        guard hysteresisRangeCentiC.contains(releaseHysteresisCentiC) else { return nil }
        guard speedRangePercent.contains(speedPercent) else { return nil }
        guard stage2RangePercent.contains(stage2Percent) else { return nil }
        guard stage2RiseRangeCentiC.contains(stage2RiseCentiC) else { return nil }
        guard cpuSkinThresholdRangeCentiC.contains(cpuSkinThresholdCentiC) else { return nil }
        guard cpuSkinHysteresisRangeCentiC.contains(cpuSkinHysteresisCentiC) else { return nil }
        return FanPolicy(
            enabled: enabled, strategy: strategy,
            thresholdCentiC: thresholdCentiC, releaseHysteresisCentiC: releaseHysteresisCentiC,
            speedPercent: speedPercent, stage2Percent: stage2Percent, stage2RiseCentiC: stage2RiseCentiC,
            temperatureSource: temperatureSource,
            cpuSkinThresholdCentiC: cpuSkinThresholdCentiC, cpuSkinHysteresisCentiC: cpuSkinHysteresisCentiC
        )
    }

    // MARK: - Codable（手写，v1.11 R1 P0——升级兼容，见类型头注记）

    private enum CodingKeys: String, CodingKey {
        case enabled, strategy, thresholdCentiC, releaseHysteresisCentiC
        case speedPercent, stage2Percent, stage2RiseCentiC
        case temperatureSource, cpuSkinThresholdCentiC, cpuSkinHysteresisCentiC
    }

    /// 手写 decode：7 既有字段 required（缺失仍炸——半合法不落盘语义不变），3 新
    /// 字段 decodeIfPresent 落默认（存量 policy.json 缺键不炸整包）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        strategy = try container.decode(FanStrategy.self, forKey: .strategy)
        thresholdCentiC = try container.decode(Int.self, forKey: .thresholdCentiC)
        releaseHysteresisCentiC = try container.decode(Int.self, forKey: .releaseHysteresisCentiC)
        speedPercent = try container.decode(Int.self, forKey: .speedPercent)
        stage2Percent = try container.decode(Int.self, forKey: .stage2Percent)
        stage2RiseCentiC = try container.decode(Int.self, forKey: .stage2RiseCentiC)
        temperatureSource = try container.decodeIfPresent(FanTemperatureSource.self, forKey: .temperatureSource) ?? .battery
        cpuSkinThresholdCentiC = try container.decodeIfPresent(Int.self, forKey: .cpuSkinThresholdCentiC) ?? 5500
        cpuSkinHysteresisCentiC = try container.decodeIfPresent(Int.self, forKey: .cpuSkinHysteresisCentiC) ?? 400
    }

    /// 手写 encode：全字段恒写（R2 P2-1 定版——新字段非可选存储；缺键省写会与
    /// 「decodeIfPresent 落默认」形成真实配置与回读值漂移的歧义形态）。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(strategy, forKey: .strategy)
        try container.encode(thresholdCentiC, forKey: .thresholdCentiC)
        try container.encode(releaseHysteresisCentiC, forKey: .releaseHysteresisCentiC)
        try container.encode(speedPercent, forKey: .speedPercent)
        try container.encode(stage2Percent, forKey: .stage2Percent)
        try container.encode(stage2RiseCentiC, forKey: .stage2RiseCentiC)
        try container.encode(temperatureSource, forKey: .temperatureSource)
        try container.encode(cpuSkinThresholdCentiC, forKey: .cpuSkinThresholdCentiC)
        try container.encode(cpuSkinHysteresisCentiC, forKey: .cpuSkinHysteresisCentiC)
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

/// 状态行词汇（方案 §7 八态；wire 格式永不本地化，App 侧同源映射展示词）。
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
/// stage2RiseCentiC）+ v1.11 T3 温度源五字段（源线值 / cpuSkin 温度与探测结论 /
/// cpuSkin 双阈值回显——滑杆播种单一真相，R1 P1-4）。旧客户端解码忽略未知键，
/// 向后兼容；新字段全部可选 + 合成 Codable decodeIfPresent——旧 daemon 回包缺席
/// → nil，App 门控升级提示。
public struct FanStatus: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let strategy: FanStrategy
    /// 状态行词（方案 §7 八态）。
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
    /// 温度源线值（v1.11 T3；0=battery / 1=cpuSkin——UINT64 数值映射见 FanWire；
    /// nil = 旧 daemon 未上报 → App 源 Picker 门控升级提示）。
    public let temperatureSource: Int?
    /// CPU 表面温度 °C（cpuSkin 源最近一次成功采样；battery 源/未采样 → nil）。
    public let cpuSkinTempC: Double?
    /// CPU 表面温度探测结论（true/false = sticky 探测结论；nil = 旧 daemon →
    /// App 升级提示，R1 P3-4 三态语义）。
    public let cpuSkinSupported: Bool?
    /// 配置回显：CPU 表面温度阈值（厘摄氏度；滑杆播种——R1 P1-4 双阈值回显）。
    public let cpuSkinThresholdCentiC: Int?
    /// 配置回显：CPU 表面温度释放滞回（厘摄氏度；滑杆播种）。
    public let cpuSkinHysteresisCentiC: Int?

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
        stage2RiseCentiC: Int = FanPolicy.default.stage2RiseCentiC,
        temperatureSource: Int? = nil,
        cpuSkinTempC: Double? = nil,
        cpuSkinSupported: Bool? = nil,
        cpuSkinThresholdCentiC: Int? = nil,
        cpuSkinHysteresisCentiC: Int? = nil
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
        self.temperatureSource = temperatureSource
        self.cpuSkinTempC = cpuSkinTempC
        self.cpuSkinSupported = cpuSkinSupported
        self.cpuSkinThresholdCentiC = cpuSkinThresholdCentiC
        self.cpuSkinHysteresisCentiC = cpuSkinHysteresisCentiC
    }
}

// MARK: - XPC 线格式

// FanWire / FanWireKeys 自 v1.11 M2 迁往 Control/FanWire.swift（同模块拆分——
// 本文件承载 v1.11 温度源扩面后触 400 行上限，纯移动零语义变化）。

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

    /// 解码 flt LE 温度（°C；v1.11 T3 cpuSkin 源专用别名——Ts 系键与转速键同一
    /// LE 打包定版，复用同一路径但独立命名，防调用点「decodeRPM 读温度」的语义
    /// 误读）。
    public static func decodeTemperatureC(_ bytes: [UInt8]) -> Float? {
        decodeRPM(bytes)
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