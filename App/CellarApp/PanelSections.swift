import CellarCore
import CellarUI
import SwiftUI

// MARK: - 面板分区（WP3 S5a 自 PanelView 迁出：PanelView 行数回落项目规 ≤400；
// 语汇消费按 §3.5 对账表，组件层零风格判断——G1）

/// 一次性动作区（WP2 §1.1 + WP2' §4.1 交付面）：
/// - 动作活跃 → 状态行（fullOnce「充满中…」/ discharge「放电中…当前 N% → 目标 M%」）
///   + 取消按钮；
/// - 无动作且 mode == active → 「充满一次」按钮（语汇 word(.actionFullOnce)——amber
///   值含「醒酒 · 」前缀，功能词后缀保留）+
///   WP2' 放电按钮（显示条件 §4.1 五条：daemonStatus != nil ∧ mode==active ∧
///   capabilities 含 discharge ∧ ext==true ∧ percent > upperLimit ∧ 无进行中动作）；
/// - capabilities 两态文案：nil（旧 daemon）= 升级提示（面板卸载重装）；[] = 机型
///   不支持（评审 P1-1 fail-closed 呈现）。
/// AX 标签用功能词（§4.1）。
struct ActionSectionView: View {
    @EnvironmentObject private var statusController: StatusController
    @Environment(\.cellarTheme) private var theme
    /// 放电确认对话框（外设断电警告 + 合盖外显睡眠提示，§4.1）。
    @State private var showDischargeConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isActionActive {
                if statusController.action?.kind == Discharge.dischargeToLimitKind {
                    dischargeProgressRow
                } else {
                    fullOnceProgressRow
                }
            } else if statusController.daemonStatus?.mode == "active" {
                Button {
                    statusController.fullOnce()
                } label: {
                    Label(theme.word(.actionFullOnce), systemImage: "bolt.fill")
                }
                .controlSize(.small)
                .disabled(statusController.busy)
                dischargeSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// fullOnce 进行中状态行（WP2 原形态）。
    private var fullOnceProgressRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(theme.success)
            Text(CellarL10n.s("panel.action.fullOnceProgress"))
                .font(.caption)
            Spacer(minLength: 4)
            Button(CellarL10n.s("common.cancel")) {
                statusController.cancelFullOnce()
            }
            .controlSize(.small)
            .disabled(statusController.busy)
        }
    }

    /// 放电进行中状态行（WP2' §4.1）：「放电中…当前 N% → 目标 M%」+ 取消。
    /// 当前 N% 数据源 = 1s telemetry 快照（优先）→ daemonStatus.lastPercent 兜底
    /// （与 PowerFlowView 同数据源纪律；目标 M% = 动作 targetPercent）。
    private var dischargeProgressRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(theme.success)
            Text(dischargeProgressText)
                .font(.caption)
            Spacer(minLength: 4)
            Button(CellarL10n.s("common.cancel")) {
                statusController.cancelDischarge()
            }
            .controlSize(.small)
            .disabled(statusController.busy)
        }
    }

    private var dischargeProgressText: String {
        let current = statusController.batterySnapshot?.percent
            ?? statusController.daemonStatus?.lastPercent
        let target = statusController.action?.targetPercent
        let currentText = current.map { "\($0)%" } ?? "--"
        let targetText = target.map { "\($0)%" } ?? "--"
        return CellarL10n.s("panel.action.dischargeProgress", currentText, targetText)
    }

    /// 放电区（按钮 + capabilities 两态文案；显示条件 §4.1 五条）。
    @ViewBuilder
    private var dischargeSection: some View {
        let capabilities = statusController.capabilities
        if capabilities == nil {
            // 旧 daemon 未上报能力：升级提示（stale 版本比对另有横幅通道）。
            Text(CellarL10n.s("panel.action.needUpgrade"))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        } else if capabilities?.contains(DaemonXPC.capabilityDischarge) != true {
            // 已上报但不含 discharge（Legacy 后端 / CHIE 缺席机器 / 探测失败）。
            Text(CellarL10n.s("panel.action.unsupported"))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        } else if canStartDischarge {
            if showDischargeConfirm {
                // 内嵌确认块（真机验收修正 2026-09-02：confirmationDialog 弹出时
                // MenuBarExtra 窗口被系统收起，确认后面板已关需重开——改面板内
                // 展开保持窗口常驻，警告信息同等显著）。
                VStack(alignment: .leading, spacing: 6) {
                    // §4.1 显著警告：外设断电 + 合盖外显睡眠。
                    Text(CellarL10n.s("panel.action.dischargeWarning"))
                        .font(.caption)
                        .foregroundStyle(theme.warning)
                    HStack(spacing: 8) {
                        Button(CellarL10n.s("panel.action.confirmDischarge")) {
                            showDischargeConfirm = false
                            statusController.dischargeToLimit()
                        }
                        .controlSize(.small)
                        .disabled(statusController.busy)
                        Button(CellarL10n.s("panel.action.back")) {
                            showDischargeConfirm = false
                        }
                        .controlSize(.small)
                    }
                }
            } else {
                Button {
                    showDischargeConfirm = true
                } label: {
                    Label(CellarL10n.s("panel.action.dischargeTitle"), systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
                .disabled(statusController.busy)
                .accessibilityLabel(CellarL10n.s("panel.action.dischargeAx"))
            }
        }
    }

    /// 放电按钮显示条件（§4.1 五条：daemonStatus 非 nil ∧ mode==active ∧
    /// capabilities 含 discharge ∧ ext==true ∧ percent > 上限 ∧ 无进行中动作；
    /// capabilities 两态已在上层分支消费）。
    private var canStartDischarge: Bool {
        guard let status = statusController.daemonStatus, status.mode == "active" else { return false }
        guard statusController.capabilities?.contains(DaemonXPC.capabilityDischarge) == true else { return false }
        guard statusController.action == nil else { return false }
        guard status.lastExternalConnected == true else { return false }
        guard let percent = status.lastPercent, percent > status.upperLimit else { return false }
        return true
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
            Toggle(CellarL10n.s("common.launchAtLogin"), isOn: Binding(
                get: { loginItems.launchAtLogin },
                set: { loginItems.toggle($0) }
            ))
            .disabled(loginItems.busy)
            if let feedback = loginItems.feedback {
                Text(feedback)
                    .font(.caption)
                    // 成功/失败配色不再按「已」中文前缀判定（反馈已本地化）——
                    // 控制器新发布 feedbackIsSuccess 判别位（S3 配套改动）。
                    .foregroundStyle(loginItems.feedbackIsSuccess ? theme.success : theme.alert)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 面板页脚（WP3 S5b：设置入口 + 退出，自 PanelView 底部行迁出）：「设置…」经
/// openSettings + NSApp.activate（真机验收修正 2026-09-02：LSUIElement app 的
/// Settings 窗口落在前台应用后面——SettingsLink 声式入口无激活钩子，改为按钮
/// 先把 App 带到前台再打开设置）；退出按钮语汇随风格（word(.quit)）。
struct PanelFooterView: View {
    @Environment(\.cellarTheme) private var theme
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // 无对齐框定：保持迁出前两行在面板纵向中轴的呈现（A 原生视觉零回归）。
        VStack(spacing: 14) {
            Button {
                // 先激活（设置窗口才能盖过其它应用），再开/前置 Settings。
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label(CellarL10n.s("panel.footerSettings"), systemImage: "gearshape")
            }
            Button(theme.word(.quit)) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
