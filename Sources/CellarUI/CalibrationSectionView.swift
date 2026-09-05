import CellarCore
import SwiftUI

/// 校准区（WP3 §2.4；**参数驱动**——CellarUICheck 仅 import CellarCore/CellarUI，
/// App 侧薄包装桥接 StatusController）：
/// - 能力门控：capabilities 缺 `calibration` → 整区隐藏（nil = 旧 daemon 隐藏即可，
///   无升级提示——校准非核心路径）；
/// - idle（action == nil）：区标题 +「开始校准」按钮 → 两步内嵌确认块（四点警示，
///   同 discharge 内嵌确认先例——confirmationDialog 会收起 MenuBarExtra 窗口）；
/// - running（action.kind == calibration）：相位词 + 当前电量 + 「取消校准」按钮
///   （busy 门控）。
public struct CalibrationSectionView: View {
    /// 校准动作在轨（daemonStatus.action?.kind == calibration → running）。
    public let calibrationActive: Bool
    /// 当前相位（running 时有效；nil = 相位未知降级呈现）。
    public let phase: Calibration.Phase?
    /// 当前电量（running 行；nil = 未知）。
    public let percent: Int?
    /// 能力在位（capabilities 含 calibration；false = 整区隐藏）。
    public let capabilityPresent: Bool
    /// mode == "active"（idle 显示条件，同 ActionSectionView 先例）。
    public let modeActive: Bool
    /// 无在轨动作（code-review P1-1：fullOnce/discharge 在轨时 idle 不显示——
    /// 否则用户点开始会被 daemon .actionOccupied 拒绝，双纵深削半）。
    public let actionIdle: Bool
    /// 控制器 busy（按钮禁用）。
    public let busy: Bool
    /// 开始（确认块确认回调：App 侧桥接 calibrateStart）。
    public let onStart: () -> Void
    /// 取消（App 侧桥接 calibrateCancel）。
    public let onCancel: () -> Void
    /// 快照矩阵注入：初始展开确认块（渲染 inactive 形态的确认态；生产恒默认 false）。
    public let initialConfirmVisible: Bool
    /// 首行标题开关（照 FanSectionView showsTitle 先例）：校准页由卡片头承担标题
    /// 时传 false，防同文重复；默认 true——面板与快照矩阵既有构造不传此参 →
    /// 渲染字节不变（112 张 golden 零 regen 全靠该默认路径）。
    public let showsTitle: Bool

    @State private var showConfirm: Bool

    @Environment(\.cellarTheme) private var theme

    public init(
        calibrationActive: Bool,
        phase: Calibration.Phase?,
        percent: Int?,
        capabilityPresent: Bool,
        modeActive: Bool,
        actionIdle: Bool = true,
        busy: Bool,
        onStart: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        initialConfirmVisible: Bool = false,
        showsTitle: Bool = true
    ) {
        self.calibrationActive = calibrationActive
        self.phase = phase
        self.percent = percent
        self.capabilityPresent = capabilityPresent
        self.modeActive = modeActive
        self.actionIdle = actionIdle
        self.busy = busy
        self.onStart = onStart
        self.onCancel = onCancel
        self.initialConfirmVisible = initialConfirmVisible
        self.showsTitle = showsTitle
        _showConfirm = State(initialValue: initialConfirmVisible)
    }

    public var body: some View {
        if capabilityPresent && (calibrationActive || (modeActive && actionIdle)) {
            VStack(alignment: .leading, spacing: 6) {
                // 标题条件渲染（showsTitle）：App 校准页卡片头承担标题 → 传 false。
                if showsTitle {
                    Text(CellarL10n.s("calibration.title"))
                        .font(.caption2)
                        .foregroundStyle(theme.tertiaryText)
                }
                if calibrationActive {
                    runningRow
                } else if showConfirm {
                    confirmBlock
                } else {
                    startButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// running 行：相位词 + 当前电量 + 取消（数据源 = daemonStatus action +
    /// telemetry 快照优先、lastPercent 兜底，与 dischargeProgressRow 同纪律）。
    private var runningRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(theme.success)
            Text(runningText)
                .font(.caption)
            Spacer(minLength: 4)
            Button(CellarL10n.s("calibration.cancel")) {
                onCancel()
            }
            .controlSize(.small)
            .disabled(busy)
        }
    }

    private var runningText: String {
        let word: String
        switch phase {
        case .chargeFull: word = CellarL10n.s("calibration.phase.chargeFull")
        case .hold: word = CellarL10n.s("calibration.phase.hold")
        case .discharge: word = CellarL10n.s("calibration.phase.discharge")
        case nil: word = CellarL10n.s("calibration.phase.chargeFull")
        }
        if let percent {
            return "\(word)… \(percent)%"
        }
        return "\(word)…"
    }

    /// 内嵌确认块（四点警示；参照 discharge 先例——两步行：按钮 → 展开确认）。
    private var confirmBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CellarL10n.s("calibration.warning"))
                .font(.caption)
                .foregroundStyle(theme.warning)
            HStack(spacing: 8) {
                Button(CellarL10n.s("calibration.confirm")) {
                    showConfirm = false
                    onStart()
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

    private var startButton: some View {
        Button {
            showConfirm = true
        } label: {
            Label(CellarL10n.s("calibration.start"), systemImage: "wrench.and.screwdriver.fill")
        }
        .controlSize(.small)
        .disabled(busy)
    }
}