import CellarCore
import CellarUI
import Sparkle
import SwiftUI

// MARK: - Sparkle 更新器注入（组合根 → 关于页；0.23.3 §1.4）

private struct CellarUpdaterKey: EnvironmentKey {
    /// 缺省 nil：预览/检查工具等未注入上下文落到禁用态；App 在 Window scene 注入
    /// 组合根幸存实例的 updater（statsSampler 先例——CellarApp.swift）。
    static let defaultValue: SPUUpdater? = nil
}

extension EnvironmentValues {
    /// Sparkle 更新器（SPUStandardUpdaterController.updater）：关于页「检查更新」
    /// 唯一入口——标准更新窗（安装/跳过此版本/稍后提醒）由 Sparkle 承载。
    var cellarUpdater: SPUUpdater? {
        get { self[CellarUpdaterKey.self] }
        set { self[CellarUpdaterKey.self] = newValue }
    }
}

/// 关于分节内容（Phase 5 v1.2 §4.2 自 SettingsView 内 private AboutTab 提取，
/// R1 P1-1——设置窗 Tab 与主窗口「外观与关于」页共用的共享子视图）：App/daemon
/// 版本（不匹配 = 既有 stale 语义警示）+ 复制诊断摘要（App/daemon 版本、注册态、
/// 连接态、风格，贴剪贴板）+ 尾部数据源说明行（UD-2：口径说明入「关于」页——
/// IO 直读只读监测，不写 SMC）。
///
/// ⚠️ 不含 ScrollView / 内容理想高测量 / `@Binding contentHeight` 成帧——
/// 这些留在设置窗 Tab 包装层（R1 P1-1：主窗口自由窗口语境无意义）。
/// 0.23.3 §2：自研更新呈现（新版本行/三态反馈/失败态/下载按钮）随 UpdateChecker
/// 退役删除——「检查更新」改接 Sparkle 标准更新窗（EdDSA 验包，§1.4）。
struct AboutSections: View {
    @EnvironmentObject private var statusController: StatusController
    @EnvironmentObject private var loginItems: LoginItemController
    @EnvironmentObject private var styleController: StyleController
    @Environment(\.cellarUpdater) private var updater
    @Environment(\.cellarTheme) private var theme
    /// 摘要已复制的轻反馈（2s 后自动清除）。
    @State private var copied = false

    var body: some View {
        Form {
            // v1.2 视觉打磨两节（§2.2）：行序不变，节头一律 CellarL10n.s 构造
            // （裸 key 在 App target 查不到会渲染裸字符串，R1 P3 红线）。
            Section {
                LabeledContent(CellarL10n.s("settings.appVersion"), value: appVersion)

                LabeledContent(CellarL10n.s("settings.daemonVersion"), value: daemonVersionText)

                // 版本不匹配警示（既有 stale 语义复用：版本行 ≠ 期望值 → 提示重装）。
                if daemonMismatch {
                    Text(CellarL10n.s("settings.versionMismatch"))
                        .font(.caption)
                        .foregroundStyle(theme.alert)
                }

                LabeledContent(CellarL10n.s("settings.connectionStatus"), value: connectionText)
                // 用户可见行用本地化展示名；原始存储值只进诊断摘要（排障需要）。
                // 全风格映射（UD-7：二元 ternary 在第三风格下会误显「原生」）。
                LabeledContent(CellarL10n.s("settings.panelStyle"), value: styleDisplayName)
                // 0.23.3 §1.4：「检查更新」→ Sparkle 标准更新窗（每日自动检查 +
                // 不自动下载安装；出站口径 = appcast GET + 用户确认后的更新包
                // 下载，SECURITY.md 同批改写）。updater 缺席（未注入语境）→
                // 按钮禁用（诚实呈现——不静默 no-op）。
                Button(CellarL10n.s("about.checkForUpdates")) {
                    updater?.checkForUpdates()
                }
                .disabled(updater == nil)
            } header: {
                Text(CellarL10n.s("settings.section.version"))
            }

            Section {
                Button(copied ? CellarL10n.s("settings.copied") : CellarL10n.s("settings.copySummary")) { copyDiagnostics() }
            } header: {
                Text(CellarL10n.s("settings.section.diagnostics"))
            }

            // 数据源说明行（UD-2 尾部增补，M3）：口径声明入共享关于内容——
            // 设置窗与主窗口关于页同源展示，纯只读监测语义自重声明。
            Section {
                Text(CellarL10n.s("about.datasource"))
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? CellarL10n.s("common.unknown")
    }

    private var daemonVersionText: String {
        statusController.daemonStatus?.version ?? CellarL10n.s("settings.unknownVersion")
    }

    /// daemon 版本与内嵌期望值不一致（首查前不判定，防初始化期误报）。
    private var daemonMismatch: Bool {
        guard let version = statusController.daemonStatus?.version else { return false }
        return version != DaemonXPC.daemonVersion
    }

    private var connectionText: String {
        switch statusController.connection {
        case .connected: return CellarL10n.s("settings.connected")
        case .unreachable: return CellarL10n.s("settings.unreachable")
        case .unknown: return CellarL10n.s("common.unknown")
        }
    }

    /// 风格展示名映射（UD-7：二元 ternary 修复为 switch 三 case 穷举，新 case
    /// 漏臂 = 编译错——全库唯一允许的风格枚举分支点）。styleController.style 已
    /// 经 validating 收敛为非可选（未知值回落 native），此处无 nil 面。
    private var styleDisplayName: String {
        switch styleController.style {
        case .native: return CellarL10n.s("settings.styleNative")
        case .amber: return CellarL10n.s("settings.styleAmber")
        case .industrial: return CellarL10n.s("settings.styleIndustrial")
        }
    }

    /// 诊断摘要贴剪贴板（NSPasteboard；注册态经控制器投影，不走 SMAppService——
    /// View 不直呼系统服务，评审 P2-2 同款纪律）。摘要为排障用途，版本号等
    /// 原始值保留（约等号语义），行文经 CellarL10n 本地化。
    private func copyDiagnostics() {
        let registration: String = {
            switch loginItems.registration {
            case .enabled: return CellarL10n.s("settings.regEnabled")
            case .requiresApproval: return CellarL10n.s("about.regApproval")
            case .notRegistered: return CellarL10n.s("common.notRegistered")
            case .unknown: return CellarL10n.s("about.regUnknown")
            }
        }()
        let daemonStatusText = daemonMismatch
            ? CellarL10n.s("about.mismatch", DaemonXPC.daemonVersion)
            : CellarL10n.s("about.match")
        let summary = [
            CellarL10n.s("about.appVersionLine", appVersion),
            CellarL10n.s("about.daemonLine", daemonVersionText, daemonStatusText),
            CellarL10n.s("about.loginItemLine", registration),
            CellarL10n.s("about.connectionLine", connectionText),
            CellarL10n.s("about.styleLine", styleController.style.rawValue),
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
