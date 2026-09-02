import CellarCore
import CellarUI
import SwiftUI

/// 首启引导（WP5 §2.1 四步定版，340pt 分步 + 进度指示）：
/// 欢迎 → 冲突门（后台扫描 + 门控三态）→ 安装（迁移守卫 + 统一 wrapper）→
/// 上限（复用既有即时应用链路 + AlertBanner）。
/// - 状态属主 OnboardingController（组合根）——本视图随时可重建，进度不丢。
/// - 底部恒有「退出 Cellar」出口（P2：硬阻断用户有出口）。
struct OnboardingView: View {
    @EnvironmentObject private var installer: DaemonInstaller
    @EnvironmentObject private var statusController: StatusController
    @EnvironmentObject private var onboarding: OnboardingController
    @Environment(\.cellarTheme) private var theme

    /// 安装复检进行中（统一 wrapper「检查中」态，§2.2 P2-3）。
    @State private var installChecking = false
    /// step 4 本地限值（复用面板 §7.1 即时应用链路）。
    @State private var upperLimit: Double = 80
    @State private var hysteresis = 2
    @State private var applyTask: Task<Void, Never>?

    /// 进度指示的可见步骤（done 不占位）。
    private static let visibleSteps: [OnboardingStep] = [.welcome, .conflictCheck, .install, .limit]

    var body: some View {
        VStack(spacing: 14) {
            progressHeader
            stepContent
            Spacer(minLength: 4)
            Button("退出 Cellar") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(18)
        .frame(width: 340)
    }

    // MARK: - 进度指示（四步点 + 步号文本）

    private var currentStepIndex: Int {
        Self.visibleSteps.firstIndex(of: onboarding.step) ?? 0
    }

    private var progressHeader: some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.visibleSteps.count, id: \.self) { index in
                Circle()
                    .fill(index <= currentStepIndex ? theme.accent : theme.track)
                    .frame(width: 8, height: 8)
            }
            Spacer()
            Text("第 \(min(currentStepIndex + 1, Self.visibleSteps.count)) 步 / 共 \(Self.visibleSteps.count) 步")
                .font(.caption2)
                .foregroundStyle(theme.tertiaryText)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch onboarding.step {
        case .welcome: welcomeStep
        case .conflictCheck: conflictStep
        case .install: installStep
        case .limit: limitStep
        case .done: EmptyView()   // 完成即常规面板（本视图不可达）
        }
    }

    // MARK: - 1 欢迎

    private var welcomeStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "wineglass.fill")
                .font(.system(size: 40))
                .accessibilityHidden(true)
            Text("欢迎使用 Cellar").font(.title2).fontWeight(.semibold)
            Text("Cellar 将安装一个 root 守护进程并接管限充：电量达到上限时停止充电，降至上限减滞回（恢复阈值）后恢复。上限最低 60%（60 地板）。")
                .font(.callout)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("开始") {
                onboarding.advance(gate: .clear, registration: installer.registration)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 2 冲突门（后台扫描 + 门控三态）

    private var conflictStep: some View {
        Group {
            // gate == nil（首帧，扫描尚未启动）与扫描中同态：进度指示，防
            // 「未发现冲突」形态闪现。
            if onboarding.gate == nil || onboarding.scanning {
                ProgressView("正在检查环境…")
                    .padding(.vertical, 24)
            } else {
                switch onboarding.gate ?? .clear {
                case .clear: clearGateView
                case .genericNeedsConfirm: genericGateView
                case .exactBlocked: blockedTeachingView
                case .genericConfirmed: EmptyView()   // 确认后立即离开本步
                }
            }
        }
        .onAppear {
            // 首查（gate == nil）才自动扫描；「重新检查」显式重扫。wrapper 呈现
            // 的门控态不自动重扫（防完成用户面板路径被瞬时结果误关闭教学页）。
            if onboarding.gate == nil { onboarding.rescan() }
        }
    }

    private var clearGateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 36))
                .foregroundStyle(theme.success)
                .accessibilityHidden(true)
            Text("未发现冲突工具").font(.headline)
            Text("未检测到其他充电管理工具，可以安全安装 Cellar。")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Button("继续") {
                onboarding.advance(gate: .clear, registration: installer.registration)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var genericGateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            Text("检测到疑似同类工具").font(.headline)
            Text("以下名称疑似电池/充电管理工具，可能为误报（如办公软件名称含 power 词根）。如确有其他工具在管理充电，请先退出后再继续。")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            hitList(generic: true)
            HStack(spacing: 8) {
                Button("重新检查") { onboarding.rescan() }
                Button("仍要继续") {
                    onboarding.confirmAndAdvance(registration: installer.registration)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// exact 硬阻断教学页（§2.1 step 2）：命中列表 + 为何冲突 + 卸载指引 + 重新检查。
    private var blockedTeachingView: some View {
        VStack(spacing: 10) {
            Image(systemName: "shield.slash.fill")
                .font(.system(size: 36))
                .foregroundStyle(theme.alert)
                .accessibilityHidden(true)
            Text("检测到同类充电管理工具").font(.headline)
            Text("两个管理器同时写充电控制键会互相打架，Cellar 拒绝安装。请先退出并卸载以下工具，然后重新检查。")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            hitList(generic: false)
            Button("重新检查") { onboarding.rescan() }
                .buttonStyle(.borderedProminent)
        }
    }

    /// 命中列表（多条目 ScrollView，340pt 内容区内；层 1/层 2 按门控态着色）。
    private func hitList(generic: Bool) -> some View {
        let entries = generic
            ? onboarding.gateDetails?.generic ?? []
            : onboarding.gateDetails?.exact ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entries, id: \.self) { entry in
                    Text(entry)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(generic ? theme.warning : theme.alert)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 72)
        .padding(8)
        .background(theme.bannerBackground, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 3 安装（迁移守卫 + 统一安装 wrapper；通知授权由控制器在启用后发起）

    private var installStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 36))
                .accessibilityHidden(true)
            Text("安装守护进程").font(.headline)
            Text("Cellar 的限充由一个 root 守护进程执行。安装后请在系统设置中批准授权，批准后 Cellar 开始工作。")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if installer.guidance == .migrateFromLegacy {
                // 迁移守卫（P1-2）：legacy 手工安装存在时不提供安装——防绕过迁移
                // 直装制造手工+托管混合态。
                Text("检测到手工安装的守护进程。请先运行 sudo cellar uninstall 清理，再回来继续安装。")
                    .font(.caption)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button(installButtonTitle, action: installStepAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(installer.busy || installChecking || installer.registration == .pending)
            }
            if installer.registration == .enabled {
                Text("守护进程已启用，即将进入上限设置。")
                    .font(.caption)
                    .foregroundStyle(theme.success)
            }
            if let error = installer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(theme.alert)
            }
        }
    }

    private var installButtonTitle: String {
        if installChecking { return "检查中…" }
        switch installer.registration {
        case .enabled: return "已启用，继续"
        case .pending: return "等待系统授权…"
        case .notRegistered: return "安装守护进程"
        }
    }

    /// 安装步主动作：已启用 → 显式前进（自动接续未触发的边缘）；否则统一 wrapper。
    private func installStepAction() {
        if installer.registration == .enabled {
            onboarding.advance(gate: onboarding.gate ?? .clear, registration: installer.registration)
            return
        }
        installViaGate()
    }

    /// 统一安装 wrapper（§2.2 P2-3）：点击 → 禁用 + 「检查中」→ 后台扫描 →
    /// 放行才 install；exact/未确认 generic → 引导页门控呈现（不 install）。
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

    // MARK: - 4 上限（复用既有即时应用链路 + AlertBanner）

    private var limitStep: some View {
        VStack(spacing: 10) {
            Text("设定充电上限").font(.headline)
            Text("达到上限停止充电，降至（上限 − 滞回）后恢复。最低 60%（60 地板）。")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            HStack(spacing: 8) {
                ForEach([80, 70, 60], id: \.self) { preset in
                    Button("\(preset)%") {
                        upperLimit = Double(preset)
                        scheduleApply()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Text("改动后自动应用").font(.caption2).foregroundStyle(theme.tertiaryText)
            }
            HStack {
                Text("充电上限").font(.callout)
                Spacer()
                Text("\(Int(upperLimit))%").monospacedDigit()
            }
            Slider(
                value: $upperLimit,
                in: 60...100,
                step: 1,
                onEditingChanged: { editing in
                    if !editing { scheduleApply() }
                }
            )
            HStack {
                Text("滞回幅度").font(.callout)
                Spacer()
                Stepper("\(hysteresis)") {
                    if hysteresis < 20 {
                        hysteresis += 1
                        scheduleApply()
                    }
                } onDecrement: {
                    if hysteresis > 1 {
                        hysteresis -= 1
                        scheduleApply()
                    }
                }
            }
            AlertBanner(
                feedback: statusController.controlFeedback,
                connection: statusController.connection,
                lastAttemptSummary: statusController.lastAttempt?.summary,
                statusFailureMessage: statusController.statusFailure?.message,
                onRetry: statusController.lastAttempt == nil
                    ? { statusController.refreshNow() }
                    : { statusController.retryLastAttempt() }
            )
            Button("完成") { finishOnboarding() }
                .buttonStyle(.borderedProminent)
        }
    }

    /// 「完成」：防抖窗口内未落盘的值先应用（在途应用不回发），随后完成写标志。
    private func finishOnboarding() {
        if !statusController.busy {
            applyLimitsNow()
        }
        onboarding.complete(registration: installer.registration)
    }

    /// 防抖应用（300ms；复用面板 §7.1 即时应用链路——StatusController.applyLimits）。
    private func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled, !statusController.busy else { return }
            applyLimitsNow()
        }
    }

    private func applyLimitsNow() {
        let upper = Int(upperLimit)
        do {
            _ = try LimitPolicy(upperLimit: upper, hysteresis: hysteresis)
        } catch {
            statusController.reportLocalRejection("参数无效：\(error)")
            return
        }
        statusController.applyLimits(upperLimit: upper, hysteresis: hysteresis)
    }
}