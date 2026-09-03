import CellarCore
import SwiftUI

/// 风扇智能降温区（Phase 5 v1.1 §7；**参数驱动**——CellarUICheck 仅 import
/// CellarCore/CellarUI，App 侧薄包装桥接 StatusController；照 CalibrationSectionView
/// 先例）：
/// - 开关 Toggle（opt-in 默认关）+ 开启两步内嵌确认块（**不用 confirmationDialog
///   ——会收起 MenuBarExtra 窗口，项目踩过**，照自动放电确认块模式）；
/// - 策略 Picker 四项：minRaise 灰显「即将支持」（§0.5b，不可选）；
/// - 阈值 Slider 30.0...55.0°C 步进 0.5；速度 Slider 40...100%；twoStage 参数
///   仅策略为两级分段时显形；
/// - 脚注固定文案：「风扇阈值与充电热暂停（40°C 暂停 / 37°C 恢复）相互独立」；
/// - 状态行九态（fan.status.*）：已关闭/探测中/自动/加速中→N rpm/保持/已暂停介入
///   （采样异常）/本机不支持/暂不支持该策略/检测到其他风扇控制写入者。
///
/// 变更即应用（onApply(FanWire)——缺席字段 = daemon 保持现值）；本地滑杆态在
/// init 从 daemon 状态播种（照 CalibrationSectionView 的参数注入先例，快照矩阵
/// 可直接构造）。
public struct FanSectionView: View {
    /// daemon 风扇状态（nil = 旧 daemon 未上报 → 控件禁用 + 升级提示）。
    public let fan: FanStatus?
    /// 控制器 busy（控件禁用）。
    public let busy: Bool
    /// 应用回调（App 侧桥接 setFan；缺席字段保持现值）。
    public let onApply: (FanWire) -> Void
    /// 快照矩阵注入：初始展开确认块（渲染 inactive 形态的确认态；生产恒默认 false）。
    public let initialConfirmVisible: Bool
    /// 快照矩阵注入：状态行词覆盖（生产用 fan.state；矩阵可钉死特定态）。
    public let stateOverride: FanStateWord?

    @State private var showConfirm: Bool
    @State private var strategy: FanStrategy
    @State private var thresholdC: Double
    @State private var speedPercent: Double
    @State private var stage2Percent: Double
    @State private var stage2RiseC: Double

    @Environment(\.cellarTheme) private var theme

    public init(
        fan: FanStatus?,
        busy: Bool,
        onApply: @escaping (FanWire) -> Void,
        initialConfirmVisible: Bool = false,
        stateOverride: FanStateWord? = nil
    ) {
        let base = fan ?? FanStatus(
            enabled: false, strategy: .constantSpeed, state: .off,
            targetRPM: nil, currentRPM: nil, thresholdCentiC: FanPolicy.default.thresholdCentiC,
            conflictFlag: false
        )
        self.fan = fan
        self.busy = busy
        self.onApply = onApply
        self.initialConfirmVisible = initialConfirmVisible
        self.stateOverride = stateOverride
        _showConfirm = State(initialValue: initialConfirmVisible)
        _strategy = State(initialValue: base.strategy)
        _thresholdC = State(initialValue: Double(base.thresholdCentiC) / 100)
        _speedPercent = State(initialValue: Double(base.speedPercent))
        _stage2Percent = State(initialValue: Double(base.stage2Percent))
        _stage2RiseC = State(initialValue: Double(base.stage2RiseCentiC) / 100)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CellarL10n.s("fan.title"))
                .font(.caption2)
                .foregroundStyle(theme.tertiaryText)

            Toggle(isOn: Binding(
                get: { fan?.enabled == true },
                set: { toggle($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CellarL10n.s("fan.desc"))
                        .font(.caption)
                    if staleDaemon {
                        Text(CellarL10n.s("fan.upgradeHint"))
                            .font(.caption2)
                            .foregroundStyle(theme.warning)
                    }
                }
            }
            .disabled(busy || staleDaemon)

            if showConfirm && !staleDaemon {
                confirmBlock
            }

            if fan != nil && !staleDaemon {
                statusRow
            }

            if fan != nil && !staleDaemon {
                strategyPicker
            }

            if fan != nil && !staleDaemon {
                thresholdRow
                speedRow
                if strategy == .twoStage {
                    stage2Rows
                }
            }

            Text(CellarL10n.s("fan.footnote"))
                .font(.caption2)
                .foregroundStyle(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 子区

    /// 开启两步内嵌确认块（boost 是可感知行为——需明示确认；关是安全方向直通）。
    private var confirmBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CellarL10n.s("fan.warning"))
                .font(.caption)
                .foregroundStyle(theme.warning)
            HStack(spacing: 8) {
                Button(CellarL10n.s("fan.confirm")) {
                    showConfirm = false
                    onApply(FanWire(enabled: 1))
                }
                .controlSize(.small)
                .disabled(busy)
                Button(CellarL10n.s("panel.action.back")) {
                    showConfirm = false
                }
                .controlSize(.small)
            }
        }
    }

    /// 状态行九态（word + boost 目标 rpm；冲突词整行高优先级呈现）。
    private var statusRow: some View {
        HStack(spacing: 4) {
            Image(systemName: statusSymbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(statusColor)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var effectiveState: FanStateWord {
        stateOverride ?? fan?.state ?? .off
    }

    private var statusSymbol: String {
        switch effectiveState {
        case .off, .automatic, .probing: return "fan"
        case .boost: return "fan.fill"
        case .hold: return "slider.horizontal.3"
        case .degraded: return "exclamationmark.triangle"
        case .unsupported, .strategyUnsupported: return "questionmark.circle"
        case .conflict: return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch effectiveState {
        case .conflict, .degraded: return theme.alert
        case .boost: return theme.accent
        case .unsupported, .strategyUnsupported: return theme.warning
        case .off, .probing, .automatic, .hold: return theme.secondaryText
        }
    }

    /// 状态文字（九态；boost 带目标 rpm——「加速中 →3200rpm」）。
    private var statusText: String {
        switch effectiveState {
        case .off: return CellarL10n.s("fan.status.off")
        case .probing: return CellarL10n.s("fan.status.probing")
        case .automatic: return CellarL10n.s("fan.status.automatic")
        case .boost:
            let rpm = fan?.targetRPM.map { "\(Int($0.rounded()))" } ?? "?"
            return CellarL10n.s("fan.status.boost", rpm)
        case .hold: return CellarL10n.s("fan.status.hold")
        case .degraded: return CellarL10n.s("fan.status.degraded")
        case .unsupported: return CellarL10n.s("fan.status.unsupported")
        case .strategyUnsupported: return CellarL10n.s("fan.status.strategyUnsupported")
        case .conflict: return CellarL10n.s("fan.status.conflict")
        }
    }

    /// 策略 Picker（minRaise 灰显 + 「即将支持」注记——不可选中，§0.5b）。
    private var strategyPicker: some View {
        Picker(CellarL10n.s("fan.strategy"), selection: $strategy) {
            ForEach(FanStrategy.allCases, id: \.self) { s in
                if s == .minRaise {
                    Text(CellarL10n.s("fan.strategy.minRaise") + "（" + CellarL10n.s("fan.strategy.minRaise.comingSoon") + "）")
                        .tag(s)
                        .disabled(true)
                } else {
                    Text(strategyLabel(s)).tag(s)
                }
            }
        }
        .pickerStyle(.menu)
        .disabled(busy)
        .onChange(of: strategy) { _ in
            onApply(FanWire(strategy: FanWire.wireValue(strategy)))
        }
    }

    private func strategyLabel(_ s: FanStrategy) -> String {
        switch s {
        case .constantSpeed: return CellarL10n.s("fan.strategy.constantSpeed")
        case .minRaise: return CellarL10n.s("fan.strategy.minRaise")
        case .twoStage: return CellarL10n.s("fan.strategy.twoStage")
        case .emergency: return CellarL10n.s("fan.strategy.emergency")
        }
    }

    private var thresholdRow: some View {
        Group {
            HStack {
                Text(CellarL10n.s("fan.threshold"))
                Spacer()
                Text(String(format: "%.1f°C", thresholdC))
                    .monospacedDigit()
            }
            .font(.caption)
            // 松手提交（P1-3）：onChange 逐档直发会按 0.5°C 步进洪水式触发 XPC——
            // 照 PanelView 松手提交先例，仅 onEditingChanged(false) 时应用一次。
            Slider(value: $thresholdC, in: 30...55, step: 0.5, onEditingChanged: { editing in
                if !editing { applyThreshold() }
            })
                .disabled(busy)
        }
    }

    /// 阈值应用（松手提交）
    private func applyThreshold() {
        onApply(FanWire(threshold: UInt64(Int((thresholdC * 100).rounded()))))
    }

    private var speedRow: some View {
        Group {
            HStack {
                Text(CellarL10n.s("fan.speed"))
                Spacer()
                Text("\(Int(speedPercent))%")
                    .monospacedDigit()
            }
            .font(.caption)
            Slider(value: $speedPercent, in: 40...100, step: 1, onEditingChanged: { editing in
                if !editing { onApply(FanWire(speed: UInt64(Int(speedPercent)))) }
            })
                .disabled(busy)
        }
    }

    /// twoStage 专属参数（仅策略 = 两级分段时显形）。
    private var stage2Rows: some View {
        Group {
            HStack {
                Text(CellarL10n.s("fan.stage2"))
                Spacer()
                Text("\(Int(stage2Percent))%")
                    .monospacedDigit()
            }
            .font(.caption)
            Slider(value: $stage2Percent, in: 60...100, step: 1, onEditingChanged: { editing in
                if !editing { onApply(FanWire(stage2: UInt64(Int(stage2Percent)))) }
            })
                .disabled(busy)
            HStack {
                Text(CellarL10n.s("fan.stage2Rise"))
                Spacer()
                Text(String(format: "%.1f°C", stage2RiseC))
                    .monospacedDigit()
            }
            .font(.caption)
            Slider(value: $stage2RiseC, in: 1...5, step: 0.5, onEditingChanged: { editing in
                if !editing { onApply(FanWire(stage2Rise: UInt64(Int((stage2RiseC * 100).rounded())))) }
            })
                .disabled(busy)
        }
    }

    // MARK: - 开关

    private var staleDaemon: Bool {
        fan == nil
    }

    /// 开关动作：开启 → 展开确认块（两步）；关闭直通（关是安全方向）。
    private func toggle(_ enabled: Bool) {
        guard !staleDaemon else { return }
        if enabled {
            showConfirm = true
        } else {
            showConfirm = false
            onApply(FanWire(enabled: 0))
        }
    }
}