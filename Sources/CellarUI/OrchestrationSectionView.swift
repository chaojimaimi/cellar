import CellarCore
import SwiftUI

// MARK: - 充电编排节（v0.19.20 WP-3；**参数驱动**——CellarUICheck 仅 import
// CellarCore/CellarUI，App 侧薄桥接 StatusController + OrchestrationSettings；
// 照 FanSectionView/ThermalSectionView 先例）：
// - 开关（XPC setOrchestration——daemon 回读 enabled 单一真相，get/set 绑定形态
//   照 ChargeScheduleListView.enabledToggle 先例）；
// - 快捷指令名输入框（值存 App 侧 UserDefaults——R1 P0-2：daemon 只发 target 数字，
//   名字仅 App 执行时消费；变更经回调回写，组件不持状态）；
// - 状态行（上次失败：详情 / 就绪；失败详情 = daemon 侧 lastError 回读）；
// - setup 指引（快捷指令 App 三步创建动作，l10n 承载）。
// 显隐判定（capabilities 含 orchestration）在宿主页——组件只做纯展示，快照矩阵
// 可直接构造（2 态 × 3 风格 × 2 外观）。

public struct OrchestrationSectionView: View {
    /// 编排开关（daemon 回读单一真相——orchestration.enabled）。
    public let enabled: Bool
    /// 快捷指令名（App 侧 UserDefaults 值；变更经 onShortcutNameChange 回写）。
    public let shortcutName: String
    /// 上次执行失败详情（daemon 回报 lastError 回读；nil = 无失败 → 状态行走就绪）。
    public let lastError: String?
    /// 控制器 busy（开关禁用；输入框不禁用——输入不触发 XPC）。
    public let busy: Bool
    /// 首行标题开关（照 ScheduleSectionView showsTitle 先例）：通用页由节头承担
    /// 标题时传 false 防同文重复；默认 true——快照矩阵不传此参。
    public let showsTitle: Bool
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
        onToggleEnabled: @escaping (Bool) -> Void,
        onShortcutNameChange: @escaping (String) -> Void
    ) {
        self.enabled = enabled
        self.shortcutName = shortcutName
        self.lastError = lastError
        self.busy = busy
        self.showsTitle = showsTitle
        self.onToggleEnabled = onToggleEnabled
        self.onShortcutNameChange = onShortcutNameChange
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsTitle {
                Text(CellarL10n.s("settings.section.orchestration"))
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
            }
            Text(CellarL10n.s("settings.orchestration.desc"))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Toggle(CellarL10n.s("settings.orchestration.toggle"), isOn: Binding(
                get: { enabled },
                set: { onToggleEnabled($0) }
            ))
            .disabled(busy)
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
            statusLine
            Text(CellarL10n.s("settings.orchestration.setup"))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
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
