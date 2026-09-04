import CellarCore
import CellarUI
import SwiftUI
import UserNotifications

/// 设置窗口（WP3 §4 定版三 Tab：外观 / 通用 / 关于；形态 = spike S1 定版的
/// 原生 Settings scene——组合根声明 + 面板 SettingsLink 入口）。外观 Tab 独立
/// 文件；关于 Tab 的风格展示行同为风格词元（白名单成员），本文件整体属 G1 白名单。
///
/// 高度治理（Phase 5 v1.2 §3.1 方案 B）：不猜高度，量——三 Tab 统一 ScrollView
/// 包装（ScrollView 向内容发 nil 提案，Form 回落理想高，测量才有真值），内容
/// 理想高经 contentHeightMeasurement 附着回写**按 Tab 分槽**的 @State，成帧
/// 读选中 Tab 的槽位 clamp(测量 + tab 条常数, 260...640)。
struct SettingsView: View {
    /// 设置 Tab 枚举（成帧按选中 Tab 分槽读值；Hashable = TabView(selection:) 要求）。
    private enum SettingsTab: Hashable {
        case appearance, general, about
    }

    /// 选中 Tab（TabView(selection:) 绑定）——**选中驱动成帧**：切 Tab 即触发
    /// body 重算，成帧不依赖窗格测量事件（见 contentHeights 的 WHY）。
    @State private var selection: SettingsTab = .general
    /// 各 Tab 内容理想高槽位（pt，含各 Tab Form 的 padding）：窗格**首次创建**
    /// 时经测量附着填充本槽（纪律见 reportContentHeight）；初始缺槽 = 0 → 成帧
    /// 落地下限 260（首帧占位）。分槽是切 Tab 高度正确性的根因修复——macOS
    /// TabView 对已创建窗格**保活缓存**，重访时窗格尺寸从未变化 → onAppear 不
    /// 重发、onChange(of: size) 无变化事件，共享标量会停留在上一个 Tab 的值
    /// （M2.5 走查复现：通用→外观「不缩」）；分槽 + 选中驱动后重访仅靠
    /// selection 变化即重算，窗格事件只在首次创建时负责填充槽位，同时消解原
    /// 多 Tab 共享标量的时序残差（方案 P3-2）。
    @State private var contentHeights: [SettingsTab: CGFloat] = [:]

    var body: some View {
        TabView(selection: $selection) {
            AppearanceTab(contentHeight: slotBinding(for: .appearance))
                .tag(SettingsTab.appearance)
                .tabItem { Label(CellarL10n.s("settings.appearance"), systemImage: "paintpalette") }
            GeneralTab(contentHeight: slotBinding(for: .general))
                .tag(SettingsTab.general)
                .tabItem { Label(CellarL10n.s("settings.general"), systemImage: "gearshape") }
            AboutTab(contentHeight: slotBinding(for: .about))
                .tag(SettingsTab.about)
                .tabItem { Label(CellarL10n.s("settings.about"), systemImage: "info.circle") }
        }
        // 成帧（§3.1 步骤 4）：高 = clamp(选中 Tab 内容理想高 + tab 条常数,
        // 260...640)。tab 条常数 30pt = ImageRenderer 三探针（零内容 / 100 /
        // 200 内容）交叉实测一致——TabView 顶部 tab 条与内容高无关；headless
        // 实测形态，真机偏差量级 ≤5pt 由成帧下限吸收。
        // 上限 640 防异常撑高；ScrollView 保留为 clamp 溢出兜底（风扇 stage2 +
        // 确认块 + hint 全开的极端态滚动）。下限 260 = M2.5 走查用户反馈
        // （2026-09-04）：360 下限时关于 Tab 缩后仍留空 ~130pt——260 后短 Tab
        // 残留 ≈ 260 − 短 Tab 理想高(~200) − 30 ≈ 30pt；通用（理想高 ~417+30）
        // 不受影响。初始打开无闪变的实测依据：测量在首帧绘制前收敛——走查
        // 「初始进入即短窗」佐证（R-3 关闭，无需更高下限兜闪变）。
        .frame(
            width: 420,
            height: settingsFrameHeight(contentHeights[selection] ?? 0)
        )
    }

    /// 槽位绑定（缺槽 = 0——成帧下限 260 兜底首帧占位；签名 = Binding<CGFloat>，
    /// 三 Tab 的绑定接收方式不变）。
    private func slotBinding(for tab: SettingsTab) -> Binding<CGFloat> {
        Binding(
            get: { contentHeights[tab] ?? 0 },
            set: { contentHeights[tab] = $0 }
        )
    }

    /// 成帧高（内容理想高 + tab 条常数，夹 260...640）。
    private func settingsFrameHeight(_ contentHeight: CGFloat) -> CGFloat {
        min(max(contentHeight + 30, 260), 640)
    }
}

// MARK: - 测量回写纪律（§3.1 步骤 2/3，三 Tab 共用；AppearanceTab.swift 同用）

/// 内容理想高回写（三 Tab 共用纪律）：
/// - 测量值 < 100 忽略——防布局未收敛的首帧 0/退化值回写（三 Tab 真实理想高
///   均 > 200，阈值安全，量纲 = pt）；
/// - |Δ| ≥ 1 才回写——防抖环，亚像素抖动不触发 frame 更新；
/// - 禁动画直切（高度随选中 Tab 直跳，不插过渡动画）。
func reportContentHeight(_ height: CGFloat, to binding: Binding<CGFloat>) {
    guard height >= 100 else { return }
    guard abs(height - binding.wrappedValue) >= 1 else { return }
    var transaction = Transaction()
    transaction.animation = nil
    withTransaction(transaction) {
        binding.wrappedValue = height
    }
}

/// 内容理想高测量附着：必须贴在 ScrollView 内的 Form 上（background GeometryReader
/// 取 Form 落位后的实际尺寸）——裸 Form 对固定高度提案贪婪填充，测不到真值；
/// 禁止插在 ScrollView 与 Form 之间（GeometryReader 在非受限提案下的贪婪尺寸
/// 行为会引入新的不稳态）。clamp 后内容高稳定，无几何反馈环。
extension View {
    func contentHeightMeasurement(into binding: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        reportContentHeight(proxy.size.height, to: binding)
                    }
                    .onChange(of: proxy.size.height) { _, newHeight in
                        reportContentHeight(newHeight, to: binding)
                    }
            }
        }
    }
}

// MARK: - 通用 Tab（WP3 §4）：开机启动双入口（与面板同源）+ 登录项注册态/
// 重新注册 + 通知授权态（onAppear 直查系统，不经 NotificationService——非
// Observable 且组合根私有，评审 P2-2 定版；App 不自管通知开关，授权是系统域）。

private struct GeneralTab: View {
    @EnvironmentObject private var loginItems: LoginItemController
    @EnvironmentObject private var statusController: StatusController
    @Environment(\.cellarTheme) private var theme
    /// 内容理想高回写绑定（SettingsView 共享成帧源，见 reportContentHeight）。
    @Binding private var contentHeight: CGFloat
    /// 通知授权态（nil = 查询中；getNotificationSettings 异步回主线程刷新）。
    @State private var notificationAuthorized: Bool?
    /// 自动放电开启两步内嵌确认块（nil = 未展开；确认/取消后关闭）。
    @State private var autoDischargeConfirming = false

    init(contentHeight: Binding<CGFloat>) {
        _contentHeight = contentHeight
    }

    var body: some View {
        // v1.1：内容装进 ScrollView（风扇区加入后定高帧两次裁切——定高猜高度
        // 不可持续，滚动是 macOS 高个设置页的标准形态）；v1.2：Form 上附着内容
        // 理想高测量（成帧由此驱动，ScrollView 退为 clamp 溢出兜底）。
        ScrollView {
            Form {
                // v1.2 视觉打磨三节（§2.1）：控件/绑定/回调原样搬入节内，节头一律
                // CellarL10n.s 构造——App target 查不到 CellarUI bundle 的裸 key
                // 字面量会渲染裸字符串，无机械门拦截（R1 P3 红线）。
                Section {
                    Toggle(CellarL10n.s("common.launchAtLogin"), isOn: Binding(
                        get: { loginItems.launchAtLogin },
                        set: { loginItems.toggle($0) }
                    ))
                    .disabled(loginItems.busy)

                    LabeledContent(CellarL10n.s("settings.registrationStatus")) {
                        HStack {
                            Text(registrationText)
                            // 修复路径落控制器（评审 P2-2）；已注册态按钮无意义，禁用。
                            Button(CellarL10n.s("settings.reregister")) { loginItems.reregister() }
                                .disabled(loginItems.busy || loginItems.registration == .enabled)
                        }
                    }

                    LabeledContent(CellarL10n.s("settings.notifications")) {
                        HStack {
                            Text(notificationText)
                            Button(CellarL10n.s("settings.openSystemSettings")) { openNotificationSettings() }
                        }
                    }

                    if let feedback = loginItems.feedback {
                        Text(feedback)
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }
                } header: {
                    Text(CellarL10n.s("settings.section.general"))
                }

                // WP2' 自动放电组——无头节（R1 P1-1 定案）：开关标签「自动放电」
                // 自任标题，带节头必同文相邻重复；仅取节间距分组。开关绑定 daemonStatus
                // 单一真相（daemon 确认后状态回传翻转）；开启两步内嵌确认块，关闭
                // 直通（关是安全方向）。
                Section {
                    Toggle(CellarL10n.s("settings.autoDischarge"), isOn: Binding(
                        get: { statusController.daemonStatus?.autoDischargeEnabled == true },
                        set: { toggleAutoDischarge($0) }
                    ))
                    .disabled(autoDischargeCapabilityAvailable == false)

                    // 开关旁一句话说明（code-review P2-3：消费 desc key，防空目录死项）。
                    Text(CellarL10n.s("settings.autoDischarge.desc"))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)

                    // 能力门控提示（三态惯例：capabilities nil = 旧 daemon 需升级；已上报
                    // 但缺 autoDischarge = 当前机型或版本不支持；含 = 可用且无提示）。
                    if let hint = autoDischargeGateHint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }

                    // 开启两步内嵌确认块（同 ActionSectionView 确认形态）：弹出前已刷新一次
                    // status——upper/hys 取 daemonStatus 现值，缩 60s 陈旧窗（R2 P3）。
                    if autoDischargeConfirming {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(CellarL10n.s("settings.autoDischarge.warning"))
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                            HStack {
                                Button(CellarL10n.s("settings.autoDischarge.confirm")) { confirmAutoDischarge() }
                                    .disabled(statusController.busy)
                                Button(CellarL10n.s("common.cancel")) { autoDischargeConfirming = false }
                            }
                        }
                    }
                }

                Section {
                    // Phase 5 v1.1：风扇智能降温区（参数驱动组件，照校准区先例——开关两步
                    // 内嵌确认/策略 Picker/阈值与转速滑杆/twoStage 条件参数/九态状态行；
                    // 旧 daemon（fan==nil）控件禁用 + 升级提示）。v1.2：showsTitle false——
                    // 标题由节头「智能风扇降温」承担，组件自身标题关掉防同文重复。
                    FanSectionView(
                        fan: statusController.fanStatus,
                        busy: statusController.busy,
                        onApply: { statusController.setFan($0) },
                        showsTitle: false
                    )
                } header: {
                    Text(CellarL10n.s("settings.section.fan"))
                }
            }
            .padding()
            .contentHeightMeasurement(into: $contentHeight)
            .onAppear {
                loginItems.load()
                loginItems.refreshRegistration()
                queryNotificationAuthorization()
            }
        }
    }

    // MARK: - WP2' 自动放电

    /// 能力门控：capabilities 含 autoDischarge 才可用（nil = 旧 daemon 未上报，
    /// [] = 已上报但不含能力）。
    private var autoDischargeCapabilityAvailable: Bool {
        statusController.capabilities?.contains(DaemonXPC.capabilityAutoDischarge) == true
    }

    /// 禁用态提示（nil = 可用，无提示）。capabilities == nil → 需升级守护进程
    /// （复用面板既有 needUpgrade 文案 key——同三态惯例）；缺能力 → 不支持。
    private var autoDischargeGateHint: String? {
        guard !autoDischargeCapabilityAvailable else { return nil }
        if statusController.capabilities == nil {
            return CellarL10n.s("panel.action.needUpgrade")
        }
        return CellarL10n.s("settings.autoDischarge.unsupported")
    }

    /// 开关动作：开启 → 先刷新一次 status（缩窗）再展开确认块；关闭直通。
    private func toggleAutoDischarge(_ enabled: Bool) {
        guard autoDischargeCapabilityAvailable else { return }
        if enabled {
            statusController.refreshNow()
            autoDischargeConfirming = true
        } else {
            autoDischargeConfirming = false
            applyAutoDischarge(false)
        }
    }

    /// 确认开启：upper/hys 取 daemonStatus 现值（单一真相），auto 显式 true。
    private func confirmAutoDischarge() {
        guard let status = statusController.daemonStatus else {
            autoDischargeConfirming = false
            return
        }
        autoDischargeConfirming = false
        statusController.applyLimits(
            upperLimit: status.upperLimit, hysteresis: status.hysteresis, autoDischarge: true
        )
    }

    /// 关闭直通（经 setLimits auto=0 持久化；daemon 缺席保持语义下显式传 false
    /// 即关——在轨自动放电不被打断，属设计）。
    private func applyAutoDischarge(_ enabled: Bool) {
        guard let status = statusController.daemonStatus else { return }
        statusController.applyLimits(
            upperLimit: status.upperLimit, hysteresis: status.hysteresis, autoDischarge: enabled
        )
    }

    private var registrationText: String {
        switch loginItems.registration {
        case .enabled: return CellarL10n.s("settings.regEnabled")
        case .requiresApproval: return CellarL10n.s("settings.regApproval")
        case .notRegistered: return CellarL10n.s("common.notRegistered")
        case .unknown: return CellarL10n.s("common.querying")
        }
    }

    private var notificationText: String {
        guard let authorized = notificationAuthorized else { return CellarL10n.s("common.querying") }
        return authorized ? CellarL10n.s("settings.notifAuthorized") : CellarL10n.s("settings.notifDenied")
    }

    /// 通知授权态直查（异步回调回主线程刷新；拒授权属常态非错误，不上告警色）。
    private func queryNotificationAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let authorized = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                notificationAuthorized = authorized
            }
        }
    }

    /// 打开系统通知设置（App 不自管通知开关——授权是系统域，评审 P2-2 定版 URL）。
    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 关于 Tab（WP3 §4）：App/daemon 版本（不匹配 = 既有 stale 语义警示）+
// 复制诊断摘要（App/daemon 版本、注册态、连接态、风格，贴剪贴板）。

private struct AboutTab: View {
    @EnvironmentObject private var statusController: StatusController
    @EnvironmentObject private var loginItems: LoginItemController
    @EnvironmentObject private var styleController: StyleController
    @Environment(\.cellarTheme) private var theme
    /// 内容理想高回写绑定（SettingsView 共享成帧源，见 reportContentHeight）。
    @Binding private var contentHeight: CGFloat
    /// 摘要已复制的轻反馈（2s 后自动清除）。
    @State private var copied = false

    init(contentHeight: Binding<CGFloat>) {
        _contentHeight = contentHeight
    }

    var body: some View {
        // 结构性包装（§3.1 步骤 1）：三 Tab 统一 ScrollView——裸 Form 对固定
        // 高度提案贪婪填充（测得值恒等于当前帧高，短 Tab 永不收缩），ScrollView
        // 向内容发 nil 提案 Form 才回落理想高；表单内容零变化。
        ScrollView {
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
                    LabeledContent(CellarL10n.s("settings.panelStyle"),
                                   value: styleController.style == .amber
                                       ? CellarL10n.s("settings.styleAmber")
                                       : CellarL10n.s("settings.styleNative"))
                } header: {
                    Text(CellarL10n.s("settings.section.version"))
                }

                Section {
                    Button(copied ? CellarL10n.s("settings.copied") : CellarL10n.s("settings.copySummary")) { copyDiagnostics() }
                } header: {
                    Text(CellarL10n.s("settings.section.diagnostics"))
                }
            }
            .padding()
            .contentHeightMeasurement(into: $contentHeight)
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
