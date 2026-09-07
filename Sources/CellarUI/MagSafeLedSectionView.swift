import CellarCore
import SwiftUI

// MARK: - MagSafe LED 分节（Phase 5 v1.8 M3；参数驱动组件照 FanSectionView 形态）

/// MagSafe 指示灯设置节（通用页 + 快照矩阵两宿主）：
/// - 标题（showsTitle 参数化——通用页由节头承担，组件标题关掉防同文重复）；
/// - 说明行：跟随系统 = 出厂行为；
/// - 模式行：跟随系统 / 常灭 / 常绿 / 常琥珀（Picker .menu）；
/// - 冲突提示行：daemon 冲突锁存态下 WARN 展示（照风扇冲突词先例）；
/// - 轻提示行（v1.10 M2）：组件内反馈槽（成功/失败 LED 切换结果，App 侧
///   magSafeLedFeedback 注入）——布局照冲突提示行先例；默认 nil 零绘制（快照
///   既有构造路径字节不变，showsTitle 默认参先例机械保证）。
///
/// 播种纪律（方案 §4 R1 P3-4 钉死）：@State 仅 init 播种——daemon 值变化经
/// `onChange(of: mode)` **无条件重播种**（ScheduleSectionView.swift:94-98 修复
/// 先例）；Picker 发送侧 guard「新值 ≠ daemon 现值」防 echo 回灌。
public struct MagSafeLedSectionView: View {
    @Environment(\.cellarTheme) private var theme
    let mode: MagSafeLEDMode?
    let conflict: Bool
    let busy: Bool
    let showsTitle: Bool
    /// 组件内轻提示（v1.10 M2；nil = 无提示不渲染。生命周期归属 App 侧控制器——
    /// 成功 5s 自动清 / 失败常驻，组件只呈现）。
    let feedback: String?
    let onApply: (MagSafeLEDMode) -> Void
    @State private var selection: MagSafeLEDMode

    public init(
        mode: MagSafeLEDMode?,
        conflict: Bool,
        busy: Bool,
        showsTitle: Bool = true,
        feedback: String? = nil,
        onApply: @escaping (MagSafeLEDMode) -> Void
    ) {
        self.mode = mode
        self.conflict = conflict
        self.busy = busy
        self.showsTitle = showsTitle
        self.feedback = feedback
        self.onApply = onApply
        _selection = State(initialValue: mode ?? .system)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsTitle {
                Text(CellarL10n.s("settings.section.magSafeLed"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }

            Text(CellarL10n.s("settings.magSafeLed.desc"))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)

            HStack {
                Text(CellarL10n.s("settings.magSafeLed.modeLabel"))
                    .font(.body)
                Spacer()
                Picker(CellarL10n.s("settings.magSafeLed.modeLabel"), selection: $selection) {
                    ForEach([MagSafeLEDMode.system, .off, .green, .amber], id: \.self) { m in
                        Text(modeLabel(m)).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)
                .disabled(busy)
            }

            if conflict {
                Text(CellarL10n.s("settings.magSafeLed.conflict"))
                    .font(.caption)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let feedback {
                // 轻提示行（v1.10 M2）：布局照冲突提示行先例（caption + 自适应换行）。
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: mode) { new in
            // daemon 值变化 → 无条件重播种（回包驱动，方案 §4；单参 onChange
            // 形态——项目 macOS 13 目标，照 FanSectionView:217 先例）。
            if let new { selection = new }
        }
        .onChange(of: selection) { new in
            // 发送侧 guard：新值 ≠ daemon 现值才发送（防 echo 回灌）。
            if new != mode { onApply(new) }
        }
    }

    private func modeLabel(_ m: MagSafeLEDMode) -> String {
        switch m {
        case .system: return CellarL10n.s("settings.magSafeLed.mode.system")
        case .off: return CellarL10n.s("settings.magSafeLed.mode.off")
        case .green: return CellarL10n.s("settings.magSafeLed.mode.green")
        case .amber: return CellarL10n.s("settings.magSafeLed.mode.amber")
        }
    }
}
