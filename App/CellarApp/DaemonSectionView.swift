import CellarCore
import CellarUI
import SwiftUI

/// 守护进程安装区（WP5 §2.2 统一安装 wrapper 接入后从 PanelView 拆出）：
/// 状态行 + 主按钮 + 四象限文案 + anomaly 行 + lastError + 位置提示。
/// 主按钮 install 触发一律先过 wrapper（后台扫描复检）——clear/本会话已确认
/// generic 才放行 install；exact/未确认 generic → 引导页教学/软警示。
struct DaemonSectionView: View {
    @EnvironmentObject private var installer: DaemonInstaller
    @EnvironmentObject private var onboarding: OnboardingController
    @Environment(\.cellarTheme) private var theme

    /// 安装复检进行中（统一 wrapper「检查中」态，§2.2 P2-3）。
    @State private var installChecking = false

    var body: some View {
        VStack(spacing: 8) {
            Text(CellarL10n.s("panel.daemon.title", statusText, routeText))
                .font(.callout)
                .fontWeight(.medium)

            if !guidanceText.isEmpty {
                Text(guidanceText)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if installer.anomaly {
                Text(CellarL10n.s("panel.daemon.anomaly"))
                    .font(.caption)
                    .foregroundStyle(theme.warning)
            }

            if let error = installer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(theme.alert)
            }

            // 位置提示（spike 局限 1.9）：注册跟随 .app 位置，移动/删除后需重新注册。
            Text(CellarL10n.s("panel.daemon.tip"))
                .font(.caption2)
                .foregroundStyle(theme.tertiaryText)

            Button(buttonTitle) {
                if installer.registration == .enabled {
                    installer.uninstall()
                } else {
                    installViaGate()   // 统一安装 wrapper（§2.2 P2-3）
                }
            }
            // 迁移象限禁用安装：防用户绕过引导直接安装，制造手工+托管混合态（评审 P2-6）。
            .disabled(
                installer.busy
                    || installChecking
                    || installer.registration == .pending
                    || installer.guidance == .migrateFromLegacy
            )

            // pending 态残留注册出口（0.3.2，BTM 事故缺口）：待授权记录损坏时
            // （反复授权后仍 spawn 失败），用户此前无任何出口——本按钮注销 SMAppService
            // 记录回到 notRegistered，可重装。正常授权流程不受影响（按钮独立于主按钮）。
            if installer.registration == .pending {
                Button(CellarL10n.s("panel.daemon.removeResidual"), role: .destructive) {
                    installer.uninstall()
                }
                .controlSize(.small)
                .disabled(installer.busy)
            }
        }
    }

    /// 统一安装 wrapper：点击 → 禁用 + 「检查中」→ 后台扫描 → 放行才 install
    /// （与引导 step 3 同构；exact → 引导页教学文案，installer.install 不执行）。
    private func installViaGate() {
        guard !installChecking, !installer.busy else { return }
        installChecking = true
        Task { @MainActor in
            let outcome = await onboarding.checkInstallGate()
            installChecking = false
            if outcome == .proceed {
                installer.install()
            }
        }
    }

    private var buttonTitle: String {
        if installChecking { return CellarL10n.s("common.checking") }
        switch installer.registration {
        case .enabled: return CellarL10n.s("panel.daemon.uninstall")
        case .pending: return CellarL10n.s("common.waitingApproval")
        case .notRegistered: return CellarL10n.s("common.installDaemon")
        }
    }

    private var statusText: String {
        // 诚实初始化态（验收事故回归）：refresh 挂起时 loaded 永假，
        // 不再以「未注册」初始值误导（用户实际不知道 daemon 是否在管）。
        guard installer.loaded else { return CellarL10n.s("panel.daemon.initializing") }
        switch installer.registration {
        case .notRegistered: return CellarL10n.s("common.notRegistered")
        case .pending: return CellarL10n.s("common.waitingApproval")
        case .enabled: return CellarL10n.s("panel.daemon.enabledStatus")
        }
    }

    private var routeText: String {
        switch installer.route {
        case .appManaged: return CellarL10n.s("panel.daemon.appManaged")
        case .manual: return CellarL10n.s("panel.daemon.manualRoute")
        case .unknown: return CellarL10n.s("common.unknown")
        }
    }

    /// 四象限文案（§2.2 表格逐行对应；全部经 CellarL10n——含「检测到手工安装
    /// 残留与托管注册并存…」迁移守卫文案）。
    private var guidanceText: String {
        guard installer.loaded else { return "" }
        switch installer.guidance {
        case .normalInstall:
            return CellarL10n.s("panel.daemon.guidance.normal")
        case .running:
            return CellarL10n.s("panel.daemon.guidance.running")
        case .migrateFromLegacy:
            return CellarL10n.s("panel.daemon.guidance.migrate")
        case .cleanMixedState:
            return CellarL10n.s("panel.daemon.guidance.cleanMixed")
        }
    }
}