import CellarCore
import CellarUI
import SwiftUI

/// 充电控制区（Phase 5 v1.2 §4.1 自 PanelView.controlSection 迁出——面板与主
/// 窗口页共用同一组件类型，各自宿主持有各自 @State，StatusController 单源；
/// 双宿主并存互不干扰）。语义全迁：预设 80/70/60（设值即排程防抖应用，60 兼作
/// 地板可见性教育）+ 上限滑杆 60...100（松手防抖应用）+ 滞回 Stepper 1...20
/// （步进防抖应用）+ 总开关（独立按钮，不受滑杆防抖影响）+ 版本行；disabled
/// 态（mode == disabled）滑杆/Stepper/预设全禁用 + 提示文案。
///
/// 滑杆同步重构（R1 P1-2 定案 + M3 评审 P1 竞态加固）：废弃
/// StatusController.onLimitsApplied 单值回调钩子（双宿主同时活跃时后开覆盖
/// 先开，先开表面滑杆失去应用成功同步）——本组件自同步：`onChange(of:
/// daemonStatus)` 单通路承担首包同步 + 应用成功回写（应用成功即 daemonStatus
/// 更新——finishControl → ingest 同一真相）。守卫语义：拖动中（isEditing）
/// 一律不回写；应用排程/在途（applyPending/busy）期间旧真相不拥有滑杆——
/// 防抖窗内轮询旧限值回包不得弹回滑杆、不得污染待应用值（评审 P1）；空闲
/// 回包一律向 daemon 真相看齐（跨宿主必然性：另一宿主的应用经此通路同步本
/// 宿主滑杆，双宿主「同步且互不干扰」的走查门要求）。首包同步在组件
/// onAppear 直接同步（每次出现重置，规格 §2.3 同步时机 = 宿主打开 + 应用
/// 成功）。
struct ControlSectionView: View {
    @EnvironmentObject private var statusController: StatusController
    @Environment(\.cellarTheme) private var theme

    // 滑杆本地态（不同步于轮询回包，防「拖到 70 未应用被拽回 80」）。
    @State private var upperLimit: Double = 80
    @State private var hysteresis = 2
    /// 拖动中（§7.1 语义扩展）：isEditing 期间跳过一切外部同步回写——拖动中
    /// 到达的回包 / 应用成功回包不回写滑杆（用户拖动值优先，松手即应用）。
    @State private var isEditing = false
    /// 组件活跃守卫（Phase 5 v1.2 §4.1 语义改组件内 appear/disappear 生命周期）：
    /// 手势拆除与 onDisappear 的相对顺序无保证——防抖排程入口据此拒绝组件
    /// 拆除后迟到的 onEditingChanged(false) 重排（原评审 P2-2 注释语义保留）。
    @State private var sectionActive = false
    /// 防抖应用任务（§7.1）：新排程先 cancel 旧任务；300ms 后走 applyLimits
    /// 全链路。组件消失（onDisappear）时 cancel——防关闭面板/离开页面后静默
    /// 落盘（§7.1「300ms 窗口内关闭不落盘」语义随组件生命周期迁移）。
    @State private var applyTask: Task<Void, Never>?
    /// 应用排程/在途守卫（M3 评审 P1）：scheduleApplyLimits 排程时置位、任务
    /// fire 后清位——期间 daemonStatus 回包（轮询旧限值/心跳等时变字段触发的
    /// onChange）不得回写滑杆（应用排程/在途期间旧真相不拥有滑杆）。fire 后
    /// 的在途窗口由 busy 门接棒（runControl 置位 → finishControl 清位）。
    @State private var applyPending = false

    var body: some View {
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
        .onAppear(perform: sectionAppeared)
        .onDisappear(perform: sectionDisappeared)
        // 自同步单通路（R1 P1-2 + M3 评审 P1）：应用成功即 daemonStatus 更新
        //（finishControl → ingest 同一真相），应用回包与轮询回包不可区分——
        // 空闲态回写无副作用（值 = 应用值），但应用排程/在途期间的旧真相回包
        // 不得拥有滑杆：防抖窗内轮询旧限值回包若回写，滑杆弹回旧值、且 fire
        // 时读回被污染的值应用上去——用户意图静默丢弃 + 上屏假成功横幅
        //（评审 P1 竞态）。守卫三件套：isEditing（拖动中不回写）、applyPending
        //（排程 → fire 窗口）、busy（fire → finishControl 在途窗口，含
        // runControl 置位前已入站的回包与横幅重试路径）。finishControl 先
        // busy=false 再 ingest——应用成功回包到达时两门已清，成功同步通路
        // 不受影响；对端（另一宿主）应用 ack 到达时本宿主空闲，跨宿主同步
        // 照常保留。onChange 触发源远不止限值变化（timestamp 30s 心跳/fan
        // RPM 10s tick/lastPercent/插拔即时刷新），门内一律 return 即不动作。
        .onChange(of: statusController.daemonStatus) {
            guard !isEditing else { return }
            guard !applyPending && !statusController.busy else { return }
            guard let (upper, hys) = statusController.syncSliderFromStatus() else { return }
            upperLimit = Double(upper)
            hysteresis = hys
        }
    }

    // MARK: - 组件生命周期（appear/disappear：防抖取消 + 首包同步重置）

    private func sectionAppeared() {
        sectionActive = true
        // 防御性复位（M3 评审 P1）：同一组件实例重现时不得残留过期 pending。
        applyPending = false
        // 首包同步（评审 P1；规格 §2.3 同步时机）：本组件在面板由 daemonStatus
        // != nil 门控呈现——appear 时 status 通常已到，直接同步；未到则由
        // onChange 通路等首个非 nil 回包（空闲态照常回写，无需首包标记）。
        if let (upper, hys) = statusController.syncSliderFromStatus() {
            upperLimit = Double(upper)
            hysteresis = hys
        }
    }

    private func sectionDisappeared() {
        // §7.1：组件消失即取消未触发的防抖应用（300ms 窗口内关闭/离开不落盘）；
        // 拖动态/排程态复位，防下次出现时外部同步被残留 isEditing/applyPending
        // 跳过（cancel 后的任务不经过 applyPending = false 清理路径——此处
        // 防御性复位，M3 评审 P1）。
        sectionActive = false
        applyTask?.cancel()
        applyTask = nil
        applyPending = false
        isEditing = false
    }

    // MARK: - 防抖应用与预检（全语义自 PanelView 迁出）

    /// 动作活跃判定（滑杆/预设/总开关的禁用依据）。
    private var isActionActive: Bool {
        statusController.action != nil
    }

    /// 防抖应用排程（规格 §7.1）：新排程先 cancel 旧任务；延迟 300ms 后走
    /// applyLimits 全链路（LimitPolicy 预检/三态/banner/busy 门控/stale 比对
    /// 全复用）。回调遇 busy（控制在途，毫秒级）→ 单次延后重排，仍 busy 则放弃
    /// （下次改动重新排程）。主线程纪律：View 隐式 @MainActor，Task 继承主
    /// actor——sleep 挂起不阻塞主线程，applyLimits 本就 @MainActor。
    ///
    /// M3 评审 P1：排程时刻捕获用户值快照（pendingUpper/pendingHys）——fire
    /// 时读回 @State 可能已被防抖窗内回包污染（旧真相回包若越过守卫回写，
    /// applyLimits fire 会把被替换的值应用上去：用户意图静默丢弃 + 假成功
    /// 横幅）；快照是防抖窗口的意图锚点，与 applyPending 门配套。fire 后清
    /// applyPending（在途窗口由 busy 门接棒）。
    private func scheduleApplyLimits(allowRetry: Bool = true) {
        guard sectionActive else { return }
        applyTask?.cancel()
        let pendingUpper = Int(upperLimit)
        let pendingHys = hysteresis
        applyPending = true
        applyTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            guard !statusController.busy else {
                if allowRetry { scheduleApplyLimits(allowRetry: false) }
                else {
                    // 放弃前把滑杆拉回 daemon 真相（评审 P2-1）：静默丢弃用户改动
                    // 会造成「滑杆显示 V2、实际策略 V1」的矛盾呈现。
                    applyPending = false
                    if let (upper, hys) = statusController.syncSliderFromStatus() {
                        upperLimit = Double(upper)
                        hysteresis = hys
                    }
                }
                return
            }
            applyLimits(upperLimit: pendingUpper, hysteresis: pendingHys)
            applyPending = false
        }
    }

    /// 本地预检（LimitPolicy 双层防线第一层）→ setLimits（StatusController 后台
    /// XPC，结果回主 actor）。参数显式传入（M3 评审 P1）：调用方持有排程时刻
    /// 的意图快照，本函数不读 @State——预检与应用值恒为同一快照。
    private func applyLimits(upperLimit: Int, hysteresis: Int) {
        do {
            _ = try LimitPolicy(upperLimit: upperLimit, hysteresis: hysteresis)
        } catch {
            // 预检失败（红色 1 UI 层防线）不上 XPC，原样上屏（不静默）。
            statusController.reportLocalRejection(CellarL10n.s("common.parameterInvalid", String(describing: error)))
            return
        }
        statusController.applyLimits(upperLimit: upperLimit, hysteresis: hysteresis)
    }

    private var isModeDisabled: Bool {
        statusController.daemonStatus?.mode == "disabled"
    }
}