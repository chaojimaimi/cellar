import CellarCore
import SwiftUI

/// 菜单栏面板（Phase 2 WP3）：守护进程安装态（WP2 既有）+ 策略控制区（WP3）。
///
/// 控制区仅 registration == .enabled 时可用（规格 §2.1 呈现优先级）；滑杆为本地
/// @State，同步时机 = 面板打开 + 应用成功（轮询回包不回写，规格 §2.3）。
/// 轮询换档由 onAppear/onDisappear 驱动（cancel + 立即刷新 + 新间隔重启，§2.2）。
struct PanelPlaceholder: View {
    @StateObject private var installer = DaemonInstaller()
    @StateObject private var statusController = StatusController()
    @StateObject private var loginItems = LoginItemController()

    // 滑杆本地态（不同步于轮询回包，防「拖到 70 未应用被拽回 80」）。
    @State private var upperLimit: Double = 80
    @State private var hysteresis = 2
    /// 本次面板打开是否已完成「首包同步」（评审 P1）：onAppear 时 daemonStatus 往往
    /// 尚未到达（registration 异步刷新），需等首个非 nil 回包补一次同步，此后轮询
    /// 回包不再回写滑杆。每次面板打开重置（规格 §2.3 同步时机 = 面板打开 + 应用成功）。
    @State private var sliderSynced = false

    var body: some View {
        VStack(spacing: 14) {
            ChargingDialPlaceholder()
                .frame(width: 150, height: 150)
                .padding(.top, 4)

            daemonSection

            if installer.registration == .enabled {
                Divider()
                controlSection
            }

            Divider()

            loginItemSection

            Divider()

            Button("退出 Cellar") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(18)
        .frame(width: 340)
        .onAppear {
            installer.refresh()
            statusController.setPolling(panelVisible: true, daemonRegistered: installer.registration == .enabled)
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
        .onDisappear {
            installer.stopPolling()
            statusController.setPolling(panelVisible: false, daemonRegistered: installer.registration == .enabled)
        }
        // 单向接线（规格 §2.1）：registration → StatusController；离开 .enabled →
        // 停轮询 + 清空运行态（防残留 .unreachable 图标永久 .alert）。
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

    /// 守护进程状态区（§2.6）：状态行（含路由）+ 四象限文案 + 位置提示 + 操作按钮。
    private var daemonSection: some View {
        VStack(spacing: 8) {
            Text("守护进程：\(statusText) · 路线：\(routeText)")
                .font(.callout)
                .fontWeight(.medium)

            if !guidanceText.isEmpty {
                Text(guidanceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if installer.anomaly {
                Text("异常：守护进程可达，但本 app 内未找到嵌入配置（可能由另一副本注册）")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let error = installer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // 位置提示（spike 局限 1.9）：注册跟随 .app 位置，移动/删除后需重新注册。
            Text("提示：已注册的守护进程跟随 Cellar.app 位置；移动或删除应用后请重新安装。")
                .font(.caption2)
                .foregroundStyle(.tertiary)

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

    /// 策略控制区（规格 §2.3 定版）：上限滑杆 60...100 + 滞回 Stepper 1...20 +
    /// 「应用」（本地预检 → setLimits）+ 总开关 + 三态反馈行 + daemon 版本。
    private var controlSection: some View {
        VStack(spacing: 10) {
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
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isModeDisabled ? "启用限充" : "停用限充") {
                    statusController.toggleCharging(enabled: isModeDisabled)
                }
                // 模式未知（首查前/失联）时总开关无意义（不知当前是停用还是启用）。
                .disabled(statusController.daemonStatus == nil || statusController.busy)
            }

            feedbackLine

            Text("守护进程版本：\(statusController.daemonStatus?.version ?? "未知") · 期望 \(DaemonXPC.daemonVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
                    .foregroundStyle(feedback.hasPrefix("已") ? Color.secondary : Color.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 三态反馈行（规格 §2.3 非静默）+ stale 分支（§3.4：版本过旧 + 重装入口提示）。
    @ViewBuilder
    private var feedbackLine: some View {
        switch statusController.controlFeedback {
        case .none:
            EmptyView()
        case .success(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.green)
        case .daemonRejected(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .transferFailed:
            Text("守护进程未运行或无响应")
                .font(.caption)
                .foregroundStyle(.red)
        case .staleDaemon:
            VStack(spacing: 2) {
                Text("守护进程版本过旧，请卸载后重新安装")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text("先点上方「卸载守护进程」，再点「安装守护进程」")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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

/// 静态环形仪表占位：与窖灯图标同构（80% 弧段 + 芯点），琥珀渐变。
private struct ChargingDialPlaceholder: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.black.opacity(0.08), lineWidth: 14)

            Circle()
                .trim(from: 0, to: 0.8)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.71, green: 0.47, blue: 0.23),
                            Color(red: 0.94, green: 0.75, blue: 0.44),
                        ]),
                        center: .center,
                        startAngle: .degrees(90),
                        endAngle: .degrees(-270)
                    ),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Circle()
                .fill(Color(red: 0.96, green: 0.85, blue: 0.63))
                .frame(width: 12, height: 12)
        }
    }
}