import Foundation

// MARK: - Phase 5 v1.4 校准调度（自动周期校准）—— CellarCore 纯函数/纯值层（方案 §2.1）

/// 校准调度策略（daemon 持久化在 policy.json 的 `DaemonPolicy.calibrationSchedule`
/// 可选字段；UD-3 配置/状态分离——运行时锚点与终态记录进 calibration-state.json，
/// 不混入 policy.json：其「非法整包 nil」校验语义不连累状态数据）。
public struct CalibrationSchedulePolicy: Codable, Equatable, Sendable {
    /// opt-in 开关（默认关，UD-2——校准会临时接管充放电，照 v1.1 风扇 opt-in 原则：
    /// 影响充电行为的能力默认关闭，用户显式开启）。
    public var enabled: Bool
    /// 校准周期（天；1...180，UI 档位 7/14/30/60/90）。
    public var intervalDays: Int
    /// 窗口起点（整点；0...23——窗口 [startHour, startHour+4)，跨午夜安全见
    /// `isWithinWindow`）。
    public var startHour: Int

    public init(enabled: Bool, intervalDays: Int, startHour: Int) {
        self.enabled = enabled
        self.intervalDays = intervalDays
        self.startHour = startHour
    }

    /// 默认策略（R2 P3 钉死：enabled false / 30 天 / 01:00——月度校准常规节奏；
    /// App Picker 预选 30、窗口起点预选 01:00）。buildStatusLocked 对未配置用户
    /// **恒填本值**（照 fanStatusLocked `policy.fan ?? .default` 先例，UD-7——
    /// 不恒填则 opt-in 默认关状态下新装用户全被误判旧 daemon）。
    public static let `default` = CalibrationSchedulePolicy(
        enabled: false, intervalDays: 30, startHour: 1
    )

    /// 窗口长度（小时；方案 §2.1 定版 4——凌晨低负载窗口）。
    public static let windowHours = 4

    /// 值域（与 XPCServer 臂 valid* 同源——同一区间常量，照 FanPolicy 先例：
    /// XPCServer 值域校验与 validated 同源，CellarCoreCheck 同源测试）。
    public static let intervalDaysRange = 1...180
    public static let startHourRange = 0...23

    /// 值域校验：任何字段越界 → nil。⚠️ **仅丢字段分层语义（R1 P1-2 / R2 P3）**：
    /// PolicyStore.load 对本字段值域非法仅丢该字段（+ Logger error），policy 其余
    /// 字段（mode/限值/风扇）不受连累——与 fan 整包 nil 分层不同，理由：调度为
    /// 非关键 opt-in 配置；类型错乱（整包 JSONDecoder 解码失败）→ 整包 nil 落默认
    /// 策略（合成 Codable 行为，与 fan 同形）。
    public static func validated(
        enabled: Bool, intervalDays: Int, startHour: Int
    ) -> CalibrationSchedulePolicy? {
        guard intervalDaysRange.contains(intervalDays) else { return nil }
        guard startHourRange.contains(startHour) else { return nil }
        return CalibrationSchedulePolicy(enabled: enabled, intervalDays: intervalDays, startHour: startHour)
    }

    /// 窗口判定（**模 24**——startHour ≥ 20 时窗口 [startHour, startHour+4) 跨
    /// 午夜安全，方案 §1.9）：(hour − startHour) mod 24 ∈ [0, windowHours)。
    /// Swift `%` 对负数返回负值，先 +24 再取模修正。
    public func isWithinWindow(hour: Int) -> Bool {
        let offset = ((hour - startHour) % 24 + 24) % 24
        return offset < Self.windowHours
    }
}

/// 校准终态归一词（state 文件 outcome 字段与 App 展示词之间的 wire 契约；
/// rawValue 永不本地化——App 侧经 l10n key 映射展示词，方案 §3.4）。
public enum CalibrationOutcome: String, Equatable, Sendable, CaseIterable {
    case done
    case cancel
    case timeout
    case safety
    /// 崩溃恢复取消（字面量 calibration:cancel(crash-recovery) 的归一词）。
    case crashRecovery = "crash-recovery"
}

/// 锁存字面量 → 校准终态归一词（UD-5 第②点空闲臂观察的判定纯函数）：锁存字面量
/// ∈ 五终态族**全等匹配**（非前缀匹配——`calibration:chargeFull/hold/discharge`
/// 相位字面量同前缀但必须 → nil，R1 P2）；非校准/未知字面量 → nil。
public func calibrationOutcomeLiteral(_ latched: String) -> CalibrationOutcome? {
    switch latched {
    case CalibrationLiteral.done(): return .done
    case CalibrationLiteral.cancel(): return .cancel
    case CalibrationLiteral.timeout(): return .timeout
    case CalibrationLiteral.safety(): return .safety
    case CalibrationLiteral.cancelCrashRecovery(): return .crashRecovery
    default: return nil
    }
}

/// 自动校准就绪判定（方案 §2.1；**纯时间判定**——外接/mode/在轨前置不在本函数内，
/// 由 startCalibrationLocked 共用核心把守，UD-6；调度臂对拒绝的处置 = 静默顺延）：
/// `enabled` ∧ 窗口内 ∧ (锚点 nil ∨ max(0, now − lastStartedAt) ≥ intervalDays 天)。
/// **负差值 clamp 0**（R1 P2：时钟回拨/NTP 校正视为刚校准过，不就绪；
/// NextEstimate 对应返回 nil 上屏「—」）。
public func calibrationAutoStartReady(
    now: Date,
    lastStartedAt: Date?,
    schedule: CalibrationSchedulePolicy
) -> Bool {
    guard schedule.enabled else { return false }
    let hour = Calendar.current.component(.hour, from: now)
    guard schedule.isWithinWindow(hour: hour) else { return false }
    // 首次启用调度：nil 锚点视为就绪（UD-4——用户开启即明确意愿，首个到期窗口即跑）。
    guard let lastStartedAt else { return true }
    let elapsed = max(0, now.timeIntervalSince(lastStartedAt))
    return elapsed >= Double(schedule.intervalDays) * 86400
}

/// 下次自动校准预估（方案 §2.1；App 消费——nil 上屏「—」）：禁用 / 负差值
/// （时钟回拨，与就绪判定 clamp 同一口径）→ nil；锚点 nil → 最近一个未结束的
/// 窗口起点（首个到期窗口即跑）；未到期 → intervalDays 到期时刻当日（或次日，
/// 若当日窗口已过）窗口起点；**逾期就绪（due 已过）→ 以 now 起算的下一窗口起点**
/// （P2-2：与 nil 锚点就绪分支同形，绝不上屏过去日期）。
public func nextAutoCalibrationEstimate(
    now: Date,
    schedule: CalibrationSchedulePolicy,
    lastStartedAt: Date?
) -> Date? {
    guard schedule.enabled else { return nil }
    if let last = lastStartedAt, now.timeIntervalSince(last) < 0 { return nil }
    let due = max(now, lastStartedAt.map {
        $0.addingTimeInterval(Double(schedule.intervalDays) * 86400)
    } ?? now)
    return nextWindowStart(afterOrAt: due, schedule: schedule)
}

/// 距 given 时刻最近、尚未结束的窗口起点（due ≥ 当日窗口结束 → 次日起点；
/// 窗口半开 [start, start+windowHours)）。本地时区钟面语义（窗口按用户本地时钟）。
private func nextWindowStart(afterOrAt due: Date, schedule: CalibrationSchedulePolicy) -> Date {
    let calendar = Calendar.current
    var candidate = calendar.date(
        bySettingHour: schedule.startHour, minute: 0, second: 0,
        of: calendar.startOfDay(for: due)
    ) ?? due
    let windowEnd = candidate.addingTimeInterval(
        Double(CalibrationSchedulePolicy.windowHours) * 3600
    )
    if due >= windowEnd {
        candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }
    return candidate
}

// MARK: - XPC 线格式（照 FanWire 全套先例：键全 UINT64，缺席 = 保持现值）

/// setCalibrationSchedule 请求载荷（缺席字段 = 保持现值；makeMessage 内 nil 不发键）。
public struct CalibrationScheduleWire: Equatable, Sendable {
    public var enabled: UInt64?
    public var intervalDays: UInt64?
    public var startHour: UInt64?

    public init(enabled: UInt64? = nil, intervalDays: UInt64? = nil, startHour: UInt64? = nil) {
        self.enabled = enabled
        self.intervalDays = intervalDays
        self.startHour = startHour
    }

    /// 便捷构造：从具体策略发全键（App applyCalibrationSchedule 全键下发，方案 §3.2；
    /// 缺席保持是 daemon 侧语义，App 不依赖）。
    public init(_ policy: CalibrationSchedulePolicy) {
        self.init(
            enabled: policy.enabled ? 1 : 0,
            intervalDays: UInt64(policy.intervalDays),
            startHour: UInt64(policy.startHour)
        )
    }

    /// 合并进现有策略（缺席保持）：任何字段非 nil 时应用；结果经
    /// `CalibrationSchedulePolicy.validated` 强校验（非法 → nil，不半合法）。
    public func mergedPolicy(base: CalibrationSchedulePolicy) -> CalibrationSchedulePolicy? {
        CalibrationSchedulePolicy.validated(
            enabled: enabled.map { $0 == 1 } ?? base.enabled,
            intervalDays: intervalDays.flatMap { Int(exactly: $0) } ?? base.intervalDays,
            startHour: startHour.flatMap { Int(exactly: $0) } ?? base.startHour
        )
    }
}

/// XPC setCalibrationSchedule 键名与值域校验（与 CalibrationSchedulePolicy.validated
/// 同源：同一区间常量）。键全部 UINT64——valid* 供 XPCServer 臂在 validateRequest
/// 类型白名单之后做值域校验；缺席（nil）不发键。
public enum CalibrationScheduleWireKeys {
    public static let enabled = "calSchedEnabled"
    public static let intervalDays = "calSchedIntervalDays"
    public static let startHour = "calSchedStartHour"
    /// XPC 命令字面量（XPCServer 臂 / DaemonXPCClient 共用）。
    public static let command = "setCalibrationSchedule"

    public static func validEnabled(_ raw: UInt64) -> Bool { raw <= 1 }
    public static func validIntervalDays(_ raw: UInt64) -> Bool {
        raw >= UInt64(CalibrationSchedulePolicy.intervalDaysRange.lowerBound)
            && raw <= UInt64(CalibrationSchedulePolicy.intervalDaysRange.upperBound)
    }
    public static func validStartHour(_ raw: UInt64) -> Bool {
        raw >= UInt64(CalibrationSchedulePolicy.startHourRange.lowerBound)
            && raw <= UInt64(CalibrationSchedulePolicy.startHourRange.upperBound)
    }
}
