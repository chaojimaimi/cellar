import Foundation

// MARK: - Phase 5 v1.6 充电日程（自动按星期/时段切换上限与总开关）—— CellarCore 纯函数/纯值层（方案 §2.1）

/// 充电日程配置（daemon 持久化在 policy.json 的 `DaemonPolicy.schedule` 可选字段；
/// UD-3 配置/状态分离——转移簿记（lastApplied/base 快照）进 schedule-state.json，
/// 不混入 policy.json）。
///
/// ⚠️ 仅丢字段分层语义（照 calibrationSchedule/thermal 先例，勿照 fan 整包 nil）：
/// PolicyStore.load 对本字段结构非法仅丢该字段（+ Logger error）；类型错乱
///（整包 JSONDecoder 解码失败）→ 整包 nil 落默认策略（合成 Codable 行为）。
public struct ChargeScheduleConfig: Codable, Equatable, Sendable {
    /// opt-in 开关（默认关，UD-1——影响充电行为的能力默认关闭，照风扇/校准调度
    /// opt-in 原则）。**关闭后日程臂仍会评估退出恢复**（desired=.base ∧
    /// lastApplied≠nil → restoreBase，UD-3——关总开关立即恢复快照 base）。
    public var enabled: Bool
    /// 日程条目（≤`maxEntries` 条；全部经 `ChargeScheduleEntry.validated` 强校验）。
    public var entries: [ChargeScheduleEntry]

    /// CodingKeys 显式钉死线格式键名（紧凑 JSON——App/daemon 双端同一 Codable
    /// 形态，解码一致由同源类型保证，UD-6）。
    private enum CodingKeys: String, CodingKey {
        case enabled, entries
    }

    public init(enabled: Bool = false, entries: [ChargeScheduleEntry] = []) {
        self.enabled = enabled
        self.entries = entries
    }

    /// 默认配置（R1 P3 Charge 前缀命名组件的默认形态：关 + 空表）。buildStatusLocked
    /// 对未配置用户**恒填本值 encoded**（照 calSched `.default` 先例，UD-7——
    /// 不恒填则未配置用户全被误判旧 daemon）。
    public static let `default` = ChargeScheduleConfig()

    /// 条目上限（UD-1 定版 8）。
    public static let maxEntries = 8

    /// 值域校验：条数越限 / 任一条目结构非法（含条目 id 重复——引擎语义健全性
    /// 防御，见下注）/ 任一条目过不了 `ChargeScheduleEntry.validated` → 整包 nil
    ///（绝不落半合法配置，UD-1「任一非法 → 整 nil」）。
    ///
    /// id 重复防御（超出 UD-1 字面清单的必要收口，登记理由）：A→B 直切与
    /// 「编辑保 id 本窗不重应用」都以 entry id 为去重键——重 id 条目会让
    /// transitionRequired 把 B 窗误判为已应用（A 的效果滞留 B 窗），引擎语义
    /// 不健全；UUID 约定下生产方（App 编辑器）恒唯一，此处兜底拒绝。
    public static func validated(
        enabled: Bool, entries: [ChargeScheduleEntry]
    ) -> ChargeScheduleConfig? {
        guard entries.count <= maxEntries else { return nil }
        var ids = Set<String>()
        ids.reserveCapacity(entries.count)
        var validatedEntries: [ChargeScheduleEntry] = []
        validatedEntries.reserveCapacity(entries.count)
        for entry in entries {
            guard let valid = ChargeScheduleEntry.validated(
                id: entry.id, weekdays: entry.weekdays, startMinute: entry.startMinute,
                endMinute: entry.endMinute, upperLimit: entry.upperLimit,
                chargingDisabled: entry.chargingDisabled
            ) else { return nil }
            guard ids.insert(valid.id).inserted else { return nil }
            validatedEntries.append(valid)
        }
        return ChargeScheduleConfig(enabled: enabled, entries: validatedEntries)
    }

    /// 紧凑 JSON 编码（XPC `scheduleJson` 字符串键与 `DaemonStatus.scheduleJson`
    /// 恒填共用；全值类型 encode 不可达失败 → nil）。
    public var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// JSON 串解码（daemon setChargeScheduleConfig 第二级校验的承载——与 App 端
    /// 同一 Codable 形态；失败上抛由调用方归入 malformedJSON 原文回传）。
    public static func decoded(from json: String) throws -> ChargeScheduleConfig {
        try JSONDecoder().decode(ChargeScheduleConfig.self, from: Data(json.utf8))
    }
}

/// 充电日程条目（UD-1 模型）：星期集合 + 半开分钟窗口 [startMinute, endMinute)
///（end < start = 跨午夜）+ 动作字段（限充上限 / 完全放开充电，至少一项）。
public struct ChargeScheduleEntry: Codable, Equatable, Sendable {
    /// 条目唯一标识（UUID 约定；转移簿记去重键——「编辑保 id」语义的承载）。
    public var id: String
    /// 生效星期（ISO 8601：周一=1 … 周日=7；去重升序存canonical形态）。
    public var weekdays: [Int]
    /// 窗口起点（当日分钟 0...1439）。
    public var startMinute: Int
    /// 窗口终点（当日分钟 0...1439，≠startMinute；< startMinute = 跨午夜窗口）。
    public var endMinute: Int
    /// 限充上限（60...100；与 `chargingDisabled` 并存合法——见 validated 注记）。
    public var upperLimit: Int?
    /// 完全放开充电（true = 窗口内等效 disable，系统默认充电，`upperLimit` 忽略；
    /// UD-5 产品后果明示：限充停充态下进窗会立即开始充电直至 100%）。nil = 不表达
    /// 该动作；false = 显式「不停充」（此时须有 `upperLimit` 才构成有效动作）。
    public var chargingDisabled: Bool?

    /// CodingKeys 显式钉死线格式键名（同 Config）。
    private enum CodingKeys: String, CodingKey {
        case id, weekdays, startMinute, endMinute, upperLimit, chargingDisabled
    }

    public init(
        id: String, weekdays: [Int], startMinute: Int, endMinute: Int,
        upperLimit: Int? = nil, chargingDisabled: Bool? = nil
    ) {
        self.id = id
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.upperLimit = upperLimit
        self.chargingDisabled = chargingDisabled
    }

    /// 值域（与 validated / CellarCoreCheck 场景同源——同一区间常量，照 FanPolicy 先例）。
    public static let weekdayRange = 1...7
    public static let minuteRange = 0...1439
    public static let upperLimitRange = 60...100

    /// 值域校验（UD-1：任一非法 → nil，条级不修补）：
    /// id 非空 / weekdays 非空 ∧ 全部 ∈ 1...7 ∧ 严格升序（去重升序 canonical——
    /// 重复与乱序皆拒，不做静默归一）/ start ≠ end ∧ 双双 ∈ 0...1439 /
    /// upperLimit ∈ 60...100 / 动作字段至少一项非 nil（`chargingDisabled` 与
    /// limit 并存合法——并存时 true 优先，limit 忽略；false+limit = 显式不停充
    /// 的限充语义；false+nil = 形式合法但无动作的惰性条目，臂按「仅簿记」处理）。
    public static func validated(
        id: String, weekdays: [Int], startMinute: Int, endMinute: Int,
        upperLimit: Int?, chargingDisabled: Bool?
    ) -> ChargeScheduleEntry? {
        guard !id.isEmpty else { return nil }
        guard !weekdays.isEmpty else { return nil }
        guard weekdays.allSatisfy({ weekdayRange.contains($0) }) else { return nil }
        guard zip(weekdays, weekdays.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        guard minuteRange.contains(startMinute), minuteRange.contains(endMinute),
              startMinute != endMinute else { return nil }
        if let upperLimit, !upperLimitRange.contains(upperLimit) { return nil }
        guard upperLimit != nil || chargingDisabled != nil else { return nil }
        return ChargeScheduleEntry(
            id: id, weekdays: weekdays, startMinute: startMinute, endMinute: endMinute,
            upperLimit: upperLimit, chargingDisabled: chargingDisabled
        )
    }
}

// MARK: - 转移判定纯函数（UD-2/UD-3；Calendar 注入——本地钟面语义，照校准调度先例）

/// 日程期望态（当前时刻按配置推导的应然状态）。
public enum DesiredScheduleState: Equatable, Sendable {
    /// 命中窗口条目（引擎应处于该条目的动作态）。
    case entry(ChargeScheduleEntry)
    /// 无命中窗口（引擎应处于 base——进窗前快照的手动策略）。
    case base
}

/// 转移决策（臂执行依据；nil = 无需转移——「其余 → 不动作（保手动值）」，UD-3）。
public enum ScheduleTransition: Equatable, Sendable {
    /// 应用窗口条目（进入边沿 / 错过边沿的补判 / A→B 直切）。
    case applyEntry(ChargeScheduleEntry)
    /// 恢复 base（退出边沿；值 = **state 快照的**进窗时刻 policy 值，非退出时刻
    /// 现值——UD-2 恒温器临时覆盖模型：窗口内手动修改是临时的）。
    case restoreBase(baseUpperLimit: Int?, baseMode: String?)
}

/// 当前命中窗口条目（UD-6「当前命中窗口 id」的判定源）：`enabled` ∧ 当前 ISO 星期
/// ∈ entry.weekdays ∧ 当前分钟 ∈ [start,end)（跨午夜取模）∧ 多条命中取 startMinute
/// 最大者（「最晚开始者胜」确定性规则；同 startMinute 取条目序靠前者——确定性钉死）。
public func matchingEntry(
    now: Date, calendar: Calendar, config: ChargeScheduleConfig
) -> ChargeScheduleEntry? {
    guard config.enabled else { return nil }
    let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
    // Calendar.component(.weekday) 周日=1…周六=7（gregorian 惯例）→ ISO 8601
    // 周一=1…周日=7：偏移换算 ((wd + 5) mod 7) + 1。
    let isoWeekday = (calendar.component(.weekday, from: now) + 5) % 7 + 1
    var best: ChargeScheduleEntry?
    for entry in config.entries {
        guard entry.weekdays.contains(isoWeekday) else { continue }
        let span = (entry.endMinute - entry.startMinute + 1440) % 1440
        let offset = (minute - entry.startMinute + 1440) % 1440
        guard offset < span else { continue }   // 半开 [start, end)——跨午夜取模安全
        if best == nil || entry.startMinute > best!.startMinute {
            best = entry
        }
    }
    return best
}

/// 期望态推导（`matchingEntry` 的枚举封装）。
public func desiredState(
    now: Date, calendar: Calendar, config: ChargeScheduleConfig
) -> DesiredScheduleState {
    if let entry = matchingEntry(now: now, calendar: calendar, config: config) {
        return .entry(entry)
    }
    return .base
}

/// 转移判定（UD-2/UD-3 规则钉死，逐条短路）：
/// - desired = .entry(W) ∧ state.lastAppliedEntryId ≠ W.id → `.applyEntry(W)`
///  （覆盖三种形态：首次进入 / **A→B 无缝衔接直切**——不经过 restore，base 快照
///   保持不动，R1 P1-1 / **重启补判**——lastApplied 为 nil 或他条时补上错过的进入边沿）；
/// - desired = .base ∧ state.lastAppliedEntryId ≠ nil → `.restoreBase(快照值)`
///  （退出边沿 / 重启补退出 / **关总开关立即恢复**——enabled=false 时 matchingEntry
///   恒 nil 自然落到本分支）；
/// - 其余（desired=.entry(W) ∧ lastApplied==W.id——含「编辑保 id 本窗不重应用」
///   R1 P3；desired=.base ∧ lastApplied==nil——无事可复）→ nil。
///
/// `config` 参与防御：desired 携带的条目必须仍是 config 成员（matchingEntry 只回
/// config 成员，本守卫对直接构造 DesiredScheduleState 的调用方兜底——转移执行
/// 绝不允许落地已被删除的条目）。
public func transitionRequired(
    desired: DesiredScheduleState, state: ScheduleState, config: ChargeScheduleConfig
) -> ScheduleTransition? {
    switch desired {
    case .entry(let entry):
        guard config.entries.contains(where: { $0.id == entry.id }) else { return nil }
        guard state.lastAppliedEntryId != entry.id else { return nil }
        return .applyEntry(entry)
    case .base:
        guard state.lastAppliedEntryId != nil else { return nil }
        return .restoreBase(baseUpperLimit: state.baseUpperLimit, baseMode: state.baseMode)
    }
}

// MARK: - lastAction 字面量族（照 CalibrationLiteral 形态；wire 格式永不本地化）

public enum ChargeScheduleLiteral {
    /// 字面量族前缀。
    public static let scheduleLiteralPrefix = "schedule:"
    /// 进入窗口转移（UD-5：id 取前 8 位——UUID 足够辨识，防字面量过长）。
    public static func entered(id: String) -> String { "schedule:entered:\(String(id.prefix(8)))" }
    /// 退出恢复转移。
    public static let restored = "schedule:restored"
}

// MARK: - XPC 线格式（UD-6：首个字符串键——数组配置不可 UINT64 表达）

/// setChargeSchedule 请求载荷（单字符串键；nil = 不发键——daemon 缺席保持语义）。
public struct ChargeScheduleWire: Equatable, Sendable {
    /// 充电日程配置 JSON（`ChargeScheduleConfig.encoded` 形态）。
    public var scheduleJson: String?

    public init(scheduleJson: String? = nil) {
        self.scheduleJson = scheduleJson
    }
}

/// XPC setChargeSchedule 键名与输入面收口常量（R-3：长度硬上限；三级校验 =
/// 长度 / JSON 解码 / validated——UTF-8 由 JSON 解码兜底，R1 P2-1，**无第四级**）。
public enum ChargeScheduleWireKeys {
    /// 字符串键（xpc_dictionary_set_string；缺席 = 保持现值）。
    public static let scheduleJson = "scheduleJson"
    /// XPC 命令字面量（XPCServer 臂 / DaemonXPCClient 共用）。
    public static let command = "setChargeSchedule"
    /// JSON 字节长度硬上限（与 validateRequest 白名单 / XPCServer 臂 /
    /// setChargeScheduleConfig 三处同源）。
    public static let maxJsonLength = 8192

    /// 长度校验（字节口径，与 xpc_string_get_length 一致）。
    public static func validLength(_ json: String) -> Bool {
        json.utf8.count <= maxJsonLength
    }
}
