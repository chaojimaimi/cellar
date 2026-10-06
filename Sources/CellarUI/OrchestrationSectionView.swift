import CellarCore
import SwiftUI

// MARK: - 充电编排节（v0.19.20 WP-3；**参数驱动**——CellarUICheck 仅 import
// CellarCore/CellarUI，App 侧薄桥接 StatusController；照 FanSectionView/
// ThermalSectionView 先例）：
// - 开关（XPC setOrchestration——daemon 回读 enabled 单一真相，get/set 绑定形态
//   照 ChargeScheduleListView.enabledToggle 先例；0.21.0 §1.2 文案诚实化
//   「编排」→「系统限充执行」，新旧键兼容解析）；
// - 状态行（上次失败：详情 / 就绪；失败详情 = daemon 侧 lastError 回读——
//   **0.23.0 §② 起 = MCLSetFailure 结构化文案承载面**）；
// - 读回展示行（0.20 M2 WP3）；
// - set 可用说明（0.23.0 §② 收敛：embeddedExecutorAvailable = readbackAvailable
//   语义——**快捷指令名输入框与三步创建指引随 Shortcuts 备用通道退役全删**
//   ——红队 F2 语义真空修复：不再指引创建无消费者的快捷指令；MCL 通道缺席机器
//   节级空态，失败细节由状态行承载，无新文案面）。
// 显隐判定（capabilities 含 orchestration）在宿主页——组件只做纯展示，快照矩阵
// 可直接构造。

public struct OrchestrationSectionView: View {
    /// 编排开关（daemon 回读单一真相——orchestration.enabled）。
    public let enabled: Bool
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
    /// 控制器 busy（开关禁用）。
    public let busy: Bool
    /// 首行标题开关（照 ScheduleSectionView showsTitle 先例）：通用页由节头承担
    /// 标题时传 false 防同文重复；默认 true——快照矩阵不传此参。
    public let showsTitle: Bool
    /// **set 可用态**（App 内嵌 set 通道在位——0.23.0 §② 语义收敛
    /// `= readbackAvailable` 语义项）：true → 通道说明行（按开关态二选一：开 =
    /// 「App 内嵌 set + 域双保险」/ 关 =「内部域执法（本开关仅控制 App 内嵌 set
    /// 通道）」）；false（缺省）→ 无说明行（MCL 通道缺席机器节级空态——原输入框/
    /// 三步指引已随批退役）。App 侧判定 = 27 终态 ∧ MCL 通道在位。
    public let embeddedExecutorAvailable: Bool
    /// 开关变更回调（宿主页走 XPC setOrchestration）。
    public let onToggleEnabled: (Bool) -> Void

    @Environment(\.cellarTheme) private var theme

    public init(
        enabled: Bool,
        lastError: String?,
        busy: Bool,
        showsTitle: Bool = true,
        readbackLine: String? = nil,
        readbackIsWarning: Bool = false,
        embeddedExecutorAvailable: Bool = false,
        onToggleEnabled: @escaping (Bool) -> Void
    ) {
        self.enabled = enabled
        self.lastError = lastError
        self.busy = busy
        self.showsTitle = showsTitle
        self.readbackLine = readbackLine
        self.readbackIsWarning = readbackIsWarning
        self.embeddedExecutorAvailable = embeddedExecutorAvailable
        self.onToggleEnabled = onToggleEnabled
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
            statusLine
            // 0.20 M2 WP3 读回展示行（宿主页传 nil 即不渲染——既有 golden 零 diff；
            // 失配/停用态 warning 色，常规值/不可用 info 级 secondary 色）。
            if let readbackLine {
                Text(readbackLine)
                    .font(.caption)
                    .foregroundStyle(readbackIsWarning ? theme.warning : theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 0.23.0 §②：set 可用 → 通道说明（按开关态二选一——0.21.3 §3.2 分流
            // 保留）；set 不可用 → 无说明行（原三步创建指引随快捷指令通道退役——
            // **不再指引创建无消费者的快捷指令**）。
            if embeddedExecutorAvailable {
                Text(CellarL10n.s(enabled
                    ? "settings.execution.channelOn"
                    : "settings.execution.channelOff"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// 状态行（WP-3：就绪 / 上次失败：详情——失败详情为 daemon 侧 lastError 回读
    /// 〔0.23.0 §② 起为 MCLSetFailure 结构化文案〕；关闭态不渲染状态行）。
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
