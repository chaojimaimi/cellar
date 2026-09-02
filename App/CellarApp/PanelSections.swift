import CellarCore
import CellarUI
import SwiftUI

// MARK: - 面板分区（WP3 S5a 自 PanelView 迁出：PanelView 行数回落项目规 ≤400；
// 语汇消费按 §3.5 对账表，组件层零风格判断——G1）

/// 一次性动作区（WP2 §1.1 交付面）：动作活跃 → 状态行 + 取消按钮；无动作且
/// mode == active → 「充满一次」按钮（语汇 word(.actionFullOnce)——amber 值含
/// 「醒酒 · 」前缀，功能词后缀保留；§1.7：活跃中控制反馈不 B 化，保持原文）。
struct ActionSectionView: View {
    @EnvironmentObject private var statusController: StatusController
    @Environment(\.cellarTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isActionActive {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(theme.success)
                    Text("充满中…预计 100% 后自动恢复")
                        .font(.caption)
                    Spacer(minLength: 4)
                    Button("取消") {
                        statusController.cancelFullOnce()
                    }
                    .controlSize(.small)
                    .disabled(statusController.busy)
                }
            } else if statusController.daemonStatus?.mode == "active" {
                Button {
                    statusController.fullOnce()
                } label: {
                    Label(theme.word(.actionFullOnce), systemImage: "bolt.fill")
                }
                .controlSize(.small)
                .disabled(statusController.busy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 动作活跃判定（滑杆/预设/总开关的禁用依据；PanelView 同语义各持私有计算）。
    private var isActionActive: Bool {
        statusController.action != nil
    }
}

/// 登录项开关区（规格 §2.4 接线：SMAppService.loginItem + AppConfigStore 持久化；
/// WP3 S5a 自 PanelView 迁出，文案与布局零变化）。
struct LoginItemSectionView: View {
    @EnvironmentObject private var loginItems: LoginItemController
    @Environment(\.cellarTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("开机启动 Cellar", isOn: Binding(
                get: { loginItems.launchAtLogin },
                set: { loginItems.toggle($0) }
            ))
            .disabled(loginItems.busy)
            if let feedback = loginItems.feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(feedback.hasPrefix("已") ? theme.success : theme.alert)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 面板页脚（WP3 S5b：设置入口 + 退出，自 PanelView 底部行迁出）：「设置…」走
/// 原生 SettingsLink（spike S1 定版形态）；退出按钮语汇随风格（word(.quit)——
/// amber「封存退出」，demo footer；native 原文兜底语义见 Theme.word）。
struct PanelFooterView: View {
    @Environment(\.cellarTheme) private var theme

    var body: some View {
        // 无对齐框定：保持迁出前两行在面板纵向中轴的呈现（A 原生视觉零回归）。
        VStack(spacing: 14) {
            SettingsLink {
                Label("设置…", systemImage: "gearshape")
            }
            Button(theme.word(.quit)) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
