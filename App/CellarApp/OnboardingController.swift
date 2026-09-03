import CellarCore
import Combine
import Foundation
import os

/// 安装复检 wrapper 结果（§2.2 P2-3 定版）：proceed = 放行 install；
/// blocked = 已在引导页呈现门控态（exact 教学 / generic 软警示），调用方不得 install。
enum InstallGate: Equatable {
    case proceed
    case blocked
}

/// 首启引导控制器（WP5 §2.1 定版；组合根成员——MenuBarExtra 视图重建不丢进度，
/// PanelView 内 @State 每次开面板重置是既有事实，step 属主必须在此）。
///
/// 职责：暂存步、冲突门状态（扫描折叠 + 命中详情）、触发式判定、收尾规则
/// （静默补写）、安装复检统一 wrapper、完成写标志（共享 store 原子 update + 内存先行）。
@MainActor
final class OnboardingController: ObservableObject {
    @Published private(set) var step: OnboardingStep = .welcome
    /// 最近一次冲突检查折叠结果（nil = 未检查）。
    @Published private(set) var gate: ConflictGateOutcome?
    /// 命中详情（教学页/软警示列表，来自最近一次扫描）。
    @Published private(set) var gateDetails: ConflictScanResult?
    /// 门控态强制呈现（面板安装路径 exact/未确认 generic 阻断时置位——此时即使
    /// onboardingCompleted 为 true 也呈现引导教学页）。
    @Published private(set) var gateOverride = false
    /// 冲突检查进行中（进度指示）。
    @Published private(set) var scanning = false
    /// 完成标志内存态（§2.4：写盘失败内存态先行，不困住用户）。
    @Published private(set) var onboardingCompleted = false
    /// 磁盘标志是否已加载（加载完成前引导门不判定）。
    @Published private(set) var completedLoaded = false

    /// 安装成功回调（CellarApp 注入：请求通知授权）——组合根分层，控制器不直接
    /// 依赖通知服务。
    var onInstallSucceeded: (() -> Void)?

    private let store: AppConfigStore
    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "onboarding")

    init(store: AppConfigStore = AppConfigStore(url: AppConfigStore.defaultURL)) {
        self.store = store
        // 0.4.1 批：启动加载自标定（StatusController/StyleController.init 同款模式）
        // ——App.init 早期访问 @StateObject 拿到的是被丢弃的临时实例，自标定保证
        // 幸存实例必然完成加载（幂等；多实例创建无害）。
        loadCompletedFlag()
    }

    // MARK: - 加载与注册变化（App 组合根接线）

    /// 启动加载完成标志（actor 读在后台；加载完成前 shouldShowOnboarding 恒 false）。
    func loadCompletedFlag() {
        Task { [store] in
            let config = await store.load()
            onboardingCompleted = config.onboardingCompleted
            completedLoaded = true
        }
    }

    /// 注册态变化入口（App 组合根 onChange + 面板 onAppear，幂等）：
    /// 收尾规则（§2.1 P0-1）+ 安装步接续（授权完成转 enabled → step 4 + 通知授权）。
    func registrationChanged(_ registration: RegistrationStatus) {
        guard completedLoaded else { return }
        // 收尾规则：已 enabled 且无暂存步 → 静默补写完成标志（现机升级 / CLI
        // 安装用户不触发引导；同时消除「老用户卸载 daemon 后被强制引导」）。
        if registration == .enabled && !hasProgress && !onboardingCompleted {
            silentlyComplete()
            return
        }
        // 安装步接续（P0 主路径）：面板收起再重开也能接续 step 4。
        if step == .install && registration == .enabled {
            advanceStep(gate: gate ?? .clear, registration: registration)
            installSucceeded()
        }
    }

    /// 已启用且引导中途（App 重启/面板未开时授权完成）：接续 step 4 + 通知授权。
    private func installSucceeded() {
        onInstallSucceeded?()
    }

    // MARK: - 引导门（§2.1 触发式；收尾规则在 registrationChanged）

    /// 引导呈现条件（触发式）。调用方另需 installer.loaded 守卫（P1-3：防已注册
    /// 用户启动瞬间引导闪现）。暂存步存在（step ∉ {.welcome, .done}）时无视
    /// registration 强制重进；未注册/待授权 → 全新用户进入引导。
    func shouldShowOnboarding(registration: RegistrationStatus) -> Bool {
        guard completedLoaded else { return false }
        if gateOverride { return true }
        if onboardingCompleted { return false }
        return hasProgress || registration == .notRegistered || registration == .pending
    }

    private var hasProgress: Bool {
        step != .welcome && step != .done
    }

    // MARK: - 步骤前进（纯转移函数消费，UI 不自行计算）

    /// 前进（welcome「开始」/conflictCheck「继续」/install 边缘「继续」）。
    func advance(gate: ConflictGateOutcome, registration: RegistrationStatus) {
        advanceStep(gate: gate, registration: registration)
    }

    /// 软警示确认：「仍要继续」→ genericConfirmed 落位后前进（放行 install）。
    func confirmAndAdvance(registration: RegistrationStatus) {
        gate = .genericConfirmed
        gateOverride = false
        // 已完成用户（onboardingCompleted == true，面板重装路径）只落确认不推进
        // 状态机（评审 P2）：防 step 滞留 .limit 与重复通知授权请求——面板路径的
        // 用户本就不该被推进引导状态机。
        guard !onboardingCompleted else { return }
        advanceStep(gate: .genericConfirmed, registration: registration)
    }

    /// step 4「完成」：limit → done（合法转移）→ 写完成标志（内存先行）。
    func complete(registration: RegistrationStatus) {
        guard step == .limit else { return }
        advanceStep(gate: gate ?? .clear, registration: registration)
        markCompleted()
    }

    private func advanceStep(gate: ConflictGateOutcome, registration: RegistrationStatus) {
        guard let next = onboardingNext(step: step, gate: gate, registration: registration) else { return }
        step = next
    }

    // MARK: - 冲突检查（后台扫描；主线程纪律）

    /// 冲突检查（冲突步首查 /「重新检查」时调用）。结果折叠落位 gate/gateDetails；
    /// clear 且为完成用户的面板门控路径 → 退回常规面板（安装按钮重新可用）。
    func rescan() {
        guard !scanning else { return }
        scanning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await ConflictScanner.appScan()
            self.scanning = false
            let outcome = ConflictScanner.fold(result)
            self.gate = outcome
            self.gateDetails = result
            switch outcome {
            case .exactBlocked, .genericNeedsConfirm:
                self.gateOverride = true
            case .clear, .genericConfirmed:
                self.gateOverride = false
                if self.onboardingCompleted, self.step == .conflictCheck {
                    self.step = .welcome
                }
            }
        }
    }

    /// 门控态呈现（安装 wrapper 受阻时调用）：切回冲突步 + 落位 gate 详情。
    private func presentGate(_ outcome: ConflictGateOutcome, details: ConflictScanResult) {
        gate = outcome
        gateDetails = details
        gateOverride = true
        step = .conflictCheck
    }

    // MARK: - 安装复检统一 wrapper（§2.2 P2-3）

    /// 安装复检：后台扫描 → 放行判定。clear /（本会话已确认的）generic 放行；
    /// exact / 未确认 generic → 引导页门控呈现 + .blocked（调用方不得 install）。
    ///
    /// ⚠️ 异步时序显式化：调用方持有「检查中」态（按钮禁用 + 文案），不挂按钮猜测。
    func checkInstallGate() async -> InstallGate {
        let result = await ConflictScanner.appScan()
        switch ConflictScanner.fold(result) {
        case .clear, .genericConfirmed:
            gateDetails = result
            return .proceed
        case .genericNeedsConfirm:
            // 本会话已确认（仍要继续）→ 放行；否则软警示呈现（不重复阻断已确认者）。
            if gate == .genericConfirmed {
                return .proceed
            }
            presentGate(.genericNeedsConfirm, details: result)
            return .blocked
        case .exactBlocked:
            presentGate(.exactBlocked, details: result)
            return .blocked
        }
    }

    // MARK: - 完成写标志（§2.4：原子读改写 + 内存先行）

    /// 写完成标志：经共享 store 的 actor 原子 update() 只写完成标志（WP3 §3.1
    /// 评审 P0-1：launchAtLogin/style 等并发写者字段互不覆盖）。写盘失败 → 内存态
    /// 已置完成（不困住用户）+ os_log 非阻塞呈现；下次启动标志仍 false 时被收尾
    /// 规则补写。
    private func markCompleted() {
        onboardingCompleted = true
        gateOverride = false
        step = .done
        Task { [store] in
            do {
                _ = try await store.update { $0.onboardingCompleted = true }
            } catch {
                Self.log.error("引导完成标志写盘失败（内存态已置完成，下次启动重试）：\(error.localizedDescription)")
            }
        }
    }

    private func silentlyComplete() {
        guard !onboardingCompleted else { return }
        Self.log.info("收尾规则：已启用且无暂存步 → 静默补写引导完成标志")
        markCompleted()
    }
}