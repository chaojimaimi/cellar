import CellarCore
import CellarUI
import SwiftUI

// MARK: - 自动化页（Phase 5 v1.6 §3.1，替换 .automation 占位）

/// 自动化页：页头（页题 + intro 说明行）+ 充电日程卡（列表 + 内嵌编辑器组合）。
/// 组装形态照 CalibrationPageView 先例（ScrollView + maxWidth 720 + panel 卡容器）。
///
/// 宿主页持编辑展开态与 config 修改流（方案 §3.1 R1 P2-2 规则①——单条展开互斥
/// 的承载点）：组件回调交回条目级操作（开关/增删改）→ 本页合并出**完整 config**
/// → 紧凑 JSON（ChargeScheduleConfig.encoded）经 applyChargeSchedule 全量下发
/// （daemon 三级校验，UD-6 全键覆盖语义）。Shortcuts 卡随 M2.5 NO-GO 缩面移除
/// （Intents 降级 v1.7，复活后随 Intents 批一并加回）。
struct AutomationPageView: View {
    @EnvironmentObject private var statusController: StatusController
    @Environment(\.cellarTheme) private var theme

    /// 编辑展开态（nil = 收起）：.new = 新建草稿（编辑器 seed nil）；.entry =
    /// 编辑现有条目（编辑器沿用其 id）。单值状态天然互斥——同一时刻至多一个
    /// 编辑器（R1 P2-2 规则①）。
    private enum Editing {
        case new
        case entry(ChargeScheduleEntry)
    }

    @State private var editing: Editing?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Text(CellarL10n.s("automation.intro"))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                scheduleCard
            }
            .padding(24)
            // 页面容器纪律：照统计/校准页（maxWidth 720，宽窗不无限拉伸）。
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    // MARK: - 页头（照校准页页头形态；自动化已实页化无版本徽章）

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(CellarL10n.s("main.page.automation"))
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Spacer()
        }
    }

    // MARK: - 日程卡（panel 容器照校准页 panel 形态）

    private func panel(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(theme.secondaryText)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            if let panelBackground = theme.panelBackground { panelBackground }
        }
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.secondaryText.opacity(0.25)))
    }

    /// 日程卡：列表（门控二态在组件内——scheduleJson 缺席 = legacy 态）+ 编辑器
    /// 内嵌展开槽（固定位于列表之后——结构身份稳定，外部回灌不重播种草稿，
    /// R1 P2-2 规则③）。
    private var scheduleCard: some View {
        panel(title: CellarL10n.s("chargeSchedule.title")) {
            VStack(alignment: .leading, spacing: 8) {
                ChargeScheduleListView(
                    config: statusController.scheduleStatus?.config,
                    activeEntryId: statusController.scheduleStatus?.activeEntryId,
                    busy: statusController.busy,
                    showsTitle: false,
                    onToggleEnabled: { toggleEnabled($0) },
                    onAdd: { editing = .new },
                    onEdit: { editing = .entry($0) },
                    onDelete: { delete($0) }
                )
                if let editing {
                    ChargeScheduleEntryEditor(
                        seed: editingSeed(editing),
                        busy: statusController.busy,
                        onCancel: { self.editing = nil },
                        onSave: { save($0) }
                    )
                    // 身份键（审查 P1）：@State 草稿仅首次入树播种——换编辑目标
                    // （A→B/新建↔条目）必须换身份才重播种，否则 A 的草稿会以 B 的
                    // id 保存；同 id 回灌身份不变，规则③「回灌不覆盖草稿」不受影响。
                    .id(editingKey(editing))
                }
            }
        }
    }

    /// 编辑器种子（.new → nil 默认草稿；.entry → 原条目——保存保 id 的依据）。
    /// 编辑器身份键：新建态与逐条目唯一——SwiftUI 结构身份切换 = @State 重播种。
    private func editingKey(_ editing: Editing) -> String {
        switch editing {
        case .new: return "new"
        case .entry(let entry): return entry.id
        }
    }

    private func editingSeed(_ editing: Editing) -> ChargeScheduleEntry? {
        switch editing {
        case .new: return nil
        case .entry(let entry): return entry
        }
    }

    // MARK: - config 修改流（合并 → 整包 JSON 下发）

    /// 当前配置（nil = 旧 daemon/未回包——组件 legacy 态下回调本就不可达，兜底）。
    private var currentConfig: ChargeScheduleConfig? {
        statusController.scheduleStatus?.config
    }

    /// 总开关变更即下发（enabled 单字段改，entries 原样保留——UD-6 全键覆盖）。
    private func toggleEnabled(_ enabled: Bool) {
        guard var config = currentConfig else { return }
        config.enabled = enabled
        apply(config)
    }

    /// 删除条目（被删条目若正被编辑 → 同步收起编辑器——草稿提交目标已不存在）。
    private func delete(_ entry: ChargeScheduleEntry) {
        guard var config = currentConfig else { return }
        config.entries.removeAll { $0.id == entry.id }
        if case .entry(let edited) = editing, edited.id == entry.id {
            editing = nil
        }
        apply(config)
    }

    /// 保存（原子提交）：编辑 → 按 id 原位替换（保 id——「本窗不重应用」语义）；
    /// 新建 → 追加。提交即收起编辑器（R1 P2-2 规则②）。
    private func save(_ entry: ChargeScheduleEntry) {
        guard var config = currentConfig else { return }
        if let index = config.entries.firstIndex(where: { $0.id == entry.id }) {
            config.entries[index] = entry
        } else {
            config.entries.append(entry)
        }
        editing = nil
        apply(config)
    }

    /// 整包 encode 下发（全值类型 encode 不可达失败——nil 静默跳过属防御兜底，
    /// 不静默吞用户操作的前提是本分支理论不可达）。
    private func apply(_ config: ChargeScheduleConfig) {
        guard let json = config.encoded else { return }
        statusController.applyChargeSchedule(json)
    }
}
