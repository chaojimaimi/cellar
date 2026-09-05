import CellarCore
import SwiftUI

// MARK: - 条目摘要装配（列表行与 App 通知文案共用单一实现）

/// 充电日程条目摘要（Phase 5 v1.6）：语汇全走 l10n key（G2），时段经
/// String(format:) printf 通路——数值渲染跨机逐字节确定，无钟面/本地区化风险
/// （照 ThermalSectionView celsiusText 先例）。列表行渲染与 StatusController
/// 日程通知文案共用本装配（单一真相，不双实现）。
public enum ChargeScheduleSummary {
    /// ISO 星期（1 = 周一 … 7 = 周日）到 l10n 词尾的钉死映射（key 域
    /// chargeSchedule.weekday.{mon..sun}）。
    private static let weekdayKeys = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    /// 星期摘要词（「一 二 三」式空格连接）。越界索引跳过不猜测——daemon 侧
    /// validated 已保证 1...7，此处仅防御手改配置的展示路径。
    ///
    /// ⚠️ key 必须先拼 `String` 再包 `String.LocalizationValue(_:)`（逐字 key
    /// 语义）——字面量插值形式 `s("prefix.\(x)")` 会把 `\()` 捕获为**格式参数**
    /// （key 变 `prefix.%@`），查表落空回退显示原始 key（v1.6 走查实证：星期
    /// chip 全显 `chargeSchedule.weekday.%@`；golden 同坏代码烤入故快照门失明
    /// ——CGRect/nodeScale 后第三例）。
    public static func weekdays(_ weekdays: [Int]) -> String {
        weekdays.compactMap { isoWeekday in
            guard ChargeScheduleEntry.weekdayRange.contains(isoWeekday),
                  isoWeekday <= weekdayKeys.count else { return nil }
            let key = "chargeSchedule.weekday." + weekdayKeys[isoWeekday - 1]
            return CellarL10n.s(String.LocalizationValue(key))
        }
        .joined(separator: " ")
    }

    /// 时段摘要（当日分钟 → 「09:00–18:00」；printf 通路跨机确定）。
    public static func timeRange(startMinute: Int, endMinute: Int) -> String {
        CellarL10n.s(
            "chargeSchedule.timeFormat",
            startMinute / 60, startMinute % 60, endMinute / 60, endMinute % 60
        )
    }

    /// 动作摘要（chargingDisabled == true 优先——与 daemon 转移判定同序，UD-1：
    /// 并存合法时 true 优先、upperLimit 忽略；惰性条目（双动作字段均无效）→
    /// 「—」降级，不猜测语义）。
    public static func action(_ entry: ChargeScheduleEntry) -> String {
        if entry.chargingDisabled == true {
            return CellarL10n.s("chargeSchedule.action.unlimited")
        }
        if let limit = entry.upperLimit {
            return CellarL10n.s("chargeSchedule.action.limit", limit)
        }
        return CellarL10n.s("common.nodata")
    }

    /// 一行完整摘要（星期 · 时段 · 动作；分隔词照 StatusLineView 适配器行 " · "
    /// 语汇先例）。通知文案（notification.scheduleEntered %@）的条目段同源。
    public static func line(_ entry: ChargeScheduleEntry) -> String {
        [
            weekdays(entry.weekdays),
            timeRange(startMinute: entry.startMinute, endMinute: entry.endMinute),
            action(entry),
        ]
        .joined(separator: " · ")
    }
}

// MARK: - 充电日程卡

/// 充电日程卡（Phase 5 v1.6 §3.1；**参数驱动**——CellarUICheck 仅 import
/// CellarCore/CellarUI，App 侧薄包装桥接 StatusController，照 ScheduleSectionView/
/// ThermalSectionView 先例）：
/// - 门控二态（UD-7）：`config == nil`（daemon 回包 scheduleJson 缺席 = 旧 daemon）
///   → 整卡升级提示行（照 ScheduleSectionView legacy 态）；非 nil → 配置态——
///   **勿把未配置当旧 daemon**（新 daemon 未配置恒填空配置 JSON）；
/// - 配置态：总开关 Toggle（变更即全量下发）+ 条目摘要行列表（当前命中条目
///   「生效中」徽章——activeEntryId 与条目 id 匹配，方案 §3.1）+ 添加按钮 +
///   空态引导 + 脚注（边沿恢复语义一句话）；
/// - 行操作：点击行进编辑（onEdit）+ 行内删除按钮（onDelete，简素风格不加滑动
///   手势）；编辑器由宿主页内嵌组装（页内嵌展开态，本组件不持编辑状态——
///   R1 P2-2 规则①单条展开互斥由宿主页 editing 态承担）；
/// - 回调全量下发的编排在宿主页（整包 config encode → setChargeSchedule JSON）。
public struct ChargeScheduleListView: View {
    /// 日程配置（nil = 旧 daemon 字段缺席 → 整卡升级提示）。
    public let config: ChargeScheduleConfig?
    /// 当前命中窗口条目 id（daemon scheduleActiveId 回读；nil = 无在窗应用）。
    public let activeEntryId: String?
    /// 控制器 busy（控件禁用）。
    public let busy: Bool
    /// 首行标题开关（照 ScheduleSectionView showsTitle 先例）：自动化页由卡片头
    /// 承担标题时传 false，防同文重复；默认 true——快照矩阵不传此参。
    public let showsTitle: Bool
    /// 总开关变更回调（宿主页改 config.enabled 后全量下发）。
    public let onToggleEnabled: (Bool) -> Void
    /// 添加回调（宿主页展开新建编辑器）。
    public let onAdd: () -> Void
    /// 行点击回调（宿主页展开该条目编辑器）。
    public let onEdit: (ChargeScheduleEntry) -> Void
    /// 行内删除回调（宿主页移除条目后全量下发）。
    public let onDelete: (ChargeScheduleEntry) -> Void

    @Environment(\.cellarTheme) private var theme

    public init(
        config: ChargeScheduleConfig?,
        activeEntryId: String? = nil,
        busy: Bool,
        showsTitle: Bool = true,
        onToggleEnabled: @escaping (Bool) -> Void,
        onAdd: @escaping () -> Void,
        onEdit: @escaping (ChargeScheduleEntry) -> Void,
        onDelete: @escaping (ChargeScheduleEntry) -> Void
    ) {
        self.config = config
        self.activeEntryId = activeEntryId
        self.busy = busy
        self.showsTitle = showsTitle
        self.onToggleEnabled = onToggleEnabled
        self.onAdd = onAdd
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                Text(CellarL10n.s("chargeSchedule.title"))
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
            }
            if config == nil {
                // 整卡升级提示行（照 ScheduleSectionView legacy 态——字段缺席 =
                // 旧 daemon；此时仅此一行，配置态内容一并隐藏）。
                Text(CellarL10n.s("chargeSchedule.legacy"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            } else {
                Text(CellarL10n.s("chargeSchedule.desc"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                enabledToggle
                if config?.entries.isEmpty == true {
                    Text(CellarL10n.s("chargeSchedule.empty"))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                } else {
                    ForEach(config?.entries ?? [], id: \.id) { entry in
                        row(entry)
                    }
                }
                addButton
                Text(CellarL10n.s("chargeSchedule.footnote"))
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 子区

    /// 总开关（变更即下发；enabled 取 daemon 回读单一真相——照 ScheduleSectionView
    /// Toggle 绑定形态）。
    private var enabledToggle: some View {
        Toggle(isOn: Binding(
            get: { config?.enabled == true },
            set: { onToggleEnabled($0) }
        )) {
            Text(CellarL10n.s("chargeSchedule.enabled"))
                .font(.caption)
        }
        .disabled(busy)
    }

    /// 条目摘要行（星期 · 时段 · 动作 + 命中徽章 + 行内删除；整行点击进编辑）。
    private func row(_ entry: ChargeScheduleEntry) -> some View {
        HStack(spacing: 8) {
            Text(ChargeScheduleSummary.line(entry))
                .font(.caption)
                .multilineTextAlignment(.leading)
            if entry.id == activeEntryId {
                // 生效中徽章（accent 12% 底——照 MainWindowView 选中行同族语汇）。
                Text(CellarL10n.s("chargeSchedule.activeBadge"))
                    .font(.caption2)
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.accent.opacity(0.12)))
            }
            Spacer(minLength: 8)
            Button {
                onDelete(entry)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
        .contentShape(Rectangle())
        .onTapGesture { onEdit(entry) }
    }

    /// 添加按钮（条目达上限禁用——前置防线，daemon validated 拒绝前不发起 XPC）。
    private var addButton: some View {
        Button {
            onAdd()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Text(CellarL10n.s("chargeSchedule.add"))
            }
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent)
        .disabled(busy || (config?.entries.count ?? 0) >= ChargeScheduleConfig.maxEntries)
    }
}
