import CellarCore
import CellarUI
import SwiftUI

/// 菜单栏面板（Phase 2 WP4 正式面板，规格 §2.7 七层分区；WP5 引导模式门）：
/// 引导模式（新用户/暂存步/冲突门阻断）呈现 OnboardingView，否则常规面板——
/// 告警横幅置顶（含 status 派生失败横幅分支）→ 仪表（GaugeView）→ 状态行
/// （StatusLineView）→ 控制区（仅 registration == .enabled）→ daemon 安装区
/// （DaemonSectionView，统一安装 wrapper）→ 登录项 + 退出。宽 340 统一。
///
/// **引导门（WP5 §2.1 触发式）：!onboardingCompleted &&（暂存步存在
/// （step ∉ {.welcome, .done}）|| registration ∈ {.notRegistered, .pending}）→
/// 引导**；installer.loaded 守卫（P1-3，首次 refresh 回包前不判定，防已注册用户
/// 启动瞬间引导闪现）；enabled 且无暂存步且未完成 → 收尾规则静默补写标志
/// （OnboardingController）。本视图只读判定，侧效应（收尾补写/安装接续）在
/// onAppear 与 onChange 触发。
///
/// 组合根提升（规格 §2.8）：四控制器为 CellarApp 层 @StateObject 经
/// environmentObject 注入——面板视图重建不断供数据源；本视图 onAppear/
/// onDisappear 只做换档（status 1s↔60s + 遥测档启停），安装刷新在 App 启动。
/// 控制逻辑沿用 WP3 不换（sliderSynced/预检/三态/busy/stale 比对全部保留）；
/// §7.1 即时应用：滑杆松手 / Stepper 步进 / 预设点击 → 防抖 300ms → 既有
/// applyLimits 全链路（移除「应用」按钮与成功反馈行——成功确认 = band 弧即时
/// 移动，回包驱动；失败仍走横幅三分支）。
struct PanelView: View {
    @EnvironmentObject private var installer: DaemonInstaller
    @EnvironmentObject private var statusController: StatusController
    @EnvironmentObject private var loginItems: LoginItemController
    @EnvironmentObject private var onboarding: OnboardingController
    @Environment(\.cellarTheme) private var theme

    // 滑杆本地态（不同步于轮询回包，防「拖到 70 未应用被拽回 80」）。
    @State private var upperLimit: Double = 80
    @State private var hysteresis = 2
    /// 拖动中（§7.1 语义扩展）：isEditing 期间跳过一切外部同步回写——首包同步
    /// 保留（非拖动时照常），拖动中到达的回包 / 应用成功回包不回写滑杆。
    @State private var isEditing = false
    /// 面板活跃守卫（评审 P2-2）：手势拆除与 onDisappear 的相对顺序无保证——
    /// 防抖排程入口据此拒绝面板拆除后迟到的 onEditingChanged(false) 重排。
    @State private var panelActive = false
    /// 防抖应用任务（§7.1）：新排程先 cancel 旧任务；300ms 后走 applyLimits
    /// 全链路。面板消失（onDisappear）时 cancel，防关闭面板后静默落盘。
    @State private var applyTask: Task<Void, Never>?
    /// 本次面板打开是否已完成「首包同步」（评审 P1）：onAppear 时 daemonStatus 往往
    /// 尚未到达（registration 异步刷新），需等首个非 nil 回包补一次同步，此后轮询
    /// 回包不再回写滑杆。每次面板打开重置（规格 §2.3 同步时机 = 面板打开 + 应用成功）。
    @State private var sliderSynced = false

    var body: some View {
        Group {
            // 引导模式门（WP5 §2.1）：loaded 守卫 + 触发式（OnboardingController 判定）。
            // ⚠️ gateOverride（用户点安装被冲突门拦下）不受 loaded 守卫——用户动作的
            // 即时反馈（教学页切换）不能被初始化挂起吞掉（验收事故回归）。
            if onboarding.gateOverride
                || (installer.loaded && onboarding.shouldShowOnboarding(registration: installer.registration)) {
                OnboardingView()
            } else {
                regularPanel
            }
        }
        .frame(width: 340)
        .onAppear(perform: panelAppeared)
        .onDisappear(perform: panelDisappeared)
        // 单向接线：registration → OnboardingController（引导门/收尾规则）。
        // StatusController 的轮询已与注册态解耦（双路线定版），无需在此接线。
        .onChange(of: installer.registration) {
            onboarding.registrationChanged(installer.registration)
        }
        // P1-3 守卫解锁：loaded 置位时补一次判定（首回包与注册同值不触发上面 onChange）。
        .onChange(of: installer.loaded) {
            onboarding.registrationChanged(installer.registration)
        }
    }

    /// 常规面板（引导不活跃时）。
    private var regularPanel: some View {
        VStack(spacing: 14) {
            AlertBanner(
                feedback: statusController.controlFeedback,
                connection: statusController.connection,
                lastAttemptSummary: statusController.lastAttempt?.summary,
                statusFailureMessage: statusController.statusFailure?.message,
                onRetry: statusController.lastAttempt == nil
                    ? { statusController.refreshNow() }
                    : { statusController.retryLastAttempt() }
            )

            GaugeView(state: gaugeState)
                .frame(width: 150, height: 150)
                .padding(.top, 4)

            // WP2' §4.2：功率流向图（数据源 = App 侧 1s telemetry 快照——非
            // daemonStatus 30s 滞后字段；快照缺席 → 不渲染零占用）。batteryPowerW
            // = 电池侧实测功率（Voltage×Amperage，WP1.5 §7.5：适配器实际输出无
            // 公开数据源，电池侧为可靠替代）。
            PowerFlowView(
                externalConnected: statusController.batterySnapshot?.externalConnected,
                isCharging: statusController.batterySnapshot?.isCharging,
                batteryPowerW: statusController.batterySnapshot.map {
                    Double($0.voltageMV) * Double($0.amperageMA) / 1_000_000
                },
                // Phase 5 v1.1：风扇状态行（仅 boost/hold 介入期显形；off 完全隐形）。
                fanStatus: statusController.daemonStatus?.fan
            )

            // WP1：温度暂停注词接线——daemonStatus 与 batterySnapshot 在本组装点
            // 交汇（方案 §2.4 数据流：App 侧直读遥测 + daemon 轮询两源并存）。
            StatusLineView(
                snapshot: statusController.batterySnapshot,
                tempPauseActive: statusController.daemonStatus?.isTempPauseAction == true
            )

            // 控制区/动作区门控（双路线定版）：按「XPC 证明 daemon 在应答」呈现——
            // 手工路线（CLI 安装）的 daemon 同样可控制；mode=="disabled" 时区内
            // 控件自带禁用 + 启用按钮（既有 isModeDisabled 设计）。SMAppService
            // 注册态仅驱动安装区。轮询与注册态解耦见 StatusController/AppSide。
            if statusController.daemonStatus != nil {
                Divider()
                controlSection
                Divider()
                ActionSectionView()
                // WP3：校准区（ActionSection 之后；能力门控缺失时组件整区隐藏）。
                Divider()
                CalibrationSection()
            }

            Divider()
            DaemonSectionView()

            Divider()
            LoginItemSectionView()

            Divider()

            PanelFooterView()
        }
        .padding(18)
        // 自绘面板背景（WP3 §3.2；spike S2 定版：容器圆角贴合、无白边/脏色）——
        // nil = 不画（native 走系统容器材质，A 原生零回归）。
        .background {
            if let panelBackground = theme.panelBackground {
                panelBackground
            }
        }
        // 面板边框（amber 专属；native nil 不画）。圆角对齐 MenuBarExtra 容器
        // （精确值 S8 真机走查复核）。
        .overlay {
            if let panelBorder = theme.panelBorder {
                RoundedRectangle(cornerRadius: 8).strokeBorder(panelBorder)
            }
        }
        // 首包同步（评审 P1；§7.1 语义扩展）：onAppear 时 status 多半未到，首个
        // 非 nil 回包补同步一次；此后轮询回包不再回写（用户拖动不被拽回）。
        // 拖动中首包到达：不回写（用户拖动值优先，松手即应用），但标记已同步——
        // 维持「轮询回包不再回写」不变量，防面板延迟关闭后值被旧回包覆盖。
        .onChange(of: statusController.daemonStatus) {
            guard !sliderSynced else { return }
            guard !isEditing, let (upper, hys) = statusController.syncSliderFromStatus() else {
                if isEditing { sliderSynced = true }
                return
            }
            upperLimit = Double(upper)
            hysteresis = hys
            sliderSynced = true
        }
    }

    // MARK: - 面板生命周期（§2.8：只做换档 + 遥测档启停；安装刷新在 App 启动）

    private func panelAppeared() {
        // 注册态新鲜度（评审 P2-1）：CLI 卸载（面板迁移指引就是让用户跑
        // sudo cellar uninstall）后重开面板必须重查，否则呈现误导性失联态。
        installer.refresh()
        panelActive = true
        statusController.setPolling(panelVisible: true)
        statusController.setTelemetry(panelVisible: true)
        // 引导判定就近触发（收尾规则/安装接续，幂等；组合根 onChange 双触发无害）。
        onboarding.registrationChanged(installer.registration)
        // 面板打开同步滑杆（规格 §2.3 同步时机之一）；应用成功经回调二次同步
        // （§7.1：拖动中不写回，防应用回包拽回正在拖动的滑杆）。
        statusController.onLimitsApplied = { upper, hys in
            sliderSynced = true
            guard !isEditing else { return }
            upperLimit = Double(upper)
            hysteresis = hys
        }
        sliderSynced = false
        if let (upper, hys) = statusController.syncSliderFromStatus() {
            upperLimit = Double(upper)
            hysteresis = hys
            sliderSynced = true
        }
        loginItems.load()
    }

    private func panelDisappeared() {
        // §7.1：面板消失即取消未触发的防抖应用（300ms 窗口内关闭不落盘）；
        // 拖动态复位，防下次打开时外部同步被残留 isEditing 跳过。
        panelActive = false
        applyTask?.cancel()
        applyTask = nil
        isEditing = false
        installer.stopPolling()
        statusController.setPolling(panelVisible: false)
        statusController.setTelemetry(panelVisible: false)
    }

    // MARK: - 仪表上下文（规格 §2.3 面板层拼装）

    /// band 语义：限充区间（恢复阈值...上限）；daemon 未注册（策略真相拿不到）
    /// 或 mode == disabled（画 band 误导「仍在限充」）→ nil 隐藏区间弧。
    private var gaugeBand: ClosedRange<Int>? {
        guard let status = statusController.daemonStatus, status.mode != "disabled" else { return nil }
        return (status.upperLimit - status.hysteresis)...status.upperLimit
    }

    private var gaugeAxLabel: String {
        var parts: [String] = []
        if let percent = statusController.batterySnapshot?.percent {
            parts.append(CellarL10n.s("panel.gaugeAx.percent", percent))
        } else {
            parts.append(CellarL10n.s("panel.gaugeAx.unavailable"))
        }
        if let band = gaugeBand {
            parts.append(CellarL10n.s("panel.gaugeAx.band", CellarL10n.s("vocabulary.native.limitLabel"), band.upperBound))
        }
        if let snapshot = statusController.batterySnapshot {
            if snapshot.isCharging {
                parts.append(theme.word(.powerFlowCharging))
            } else if snapshot.externalConnected {
                parts.append(theme.word(.powerFlowFloating))
            } else {
                parts.append(theme.word(.powerFlowOnBattery))
            }
        }
        // 分隔符按语言本地化（zh 全角逗号 / en 半角逗号+空格）。
        return parts.joined(separator: CellarL10n.s("common.joinSeparator"))
    }

    private var gaugeState: GaugeState {
        GaugeState(
            percent: statusController.batterySnapshot?.percent,
            band: gaugeBand,
            isCharging: statusController.batterySnapshot?.isCharging ?? false,
            axLabel: gaugeAxLabel
        )
    }

    // MARK: - 策略控制区（规格 §2.3 定版 + §2.6 预设 + §7.1 即时应用）：预设 80/70/60
    // （设值即排程防抖应用，原两步制观感消失、一步完成；60 兼作地板可见性
    // 教育）+ 上限滑杆 60...100（松手防抖应用）+ 滞回 Stepper 1...20（步进
    // 防抖应用）+ 总开关（独立按钮，不受滑杆防抖影响）。§7.1 移除「应用」
    // 按钮与 .success 反馈行——成功确认 = band 弧即时移动（回包驱动）；失败
    // 仍走横幅（三分支不变）。disabled 态（mode == disabled）：滑杆/Stepper/
    // 预设全禁用 + 提示文案（P1 定版语义保留）。
    private var controlSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach([80, 70, 60], id: \.self) { preset in
                    Button("\(preset)%") {
                        upperLimit = Double(preset)   // 预设 = 设值 + 排程（§7.1）
                        scheduleApplyLimits()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isModeDisabled || isActionActive)
                }
                Text(CellarL10n.s("panel.automaticallyApplied"))
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text(theme.word(.limitLabel))
                Spacer()
                Text("\(Int(upperLimit))%")
                    .monospacedDigit()
            }
            // §7.1：松手（onEditingChanged(false)）→ 防抖 300ms → applyLimits
            // 全链路（预检/三态/banner/busy/stale 比对全复用）。
            Slider(
                value: $upperLimit,
                in: 60...100,   // UI 层 60 地板（红线 1）
                step: 1,
                onEditingChanged: { editing in
                    isEditing = editing
                    if !editing { scheduleApplyLimits() }
                }
            )
            .disabled(isModeDisabled || isActionActive)

            HStack {
                Text(CellarL10n.s("panel.hysteresis"))
                Spacer()
                // §7.1：macOS Stepper 按钮点击的 onEditingChanged 触发不可靠，
                // 用显式步进回调（点击即用户意图），步进后同走防抖排程。
                Stepper("\(hysteresis)") {
                    if hysteresis < 20 {
                        hysteresis += 1
                        scheduleApplyLimits()
                    }
                } onDecrement: {
                    if hysteresis > 1 {
                        hysteresis -= 1
                        scheduleApplyLimits()
                    }
                }
                .disabled(isModeDisabled || isActionActive)
            }

            HStack(spacing: 8) {
                if isModeDisabled {
                    // setLimits 会强制切回 active（DaemonCore 语义），隐式重新启用
                    // 反直觉——disabled 态禁用并提供提示（P1 定版，§7.1 保留）。
                    Text(CellarL10n.s("panel.tuneDisabledHint"))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
                Button(isModeDisabled ? CellarL10n.s("panel.enableLimit") : CellarL10n.s("panel.disableLimit")) {
                    statusController.toggleCharging(enabled: isModeDisabled)
                }
                // 模式未知（首查前/失联）时总开关无意义（不知当前是停用还是启用）；
                // 动作活跃期禁用（隐式取消只经滑杆/取消按钮，不误触总开关）。
                .disabled(statusController.daemonStatus == nil || statusController.busy || isActionActive)
            }

            Text(CellarL10n.s(
                "panel.versionLine",
                statusController.daemonStatus?.version ?? CellarL10n.s("common.unknown"),
                DaemonXPC.daemonVersion
            ))
                .font(.caption2)
                .foregroundStyle(theme.tertiaryText)
        }
    }

    // MARK: - 一次性动作区与登录项区（WP3 S5a 迁出至 PanelSections.swift：动作区
    // 语汇 word(.actionFullOnce)、页脚 word(.quit)；动作活跃判定 isActionActive
    // 供本区滑杆/预设/总开关禁用，语义与迁出前一致）。
    /// 动作活跃判定（滑杆/预设/总开关的禁用依据）。
    private var isActionActive: Bool {
        statusController.action != nil
    }

    /// 防抖应用排程（规格 §7.1）：新排程先 cancel 旧任务；延迟 300ms 后走
    /// applyLimits 全链路（LimitPolicy 预检/三态/banner/busy 门控/stale 比对
    /// 全复用）。回调遇 busy（控制在途，毫秒级）→ 单次延后重排，仍 busy 则放弃
    /// （下次改动重新排程）。主线程纪律：View 隐式 @MainActor，Task 继承主
    /// actor——sleep 挂起不阻塞主线程，applyLimits 本就 @MainActor。
    private func scheduleApplyLimits(allowRetry: Bool = true) {
        guard panelActive else { return }
        applyTask?.cancel()
        applyTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            guard !statusController.busy else {
                if allowRetry { scheduleApplyLimits(allowRetry: false) }
                else {
                    // 放弃前把滑杆拉回 daemon 真相（评审 P2-1）：静默丢弃用户改动
                    // 会造成「滑杆显示 V2、实际策略 V1」的矛盾呈现。
                    if let (upper, hys) = statusController.syncSliderFromStatus() {
                        upperLimit = Double(upper)
                        hysteresis = hys
                    }
                }
                return
            }
            applyLimits()
        }
    }

    /// 本地预检（LimitPolicy 双层防线第一层）→ setLimits（StatusController 后台
    /// XPC，结果回主 actor）。
    private func applyLimits() {
        let upper = Int(upperLimit)
        do {
            _ = try LimitPolicy(upperLimit: upper, hysteresis: hysteresis)
        } catch {
            // 预检失败（红色 1 UI 层防线）不上 XPC，原样上屏（不静默）。
            statusController.reportLocalRejection(CellarL10n.s("common.parameterInvalid", String(describing: error)))
            return
        }
        statusController.applyLimits(upperLimit: upper, hysteresis: hysteresis)
    }

    private var isModeDisabled: Bool {
        statusController.daemonStatus?.mode == "disabled"
    }
}