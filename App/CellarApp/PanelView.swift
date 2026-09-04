import CellarCore
import CellarUI
import SwiftUI

/// 菜单栏面板（Phase 2 WP4 正式面板，规格 §2.7 七层分区；WP5 引导模式门）：
/// 引导模式（新用户/暂存步/冲突门阻断）呈现 OnboardingView，否则常规面板——
/// 告警横幅置顶（含 status 派生失败横幅分支）→ 仪表（GaugeView）→ 状态行
/// （StatusLineView）→ 控制区（ControlSectionView，Phase 5 v1.2 §4.1 自本视图
/// 迁出的共享组件——面板与主窗口页双宿主）→ 登录项 + 退出。宽 340 统一。
/// v1.2 走查批 F5：daemon 安装区（DaemonSectionView）自面板移除——新用户安装走
/// 引导模式（OnboardingView 覆盖常规面板），异常可见性由告警横幅（失联横幅）
/// + 主窗口通用页承担（主窗口页已含 DaemonSectionView 全功能，排障入口在彼）。
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
/// 控制逻辑（滑杆本地态/防抖/预检/自同步）全在 ControlSectionView 组件内
/// （§4.1 R1 P1-2：滑杆同步废弃控制器回调钩子，改组件 onChange 自同步）——
/// 面板行为/视觉零回归，双宿主各自 @State。
struct PanelView: View {
    @EnvironmentObject private var installer: DaemonInstaller
    @EnvironmentObject private var statusController: StatusController
    @EnvironmentObject private var loginItems: LoginItemController
    @EnvironmentObject private var onboarding: OnboardingController
    @Environment(\.cellarTheme) private var theme

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
            // Phase 5 v1.2 §4.1：控制区迁出为共享组件 ControlSectionView（面板
            // 与主窗口页双宿主；控制逻辑/守卫/防抖全语义随组件移动，此处仅消费）。
            if statusController.daemonStatus != nil {
                Divider()
                ControlSectionView()
                Divider()
                ActionSectionView()
                // WP3：校准区（ActionSection 之后；能力门控缺失时组件整区隐藏）。
                Divider()
                CalibrationSection()
            }

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
    }

    // MARK: - 面板生命周期（§2.8：只做换档 + 遥测档启停；安装刷新在 App 启动）

    private func panelAppeared() {
        // 注册态新鲜度（评审 P2-1）：CLI 卸载（面板迁移指引就是让用户跑
        // sudo cellar uninstall）后重开面板必须重查，否则呈现误导性失联态。
        installer.refresh()
        // Phase 5 v1.2 §2.3：多表面仲裁 API（面板表面；换档语义与旧单表面
        // 采样 API 完全等价——任一表面可见 → 1s，全无 → 60s/遥测停）。
        statusController.setPanelVisible(true)
        // 引导判定就近触发（收尾规则/安装接续，幂等；组合根 onChange 双触发无害）。
        onboarding.registrationChanged(installer.registration)
        // 注册态就近重判（评审 P2-1 一行保险）：启动接线 onChange 挂主 Window
        // scene——主窗关闭期间 registration 翻转（如 CLI 卸载）不再触达
        // statusController，面板重开必须就地补判，防失联语义滞留「已注册」。
        statusController.registrationChanged(installer.registration)
        loginItems.load()
    }

    private func panelDisappeared() {
        // §2.8 只做换档：控制区滑杆/防抖的生命周期管理已随 ControlSectionView
        // 组件内 appear/disappear 迁出（§4.1——面板关闭时组件同步销毁守卫）。
        installer.stopPolling()
        statusController.setPanelVisible(false)
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
}