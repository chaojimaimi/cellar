import Foundation

// MARK: - WP2 topoffprotection <80% 限充通道（方案 §3；CellarCore 决策纯函数 + 域写入器）

/// sub80 通道态（DaemonStatus.sub80State wire 三态，方案 §3.2；R3-P3 off 语义；
/// 0.21.1 §2.2 off 语义**收紧为「真停用」**）：
/// - `active`：topoff 通道承载中（<80 执法或 ≥80 域随写卫生——域管理面活跃）；
/// - `degraded`：重申×3 封顶后诚实降级（域随写 80 + 编排钳 80；每小时自愈重探）；
/// - `off`：**真停用（mode 关）清理路径后**（mode→disabled 关断清理 / 退出恢复
///   restoreAndExit——0.21.1 §2.2 起编排开关关断不再置 off：编排关不断域，域随写
///   target 覆盖全区间，编排关用户将见 off→active 显示变化）——防「UI 已停用、
///   实际钉 75」不诚实态；
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
    /// 降级稳态域写值（0.23.0 §④ 统一：`max(target, degradedLimit)`——经
    /// `degradedWriteValue(for:)` 计算，本常量退居**边界角色**：<80 判据
    ///（sub80Carried）、domainBackstop 承载门、CHHysteresis target<80 门等
    /// 全库比较面不改（红队全库 17 处分类账：写值恰 4 处/边界 5 处/测试 4 处）。
    public static let degradedLimit = 80
    /// 0.21.3 §1.3 suppressed 锁存阈值：连续覆写签名命中 ≥2 次 → 域机制被外部
    /// 压制（UI-100 三键覆写形态）——wire sub80MechanismSuppressed 数据源（App
    /// 通用页警示行 + doctor 检查 20 FAIL 臂）。锁存后重写限频复用
    /// reassertionCooldown 10 min；0.22.3 §1 起解除 = **连续 2 次一致读回 ∧ 过
    /// 瞬态守卫**（单次一致不再释放——2026-10-04 10:19 虚假释放事件根治）。
    public static let suppressionThreshold = 2
    /// 0.22.3 §1 锁存释放的瞬态守卫（秒）：streak 计数要求 `now − lastWriteAt ≥ 120s`
    /// （自身 10 min 限频重写的瞬态窗外）——结构性排除「读到自己的重写」形态；
    /// 守卫窗内的一致读回不计不减（无证据）。真健康释放延迟 ~3 min（120s 守卫 +
    /// 2×30s 采样），横幅多挂两三分钟可接受（方案 §1 钉死）。
    public static let suppressionTransientGuard: TimeInterval = 120
    /// 0.22.3 §2 owned 拍周期域读回节奏：**别名赋值同源钉死 reassertionCooldown**
    /// （评审 P2-4——读回节奏 = 重写限频节奏，防双常量漂移）。owned（非 degraded）
    /// 态任何静默漂移 ≤10 min 首次命中（健康稳态成本 = 2 子进程/10 min，登记）。
    public static let periodicReadbackInterval: TimeInterval = Topoff.reassertionCooldown
    /// 0.22.3 §3 失速判定门槛（秒）：锚点龄 ≥ 30 min ∧ percent ≥ 锚点 percent →
    /// stallDue（本拍强制域读回 + 触发拍刷新锚点——30 min 节奏封顶防复读风暴）。
    public static let stallThreshold: TimeInterval = 1800
    /// 0.22.3 §3 失速期连续一致读回升级阈值：≥2 次 → persistLog 升级 WARN
    /// （第二传感器——域文件看着对但充电行为不跟随的可见面；wire 无通道）。
    public static let stallConsistentWarnThreshold = 2
    /// 关断清理域随写值（§3.7——先值后态+通知）。
    public static let shutdownLimit = 100
    /// 0.20.1 热修：topoff 子进程看门狗超时（秒）——真机 wedge 事件（走查②：strike
    /// 路径子进程挂起持全局锁→daemon 整体楔死）的修复常量。
    public static let subprocessTimeoutSeconds = 10

    /// **0.23.0 §④ degraded 稳态写值统一**：`max(target, degradedLimit)`。
    /// - target < 80 → 80（既有语义不变——degraded 恒回退 80）；
    /// - target ≥ 80 → target（**语义收益**：degraded 非 <80 专属——编排关 ≥85
    ///   域承载态 degraded 后停 target 而非被拉到 80，与「域值随汇聚目标」不变量
    ///   一致）。
    /// **与 `SuppressionRecovery.openValue` 公式互钉**（红队 F7 附注）：两者同为
    /// `max(target, 80)` 形态——openValue 是 App 恢复写（开启垫脚石），本函数是
    /// daemon degraded 稳态域写；公式任一侧改动必须同步审视另一侧（防 D2×W4
    /// 互搏——W4 行 6/7 期望表同源消费本公式）。
    public static func degradedWriteValue(for target: Int) -> Int {
        max(target, degradedLimit)
    }

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
    /// 守卫允许带 off 重试直至写成功）。0.21.1 §2.2：**消费面收缩为「真停用」**
    /// ——mode 非 active（disable/SIGHUP/restoreAndExit 事件路径 + 汇聚点 mode
    /// nil 臂状态不变量）；编排关 ∧ target ≥80 不再消费（域随写 target 覆盖
    /// 全区间——off 置位仅剩 mode 关两路，off 语义收紧「真停用」）。
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

    /// 域读回（0.21.3 §1.2 G7b——外部覆写快速自愈的判定输入）：root 侧
    /// `defaults read <path> <key>` 锁内子进程 ×2（limit/FeatureState 各一笔；
    /// 0.20.1 收尸纪律同款由 daemon 侧 run 注入承担）。**仅违规拍/锁存期补采样
    /// 调用**（daemon 以 `Topoff.isViolationTick` ∨ suppressed 锁存预判——健康
    /// 稳态零子进程开销）。
    ///
    /// 返回语义（与 channelTick `domainReadback` 参数钉死）：
    /// - 外层 nil = **读失败**（子进程启动失败〔负退出码〕∨ **看门狗击杀等白名单
    ///   外退出码**——defaults 正常退出码仅 {0 成功, 1 键/域缺席}；0.20.1 看门狗
    ///   SIGTERM 击杀 terminationStatus=15，误归「键缺席→覆写签名」会虚增
    ///   suppressionConsecutive〔两次挂起 = 假锁存〕，一律 fail-open）→ 调用方
    ///   按既有违规计数（不阻断防线）；
    /// - 外层非 nil = 域已看视：键缺席/解析失败 → 对应内层 nil（参与覆写签名——
    ///   域文件被删/键被清本身即外部覆写形态，重写自愈方向正确）。
    public static func read(
        defaultsPath: String = Topoff.domainPath,
        run: (String, [String]) -> (output: String, exitCode: Int32)
    ) -> (limit: Int?, featureState: Int?)? {
        func readKey(_ key: String) -> (value: Int?, exitCode: Int32) {
            let result = run("/usr/bin/defaults", ["read", defaultsPath, key])
            guard result.exitCode == 0 else { return (nil, result.exitCode) }
            let parsed = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            return (parsed, 0)
        }
        let limitRead = readKey(Topoff.limitKey)
        let stateRead = readKey(Topoff.featureStateKey)
        // 读失败判定：退出码 ∈ {0, 1} 白名单外（负 = 启动失败；15 = 看门狗 SIGTERM
        // 击杀；其余异常值同归）→ 整体 fail-open。
        if !(0...1).contains(limitRead.exitCode) || !(0...1).contains(stateRead.exitCode) {
            return nil
        }
        return (limitRead.value, stateRead.value)
    }
}

/// 0.22.3 §3 失速锚点（观测层第二传感器——percent 停驻在 target+2 以上的锚定）。
/// ⚠️ 方案钉的 `(percent: Int, at: Date)?` tuple 形态在 `TopoffChannelState` 的
/// `Equatable` 合成上不可行（tuple 成员不满足协议合成——编译实证），以最小嵌套
/// struct 承载同语义（代码现实适配，字段与判据一字不差）。
public struct TopoffStallAnchor: Equatable, Sendable {
    /// 锚定时刻的电量。
    public var percent: Int
    /// 锚定时刻。
    public var at: Date

    public init(percent: Int, at: Date) {
        self.percent = percent
        self.at = at
    }
}

/// topoff 通道运行时状态（daemon 锁内内存态）。0.20.2 §2 起**诚实性五字段**
///（degraded / strikes / off / lastViolationAt / lastHealProbeAt）经
/// TopoffPersistedState 跨重启持久化（写入点钉在 sub80 门内、触发源仅 strike/
/// 降级跳变/off 关断——TopoffStateStore）；其余瞬态字段**内存态不持久化**：
/// 重启即重探，lastWritten 丢失 → 首 tick 幂等重写一次（停机期间
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
    /// 0.21.3 §1.3：连续覆写签名命中计数（G3/UI-100 检测）。违规拍域读回覆写
    /// 签名命中 +1、读回一致清零；**≥ Topoff.suppressionThreshold → suppressed
    /// 锁存**（wire sub80MechanismSuppressed 数据源；锁存后重写限频 10 min——
    /// 防持续覆写 30s churn）。**内存态不持久化**（重启丢计数可接受——登记于
    /// 方案 §1.3：覆写源（MDM/系统设置驻留）跨重启仍在则 ≤2 拍内重新锁存）。
    public var suppressionConsecutive: Int
    /// 0.22.3 §1：签名一致的连续计数（锁存释放持续性判据——首次一致 streak=1
    /// 保持锁存，连续第二次一致 → 释放；签名命中 → 清零）。**内存态不持久化**
    /// （与 suppressionConsecutive 同类——重启丢 streak 无害：锁存态下周期读回
    /// ≤10 min 重采，最坏多挂一个守卫窗）。
    public var suppressionConsistentStreak: Int
    /// 0.22.3 §2：上次周期域读回时刻（daemon 预检臂 3 判定输入；nil = 远古——
    /// 首拍即读）。**读尝试即推进（无论成败）**——失败不加速重试，每失败周期
    /// 10 min 盲区有界（评审 P2-2）。内存态不持久化（重启即首拍读回——停机漂移
    /// 的最便宜对账）。
    public var lastPeriodicReadbackAt: Date?
    /// 0.22.3 §2：确认拍请求（channelTick 签名命中 ∧ 未锁存拍置位——下一拍 daemon
    /// 必读，30s 内完成「连续两次」锁存判定；读尝试即清）。内存态。
    public var pendingSuppressionConfirmation: Bool
    /// 0.22.3 §3：失速锚点（nil = 无在档锚点；重置条件见 `Topoff.stallTick`）。
    /// 内存态不持久化（Discharge 先例同款纪律——判定/态进 CellarCore 场景域可测）。
    public var stallAnchor: TopoffStallAnchor?
    /// 0.22.3 §3：失速期连续一致读回计数（≥ Topoff.stallConsistentWarnThreshold
    /// → daemon persistLog 升级 WARN；签名命中/锚点重置即归零）。内存态。
    public var stallConsistentCount: Int

    public init() {
        violationTicks = 0
        strikes = 0
        degraded = false
        healProbeActive = false
        healProbeTicks = 0
        off = false
        suppressionConsecutive = 0
        suppressionConsistentStreak = 0
        lastPeriodicReadbackAt = nil
        pendingSuppressionConfirmation = false
        stallAnchor = nil
        stallConsistentCount = 0
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
    /// 0.21.2 §3.2：**strike 边沿信号**（channelTick 内 strikes 递增拍置 true——
    /// 单拍有效；照 notifyOnly 缺省先例默认 false 保源兼容，既有构造点零 diff）。
    /// WHY（R1-P0 接线层盲区根治）：验证窗满拍 violationTicks 即归零——先于
    /// topoff tick 运行的观测点可见最大 19，「≥20 判据」按字面接线**永不触发**
    /// 且纯函数测试全绿；显式边沿信号让 daemon 无需比对 strikes 前后值（决策层
    /// 显式优于 daemon 侧比对）。
    /// **0.23.0 自动放电自动机退役**：strikeFired 机制本身保留（降级拍语义不变
    /// ——产出零成本），唯一下游消费者（strike 陪跑链 / StrikeEdgeLatch 边沿锁存）
    /// 已随批退役——边沿暂无人消费，无害（daemon 侧仅不再置位锁存簿记）。
    public var strikeFired: Bool = false

    public init(writeLimit: Int?, state: TopoffChannelState, notifyOnly: Bool = false, strikeFired: Bool = false) {
        self.writeLimit = writeLimit
        self.state = state
        self.notifyOnly = notifyOnly
        self.strikeFired = strikeFired
    }
}

// MARK: - 汇聚点分流与通道状态机（纯函数——CellarCoreCheck 场景域钉死，daemon 只消费）

extension Topoff {
    /// 汇聚点分流路由（§3.1）：产出汇聚目标 + topoff 承载判定。
    /// **0.23.1 编排退役**：原「编排断言目标 desired」推导链随编排链退役整批删除
    ///（desired 恒 nil——App set 断言链唯一消费面已消失；原次序即契约的 desired
    /// 分支族不再存在），本函数收敛为「daemon 域承载」单通道的路由纯函数。
    /// **domainBackstop 域承载全区间**（0.21.3 §1.1 语义保留、0.23.1 收敛为常态）：
    /// 非全开窗 ∧ ≥80 → topoffOwned（violation/strike/degraded 链生效——G7 根治；
    /// 原「编排开关关」前置项随编排开关退役**显式删除**——域承载不再
    /// 依赖开关两态，≥80 全区间域承载即新常态）。
    /// **26/无 sub80 能力机器（sub80Capable=false）→ topoffOwned 恒 false**
    ///（26 行为零变化回归锚）。
    /// **fullOnce 窗（fullOnceWindow，缺省 false = 既有构造零 diff）**：窗内汇聚
    /// 目标强制 100（等价「完全放开」——域随写 100 防 agent 层对抗；窗位仅 27
    /// fullOnce 置窗臂置位）。**全开窗排除（R1-P1-1）**：chargingDisabled/fullOnce
    /// 窗强制 convergenceTarget=100，窗内进 owned 会路由 healTick → 探针写 100
    /// + 超时臂回写 80——违反「域值随汇聚目标」不变量；窗内回落 §3.6 卫生分支
    /// （写 100 无执法——窗语义即完全放开）。
    public static func convergenceRoute(
        modeActive: Bool,
        chargingDisabledWindow: Bool,
        upperLimit: Int,
        sub80Capable: Bool,
        actionActive: Bool,
        fullOnceWindow: Bool = false
    ) -> (convergenceTarget: Int?, topoffOwned: Bool) {
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
        // topoff 承载门：sub80 能力 ∧ mode active ∧ 无在轨动作（动作活跃 → 放电/
        // 校准维护分支掌权，域通道静默——执法总开关）∧（<80 承载 ∨ 域承载全区间
        // 扩展：≥80 ∧ 非全开窗）。**0.23.1**：扩展语义即常态——daemon 域承载覆盖
        // 全区间目标（violation → 轻量重申 → strike → degraded → 域值链），MCL
        // 对账防线归 expectation 表与 App 补偿臂（宽读静默门）。**全开窗排除
        //（R1-P1-1）**：窗强制 convergenceTarget=100，窗内进 owned 会路由 healTick
        // → 探针写 100 + 超时臂回写 80——违反「域值随汇聚目标」不变量；窗内回落
        // §3.6 卫生分支（写 100 无执法——窗语义即完全放开）。26 红线：sub80 门内
        // 恒 false（零触及）。
        let sub80Carried = convergenceTarget.map { $0 < degradedLimit } ?? false
        let fullOpenWindow = fullOnceWindow || chargingDisabledWindow
        let domainBackstop = !fullOpenWindow
            && (convergenceTarget.map { $0 >= degradedLimit } ?? false)
        let topoffOwned = sub80Capable && modeActive && !actionActive
            && (sub80Carried || domainBackstop)
        return (convergenceTarget, topoffOwned)
    }

    /// topoff 通道每拍推进（承载态，§3.2/§3.3）：
    /// 24h 无违反 strikes 复位 → 幂等写（目标变化/上次未落盘——写后动力学重置）→
    /// **0.21.3 §1.2 域读回三分支**（覆写签名 → 重写自愈 + 清零不耗 strike +
    /// suppressionConsecutive 计数/锁存/限频/确认拍置位；签名一致 → **0.22.3 §1
    /// 释放持续性**——首次一致 streak=1 保持锁存，连续第二次一致 ∧ 过 120s 瞬态
    /// 守卫才解除；读失败 → fail-open 既有计数）→ 行为验证窗（连续 20 违规 tick
    /// → strike）→
    /// strike <3 重申（冷却门内重写域+通知）/ ≥3 诚实降级（0.23.0 §④ 域随写
    /// `degradedWriteValue(for:)`=max(target,80)，编排钳由路由层承接）。采样缺席
    /// 拍不推进窗（证据不足防误降级）。
    /// `domainReadback`：daemon 预判命中才读并注入读回结果——预判 = 违规拍
    /// （`isViolationTick`）∨ **suppressed 锁存期补采样**（review P1：锁存态下
    /// 非违规 owned 拍也采样——覆写源停止后锁存仍可在下一拍经一致读回解除，
    /// wire「随轮询自然消失」兑现；健康稳态零子进程）——channelTick 保持纯函数，
    /// 覆写判定在场景域钉死。
    /// - parameter domainReadback: 域读回（`TopoffWriter.read` 输出）；
    ///   nil = 未注入（健康非违规拍）/读失败（fail-open 既有计数）。缺省 nil 保
    ///   源兼容。
    public static func channelTick(
        state: TopoffChannelState,
        target: Int,
        now: Date,
        percent: Int?,
        externalConnected: Bool?,
        isCharging: Bool?,
        domainReadback: (limit: Int?, featureState: Int?)? = nil
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
        // 0.21.3 §1.2 域读回消费（三分支，G7b 外部覆写快速自愈；0.22.3 §2 起 daemon
        // 注入时机扩为四臂——违规拍预判 ∨ suppressed 锁存期补采样 ∨ **周期到期**
        // 〔健康稳态 2 子进程/10 min 盯防〕∨ 确认拍；臂面见 daemon 侧预检）：
        // - 覆写签名命中（双键口径：limit ≠ lastWritten ∨ FeatureState ≠ 1——
        //   UI-100 三键覆写在两键必命中；enabled 键不参与签名，残留影响走 §4.4
        //   真机走查）→ 重写意图（writeLimit=target）+ violationTicks 清零**不耗
        //   strike**（覆写非通道失效——证据类型区分；覆写循环有意不降级：降级对
        //   覆写形态无益，升级走 suppressed 可见链）+ suppressionConsecutive 计数
        //   （≥2 锁存 → 重写限频 10 min——限频拍读回仍覆写签名则**一律清零不计数**
        //   ，R2-P2：限频只封 writeLimit，不改变证据归类——否则 20 tick 后
        //   strike→degraded 违背「覆写不降级」钉死语义）。**非违规拍的覆写**
        //   （锁存期补采样引入）同样走本臂——域值错误与充电态无关，重写即自愈；
        // - 签名一致 → **0.22.3 §1 释放持续性**：锁存期首次一致 streak=1 保持
        //   锁存，连续第二次一致 ∧ 过 120s 瞬态守卫才清零解除（单次一致不再
        //   释放——2026-10-04 10:19 虚假释放根治；未锁存一致 → 两计数全清），
        //   违规拍随后落正常计数（既有链——strike 只计 agent 无视）；
        // - 读失败/未读（nil）→ fail-open 既有计数（读失败不阻断防线）。
        if let readback = domainReadback {
            // 0.22.3 §1：签名证据簿记（计数/持续性 streak/120s 瞬态守卫/确认拍
            // 置位）收敛进 `consumeSuppressionEvidence` 共用 helper（healTick
            // degraded 簿记同源——单一语义防实现漂移）；本函数只保留 writeLimit
            // 意图与 violationTicks 推进（覆写拍清零不耗 strike——既有语义）。
            let overridden = Topoff.consumeSuppressionEvidence(
                state: &s, readback: readback, now: now)
            if overridden {
                s.violationTicks = 0
                if s.suppressionConsecutive >= suppressionThreshold {
                    let cooldownElapsed = s.lastWriteAt.map {
                        now.timeIntervalSince($0) >= reassertionCooldown
                    } ?? true
                    return TopoffTickPlan(
                        writeLimit: cooldownElapsed ? target : nil, state: s
                    )
                }
                return TopoffTickPlan(writeLimit: target, state: s)
            }
            // 签名一致：锁存期**首次一致 streak=1 保持锁存**（释放唯一路径 =
            // 连续第二次一致 ∧ 过 120s 瞬态守卫——helper 内；10:19 单次一致虚假
            // 释放根治）；未锁存一致 → 两计数全清。落正常违规计数（既有链——
            // strike 只计 agent 无视）。
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
            // 0.21.2 §3.2：两臂（重申/降级）均为 strikes 递增拍 → strikeFired=true
            // 边沿（单拍有效；降级拍边沿由消费侧 !degraded 门拦截——第 3 边沿不放电）。
            s.violationTicks = 0
            s.strikes += 1
            s.lastViolationAt = now
            if s.strikes >= strikeLimit {
                s.degraded = true
                s.healProbeActive = false
                // P2 评审修法：播种 lastHealProbeAt——降级稳态整 1h 后才首探（不被
                // 下一拍探针打破；与 re-degradation 路径 <1h 等剩余窗的行为对齐）。
                s.lastHealProbeAt = now
                // 0.23.0 §④ 写值统一：degraded 稳态写 max(target,80)（降级写即
                // 第三次重写——≥80 目标停 target，W4 行 6/7 同源）。
                return TopoffTickPlan(
                    writeLimit: degradedWriteValue(for: target), state: s, strikeFired: true)
            }
            // 重申（冷却门内）：重写域 + 通知；冷却未到 → 不写（窗已重置继续观察）。
            let cooldownElapsed = s.lastWriteAt.map {
                now.timeIntervalSince($0) >= reassertionCooldown
            } ?? true
            return TopoffTickPlan(writeLimit: cooldownElapsed ? target : nil, state: s, strikeFired: true)
        }
        s.violationTicks = 0
        return TopoffTickPlan(writeLimit: nil, state: s)
    }

    /// 降级自愈每拍推进（§3.2；**P1 评审三件套修定**）：
    /// - 稳态：域值维持降级稳态 `degradedWriteValue(for:)`=max(target,80)（与编排
    ///   钳同值——单通道互斥），每小时重探（域写 target + 20 tick 行为观察，编排
    ///   静默）；
    /// - 观察窗（P1-③）：target 变更幂等重写照 channelTick 形态（探针中域值不停留
    ///   旧目标；稳态下不重写——域值与编排钳保持互斥一致）；
    /// - 判定（P1-①「钉在 target」指纹）：强证据拍 → 恢复（degraded/strikes 清零）；
    ///   20 连续违规 → 自愈失败回稳态（0.23.0 §④ 域随写 max(target,80)，下小时
    ///   再探——无封顶持续重试）；
    ///   **P1-② 无差别超时臂**：窗满 20 tick 无违反无证据（活 agent 钉 target 正点
    ///   充电微顶/死通道 + native 钳 80 等弱信号形态）→ 探针结束回降级稳态（补写
    ///   degradedWriteValue 维持稳态不变量）+ 下小时再探——不再永久滞留。
    /// - parameter domainReadback: **0.22.3 §2 degraded 态签名簿记**（可选注入——
    ///   channelTick 0.21.3 同款注入形态，纯函数保持；daemon 周期臂 3 含 degraded）。
    ///   签名命中 → suppressionConsecutive++（≥2 锁存照旧——wire 恢复可见 → App
    ///   恢复链在降级态同样可点火）；一致 → §1 streak 语义（降级态锁存释放同样需
    ///   持续一致）。**仅簿记**：80 钳/探针/writeLimit 意图零变化（签名自愈写不进
    ///   healTick——降级态域值由探针与稳态钳维护）。nil = 未注入/读失败（fail-open）。
    public static func healTick(
        state: TopoffChannelState,
        target: Int,
        now: Date,
        percent: Int?,
        externalConnected: Bool?,
        isCharging: Bool?,
        domainReadback: (limit: Int?, featureState: Int?)? = nil
    ) -> TopoffTickPlan {
        var s = state
        // 0.22.3 §2：degraded 态签名簿记（与 channelTick 同一 helper——计数/streak/
        // 守卫/确认拍置位单一语义）。置于全部相位分支之前——稳态与探针期同权消费；
        // 其余语义（80 钳/探针/writeLimit）零变化。
        Topoff.consumeSuppressionEvidence(state: &s, readback: domainReadback, now: now)
        if !s.healProbeActive {
            // 稳态：每小时重探（P2 播种后首探整 1h）。
            let due = s.lastHealProbeAt.map {
                now.timeIntervalSince($0) >= healProbeInterval
            } ?? true
            guard due else { return TopoffTickPlan(writeLimit: nil, state: s) }
            // 0.22.0 §4.1 外接电源门：违规判定与恢复证据均要求 externalConnected
            //（isViolationTick/isEnforcementEvidence）——电池供电态探针的 20 tick
            // 观察窗必然走无差别超时臂（每次纯空转 ~10 min + 两笔域写）。到期 ∧
            // 非插电（false 与 nil 采样缺席同门）→ 返回 nil plan 不启动、不消耗
            // due（lastHealProbeAt 不推进）——插电后首拍即探。观察窗中拔电维持
            // 既有语义（超时臂收尾）——门只钉稳态启动拍，不扩权。
            guard externalConnected == true else {
                return TopoffTickPlan(writeLimit: nil, state: s)
            }
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
                // 自愈失败：回降级稳态（0.23.0 §④ 写 max(target,80)），下小时再探。
                s.healProbeActive = false
                s.healProbeTicks = 0
                s.violationTicks = 0
                s.lastViolationAt = now
                return TopoffTickPlan(writeLimit: degradedWriteValue(for: target), state: s)
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
        // P1-② 无差别超时臂：窗满 20 tick 未判定 → 探针结束回降级稳态（0.23.0 §④
        // 补写 max(target,80) 维持稳态不变量）+ 下小时再探。
        if s.healProbeTicks >= verificationTicks {
            s.healProbeActive = false
            s.healProbeTicks = 0
            s.violationTicks = 0
            return TopoffTickPlan(writeLimit: degradedWriteValue(for: target), state: s)
        }
        return TopoffTickPlan(writeLimit: nil, state: s)
    }
}

// MARK: - 0.22.3 §1-§3 锁存释放持续性 / 周期读回 / 失速检测（纯函数——CellarCoreCheck
// 场景域钉死，daemon 只消费）

extension Topoff {
    /// 0.22.3 §1 域读回签名证据簿记（channelTick / healTick 共用——单一语义防实现
    /// 漂移；只动三个抑制簿记字段，violationTicks 推进与 writeLimit 意图归各调用链
    /// 既有语义）。返回是否覆写签名命中（channelTick 据此走重写自愈臂）。
    ///
    /// - 签名命中（双键口径任一：limit ≠ lastWritten ∨ FeatureState ≠ 1）→
    ///   suppressionConsecutive+1 + **streak 清零**（一致性证据被打断照旧清——
    ///   10:19 形态的对称面）+ 未锁存拍置 `pendingSuppressionConfirmation`（下一拍
    ///   确认拍必读——30s 内完成「连续两次」锁存判定）；
    /// - 签名一致 → **释放持续性判据**：锁存期要求 `now − lastWriteAt ≥ 120s`
    ///   瞬态守卫（结构性排除「读到自己的重写」形态）；守卫窗内不计不减（无证据）；
    ///   窗外首次一致 streak=1 **保持锁存与计数**（继续限频重写与补采样），连续第二
    ///   次一致 → 释放（suppressionConsecutive=0、streak=0）；未锁存一致 → 两计数
    ///   全清（未锁存无「释放」概念——简化）；
    /// - nil readback（读失败）→ 两计数均不动（失败不构成任何证据——fail-open）。
    @discardableResult
    public static func consumeSuppressionEvidence(
        state: inout TopoffChannelState,
        readback: (limit: Int?, featureState: Int?)?,
        now: Date
    ) -> Bool {
        guard let readback else { return false }   // 读失败：两计数均不动
        let overridden = readback.limit != state.lastWrittenLimit
            || readback.featureState != 1
        if overridden {
            state.suppressionConsistentStreak = 0
            state.suppressionConsecutive += 1
            if state.suppressionConsecutive < suppressionThreshold {
                // degraded 态置位无害（code-review P3：臂④非 degraded 不可达，
                // 位滞留至下一周期读 ≤10 min 清除；降级恢复后残留位触发一次
                // 即时读，有益无害）。
                state.pendingSuppressionConfirmation = true
            }
            return true
        }
        if state.suppressionConsecutive >= suppressionThreshold {
            // 锁存期：瞬态守卫门外才计一致性证据。
            let guardElapsed = state.lastWriteAt.map {
                now.timeIntervalSince($0) >= suppressionTransientGuard
            } ?? true
            guard guardElapsed else { return false }   // 守卫窗内：不计不减
            state.suppressionConsistentStreak += 1
            if state.suppressionConsistentStreak >= 2 {
                // 连续第二次一致 → 释放（方案 §1 钉死字面 2——与锁存阈值
                // suppressionThreshold 仅数值巧合，语义独立勿合并常量）。
                state.suppressionConsecutive = 0
                state.suppressionConsistentStreak = 0
            }
            // 首次一致（streak=1）→ 保持锁存与计数。
        } else {
            // 未锁存一致 → 两计数全清（简化——streak 仅锁存期有意义）。
            state.suppressionConsecutive = 0
            state.suppressionConsistentStreak = 0
        }
        return false
    }

    /// 0.22.3 §2 周期读回到期判定（daemon 预检臂 3 纯函数钉面）：nil = 远古——
    /// 首拍即读；`now − last ≥ periodicReadbackInterval` → due（≥ 边界钉面）。
    public static func periodicReadbackDue(last: Date?, now: Date) -> Bool {
        last.map { now.timeIntervalSince($0) >= periodicReadbackInterval } ?? true
    }

    /// 0.22.3 §3 失速锚点每拍推进（观测层第二传感器——「域文件看着对但充电行为
    /// 不跟随」的行为兜底；已知形态〔机制关闭〕由 §2 周期读回先行命中，本判定为
    /// 第二传感器）。返回 `(nextAnchor, stallDue)`。
    ///
    /// - 锚点重置（任一）：!owned ∨ !ext ∨ isCharging ∨ 采样缺席 ∨
    ///   `percent < target + violationMarginPercent(2)`（合法回落 ~7%/30min 恒可辨
    ///   ——percent 下降即刷新锚点，永不误报）；
    /// - 锚点更新：无锚点 → 立 (percent, now)；percent 下降 → 刷新；
    /// - stallDue：锚点龄 ≥ stallThreshold(30 min) ∧ percent ≥ 锚点 percent →
    ///   **触发拍刷新锚点为 (percent, now)**（失速持续态 30 min 节奏封顶，防每
    ///   30s 复读风暴——评审 P1-1）。
    public static func stallTick(
        anchor: TopoffStallAnchor?,
        owned: Bool,
        percent: Int?,
        target: Int?,
        externalConnected: Bool?,
        isCharging: Bool?,
        now: Date
    ) -> (anchor: TopoffStallAnchor?, stallDue: Bool) {
        guard owned, let percent, let target,
              externalConnected == true, isCharging == false,
              percent >= target + violationMarginPercent else {
            return (nil, false)   // 重置条件（任一）→ 清锚点
        }
        guard let anchor else { return (TopoffStallAnchor(percent: percent, at: now), false) }
        if now.timeIntervalSince(anchor.at) >= stallThreshold, percent >= anchor.percent {
            // stallDue：触发拍刷新锚点（30 min 节奏封顶）。
            return (TopoffStallAnchor(percent: percent, at: now), true)
        }
        if percent < anchor.percent {
            // percent 下降 → 刷新锚点（合法回落恒可辨）。
            return (TopoffStallAnchor(percent: percent, at: now), false)
        }
        return (anchor, false)   // 停驻未到期：保持锚点
    }

    /// 0.22.3 §3 失速期一致读回计数推进（daemon 消费——stallDue 拍强制读回后按
    /// 签名分类计数；连续 ≥ stallConsistentWarnThreshold → persistLog 升级 WARN）。
    public static func stallConsistentCountNext(current: Int, overridden: Bool) -> Int {
        overridden ? 0 : current + 1
    }
}
