import Foundation
import os

// MARK: - 刷新调度（纯函数，规格 §2.2）

/// 状态轮询间隔（秒）。面板可见 **1s**、面板关闭 **60s**（保持图标新鲜度与失联
/// 检测）。**双路线解耦定版（WP2）**：轮询与注册态无关——手工路线（CLI 安装）的
/// daemon 同样经 XPC 服务于面板与图标；XPC 无应答时快速失败，开销可忽略。
public func refreshInterval(panelVisible: Bool) -> TimeInterval {
    panelVisible ? 1 : 60
}

// MARK: - 连接态与图标映射（规格 §2.1/§2.5）

/// daemon 连接态。registration 复位（离开 .enabled）时回落 .unknown——
/// 防残留 .unreachable 让图标永久 .alert（用户主动卸载 ≠ 故障）。
public enum ConnectionState: Equatable, Sendable {
    /// 最近一次 getStatus 成功。
    case connected
    /// 最近一次 getStatus 失败（超时/连接失败）。
    case unreachable
    /// 尚未刷新过（首查前 / registration 复位后）。
    case unknown
}

/// 菜单栏图标状态（Phase 2 仅逻辑 + 测试；多状态资产 WP4，单一模板图标不变）。
public enum MenuBarIconState: Equatable, Sendable {
    case charging
    case holding
    case discharging
    case disabled
    case alert
}

/// App 侧实时电源态（IOPS 订阅；WP5 §2.4 菜单栏图标插拔电即时化的数据源）。
/// 非 nil 时替换 daemonStatus.lastExternalConnected/lastChargingEnabled 参与
/// 规则 4/5 判定；规则 1/2/3（失联/未安装/禁用）优先级更高，不受 override 影响。
public struct PowerOverride: Equatable, Sendable {
    public let externalConnected: Bool
    public let isCharging: Bool

    public init(externalConnected: Bool, isCharging: Bool) {
        self.externalConnected = externalConnected
        self.isCharging = isCharging
    }
}

/// 图标状态映射，规则全序（规格 §2.5 定版五条，逐条短路）：
/// 1. connection == .unreachable → .alert（失联优先于一切）
/// 2. status == nil → .disabled（connection 已被规则 1 过滤，全称覆盖三 connection 值）
/// 3. mode == "disabled" → .disabled
/// 4. lastExternalConnected == false → .discharging
/// 5. lastChargingEnabled == true → .charging；否则（含 nil 字段初态）→ .holding
///
/// nil 字段语义：nil ≠ false（规则 4 不触发）、nil ≠ true（规则 5 不触发）——
/// 双 nil 落 .holding，与「未采样过」的初态语义一致。
///
/// powerOverride（WP5 §2.4）：非 nil 时以 App 侧 IOPS 实时电源态**替换**
/// daemonStatus.last* 字段参与规则 4/5 判定（图标即时翻转——不再受 daemon 30s
/// tick 与轮询档位约束）；override 下规则 5 语义同源：isCharging==true → .charging，
/// 否则 → .holding。
public func menuBarIconState(
    status: DaemonStatus?,
    connection: ConnectionState,
    powerOverride: PowerOverride?
) -> MenuBarIconState {
    if connection == .unreachable { return .alert }
    guard let status else { return .disabled }
    if status.mode == "disabled" { return .disabled }
    if let powerOverride {
        if powerOverride.externalConnected == false { return .discharging }
        return powerOverride.isCharging ? .charging : .holding
    }
    if status.lastExternalConnected == false { return .discharging }
    if status.lastChargingEnabled == true { return .charging }
    return .holding
}

/// 无 override 形态（既有调用点与用例 85 零改动；行为 == powerOverride nil）。
public func menuBarIconState(status: DaemonStatus?, connection: ConnectionState) -> MenuBarIconState {
    menuBarIconState(status: status, connection: connection, powerOverride: nil)
}

// MARK: - 菜单栏多状态符号（WP4 规格 §2.2 候选表 + §7.3 图标纪律）

/// 菜单栏图标 SF Symbol 首选名（规格 §2.2 候选表首选项 + §7.3 修订；评审实测
/// macOS 26 目标下候选全部存在）。形状承载语义优先、颜色仅作增强（.alert 由
/// 形状三角形表达）。
///
/// **图标纪律（规格 §7.3，验收 Q2 修复）**：菜单栏图标只表达 Cellar 的管理状态，
/// 永不用电量档位字形——系统菜单栏已有真实电量图标，档位字形（如 battery.100
/// 在 85% 呈「满电」形）必然被读成电量且必然误导；discharging 用
/// arrow.down.circle（回退 minus.circle）表达放电而无档位含义。
public func menuBarSymbolName(for state: MenuBarIconState) -> String {
    switch state {
    case .charging: return "bolt.fill"
    case .holding: return "gauge.with.needle"
    case .discharging: return "arrow.down.circle"
    // ⚠️ disabled 首选 power.dotted（2026-09-01 实测 powerplug.slash 在 macOS 26
    // 不存在——Image(systemName:) 渲染为空 = 菜单栏图标整只消失）。
    case .disabled: return "power.dotted"
    case .alert: return "exclamationmark.triangle.fill"
    }
}

/// 同表回退链（首选符号不可用时按此降级；调用方应做运行时存在性检查——
/// powerplug.slash 缺失事故证明候选表本身也需要兜底）。
public func menuBarSymbolFallbackName(for state: MenuBarIconState) -> String {
    switch state {
    case .charging: return "bolt.circle.fill"
    case .holding: return "circle.dashed"
    case .discharging: return "minus.circle"
    case .disabled: return "powerplug"
    case .alert: return "exclamationmark.triangle"
    }
}

/// 菜单栏电池形态取值链（0.18 batteryForm 纯函数化；v1.12.1 冻结修复配套）。
/// 三条独立的「快照值 ?? 回退值」链，与原实现逐字段等价：
/// - percent：快照 ?? daemonPercent（快照缺席时 60s 轮询恒新鲜）；
/// - charging：快照 ?? override.isCharging ?? false（IOPS 活数据）；
/// - plugged：快照 ?? override.externalConnected ?? charging（外接缺席时以
///   充电态近似——保守方向，充电必外接）。
///
/// 快照在位 ⇒ 某表面可见（refreshCadence 1s 采样）；**全表面关闭即清空**
/// （v1.12.1 冻结修复——旧版停采样不清空，最后一次面板可见时刻的电源态冻结成
/// 永久旧值，插拔电徽标点击面板才刷新的根因）；反向不成立——可见时也可能短暂
/// 缺席（重开首帧补采样在途 / 采样失败降级）。快照与 override 双缺席且
/// daemonPercent nil → 整体 nil，label 回退符号形态（恒渲染红线）。override
/// 缺席（IOPS 订阅创建失败降级）→ 充电/外接按 false（无徽标），与冷启动初态
/// 同语义。
public func menuBarBatteryForm(
    snapshotPercent: Int?,
    snapshotIsCharging: Bool?,
    snapshotExternalConnected: Bool?,
    powerOverride: PowerOverride?,
    daemonPercent: Int?
) -> (percent: Int, charging: Bool, plugged: Bool)? {
    guard let percent = snapshotPercent ?? daemonPercent else { return nil }
    let isCharging = snapshotIsCharging ?? (powerOverride?.isCharging ?? false)
    let plugged = snapshotExternalConnected
        ?? (powerOverride?.externalConnected ?? isCharging)
    return (percent, isCharging, plugged)
}

// MARK: - 遥测采样节奏（WP4 规格 §2.1 P0-2 独立门控）

/// 面板遥测采样间隔（秒）。**任一表面可见 1s、全表面关闭 nil（停止采样）**
/// （调用点传入面板 ∨ 主窗口合并可见性）。
/// 与 status 轮询（refreshInterval）并行独立、不复用同一循环——停采样省电
/// （「App 不得成为耗电源」）的前提是**快照无残留消费者**：菜单栏电池形态
/// 徽标取值链第一优先源就是 batterySnapshot（menuBarBatteryForm），因此停采样
/// 必须伴随清空快照（refreshCadence 全表面关闭分支，v1.12.1 冻结修复）——否则
/// 最后一次采样值冻结成永久旧值，插拔电徽标点击面板才刷新。
/// 未注册 daemon 时遥测照常（门控只有 panelVisible）。
public func telemetrySampleInterval(panelVisible: Bool) -> TimeInterval? {
    panelVisible ? 1 : nil
}

// MARK: - 状态行电流方向（WP4 规格 §7.2 P2-2 修复；WP4 §4.3 枚举下沉消除双真相；0.19.4 §1.1 kind 版接管）

/// 电流方向枚举（判定逻辑唯一真相；展示词条由 UI 层经 CellarL10n 本地化——
/// 本类型不含用户可见串）。
public enum CurrentDirection: String, Equatable, Sendable {
    /// 充电中（kind == .charging——实际受电）。
    case charging
    /// 放电（kind ∈ {.assist, .battery}——补入/电池供电）。
    case discharging
}

/// 电流方向判定（0.19.4 §1.1 kind 版，替代 isCharging 二参版——FlowDiagramKind
/// 统一接管全 App 流向判据后，方向词与流向形态同源裁决）：charging → .charging；
/// assist / battery → .discharging；holding → nil（只显幅值，方向词隐藏——修
/// 「停充态显示放电 0.00 A」的自相矛盾语义由 holding 态承接）。
///
/// ⚠️ 语义变更如实登记（0.19.4 §1.1，CHANGELOG 引用）：
/// 1. 旧二参版钉死的边界 (isCharging=true, ext=false)（拔电瞬态按充电呈现）在
///    kind 版下翻转为 .discharging——ext=false 经 flowDiagramModel ① 恒得 .battery。
///    有意修正：拔电后电池确实在放电，方向词「放电」比沿用陈旧 isCharging 位更诚实。
/// 2. ③-holding 子情形（遥测在场 ∧ isCharging=true ∧ |BP|≤ε）：方向词由「充电」
///    翻为 nil（只显幅值）——0.19.3 已登记的徽章/图形分叉随统一收口一并消除。
public func currentDirection(kind: FlowDiagramKind) -> CurrentDirection? {
    switch kind {
    case .charging: return .charging
    case .assist, .battery: return .discharging
    case .holding: return nil
    }
}

// MARK: - 用户域偏好持久化（规格 §2.4）

/// 用户偏好（app-config.json 的 Codable 形态）。
/// 范围定版：不镜像上限/滞回（策略唯一真相在 daemon）；仅持登录项开关、
/// Phase 3 预留的风格字段与 WP5 首启引导完成标志。
public struct AppConfig: Codable, Equatable, Sendable {
    /// 开机启动（SMAppService.loginItem 注册态镜像；App 重建后登录项可能掉注册，
    /// 属已知现象，WP6 统一验证）。
    public var launchAtLogin: Bool
    /// Phase 3 预留（面板风格）。当前恒 nil（默认值形态也合法）。
    public var style: String?
    /// WP5 首启引导完成标志（§2.4；默认 false——旧 app-config.json 缺 key 时
    /// 经 decodeIfPresent 兼容为 false）。
    public var onboardingCompleted: Bool
    /// 菜单栏电量百分比显隐（v1.10 M2；nil = 未设置 = 关——照 style: String?
    /// 先例，旧 app-config.json 缺 key 经 decodeIfPresent 兼容为 nil）。
    public var menuBarPercentageVisible: Bool?
    /// 菜单栏电池电量图标显隐（0.18 T3 D-3b；nil = 未设置 = 关——照
    /// menuBarPercentageVisible 先例，旧 app-config.json 缺 key 经
    /// decodeIfPresent 兼容为 nil。v1.11 windowBatteryIconVisible 退役：手写
    /// Codable 删字段——旧配置文件中的该键被新解码自动忽略，零迁移）。
    public var menuBarBatteryIconVisible: Bool?

    public init(
        launchAtLogin: Bool = false,
        style: String? = nil,
        onboardingCompleted: Bool = false,
        menuBarPercentageVisible: Bool? = nil,
        menuBarBatteryIconVisible: Bool? = nil
    ) {
        self.launchAtLogin = launchAtLogin
        self.style = style
        self.onboardingCompleted = onboardingCompleted
        self.menuBarPercentageVisible = menuBarPercentageVisible
        self.menuBarBatteryIconVisible = menuBarBatteryIconVisible
    }

    public static let `default` = AppConfig()

    // MARK: - Codable（WP5 自定义，§2.4）

    /// CodingKeys 全字段显式。
    private enum CodingKeys: String, CodingKey {
        case launchAtLogin
        case style
        case onboardingCompleted
        case menuBarPercentageVisible
        case menuBarBatteryIconVisible
    }

    /// 自定义 decode：新键可缺席（旧文件兼容）——decodeIfPresent ?? false；
    /// 其余字段同语义回退默认值。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        style = try container.decodeIfPresent(String.self, forKey: .style)
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        menuBarPercentageVisible = try container.decodeIfPresent(Bool.self, forKey: .menuBarPercentageVisible)
        menuBarBatteryIconVisible = try container.decodeIfPresent(Bool.self, forKey: .menuBarBatteryIconVisible)
    }

    /// 自定义 encode：onboardingCompleted 恒写（前向兼容）；style / menuBarPercentageVisible
    /// / menuBarBatteryIconVisible 沿用 encodeIfPresent（nil 缺席，与旧合成编码一致）。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encodeIfPresent(style, forKey: .style)
        try container.encode(onboardingCompleted, forKey: .onboardingCompleted)
        try container.encodeIfPresent(menuBarPercentageVisible, forKey: .menuBarPercentageVisible)
        try container.encodeIfPresent(menuBarBatteryIconVisible, forKey: .menuBarBatteryIconVisible)
    }
}

/// 用户偏好持久化（actor + 同目录临时文件原子替换，规格 §2.4）。
///
/// - 读：文件缺失 / 非 JSON / 解码失败 → 默认（os_log 可见化——偏好可重建，不值得
///   抛错打断面板；不静默）。
/// - 写：同目录临时文件（0644）+ rename 原子替换；父目录自动创建（用户域首写
///   场景——App 不假设 Application Support/Cellar 已存在）。
/// - **独立实现，不复用 PolicyStore 写路径**：共享需动 daemon 持久化代码（红线），
///   且两者目录域不同（root 系统域 vs 用户域）。
public actor AppConfigStore {
    public let url: URL

    /// 默认位置：用户域 `~/Library/Application Support/Cellar/app-config.json`。
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cellar/app-config.json")
    }

    /// 注入 URL 供测试（CellarCoreCheck 用临时目录；App 用 defaultURL）。
    public init(url: URL) {
        self.url = url
    }

    /// 读：缺失/损坏 → 默认（故障可见化但不抛错——偏好丢失自愈，属可重建状态）。
    public func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url) else {
            Self.log.info("app-config 缺失（\(self.url.path)），使用默认偏好")
            return .default
        }
        guard let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            Self.log.error("app-config 损坏（非 JSON 或字段不符），回退默认偏好")
            return .default
        }
        return decoded
    }

    /// 写：编码 → 临时文件 → chmod 0644 → rename（原子替换）。错误原样上抛
    /// （面板上屏失败文案，不静默）。
    public func save(_ config: AppConfig) throws {
        let data = try JSONEncoder().encode(config)
        let directory = url.deletingLastPathComponent()
        // 首写建目录（用户域，无需特权；失败即上抛，绝不静默）。
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".app-config.json.tmp")
        // 清理：任何失败路径都尽力移除临时文件（不覆盖原错误）。
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try data.write(to: temporaryURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: temporaryURL.path
        )
        #if canImport(Darwin)
        guard rename(temporaryURL.path, url.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        #else
        // 非 Darwin 兜底（本包仅 macOS，此路径仅保持可编译性）：非原子替换。
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
        #endif
    }

    /// 原子读改写（WP3 §3.1，评审 P0-1 定版）：actor 方法体内同步执行
    /// （load → transform → save 无挂起点），单实例上 RMW 不可交错——共享同一
    /// store 的多写者（风格/登录项/引导完成标志）并发更新时字段互不覆盖。
    ///
    /// - 读失败（缺失/损坏）→ 回退默认配置再改写（与 load 同语义：偏好可重建，
    ///   不值得打断调用方）。
    /// - 写失败原样上抛（调用方上屏失败文案，不静默）。
    ///
    /// ⚠️ 参数必须 `@Sendable`：Swift 6 数据竞争安全要求跨 actor 调用的全部实参
    /// 可 Sendable（三调用点 StyleController / LoginItemController /
    /// OnboardingController 全部跨隔离）；闭包应仅捕获 Sendable 值。
    public func update(
        _ transform: @Sendable (inout AppConfig) -> Void
    ) throws -> AppConfig {
        var config = load()
        transform(&config)
        try save(config)
        return config
    }

    /// 日志（actor 静态成员非隔离；Logger Sendable，跨隔离界安全）。
    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "app-config")
}

// MARK: - 温度暂停派生助手（WP1 充电侧温度暂停）

/// 温度暂停态判定（daemonStatus → 状态行注词的唯一接线）。
/// `enforce:tempPause` 表示「当前处于温度暂停态」，非单次写事件——case 3/4 无写
/// 仍返回该字面量，暂停期持续可见（App 60s 轮询必见，审查 M3 同构）。字面量是
/// wire 格式永不本地化，App 不裸写字符串（方案 §2.4）。
public extension DaemonStatus {
    var isTempPauseAction: Bool {
        lastAction == "enforce:tempPause"
    }
}

// MARK: - 校准动作助手（WP3 §2.3：daemonStatus.action 直读，App 面板校准区数据源）

/// 校准动作态/相位态派生（OneShotAction.phase 为持久化原始值——未知串显式 nil，
/// 消费面按「未知」降级呈现，不猜测语义）。
public extension DaemonStatus {
    /// 动作在轨且 kind == calibration。
    var isCalibrationAction: Bool {
        action?.kind == Calibration.kind
    }

    /// 校准当前相位（kind==calibration 时解析 action.phase 原始值；未知串/缺席 → nil）。
    var calibrationPhase: Calibration.Phase? {
        guard isCalibrationAction, let raw = action?.phase else { return nil }
        return Calibration.Phase(rawValue: raw)
    }
}

// MARK: - 校准调度派生助手（Phase 5 v1.4 §2.1/§2.3：DaemonStatus calSched 强类型视图）

public extension DaemonStatus {
    /// 校准调度配置（daemon buildStatusLocked **恒填** .default——nil 仅在旧 daemon
    /// 回包时出现；App 门控二态：字段缺席 = 整卡升级提示，非 nil 且 enabled == false
    /// = 正常 off 态，UD-7——勿把「未配置」当「旧 daemon」）。
    var calibrationSchedule: CalibrationSchedulePolicy? {
        guard let enabled = calSchedEnabled, let intervalDays = calSchedIntervalDays,
              let startHour = calSchedStartHour else { return nil }
        return CalibrationSchedulePolicy(
            enabled: enabled, intervalDays: intervalDays, startHour: startHour
        )
    }

    /// 下次自动校准预估（方案 §2.1 派生助手；调度禁用 / 旧 daemon / 时钟回拨负差值
    /// → nil——预估行上屏「—」）。以当前时刻推算（面板轮询逐次刷新）。
    var nextAutoCalibrationEstimate: Date? {
        guard let schedule = calibrationSchedule else { return nil }
        // 模块限定：与同名实例属性区分（编译器提示的消歧写法）。
        return CellarCore.nextAutoCalibrationEstimate(
            now: Date(),
            schedule: schedule,
            lastStartedAt: lastCalStart.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

// MARK: - 展示格式化

/// 时间戳本地时区渲染。⚠️ 直接对 Date 做字符串插值（description）恒为 UTC——
/// 渲染层必须显式转换（真机验收缺陷：CLI status 显示 +0000 时间，与系统时钟差 8 小时）。
/// timeZone 可注入供测试确定性；locale 钉死 POSIX，防地区设置（历法/12 小时制）漂移格式。
public func formatTimestamp(
    _ date: Date,
    timeZone: TimeZone = .current
) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.timeZone = timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: date)
}