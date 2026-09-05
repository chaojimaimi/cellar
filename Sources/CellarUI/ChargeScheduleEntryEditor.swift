import CellarCore
import SwiftUI

/// 充电日程条目编辑器（Phase 5 v1.6 §3.1 R1 P2-2；**页内嵌展开**——不用 sheet，
/// 照自动放电两步内嵌确认块的先例；**参数驱动**——CellarUICheck 注入 seed 钉死
/// 渲染，回调空闭包无副作用）：
/// - **状态三规则（R1 P2-2）**：①单条展开互斥由宿主页编辑态承担（本组件无展开
///   状态，同一时刻宿主页只装一个实例）；②「取消」丢弃草稿（草稿全在本地
///   @State，丢弃即随视图消失）、「保存」原子提交（onSave 一次回调交完整条目，
///   由宿主页合并成整包 config 下发）；③外部回灌**刻意不回灌**——@State 仅在
///   视图首次入树时经 init 播种，宿主页 config 轮询刷新只重渲染列表、不重播种
///   草稿（与 ScheduleSectionView 的回灌语义相反：那是"无草稿的设置态"，这里是
///   "展开中的编辑草稿"，覆盖即丢用户输入）；
/// - **编辑保存保 id**（R1 P3）：编辑现有条目沿用 seed.id——「本窗不重应用」语义
///   的承载；新建生成新 UUID 字符串；
/// - 字段：星期七选 chip 组（ISO 1...7，周一=1）+ 开始/结束时间 Picker（48 半点
///   档——30 分钟步进钉死）+ 动作二选一 Picker（「限充上限」+ Slider 60...100
///   步进 1 /「放开充电」+ **进窗立即充电至 100% 警示**，R1 P3 UD-5 产品后果
///   明示）；end < start → 「跨午夜」提示词；
/// - 前置防线：草稿非法（未选星期 / 起止相等——daemon validated 必拒）→ 保存
///   禁用，不发起注定失败的 XPC。
public struct ChargeScheduleEntryEditor: View {
    /// 编辑种子：nil = 新建（默认草稿：周一至周五 09:00–18:00 限充 80——照
    /// daemon 默认策略上限）；非 nil = 编辑现有条目（沿用其 id）。
    public let seed: ChargeScheduleEntry?
    /// 控制器 busy（提交期禁用）。
    public let busy: Bool
    /// 取消回调（宿主页收起编辑器，草稿丢弃）。
    public let onCancel: () -> Void
    /// 保存回调（payload = 草稿成品条目；宿主页原位替换/追加后整包下发）。
    public let onSave: (ChargeScheduleEntry) -> Void

    // 草稿态（仅本组件持有——R1 P2-2 规则②的承载）。
    @State private var selectedWeekdays: Set<Int>
    /// 起止分钟（@State 只存半点档值——Picker 48 档 tag 与之一一对应，保存直取）。
    @State private var startMinute: Int
    @State private var endMinute: Int
    /// 动作二选一（true = 完全放开充电——chargingDisabled 语义；false = 限充上限）。
    @State private var unlimited: Bool
    @State private var limit: Int

    /// 时间 Picker 档位（48 半点档：0、30、…、1410——minute 粒度存储、30 分钟
    /// 步进选择的钉死形态）。
    private static let halfHourSlots: [Int] = stride(from: 0, through: 1439, by: 30).map { $0 }

    @Environment(\.cellarTheme) private var theme

    public init(
        seed: ChargeScheduleEntry?,
        busy: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping (ChargeScheduleEntry) -> Void
    ) {
        self.seed = seed
        self.busy = busy
        self.onCancel = onCancel
        self.onSave = onSave
        // 草稿播种（仅首次入树生效——R1 P2-2 规则③刻意不回灌）。seed 分钟值钳到
        // 半点档（UI 粒度 30 分钟；手改配置的奇数分钟仅影响展示起点，保存按档值）。
        let base = seed
        _selectedWeekdays = State(initialValue: Set(base?.weekdays ?? [1, 2, 3, 4, 5]))
        _startMinute = State(initialValue: ((base?.startMinute ?? 540) / 30) * 30)
        _endMinute = State(initialValue: ((base?.endMinute ?? 1080) / 30) * 30)
        // 动作初值照 daemon 转移同序：chargingDisabled == true 优先（并存合法时
        // 上限被忽略——编辑态如实呈现生效动作）。
        _unlimited = State(initialValue: base?.chargingDisabled == true)
        _limit = State(initialValue: base?.upperLimit ?? 80)
    }

    /// 派生：当前动作是否「限充上限」。
    private var isLimitMode: Bool { !unlimited }

    /// 草稿合法性（daemon validated 前置防线）：至少选一天 ∧ 起止不等
    ///（end < start = 跨午夜合法；end == start 非法——半开窗口退化）。
    private var isDraftValid: Bool {
        !selectedWeekdays.isEmpty && endMinute != startMinute
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            weekdaySection
            startRow
            endRow
            if endMinute < startMinute {
                // 跨午夜提示（end < start 自动出现——窗口取模语义的 UI 面）。
                Text(CellarL10n.s("chargeSchedule.crossMidnight"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            actionRow
            if isLimitMode {
                limitRow
            } else {
                // R1 P3 UD-5：放开充电的产品后果明示（限充停充态下进窗立即充电）。
                Text(CellarL10n.s("chargeSchedule.unlimitedWarning"))
                    .font(.caption)
                    .foregroundStyle(theme.warning)
            }
            buttonRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 字段区

    /// 星期七选 chip 组（ISO 1...7；存储前 sorted() 恢复去重升序 canonical）。
    private var weekdaySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CellarL10n.s("chargeSchedule.weekdays"))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { isoWeekday in
                    weekdayChip(isoWeekday)
                }
            }
        }
    }

    /// 单个星期 chip（选中 accent 12% 底 + accent 字，未选 track 底 + 二级字——
    /// 照 MainWindowView 选中行/ThermalSectionView 语汇同族；无 hover 态需求）。
    private func weekdayChip(_ isoWeekday: Int) -> some View {
        let selected = selectedWeekdays.contains(isoWeekday)
        return Button {
            if selected {
                selectedWeekdays.remove(isoWeekday)
            } else {
                selectedWeekdays.insert(isoWeekday)
            }
        } label: {
            Text(ChargeScheduleSummary.weekdays([isoWeekday]))
                .font(.caption2)
                .foregroundStyle(selected ? theme.accent : theme.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(selected ? theme.accent.opacity(0.12) : theme.track)
                )
        }
        .buttonStyle(.plain)
    }

    /// 开始/结束行（标签 + 48 半点档 Picker；label 作 a11y 与菜单标题）。
    private var startRow: some View {
        timeRow(
            label: CellarL10n.s("chargeSchedule.start"),
            selection: $startMinute
        )
    }

    private var endRow: some View {
        timeRow(
            label: CellarL10n.s("chargeSchedule.end"),
            selection: $endMinute
        )
    }

    private func timeRow(label: String, selection: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Spacer()
            Picker(label, selection: selection) {
                ForEach(Self.halfHourSlots, id: \.self) { minute in
                    Text(String(format: "%02lld:%02lld", minute / 60, minute % 60))
                        .tag(minute)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    /// 动作二选一（「限充上限」/「放开充电」；切换即换下方从属控件）。
    private var actionRow: some View {
        HStack {
            Text(CellarL10n.s("chargeSchedule.action"))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Spacer()
            Picker(CellarL10n.s("chargeSchedule.action"), selection: $unlimited) {
                Text(CellarL10n.s("chargeSchedule.action.limitMode")).tag(false)
                Text(CellarL10n.s("chargeSchedule.action.unlimited")).tag(true)
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    /// 限充上限滑杆行（60...100 步进 1——值域取 ChargeScheduleEntry 区间常量
    /// 单一事实，照 ThermalSectionView 先例；编辑草稿仅改 @State，不逐档下发）。
    private var limitRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(CellarL10n.s("chargeSchedule.action.limitMode"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Text(CellarL10n.s("chargeSchedule.limitUnit", limit))
                    .font(.caption)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(limit) },
                    set: { limit = Int($0.rounded()) }
                ),
                in: Double(ChargeScheduleEntry.upperLimitRange.lowerBound)
                    ... Double(ChargeScheduleEntry.upperLimitRange.upperBound),
                step: 1
            )
        }
    }

    /// 取消/保存行（保存禁用 = 草稿非法前置防线；提交期 busy 双保险）。
    private var buttonRow: some View {
        HStack {
            Spacer()
            Button(CellarL10n.s("common.cancel")) { onCancel() }
                .disabled(busy)
            Button(CellarL10n.s("chargeSchedule.save")) { save() }
                .disabled(busy || !isDraftValid)
        }
        .font(.caption)
    }

    // MARK: - 提交（原子：一次回调交完整条目）

    /// 草稿 → 条目成品：编辑沿用 seed.id（R1 P3「编辑保 id」——本窗不重应用），
    /// 新建生成新 UUID；weekdays sorted() 恢复去重升序 canonical（validated 要求
    /// 严格升序）；动作字段二选一——限充 → upperLimit + chargingDisabled nil，
    /// 放开 → chargingDisabled true（upperLimit 忽略语义，UD-1）。
    private func save() {
        let entry = ChargeScheduleEntry(
            id: seed?.id ?? UUID().uuidString,
            weekdays: selectedWeekdays.sorted(),
            startMinute: startMinute,
            endMinute: endMinute,
            upperLimit: unlimited ? nil : limit,
            chargingDisabled: unlimited ? true : nil
        )
        onSave(entry)
    }
}
