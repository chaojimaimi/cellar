import CellarCore
import SwiftUI

/// 校准调度卡（Phase 5 v1.4 §3.1；**参数驱动**——CellarUICheck 仅 import
/// CellarCore/CellarUI，App 侧薄包装桥接 StatusController，照 FanSectionView 先例）：
/// - 门控二态（方案 §7-M3-2）：`schedule == nil`（daemon 回包 calSched 字段缺席 =
///   旧 daemon）→ 整卡升级提示行；非 nil 且 enabled == false = 正常 off 态——
///   **勿把「未配置」当「旧 daemon」**（新 daemon 未配置恒填 .default，UD-7）；
/// - off：开关关（可开）；on：开关开 + 周期 Picker（7/14/30/60/90 天，预选 30）+
///   窗口起点 Picker（0-23 整点，预选 01:00——均照 `.default` 钉死）+ 下次预估行；
/// - 变更即应用（onApply(CalibrationScheduleWire)）：**全键下发**（组件以
///   `CalibrationScheduleWire(policy)` 便捷构造发满三键；缺席保持是 daemon 侧
///   语义，App 不依赖，方案 §7-M3-3）；
/// - 说明块：调度语义一句话 + `calibration.warning` 四点警示（照确认块警示语汇）。
///
/// 下次预估行文案由 App 侧组装后经 `nextEstimateText` 注入（本地时区钟面语义
/// 不进组件——快照注入钉死字面量，golden 跨时区逐字节确定，TBDPlaceholder_stats
/// 先例）；nil（负差值/不可推算）→ 「—」（common.nodata）。
public struct ScheduleSectionView: View {
    /// 校准调度配置（nil = 旧 daemon 字段缺席 → 整卡升级提示）。
    public let schedule: CalibrationSchedulePolicy?
    /// 控制器 busy（控件禁用）。
    public let busy: Bool
    /// 下次预估行文案（App 组装；nil = 负差值/不可推算 → 「—」）。
    public let nextEstimateText: String?
    /// 应用回调（App 侧桥接 applyCalibrationSchedule；全键 wire）。
    public let onApply: (CalibrationScheduleWire) -> Void
    /// 首行标题开关（照 CalibrationSectionView showsTitle 先例）：校准页由卡片头
    /// 承担标题时传 false，防同文重复；默认 true——快照矩阵不传此参。
    public let showsTitle: Bool

    /// 周期档位（钉死五档，方案 §7-M3-3；预选 30 = .default.intervalDays）。
    private static let intervalChoices = [7, 14, 30, 60, 90]

    @State private var intervalDays: Int
    @State private var startHour: Int

    @Environment(\.cellarTheme) private var theme

    public init(
        schedule: CalibrationSchedulePolicy?,
        busy: Bool,
        nextEstimateText: String? = nil,
        onApply: @escaping (CalibrationScheduleWire) -> Void,
        showsTitle: Bool = true
    ) {
        self.schedule = schedule
        self.busy = busy
        self.nextEstimateText = nextEstimateText
        self.onApply = onApply
        self.showsTitle = showsTitle
        // 本地选择态自 daemon 状态播种（照 FanSectionView init 先例；旧 daemon /
        // 未回包落 .default——仅影响 Picker 初值，off 态本就不显示 Picker）。
        let base = schedule ?? CalibrationSchedulePolicy.default
        _intervalDays = State(initialValue: base.intervalDays)
        _startHour = State(initialValue: base.startHour)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                Text(CellarL10n.s("calibration.schedule.title"))
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
            }
            if schedule == nil {
                // 整卡升级提示行（照 capabilities nil 处置先例——字段缺席 = 旧 daemon）。
                Text(CellarL10n.s("calibration.schedule.legacy"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            } else {
                Toggle(isOn: Binding(
                    get: { schedule?.enabled == true },
                    set: { apply(enabled: $0) }
                )) {
                    Text(CellarL10n.s("calibration.schedule.enable"))
                        .font(.caption)
                }
                .disabled(busy)
                if schedule?.enabled == true {
                    intervalPicker
                    startHourPicker
                    nextEstimateRow
                }
                hintBlock
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 外部值回灌（code-review P2-1）：页面构建早于 daemon 首回包时按 .default
        // 播种——daemon 恢复后不回灌的话，用户动 Picker 会把播种默认值静默提交、
        // 覆盖 daemon 原配置（如 7 天/22:00）。回包/轮询更新 schedule 值变即重播种
        // （用户刚提交的值原样回填，无感；onChange 不参与静态渲染——20 张 golden
        // 零扰动）。⚠️ FanSectionView 同款问题登记后续批统一收口，本批只修本组件。
        .onChange(of: schedule) { newValue in
            let base = newValue ?? CalibrationSchedulePolicy.default
            intervalDays = base.intervalDays
            startHour = base.startHour
        }
    }

    // MARK: - 子区

    /// 周期 Picker（五档钉死；变更即全键下发）。
    private var intervalPicker: some View {
        Picker(CellarL10n.s("calibration.schedule.interval"), selection: $intervalDays) {
            ForEach(Self.intervalChoices, id: \.self) { days in
                Text(CellarL10n.s("calibration.schedule.intervalUnit", days)).tag(days)
            }
        }
        .pickerStyle(.menu)
        .disabled(busy)
        .onChange(of: intervalDays) { _ in apply(enabled: schedule?.enabled == true) }
    }

    /// 窗口起点 Picker（0-23 整点；HH:00 钟面格式）。
    private var startHourPicker: some View {
        Picker(CellarL10n.s("calibration.schedule.startHour"), selection: $startHour) {
            ForEach(CalibrationSchedulePolicy.startHourRange, id: \.self) { hour in
                Text(CellarL10n.s("calibration.schedule.hourFormat", hour)).tag(hour)
            }
        }
        .pickerStyle(.menu)
        .disabled(busy)
        .onChange(of: startHour) { _ in apply(enabled: schedule?.enabled == true) }
    }

    /// 下次预估行（App 组装文案；nil → 「—」降级——负差值时钟回拨口径，方案 §7-M3-4）。
    private var nextEstimateRow: some View {
        Text(nextEstimateText ?? CellarL10n.s("common.nodata"))
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
    }

    /// 说明块：调度语义一句话 + 四点警示（引用 calibration.warning——与手动校准
    /// 确认块同一警示文案，自动调度触发同样的充放电接管）。
    private var hintBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CellarL10n.s("calibration.schedule.hint"))
                .font(.caption2)
                .foregroundStyle(theme.tertiaryText)
            Text(CellarL10n.s("calibration.warning"))
                .font(.caption)
                .foregroundStyle(theme.warning)
        }
    }

    // MARK: - 应用（全键下发）

    /// 以本地 Picker 现值组满三键发 wire（enabled 取开关现值；daemon 侧 mergedPolicy
    /// 经 validated 强校验——档位值恒在 1...180 / 0...23 值域内）。
    private func apply(enabled: Bool) {
        onApply(CalibrationScheduleWire(CalibrationSchedulePolicy(
            enabled: enabled, intervalDays: intervalDays, startHour: startHour
        )))
    }
}
