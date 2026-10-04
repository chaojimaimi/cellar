import Foundation

#if canImport(XPC)
import XPC
#endif

/// daemon 状态快照（XPC 回包 / CLI 渲染 / doctor 检查共用；Codable JSON 通讯载荷）。
///
/// lastAction 为最近一次策略/事件动作的人类可读描述（如 "enforce:disableCharging"、
/// "sleep:noop"、"disable"），可选字段随采样状态填充，未采样过为 nil。
public struct DaemonStatus: Codable, Equatable, Sendable {
    /// daemon 版本（install 后核对：防 CLI 对 stale daemon，评审 F-3）。
    public var version: String
    /// "active" | "disabled"。
    public var mode: String
    public var upperLimit: Int
    public var hysteresis: Int
    public var lastAction: String?
    public var lastPercent: Int?
    public var lastExternalConnected: Bool?
    public var lastChargingEnabled: Bool?
    /// 活跃的一次性动作（WP2「充满一次」；nil = 无动作）。可选字段 + 合成 Codable 的
    /// decodeIfPresent——旧 daemon 回包/旧客户端解码天然兼容（缺席 → nil）。
    public var action: OneShotAction?
    /// daemon 能力清单（WP2' 能力发现，§2.1）：启动探测通过时置 `["discharge"]`；
    /// nil = 旧 daemon 未上报（App 提示升级）；[] = 已上报但不含 discharge（机型不支持）。
    /// 合成 Codable decodeIfPresent——旧 daemon 回包缺席 → nil 天然兼容（评审 P2-5）。
    public var capabilities: [String]?
    /// WP2' 自动放电开关（daemon 每次 buildStatusLocked 从 policy 填充）；
    /// 可选字段 + 合成 Codable——旧 daemon 回包缺席 → nil 天然兼容。
    public var autoDischargeEnabled: Bool?
    /// Phase 5 v1.1 风扇状态载荷（daemon 每次 buildStatusLocked 从风扇运行时
    /// 状态组装；可选字段 + 合成 Codable decodeIfPresent——旧 daemon 回包缺席
    /// → nil，App 提示升级，照 autoDischargeEnabled 先例，方案 §8）。
    public var fan: FanStatus?
    /// Phase 5 v1.4 校准调度配置回读（buildStatusLocked **恒填**——未配置用户填
    /// .default，照 fanStatusLocked 先例，UD-7；可选字段 decodeIfPresent——旧
    /// daemon 回包缺席 → nil，App 据此整卡升级提示）。
    public var calSchedEnabled: Bool?
    public var calSchedIntervalDays: Int?
    public var calSchedStartHour: Int?
    /// Phase 5 v1.4 上次校准记录（epoch 秒 + 归一词，state 内存缓存读取，UD-5；
    /// 无记录 → lastCal 三键缺席表达）。
    public var lastCalStart: Int?
    public var lastCalEnd: Int?
    public var lastCalOutcome: String?
    /// Phase 5 v1.5 热暂停配置回读（buildStatusLocked **恒填** `policy.thermal ??
    /// .default` 展开，UD-7——照 calSched 三键先例，防默认配置用户被误判旧 daemon；
    /// 合成 Codable decodeIfPresent——旧 daemon 回包缺席 / 旧客户端解码 → nil 兼容）。
    public var thermPauseCentiC: Int?
    public var thermHysteresisCentiC: Int?
    /// Phase 5 v1.6 充电日程配置回读（buildStatusLocked **恒填**——未配置用户填
    /// 空配置 JSON，照 calSched 先例 UD-7，防默认配置用户被误判旧 daemon；
    /// 合成 Codable decodeIfPresent——旧 daemon 回包缺席 / 旧客户端解码 → nil 兼容，
    /// App 据此整卡升级提示）。
    public var scheduleJson: String?
    /// 当前命中窗口条目 id（state 内存缓存读；nil = 无在窗应用/旧 daemon）。
    public var scheduleActiveId: String?
    /// Phase 5 v1.7 原生限充注册态（daemon 在 getStatus 快照时 load() 每请求填充，
    /// 方案 §3.2——不进 enforce tick；三态形态由 NativeChargeLimit.wireStatus 钉死）。
    /// 可选字段 + 合成 Codable decodeIfPresent——旧 daemon 回包缺席 → nil 天然兼容
    /// （App 提示升级），照 fan/autoDischargeEnabled 先例。
    public var nativeLimit: NativeLimitStatus?
    /// Phase 5 v1.8 MagSafe LED 状态载荷（buildStatusLocked **恒填**——内存缓存
    /// 组装零读盘，v1.7 P1 教训：全回包携带；可选字段 + 合成 Codable
    /// decodeIfPresent——旧 daemon 回包缺席 → nil，App 提示升级，照 fan 先例）。
    public var magSafeLed: MagSafeLEDStatus?
    /// v0.19.20 编排状态载荷（buildStatusLocked **恒填**——内存组装零读盘，照
    /// magSafeLed 先例，UD-7：全回包携带防 ingest 覆盖触发「旧 daemon」闪断；
    /// 合成 Codable decodeIfPresent——旧 daemon 回包缺席 → nil 天然兼容）。
    public var orchestration: OrchestrationStatus?
    /// 0.20 M1a 合盖状态（§2.2 合盖拒绝闸；追加式可选字段——合成 Codable
    /// decodeIfPresent，旧 daemon 回包缺席 / 旧客户端解码 → nil 兼容，wire 零破坏）。
    /// true = 合盖（放电启动拒绝/运行中止判据）；nil = 读取失败或未探测（诚实缺席，
    /// 弱检查局限见 docs/DEVICES.md 键世代表）。
    public var clamshellClosed: Bool?
    /// 0.20 M1b sub80 通道态（WP2 §3.2 降级态传播；追加式可选字段——decodeIfPresent
    /// 先例）。三态：active（topoff 承载）/ degraded（重申×3 降级，编排钳 80）/
    /// off（关断清理后）；**26/无 sub80 能力机器不填**（缺席 = 无此特性，R3-P3）。
    public var sub80State: Sub80State?
    /// 0.21.0 §2.2 CHIE 迟滞执法挂载态（**独立可选字段——不改 Sub80State Codable 枚举**，
    /// decodeIfPresent 先例，防旧 App 整包解码失败）。true = 迟滞备用通道执法中（面板
    /// 横幅「实验性备用通道执法中（约 1 循环/天）」数据源）；**仅 sub80 能力机恒填**，
    /// 26/无能力机器不填（缺席 = 无此特性——与 sub80State 同纪律）。
    public var sub80Hysteresis: Bool?
    /// 0.21.0 §2.4 开关回读（policy.chHysteresisEnabled **恒填**——照 orchestration.
    /// enabled 单一真相先例，App 开关绑定源；可选字段 decodeIfPresent——旧 daemon 回包
    /// 缺席 → nil 天然兼容，App 按 nil = 关处理）。26 平台照填（UI 侧 capabilities
    /// 门控不渲染——wire 恒填与渲染门控分层）。
    public var chHysteresisEnabled: Bool?
    /// 0.21.0 §3.2 校准抑制态（模式指纹识别——「系统校准中（限充暂缓——校准结束
    /// 自动恢复）」面板横幅/status/doctor 行数据源）。**27 观测段识别
    ///（orchestrationTerminal 门内恒填）**；26/旧 daemon 缺席 = 无此特性
    ///（decodeIfPresent wire 兼容先例）。诚实边界：模式识别有误报/漏报可能
    ///（方案 §3.2 登记）。
    public var calibrationSuspected: Bool?
    /// 0.21.0 §5 GUI sub80 明细——自愈探针进度两键（观察窗进行中 + 拍计数；
    /// **仅 sub80 能力机恒填**，26/旧 daemon 缺席 = 无此特性）。验证窗总长 =
    /// `Topoff.verificationTicks`（CellarCore 常量，UI 侧同源引用不重复编码）。
    public var sub80HealProbeActive: Bool?
    public var sub80HealProbeTicks: Int?
    /// 0.21.1 §2.2 域生效值（topoffprotection mclLimitValue 最近成功写入值——agent
    /// 实际跟随值；**仅 sub80 能力机填充**，26/旧 daemon 缺席 = 无此特性，
    /// decodeIfPresent wire 兼容先例）。App 读回行失配提示数据源：MCL 读回（系统
    /// 设置现值）≠ 域生效值 → 「系统设置 X% 已被 Cellar 目标 Y% 覆盖」提示——
    /// 域随写覆盖全区间后系统 MCL 被统一覆盖的显性化（方案 §0.3/§2.2）。
    /// fresh 重启首拍写前缺席（nil = 无提示——诚实缺席，幂等重写后填充）。
    public var sub80WrittenLimit: Int?
    /// 0.21.1 §1.1 门 c 振荡熔断抑制态（App 横幅「自动放电已暂停：检测到频繁
    /// 放电循环」数据源；decodeIfPresent wire 兼容先例）。true = 2h 滑窗内 ≥2 次
    /// autostart 放电完成 → 后续自动放电静默（手动放电不受影响）；解除 = 重启
    ///（内存态）或用户重新 opt-in。恒填（daemon 每回包从锁内运行态组装）。
    public var autoDischargeSuspended: Bool?
    /// 0.21.3 §1.3 UI-100 机制关闭检测（G3）：topoff 域连续 ≥2 拍覆写签名命中
    ///（suppressionConsecutive ≥ Topoff.suppressionThreshold——锁存）。true =
    /// 系统设置把充电上限设为 100% 关闭了原生限充机制，Cellar 正在自动恢复——
    /// App 通用页警示行 + doctor 检查 20 FAIL 臂数据源。**仅 sub80 能力机恒填**
    ///（26/旧 daemon 缺席 = 无此特性，decodeIfPresent wire 兼容先例）；解除 =
    /// 域读回一致清零（锁存期 daemon 对非违规 owned 拍也补采样读回——覆写源
    /// 停止后下一拍即解除，随轮询自然消失〔review P1 半死态根治〕）。
    public var sub80MechanismSuppressed: Bool?
    /// 0.21.3 §2.1 MCL 对账期望派生的两窗输入（shutdownExpectation 八行表行 1/2）：
    /// fullOnce 临时放开窗是否在位（orchestrationState.fullOnceWindowActive）。
    /// **orchestrationTerminal 门内恒填**（27 观测段；26/旧 daemon 缺席 = 无此
    /// 特性——App 对账循环 orchestrationTerminal 门内天然不消费，decodeIfPresent
    /// wire 兼容先例）。
    public var fullOnceWindowActive: Bool?
    /// 同上——chargingDisabled 日程窗是否在位（scheduleState.lastAppliedEntryId
    /// 派生的显式字段——单一真相，勿由 App 侧再派生）。orchestrationTerminal
    /// 门内恒填。
    public var chargingDisabledWindowActive: Bool?
    /// 快照时刻（最近一次成功采样；未采样过为状态组装时刻）。
    public var timestamp: Date

    public init(
        version: String,
        mode: String,
        upperLimit: Int,
        hysteresis: Int,
        lastAction: String? = nil,
        lastPercent: Int? = nil,
        lastExternalConnected: Bool? = nil,
        lastChargingEnabled: Bool? = nil,
        action: OneShotAction? = nil,
        capabilities: [String]? = nil,
        autoDischargeEnabled: Bool? = nil,
        fan: FanStatus? = nil,
        calSchedEnabled: Bool? = nil,
        calSchedIntervalDays: Int? = nil,
        calSchedStartHour: Int? = nil,
        lastCalStart: Int? = nil,
        lastCalEnd: Int? = nil,
        lastCalOutcome: String? = nil,
        thermPauseCentiC: Int? = nil,
        thermHysteresisCentiC: Int? = nil,
        scheduleJson: String? = nil,
        scheduleActiveId: String? = nil,
        nativeLimit: NativeLimitStatus? = nil,
        orchestration: OrchestrationStatus? = nil,
        clamshellClosed: Bool? = nil,
        sub80State: Sub80State? = nil,
        sub80Hysteresis: Bool? = nil,
        chHysteresisEnabled: Bool? = nil,
        calibrationSuspected: Bool? = nil,
        sub80HealProbeActive: Bool? = nil,
        sub80HealProbeTicks: Int? = nil,
        sub80WrittenLimit: Int? = nil,
        autoDischargeSuspended: Bool? = nil,
        sub80MechanismSuppressed: Bool? = nil,
        fullOnceWindowActive: Bool? = nil,
        chargingDisabledWindowActive: Bool? = nil,
        timestamp: Date = Date()
    ) {
        self.version = version
        self.mode = mode
        self.upperLimit = upperLimit
        self.hysteresis = hysteresis
        self.lastAction = lastAction
        self.lastPercent = lastPercent
        self.lastExternalConnected = lastExternalConnected
        self.lastChargingEnabled = lastChargingEnabled
        self.action = action
        self.capabilities = capabilities
        self.autoDischargeEnabled = autoDischargeEnabled
        self.fan = fan
        self.calSchedEnabled = calSchedEnabled
        self.calSchedIntervalDays = calSchedIntervalDays
        self.calSchedStartHour = calSchedStartHour
        self.lastCalStart = lastCalStart
        self.lastCalEnd = lastCalEnd
        self.lastCalOutcome = lastCalOutcome
        self.thermPauseCentiC = thermPauseCentiC
        self.thermHysteresisCentiC = thermHysteresisCentiC
        self.scheduleJson = scheduleJson
        self.scheduleActiveId = scheduleActiveId
        self.nativeLimit = nativeLimit
        self.orchestration = orchestration
        self.clamshellClosed = clamshellClosed
        self.sub80State = sub80State
        self.sub80Hysteresis = sub80Hysteresis
        self.chHysteresisEnabled = chHysteresisEnabled
        self.calibrationSuspected = calibrationSuspected
        self.sub80HealProbeActive = sub80HealProbeActive
        self.sub80HealProbeTicks = sub80HealProbeTicks
        self.sub80WrittenLimit = sub80WrittenLimit
        self.autoDischargeSuspended = autoDischargeSuspended
        self.sub80MechanismSuppressed = sub80MechanismSuppressed
        self.fullOnceWindowActive = fullOnceWindowActive
        self.chargingDisabledWindowActive = chargingDisabledWindowActive
        self.timestamp = timestamp
    }
}

/// Phase 5 v1.7 原生限充状态载荷（DaemonStatus.nativeLimit 可选字段；旧 daemon
/// 回包缺席 → nil，App 提示升级，照 fan: FanStatus? 先例，方案 §3.2）。
///
/// 三态钉死（wire 形态被场景 原生-16/17 与 M2 原生-23..24 钉死，映射纯函数
/// `NativeChargeLimit.wireStatus`）：
/// - 字段缺席（DaemonStatus.nativeLimit == nil）= 旧 daemon（App 弹升级提示）；
/// - known=false = 检测器未知态 ⇒ 恒 active=false 且双 socLimit=nil；
/// - known=true ∧ active=false（无阻断策略）⇒ 恒双 socLimit=nil——App 无需猜测。
public struct NativeLimitStatus: Codable, Sendable, Equatable {
    /// false = 检测器故障（读取/解析失败，未知态）；与新 daemon「恒填」约定并存：
    /// 字段缺席 = 旧 daemon；字段在 + known=false = 检测器未知。
    public var known: Bool
    /// 原生限充激活（守卫口径 blockingPolicies 非空——不限 reason，物理执法事实）。
    public var active: Bool
    /// blockingPolicies 最小 soclimit（active=true 时填充——最先触发者；
    /// active=false 恒 nil）。
    public var socLimit: Int?
    /// 手动策略过滤口径（reason == "manualChargeLimit" 最小值，R2 P1——注记行/
    /// 冲突横幅消费；无手动策略或 active=false 恒 nil）。
    public var manualSocLimit: Int?

    public init(known: Bool, active: Bool, socLimit: Int?, manualSocLimit: Int?) {
        self.known = known
        self.active = active
        self.socLimit = socLimit
        self.manualSocLimit = manualSocLimit
    }
}

/// CLI 侧 XPC 调用失败矩阵（评审 E-3）：timeout/connectionFailed → "daemon 未安装或未运行"；
/// daemonError → 原文透传。
public enum DaemonClientError: Error, Equatable, Sendable {
    /// 5 秒无回包。
    case timeout
    /// 连接建立失败 / 对端连接无效（daemon 未运行即为此态）。
    case connectionFailed
    /// daemon 回包 ok=false（含 euid 鉴权拒绝与参数错误），原文随包带回。
    case daemonError(String)
}

/// raw XPC 协议（规格 §2）：请求键 cmd/upper/hysteresis；回包键 ok/status|error。
/// 不用 NSXPCConnection——euid 校验可直接用 `xpc_connection_get_euid`，
/// 同步回传对 CLI 天然友好（评审 E-4：reply_sync 无超时参数，客户端自行信号量限时）。
public enum DaemonXPC {
    public static let machServiceName = "com.cellar.daemon"
    // install 后与 getStatus 的 version 核对（评审 F-3）；与 App/CLI 版本串一致
    // ——daemon 行为有变更必须 bump（WP2' 扩 dischargeToLimit 协议 + ActionState
    // 扩展 + capabilities 字段，行为变更第三次破例）：0.3.0 已发布于 WP2 面板卸载
    // 重装验证，本包为 0.3.1（发布归宿 0.3.1-alpha，防版本回退）。
    // WP1（0.4.0-alpha）：常规执法路径介入充电侧温度守卫 + 放电恢复路径传温，
    // 行为变更第四次破例 bump（doctor 版本矩阵三方一致）。
    // Phase 5 v1.1（0.5.0-alpha）：新增 setFan 命令 + DaemonStatus.fan 字段
    // （风扇智能降温，行为变更第五次破例 bump——install 后 getStatus 版本核对
    // 同置，防 CLI 对 stale daemon）。
    // 0.5.1-alpha（2026-09-04 热修）：风扇键写后回读锁存延迟（≤100ms 量级）导致
    // 能力误判——verifyFanKey 改锁存重试阶梯（行为修复，第六次破例 bump）。
    // 0.6.0-alpha（2026-09-04）：纯 App/UI 层打磨批（页脚 + 设置窗高度），协议
    // 零变更——随版本矩阵同步 bump（doctor 三方一致纪律）。
    // 0.6.1-alpha（2026-09-04）：设置窗分节视觉打磨，协议零变更（同上纪律）。
    // 0.7.0-alpha（2026-09-04）：实时仪表板主窗口（App 层新增，协议零变更——
    // 随版本矩阵同步 bump，doctor 三方一致纪律）。
    // 0.8.0-alpha（2026-09-05）：统计面板（App 侧 SQLite 本地采样，协议零变更——
    // 同上纪律）。
    // 0.9.0-alpha（2026-09-04）：校准调度批——新增 setCalibrationSchedule 命令 +
    // DaemonStatus calSched 三键（恒填）与 lastCal 三键（上次校准记录回读），
    // 行为变更第七次破例 bump（install 后 getStatus 版本核对，防 CLI/App 对
    // stale daemon，UD-9）。
    // 0.10.0-alpha（2026-09-05）：Phase 5 v1.5 热保护完整化——新增 setThermal 命令
    // + DaemonStatus thermPauseCentiC/thermHysteresisCentiC 两键（恒填），行为变更
    // 第八次破例 bump（install 后 getStatus 版本核对，防 CLI/App 对 stale daemon，
    // UD-9；M4 发布批补 Info.plist/package-release.sh 两方）。
    // 0.11.0-alpha（2026-09-05）：Phase 5 v1.6 自动化批 M2（daemon 日程引擎）——
    // 新增 setChargeSchedule 命令 + **首个字符串键** scheduleJson（UD-6，数组配置
    // 不可 UINT64 表达；validateRequest 白名单 STRING 类型 + ≤8192 字节）+
    // DaemonStatus scheduleJson/scheduleActiveId 两键（前者恒填——新 daemon 恒非
    // nil，nil = 旧 daemon 门控），行为变更第九次破例 bump（install 后 getStatus
    // 版本核对，防 CLI/App 对 stale daemon，UD-9；M4 发布批补 Info.plist/
    // package-release.sh 两方）。
    public static let daemonVersion = "0.22.4-alpha"
    /// discharge 能力字面量（App/daemon 同源引用，§2.1）：daemon 启动探测通过
    /// （backend == "tahoe" ∧ CHIE getKeyInfo 在位，评审 P1-1 fail-closed）时置于
    /// `DaemonStatus.capabilities`。App 两态文案：nil = 需升级守护进程（面板卸载
    /// 重装）；[] = 当前机型不支持放电。
    public static let capabilityDischarge = "discharge"
    /// WP2' 自动放电能力字面量（与 discharge 同批上报——自动放电是策略能力非硬件
    /// 能力；App 按三态显隐开关：nil = 需升级 / 缺席 = 不支持 / 含 = 可用）。
    public static let capabilityAutoDischarge = "autoDischarge"
    /// WP3 校准能力字面量（与 discharge 同批上报——校准为纯软件能力，强度依赖
    /// 放电能力探测（tahoe ∧ CHIE 在位）；App 按能力显隐校准区，XPC 侧纵深防御）。
    public static let capabilityCalibration = "calibration"
    /// v0.19.20 编排能力字面量（0.19.10 WP-A 的 27 终态上报从 [] 扩展而来——
    /// noBackendTerminalDisposition 置值）：编排是 27 唯一执法路径；App 按能力
    /// 显隐通用页编排节 + fullOnce 按钮连带禁用（WP-5）。
    public static let capabilityOrchestration = "orchestration"
    /// 0.20 M1a sub80 能力字面量（WP2 <80% 限充通道；方案 §2.1 矩阵——27 终态即报
    /// 无条件，域存在性不作上报条件（R2-P2：防干净机器域未创建的假阴性隐藏功能）；
    /// 26 及更早平台不上报）。App 消费：滑杆下放 60–100 + 实验性徽章显隐；真实
    /// 可用性由 M1b 行为验证/降级兜底。
    public static let capabilitySub80 = "sub80"

    // MARK: - 线格式键与常量

    public static let cmdKey = "cmd"
    public static let upperKey = "upper"
    public static let hysteresisKey = "hysteresis"
    /// WP2' 自动放电键（UINT64，0/1；缺席 = 保持现值——旧 daemon/CLI 天然兼容）。
    public static let autoKey = "auto"
    /// Phase 5 v1.8 MagSafe LED 模式键（UINT64，0/1/3/4 白名单；缺席仅限非
    /// setMagSafeLed 命令——值域校验由 XPCServer 臂负责，照 auto 同纪律）。
    public static let magSafeLedModeKey = "magSafeLedMode"
    public static let okKey = "ok"
    public static let statusKey = "status"
    public static let errorKey = "error"

    /// cmd 最大长度（字节；命令集为 ASCII，字节数即字符数）。
    public static let maxCommandLength = 32
    /// 客户端回包等待上限（秒）。
    public static let replyTimeoutSeconds: TimeInterval = 5

    #if canImport(XPC)
    // MARK: - 请求/回包构造与校验（服务端与客户端共用）

    /// 构造请求字典（⚠️ Swift 的 ARC 自动管理 xpc 对象引用计数——调用方不得手动
    /// xpc_retain/xpc_release，否则双重释放崩溃）。auto/fan/calSched/thermal/schedule
    /// 缺省 = 不发键（daemon 缺席保持语义，照 auto 键先例；Wire 内 nil 字段亦不发键）。
    /// Phase 5 v1.6：schedule 为**首个字符串键**（xpc_dictionary_set_string，UD-6
    /// ——数组配置不可 UINT64 表达）。
    public static func makeMessage(
        cmd: String, upper: UInt64, hysteresis: UInt64, auto: UInt64? = nil,
        fan: FanWire? = nil, calSched: CalibrationScheduleWire? = nil,
        thermal: ThermalWire? = nil, schedule: ChargeScheduleWire? = nil,
        magSafeLedMode: UInt64? = nil, orchestrationEnabled: UInt64? = nil,
        orchestrationReport: OrchestrationReportWire? = nil,
        chHysteresisEnabled: UInt64? = nil
    ) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, cmdKey, cmd)
        xpc_dictionary_set_uint64(message, upperKey, upper)
        xpc_dictionary_set_uint64(message, hysteresisKey, hysteresis)
        if let auto {
            xpc_dictionary_set_uint64(message, autoKey, auto)
        }
        if let magSafeLedMode {
            xpc_dictionary_set_uint64(message, magSafeLedModeKey, magSafeLedMode)
        }
        if let fan {
            if let enabled = fan.enabled { xpc_dictionary_set_uint64(message, FanWireKeys.enabled, enabled) }
            if let strategy = fan.strategy { xpc_dictionary_set_uint64(message, FanWireKeys.strategy, strategy) }
            if let threshold = fan.threshold { xpc_dictionary_set_uint64(message, FanWireKeys.threshold, threshold) }
            if let hysteresis = fan.hysteresis { xpc_dictionary_set_uint64(message, FanWireKeys.hysteresis, hysteresis) }
            if let speed = fan.speed { xpc_dictionary_set_uint64(message, FanWireKeys.speed, speed) }
            if let stage2 = fan.stage2 { xpc_dictionary_set_uint64(message, FanWireKeys.stage2, stage2) }
            if let stage2Rise = fan.stage2Rise { xpc_dictionary_set_uint64(message, FanWireKeys.stage2Rise, stage2Rise) }
            // v1.11 T3 温度源三键（全 UINT64——fanSource 数值映射 0=battery/1=cpuSkin）。
            if let source = fan.source { xpc_dictionary_set_uint64(message, FanWireKeys.source, source) }
            if let cpuThreshold = fan.cpuThreshold { xpc_dictionary_set_uint64(message, FanWireKeys.cpuThreshold, cpuThreshold) }
            if let cpuHysteresis = fan.cpuHysteresis { xpc_dictionary_set_uint64(message, FanWireKeys.cpuHysteresis, cpuHysteresis) }
        }
        if let calSched {
            if let enabled = calSched.enabled { xpc_dictionary_set_uint64(message, CalibrationScheduleWireKeys.enabled, enabled) }
            if let intervalDays = calSched.intervalDays { xpc_dictionary_set_uint64(message, CalibrationScheduleWireKeys.intervalDays, intervalDays) }
            if let startHour = calSched.startHour { xpc_dictionary_set_uint64(message, CalibrationScheduleWireKeys.startHour, startHour) }
        }
        if let thermal {
            if let pause = thermal.pause { xpc_dictionary_set_uint64(message, ThermalWireKeys.pause, pause) }
            if let hysteresis = thermal.hysteresis { xpc_dictionary_set_uint64(message, ThermalWireKeys.hysteresis, hysteresis) }
        }
        if let json = schedule?.scheduleJson {
            xpc_dictionary_set_string(message, ChargeScheduleWireKeys.scheduleJson, json)
        }
        // v0.19.20 编排键组：开关单 UINT64 键 + 回报三键（detail 仅非 nil 时发——
        // ok=true 缺席即「无详情」语义）。
        if let orchestrationEnabled {
            xpc_dictionary_set_uint64(message, OrchestrationWireKeys.enabled, orchestrationEnabled)
        }
        if let report = orchestrationReport {
            if let token = report.token {
                xpc_dictionary_set_string(message, OrchestrationWireKeys.token, token)
            }
            if let ok = report.ok {
                xpc_dictionary_set_uint64(message, OrchestrationWireKeys.ok, ok)
            }
            if let detail = report.detail {
                xpc_dictionary_set_string(message, OrchestrationWireKeys.detail, detail)
            }
        }
        // 0.21.0 §2.4 迟滞开关单键（UINT64 0/1——照编排开关同键型同纪律）。
        if let chHysteresisEnabled {
            xpc_dictionary_set_uint64(message, CHHysteresisWireKeys.enabled, chHysteresisEnabled)
        }
        return message
    }

    /// 请求结构校验（评审 A-4/P0）：xpc_get_type 白名单——cmd 必须为 STRING 且 ≤32 字节、
    /// upper/hysteresis 若出现必须为 UINT64；缺 cmd / 类型混淆 / 超长 → nil
    /// （调用方回错误包，不崩溃）。upper/hysteresis 缺席按 0 处理；auto 缺席 → nil
    /// （值域校验（0/1）由 XPCServer 臂负责——与 upper/hysteresis 同纪律）。
    /// Phase 5 v1.1：setFan 七键（fanEnabled/fanStrategy/fanThreshold/fanHysteresis/
    /// fanSpeed/fanStage2/fanStage2Rise）+ v1.11 T3 三键（fanSource/fanCpuThreshold/
    /// fanCpuHysteresis）全 UINT64 白名单——任一出现但类型混淆
    /// → 整包拒绝；全部缺席 → fan == nil（非 setFan 命令天然兼容）。值域校验
    /// （validFan*）由 XPCServer 臂负责（与 auto 同纪律）。
    /// Phase 5 v1.4：setCalibrationSchedule 三键（calSchedEnabled/calSchedIntervalDays/
    /// calSchedStartHour）同款 UINT64 白名单 + anyKeyPresent 判定；值域校验（valid*）
    /// 由 XPCServer 臂负责。
    /// Phase 5 v1.5：setThermal 两键（thermPauseCentiC/thermHysteresisCentiC）同款
    /// UINT64 白名单 + anyThermalKeyPresent 判定；值域校验（validTherm*）由
    /// XPCServer 臂负责。
    /// Phase 5 v1.6：setChargeSchedule 单字符串键（scheduleJson）白名单——出现即
    /// 必须 STRING（UINT64/BOOL 混入 → 整包拒绝）∧ 字节长度 ≤8192（R-3 输入面
    /// 收口，与 XPCServer 臂/setChargeScheduleConfig 同源）；
    /// anyScheduleKeyPresent 判定；JSON/validated 两级校验由 core.setChargeScheduleConfig
    /// 负责（三级 = 长度/JSON/validated，无第四级 UTF-8——R1 P2-1）。
    public static func validateRequest(
        _ msg: xpc_object_t
    ) -> (cmd: String, upper: UInt64, hysteresis: UInt64, auto: UInt64?, fan: FanWire?,
          calSched: CalibrationScheduleWire?, thermal: ThermalWire?,
          schedule: ChargeScheduleWire?, magSafeLedMode: UInt64?,
          orchestrationEnabled: UInt64?, orchestrationReport: OrchestrationReportWire?,
          chHysteresisEnabled: UInt64?)? {
        // Swift 导入下 xpc_object_t 为非可选；nil 不可能传入，仅需类型判定。
        guard xpc_get_type(msg) == XPC_TYPE_DICTIONARY else { return nil }

        guard let cmdValue = xpc_dictionary_get_value(msg, cmdKey) else { return nil }
        guard xpc_get_type(cmdValue) == XPC_TYPE_STRING else { return nil }
        let cmdLength = xpc_string_get_length(cmdValue)
        guard cmdLength > 0, cmdLength <= maxCommandLength else { return nil }
        guard let cmdPointer = xpc_dictionary_get_string(msg, cmdKey) else { return nil }

        var upper: UInt64 = 0
        var hysteresis: UInt64 = 0
        if let value = xpc_dictionary_get_value(msg, upperKey) {
            guard xpc_get_type(value) == XPC_TYPE_UINT64 else { return nil }
            upper = xpc_dictionary_get_uint64(msg, upperKey)
        }
        if let value = xpc_dictionary_get_value(msg, hysteresisKey) {
            guard xpc_get_type(value) == XPC_TYPE_UINT64 else { return nil }
            hysteresis = xpc_dictionary_get_uint64(msg, hysteresisKey)
        }
        var auto: UInt64?
        if let value = xpc_dictionary_get_value(msg, autoKey) {
            guard xpc_get_type(value) == XPC_TYPE_UINT64 else { return nil }
            auto = xpc_dictionary_get_uint64(msg, autoKey)
        }
        // 风扇十键（v1.11 T3 +3：fanSource/fanCpuThreshold/fanCpuHysteresis）：出现
        // 即必须 UINT64（STRING/BOOL 混入 → 整包拒绝）；缺席保持 nil。
        var fan = FanWire()
        for (key, kind) in [
            (FanWireKeys.enabled, \FanWire.enabled),
            (FanWireKeys.strategy, \FanWire.strategy),
            (FanWireKeys.threshold, \FanWire.threshold),
            (FanWireKeys.hysteresis, \FanWire.hysteresis),
            (FanWireKeys.speed, \FanWire.speed),
            (FanWireKeys.stage2, \FanWire.stage2),
            (FanWireKeys.stage2Rise, \FanWire.stage2Rise),
            (FanWireKeys.source, \FanWire.source),
            (FanWireKeys.cpuThreshold, \FanWire.cpuThreshold),
            (FanWireKeys.cpuHysteresis, \FanWire.cpuHysteresis),
        ] {
            if let value = xpc_dictionary_get_value(msg, key) {
                guard xpc_get_type(value) == XPC_TYPE_UINT64 else { return nil }
                fan[keyPath: kind] = xpc_dictionary_get_uint64(msg, key)
            }
        }
        let anyFanKeyPresent = fan.enabled != nil || fan.strategy != nil || fan.threshold != nil
            || fan.hysteresis != nil || fan.speed != nil || fan.stage2 != nil || fan.stage2Rise != nil
            || fan.source != nil || fan.cpuThreshold != nil || fan.cpuHysteresis != nil
        // 校准调度三键：出现即必须 UINT64（类型混淆 → 整包拒绝）；缺席保持 nil。
        var calSched = CalibrationScheduleWire()
        for (key, kind) in [
            (CalibrationScheduleWireKeys.enabled, \CalibrationScheduleWire.enabled),
            (CalibrationScheduleWireKeys.intervalDays, \CalibrationScheduleWire.intervalDays),
            (CalibrationScheduleWireKeys.startHour, \CalibrationScheduleWire.startHour),
        ] {
            if let value = xpc_dictionary_get_value(msg, key) {
                guard xpc_get_type(value) == XPC_TYPE_UINT64 else { return nil }
                calSched[keyPath: kind] = xpc_dictionary_get_uint64(msg, key)
            }
        }
        let anyCalSchedKeyPresent = calSched.enabled != nil
            || calSched.intervalDays != nil || calSched.startHour != nil
        // 热暂停两键：出现即必须 UINT64（类型混淆 → 整包拒绝）；缺席保持 nil。
        var thermal = ThermalWire()
        for (key, kind) in [
            (ThermalWireKeys.pause, \ThermalWire.pause),
            (ThermalWireKeys.hysteresis, \ThermalWire.hysteresis),
        ] {
            if let value = xpc_dictionary_get_value(msg, key) {
                guard xpc_get_type(value) == XPC_TYPE_UINT64 else { return nil }
                thermal[keyPath: kind] = xpc_dictionary_get_uint64(msg, key)
            }
        }
        let anyThermalKeyPresent = thermal.pause != nil || thermal.hysteresis != nil
        // 充电日程字符串键：出现即必须 STRING ∧ ≤8192 字节（类型混淆/超长 → 整包
        // 拒绝）；缺席保持 nil（既有命令天然兼容）。
        var scheduleJson: String?
        if let value = xpc_dictionary_get_value(msg, ChargeScheduleWireKeys.scheduleJson) {
            guard xpc_get_type(value) == XPC_TYPE_STRING else { return nil }
            guard xpc_string_get_length(value) <= ChargeScheduleWireKeys.maxJsonLength else { return nil }
            guard let pointer = xpc_dictionary_get_string(msg, ChargeScheduleWireKeys.scheduleJson) else { return nil }
            scheduleJson = String(cString: pointer)
        }
        let anyScheduleKeyPresent = scheduleJson != nil
        // Phase 5 v1.8 MagSafe LED 模式键：出现即必须 UINT64（类型混淆 → 整包拒绝）；
        // 值域校验（0/1/3/4 白名单）由 XPCServer 臂负责（照 auto 同纪律）。
        var magSafeLedMode: UInt64?
        if let value = xpc_dictionary_get_value(msg, magSafeLedModeKey) {
            guard xpc_get_type(value) == XPC_TYPE_UINT64 else { return nil }
            magSafeLedMode = xpc_dictionary_get_uint64(msg, magSafeLedModeKey)
        }
        // v0.19.20 编排开关单键：出现即必须 UINT64（值域 0/1 白名单由 XPCServer
        // 臂复核——照 auto 同纪律）。
        var orchestrationEnabled: UInt64?
        if let value = xpc_dictionary_get_value(msg, OrchestrationWireKeys.enabled) {
            guard xpc_get_type(value) == XPC_TYPE_UINT64 else { return nil }
            orchestrationEnabled = xpc_dictionary_get_uint64(msg, OrchestrationWireKeys.enabled)
        }
        // v0.19.20 回报三键：token/detail 出现即必须 STRING 且 ≤64/≤8192 字节、
        // ok 出现即必须 UINT64（类型混淆/超长 → 整包拒绝，照 scheduleJson 同纪律）；
        // 全部缺席 → nil（既有命令天然兼容）。
        var report = OrchestrationReportWire()
        if let value = xpc_dictionary_get_value(msg, OrchestrationWireKeys.token) {
            guard xpc_get_type(value) == XPC_TYPE_STRING else { return nil }
            guard xpc_string_get_length(value) <= OrchestrationWireKeys.maxTokenLength else { return nil }
            guard let pointer = xpc_dictionary_get_string(msg, OrchestrationWireKeys.token) else { return nil }
            report.token = String(cString: pointer)
        }
        if let value = xpc_dictionary_get_value(msg, OrchestrationWireKeys.ok) {
            guard xpc_get_type(value) == XPC_TYPE_UINT64 else { return nil }
            report.ok = xpc_dictionary_get_uint64(msg, OrchestrationWireKeys.ok)
        }
        if let value = xpc_dictionary_get_value(msg, OrchestrationWireKeys.detail) {
            guard xpc_get_type(value) == XPC_TYPE_STRING else { return nil }
            guard xpc_string_get_length(value) <= OrchestrationWireKeys.maxDetailLength else { return nil }
            guard let pointer = xpc_dictionary_get_string(msg, OrchestrationWireKeys.detail) else { return nil }
            report.detail = String(cString: pointer)
        }
        let anyOrchestrationKeyPresent = report.token != nil || report.ok != nil || report.detail != nil
        // 0.21.0 §2.4 迟滞开关键：出现即必须 UINT64（类型混淆 → 整包拒绝）；值域
        // 0/1 白名单由 XPCServer 臂复核（照编排开关同纪律）。
        var chHysteresisEnabled: UInt64?
        if let value = xpc_dictionary_get_value(msg, CHHysteresisWireKeys.enabled) {
            guard xpc_get_type(value) == XPC_TYPE_UINT64 else { return nil }
            chHysteresisEnabled = xpc_dictionary_get_uint64(msg, CHHysteresisWireKeys.enabled)
        }
        return (cmd: String(cString: cmdPointer), upper: upper, hysteresis: hysteresis,
                auto: auto, fan: anyFanKeyPresent ? fan : nil,
                calSched: anyCalSchedKeyPresent ? calSched : nil,
                thermal: anyThermalKeyPresent ? thermal : nil,
                schedule: anyScheduleKeyPresent ? ChargeScheduleWire(scheduleJson: scheduleJson) : nil,
                magSafeLedMode: magSafeLedMode,
                orchestrationEnabled: orchestrationEnabled,
                orchestrationReport: anyOrchestrationKeyPresent ? report : nil,
                chHysteresisEnabled: chHysteresisEnabled)
    }

    /// 成功回包：{"ok": true, "status": <statusJSON>}（ARC 管理生命周期，勿手动 release）。
    public static func okReply(_ statusJSON: String) -> xpc_object_t {
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(reply, okKey, true)
        xpc_dictionary_set_string(reply, statusKey, statusJSON)
        return reply
    }

    /// 错误回包：{"ok": false, "error": <message>}（ARC 管理生命周期，勿手动 release）。
    public static func errorReply(_ message: String) -> xpc_object_t {
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(reply, okKey, false)
        xpc_dictionary_set_string(reply, errorKey, message)
        return reply
    }

    /// 状态 → JSON 串（encode 失败（不可达）→ nil）。
    public static func encodeStatus(_ status: DaemonStatus) -> String? {
        guard let data = try? JSONEncoder().encode(status) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// JSON 串 → 状态（解码失败原样上抛；仅 daemon/CLI 配对使用，失败按 daemonError 呈现）。
    public static func decodeStatus(_ json: String) throws -> DaemonStatus {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(DaemonStatus.self, from: data)
    }
    #endif
}

