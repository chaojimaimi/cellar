import Foundation

// MARK: - 多 Profile 快照模型（0.23.18 方案 §2.1）—— CellarCore 纯值/纯函数层
//
// Profile = App 侧参数快照集；切换 = 快照经既有命令串行下发（编排器在 App 层，
// StatusController+ProfileApply.swift）。**策略唯一真相仍在 daemon（policy.json
// 一字不动）**——本层只是 App 侧的快捷重放层数据模型。
//
// 落点纪律（照 MenuPresetModel 先例）：本文件**必须在 CellarCore**——
// CellarCoreCheck 唯一依赖 ["CellarCore"]，判定面场景（ProfileDomain）才能 import
// 直测。模型**零用户可见串**（CellarCore 不可 import CellarL10n——Package.swift
// 单向依赖；profile 名是用户数据非 l10n 键）。
//
// 完备性门（UD-7 先例）：capture 只在 daemon 恒填字段全部在位时产出快照——任一
// 缺席（旧 daemon 形态）→ 整体 nil，**不造半份快照**（半份快照切换 = 静默丢旋钮，
// 比拒绝更危险）。fan 内部 v1.11 三键缺席同门（FanSnapshot.make 返回 nil）。

/// 风扇快照（九个已捕获旋钮字段；`releaseHysteresisCentiC` 无读回面——FanStatus
/// 不回显 battery 源释放滞回，快照不可知 → 不捕获不下发，缺席保持语义原样保留）。
public struct FanSnapshot: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var strategy: FanStrategy
    public var thresholdCentiC: Int
    public var speedPercent: Int
    public var stage2Percent: Int
    public var stage2RiseCentiC: Int
    /// 温度源线值原样（FanStatus.temperatureSource；0=battery / 1=cpuSkin）。
    public var temperatureSourceRaw: Int?
    public var cpuSkinThresholdCentiC: Int?
    public var cpuSkinHysteresisCentiC: Int?

    public init(
        enabled: Bool,
        strategy: FanStrategy,
        thresholdCentiC: Int,
        speedPercent: Int,
        stage2Percent: Int,
        stage2RiseCentiC: Int,
        temperatureSourceRaw: Int?,
        cpuSkinThresholdCentiC: Int?,
        cpuSkinHysteresisCentiC: Int?
    ) {
        self.enabled = enabled
        self.strategy = strategy
        self.thresholdCentiC = thresholdCentiC
        self.speedPercent = speedPercent
        self.stage2Percent = stage2Percent
        self.stage2RiseCentiC = stage2RiseCentiC
        self.temperatureSourceRaw = temperatureSourceRaw
        self.cpuSkinThresholdCentiC = cpuSkinThresholdCentiC
        self.cpuSkinHysteresisCentiC = cpuSkinHysteresisCentiC
    }

    /// 读回构造（capture 唯一入口）。**完备性门**：v1.11 三键（temperatureSource /
    /// cpuSkinThresholdCentiC / cpuSkinHysteresisCentiC）任一缺席 = 旧 daemon 形态
    /// → nil（capture 整体 nil 同门——不造半份快照）。
    public static func make(from status: FanStatus) -> FanSnapshot? {
        guard let source = status.temperatureSource,
              let cpuThreshold = status.cpuSkinThresholdCentiC,
              let cpuHysteresis = status.cpuSkinHysteresisCentiC else { return nil }
        return FanSnapshot(
            enabled: status.enabled,
            strategy: status.strategy,
            thresholdCentiC: status.thresholdCentiC,
            speedPercent: status.speedPercent,
            stage2Percent: status.stage2Percent,
            stage2RiseCentiC: status.stage2RiseCentiC,
            temperatureSourceRaw: source,
            cpuSkinThresholdCentiC: cpuThreshold,
            cpuSkinHysteresisCentiC: cpuHysteresis
        )
    }

    /// 快照 → setFan 下发载荷（链步唯一形态）。已捕获九键**全发**（setFan 缺席
    /// 保持语义下，只发变化键无法表达「恢复快照值」——全发即恢复语义）；映射经
    /// `FanWire.wireValue` 同源函数（零第二真相）。`hysteresis`（battery 源释放
    /// 滞回）恒 nil 不发——无读回面（见类型头注），缺席保持 = 该旋钮不归 profile
    /// 管（登记偏差 vs 方案「十键全发」字样）。
    public func fanWire() -> FanWire {
        FanWire(
            enabled: enabled ? 1 : 0,
            strategy: FanWire.wireValue(strategy),
            threshold: UInt64(thresholdCentiC),
            hysteresis: nil,
            speed: UInt64(speedPercent),
            stage2: UInt64(stage2Percent),
            stage2Rise: UInt64(stage2RiseCentiC),
            source: temperatureSourceRaw.flatMap { UInt64($0) },
            cpuThreshold: cpuSkinThresholdCentiC.flatMap { UInt64($0) },
            cpuHysteresis: cpuSkinHysteresisCentiC.flatMap { UInt64($0) }
        )
    }

    /// 回读对比（applyPlan diff-skip 与 activeMatch 共用比较输入）：九字段逐一全等。
    public func matches(_ status: FanStatus) -> Bool {
        enabled == status.enabled
            && strategy == status.strategy
            && thresholdCentiC == status.thresholdCentiC
            && speedPercent == status.speedPercent
            && stage2Percent == status.stage2Percent
            && stage2RiseCentiC == status.stage2RiseCentiC
            && temperatureSourceRaw == status.temperatureSource
            && cpuSkinThresholdCentiC == status.cpuSkinThresholdCentiC
            && cpuSkinHysteresisCentiC == status.cpuSkinHysteresisCentiC
    }
}

/// 热保护快照（therm 两键——daemon buildStatusLocked 恒填，UD-7）。
public struct ThermalSnapshot: Codable, Equatable, Sendable {
    public var pauseCentiC: Int
    public var hysteresisCentiC: Int

    public init(pauseCentiC: Int, hysteresisCentiC: Int) {
        self.pauseCentiC = pauseCentiC
        self.hysteresisCentiC = hysteresisCentiC
    }
}

/// 校准调度快照（calSched 三键——恒填，UD-7）。
public struct CalibrationSnapshot: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var intervalDays: Int
    public var startHour: Int

    public init(enabled: Bool, intervalDays: Int, startHour: Int) {
        self.enabled = enabled
        self.intervalDays = intervalDays
        self.startHour = startHour
    }
}

/// Profile 载荷（AppConfig.profiles 数组元素；Codable 经 app-config.json 持久化，
/// 旧配置文件缺 key 由 AppConfig decodeIfPresent 兼容）。
public struct ProfilePayload: Codable, Equatable, Sendable {
    /// 实例标识（UUID().uuidString——capture 产出即定，rename/复制语义见
    /// ProfileController；菜单项 representedObject / activeProfileID 引用此值）。
    public var id: String
    /// 用户命名（trim 后非空 ≤40 字符——ProfileModel.isValidName 校验；纯用户
    /// 数据，非 l10n 键）。
    public var name: String
    /// "active" | "disabled"（wire 字面量口径——mode 是 wire 值永不本地化）。
    public var mode: String
    public var upperLimit: Int
    public var hysteresis: Int
    public var fan: FanSnapshot?
    public var thermal: ThermalSnapshot?
    /// 充电日程配置 JSON 原样存取（byte 透传——daemon 回读什么就存什么/发什么，
    /// App 不解析不归一；diff = 字符串全等）。
    public var scheduleJson: String?
    public var calibration: CalibrationSnapshot?
    public var chHysteresisEnabled: Bool?
    /// MagSafeLEDMode.rawValue（nil = system 未设 opt-in 形态原样保留）。
    public var magSafeLedMode: UInt8?

    public init(
        id: String,
        name: String,
        mode: String,
        upperLimit: Int,
        hysteresis: Int,
        fan: FanSnapshot?,
        thermal: ThermalSnapshot?,
        scheduleJson: String?,
        calibration: CalibrationSnapshot?,
        chHysteresisEnabled: Bool?,
        magSafeLedMode: UInt8?
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.upperLimit = upperLimit
        self.hysteresis = hysteresis
        self.fan = fan
        self.thermal = thermal
        self.scheduleJson = scheduleJson
        self.calibration = calibration
        self.chHysteresisEnabled = chHysteresisEnabled
        self.magSafeLedMode = magSafeLedMode
    }
}

/// 切换计划项（纯值——编排器 exhaustively 映射为 ControlAttempt + XPC operation；
/// **无 .enable case**：启用一律由 setLimits 恒切 active 语义覆盖（方案 §2.2
/// 矩阵；杜绝死 case 不可达臂））。
public enum ProfileApplyStep: Equatable, Sendable {
    case setLimits(upperLimit: Int, hysteresis: Int)
    /// 十键载荷由 FanSnapshot.fanWire() 组装（链步经 runControl 不置
    /// fanPendingField——field 取形注记见编排器）。
    case setFan(FanWire)
    /// 全键下发（ThermalWire(policy) 便捷构造）。
    case setThermal(ThermalWire)
    case setChargeSchedule(json: String)
    /// 全键（CalibrationScheduleWire(policy) 便捷构造）。
    case setCalibrationSchedule(CalibrationScheduleWire)
    case setChHysteresisEnabled(Bool)
    /// 收尾步（disable 不动限值；编排器在成功回包后追加
    /// reconcileShutdownResidualNow 补偿——toggleCharging(false) 同款）。
    case disable
    /// MagSafeLEDMode.rawValue（链步走 runControl 通道——与 LED 轻路径并存互不
    /// 渗透，方案 §2.3 偏离登记）。
    case setMagSafeLed(UInt8)
}

// MARK: - 模型纯函数集

public enum ProfileModel {
    /// 方案数上限（create/duplicate 前置拒绝；UI 侧同源引用不重复编码）。
    public static let maxProfiles = 10

    /// 现值快照（UD-7 恒填字段完备性门：fan 恒填、therm 两键恒填、calSched 三键
    /// 恒填、scheduleJson 恒填、chHysteresisEnabled 恒填、magSafeLed 载荷恒填——
    /// 任一缺席（旧 daemon 形态）→ 整体 nil；fan 内部 v1.11 三键缺席经
    /// FanSnapshot.make 同门 nil）。调用方（ProfileController/管理页）对 nil 上屏
    /// 「无法捕获（daemon 版本过旧）」。name 留空由调用方命名后落库。
    public static func capture(from status: DaemonStatus) -> ProfilePayload? {
        guard let fan = status.fan,
              let fanSnapshot = FanSnapshot.make(from: fan),
              let pauseCentiC = status.thermPauseCentiC,
              let thermHysteresis = status.thermHysteresisCentiC,
              let calEnabled = status.calSchedEnabled,
              let calIntervalDays = status.calSchedIntervalDays,
              let calStartHour = status.calSchedStartHour,
              let scheduleJson = status.scheduleJson,
              let chHysteresisEnabled = status.chHysteresisEnabled,
              let ledStatus = status.magSafeLed
        else { return nil }
        return ProfilePayload(
            id: UUID().uuidString,
            name: "",
            mode: status.mode,
            upperLimit: status.upperLimit,
            hysteresis: status.hysteresis,
            fan: fanSnapshot,
            thermal: ThermalSnapshot(pauseCentiC: pauseCentiC, hysteresisCentiC: thermHysteresis),
            scheduleJson: scheduleJson,
            calibration: CalibrationSnapshot(
                enabled: calEnabled, intervalDays: calIntervalDays, startHour: calStartHour
            ),
            chHysteresisEnabled: chHysteresisEnabled,
            magSafeLedMode: ledStatus.mode?.rawValue
        )
    }

    /// 切换计划（模式转移矩阵 §2.2 八行 + 旋钮 diff-skip；**步序固定**：
    /// setLimits → setFan → setThermal → setChargeSchedule → setCalibrationSchedule
    /// → setChHysteresisEnabled → [disable] → setMagSafeLed——LED 最后，与充电语义
    /// 无耦合依赖）。全跳 → 空数组（编排器按「已应用」处理：只更新意图 + 反馈，
    /// 零命令）。
    ///
    /// 矩阵（p = profile.mode / c = current.mode / L = limits 同值）：
    /// needsSetLimits = ¬L ∨ (p==active ∧ c==disabled)（setLimits 恒切 active =
    /// 隐式启用）；needsDisable = (p==disabled) ∧ (c==active ∨ ¬L)（setLimits 会
    /// 强制 active，disabled 方案须拉回——行 8 双步存在亚秒级瞬态 active 执法窗，
    /// daemon API 面下不可避免，方案 §8 R14 登记）。
    public static func applyPlan(profile: ProfilePayload, current: DaemonStatus) -> [ProfileApplyStep] {
        let limitsSame = limitsMatch(profile, current)
        let needsSetLimits = !limitsSame || (profile.mode == "active" && current.mode == "disabled")
        let needsDisable = profile.mode == "disabled" && (current.mode == "active" || !limitsSame)
        var plan: [ProfileApplyStep] = []
        if needsSetLimits {
            plan.append(.setLimits(upperLimit: profile.upperLimit, hysteresis: profile.hysteresis))
        }
        if let fan = profile.fan, !fanMatches(fan, current) {
            plan.append(.setFan(fan.fanWire()))
        }
        if let thermal = profile.thermal, !thermalMatches(thermal, current) {
            plan.append(.setThermal(ThermalWire(ThermalPolicy(
                pauseCentiC: thermal.pauseCentiC, hysteresisCentiC: thermal.hysteresisCentiC
            ))))
        }
        if let json = profile.scheduleJson, json != current.scheduleJson {
            plan.append(.setChargeSchedule(json: json))
        }
        if let calibration = profile.calibration, !calibrationMatches(calibration, current) {
            plan.append(.setCalibrationSchedule(CalibrationScheduleWire(CalibrationSchedulePolicy(
                enabled: calibration.enabled,
                intervalDays: calibration.intervalDays,
                startHour: calibration.startHour
            ))))
        }
        if let chHysteresis = profile.chHysteresisEnabled,
           chHysteresis != current.chHysteresisEnabled {
            plan.append(.setChHysteresisEnabled(chHysteresis))
        }
        if needsDisable {
            plan.append(.disable)
        }
        if let ledMode = profile.magSafeLedMode,
           ledMode != current.magSafeLed?.mode?.rawValue {
            plan.append(.setMagSafeLed(ledMode))
        }
        return plan
    }

    /// 读回活动判定（✓ 标注唯一数据源——**读回派生非意图镜像**，防意图漂移；
    /// 方案 §2.1 B3-5 诚实语义）：逐字段全匹配 → 按列表序首个匹配 id；全不匹配
    /// → nil（✓ 不显示——「本地意图 ≠ daemon 现值」如实呈现）。
    ///
    /// 与 applyPlan 共用同一比较域（limitsMatch / 六旋钮 helper 单源——评审 P3）：
    /// wire 契约域（mode ∈ "active"|"disabled"）上 applyPlan(profile:current:).isEmpty
    /// ⇔ 本函数命中该 profile（结构性证明，方案-11 互证钉死）。
    public static func activeMatch(profiles: [ProfilePayload], current: DaemonStatus) -> String? {
        for profile in profiles where readbackMatches(profile, current) {
            return profile.id
        }
        return nil
    }

    /// 命名校验：trim 后非空且 ≤40 字符（管理页行内红字校验 + create/rename
    /// 前置门共用）。
    public static func isValidName(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 40
    }

    // MARK: - 收敛守卫（纯函数——编排器消费，可向量直测，方案 §2.3 R16 落地面）

    /// 步型 witness（applyStepCaseCount 穷举 switch 需要一个 ProfileApplyStep 实例
    /// 驱动；任取 .disable——计数与实例无关）。
    private static let witness = ProfileApplyStep.disable

    /// 步型总数（穷举 switch 派生——**新增 case 时本模式清单编译失败**，计数被迫
    /// 经本文件同步，杜绝上限漂移；评审 P3）。任意输入恒 8。
    public static func applyStepCaseCount(of step: ProfileApplyStep) -> Int {
        switch step {
        case .setLimits, .setFan, .setThermal, .setChargeSchedule,
             .setCalibrationSchedule, .setChHysteresisEnabled, .disable, .setMagSafeLed:
            return 8
        }
    }

    /// 收敛守卫（链推进单点保险，全值输入输出）：
    /// - **守卫一**：lastStep == nextStep = 紧邻同型步重推导 = 上一发步后读回未
    ///   收敛（日程 JSON 归一化漂移等）→ 中止；
    /// - **守卫二**：executed ≥ applyStepCaseCount = 步型全发仍未收敛 = 振荡 →
    ///   中止。
    ///
    /// 评审收口 P1（0.23.18 全审）：原「nextStep == nil 仅查守卫二」双语义入口
    /// 随编排器链尾判定前置消除（唯一调用点 plan.first 判空先行 → nextStep 恒
    /// 非 nil），签名收窄为非可选 nextStep 单语义——双参 Optional 形态退役。
    public static func chainGuardShouldAbort(
        lastStep: ProfileApplyStep?,
        nextStep: ProfileApplyStep,
        executed: Int
    ) -> Bool {
        lastStep == nextStep || executed >= applyStepCaseCount(of: witness)
    }

    // MARK: - 比较域（applyPlan diff-skip 与 activeMatch 单源——评审 P3 实现纪律）

    private static func limitsMatch(_ profile: ProfilePayload, _ status: DaemonStatus) -> Bool {
        profile.upperLimit == status.upperLimit && profile.hysteresis == status.hysteresis
    }

    /// fan 读回对比（current.fan nil = 读回缺席 → 视为不匹配，发步如实在蜂）。
    private static func fanMatches(_ fan: FanSnapshot, _ status: DaemonStatus) -> Bool {
        guard let readback = status.fan else { return false }
        return fan.matches(readback)
    }

    private static func thermalMatches(_ thermal: ThermalSnapshot, _ status: DaemonStatus) -> Bool {
        status.thermPauseCentiC == thermal.pauseCentiC
            && status.thermHysteresisCentiC == thermal.hysteresisCentiC
    }

    private static func calibrationMatches(
        _ calibration: CalibrationSnapshot, _ status: DaemonStatus
    ) -> Bool {
        status.calSchedEnabled == calibration.enabled
            && status.calSchedIntervalDays == calibration.intervalDays
            && status.calSchedStartHour == calibration.startHour
    }

    /// 全字段读回匹配（activeMatch 内核；nil 快照字段 = profile 未捕获该旋钮 →
    /// 跳过该项不判——与 applyPlan 的跳步语义同构，评审 P3）。
    private static func readbackMatches(_ profile: ProfilePayload, _ status: DaemonStatus) -> Bool {
        profile.mode == status.mode && limitsMatch(profile, status)
            && fanFieldMatches(profile, status)
            && thermalFieldMatches(profile, status)
            && scheduleFieldMatches(profile, status)
            && calibrationFieldMatches(profile, status)
            && chFieldMatches(profile, status)
            && ledFieldMatches(profile, status)
    }

    private static func fanFieldMatches(_ profile: ProfilePayload, _ status: DaemonStatus) -> Bool {
        guard let fan = profile.fan else { return true }
        return fanMatches(fan, status)
    }

    private static func thermalFieldMatches(_ profile: ProfilePayload, _ status: DaemonStatus) -> Bool {
        guard let thermal = profile.thermal else { return true }
        return thermalMatches(thermal, status)
    }

    private static func scheduleFieldMatches(_ profile: ProfilePayload, _ status: DaemonStatus) -> Bool {
        guard let json = profile.scheduleJson else { return true }
        return json == status.scheduleJson
    }

    private static func calibrationFieldMatches(_ profile: ProfilePayload, _ status: DaemonStatus) -> Bool {
        guard let calibration = profile.calibration else { return true }
        return calibrationMatches(calibration, status)
    }

    private static func chFieldMatches(_ profile: ProfilePayload, _ status: DaemonStatus) -> Bool {
        guard let chHysteresis = profile.chHysteresisEnabled else { return true }
        return chHysteresis == status.chHysteresisEnabled
    }

    private static func ledFieldMatches(_ profile: ProfilePayload, _ status: DaemonStatus) -> Bool {
        guard let ledMode = profile.magSafeLedMode else { return true }
        return ledMode == status.magSafeLed?.mode?.rawValue
    }
}
