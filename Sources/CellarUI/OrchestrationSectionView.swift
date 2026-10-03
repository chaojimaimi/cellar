import CellarCore
import SwiftUI

// MARK: - 充电编排节（v0.19.20 WP-3；**参数驱动**——CellarUICheck 仅 import
// CellarCore/CellarUI，App 侧薄桥接 StatusController + OrchestrationSettings；
// 照 FanSectionView/ThermalSectionView 先例）：
// - 开关（XPC setOrchestration——daemon 回读 enabled 单一真相，get/set 绑定形态
//   照 ChargeScheduleListView.enabledToggle 先例；0.21.0 §1.2 文案诚实化
//   「编排」→「系统限充执行」，新旧键兼容解析）；
// - 快捷指令名输入框（值存 App 侧 UserDefaults——R1 P0-2：daemon 只发 target 数字，
//   名字仅 App 执行时消费；变更经回调回写，组件不持状态）；
// - 状态行（上次失败：详情 / 就绪；失败详情 = daemon 侧 lastError 回读）；
// - setup 指引（快捷指令 App 三步创建动作，l10n 承载）；
// - 0.21.0 §1.2：embeddedExecutorAvailable 参数（R2-P3-3）——set 可用态输入框
//   隐藏 + setup 指引降级为说明性文案（内嵌执行通道接管，快捷指令备用化）。
// 显隐判定（capabilities 含 orchestration）在宿主页——组件只做纯展示，快照矩阵
// 可直接构造（2 态 × 3 风格 × 2 外观）。

public struct OrchestrationSectionView: View {
    /// 编排开关（daemon 回读单一真相——orchestration.enabled）。
    public let enabled: Bool
    /// 快捷指令名（App 侧 UserDefaults 值；变更经 onShortcutNameChange 回写）。
    public let shortcutName: String
    /// 上次执行失败详情（daemon 回报 lastError 回读；nil = 无失败 → 状态行走就绪）。
    public let lastError: String?
    /// 0.20 M2 WP3 读回展示行（宿主页组装好的成品串——「当前生效上限（读回）：
    /// 75%」/「读回不可用」/「读回校验已停用…」/「读回与目标不符…」；nil = 不渲染，
    /// 既有构造零 diff——旧 daemon/26 无编排能力机器天然缺席）。数据源 = App 侧
    /// MCLClient 采样 + WP3 执行后即时校验（App 本地 UI 态，wire 零变更）。
    public let readbackLine: String?
    /// 读回行告警色（读回失配/停用 → warning；nil 行不渲染本参数无效）。
    /// 默认 false——既有构造零 diff。
    public let readbackIsWarning: Bool
    /// 控制器 busy（开关禁用；输入框不禁用——输入不触发 XPC）。
    public let busy: Bool
    /// 首行标题开关（照 ScheduleSectionView showsTitle 先例）：通用页由节头承担
    /// 标题时传 false 防同文重复；默认 true——快照矩阵不传此参。
    public let showsTitle: Bool
    /// **0.21.0 §1.2 set 可用态**（App 内嵌执行通道接管——R2-P3-3 参数驱动，
    /// CellarUI 不 import App 层）：true → 快捷指令名输入框隐藏 + setup 三步指引
    /// 分流为执行通道文案（0.21.3 §3.2 按开关态二选一：开 =「App 内嵌 set + 域
    /// 双保险」/ 关 =「内部域执法（本开关仅控制 App 内嵌 set 通道）」）；
    /// false（缺省）→ 原指引（既有构造零 diff）。App 侧判定 = 27 终态 ∧ MCL set
    /// 通道可用 ∧ 未驻留快捷指令 fallback。
    public let embeddedExecutorAvailable: Bool
    /// 开关变更回调（宿主页走 XPC setOrchestration）。
    public let onToggleEnabled: (Bool) -> Void
    /// 快捷指令名变更回调（宿主页写 UserDefaults；实时回写无提交按钮——照
    /// UserDefaults 轻量偏好惯例）。
    public let onShortcutNameChange: (String) -> Void

    @Environment(\.cellarTheme) private var theme

    public init(
        enabled: Bool,
        shortcutName: String,
        lastError: String?,
        busy: Bool,
        showsTitle: Bool = true,
        readbackLine: String? = nil,
        readbackIsWarning: Bool = false,
        embeddedExecutorAvailable: Bool = false,
        onToggleEnabled: @escaping (Bool) -> Void,
        onShortcutNameChange: @escaping (String) -> Void
    ) {
        self.enabled = enabled
        self.shortcutName = shortcutName
        self.lastError = lastError
        self.busy = busy
        self.showsTitle = showsTitle
        self.readbackLine = readbackLine
        self.readbackIsWarning = readbackIsWarning
        self.embeddedExecutorAvailable = embeddedExecutorAvailable
        self.onToggleEnabled = onToggleEnabled
        self.onShortcutNameChange = onShortcutNameChange
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsTitle {
                // 0.21.0 §1.2 文案诚实化：「编排」→「系统限充执行」（新旧键兼容——
                // 新键优先缺译回落旧键，旧键保留不删）。
                Text(CellarL10n.sRenamed(
                    "settings.section.execution", fallback: "settings.section.orchestration"))
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
            }
            Text(CellarL10n.sRenamed(
                "settings.execution.desc", fallback: "settings.orchestration.desc"))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Toggle(CellarL10n.sRenamed(
                "settings.execution.toggle", fallback: "settings.orchestration.toggle"), isOn: Binding(
                get: { enabled },
                set: { onToggleEnabled($0) }
            ))
            .disabled(busy)
            // 0.21.0 §1.2：set 可用态 → 名字输入框隐藏（内嵌通道不经名字执行）。
            if !embeddedExecutorAvailable {
                HStack(spacing: 12) {
                    Text(CellarL10n.s("settings.orchestration.shortcutName"))
                        .font(.body)
                    Spacer(minLength: 8)
                    TextField("", text: Binding(
                        get: { shortcutName },
                        set: { onShortcutNameChange($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .disabled(busy)
                }
            }
            statusLine
            // 0.20 M2 WP3 读回展示行（宿主页传 nil 即不渲染——既有 golden 零 diff；
            // 失配/停用态 warning 色，常规值/不可用 info 级 secondary 色）。
            if let readbackLine {
                Text(readbackLine)
                    .font(.caption)
                    .foregroundStyle(readbackIsWarning ? theme.warning : theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 0.21.0 §1.2：setup 指引二态——set 可用 → 降级说明性文案（快捷指令
            // 备用化）；set 不可用 → 原三步创建指引（既有文案零变化）。
            // **0.21.3 §3.2 文案分流（0.21.2 登记）**：旧单一 embeddedNotice 在开关
            // 关态误导（「已由 App 内嵌执行通道接管」——域执法不受本开关门，开关
            // 关 ≠ 无执法）。改为按开关态分流：开 =「App 内嵌 set + 域双保险」；
            // 关 =「内部域执法（本开关仅控制 App 内嵌 set 通道）」——参数驱动
            //（enabled/embeddedExecutorAvailable 均既有参数，CellarUICheck 快照
            // 矩阵直接构造两态）。
            if embeddedExecutorAvailable {
                Text(CellarL10n.s(enabled
                    ? "settings.execution.channelOn"
                    : "settings.execution.channelOff"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(CellarL10n.s("settings.orchestration.setup"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// 状态行（WP-3：就绪 / 上次失败：详情——失败详情为 daemon 侧 lastError 回读，
    /// 捷径被删/改名等 failed 形态经回报链落在那里；关闭态不渲染状态行）。
    @ViewBuilder
    private var statusLine: some View {
        if let lastError {
            Text(CellarL10n.s("settings.orchestration.lastFailed", lastError))
                .font(.caption)
                .foregroundStyle(theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if enabled {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(theme.success)
                Text(CellarL10n.s("settings.orchestration.statusReady"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }
}
