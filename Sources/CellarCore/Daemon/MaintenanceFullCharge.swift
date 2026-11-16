import Foundation

// MARK: - 0.23.25 §2.2 charge-to-full 系统维护充满感知与退让（状态机纯函数；
// 任务书 docs/plans/phase9-0.23.25-maintenance-fullcharge.md §2.2；CellarCore 决策
// 纯函数，照 CalibrationCoexistence.swift 同目录同形态）
//
// 背景（§0 实证摘要）：macOS 27 powerd batterygauging 维护「上次充满 staleness」——
// `Last full charge date` 距今 ≥21 天（实测阈值 20.9 天判 too recent / 21.0 天判
// try and charge to full）且机器插电时，任意充电决策评估会发起
// `Charge To Full System Level Request:1` → powerd post
// `com.apple.system.powersources.chargingtofulloverride` → SOC limit 政策被系统
// **有意挂起**（`SOC limit policy suspend due to mitigation active`）→ 域写 75 正确
// 且读回一致但物理充电直达 100%。缠斗逻辑上赢不了——本类型把该形态识别出来并
// **配合让位**（充满约 15-25 min，系统自动撤销 override 并恢复 SOC limit，充满后
// Cellar 无缝恢复执法）。
//
// 识别两通道（§2.2，任一满足）：
// ① **通知快路径**——Darwin 通知 `chargingtofulloverride` 边沿拍（main.swift
//   CFNotificationCenter 回调转发，全库无 CFNotificationCenter 先例本批新引）；
//   Darwin 通知无 payload——边沿语义由本状态机判定，不假设 post 次数；通知丢失
//   只影响响应时延（指纹保底 ≤90s），不影响正确性；
// ② **行为指纹保底路径**——连续 ≥3 拍：`读回 limit == 100 ∧ isCharging ∧
//   percent > target + violationMargin ∧ ext`（四条件联合——R3 防误报；复用
//   `Topoff.violationMarginPercent` 既有常量定值）。3 拍 < 校准识别窗 10 tick
//   ——校准证据优先序不被抢占（R8 注记：校准抑制活跃期读回臂不执行 → 指纹通道
//   结构性不可达，仅通知通道可进入；校准充满完成后自然退出，两态并存无冲突）。
//
// 退出三臂（任一满足，退出即 B6 边沿重申写——daemon 侧边沿副作用）：
// ① 最近读回 `limit != 100`（powerd 恢复 SOC limit ∧ PowerUIAgent 重写域）∧
//   当前拍不构成指纹；② **超时 2h 强退**（正常 15-25 min；兜底系统 hang，强退记
//   warn）；③ mode 非 active 时照模式关断清理优先（既有链——DaemonCore+Topoff.swift
//   `guard let convergenceTarget` 关断清理先于抑制早退的结构不变；状态机无 mode
//   输入，本臂由 daemon 结构承接——CellarCoreCheck 不可 import cellar-daemon，
//   注记登记走真机走查兜底，照 CalibrationCoexistenceDomain 同款）。
//
// 退让语义（B5 红线——执法主干零改动）：Topoff.swift 纯函数本体零改动；
// 退让 = 调用侧早退（strike 验证窗 + 超带轻量重申 + 域随写卫生三臂静默——
// 不与 PowerUIAgent 抢域写）+ violationTicks 清零（证据优先，照校准抑制
// R1-P2-4 同款）+ **退出边沿显式重申写 target**（B6：channelTick 幂等写仅在
// `lastWrittenLimit != target` 时发射，退让期账面值保持 =target，恢复第一拍该
// 分支不发射——故恢复必须边沿显式重申；边沿写失败的兜底 = 既有读回覆写签名
// 重写臂）。退出评估支持**同拍新鲜读回重评**（daemon 早退臂结构第三步：maintenance-
// scoped 读回 → 写 state.lastReadback → tick 重评——signalPending 已在推进拍
// 消费，重评不重走进入通道）。
//
// 读回数据流（终审 P3 钉死——「tick 消费上拍锁存值」）：tick 统一消费
// `state.lastReadback`（上拍锁存）——进入前由既有五臂读回预检结果回填、退让期由
// maintenance-scoped 读回（周期 10 min + 信号边沿拍立即一次）回填。
//
// 分层（照 Topoff/CalibrationCoexistence 先例）：状态机与抑制判定全在本文件纯函数
//（CellarCoreCheck 场景域钉死），daemon 侧只做副作用（persistLog 进出、
// violationTicks 清零、maintenance-scoped 读回、B6 边沿重申写、链路静默消费）。
//
// 运行态 `State` **不持久化**（B8——照 CalibrationCoexistence.State 先例）：退让中
// daemon 重启 → ≤90s 指纹重识别空窗（3 拍 × 30s 心跳），期间回既有缠斗（良性，
// 任务书 §5 R7 登记），换零新增落盘面。

/// charge-to-full 维护充满常量与判定纯函数（§2.2 判据逐字）。
public enum MaintenanceFullCharge {
    /// 系统维护充满的域读回签名值（PowerUIAgent 把充电上限域覆写 limit=100——§0
    /// 实证；读回 == 100 即 override 在位指纹）。与 `Topoff.shutdownLimit` 同值但
    /// 语义独立（关断清理域随写值）——勿合并常量（照 suppressionThreshold/streak=2
    /// 数值巧合先例）。
    public static let overrideLimit = 100
    /// 行为指纹持续窗（3 拍 = 90s，30s 心跳）。**< 校准识别窗 10 tick**——校准
    /// 证据优先序不被抢占（§2.2；R8：校准抑制期指纹通道结构性不可达——登记接受）。
    public static let fingerprintTicksRequired = 3
    /// maintenance-scoped 读回节奏（周期 10 min——照健康稳态周期采样 2 子进程/
    /// 10 min 成本口径；信号边沿拍立即一次另计，见 `readbackDue`）。15-25 min
    /// 充满窗内 2-3 次读回即覆盖恢复检出，不退化为 2h 超时。与
    /// `Topoff.periodicReadbackInterval` 同值但语义独立（topoff 五臂周期盯防 vs
    /// 退让期恢复检出）——勿合并常量（同源合并需跨类型耦合，独立语义分开演进）。
    public static let readbackInterval: TimeInterval = 600
    /// 超时强退（正常 15-25 min；2h 兜底系统 hang——强退记 warn，R2：缠斗回
    /// 既有链，strike 链接管，诚实降级语义不变）。
    public static let timeout: TimeInterval = 2 * 3600

    /// 识别运行时状态（daemon 锁内内存态；**不持久化**——B8，见文件头注）。
    public struct State: Equatable, Sendable {
        /// 退让态（true = 三臂早退中——wire `DaemonStatus.maintenanceFullChargeActive`
        /// 数据源）。
        public var active: Bool
        /// 进入时刻（超时 2h 强退判定输入；退出清 nil）。
        public var enteredAt: Date?
        /// 最近一次域读回 limit（**双重可选**——外层 nil = 从未读过 ∨ 读失败
        ///（fail-open 证据等价）；.some(nil) = 读到域但键缺席/解析失败；
        /// .some(.some(v)) = 最近读回值）。tick 统一消费**上拍锁存值**：进入前由
        /// 既有五臂读回预检回填（DaemonCore+Topoff.swift 读回臂）、退让期由
        /// maintenance-scoped 读回回填（daemon 侧写——本拍消费的是上拍值）。
        public var lastReadbackLimit: Int??
        /// 行为指纹连续命中计数（识别窗推进；指纹失效拍清零）。
        public var fingerprintTicks: Int

        public init(
            active: Bool = false, enteredAt: Date? = nil,
            lastReadbackLimit: Int?? = nil, fingerprintTicks: Int = 0
        ) {
            self.active = active
            self.enteredAt = enteredAt
            self.lastReadbackLimit = lastReadbackLimit
            self.fingerprintTicks = fingerprintTicks
        }

        /// 空状态（daemon 启动初值；重启即空 = B8 重启语义——≤90s 指纹重识别空窗）。
        public static let empty = State()
    }

    /// 每拍推进结果（daemon 依此做边沿副作用：进出 persistLog + LogEvent /
    /// violationTicks 清零 / B6 退出边沿重申写 / 超时强退 warn）。
    public struct TickOutcome: Equatable, Sendable {
        /// 推进后的状态。
        public let state: State
        /// 逐臂计划（suspendEnforcementArms 三臂早退 + violationTicksReset 证据优先）。
        public let plan: Plan
        /// 进入拍（false→true 边沿）：daemon persistLog 进入 + violationTicks 清零。
        public let risingEdge: Bool
        /// 退出拍（true→false 边沿）：daemon persistLog 退出 + B6 边沿重申写。
        public let fallingEdge: Bool
        /// 超时强退（fallingEdge ∧ 臂②——daemon warn 日志面，R2 可溯源）。
        public let timeoutExit: Bool

        public init(
            state: State, plan: Plan, risingEdge: Bool, fallingEdge: Bool,
            timeoutExit: Bool = false
        ) {
            self.state = state
            self.plan = plan
            self.risingEdge = risingEdge
            self.fallingEdge = fallingEdge
            self.timeoutExit = timeoutExit
        }
    }

    /// 逐臂计划（照 CalibrationCoexistence.SuppressionPlan 逐臂消费形态——纯值，
    /// daemon 按字段逐臂消费；CellarCoreCheck 场景域钉死）。
    public struct Plan: Equatable, Sendable {
        /// 三臂早退（配合语义核心：不与 PowerUIAgent 抢域写）：① strike 验证窗
        /// 不推进（channelTick/healTick 不调用）；② 超带轻量重申不发（notifyOnly
        /// 随之静默）；③ 域随写卫生暂停。daemon 消费点：topoffConvergenceRouteLocked
        /// maintenance 早退臂（五臂读回预检与两写臂全在早退面之后——零触达）。
        public let suspendEnforcementArms: Bool
        /// 进入边沿拍 violationTicks 清零（证据优先——照校准抑制 R1-P2-4 同款；
        /// 退让开始即不带旧违规证据，防出退让后首拍误 strike）。
        public let violationTicksReset: Bool

        public init(suspendEnforcementArms: Bool, violationTicksReset: Bool) {
            self.suspendEnforcementArms = suspendEnforcementArms
            self.violationTicksReset = violationTicksReset
        }
    }

    /// 单拍行为指纹（§2.2 判据逐字）：`readback == 100 ∧ isCharging ∧
    /// percent > target + violationMargin ∧ ext`（四条件联合——R3 防误报）。
    /// - readback：最近域读回 limit（外层已解包；nil = 从未读过/读失败/键缺席
    ///   ——证据不足不推进）；
    /// - percent/externalConnected/isCharging：采样缺席（nil）→ false（同
    ///   channelTick 采样缺席拍不推进窗的防误判纪律）；
    /// - margin 复用 `Topoff.violationMarginPercent`（任务书 §2.2 钉死——既有
    ///   常量定值，勿另立常量漂移）。
    public static func fingerprintMatches(
        readback: Int?, percent: Int?, externalConnected: Bool?,
        isCharging: Bool?, target: Int
    ) -> Bool {
        guard readback == overrideLimit else { return false }
        guard let percent, let externalConnected, let isCharging else { return false }
        return percent > target + Topoff.violationMarginPercent
            && externalConnected && isCharging
    }

    /// 识别状态机每拍推进（纯函数，判定次序即契约）：
    /// - **退让态**：三退出臂评估（任一满足即退出 + fallingEdge）——
    ///   ① 最近读回 `limit != 100` ∧ 当前拍不构成指纹（系统恢复 SOC limit；读回
    ///   外层 nil/内层 nil 不构成退出证据——读失败不改变退让态，fail-open）；
    ///   ② 超时 2h 强退（timeoutExit = true，daemon warn）；③ mode 非 active
    ///   由 daemon 既有结构承接（关断清理先于早退臂——状态机无 mode 输入，头注）；
    ///   其余拍维持（suppressEnforcementArms 恒 true）。
    /// - **非退让态**：① 通知边沿拍（signalPending）→ 立即进入（risingEdge）；
    ///   ② 行为指纹命中 → 计数 +1，满 3 拍 → 进入；未命中 → 计数清零（中断即
    ///   重窗——瞬时读回 100 不构成 override 证据）。通知边沿进入无指纹门（Darwin
    ///   post 即系统已发起 override——§2.1「信号仅作立即评估触发器」的进入面；
    ///   误报代价 = 一次退让观察窗，无执法损失——R3 登记）。
    /// - `readback`：上拍锁存值（daemon 传 `state.lastReadbackLimit`——头注数据
    ///   流；推进结果把注入值回写 state，重评路径注入新鲜读回时同形）。
    public static func tick(
        state: State,
        signalPending: Bool,
        readback: Int??,
        percent: Int?,
        externalConnected: Bool?,
        isCharging: Bool?,
        target: Int,
        now: Date
    ) -> TickOutcome {
        var s = state
        // 读回锁存推进：本拍注入值即「上拍锁存」（daemon 传 state.lastReadbackLimit
        // 时为幂等回写；早退臂重评路径注入新鲜读回时为真实推进）。
        s.lastReadbackLimit = readback
        let currentReadback = readback.flatMap { $0 }
        if s.active {
            // ---- 退出评估（三臂，判定次序即契约）----
            // 臂①：最近读回 limit != 100 ∧ 当前拍不构成指纹（系统恢复；读回缺席
            // 不构成退出证据——fail-open 维持退让态）。
            let fingerprintNow = fingerprintMatches(
                readback: currentReadback, percent: percent,
                externalConnected: externalConnected, isCharging: isCharging,
                target: target)
            if let limit = currentReadback, limit != overrideLimit, !fingerprintNow {
                s.active = false
                s.enteredAt = nil
                s.fingerprintTicks = 0
                return TickOutcome(
                    state: s, plan: suppressionPlan(active: false),
                    risingEdge: false, fallingEdge: true, timeoutExit: false)
            }
            // 臂②：超时 2h 强退（兜底系统 hang；daemon warn 可溯源——R2）。
            if let enteredAt = s.enteredAt, now.timeIntervalSince(enteredAt) >= timeout {
                s.active = false
                s.enteredAt = nil
                s.fingerprintTicks = 0
                return TickOutcome(
                    state: s, plan: suppressionPlan(active: false),
                    risingEdge: false, fallingEdge: true, timeoutExit: true)
            }
            // 臂③ mode 非 active：daemon 既有结构承接（关断清理先于早退臂——
            // 状态机无 mode 输入，头注登记）。
            return TickOutcome(
                state: s, plan: suppressionPlan(active: true),
                risingEdge: false, fallingEdge: false)
        }
        // ---- 进入通道（两通道任一满足）----
        // ① 通知边沿拍：立即进入（Darwin post 即系统已发起 override——快路径；
        // 进入即清指纹计数——边沿证据替代累积证据）。
        if signalPending {
            s.active = true
            s.enteredAt = now
            s.fingerprintTicks = 0
            return TickOutcome(
                state: s, plan: suppressionPlan(active: true),
                risingEdge: true, fallingEdge: false)
        }
        // ② 行为指纹：连续 ≥3 拍（保底路径——通知不可达时 ≤90s 检出，R1）。
        if fingerprintMatches(
            readback: currentReadback, percent: percent,
            externalConnected: externalConnected, isCharging: isCharging,
            target: target) {
            s.fingerprintTicks += 1
            if s.fingerprintTicks >= fingerprintTicksRequired {
                s.active = true
                s.enteredAt = now
                s.fingerprintTicks = 0
                return TickOutcome(
                    state: s, plan: suppressionPlan(active: true),
                    risingEdge: true, fallingEdge: false)
            }
            return TickOutcome(
                state: s, plan: suppressionPlan(active: false),
                risingEdge: false, fallingEdge: false)
        }
        s.fingerprintTicks = 0
        return TickOutcome(
            state: s, plan: suppressionPlan(active: false),
            risingEdge: false, fallingEdge: false)
    }

    /// maintenance-scoped 读回到期判定（早退臂节奏纯函数钉面，照
    /// `Topoff.periodicReadbackDue` 先例）：信号边沿拍恒 due（立即一次——充满完成
    /// 时下一读回即见恢复）；nil = 首拍即读；`now − last ≥ readbackInterval` → due
    /// （≥ 边界钉面）。**读尝试即推进**簿记归 daemon（评审 P2-2 先例——失败不加速
    /// 重试，失败周期 10 min 盲区有界）。
    public static func readbackDue(last: Date?, signalPending: Bool, now: Date) -> Bool {
        if signalPending { return true }
        return last.map { now.timeIntervalSince($0) >= readbackInterval } ?? true
    }
}

// MARK: - 三臂退让计划（照 CalibrationCoexistence.SuppressionPlan 逐臂消费形态；
// daemon 消费点钉单，新增执法臂必须对照）

extension MaintenanceFullCharge {
    /// 退让计划判定（输入 = 退让态；非退让态两臂全 false = 既有链零变化锚）。
    /// 退让态 = 三臂早退 + violationTicks 清零（violationTicksReset 仅进入边沿拍
    /// 被 daemon 消费——非边沿退让拍违规窗本就冻结〔channelTick 不调用〕，恒 true
    /// 无副作用面，钉面简化）。
    public static func suppressionPlan(active: Bool) -> Plan {
        Plan(suspendEnforcementArms: active, violationTicksReset: active)
    }
}
