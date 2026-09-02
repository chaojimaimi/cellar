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

/// 图标状态映射，规则全序（规格 §2.5 定版五条，逐条短路）：
/// 1. connection == .unreachable → .alert（失联优先于一切）
/// 2. status == nil → .disabled（connection 已被规则 1 过滤，全称覆盖三 connection 值）
/// 3. mode == "disabled" → .disabled
/// 4. lastExternalConnected == false → .discharging
/// 5. lastChargingEnabled == true → .charging；否则（含 nil 字段初态）→ .holding
///
/// nil 字段语义：nil ≠ false（规则 4 不触发）、nil ≠ true（规则 5 不触发）——
/// 双 nil 落 .holding，与「未采样过」的初态语义一致。
public func menuBarIconState(status: DaemonStatus?, connection: ConnectionState) -> MenuBarIconState {
    if connection == .unreachable { return .alert }
    guard let status else { return .disabled }
    if status.mode == "disabled" { return .disabled }
    if status.lastExternalConnected == false { return .discharging }
    if status.lastChargingEnabled == true { return .charging }
    return .holding
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

// MARK: - 遥测采样节奏（WP4 规格 §2.1 P0-2 独立门控）

/// 面板遥测采样间隔（秒）。面板可见 **1s**、面板关闭 **nil（停止采样）**。
/// 与 status 轮询（refreshInterval）并行独立、不复用同一循环——菜单栏图标数据源
/// 是 daemonStatus，关闭面板后 batterySnapshot 无消费者，60s 遥测档纯属耗电
/// （「App 不得成为耗电源」）。未注册 daemon 时遥测照常（门控只有 panelVisible）。
public func telemetrySampleInterval(panelVisible: Bool) -> TimeInterval? {
    panelVisible ? 1 : nil
}

// MARK: - 状态行电流方向（WP4 规格 §7.2 P2-2 修复；WP4 §4.3 枚举下沉消除双真相）

/// 电流方向枚举（判定逻辑唯一真相；展示词条由 UI 层经 CellarL10n 本地化——
/// 本类型不含用户可见串）。
public enum CurrentDirection: String, Equatable, Sendable {
    /// 充电中（isCharging 优先）。
    case charging
    /// 电池供电（未外接）。
    case discharging
}

/// 电流方向判定（规格 §7.2 方向词规则，三分支）：isCharging 优先——边界（外接
/// 断开瞬间 isCharging 可能仍为 true）按充电呈现；其次 !externalConnected → 放电；
/// 其余（外接 + 停充）→ nil（方向词隐藏、幅值照显——修「停充态显示放电
/// 0.00 A」的自相矛盾）。
public func currentDirection(isCharging: Bool, externalConnected: Bool) -> CurrentDirection? {
    if isCharging { return .charging }
    if !externalConnected { return .discharging }
    return nil
}

/// ⚠️ 已弃用（WP4 §4.3）：新消费面（StatusLineView）改用
/// `currentDirection(isCharging:externalConnected:)` 枚举 + CellarL10n 词条
/// （direction.charging / direction.discharging）。本包装仅保留中文 token 语义
/// 供 CellarCoreCheck 用例 92 钉死行为（枚举 →「充电/放电」token，行为零变化）。
/// 不加 `@available(*, deprecated)`：CellarCoreCheck 钉死场景仍调用本函数，属性
/// 会产生编译警告，与「构建零警告」门冲突——以文档注记方式弃用（偏差登记）。
public func currentDirectionWord(isCharging: Bool, externalConnected: Bool) -> String? {
    switch currentDirection(isCharging: isCharging, externalConnected: externalConnected) {
    case .charging: return "充电"
    case .discharging: return "放电"
    case nil: return nil
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

    public init(launchAtLogin: Bool = false, style: String? = nil, onboardingCompleted: Bool = false) {
        self.launchAtLogin = launchAtLogin
        self.style = style
        self.onboardingCompleted = onboardingCompleted
    }

    public static let `default` = AppConfig()

    // MARK: - Codable（WP5 自定义，§2.4）

    /// CodingKeys 全字段显式。
    private enum CodingKeys: String, CodingKey {
        case launchAtLogin
        case style
        case onboardingCompleted
    }

    /// 自定义 decode：新键可缺席（旧文件兼容）——decodeIfPresent ?? false；
    /// 其余字段同语义回退默认值。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        style = try container.decodeIfPresent(String.self, forKey: .style)
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
    }

    /// 自定义 encode：onboardingCompleted 恒写（前向兼容）；style 沿用 encodeIfPresent
    /// （nil 缺席，与旧合成编码一致）。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encodeIfPresent(style, forKey: .style)
        try container.encode(onboardingCompleted, forKey: .onboardingCompleted)
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