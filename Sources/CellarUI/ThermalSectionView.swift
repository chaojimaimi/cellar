import CellarCore
import SwiftUI

/// 充电热保护区（Phase 5 v1.5 §3.1；**参数驱动**——CellarUICheck 仅 import
/// CellarCore/CellarUI，App 侧薄包装桥接 StatusController，照 FanSectionView/
/// ScheduleSectionView 先例）：
/// - 门控二态（UD-7）：`thermal == nil`（daemon 回包 therm 两键缺席 = 旧 daemon）
///   → 整卡升级提示行（照 ScheduleSectionView legacy 态）；非 nil → 配置态——
///   **勿把默认配置当旧 daemon**（新 daemon 恒填 `.default` 展开）；
/// - **无开关**——热保护不可关闭（UD-2 值域钳制的 UI 面，§4 红线 3），与风扇节
///   （有 Toggle）的结构性差异，脚注言明；
/// - 暂停阈值 Slider 35...45°C 步进 0.5，**松手提交**（onEditingChanged(false)
///   才应用——照 fan 先例，防逐档洪水式 XPC）；
/// - **恢复温度 Slider（v1.5 走查重构）**：用户心智模型是「两个温度点」而非
///   「阈值 + 差值量」——第二滑杆直接表示恢复温度（值 = 暂停点 − 滞回），随暂停
///   阈值拖动实时跟随；值域 [暂停−8, 暂停−1] 动态钳制，拖动改写滞回
///   （hysteresis = pause − resume），非法组合（恢复 ≥ 暂停）在滑杆域内天然
///   不可表达——数据模型（pause + hysteresis）与 XPC 契约零变化；
/// - 滞回温差只读行（pause − resume 派生展示）；
/// - 变更即**全键下发**（onApply(ThermalWire)——`ThermalWire(_:)` 便捷构造；
///   缺席保持是 daemon 侧语义，App 不依赖，照 ScheduleSectionView apply 先例）。
public struct ThermalSectionView: View {
    /// 充电热暂停配置（nil = 旧 daemon 字段缺席 → 整卡升级提示）。
    public let thermal: ThermalStatus?
    /// 控制器 busy（控件禁用）。
    public let busy: Bool
    /// 应用回调（App 侧桥接 setThermal；全键 wire）。
    public let onApply: (ThermalWire) -> Void
    /// 首行标题开关（照 FanSectionView showsTitle 先例）：App 通用页由节头承担
    /// 标题时传 false，防同文重复；默认 true——快照矩阵不传此参。
    public let showsTitle: Bool

    /// 滑杆值域自 ThermalPolicy 区间常量换算 °C（单一事实——与 XPCServer 值域
    /// 校验同一来源，组件不另立数字；step 0.5 照 fan 阈值滑杆先例）。
    private static let pauseRangeC: ClosedRange<Double> =
        (Double(ThermalPolicy.pauseRangeCentiC.lowerBound) / 100)
        ... (Double(ThermalPolicy.pauseRangeCentiC.upperBound) / 100)
    private static let hysteresisRangeC: ClosedRange<Double> =
        (Double(ThermalPolicy.hysteresisRangeCentiC.lowerBound) / 100)
        ... (Double(ThermalPolicy.hysteresisRangeCentiC.upperBound) / 100)

    /// 恢复温度滑杆动态值域：[暂停−8, 暂停−1]（由滞回区间常量换算——暂停点
    /// 变化时域随之平移，resume 恒在域内，见 resumeRow 注释）。
    private static func resumeRangeC(currentPauseC: Double) -> ClosedRange<Double> {
        (currentPauseC - Double(ThermalPolicy.hysteresisRangeCentiC.upperBound) / 100)
            ... (currentPauseC - Double(ThermalPolicy.hysteresisRangeCentiC.lowerBound) / 100)
    }

    /// 恢复温度投影（滑杆值 = 暂停点 − 滞回；@State 只存 pause/hysteresis 两源，
    /// resume 恒派生——两滑杆与温差行三者自洽，无第二真相源）。
    private var resumeC: Double {
        pauseC - hysteresisC
    }

    @State private var pauseC: Double
    @State private var hysteresisC: Double

    @Environment(\.cellarTheme) private var theme

    public init(
        thermal: ThermalStatus?,
        busy: Bool,
        onApply: @escaping (ThermalWire) -> Void,
        showsTitle: Bool = true
    ) {
        self.thermal = thermal
        self.busy = busy
        self.onApply = onApply
        self.showsTitle = showsTitle
        // 本地滑杆态自 daemon 状态播种（照 FanSectionView init 先例；旧 daemon /
        // 未回包落 .default——仅影响 Slider 初值，legacy 态本就不显示控件）。
        let base = thermal ?? ThermalStatus()
        _pauseC = State(initialValue: Double(base.pauseCentiC) / 100)
        _hysteresisC = State(initialValue: Double(base.hysteresisCentiC) / 100)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                Text(CellarL10n.s("thermal.title"))
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
            }
            if thermal == nil {
                // 整卡升级提示行（照 ScheduleSectionView legacy 态——字段缺席 =
                // 旧 daemon；此时仅此一行，脚注等配置态内容一并隐藏）。
                Text(CellarL10n.s("thermal.legacy"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            } else {
                Text(CellarL10n.s("thermal.desc"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                pauseRow
                resumeRow
                gapRow
                Text(CellarL10n.s("thermal.footnote"))
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 外部值回灌（照 ScheduleSectionView code-review P2-1 先例）：页面构建早于
        // daemon 首回包时按 .default 播种——回包后不回灌的话，用户动滑杆会把播种
        // 默认值静默提交、覆盖 daemon 原配置。回包/轮询更新值变即重播种（用户刚
        // 提交的值原样回填，无感；onChange 只在配置真变时触发、不参与静态渲染——
        // golden 零扰动）。⚠️ FanSectionView 同款问题已登记后续批统一收口。
        .onChange(of: thermal) { newValue in
            let base = newValue ?? ThermalStatus()
            pauseC = Double(base.pauseCentiC) / 100
            hysteresisC = Double(base.hysteresisCentiC) / 100
        }
    }

    // MARK: - 子区

    /// 暂停阈值行（35...45°C 步进 0.5，松手提交）。
    private var pauseRow: some View {
        Group {
            HStack {
                Text(CellarL10n.s("thermal.pause"))
                Spacer()
                Text(celsiusText(pauseC))
                    .monospacedDigit()
            }
            .font(.caption)
            Slider(value: $pauseC, in: Self.pauseRangeC, step: 0.5, onEditingChanged: { editing in
                if !editing { apply() }
            })
                .disabled(busy)
        }
    }

    /// 恢复温度行（v1.5 走查重构：滑杆直接表示恢复温度——值 = 暂停点 − 滞回，
    /// 随暂停阈值实时跟随；值域 [暂停−8, 暂停−1] 动态钳制，拖动即改写滞回）。
    /// 动态值域由滞回区间常量换算（单一事实源），resume 恒在域内：resume =
    /// pause − hysteresis 且 hysteresis ∈ [1,8] ⟹ resume ∈ [pause−8, pause−1]。
    private var resumeRow: some View {
        Group {
            HStack {
                Text(CellarL10n.s("thermal.resume"))
                Spacer()
                Text(celsiusText(resumeC))
                    .monospacedDigit()
            }
            .font(.caption)
            Slider(
                value: Binding(
                    get: { resumeC },
                    set: { hysteresisC = pauseC - $0 }
                ),
                in: Self.resumeRangeC(currentPauseC: pauseC),
                step: 0.5,
                onEditingChanged: { editing in
                    if !editing { apply() }
                }
            )
                .disabled(busy)
        }
    }

    /// 滞回温差只读行（派生展示：pause − resume；数值恒与两滑杆一致）。
    private var gapRow: some View {
        Text(CellarL10n.s("thermal.gap", pauseC - resumeC, CellarL10n.s("thermal.unit.celsius.short")))
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
    }

    // MARK: - 应用（全键下发）

    /// 以本地滑杆现值组全键发 wire（`ThermalWire(_:)` 便捷构造；daemon 侧
    /// mergedPolicy 经 validated 强校验——滑杆值域恒在区间内）。
    private func apply() {
        onApply(ThermalWire(ThermalPolicy(
            pauseCentiC: Int((pauseC * 100).rounded()),
            hysteresisCentiC: Int((hysteresisC * 100).rounded())
        )))
    }

    /// 数值 + 单位短词（G2：单位词不写字面量——`thermal.unit.celsius.short`）。
    /// String(format:) 为 printf 语义非本地区化通路——数值渲染跨机逐字节确定
    ///（fan 阈值行同款先例），无钟面/本地区化风险，无需预格式化注入。
    private func celsiusText(_ value: Double) -> String {
        String(format: "%.1f", value) + CellarL10n.s("thermal.unit.celsius.short")
    }
}
