import CellarCore
import CellarUI
import Foundation
import os

// MARK: - 多 Profile 切换编排器（0.23.18 方案 §2.3；extension 文件——
// StatusController 行数纪律拆分先例，LED/LimitExecution 同款）

extension StatusController {

    // 取证打点通道（0.23.19 热修 §2——AppConfigStore.log 先例形态；Logger
    // Sendable 跨隔离安全）。级别纪律（0.23.21-alpha 整理批分级定版）：正常链路
    // 四条（chain start/advance/dispatch/finish）.debug——每次方案切换必打 5-18
    // 行，日常零 error 噪音（缺陷已根治 + 方案-13 回归门兜底；debug 级事后
    // log show 不可检索 = 正常链路放弃事后取证，取舍已登记）；异常路径四条
    // （ABORT 双臂 + ABORT+2s 双臂）保持 .error 持久化可查——再发异常唯一事后
    // 取证主通道（0.23.19 装具一次复现破案的价值通道，用户侧 log show 可操作）；
    // .notice 中间档排除（default 级落盘可检索但用户 Console.app 常规视图可见
    // ——四类打点每次切换对非开发者用户构成噪音）。全部插值 privacy: .public
    // （os_log 隐私默认私有，否则 log show 侧只见 <private> 取证失效）——分级
    // 只动级别不动插值，privacy 恰 33 不变。
    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "profile-chain")

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
        // 取证打点①（0.23.19 热修 §2）：链启动——方案名/id/限值/模式 + 现值基线。
        Self.log.debug("chain start name=\(payload.name, privacy: .public) id=\(payload.id, privacy: .public) limits=\(payload.upperLimit, privacy: .public)/\(payload.hysteresis, privacy: .public) mode=\(payload.mode, privacy: .public) | current(mode=\(current.mode, privacy: .public), upper=\(current.upperLimit, privacy: .public), hys=\(current.hysteresis, privacy: .public))")
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
        // 取证打点②（0.23.19 热修 §2）：每推进入口——plan 步型序列 String(describing:)
        // 逐元素全形重建 T1 实际步序（ProfileApplyStep 含关联值 enum）。
        Self.log.debug("advance #executed=\(chain.executed, privacy: .public) lastStep=\(Self.forensicStep(chain.lastStep), privacy: .public) | plan=[\(Self.forensicPlan(plan), privacy: .public)] | status(mode=\(status.mode, privacy: .public), upper=\(status.upperLimit, privacy: .public), hys=\(status.hysteresis, privacy: .public))")
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
            // 取证装具 §2 P1-2：守卫臂传现读回（在作用域处——abortChain 内
            // 清链前打 ABORT 快照行 + 2s 延迟复核）。
            abortChain(status: status)
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
        // 取证打点⑤（0.23.19 热修 §2）：发步——关联值全形（LED 非法 raw 臂的
        // ABORT 行前置即本行，步载荷可直读）。
        Self.log.debug("dispatch step=\(String(describing: step), privacy: .public)")
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
                // 取证装具 §2 P1-2：本臂无现读回可传（省略 match/status 段）。
                abortChain(status: nil)
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
        // 取证打点④（0.23.19 热修 §2）：链尾收敛——executed 清链即灭，先取后清
        // （原行序不变：guard → 清链 → 聚合反馈 → 意图更新；插值前落局部量——
        // Logger 插值闭包内实例属性须显式 self，Swift 6 严格模式门）。
        let executed = profileChain?.executed ?? 0
        Self.log.debug("finish name=\(payload.name, privacy: .public) executed=\(executed, privacy: .public)")
        profileChain = nil
        setSuccessFeedback(CellarL10n.s("control.profile.applied", payload.name))
        ProfileController.shared.setActiveIntent(id: payload.id)
    }

    /// 链中止（收敛守卫一/二命中 + 非法 LED raw 防御）：统一清链 + 「未收敛」
    /// 拒绝上屏（非静默；横幅通道 = reportLocalRejection→controlFeedback）。
    ///
    /// 0.23.19 热修改签名收 `status: DaemonStatus?`（取证装具 §2 P1-2 定版）：
    /// 守卫臂传现读回（abort 时 matchReport + 全比较面现值一次读全）、LED 非法
    /// raw 臂传 nil（省略 match/status 两段）。**零判定逻辑改动**——name 捕获 →
    /// 清链 → 拒绝上屏原行序不变；装具打点（快照行 + 2s 延迟复核）纯观测面。
    private func abortChain(status: DaemonStatus?) {
        let name = profileChain?.payload.name ?? ""
        // 清链前捕获 payload/链面（§2 打点六：2s 延迟复核的输入——清链后
        // profileChain 为 nil，捕获必须前置）。
        let payload = profileChain?.payload
        let lastStep = profileChain?.lastStep
        let executed = profileChain?.executed ?? 0
        if let payload = payload {
            if let status = status {
                // 快照行（评审 P2：matchReport 八域布尔 + status 侧全比较面现值
                // 一次读全，不依赖相邻行拼凑）。nextStep = 同输入重推导计划首步
                // （applyPlan 纯函数——与守卫臂触发时的 step 恒等）。
                let report = ProfileModel.matchReport(profile: payload, current: status)
                let plan = ProfileModel.applyPlan(profile: payload, current: status)
                // 0.23.20 热修 §2 装具补强：ABORT 行补双原串打点（schedRaw= 方案
                // 侧 / expected= 现值侧——键名防与 match 段 sched= 布尔撞名）。
                // 语义比较落地后 byte 差异不再进判定域，读回未收敛中止时人工
                // 取证必须能看到双侧原串形态（schedEq 布尔是 byte 口径，真差异
                // 只能靠原串对账）。截断见 forensicTruncated（单插值形态）。
                Self.log.error("ABORT name=\(name, privacy: .public) executed=\(executed, privacy: .public) lastStep=\(Self.forensicStep(lastStep), privacy: .public) nextStep=\(Self.forensicStep(plan.first), privacy: .public) | match(\(Self.forensicMatchFace(report), privacy: .public)) | status(\(Self.forensicStatusFace(status, scheduleExpected: payload.scheduleJson), privacy: .public)) | schedRaw=\(Self.forensicTruncated(payload.scheduleJson), privacy: .public) expected=\(Self.forensicTruncated(status.scheduleJson), privacy: .public)")
            } else {
                // LED 非法 raw 臂（status nil）：省略 match/status 段（无现值
                // 可比——前置 dispatch 行已载该步全形）。
                Self.log.error("ABORT name=\(name, privacy: .public) executed=\(executed, privacy: .public) lastStep=\(Self.forensicStep(lastStep), privacy: .public) nextStep=n/a | match(n/a——status 缺席（LED 非法 raw 臂）)")
            }
            scheduleAbortRecheck(payload: payload)
        }
        profileChain = nil
        reportLocalRejection(CellarL10n.s("control.profile.notConverged", name))
    }

    // MARK: - 取证渲染 helper（0.23.19 热修 §2——纯观测装具配套，零判定消费）

    /// 步型渲染（关联值 enum 全形——String(describing:)；nil → "nil" 字面）。
    private static func forensicStep(_ step: ProfileApplyStep?) -> String {
        step.map { String(describing: $0) } ?? "nil"
    }

    /// plan 步型序列渲染（String(describing:) 逐元素 + 逗号连接）。
    private static func forensicPlan(_ plan: [ProfileApplyStep]) -> String {
        plan.map { String(describing: $0) }.joined(separator: ", ")
    }

    /// Optional 渲染（nil → "nil" 字面——现值缺席与假值不可混）。
    private static func forensicBool(_ value: Bool?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private static func forensicInt(_ value: Int?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private static func forensicUInt8(_ value: UInt8?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private static func forensicStrategy(_ value: FanStrategy?) -> String {
        value.map { String(describing: $0) } ?? "nil"
    }

    /// matchReport 单域渲染：skip 域渲 "skip"（nil 未捕获与 false 匹配不可混）。
    private static func forensicDomain(_ matched: Bool, _ skipped: Bool) -> String {
        skipped ? "skip" : String(matched)
    }

    /// matchReport 八域渲染行（ABORT 快照行与 ABORT+2s 复核行同版式——逐行直读比对；
    /// 逗号空格分隔与 status 段同构）。
    private static func forensicMatchFace(_ report: MatchReport) -> String {
        "mode=\(report.mode), limits=\(report.limits), fan=\(forensicDomain(report.fan, report.fanSkipped)), therm=\(forensicDomain(report.thermal, report.thermalSkipped)), sched=\(forensicDomain(report.schedule, report.scheduleSkipped)), cal=\(forensicDomain(report.calibration, report.calibrationSkipped)), ch=\(forensicDomain(report.ch, report.chSkipped)), led=\(forensicDomain(report.led, report.ledSkipped))"
    }

    /// DaemonStatus 全比较面现值渲染行（同上双行同版式；schedEq = 方案日程 JSON
    /// 与现值 byte 等价布尔——JSON 长串不上日志，等价面即比较面）。
    private static func forensicStatusFace(
        _ status: DaemonStatus, scheduleExpected: String?
    ) -> String {
        let fan = status.fan
        return "mode=\(status.mode), upper=\(status.upperLimit), hys=\(status.hysteresis), fanEn=\(forensicBool(fan?.enabled)), strat=\(forensicStrategy(fan?.strategy)), thresh=\(forensicInt(fan?.thresholdCentiC)), speed=\(forensicInt(fan?.speedPercent)), s2=\(forensicInt(fan?.stage2Percent)), s2rise=\(forensicInt(fan?.stage2RiseCentiC)), src=\(forensicInt(fan?.temperatureSource)), cpuT=\(forensicInt(fan?.cpuSkinThresholdCentiC)), cpuH=\(forensicInt(fan?.cpuSkinHysteresisCentiC)), therm=\(forensicInt(status.thermPauseCentiC))/\(forensicInt(status.thermHysteresisCentiC)), cal=\(forensicBool(status.calSchedEnabled))/\(forensicInt(status.calSchedIntervalDays))/\(forensicInt(status.calSchedStartHour)), ch=\(forensicBool(status.chHysteresisEnabled)), led=\(forensicUInt8(status.magSafeLed?.mode?.rawValue)), schedEq=\(scheduleExpected == status.scheduleJson)"
    }

    /// 取证串截断渲染（0.23.20 热修 §2：os_log 动态内容截断域实证——8KB 上限
    /// 串直打必被截，取证失效）。截断策略：各串取前 256 + 后 256 字节 + 总长
    /// 标注，超 512 字节拼形态 `head…tail (len=N)`；≤512 字节原样全串。nil →
    /// "nil" 字面（forensicBool 先例——缺席与空串不可混）。**单插值 helper 返回
    /// 完整串**——ABORT 双原串各占一插值，源钉-9 privacy 计数恰 33 依赖此形态
    /// （拆 head/tail/len 三插值则为 35，由计数钉强制对齐）。utf8 字节口径截断
    /// （String(decoding:) 不可达失败；多字节切边界降级替换符不崩溃——日程
    /// JSON 恒 ASCII 键名，实际不可达）。
    private static func forensicTruncated(_ raw: String?) -> String {
        guard let raw = raw else { return "nil" }
        let byteCount = raw.utf8.count
        guard byteCount > 512 else { return raw }
        let head = String(decoding: raw.utf8.prefix(256), as: UTF8.self)
        let tail = String(decoding: raw.utf8.suffix(256), as: UTF8.self)
        return "\(head)…\(tail) (len=\(byteCount))"
    }

    /// abort 2s 后单发观测（0.23.19 热修 §2 P3-2 + 二轮 P3 补比较基准）：瞬态
    /// 竞态取证的后半程——「abort 发生在某瞬态、之后读回收敛使 ✓ 点亮而失败
    /// 横幅残留」（§1 缺陷形态），2s 后 daemonStatus 快照 + matchReport 八域
    /// 复核布尔把收敛结论直接落日志不靠肉眼比对。纯观测：只读 shared.daemonStatus
    /// + 纯函数，零写入零反馈。
    private func scheduleAbortRecheck(payload: ProfilePayload) {
        let name = payload.name
        let scheduleExpected = payload.scheduleJson
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard let now = StatusController.shared.daemonStatus else {
                Self.log.error("ABORT+2s name=\(name, privacy: .public) | daemonStatus nil（失联——复核无现值可比）")
                return
            }
            let recheck = ProfileModel.matchReport(profile: payload, current: now)
            let plan = ProfileModel.applyPlan(profile: payload, current: now)
            Self.log.error("ABORT+2s name=\(name, privacy: .public) planEmpty=\(plan.isEmpty, privacy: .public) | match(\(Self.forensicMatchFace(recheck), privacy: .public)) | status(\(Self.forensicStatusFace(now, scheduleExpected: scheduleExpected), privacy: .public))")
        }
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
