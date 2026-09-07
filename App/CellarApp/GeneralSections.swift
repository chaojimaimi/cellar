import CellarCore
import CellarUI
import SwiftUI
import UserNotifications

/// 通用分节内容（M3.5 工单 4 自 SettingsView 内 private GeneralTab 提取——设置
/// 窗退役后并入主窗口通用页；登录项开关 + 注册态 + 通知授权 + 自动放电组 +
/// 风扇组全部随迁，行为零变化）。
///
/// v1.8 走查批 F4 布局重构（行为零变化，只动布局容器）：macOS Form 各 Section
/// 的 label 列独立自适应——Toggle 全宽行与 LabeledContent 双列行混用导致行起始
/// x 参差。改自定义分节：节头 13pt semibold secondaryText（key 复用
/// settings.section.*）+ 行栅格统一（标签列固定 150pt）——全部行同起点对齐；
/// 整块包卡片底（容器形态照校准/自动化页 panel 先例：panelBackground 底 +
/// 圆角 18 描边）。自动放电节保持无头（R1 P1-1 定案：开关标签「自动放电」自任
/// 标题，带节头必同文相邻重复）。
///
/// ⚠️ 不含 ScrollView / 内容理想高测量 / `@Binding contentHeight` 成帧——那些
/// 是设置窗成帧包装的专属装置，随设置窗一并退役（reportContentHeight /
/// contentHeightMeasurement 零残留）。
struct GeneralSections: View {
    @EnvironmentObject private var loginItems: LoginItemController
    @EnvironmentObject private var statusController: StatusController
    @EnvironmentObject private var displaySettings: DisplaySettingsController
    @Environment(\.cellarTheme) private var theme
    /// 通知授权态（nil = 查询中；getNotificationSettings 异步回主线程刷新）。
    @State private var notificationAuthorized: Bool?
    /// 自动放电开启两步内嵌确认块（nil = 未展开；确认/取消后关闭）。
    @State private var autoDischargeConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            generalSection
            autoDischargeSection
            fanSection
            thermalSection
            magSafeLedSection
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            if let panelBackground = theme.panelBackground { panelBackground }
        }
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.secondaryText.opacity(0.25)))
        .onAppear {
            loginItems.load()
            loginItems.refreshRegistration()
            queryNotificationAuthorization()
        }
    }

    // MARK: - 分节（节间 16 / 行距 10）

    /// 节头（R1 P3 红线：一律 CellarL10n.s 构造——App target 查不到 CellarUI
    /// bundle 的裸 key 字面量会渲染裸字符串，无机械门拦截；参数取
    /// LocalizationValue——调用点保持 key 字面量，与既有直调形态一致）。
    private func sectionHeader(_ key: String.LocalizationValue) -> some View {
        Text(CellarL10n.s(key))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
    }

    /// 标签:内容行（行栅格统一：标签列固定 150pt leading——全部标签行同起点，
    /// 治 Form 时代行起始 x 参差；firstTextBaseline 对齐——标签与内容首行基线
    /// 一致，多行内容不吊顶）。
    private func labelRow<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.body)
                .frame(width: 150, alignment: .leading)
            content()
        }
    }

    /// 通用节：开机启动开关（全宽 checkbox 行，起始 x=0 与标签列对齐）+
    /// 注册态/通知两行（标签:内容栅格）+ 反馈行。
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("settings.section.general")

            Toggle(CellarL10n.s("common.launchAtLogin"), isOn: Binding(
                get: { loginItems.launchAtLogin },
                set: { loginItems.toggle($0) }
            ))
            .disabled(loginItems.busy)

            // 0.18 T3 D-3d：菜单栏电池电量图标显隐（v1.11「标题栏」误解返工——
            // 开关迁菜单栏形态门控；默认关——开即菜单栏图标切「电池电量」形态，
            // 关即回现状状态符号；绑定形态照 launchAtLogin 行先例，loaded 前
            // 禁用防半程回写）。
            Toggle(CellarL10n.s("settings.menuBarBatteryIcon"), isOn: Binding(
                get: { displaySettings.menuBarBatteryIconVisible },
                set: { _ in displaySettings.toggleMenuBarBatteryIcon() }
            ))
            .disabled(!displaySettings.loaded)

            labelRow(CellarL10n.s("settings.registrationStatus")) {
                HStack {
                    Text(registrationText)
                    // 修复路径落控制器（评审 P2-2）；已注册态按钮无意义，禁用。
                    Button(CellarL10n.s("settings.reregister")) { loginItems.reregister() }
                        .disabled(loginItems.busy || loginItems.registration == .enabled)
                }
            }

            labelRow(CellarL10n.s("settings.notifications")) {
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
        }
    }

    /// 自动放电节（无头节，R1 P1-1 定案——开关标签「自动放电」自任标题）：
    /// 开关全宽行 + 说明行 + 能力门控提示 + 开启两步确认块，逻辑原样随迁。
    private var autoDischargeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // WP2' 自动放电组：开关绑定 daemonStatus 单一真相（daemon 确认后状态
            // 回传翻转）；开启两步内嵌确认块，关闭直通（关是安全方向）。
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
    }

    /// 风扇节：FanSectionView 原样嵌入（showsTitle false 保持——标题由节头
    /// 「智能风扇降温」承担，组件自身标题关掉防同文重复；v1.2 先例）。
    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("settings.section.fan")

            // Phase 5 v1.1：风扇智能降温区（参数驱动组件，照校准区先例——开关两步
            // 内嵌确认/策略 Picker/阈值与转速滑杆/twoStage 条件参数/八态状态行；
            // 旧 daemon（fan==nil）控件禁用 + 升级提示）。v1.11 T3：currentTempC
            // 注入当前源温度（battery 源 = 1s 遥测电池温度 / cpuSkin 源 = daemon
            // 回显——FanStatus 无电池温度回显字段，battery 侧只有 App 层快照可给）。
            FanSectionView(
                fan: statusController.fanStatus,
                busy: statusController.busy,
                onApply: { statusController.setFan($0) },
                showsTitle: false,
                currentTempC: currentFanTempC
            )
        }
    }

    /// 当前源温度注入（v1.11 T3 D-3f 定版数据源）：cpuSkin 源（线值 1）取
    /// FanStatus.cpuSkinTempC；battery 源/旧 daemon（键缺席按 battery 口径）取
    /// batterySnapshot.temperatureC。
    private var currentFanTempC: Double? {
        let fan = statusController.fanStatus
        if fan?.temperatureSource == 1 {
            return fan?.cpuSkinTempC
        }
        return statusController.batterySnapshot?.temperatureC
    }

    /// 热保护节：ThermalSectionView 原样嵌入（showsTitle false——标题由节头
    /// 承担防同文重复，风扇区同款）。
    private var thermalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("settings.section.thermal")

            // Phase 5 v1.5：充电热保护区（参数驱动组件照风扇区先例——门控二态：
            // 旧 daemon（therm 两键缺席）整卡升级提示；**无开关**——热保护不可
            // 关闭，§4 红线 3）。
            ThermalSectionView(
                thermal: statusController.thermalStatus,
                busy: statusController.busy,
                onApply: { statusController.setThermal($0) },
                showsTitle: false
            )
        }
    }

    /// MagSafe LED 节（Phase 5 v1.8；三态门控，方案 §4）：nil = 旧 daemon →
    /// 升级提示行；supported=false → 不支持提示行（照自动放电门控提示先例）；
    /// supported → MagSafeLedSectionView（showsTitle false——节头承担标题）。
    private var magSafeLedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("settings.section.magSafeLed")
            let led = statusController.magSafeLedStatus
            if let led {
                if led.supported {
                    // v1.10 M2：LED 禁用源 = OR 接法（busy || magSafeLedPending）——
                    // LED 自身在途与全局控制在途两情形都禁用；LED 切换不再置全局
                    // busy，风扇/热保护不再被 LED 往返闪灰（本批修复目标）。
                    MagSafeLedSectionView(
                        mode: led.mode,
                        conflict: led.conflict,
                        busy: statusController.busy || statusController.magSafeLedPending,
                        showsTitle: false,
                        feedback: statusController.magSafeLedFeedback,
                        onApply: { statusController.setMagSafeLed($0) }
                    )
                } else {
                    Text(CellarL10n.s("settings.magSafeLed.unsupported"))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            } else {
                Text(CellarL10n.s("panel.action.needUpgrade"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
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
