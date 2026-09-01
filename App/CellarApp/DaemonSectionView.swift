import CellarCore
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
            Text("守护进程：\(statusText) · 路线：\(routeText)")
                .font(.callout)
                .fontWeight(.medium)

            if !guidanceText.isEmpty {
                Text(guidanceText)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if installer.anomaly {
                Text("异常：守护进程可达，但本 app 内未找到嵌入配置（可能由另一副本注册）")
                    .font(.caption)
                    .foregroundStyle(theme.warning)
            }

            if let error = installer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(theme.alert)
            }

            // 位置提示（spike 局限 1.9）：注册跟随 .app 位置，移动/删除后需重新注册。
            Text("提示：已注册的守护进程跟随 Cellar.app 位置；移动或删除应用后请重新安装。")
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
        if installChecking { return "检查中…" }
        switch installer.registration {
        case .enabled: return "卸载守护进程"
        case .pending: return "等待系统授权…"
        case .notRegistered: return "安装守护进程"
        }
    }

    private var statusText: String {
        switch installer.registration {
        case .notRegistered: return "未注册"
        case .pending: return "等待系统授权…"
        case .enabled: return "已启用"
        }
    }

    private var routeText: String {
        switch installer.route {
        case .appManaged: return "App 托管"
        case .manual: return "手工路线"
        case .unknown: return "未知"
        }
    }

    /// 四象限文案（§2.2 表格逐行对应）。
    private var guidanceText: String {
        switch installer.guidance {
        case .normalInstall:
            return "守护进程未安装。点击「安装守护进程」注册，首次需在系统设置中批准。"
        case .running:
            return "守护进程随系统托管运行中。"
        case .migrateFromLegacy:
            return "检测到手工安装的守护进程。请先运行 sudo cellar uninstall，再点击「安装守护进程」。"
        case .cleanMixedState:
            return "检测到手工安装残留与托管注册并存。请先在本面板卸载，再运行 sudo cellar uninstall 清理残留，最后重新安装。"
        }
    }
}