import Foundation

// MARK: - WP2 topoffprotection <80% 限充通道（方案 §3；CellarCore 决策纯函数 + 域写入器）

/// sub80 通道态（DaemonStatus.sub80State wire 三态，方案 §3.2；R3-P3 off 语义）：
/// - `active`：topoff 通道承载中（<80 执法或 ≥80 域随写卫生——域管理面活跃）；
/// - `degraded`：重申×3 封顶后诚实降级（域随写 80 + 编排钳 80；每小时自愈重探）；
/// - `off`：两条关断清理路径后（mode→disabled 关断清理 / 编排开关关断且目标 ≥80
///   域随写 100）——防「UI 已停用、实际钉 75」不诚实态；
/// - 26/无 sub80 能力机器不填（缺席 = 无此特性）。
public enum Sub80State: String, Codable, Equatable, Sendable {
    case active, degraded, off
}

/// topoff 通道常量与判定纯函数（方案 §3.2/§3.3；§11.5.1 实测事实源）。
public enum Topoff {
    /// 行为验证窗（N=20 tick = 10 min——与 §11.5.1 接管时序 t+5~10min 对齐；
    /// 重写即重置动力学，误报最多耗一次 strike）。
    public static let verificationTicks = 20
    /// 违规判定余量（percent > target + 2 才算通道未生效证据）。
    public static let violationMarginPercent = 2
    /// 重申冷却（10 min；窗长本身 10 min 自然满足——护栏防外源快触发）。
    public static let reassertionCooldown: TimeInterval = 600
    /// strike 上限（重申×3 封顶 → 诚实降级；初写后第 3 个失败窗触发降级写）。
    public static let strikeLimit = 3
    /// 降级自愈重探节奏（每小时：域写 target + 20 tick 行为观察）。
    public static let healProbeInterval: TimeInterval = 3600
    /// 违规计数复位窗（连续 24h 无违反 → strikes 复位，R1-P3）。
    public static let violationResetWindow: TimeInterval = 24 * 3600
    /// 0.20.2 §3：超带轻量重申冷却（5 min——通知风暴封顶；与 strike 重申冷却
    /// reassertionCooldown（10 min、lastWriteAt 域写路径）相互独立，簿记分离）。
    public static let notifyReassertCooldown: TimeInterval = 300
    /// 降级稳态域随写值（= 编排钳制值，§3.2 诚实降级）。
    public static let degradedLimit = 80
    /// 关断清理域随写值（§3.7——先值后态+通知）。
    public static let shutdownLimit = 100
    /// 0.20.1 热修：topoff 子进程看门狗超时（秒）——真机 wedge 事件（走查②：strike
    /// 路径子进程挂起持全局锁→daemon 整体楔死）的修复常量。
    public static let subprocessTimeoutSeconds = 10

    /// 域路径 / 通知名 / 键名（SMC-NOTES §11.5/§11.5.1 实测；0.19.20 实验期同域）。
    public static let domainPath = "/var/root/Library/Preferences/com.apple.smartcharging.topoffprotection"
    public static let notifyName = "com.apple.smartcharging.defaultschanged"
    public static let limitKey = "mclLimitValue"
    public static let featureStateKey = "MCLFeatureState"

    /// 违规一拍判定（§3.2）：`percent > target + 2 ∧ ext ∧ isCharging` = 通道未生效
    /// 的一拍证据（agent 应在目标以上停充；仍在充 = 域值未被跟随）。
    public static func isViolationTick(
        percent: Int, target: Int, externalConnected: Bool, isCharging: Bool
    ) -> Bool {
        percent > target + violationMarginPercent && externalConnected && isCharging
    }

    /// 通道存活强证据（自愈恢复判定；**P1 评审修法 ①——「钉在 target」指纹**）：
    /// `ext ∧ !isCharging ∧ percent ∈ [target-1, target]`。native 地板 80 使该窗对
    /// 所有 <80 目标无歧义——死通道 + native 钳 80 停充（80 ∉ [target-1, target]）
    /// 不再构成假恢复证据（修死故障臂 (a)）；[target, target+2] 不可用（target 78/79
    /// 时 native 80 落窗内）。target 正点停充（percent == target）构成证据。
    public static func isEnforcementEvidence(
        percent: Int, target: Int, externalConnected: Bool, isCharging: Bool
    ) -> Bool {
        externalConnected && !isCharging && percent >= target - 1 && percent <= target
    }

    /// §3.7 关断清理幂等守卫（纯函数钉面——0.20.2 §2 off 持久化跨重启兼容论证）：
    /// `(100, off)` 态 → false（零写恢复）；重启 fresh lastWrittenLimit（nil）→
    /// true（一次幂等重写 100 + off 后归位零写稳态——off 诚实性不因重启丢失，
    /// 守卫允许带 off 重试直至写成功）。
    public static func shutdownCleanupNeeded(lastWrittenLimit: Int?, off: Bool) -> Bool {
        lastWrittenLimit != shutdownLimit || !off
    }
}

/// 域写入结果（§3.3 原子序的调用侧呈现）。
public enum TopoffWriteOutcome: Equatable, Sendable {
    /// 两笔写均成功（notified = 通知发送结果；失败不阻塞——agent 分钟级跟随兜底）。
    case written(notified: Bool)
    /// 任一笔写失败（**不通知**——原子序红线；调用方下 tick 幂等重写）。
    case failed(String)
}

/// topoffprotection 域写入器（§3.3 原子序；root 域写）。
///
/// IO 全注入（`run`/`notify` 闭包——CellarCoreCheck 场景域可测）；生产接线：
/// `defaults write <path> <key> -int N`（§11.5 spike 实测形态）+ `notifyutil -p`。
public enum TopoffWriter {
    /// 原子序写入：**先 `mclLimitValue` 后 `MCLFeatureState`**（中间崩溃最多留惰性态
    /// ——state=旧值 + limit=新值，agent 不跟随新执法）；**两笔写均成功才发通知**；
    /// tick 幂等重写收敛（同值重写无痕）。
    public static func write(
        limit: Int,
        defaultsPath: String = Topoff.domainPath,
        run: (String, [String]) -> (output: String, exitCode: Int32),
        notify: (String) -> Bool
    ) -> TopoffWriteOutcome {
        let limitWrite = run("/usr/bin/defaults", [
            "write", defaultsPath, Topoff.limitKey, "-int", String(limit)
        ])
        guard limitWrite.exitCode == 0 else {
            return .failed("mclLimitValue 写入失败（exit \(limitWrite.exitCode)）")
        }
        let stateWrite = run("/usr/bin/defaults", [
            "write", defaultsPath, Topoff.featureStateKey, "-int", "1"
        ])
        guard stateWrite.exitCode == 0 else {
            return .failed("MCLFeatureState 写入失败（exit \(stateWrite.exitCode)）")
        }
        return .written(notified: notify(Topoff.notifyName))
    }
}

/// topoff 通道运行时状态（daemon 锁内内存态）。0.20.2 §2 起**诚实性五字段**
///（degraded / strikes / off / lastViolationAt / lastHealProbeAt）经
/// TopoffPersistedState 跨重启持久化（写入点钉在 sub80 门内、触发源仅 strike/
/// 降级跳变/off 关断——TopoffStateStore）；其余瞬态字段照 OrchestrationState
/// 先例不持久化：重启即重探，lastWritten 丢失 → 首 tick 幂等重写一次（停机期间
/// 域实况漂移的最便宜对账，R1-P2）。
public struct TopoffChannelState: Equatable, Sendable {
    /// 当前通道承载目标（nil = 从未承载）。
    public var activeTarget: Int?
    /// 最近一次**成功**写入的域值（幂等重写判定输入）。
    public var lastWrittenLimit: Int?
    /// 最近一次成功写入时刻（重申冷却 / 自愈节奏输入）。
    public var lastWriteAt: Date?
    /// 行为验证窗计数（连续违规 tick；≥20 → strike）。
    public var violationTicks: Int
    /// 已耗 strike 数（重申×3 封顶 → 降级）。
    public var strikes: Int
    /// 降级态（域随写 80 + 编排钳 80 + 每小时自愈重探）。
    public var degraded: Bool
    /// 自愈观察窗进行中（此间编排静默——topoff 独占执法，行为观察有效前提）。
    public var healProbeActive: Bool
    /// 自愈观察窗计数。
    public var healProbeTicks: Int
    /// 上次自愈重探时刻（1h 节奏）。
    public var lastHealProbeAt: Date?
    /// 最近违规时刻（24h 无违反 → strikes 复位，R1-P3）。
    public var lastViolationAt: Date?
    /// 关断清理已执行（sub80State=off 源；通道重新承载即清除）。
    public var off: Bool
    /// 0.20.2 §3：上次超带轻量重申时刻（5 min 通知冷却簿记）。**内存态不持久化**
    ///（重启后冷却重置的代价 = 可能多发一次通知，无害——方案 §3 契约钉死）。
    public var lastReassertAt: Date?

    public init() {
        violationTicks = 0
        strikes = 0
        degraded = false
        healProbeActive = false
        healProbeTicks = 0
        off = false
    }
}

/// topoff 通道每拍推进计划（纯函数输出——daemon 只执行副作用：写域/通知/簿记）。
public struct TopoffTickPlan: Equatable, Sendable {
    /// 需写入的域值（nil = 本拍不写）。
    public let writeLimit: Int?
    /// 状态推进结果。
    public let state: TopoffChannelState
    /// 0.20.2 §3：超带轻量重申（违规带内提前向 agent 重发「立即重读」信号）。
    /// daemon 消费 = 仅 notifyutil 轻调用 + persistLog 一行——**不走域写路径、
    /// 不动 strikes/violationTicks/20 tick 验证窗与 strike×3 降级**（三套机制
    /// 并行独立，验证窗满仍走 strike 原路径）。默认 false 保源兼容（既有构造点
    /// 零 diff）。
    public var notifyOnly: Bool = false

    public init(writeLimit: Int?, state: TopoffChannelState, notifyOnly: Bool = false) {
        self.writeLimit = writeLimit
        self.state = state
        self.notifyOnly = notifyOnly
    }
}

// MARK: - 汇聚点分流与通道状态机（纯函数——CellarCoreCheck 场景域钉死，daemon 只消费）

extension Topoff {
    /// 汇聚点双通道路由（§3.1，R1-P3 位置约束钉死）：产出汇聚目标 + 编排断言目标 +
    /// topoff 承载判定。**topoff 分流独立于编排开关门派生**（desired 推导链的
    /// `orchestrationEnabled != true → nil` 门不承载 topoff——编排开关仅管 shortcuts
    /// 执行通道）；topoff 同受 mode/actionActive 门（执法总开关）。
    ///
    /// 单通道互斥不变量：<80（非降级稳态）→ topoff 独占（编排静默 desired=nil）；
    /// 降级稳态 → 编排钳 80；自愈观察窗 → topoff 独占（行为观察有效前提）；
    /// ≥80 → 编排原样（0.19.20 链，sub80 机加 §3.6 域随写卫生）。
    /// **26/无 sub80 能力机器（sub80Capable=false）→ 0.19.20 既有链逐值不变**
    ///（topoffOwned 恒 false——26 行为零变化回归锚）。
    /// **0.21.0 §1.3 fullOnce 窗（fullOnceWindow，缺省 false = 既有构造零 diff）**：
    /// 窗内汇聚目标/断言目标强制 100（等价「完全放开」——语义同 chargingDisabled
    /// 窗：域随写 100 防 agent 层对抗 App set；断言目标 100 防 valueChange 按
    /// policy 值回拉，临时放开不坍缩）。窗位仅 27 fullOnce 复活臂置位。
    /// **0.21.0 §2.1 迟滞路由（R1-P1-4 定版；hysteresisEnabled/active 缺省 false =
    /// 既有构造零 diff——26 回归锚第二把）**：迟滞执法期（opt-in ∧ CHIE 可写已由
    /// daemon 挂载门过滤，路由只消费 active 结论）desired = **nil（编排静默）**——
    /// 消除编排钳 80 与迟滞压 75 互搏臂（降级现行 desired=80 分支在迟滞 active 时
    /// 不触达）。迟滞退出（热终止/持续合盖/开关关/自愈恢复）→ active=false → 回落
    /// 既有降级钳 80 分支（现状）。off/关断语义不变（全链清理含迟滞退出）。
    /// **0.21.0 §3.1 校准共存（R1-P1-5 定版；calibrationSuspected 缺省 false =
    /// 既有构造零 diff——26 回归锚第三把）**：校准抑制态 desired = **nil（App set
    /// 断言静默——抑制臂②）**，置于 fullOnce 窗之后、其余全部分支（含 chargingDisabled
    /// 日程窗）之前——降级钳 80 断言与 80-90 主力区间 enforcement 断言（规则 5 set
    /// 对抗校准，R1 指正）一并静默。**两窗断言臂不同权（P3-1 注记）**：fullOnce 窗
    ///（用户显式放开）**先于**校准分支 → 窗内断言 100 保持；日程窗**后于**校准分支
    /// → 日程窗 ∧ 校准态 desired=nil（断言让位）。该角良性自洽：suspected 要求
    /// percent ≥95 持续充电——MCL 若 <100 则电池回落 95 以下嫌疑自消、窗断言 100
    /// 随后恢复；MCL 已被校准推至 100 时窗语义本就满足（域随写 100 两窗同权放行
    /// ——suppressionPlan 窗豁免）。场景 校准共存-11 扩臂钉死。
    public static func convergenceRoute(
        modeActive: Bool,
        orchestrationEnabled: Bool,
        chargingDisabledWindow: Bool,
        upperLimit: Int,
        sub80Capable: Bool,
        actionActive: Bool,
        degraded: Bool,
        healProbeActive: Bool,
        fullOnceWindow: Bool = false,
        hysteresisEnabled: Bool = false,
        hysteresisActive: Bool = false,
        calibrationSuspected: Bool = false
    ) -> (convergenceTarget: Int?, orchestrationDesired: Int?, topoffOwned: Bool) {
        // 汇聚目标（mode 门 → fullOnce 窗 / chargingDisabled 窗强制 100（等价
        //「完全放开」）→ 上限）。校准抑制态不改汇聚目标——topoff 臂静默由 daemon
        // 早退承接（域随写卫生暂停臂③），域值/簿记冻结不漂移。
        let convergenceTarget: Int?
        if !modeActive {
            convergenceTarget = nil
        } else if fullOnceWindow {
            convergenceTarget = shutdownLimit
        } else if chargingDisabledWindow {
            convergenceTarget = shutdownLimit
        } else {
            convergenceTarget = upperLimit
        }
        // topoff 承载门：sub80 能力 ∧ mode active ∧ 无在轨动作 ∧ 目标 <80
        //（动作活跃 → 放电/校准维护分支掌权，双通道静默——执法总开关）。
        let topoffOwned = sub80Capable && modeActive && !actionActive
            && (convergenceTarget.map { $0 < degradedLimit } ?? false)
        // 编排断言目标（0.19.20 链 + 0.20 M1b 分流 + 0.21.0 §2.1 迟滞分流 + §3.1
        // 校准分流；次序即契约勿重排）。
        let desired: Int?
        if !modeActive || !orchestrationEnabled {
            desired = nil
        } else if fullOnceWindow {
            desired = shutdownLimit                          // fullOnce 窗 → 断言 100（防回拉）
        } else if calibrationSuspected {
            // §3.1 臂②断言静默；先于 chargingDisabled 窗分支——日程窗 ∧ 校准态
            // desired=nil（两窗断言臂不同权，见方法头注 P3-1 注记）。识别/退出由
            // daemon 侧 CalibrationCoexistence.tick 纯函数驱动（CellarCoreCheck 场景
            // 域钉死）。
            desired = nil
        } else if topoffOwned && !degraded {
            desired = nil                                    // topoff 承载 → 编排静默（互斥）
        } else if topoffOwned && degraded && hysteresisEnabled && hysteresisActive {
            desired = nil                                    // 迟滞执法 → 编排静默（§2.1 R1-P1-4——消 80 钳与迟滞互搏）
        } else if topoffOwned && degraded && !healProbeActive {
            desired = degradedLimit                          // 降级稳态 → 编排钳 80
        } else if topoffOwned && degraded && healProbeActive {
            desired = nil                                    // 自愈观察窗 → topoff 独占
        } else if chargingDisabledWindow {
            desired = shutdownLimit
        } else {
            desired = NativeOrchestration.nativeTarget(effectiveLimit: upperLimit).target
        }
        return (convergenceTarget, desired, topoffOwned)
    }

    /// topoff 通道每拍推进（承载态，§3.2/§3.3）：
    /// 24h 无违反 strikes 复位 → 幂等写（目标变化/上次未落盘——写后动力学重置）→
    /// 行为验证窗（连续 20 违规 tick → strike）→ strike <3 重申（冷却门内重写域+
    /// 通知）/ ≥3 诚实降级（域随写 80，编排钳由路由层承接）。采样缺席拍不推进窗
    /// （证据不足防误降级）。
    public static func channelTick(
        state: TopoffChannelState,
        target: Int,
        now: Date,
        percent: Int?,
        externalConnected: Bool?,
        isCharging: Bool?
    ) -> TopoffTickPlan {
        var s = state
        // 24h 无违反 → strikes 复位（降级态不经此处——healTick 承载）。
        if s.strikes > 0, let last = s.lastViolationAt,
           now.timeIntervalSince(last) >= violationResetWindow {
            s.strikes = 0
        }
        // 幂等写：目标变化 ∨ 上次写未落盘（失败重试）→ 写 + 观察窗重置。
        if s.activeTarget != target || s.lastWrittenLimit != target {
            s.activeTarget = target
            s.violationTicks = 0
            return TopoffTickPlan(writeLimit: target, state: s)
        }
        // 行为验证窗（采样缺席拍：证据不足不推进——防误降级）。
        guard let percent, let externalConnected, let isCharging else {
            return TopoffTickPlan(writeLimit: nil, state: s)
        }
        if isViolationTick(percent: percent, target: target,
                           externalConnected: externalConnected, isCharging: isCharging) {
            s.violationTicks += 1
            guard s.violationTicks >= verificationTicks else {
                // 0.20.2 §3 超带轻量重申：违规带内提前向 agent 重发「立即重读」
                // 信号（压缩停充时延——验证窗满前的空转期，实测超上限窗口 15-20 min）。
                // 仅**非降级承载态**（degraded 稳态无 topoff 执法可重申）∧ 非
                // healProbe 观察窗（防污染探针观察语义——R1-P3）；5 min 冷却封顶防
                // 通知风暴。writeLimit 保持 nil——不重写域值、不动 strikes/
                // violationTicks/20 tick 窗（三套机制并行独立）。
                if !s.degraded && !s.healProbeActive {
                    let notifyDue = s.lastReassertAt.map {
                        now.timeIntervalSince($0) >= notifyReassertCooldown
                    } ?? true
                    if notifyDue {
                        s.lastReassertAt = now
                        return TopoffTickPlan(writeLimit: nil, state: s, notifyOnly: true)
                    }
                }
                return TopoffTickPlan(writeLimit: nil, state: s)
            }
            // strike：重申×3 封顶 → 诚实降级（第 3 strike 的降级写 80 即第三次重写）。
            s.violationTicks = 0
            s.strikes += 1
            s.lastViolationAt = now
            if s.strikes >= strikeLimit {
                s.degraded = true
                s.healProbeActive = false
                // P2 评审修法：播种 lastHealProbeAt——降级稳态整 1h 后才首探（不被
                // 下一拍探针打破；与 re-degradation 路径 <1h 等剩余窗的行为对齐）。
                s.lastHealProbeAt = now
                return TopoffTickPlan(writeLimit: degradedLimit, state: s)
            }
            // 重申（冷却门内）：重写域 + 通知；冷却未到 → 不写（窗已重置继续观察）。
            let cooldownElapsed = s.lastWriteAt.map {
                now.timeIntervalSince($0) >= reassertionCooldown
            } ?? true
            return TopoffTickPlan(writeLimit: cooldownElapsed ? target : nil, state: s)
        }
        s.violationTicks = 0
        return TopoffTickPlan(writeLimit: nil, state: s)
    }

    /// 降级自愈每拍推进（§3.2；**P1 评审三件套修定**）：
    /// - 稳态：域值维持降级稳态 80（与编排钳同值——单通道互斥），每小时重探
    ///   （域写 target + 20 tick 行为观察，编排静默）；
    /// - 观察窗（P1-③）：target 变更幂等重写照 channelTick 形态（探针中域值不停留
    ///   旧目标；稳态下不重写——域值 80 须与编排钳 80 保持互斥一致）；
    /// - 判定（P1-①「钉在 target」指纹）：强证据拍 → 恢复（degraded/strikes 清零）；
    ///   20 连续违规 → 自愈失败回稳态（域随写 80，下小时再探——无封顶持续重试）；
    ///   **P1-② 无差别超时臂**：窗满 20 tick 无违反无证据（活 agent 钉 target 正点
    ///   充电微顶/死通道 + native 钳 80 等弱信号形态）→ 探针结束回降级稳态（补写
    ///   degradedLimit 维持稳态不变量）+ 下小时再探——不再永久滞留。
    public static func healTick(
        state: TopoffChannelState,
        target: Int,
        now: Date,
        percent: Int?,
        externalConnected: Bool?,
        isCharging: Bool?
    ) -> TopoffTickPlan {
        var s = state
        if !s.healProbeActive {
            // 稳态：每小时重探（P2 播种后首探整 1h）。
            let due = s.lastHealProbeAt.map {
                now.timeIntervalSince($0) >= healProbeInterval
            } ?? true
            guard due else { return TopoffTickPlan(writeLimit: nil, state: s) }
            s.healProbeActive = true
            s.healProbeTicks = 0
            s.violationTicks = 0
            s.lastHealProbeAt = now
            s.activeTarget = target
            return TopoffTickPlan(writeLimit: target, state: s)
        }
        // 观察窗中：P1-③ target 变更幂等重写（探针中 topoff 独占执法——域值立即
        // 随写新目标 + 观察窗重置；照 channelTick 幂等形态）。
        if s.activeTarget != target || s.lastWrittenLimit != target {
            s.activeTarget = target
            s.healProbeTicks = 0
            s.violationTicks = 0
            return TopoffTickPlan(writeLimit: target, state: s)
        }
        // 观察窗推进（采样缺席拍不推进）。
        guard let percent, let externalConnected, let isCharging else {
            return TopoffTickPlan(writeLimit: nil, state: s)
        }
        s.healProbeTicks += 1
        if isViolationTick(percent: percent, target: target,
                           externalConnected: externalConnected, isCharging: isCharging) {
            s.violationTicks += 1
            if s.violationTicks >= verificationTicks {
                // 自愈失败：回降级稳态（域随写 80），下小时再探。
                s.healProbeActive = false
                s.healProbeTicks = 0
                s.violationTicks = 0
                s.lastViolationAt = now
                return TopoffTickPlan(writeLimit: degradedLimit, state: s)
            }
        } else if isEnforcementEvidence(percent: percent, target: target,
                                        externalConnected: externalConnected, isCharging: isCharging) {
            // 恢复：通道存活强证据（钉在 target 停充）→ degraded/strikes 清零，
            // 域值已在 target——下一拍 channelTick 幂等无写，无缝回归承载。
            s.degraded = false
            s.strikes = 0
            s.healProbeActive = false
            s.healProbeTicks = 0
            s.violationTicks = 0
            return TopoffTickPlan(writeLimit: nil, state: s)
        } else {
            // 弱信号拍：违规连计中断（窗继续——P1-② 超时臂兜底收口）。
            s.violationTicks = 0
        }
        // P1-② 无差别超时臂：窗满 20 tick 未判定 → 探针结束回降级稳态（补写
        // degradedLimit）+ 下小时再探。
        if s.healProbeTicks >= verificationTicks {
            s.healProbeActive = false
            s.healProbeTicks = 0
            s.violationTicks = 0
            return TopoffTickPlan(writeLimit: degradedLimit, state: s)
        }
        return TopoffTickPlan(writeLimit: nil, state: s)
    }
}
