import Foundation

// MARK: - 0.21.0 §3 校准共存（模式指纹识别 + 三臂抑制；方案 §3.1/§3.2；CellarCore 决策纯函数）
//
// 背景（方案 §3.1）：macOS 电池校准是黑盒（无公开信号）——系统偶发要求充满 100%
// 做电量计校准，Cellar 的限充执法（topoff 域 / App set 断言 / 域随写卫生）会对抗它。
// 本类型以**模式指纹**识别校准窗口，识别期内三臂全抑制（R1-P1-5 定版）：
// ① topoff 臂（strike 计数 + 超带轻量重申 + 自愈探针推进）；② App set 断言
//（calibrationSuspected 纳入 Topoff.convergenceRoute 的 desired 派生——校准态
// desired=nil，断言静默）；③ 域随写卫生暂停（校准需要充满 100——域值随写会钉住
// agent 停充）。
//
// 诚实边界（R1-P3 登记）：模式识别有误报/漏报可能；**指纹门 target ≤ 90 的盲区**——
// target 91-94 的用户在真实校准期无抑制（与违规不可区分），观察期调参。
// 防误报：target=100 设置时指纹永不满足（target 门排除）。
//
// **已知交互登记（随批 review）**：①迟滞挂载期指纹结构性不可达（percent 被钳
// ≤ target+滞回 ≤ 92——CHHysteresis.swift 头注 P3-2，备用执法优先，无共存门）；
// ②§1.5 对账环补偿臂经 `residualCompensationExempt` App 侧近似豁免（本文件尾——
// daemon 指纹在该配置不可达时的引导链，两个独立判定）。
//
// 分层（照 Topoff/CHHysteresis 先例）：状态机与抑制判定全在本文件纯函数
//（CellarCoreCheck 场景域钉死），daemon 侧只做副作用（persistLog 进出、
// violationTicks 清零、链路静默消费）。
//
// 运行态 `State` **不持久化**（照 OrchestrationState 先例）：重启即清——代价 =
// 校准中 daemon 重启后重走 10 tick 识别窗（5 min 抑制空窗，识别期内既有链照常，
// strike 有 20 tick 窗 + ×3 封顶兜底，不构成执法回归），换零新增落盘面。

/// 校准共存常量与判定纯函数（方案 §3.1 判据逐字）。
public enum CalibrationCoexistence {
    /// 指纹持续窗（10 tick = 5 min，30s 心跳；CellarCore 常量）。**识别窗 <
    /// strike 验证窗 20 tick**（R1-P2-4）——识别命中时校准证据优先于违规证据，
    /// 命中拍同步清零 topoff violationTicks（daemon 消费）。
    public static let detectionTicks = 10
    /// 指纹电量门（percent ≥ 95）。
    public static let percentGate = 95
    /// 指纹 target 门（policy.target ≤ 90）。**盲区登记（R1-P3）**：target 91-94
    /// 的用户真实校准期无抑制（与违规不可区分）。
    public static let targetGate = 90

    /// 识别运行时状态（daemon 锁内内存态；不持久化——见文件头注）。
    public struct State: Equatable, Sendable {
        /// 校准抑制态（true = 三臂抑制中——wire `DaemonStatus.calibrationSuspected`
        /// 数据源）。
        public var suspected: Bool
        /// 指纹连续命中计数（识别窗推进；指纹失效拍清零）。
        public var fingerprintTicks: Int

        public init(suspected: Bool = false, fingerprintTicks: Int = 0) {
            self.suspected = suspected
            self.fingerprintTicks = fingerprintTicks
        }

        /// 空状态（daemon 启动初值）。
        public static let empty = State()
    }

    /// 每拍推进结果（daemon 依此做边沿副作用：进出 persistLog / violationTicks 清零）。
    public struct TickOutcome: Equatable, Sendable {
        /// 推进后的识别状态。
        public let state: State
        /// 识别命中拍（false→true 边沿）：daemon 清零 topoff violationTicks +
        /// persistLog 进入。
        public let risingEdge: Bool
        /// 退出拍（true→false 边沿）：daemon persistLog 退出（既有链下一拍恢复）。
        public let fallingEdge: Bool

        public init(state: State, risingEdge: Bool, fallingEdge: Bool) {
            self.state = state
            self.risingEdge = risingEdge
            self.fallingEdge = fallingEdge
        }
    }

    /// 单拍指纹命中（§3.1 判据逐字）：
    /// `percent ≥ 95 ∧ ext ∧ charging ∧ policy.target ≤ 90`。
    /// target=100（完全放开设置）时永不满足——防误报锚。
    public static func fingerprintMatches(
        percent: Int, externalConnected: Bool, isCharging: Bool, target: Int
    ) -> Bool {
        percent >= percentGate && externalConnected && isCharging && target <= targetGate
    }

    /// 识别状态机每拍推进（纯函数，判定次序即契约）：
    /// - **完全放开窗惰性拍**（fullOpenWindow = fullOnce 临时放开窗 ∨ chargingDisabled
    ///   日程窗——「target=100 设置时指纹永不满足」防误报锚的窗形态推广）：状态原样
    ///   返回（不推进计数、不评估进出）——窗内充电到 100 是用户/日程显式意图，与
    ///   校准指纹同形，计入会构成假阳性；
    /// - 抑制态：`percent < 95 ∨ target > 90` → 退出（false + 计数清零 + fallingEdge；
    ///   方案 §3.1 退出判据逐字——ext/charging 不在退出集：拔电/停充拍电量尚未回落
    ///   时抑制延续无害——三臂在非充电压本就零触达，percent < 95 后自然收敛）；
    ///   其余拍维持。
    /// - 非抑制态：指纹命中 → 计数 +1，满 10 tick → 命中（true + risingEdge）；
    ///   未命中 → 计数清零（中断即重窗——瞬时满电顶充不构成校准证据）。
    public static func tick(
        state: State,
        percent: Int,
        externalConnected: Bool,
        isCharging: Bool,
        target: Int,
        fullOpenWindow: Bool = false
    ) -> TickOutcome {
        var s = state
        // 完全放开窗：指纹惰性（窗语义见上——缺省 false = 既有构造零 diff）。
        if fullOpenWindow {
            return TickOutcome(state: s, risingEdge: false, fallingEdge: false)
        }
        if s.suspected {
            if percent < percentGate || target > targetGate {
                s.suspected = false
                s.fingerprintTicks = 0
                return TickOutcome(state: s, risingEdge: false, fallingEdge: true)
            }
            return TickOutcome(state: s, risingEdge: false, fallingEdge: false)
        }
        if fingerprintMatches(
            percent: percent, externalConnected: externalConnected,
            isCharging: isCharging, target: target
        ) {
            s.fingerprintTicks += 1
            if s.fingerprintTicks >= detectionTicks {
                s.suspected = true
                s.fingerprintTicks = 0
                return TickOutcome(state: s, risingEdge: true, fallingEdge: false)
            }
            return TickOutcome(state: s, risingEdge: false, fallingEdge: false)
        }
        s.fingerprintTicks = 0
        return TickOutcome(state: s, risingEdge: false, fallingEdge: false)
    }
}

// MARK: - 三臂抑制计划（R1-P1-5 定版——daemon 消费点钉单，新增执法臂必须对照）

extension CalibrationCoexistence {
    /// 三臂抑制计划（纯值——daemon 按字段逐臂消费；CellarCoreCheck 场景域钉死）。
    public struct SuppressionPlan: Equatable, Sendable {
        /// ① topoff 臂静默：strike 验证窗不推进（channelTick/healTick 不调用——
        ///   含自愈探针观察推进）∧ 超带轻量重申不发（notifyOnly 随之静默）。
        ///   daemon 消费点：topoffConvergenceRouteLocked 校准早退分支。
        /// ③ 域随写卫生暂停：≥80 汇聚段不随写域值（校准需要充满 100——域值随写
        ///   会钉住 agent 停充）。同一消费点（早退分支越过卫生写臂）。
        public let suspendTopoffArms: Bool
        /// ② App set 断言静默：desired 派生置 nil（Topoff.convergenceRoute 的
        ///   calibrationSuspected 分支）——assertionRequest 规则 1 兜底 .none。
        public let silenceAssertion: Bool

        public init(suspendTopoffArms: Bool, silenceAssertion: Bool) {
            self.suspendTopoffArms = suspendTopoffArms
            self.silenceAssertion = silenceAssertion
        }
    }

    /// 抑制计划判定（输入 = 识别态 + 完全放开窗；非抑制态两臂全 false = 既有链
    /// 零变化锚）。**完全放开窗豁免**（fullOpenWindow = fullOnce 窗 ∨ chargingDisabled
    /// 窗）：窗内 topoff 执法臂天然指向 100（convergenceTarget 强制 100——域随写
    /// 100 与校准同向；违规判定对 target=100 恒假，strike 窗天然零推进），抑制反而
    /// 会冻结「域随写 100」的对账写、阻断临时放开——窗优先。
    /// ⚠️ **两窗断言臂不同权（P3-1 注记，与 Topoff.convergenceRoute 次序对齐）**：
    /// fullOnce 窗（用户显式放开）分支**先于**校准分支 → 窗内断言 100 保持；日程窗
    ///（chargingDisabled）分支**后于**校准分支 → 窗 ∧ 校准态 desired=nil（断言臂
    /// 让位）。该角良性自洽：suspected 要求 percent ≥95 持续充电——MCL 若 <100 则
    /// 电池回落 95 以下嫌疑自消、断言 100 随后恢复；MCL 已被校准推至 100 时窗语义
    /// 本就满足。场景 校准共存-11 扩臂钉死。
    public static func suppressionPlan(suspected: Bool, fullOpenWindow: Bool = false) -> SuppressionPlan {
        let suppress = suspected && !fullOpenWindow
        return SuppressionPlan(suspendTopoffArms: suppress, silenceAssertion: suppress)
    }
}

// MARK: - §1.5 对账环 × 校准共存（P2-1 修复：补偿臂校准可疑豁免——App 侧独立判定）

extension CalibrationCoexistence {
    /// §1.5 关断残留对账环的校准可疑豁免（**App 侧独立近似指纹**——CellarCoreCheck
    /// 场景域钉死，App `reconcileShutdownResidual` 消费）：
    /// `readback > expected ∧ percent ≥ 95 ∧ charging ∧ target ≤ 90` → 豁免本轮补偿。
    ///
    /// 为什么不能只门 daemon 的 `calibrationSuspected`（review P2-1 失败链）：target 75
    /// ∧ 编排关（合法稳态，期望 80）∧ 系统真实校准推 MCL 到 100 → 对账环 ≤30s set 80
    /// 压回 → 电池钳在 80-85 → **percent ≥95 永不满足 → daemon 指纹结构性不可达**。
    /// App 侧近似是引导链：豁免放行 MCL 保持 100 → 电池自由充 → percent 稳定 ≥95 →
    /// daemon 指纹（10 tick 窗）接管、三臂抑制生效。
    ///
    /// ⚠️ **与 daemon 指纹是两个独立判定**（App 无 daemon 的 10 tick 窗状态）——
    /// 单拍近似的诚实边界：①可能漏抑制对账一轮（下轮 30s 重评）；②percent 爬坡到
    /// ≥95 前，压回循环照旧（校准爬坡循环成本登记，观察期调参）；③target 91-94 盲区
    /// 同 daemon 指纹（R1-P3）；④无 ext 门（充电 ⟹ 外接的物理蕴含，App 侧从简）；
    /// ⑤放电相（percent ≥95 ∧ !charging）不豁免——对账照常（校准放电相 MCL 值不对
    /// 抗放电；再充相的压回交互随批登记观察项）。
    ///
    /// 证据不足（percent/isCharging 缺席）→ false = 补偿照旧（保守方向：关断残留
    /// 语义优先，不因观测缺席改变既有行为）。
    public static func residualCompensationExempt(
        readback: Int,
        expected: Int,
        percent: Int?,
        isCharging: Bool?,
        target: Int
    ) -> Bool {
        // 读回未超期望 → 无「压回」意图可豁免（对账环本就不动作）。
        guard readback > expected else { return false }
        guard let percent, let isCharging else { return false }
        return percent >= percentGate && isCharging && target <= targetGate
    }
}
