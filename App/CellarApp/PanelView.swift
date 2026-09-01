import CellarCore
import SwiftUI

/// 菜单栏面板（Phase 2 WP4 正式面板，规格 §2.7 七层分区）：
/// 告警横幅置顶 → 仪表（GaugeView）→ 状态行（StatusLineView）→ 控制区
/// （仅 registration == .enabled）→ daemon 安装区（精简）→ 登录项 + 退出。
/// 宽 340 统一。
///
/// 组合根提升（规格 §2.8）：三个控制器为 CellarApp 层 @StateObject 经
/// environmentObject 注入——面板视图重建不断供数据源；本视图 onAppear/
/// onDisappear 只做换档（status 1s↔60s + 遥测档启停），安装刷新在 App 启动。
/// 控制逻辑沿用 WP3 不换（sliderSynced/预检/三态/busy/stale 比对全部保留）。
struct PanelView: View {
    @EnvironmentObject private var installer: DaemonInstaller
    @EnvironmentObject private var statusController: StatusController
    @EnvironmentObject private var loginItems: LoginItemController
    @Environment(\.cellarTheme) private var theme

    // 滑杆本地态（不同步于轮询回包，防「拖到 70 未应用被拽回 80」）。
    @State private var upperLimit: Double = 80
    @State private var hysteresis = 2
    /// 本次面板打开是否已完成「首包同步」（评审 P1）：onAppear 时 daemonStatus 往往
    /// 尚未到达（registration 异步刷新），需等首个非 nil 回包补一次同步，此后轮询
    /// 回包不再回写滑杆。每次面板打开重置（规格 §2.3 同步时机 = 面板打开 + 应用成功）。
    @State private var sliderSynced = false

    var body: some View {
        VStack(spacing: 14) {
            AlertBanner(
                feedback: statusController.controlFeedback,
                connection: statusController.connection,
                lastAttemptSummary: statusController.lastAttempt?.summary,
                onRetry: statusController.lastAttempt == nil
                    ? { statusController.refreshNow() }
                    : { statusController.retryLastAttempt() }
            )

            GaugeView(state: gaugeState)
                .frame(width: 150, height: 150)
                .padding(.top, 4)

            StatusLineView(snapshot: statusController.batterySnapshot)

            if installer.registration == .enabled {
                Divider()
                controlSection
            }

            Divider()
            daemonSection

            Divider()
            loginItemSection

            Divider()

            Button("退出 Cellar") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(18)
        .frame(width: 340)
        .onAppear(perform: panelAppeared)
        .onDisappear(perform: panelDisappeared)
        // 单向接线（规格 §2.1）：registration → StatusController（与 App 层接线并存，
        // 面板打开期间的注册变化就近处理；registrationChanged 幂等，双触发无害）。
        .onChange(of: installer.registration) {
            statusController.registrationChanged(installer.registration)
        }
        // 首包同步（评审 P1）：onAppear 时 status 多半未到，首个非 nil 回包补同步
        // 一次；此后轮询回包不再回写（用户拖动不被拽回）。
        .onChange(of: statusController.daemonStatus) {
            guard !sliderSynced, let (upper, hys) = statusController.syncSliderFromStatus() else { return }
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
        statusController.setPolling(panelVisible: true, daemonRegistered: installer.registration == .enabled)
        statusController.setTelemetry(panelVisible: true)
        // 面板打开同步滑杆（规格 §2.3 同步时机之一）；应用成功经回调二次同步。
        statusController.onLimitsApplied = { upper, hys in
            upperLimit = Double(upper)
            hysteresis = hys
            sliderSynced = true
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
        installer.stopPolling()
        statusController.setPolling(panelVisible: false, daemonRegistered: installer.registration == .enabled)
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
            parts.append("当前电量 \(percent)%")
        } else {
            parts.append("电量遥测不可用")
        }
        if let band = gaugeBand {
            parts.append("充电上限 \(band.upperBound)%")
        }
        if let snapshot = statusController.batterySnapshot {
            if snapshot.isCharging {
                parts.append("充电中")
            } else if snapshot.externalConnected {
                parts.append("已停充")
            } else {
                parts.append("电池供电")
            }
        }
        return parts.joined(separator: "，")
    }

    private var gaugeState: GaugeState {
        GaugeState(
            percent: statusController.batterySnapshot?.percent,
            band: gaugeBand,
            isCharging: statusController.batterySnapshot?.isCharging ?? false,
            axLabel: gaugeAxLabel
        )
    }

    // MARK: - 守护进程安装区（§2.7 精简：状态行 + 主按钮 + 四象限文案 +
    // anomaly 行保留 + lastError + 位置提示）

    private var daemonSection: some View {
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
                    installer.install()
                }
            }
            // 迁移象限禁用安装：防用户绕过引导直接安装，制造手工+托管混合态（评审 P2-6）。
            .disabled(
                installer.busy
                    || installer.registration == .pending
                    || installer.guidance == .migrateFromLegacy
            )
        }
    }

    /// 策略控制区（规格 §2.3 定版 + §2.6 预设微调）：预设 80/70/60（两步制，
    /// 仅设滑杆防误触；60 兼作地板可见性教育）+ 上限滑杆 60...100 + 滞回
    /// Stepper 1...20 + 「应用」（本地预检 → setLimits）+ 总开关 + 成功反馈行。
    private var controlSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach([80, 70, 60], id: \.self) { preset in
                    Button("\(preset)%") {
                        upperLimit = Double(preset)   // 两步制：仅设定滑杆值
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Text("预设仅设滑杆，确认后点「应用」")
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text("充电上限")
                Spacer()
                Text("\(Int(upperLimit))%")
                    .monospacedDigit()
            }
            Slider(value: $upperLimit, in: 60...100, step: 1)   // UI 层 60 地板（红线 1）

            HStack {
                Text("滞回幅度")
                Spacer()
                Stepper("\(hysteresis)", value: $hysteresis, in: 1...20)
            }

            HStack(spacing: 8) {
                Button("应用") { applyLimits() }
                    .disabled(isModeDisabled || statusController.busy)
                if isModeDisabled {
                    // setLimits 会强制切回 active（DaemonCore 语义），隐式重新启用
                    // 反直觉——disabled 态禁用并提供提示（P1 定版）。
                    Text("启用限充后可调整")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
                Button(isModeDisabled ? "启用限充" : "停用限充") {
                    statusController.toggleCharging(enabled: isModeDisabled)
                }
                // 模式未知（首查前/失联）时总开关无意义（不知当前是停用还是启用）。
                .disabled(statusController.daemonStatus == nil || statusController.busy)
            }

            if case .success(let text) = statusController.controlFeedback {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(theme.success)
            }

            Text("守护进程版本：\(statusController.daemonStatus?.version ?? "未知") · 期望 \(DaemonXPC.daemonVersion)")
                .font(.caption2)
                .foregroundStyle(theme.tertiaryText)
        }
    }

    /// 登录项开关（规格 §2.4 接线：SMAppService.loginItem + AppConfigStore 持久化）。
    private var loginItemSection: some View {
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

    /// 「应用」按钮动作：本地预检（LimitPolicy 双层防线第一层）→ setLimits。
    private func applyLimits() {
        let upper = Int(upperLimit)
        do {
            _ = try LimitPolicy(upperLimit: upper, hysteresis: hysteresis)
        } catch {
            // 预检失败（红色 1 UI 层防线）不上 XPC，原样上屏（不静默）。
            statusController.reportLocalRejection("参数无效：\(error)")
            return
        }
        statusController.applyLimits(upperLimit: upper, hysteresis: hysteresis)
    }

    private var isModeDisabled: Bool {
        statusController.daemonStatus?.mode == "disabled"
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

    private var buttonTitle: String {
        switch installer.registration {
        case .enabled: return "卸载守护进程"
        case .pending: return "等待系统授权…"
        case .notRegistered: return "安装守护进程"
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