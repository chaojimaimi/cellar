import CellarCore
import CellarUI
import Foundation

// MARK: - 多 Profile 切换编排器（0.23.18 方案 §2.3；extension 文件——
// StatusController 行数纪律拆分先例，LED/LimitExecution 同款）

extension StatusController {

    /// 链会话状态（值类型；存储槽 `profileChain` 在主类声明——extension 不能声明
    /// 存储属性，LED magSafeLedPending 同款拆分先例）。
    struct ProfileChainState {
        /// 本链方案载荷（每步重推导的 applyPlan 输入 + 链尾聚合反馈/意图更新的名字）。
        let payload: ProfilePayload
        /// 最近已发起步（收敛守卫一输入：紧邻同型步重推导 = 读回未收敛 → 中止）。
        var lastStep: ProfileApplyStep?
        /// 已发起步数（收敛守卫二输入：≥ ProfileModel.applyStepCaseCount = 步型全发
        /// 仍未收敛 = 振荡 → 中止）。
        var executed: Int
    }

    // MARK: - 入口（ProfileController.switchTo 唯一调用方）

    /// 切换启动：置链 → 推进首步。每步 runControl 持 busy 至 finishControl，
    /// finishControl 内 busy=false → onFailure/onSuccess → 下一步 busy=true 是
    /// **同一 MainActor 同步序列**，无重入窗——用户 UI 事件无法插进两步之间
    /// （链原子性免费获得，方案 §2.3）。
    ///
    /// 入口三门（非静默拒绝上屏；mode == "disabled" **不禁用**——切到 active
    /// profile 正是从 disabled 走出的合法路径，显式 disable/隐式启用矩阵 §2.1
    /// 已如实处理）：busy / 在轨一次性动作（action != nil——setLimits 隐式取消
    /// 在轨动作的入口禁用面，R4）/ 链在途（profileChain != nil，常态被 busy 门
    /// 先拦——此处兜底死链防御，R6：链不接受排队）。daemonStatus == nil 门由
    /// 调用方结构性承接：switchTo(_ current: DaemonStatus) 参数非可选 + 管理
    /// 页/菜单禁用矩阵（status nil 禁用）双保险——guard 不可表达非可选参数为 nil。
    ///
    /// 链期间菜单/管理页切换控件经 busy+actionActive 门禁用；**风扇节例外**
    /// （FanSectionView 不接 busy——v0.19.7 有意设计）：链飞行期用户可经 fan 轻
    /// 路径提交风扇变更，与链 setFan 步并发 = last-wins（R13 登记，接受；不加
    /// busy 门——不偏离 v0.19.7 意图）。链前残留排队笔：finishControl 中
    /// onSuccess/onFailure 先于 queuedControlCall 补发——链推进完后，用户链前点
    /// 的预设/控制照常补发，用户显式动作胜出该旋钮，✓ 随读回消失（诚实，R2）。
    func applyProfile(payload: ProfilePayload, current: DaemonStatus) {
        guard busy == false, action == nil, profileChain == nil else {
            // 非静默拒绝上屏（唯一本地拒绝文案通路 common.parameterInvalid——
            // ControlSectionView/StatusItemController/OnboardingView 三处既有调用
            // 点同款；本臂为防御性兜底：三门在菜单/管理页禁用矩阵双侧结构性禁用，
            // 正常交互不可达，marker 串照 daemon actionOccupied 字面量标记风格）。
            reportLocalRejection(CellarL10n.s("common.parameterInvalid", "profileSwitchOccupied"))
            return
        }
        profileChain = ProfileChainState(payload: payload, lastStep: nil, executed: 0)
        advanceProfileChain(from: current)
    }

    // MARK: - 链推进（每步用最新读回重推导剩余计划——评审 P2-2 定版）

    /// 推进一步：链存续守卫 → 重推导计划 → **链尾判定前置** → 收敛守卫单点 → 发步。
    ///
    /// 评审收口 P1（0.23.18 全审）次序修正：原实现守卫二（executed ≥ 步型总数）
    /// 在 plan 重推导之前以 nextStep: nil 形态独立前置——八步满序链（disabled
    /// 方案七旋钮全差异）第 8 步成功回包后 advance #9 时 executed=8，守卫二把
    /// 「全旋钮已收敛、计划已空」误判为振荡中止 → 已生效整链弹「未收敛」假失败
    /// + 跳过 applied 反馈与意图更新。修正：**plan 判空（链尾 finish）先于守卫**
    /// ，守卫合并至 plan.first 之后的单点（守卫语义不变：仍在发步前——链存续
    /// 守卫与 defer 时序防御不回退）；chainGuardShouldAbort 随之收窄单语义
    /// （nextStep 非可选，「nextStep nil 仅查守卫二」双语义入口消除）。
    private func advanceProfileChain(from status: DaemonStatus) {
        // 链存续守卫（评审 P1 时序防御）：在飞步回包时链可能已被中止/失败清链——
        // 空转 return，杜绝强解包崩溃路径。**此守卫必须先于一切链状态访问**。
        guard let chain = profileChain else { return }
        // 每步重推导（评审 P2-2 定版，消除链首陈旧 diff 输入）：以最新读回重算
        // 剩余计划——已生效旋钮自动跳过（diff-skip 廉价），整链重做 = 再点一次
        // 方案。计划空 ⇔ 全旋钮读回匹配（与 activeMatch 共用比较 helper——评审
        // P3 实现纪律钉死 + 方案-11 场景互证）。
        let plan = ProfileModel.applyPlan(profile: chain.payload, current: status)
        // 链尾判定前置（评审收口 P1）：计划空 → 聚合反馈 + 意图更新 + 清链——
        // **必须先于收敛守卫**（见函数头注：守卫二先行会误杀满序链的收敛尾）。
        guard let step = plan.first else {
            finishProfileChain()
            return
        }
        // 收敛守卫（单点，**发步前**——评审 P1：上限检查严禁放 defer 出口，否则
        // 「已发起步 + defer 清链」组合下在飞回包续链 = 崩溃路径；R16——守卫纯
        // 函数在 CellarCore 可向量直测，ProfileDomain 方案-10）：守卫一 lastStep
        // == nextStep = 紧邻同型步重推导 = daemon 读回未收敛（如日程 JSON 归一化
        // 漂移）中止 + 守卫二 executed ≥ applyStepCaseCount = 步型全发仍未收敛 =
        // 振荡中止。此处 nextStep 恒非 nil（plan.first 判空先行）。
        if ProfileModel.chainGuardShouldAbort(
            lastStep: chain.lastStep, nextStep: step, executed: chain.executed
        ) {
            abortChain()
            return
        }
        profileChain?.lastStep = step
        profileChain?.executed += 1
        dispatchProfileStep(step)
    }

    /// 链步 → runControl 单槽下发（exhaustive switch——ProfileApplyStep 新增 case
    /// 编译期强制同步）。**链步成功反馈一律 nil 静默**（横幅串击根除——B3-4），
    /// 仅链尾 finishProfileChain 一笔聚合反馈；失败即停：onFailure 清链（横幅
    /// 本体由 classifyControlFailure 既有三态落位——onFailure 不重复落横幅）。
    private func dispatchProfileStep(_ step: ProfileApplyStep) {
        switch step {
        case .setLimits(let upperLimit, let hysteresis):
            runControl(
                attempt: .setLimits(upperLimit: upperLimit, hysteresis: hysteresis),
                operation: { try DaemonXPCClient().setLimits(upperLimit: upperLimit, hysteresis: hysteresis) },
                successFeedback: nil,
                onFailure: { _ in self.profileChain = nil },
                onSuccess: { status in self.advanceProfileChain(from: status) }
            )
        case .setFan(let wire):
            runControl(
                attempt: .setFan(wire, .strategy),
                operation: { try DaemonXPCClient().setFan(wire) },
                successFeedback: nil,
                onFailure: { _ in self.profileChain = nil },
                onSuccess: { status in self.advanceProfileChain(from: status) }
            )
            // fan 步 field: .strategy 取形注记（方案 §2.3）：链步经 runControl
            // **不置 fanPendingField**（该 pending 视觉仅轻路径 setFan(_:field:) 写）
            // → 链飞行期风扇节无控件被钉 pending；field 仅影响重试臂重走轻路径时
            // 哪颗控件短暂呈 pending，取 .strategy 任意合法（九键全发 wire 使下发
            // 效果与 field 取值无关）。ControlAttempt.setFan 关联值无标签（wire,
            // field 二元组形态）——方案「field: .strategy」指取值非形参标签。
        case .setThermal(let wire):
            runControl(
                attempt: .setThermal(wire),
                operation: { try DaemonXPCClient().setThermal(wire) },
                successFeedback: nil,
                onFailure: { _ in self.profileChain = nil },
                onSuccess: { status in self.advanceProfileChain(from: status) }
            )
        case .setChargeSchedule(let json):
            runControl(
                attempt: .setChargeSchedule(json),
                operation: { try DaemonXPCClient().setChargeSchedule(json) },
                successFeedback: nil,
                onFailure: { _ in self.profileChain = nil },
                onSuccess: { status in self.advanceProfileChain(from: status) }
            )
        case .setCalibrationSchedule(let wire):
            runControl(
                attempt: .setCalibrationSchedule(wire),
                operation: { try DaemonXPCClient().setCalibrationSchedule(wire) },
                successFeedback: nil,
                onFailure: { _ in self.profileChain = nil },
                onSuccess: { status in self.advanceProfileChain(from: status) }
            )
        case .setChHysteresisEnabled(let enabled):
            runControl(
                attempt: .setChHysteresisEnabled(enabled),
                operation: { try DaemonXPCClient().setChHysteresisEnabled(enabled) },
                successFeedback: nil,
                onFailure: { _ in self.profileChain = nil },
                onSuccess: { status in self.advanceProfileChain(from: status) }
            )
        case .disable:
            runControl(
                attempt: .setChargingEnabled(false),
                operation: { try DaemonXPCClient().disable() },
                successFeedback: nil,
                onFailure: { _ in self.profileChain = nil },
                onSuccess: { status in
                    // toggleCharging(false) 同款补偿（reconcileShutdownResidualNow
                    // 已 internal——StatusController+LimitExecution.swift:56，零改动）。
                    self.reconcileShutdownResidualNow()
                    self.advanceProfileChain(from: status)
                }
            )
        case .setMagSafeLed(let raw):
            // 手改配置防御：非法 raw 值（MagSafeLEDMode 白名单外）永不收敛——
            // 按未收敛中止（capture 只存合法 rawValue；UInt8 载荷为手编 Codable 容错面）。
            guard let mode = MagSafeLEDMode(rawValue: raw) else {
                abortChain()
                return
            }
            runControl(
                attempt: .setMagSafeLed(mode),
                operation: { try DaemonXPCClient().setMagSafeLed(raw) },
                successFeedback: nil,
                onFailure: { _ in self.profileChain = nil },
                onSuccess: { status in self.advanceProfileChain(from: status) }
            )
        }
    }

    // MARK: - 链收尾 / 中止

    /// 链尾收敛：计划空 ⇔ 全旋钮读回匹配 → 聚合反馈（control.profile.applied 含
    /// 方案名——**仅此一笔成功反馈**，链步全 nil 静默）+ 意图更新（activeIntentID
    /// /activeProfileID；✓ 标注仍由读回 activeMatch 派生——意图镜像非判定源）+
    /// 清链。
    private func finishProfileChain() {
        guard let payload = profileChain?.payload else { return }
        profileChain = nil
        setSuccessFeedback(CellarL10n.s("control.profile.applied", payload.name))
        ProfileController.shared.setActiveIntent(id: payload.id)
    }

    /// 链中止（收敛守卫一/二命中 + 非法 LED raw 防御）：统一清链 + 「未收敛」
    /// 拒绝上屏（非静默；横幅通道 = reportLocalRejection→controlFeedback）。
    private func abortChain() {
        let name = profileChain?.payload.name ?? ""
        profileChain = nil
        reportLocalRejection(CellarL10n.s("control.profile.notConverged", name))
    }

    // MARK: - LED 链步重试 helper（ControlModels `.setMagSafeLed` case 恢复配套）

    /// LED 单步直发（retryLastAttempt `.setMagSafeLed` 臂唯一入口）：走 runControl
    /// 单槽通道——链步重试必须回同一通道（attempt 语义支撑重试/横幅/单槽）。
    /// **不照抄 v1.10 M2 旧轻路径臂**（旧臂 setMagSafeLed(mode) 走独立轻路径不写
    /// lastAttempt——隔离纪律仅对轻路径 UI 直调面保持不变，两通道并存互不渗透，
    /// 方案 §2.3 偏离登记）。成功反馈复用 `status.summary.setMagSafeLed` 键
    /// （StatusController+LEDControl.swift:62 在用——零新键，勿破坏键数账）。
    func applyLedStepDirect(_ mode: MagSafeLEDMode) {
        runControl(
            attempt: .setMagSafeLed(mode),
            operation: { try DaemonXPCClient().setMagSafeLed(mode.rawValue) },
            successFeedback: CellarL10n.s("status.summary.setMagSafeLed")
        )
    }
}
