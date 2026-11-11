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
    @EnvironmentObject private var statusController: StatusController
    @Environment(\.cellarTheme) private var theme

    /// 安装复检进行中（统一 wrapper「检查中」态，§2.2 P2-3）。
    @State private var installChecking = false

    /// 卸载确认臂（0.23.7 B2-1）：enabled 态主按钮点击先展开内嵌确认块，确认才
    /// 真正卸载。页面级 @State——页面重建即清（残留态无跨页滞留面）。
    @State private var showUninstallConfirm = false

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

            // 0.20.1 §3.2：损坏 BTM 记录形态（App 托管 ∧ 反复 spawn 失败）——独立
            // 引导行（独立 @Published 检出，不动 MigrationGuidance 四象限枚举）。
            // 0.23.22 §1.2 块内二分：升级失配精确形态（stalePinSuspected 检出）→
            // 精确行 + 一键重注册（轻量路径——通用行指引 sudo sfltool resetbtm 对
            // 本形态是误导性重锤：BTM 记录未损坏，resetbtm 反清全部良性记录）；
            // 其余损坏形态维持通用行原文案原样式。
            if installer.btmCorrupted {
                if installer.stalePinDetected {
                    Text(CellarL10n.s("panel.daemon.stalePin"))
                        .font(.caption)
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(CellarL10n.s("panel.daemon.reRegister")) {
                        installer.reRegister()
                    }
                    .controlSize(.small)
                    .disabled(installer.busy)
                } else {
                    Text(CellarL10n.s("panel.daemon.btmCorrupted"))
                        .font(.caption)
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 0.23.18 §2.6② 随批 2：BTM 锚点漂移疑似行（btmCorrupted 行后同形态
            // ——特征态 = 已启用 ∧ 路线未知 ∧ XPC 失联，btmAnchorDriftSuspected
            // 纯函数在 CellarCore DaemonRegistration.swift；措辞「疑似」如实——
            // launchctl print 瞬态失败可能误报，refresh 重开面板自纠，不做去抖）。
            if btmAnchorDriftSuspected(
                registration: installer.registration,
                route: installer.route,
                connection: statusController.connection
            ) {
                Text(CellarL10n.s("panel.daemon.btmDrift"))
                    .font(.caption)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
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

            // 0.23.7 B2-1：enabled 态卸载两步确认——主按钮原直呼 installer.uninstall()
            // （单步破坏性操作，误触即停止限充管理并恢复系统默认充电行为）。照放电
            // 确认块先例（PanelSections dischargeSection：confirmationDialog 弹出会
            // 收起 MenuBarExtra，确认后面板已关——内嵌展开保持窗口常驻，警告信息
            // 同等显著）臂切换：确认块替代原按钮位置展开。
            if installer.registration == .enabled, showUninstallConfirm {
                VStack(alignment: .leading, spacing: 6) {
                    Text(CellarL10n.s("panel.daemon.uninstallWarning"))
                        .font(.caption)
                        .foregroundStyle(theme.warning)
                    HStack(spacing: 8) {
                        Button(CellarL10n.s("common.confirm")) {
                            showUninstallConfirm = false
                            installer.uninstall()
                        }
                        .controlSize(.small)
                        .disabled(installer.busy)
                        Button(CellarL10n.s("common.back")) {
                            showUninstallConfirm = false
                        }
                        .controlSize(.small)
                    }
                }
            } else {
                Button(buttonTitle) {
                    if installer.registration == .enabled {
                        showUninstallConfirm = true
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
            }

            // pending 态残留注册出口（0.3.2，BTM 事故缺口）：待授权记录损坏时
            // （反复授权后仍 spawn 失败），用户此前无任何出口——本按钮注销 SMAppService
            // 记录回到 notRegistered，可重装。正常授权流程不受影响（按钮独立于主按钮）。
            // 0.23.7 B2-1 设计决策：本按钮**不加确认**（plan §0 非目标）——故障态
            // 恢复出口（授权流程已损坏），加摩擦适得其反，与 enabled 态主按钮的
            // 两步确认分立。
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
    /// 0.4.1 批混合态弱化：手工 daemon 健康运行（route==manual ∧ XPC connected）
    /// 时，migrate/cleanMixed 两象限降级为说明性文案（功能不受影响）——文案按
    /// 象限拆分：migrate 象限无托管残留（registration==notRegistered），不含残留句
    /// （快审 R1 P1）；cleanMixed 象限保留残留句 + 面板卸载指引。daemon 失联/
    /// 未运行时维持原文案（此时残留确有风险）。
    private var guidanceText: String {
        guard installer.loaded else { return "" }
        let manualHealthy = installer.route == .manual
            && statusController.connection == .connected
        switch installer.guidance {
        case .normalInstall:
            return CellarL10n.s("panel.daemon.guidance.normal")
        case .running:
            return CellarL10n.s("panel.daemon.guidance.running")
        case .migrateFromLegacy:
            return manualHealthy
                ? CellarL10n.s("panel.daemon.guidance.manualHealthy")
                : CellarL10n.s("panel.daemon.guidance.migrate")
        case .cleanMixedState:
            return manualHealthy
                ? CellarL10n.s("panel.daemon.guidance.cleanMixedHealthy")
                : CellarL10n.s("panel.daemon.guidance.cleanMixed")
        }
    }
}