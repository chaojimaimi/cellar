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
/// （daemon 三级校验，UD-6 全键覆盖语义）。Shortcuts 卡随 M2.5 NO-GO 移除
/// （AppIntents 系统硬要求签名 Team ID，项目不引入付费签名——已终止不再规划）。
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

    /// 待删条目暂存（0.23.7 B2-2 删除两步确认）：组件行内 minus.circle → onDelete
    /// 改暂存本槽（不再直删），列表与编辑器之间内嵌确认块展开，确认才走 delete
    /// 全量下发。宿主层拦截——组件 ChargeScheduleListView 在 golden 矩阵内零触及。
    /// 页面级 @State——页面重建即清（残留态无跨页滞留面）。
    @State private var pendingDeleteEntry: ChargeScheduleEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                // 主窗挂点（0.23.7 B2-6 自动化页扩挂，B1 登记 P2 收口）——与面板
                // 同源反馈（controlFeedback/statusFailure/失联连接态），文案沿用
                // panel.banner.*（0.23.7 B2-4 文案已统一指主窗）；参数照 B1-2
                // ControlPageView/GeneralSections 挂点同构。无失败态 bannerContent
                // 返回 nil 零渲染，页面常规态零布局变化。
                AlertBanner(
                    feedback: statusController.controlFeedback,
                    connection: statusController.connection,
                    lastAttemptSummary: statusController.lastAttempt?.summary,
                    statusFailureMessage: statusController.statusFailure?.message,
                    onRetry: statusController.lastAttempt == nil
                        ? { statusController.refreshNow() }
                        : { statusController.retryLastAttempt() }
                )
                Text(CellarL10n.s("automation.intro"))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                scheduleCard
            }
            .padding(24)
            // 页面容器纪律：照统计/校准页（maxWidth 720，宽窗不无限拉伸）。
            .frame(maxWidth: 720, alignment: .leading)
            // 内容列 720 居中：外层撑满窗口宽，宽窗两侧均分留白（滚动条仍贴窗口右缘=macOS 惯例）。
            .frame(maxWidth: .infinity)
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

    /// 日程卡：列表（门控二态在组件内——scheduleJson 缺席 = legacy 态）+ 删除
    /// 确认条件槽（0.23.7 B2-2：pendingDeleteEntry 非 nil 时展开）+ 编辑器内嵌
    /// 展开槽。结构身份由条件槽 + 编辑器显式 .id 双重保障（外部回灌不重播种
    /// 草稿，R1 P2-2 规则③）——原「固定位于列表之后」口径过期（plan-reviewer
    /// P3：单靠位置的说法会误导后来者）。
    private var scheduleCard: some View {
        panel(title: CellarL10n.s("chargeSchedule.title")) {
            VStack(alignment: .leading, spacing: 8) {
                ChargeScheduleListView(
                    config: statusController.scheduleStatus?.config,
                    activeEntryId: statusController.scheduleStatus?.activeEntryId,
                    busy: statusController.busy,
                    showsTitle: false,
                    // **0.23.1 编排退役**：原「编排生效中 → <80 条目『原生最低 80%』
                    // 行内标注」随批删除（R4/常规 P1-6——<80 全区间域承载后标注失实）。
                    onToggleEnabled: { toggleEnabled($0) },
                    // 0.23.7 B2-2：编辑态切换 → 清删除确认暂存（暂存随编辑目标变动
                    // 失效，防跨目标滞留；不给 editing 加互斥守卫——共存无害见下）。
                    onAdd: {
                        pendingDeleteEntry = nil
                        editing = .new
                    },
                    onEdit: {
                        pendingDeleteEntry = nil
                        editing = .entry($0)
                    },
                    onDelete: { pendingDeleteEntry = $0 }
                )
                // 删除两步确认块（0.23.7 B2-2，照放电确认块形态：内嵌展开——
                // 删除原为 minus.circle 直删 + 全量下发，无任何确认面）。仅
                // pendingDeleteEntry 非 nil 时渲染；编辑器展开时共存无害（二者
                // 互斥性弱；delete(_:) 自带「被删条目正被编辑 → 收起编辑器」
                // 互斥处理，不给 editing 加互斥守卫）。
                if let entry = pendingDeleteEntry {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(CellarL10n.s("chargeSchedule.deleteConfirm"))
                            .font(.caption)
                            .foregroundStyle(theme.warning)
                        // 摘要行复用组件既有摘要形态（星期 · 时段 · 动作）。
                        Text(ChargeScheduleSummary.line(entry))
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(theme.secondaryText)
                        HStack(spacing: 8) {
                            Button(CellarL10n.s("common.confirm")) {
                                pendingDeleteEntry = nil
                                delete(entry)
                            }
                            .controlSize(.small)
                            // 确认钮照放电确认块先例禁 busy（plan-reviewer P3：
                            // 暂存到确认之间 busy 可被他处置位，批次内一致语汇）。
                            .disabled(statusController.busy)
                            Button(CellarL10n.s("common.back")) {
                                pendingDeleteEntry = nil
                            }
                            .controlSize(.small)
                        }
                    }
                }
                if let editing {
                    ChargeScheduleEntryEditor(
                        seed: editingSeed(editing),
                        busy: statusController.busy,
                        onCancel: {
                            pendingDeleteEntry = nil   // 编辑态切换 → 清删除确认暂存（0.23.7 B2-2）
                            self.editing = nil
                        },
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
        pendingDeleteEntry = nil   // 编辑态切换 → 清删除确认暂存（0.23.7 B2-2）
        apply(config)
    }

    /// 整包 encode 下发（全值类型 encode 不可达失败——nil 静默跳过属防御兜底，
    /// 不静默吞用户操作的前提是本分支理论不可达）。
    private func apply(_ config: ChargeScheduleConfig) {
        guard let json = config.encoded else { return }
        statusController.applyChargeSchedule(json)
    }
}
