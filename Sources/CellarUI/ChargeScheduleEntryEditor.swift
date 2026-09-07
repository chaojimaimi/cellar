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
/// - 字段：星期七选 chip 组（ISO 1...7，周一=1）+ 开始/结束时间选择（自定义内滚
///   弹出 `ScheduleTimeField`——0.18.1 T2 治原生 menu 48 档撑窗；30 分钟步进钉死，
///   结束 49 档含「24:00」次日零点特例档，0.18.1 T1 全天语义 UI 面）+ 动作二选一
///   Picker（「限充上限」+ Slider 60...100 步进 1 /「放开充电」+ **进窗立即充电至
///   100% 警示**，R1 P3 UD-5 产品后果明示）；start == end → 「全天」提示词 /
///   end < start → 「跨午夜」提示词（两态互斥）；
/// - 前置防线：草稿非法（未选星期——0.18.1 D-1d 起止相等合法化为全天）→ 保存
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
    /// 起止分钟（@State 只存半点档值——档位表 tag 与之一一对应，保存直取；
    /// 结束档值域含 1440 = 次日零点档）。
    @State private var startMinute: Int
    @State private var endMinute: Int
    /// 动作二选一（true = 完全放开充电——chargingDisabled 语义；false = 限充上限）。
    @State private var unlimited: Bool
    @State private var limit: Int

    /// 开始档位（48 半点档：0、30、…、1439——minute 粒度存储、30 分钟步进钉死）。
    private static let startSlots = stride(from: 0, through: 1439, by: 30).map { $0 }
    /// 结束档位（49 档：开始档 + 1440「24:00」次日零点特例——0.18.1 T1 D-1b
    /// end 值域扩展 0...1440 的 UI 面；start == end 全天语义见 isDraftValid）。
    private static let endSlots = startSlots + [1440]

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

    /// 草稿合法性（daemon validated 前置防线）：至少选一天。0.18.1 D-1d 放宽——
    /// start == end 合法（全天语义；daemon validated 归一 (0,0) canonical，save()
    /// 本地同款归一），end < start 跨午夜合法；分钟值域由档位表天然限定
    /// （起止档 ∈ 0...1440），无需数值防线。
    private var isDraftValid: Bool {
        !selectedWeekdays.isEmpty
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
            if startMinute == endMinute {
                // 全天提示（0.18.1 T1 D-1d：start == end 草稿即全天——说明文案
                // 随态出现，与跨午夜提示互斥）。
                Text(CellarL10n.s("schedule.allDay.hint"))
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

    /// 开始/结束行（标签 + 内滚弹出档位选择；label 作 a11y 与弹层语境）。
    private var startRow: some View {
        ScheduleTimeField(
            label: CellarL10n.s("chargeSchedule.start"),
            selection: $startMinute,
            slots: Self.startSlots
        )
    }

    private var endRow: some View {
        ScheduleTimeField(
            label: CellarL10n.s("chargeSchedule.end"),
            selection: $endMinute,
            slots: Self.endSlots
        )
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
    /// 放开 → chargingDisabled true（upperLimit 忽略语义，UD-1）；**全天本地归一**
    /// （0.18.1 D-1d/R2 P3）：start == end → 存 (0,0) canonical——与 daemon
    /// validated 归一同款，消「保存 (12:00,12:00) → daemon 归一 (0,0) → 回读列表
    /// 摘要瞬间跳变」的显示闪变。
    private func save() {
        let isAllDay = startMinute == endMinute
        let entry = ChargeScheduleEntry(
            id: seed?.id ?? UUID().uuidString,
            weekdays: selectedWeekdays.sorted(),
            startMinute: isAllDay ? 0 : startMinute,
            endMinute: isAllDay ? 0 : endMinute,
            upperLimit: unlimited ? nil : limit,
            chargingDisabled: unlimited ? true : nil
        )
        onSave(entry)
    }
}

// MARK: - 时间选择字段（0.18.1 T2 内滚改造）

/// 时间选择字段（标签 + 当前值 Button + `.popover` 档位列表）：原生 menu Picker
/// 在主窗场景整体撑出屏幕（menu 形态档位全展开、无内滚——0.18.1 走查②本体）。
/// 自定义弹出 = popover 内 ScrollView 固定高 300pt 内滚 + 档位 Button 列表
///（行高 28、当前档 accent 12% 底 + accent 字——照 weekdayChip 同族语汇，
/// 工业 token 着装，无 `if style == .industrial` 分支）。**档位表参数化**
///（R1 P2-1）：开始传 48 档 / 结束传 49 档（含 24:00 特例字面）。
private struct ScheduleTimeField: View {
    let label: String
    @Binding var selection: Int
    /// 档位分钟表（升序；形态由调用方决定——start 48 档 / end 49 档）。
    let slots: [Int]

    @Environment(\.cellarTheme) private var theme
    @State private var showsPopover = false

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Spacer()
            Button {
                showsPopover = true
            } label: {
                Text(slotText(selection))
                    .font(.system(.caption, design: theme.numericFontDesign ?? .default))
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.track))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                slotList
            }
        }
    }

    /// 档位弹层（固定 96×300——档位全量可达，内滚不再撑窗）。
    private var slotList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(slots, id: \.self) { slot in
                    slotRow(slot)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 96, height: 300)
    }

    /// 单档行（行高 28；当前档 accent 高亮——点选即回填并收起弹层）。
    private func slotRow(_ slot: Int) -> some View {
        let selected = slot == selection
        return Button {
            selection = slot
            showsPopover = false
        } label: {
            Text(slotText(slot))
                .font(.system(.caption, design: theme.numericFontDesign ?? .default))
                .monospacedDigit()
                .foregroundStyle(selected ? theme.accent : theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background {
                    if selected {
                        Capsule().fill(theme.accent.opacity(0.12))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    /// 档位字面（printf 通路跨机确定；1440 特例「24:00」——次日零点档字面）。
    private func slotText(_ minute: Int) -> String {
        minute == 1440 ? "24:00" : String(format: "%02lld:%02lld", minute / 60, minute % 60)
    }
}
