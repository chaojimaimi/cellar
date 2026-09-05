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
        self.timestamp = timestamp
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
    public static let daemonVersion = "0.12.0-alpha"
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

    // MARK: - 线格式键与常量

    public static let cmdKey = "cmd"
    public static let upperKey = "upper"
    public static let hysteresisKey = "hysteresis"
    /// WP2' 自动放电键（UINT64，0/1；缺席 = 保持现值——旧 daemon/CLI 天然兼容）。
    public static let autoKey = "auto"
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
        thermal: ThermalWire? = nil, schedule: ChargeScheduleWire? = nil
    ) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, cmdKey, cmd)
        xpc_dictionary_set_uint64(message, upperKey, upper)
        xpc_dictionary_set_uint64(message, hysteresisKey, hysteresis)
        if let auto {
            xpc_dictionary_set_uint64(message, autoKey, auto)
        }
        if let fan {
            if let enabled = fan.enabled { xpc_dictionary_set_uint64(message, FanWireKeys.enabled, enabled) }
            if let strategy = fan.strategy { xpc_dictionary_set_uint64(message, FanWireKeys.strategy, strategy) }
            if let threshold = fan.threshold { xpc_dictionary_set_uint64(message, FanWireKeys.threshold, threshold) }
            if let hysteresis = fan.hysteresis { xpc_dictionary_set_uint64(message, FanWireKeys.hysteresis, hysteresis) }
            if let speed = fan.speed { xpc_dictionary_set_uint64(message, FanWireKeys.speed, speed) }
            if let stage2 = fan.stage2 { xpc_dictionary_set_uint64(message, FanWireKeys.stage2, stage2) }
            if let stage2Rise = fan.stage2Rise { xpc_dictionary_set_uint64(message, FanWireKeys.stage2Rise, stage2Rise) }
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
        return message
    }

    /// 请求结构校验（评审 A-4/P0）：xpc_get_type 白名单——cmd 必须为 STRING 且 ≤32 字节、
    /// upper/hysteresis 若出现必须为 UINT64；缺 cmd / 类型混淆 / 超长 → nil
    /// （调用方回错误包，不崩溃）。upper/hysteresis 缺席按 0 处理；auto 缺席 → nil
    /// （值域校验（0/1）由 XPCServer 臂负责——与 upper/hysteresis 同纪律）。
    /// Phase 5 v1.1：setFan 七键（fanEnabled/fanStrategy/fanThreshold/fanHysteresis/
    /// fanSpeed/fanStage2/fanStage2Rise）全 UINT64 白名单——任一出现但类型混淆
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
          schedule: ChargeScheduleWire?)? {
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
        // 风扇七键：出现即必须 UINT64（STRING/BOOL 混入 → 整包拒绝）；缺席保持 nil。
        var fan = FanWire()
        for (key, kind) in [
            (FanWireKeys.enabled, \FanWire.enabled),
            (FanWireKeys.strategy, \FanWire.strategy),
            (FanWireKeys.threshold, \FanWire.threshold),
            (FanWireKeys.hysteresis, \FanWire.hysteresis),
            (FanWireKeys.speed, \FanWire.speed),
            (FanWireKeys.stage2, \FanWire.stage2),
            (FanWireKeys.stage2Rise, \FanWire.stage2Rise),
        ] {
            if let value = xpc_dictionary_get_value(msg, key) {
                guard xpc_get_type(value) == XPC_TYPE_UINT64 else { return nil }
                fan[keyPath: kind] = xpc_dictionary_get_uint64(msg, key)
            }
        }
        let anyFanKeyPresent = fan.enabled != nil || fan.strategy != nil || fan.threshold != nil
            || fan.hysteresis != nil || fan.speed != nil || fan.stage2 != nil || fan.stage2Rise != nil
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
        return (cmd: String(cString: cmdPointer), upper: upper, hysteresis: hysteresis,
                auto: auto, fan: anyFanKeyPresent ? fan : nil,
                calSched: anyCalSchedKeyPresent ? calSched : nil,
                thermal: anyThermalKeyPresent ? thermal : nil,
                schedule: anyScheduleKeyPresent ? ChargeScheduleWire(scheduleJson: scheduleJson) : nil)
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

#if canImport(XPC)
/// CLI 侧客户端：raw XPC + 异步回包 + 信号量 5 秒等待（评审 E-4——
/// `send_message_with_reply_sync` 无超时参数，超时必须自行实现）。
public struct DaemonXPCClient: Sendable {
    /// 保持 throws 契约（规格 §2）。⚠️ Swift 导入下 `xpc_connection_create_mach_service`
    /// 返回非可选句柄——连接"建立失败"不可观测，实际失败形态（daemon 未运行）在
    /// exchange 中经连接无效事件暴露为 .connectionFailed。
    public init() throws {}

    public func getStatus() throws -> DaemonStatus {
        try exchange(cmd: "getStatus")
    }

    /// ⚠️ 60 地板双重复核的一侧：CLI 侧已用 LimitPolicy 构造校验；daemon 侧 setLimits 再核验一次。
    /// 负数经 clamping 收敛为 0（不会是合法策略，daemon 侧报地板错误；防 UInt64 转换崩溃）。
    /// autoDischarge：nil = 不发键（daemon 缺席保持——非开关调用点一律传 nil，
    /// 防 60s 轮询窗口内用旧值覆写 CLI 刚改的限值）。
    public func setLimits(
        upperLimit: Int, hysteresis: Int, autoDischarge: Bool? = nil
    ) throws -> DaemonStatus {
        try exchange(
            cmd: "setLimits",
            upper: UInt64(clamping: upperLimit),
            hysteresis: UInt64(clamping: hysteresis),
            auto: autoDischarge.map { $0 ? 1 : 0 }
        )
    }

    public func disable() throws -> DaemonStatus {
        try exchange(cmd: "disable")
    }

    public func enable() throws -> DaemonStatus {
        try exchange(cmd: "enable")
    }

    /// 一次性动作：充满一次（WP2）。前置（外接 && mode=active）不满足 → daemonError
    /// 原文；动作已在轨 → 幂等回当前状态。
    public func fullOnce() throws -> DaemonStatus {
        try exchange(cmd: "fullOnce")
    }

    /// 取消当前一次性动作（无动作时幂等成功，回当前状态）。
    public func cancelAction() throws -> DaemonStatus {
        try exchange(cmd: "cancelAction")
    }

    /// WP2'：放电到上限（无参数——目标 = daemon 当前策略上限启动时快照）。
    /// 前置（外接 && mode=active && percent > 目标 && 能力在位）不满足 → daemonError
    /// 原文；动作已在轨 → 幂等回当前状态。
    public func dischargeToLimit() throws -> DaemonStatus {
        try exchange(cmd: "dischargeToLimit")
    }

    /// WP3：开始校准（手动触发四相状态机；无参数——相位序列由 daemon 执行）。
    /// 前置拒绝（mode/外接/能力）→ daemonError 原文；校准已在轨 → 幂等回当前状态；
    /// 其他动作在轨 → actionOccupied 拒绝原文。
    public func startCalibration() throws -> DaemonStatus {
        try exchange(cmd: "startCalibration")
    }

    /// WP3：取消校准（独立命令臂；幂等——无动作亦成功回当前状态）。
    public func cancelCalibration() throws -> DaemonStatus {
        try exchange(cmd: "cancelCalibration")
    }

    /// Phase 5 v1.1：设置风扇策略（可选字段缺席 = daemon 保持现值；minRaise →
    /// daemonError 原文「该策略在当前版本暂未开放」）。**不改 mode**（与
    /// setLimits 的「更新即切 active」语义正交）；boost 期立即按新配置重算重写。
    public func setFan(_ fan: FanWire) throws -> DaemonStatus {
        try exchange(cmd: FanWireKeys.command, upper: 0, hysteresis: 0, auto: nil, fan: fan)
    }

    /// Phase 5 v1.4：设置校准调度（可选字段缺席 = daemon 保持现值；**不改 mode**）。
    /// 旧 daemon → 「未知命令」daemonError（App detectStaleBeforeReject 升级提示
    /// 既有闭环，UD-7）。
    public func setCalibrationSchedule(_ schedule: CalibrationScheduleWire) throws -> DaemonStatus {
        try exchange(
            cmd: CalibrationScheduleWireKeys.command, upper: 0, hysteresis: 0,
            auto: nil, fan: nil, calSched: schedule
        )
    }

    /// Phase 5 v1.5：设置充电热暂停策略（可选字段缺席 = daemon 保持现值；**不改
    /// mode**；值域 35-45°C / 滞回 1-8°C，保护不可被配置关闭——UD-2 值域钳制）。
    /// 旧 daemon → 「未知命令」daemonError（detectStaleBeforeReject 升级提示既有
    /// 闭环，R-4）。
    public func setThermal(_ thermal: ThermalWire) throws -> DaemonStatus {
        try exchange(
            cmd: ThermalWireKeys.command, upper: 0, hysteresis: 0,
            auto: nil, fan: nil, calSched: nil, thermal: thermal
        )
    }

    /// Phase 5 v1.6：设置充电日程（配置 JSON 字符串键——**协议首个字符串键**，UD-6；
    /// daemon 侧三级校验长度/JSON/validated，任一失败 → daemonError 原文；**不改
    /// mode、不取消在轨**，成功即 tick——命中窗口条目 ≤1 tick 生效）。旧 daemon →
    /// 「未知命令」daemonError（App detectStaleBeforeReject 升级提示既有闭环，R-7）。
    public func setChargeSchedule(_ json: String) throws -> DaemonStatus {
        try exchange(
            cmd: ChargeScheduleWireKeys.command, upper: 0, hysteresis: 0,
            auto: nil, fan: nil, calSched: nil, thermal: nil,
            schedule: ChargeScheduleWire(scheduleJson: json)
        )
    }

    // MARK: - 内部

    /// 一次请求-回包交换：发消息 → 等回包（≤5s）→ 解析。
    /// - 连接无效事件（daemon 未运行/未安装）→ .connectionFailed
    /// - 超时无回包 → .timeout
    /// - ok=false → .daemonError(原文)
    private func exchange(
        cmd: String, upper: UInt64 = 0, hysteresis: UInt64 = 0, auto: UInt64? = nil,
        fan: FanWire? = nil, calSched: CalibrationScheduleWire? = nil,
        thermal: ThermalWire? = nil, schedule: ChargeScheduleWire? = nil
    ) throws -> DaemonStatus {
        // Swift 导入下连接句柄非可选（失败经事件暴露，见 init 注释）。
        // ⚠️ xpc 对象引用计数由 ARC 自动管理：不得手动 xpc_release（双重释放崩溃）。
        let connection = xpc_connection_create_mach_service(DaemonXPC.machServiceName, nil, 0)
        let message = DaemonXPC.makeMessage(
            cmd: cmd, upper: upper, hysteresis: hysteresis, auto: auto,
            fan: fan, calSched: calSched, thermal: thermal, schedule: schedule
        )
        let waiter = ReplyWaiter()

        xpc_connection_set_event_handler(connection) { object in
            waiter.receive(object)
        }
        xpc_connection_set_target_queue(connection, DispatchQueue.global(qos: .userInitiated))
        xpc_connection_resume(connection)
        xpc_connection_send_message(connection, message)

        // 异步回包 + 信号量 5 秒超时（reply_sync 无超时参数，评审 E-4）。
        let outcome = waiter.wait(timeout: .now() + DaemonXPC.replyTimeoutSeconds)

        // 收包/超时/错误事件齐备后关闭连接（连接与消息对象随作用域由 ARC 回收）。
        xpc_connection_cancel(connection)

        switch outcome {
        case .timedOut:
            throw DaemonClientError.timeout
        case .invalidPeer:
            throw DaemonClientError.connectionFailed
        case .reply(let object):
            return try Self.parse(reply: object)
        }
    }

    /// 解析回包字典（对象随参数作用域由 ARC 回收，勿手动 release）。
    private static func parse(reply object: xpc_object_t) throws -> DaemonStatus {
        guard xpc_get_type(object) == XPC_TYPE_DICTIONARY else {
            throw DaemonClientError.connectionFailed
        }
        let ok = xpc_dictionary_get_bool(object, DaemonXPC.okKey)
        if ok {
            guard let json = xpc_dictionary_get_string(object, DaemonXPC.statusKey) else {
                throw DaemonClientError.daemonError("daemon 回包缺少状态载荷")
            }
            return try DaemonXPC.decodeStatus(String(cString: json))
        }
        if let error = xpc_dictionary_get_string(object, DaemonXPC.errorKey) {
            throw DaemonClientError.daemonError(String(cString: error))
        }
        throw DaemonClientError.daemonError("daemon 返回未知错误")
    }
}

/// 回包等待盒：事件处理器（全局队列）写入、等待方（调用线程）读取。
///
/// ⚠️ 生命周期：handler 参数对象为借用（+0），跨回调持有依赖 Swift ARC——
/// 存入 `state` 时编译器自动 retain，读取/离开作用域时自动 release；
/// 本类型不做任何手动 xpc_retain/xpc_release。
private final class ReplyWaiter: @unchecked Sendable {
    private enum State {
        case pending
        case received(xpc_object_t)
        case invalidPeer
    }

    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var state: State = .pending

    /// 事件回调（可被多次调用；首个有效结果生效，后续事件被 ARC 回收）。
    func receive(_ object: xpc_object_t) {
        lock.lock()
        if case .pending = state {
            if xpc_get_type(object) == XPC_TYPE_ERROR {
                // 连接无效（daemon 未运行等）：错误常量对象不存储（immortal）。
                state = .invalidPeer
            } else {
                state = .received(object)   // 存储时 ARC 自动 retain（跨回调安全）
            }
        }
        lock.unlock()
        semaphore.signal()
    }

    /// 等待回包（超时返回 timedOut）。返回 .reply 时对象由 .received 持有，
    /// 调用方使用期间保持存活（ARC），离开作用域自动回收。
    func wait(timeout: DispatchTime) -> Outcome {
        _ = semaphore.wait(timeout: timeout)
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .pending:
            return .timedOut
        case .received(let object):
            return .reply(object)
        case .invalidPeer:
            return .invalidPeer
        }
    }

    enum Outcome {
        case timedOut
        case invalidPeer
        case reply(xpc_object_t)
    }
}
#endif