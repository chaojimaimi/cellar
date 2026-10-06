import CellarCore
import CellarUI
import Foundation
import os

// MARK: - 0.21.0 §1.1/§1.5 限充执行器 + 关断残留态驱动对账（外迁 extension——
// StatusController.swift 行数纪律，LED extension 同款拆分惯例；跨文件读取的成员
// 在主类已放宽 internal——mclClient/mclReadbackValue）
//
// **0.23.0 §② Shortcuts 备用通道退役**：原双实现执行器抽象（set 优先 / 快捷指令
// fallback——ShortcutLimitExecutor/ShortcutsRunning/OrchestrationSettings）随批
// 退役，执行体收敛 MCLSetLimitExecutor 单实现（LimitExecuting 协议保留为读回重跑
// 臂的注入缝——单一 conformer）。

/// 限充执行器抽象（§1.1 R1-P2-3；0.23.0 收敛单实现）：编排消费与读回校验失配
/// 重跑臂共用的执行体缝。返回**读回校验目标**（= NativeLimitSet.setTarget 映射后
/// 的实际写入值），**0.22.4 模型 v2 起为 Optional**——setTarget <80 → nil（映射
/// 退役：任何 100/80 补写都只造 M2 环境拖慢域接管，见 NativeLimitSet.setTarget
/// 头注）；nil = 未执行写（调用方按各自链语义处理——生产链 expected ∈ {80,100,≥80}
/// 恒非 nil，nil 分支防御性）。抛错 = 执行失败（detail 进回报链；MCLSetFailure 为
/// 结构化失败分类）。
protocol LimitExecuting: Sendable {
    func execute(target: Int) async throws -> Int?
}

/// set 路径执行体（**唯一执行通道**——0.23.0 §② 快捷指令 fallback 退役）：MCLClient
/// setLimit 免 root 直写。阻塞 ObjC 调用经 Task.detached 承载（主 actor 永不等待
/// ——MCLClient 线程纪律）。
struct MCLSetLimitExecutor: LimitExecuting {
    let client: MCLClient

    func execute(target: Int) async throws -> Int? {
        // 0.22.4：<80 → nil（映射退役）。防御分支（生产链 expected 恒 ≥80 不可达）
        // 走抛错而非静默返回——抛错进既有失败链如实上屏/计数，返回 nil 会被对账臂
        // 当成功复位退避、被回报链报 ok（虚报成功，违反不静默纪律）。用独立错误
        // 类型而非 MCLSetFailure：分类学语义是 NSError 分类（失败可见面），
        // 值级防御拒绝不应污染通道健康分类。
        guard let value = NativeLimitSet.setTarget(for: target) else {
            throw LimitSetDomainFloor(target: target)
        }
        try await Task.detached { [client] in
            client.setLimit(value)
        }.value.get()
        return value
    }
}

/// 0.22.4 防御性拒绝（setTarget nil 分支——生产不可达，见 MCLSetLimitExecutor）。
struct LimitSetDomainFloor: Error, CustomStringConvertible {
    let target: Int
    var description: String {
        "目标 \(target)% 低于原生 set 下限 80——0.22.4 模型 v2 下不写 MCL（域直接执法）"
    }
}

extension StatusController {
    // MARK: - 0.21.0 §1.5 关断残留闭环（App 侧补偿臂；0.23.0 §② 原执行体路由
    // makeLimitExecutor 随快捷指令 fallback 退役——消费点直接构造 MCLSetLimitExecutor）

    /// App 自发关断（面板 disable / 编排开关关 XPC 成功回包）→ 按表即时对账
    /// （主 actor 调度，阻塞 I/O 全 detached——runControl onSuccess 回调语境）。
    /// **0.22.4**：同链受益于每跳新鲜 getStatus 取回（F3 stale 拍修法）与静默门
    /// ——mode 关时门不静默（本变体的放开语义保留，期望恒 100）。
    func reconcileShutdownResidualNow() {
        Task { await reconcileShutdownResidual() }
    }

    /// 态驱动对账单跳（R3-P2-2 **读回值驱动**，无需会话记忆——覆盖 App 重启窗）：
    /// 观察 daemonStatus 派生 MCL 期望值（NativeLimitSet.shutdownExpectation——
    /// **0.21.3 §2.1 八行表统一重定版**：两窗/mode 关恒 100 / 编排开 ≥80 →
    /// target（MCL 主导，本循环即周期对账防线）/ 编排开 <80 非 degraded → 100
    ///（MCL 让域管）∧ degraded → 80（对齐编排钳）/ 编排关 degraded → 80（域通道
    /// 死亡最后防线）∧ 非 degraded → 100（**0.21.3 §1.1 域承载全区间**——旧
    /// 「<80→80 兜底」为 G1 实证有害形态〔MCL 80 主导顶掉域 75〕，废除）），MCL
    /// 读回 ≠ 期望 → 补偿 set（走执行器味道——set 优先/驻留 fallback 一致，统一
    /// API set 保机制使能——三分支分支 2 路径）。
    /// **0.22.4 模型 v2 门控（方案 §3.1）**：补偿前先过 `NativeLimitSet.
    /// compensationSilenced` 静默门——域承载态（sub80 .active ∧ <80 ∨ 编排关）与
    /// 自愈探针观察窗不对账（域写值直接流入 MCL 执法〔M1〕，补偿写 100 = 13:32
    /// 互搏元凶；MCL=100 = 无限制且诱发 agent 再关〔M2/M4〕）；编排开∧≥80 与
    /// degraded 稳态防线显式排除（裁决记录见纯函数头注）；输入取每跳新鲜 status
    ///（F3，见函数体注）。
    ///
    /// 门控纪律：**27 终态门**（26 平台 orchestrationTerminal=false → 恒 no-op
    /// ——App 写 MCL 属 0.21 新行为，26 红线零增量）；读回缺席（nil）→ 不补偿
    /// （读回不可用即无法对账，不猜测语义）；期望达成 → 仅刷新按钮判定源；
    /// **校准可疑豁免（review P2-1）**：读回 > 期望 ∧ App 侧近似指纹命中
    ///（percent ≥95 ∧ charging ∧ target ≤90——`CalibrationCoexistence.
    /// residualCompensationExempt`，CellarCoreCheck 场景域钉死）→ 跳过本轮补偿。
    /// 与 daemon 指纹是两个独立判定（App 无 10 tick 窗状态；该配置下 daemon 指纹
    /// 因对账压回钳 80-85 结构性不可达，App 侧近似是引导链——放行 MCL 100 让电池
    /// 自由充至 percent ≥95，daemon 指纹接管三臂抑制）。近似豁免诚实边界：可能漏
    /// 抑制对账一轮（下轮 30s 重评）；percent 爬坡到 ≥95 前压回循环照旧。
    /// **0.21.1 §3.2 补偿重试退避（M1a P3-2）**：补偿连续失败 ≥3 → 会话停试
    ///（30s 循环不再每拍空打；成功/对账一致/期望值变化复位——照 WP3 读回失配
    /// 退避 R0-P2 同形态；失败残留由 doctor 检查 20 可见化）。
    func reconcileShutdownResidual() async {
        guard orchestrationTerminal else { return }
        // 0.22.4 F3（stale 拍修法）：每跳先取新鲜 status——XPC getStatus 直读经
        // Task.detached 承载（阻塞调用离主 actor，下方 :MCL 读回同款先例；refreshOnce
        // 同形态）。日程窗进出是 daemon 自治转换（无 XPC 回包刷新 wire），缓存 wire
        // ≤60s 陈旧会误判静默门「窗在位」→ W4 恰发一拍 100（13:32 同类有界重演
        // 30-60s）；新鲜取后 disable 回包后必得 post-disable 状态（mode 关即时变体
        // 的 stale 拍窄窗由此结构性关闭，D3 兜底保留为纵深）。失败 → 跳过本跳
        //（fail-open 一拍，**不 fallback 缓存 daemonStatus**——陈旧输入恰是本修法
        // 要消除的误判源）。⚠️ fresh status 仅用于静默门与期望判定，**不进 ingest**
        //（通知/边沿基线走轮询链单一入口，双路径干扰防——红队终签确认项）。
        let status = await Task.detached { () -> DaemonStatus? in
            try? DaemonXPCClient().getStatus()
        }.value
        guard let status else { return }
        let expected = NativeLimitSet.shutdownExpectation(
            modeActive: status.mode == "active",
            orchestrationEnabled: status.orchestration?.enabled == true,
            upperLimit: status.upperLimit,
            degraded: status.sub80State == .degraded,
            fullOnceWindowActive: status.fullOnceWindowActive == true,
            chargingDisabledWindowActive: status.chargingDisabledWindowActive == true
        )
        guard let expected else { return }
        // 0.22.4 补偿臂静默门（方案 §3.1 v2 门式；形参全部取 fresh status wire
        // 字段——缓存态拼参禁，复核 P3-2）：域承载态（.active ∧ <80 ∨ 编排关）与
        // 自愈探针观察窗不对账属预期——模型 v2 域写值直接流入 MCL 执法，补偿写
        // 100 即 13:32 互搏元凶。编排开∧≥80（周期对账防线）与 degraded 稳态（最后
        // 防线）不静默；mode 关（即时变体放开语义）不静默——判据全在纯函数面。
        if NativeLimitSet.compensationSilenced(
            modeActive: status.mode == "active",
            fullOnceWindow: status.fullOnceWindowActive == true,
            chargingDisabledWindow: status.chargingDisabledWindowActive == true,
            healProbeActive: status.sub80HealProbeActive == true,
            sub80State: status.sub80State,
            upperLimit: status.upperLimit,
            orchestrationEnabled: status.orchestration?.enabled == true
        ) {
            // 首次静默打一条 os_log 说明（会话级——稳态静默不刷日志）。
            if !compensationSilenceLogged {
                compensationSilenceLogged = true
                Self.log.info("关断残留对账静默：域承载态/自愈探针期不对账属预期（0.22.4 模型 v2——域写值直接执法，补偿写 100 即互搏；编排开∧≥80 与 degraded 稳态防线保留）")
            }
            return
        }
        // 0.21.1 §3.2 退避门（先于读回——停试期不再做无谓 MCL 读；期望值变化 =
        // 新关断态 → 重试机会重置）。
        if reconcileFailureStreak >= Self.reconcileFailureBackoffLimit {
            guard reconcileBackoffExpected != expected else {
                Self.log.info("关断残留对账退避：连续 \(self.reconcileFailureStreak) 次补偿失败且期望 \(expected)% 未变——本会话停试（期望变化/App 重启复位；doctor 检查 20 可见）")
                return
            }
            reconcileFailureStreak = 0
            reconcileBackoffExpected = nil
        }
        let client = mclClient
        let readback = await Task.detached { client.readLimit() }.value
        guard let readback else { return }
        guard readback != expected else {
            mclReadbackValue = readback   // 对账一致——顺带刷新恢复臂判定源
            reconcileFailureStreak = 0    // 残留已消除——退避复位（0.21.1 §3.2）
            reconcileBackoffExpected = nil
            return
        }
        // 校准可疑豁免（review P2-1）：percent 数据源 = 1s 遥测快照优先、daemon
        // lastPercent 兜底；charging = 遥测 IsCharging 优先、powerOverride 兜底——
        // 表面全关（菜单栏常驻主态）时遥测快照不发布，无兜底则豁免在后台形态恒
        // 惰性（校准恰多发起于此）；daemon lastChargingEnabled 是控制键使能态非
        // 「正在充电」，不参与（27 终态本就 nil）。证据不足 → 豁免 false（保守：
        // 关断残留语义优先，不因观测缺席改变既有行为；IOPS 误豁免最坏代价 =
        // MCL 滞留 100 至下轮 30s 重评，有界且 doctor 检查 20 可见——复核 P3-3′）。
        let telemetry = batterySnapshot
        let calibrationExempt = CalibrationCoexistence.residualCompensationExempt(
            readback: readback,
            expected: expected,
            percent: telemetry?.percent ?? status.lastPercent,
            isCharging: telemetry?.isCharging ?? powerOverride?.isCharging,
            target: status.upperLimit
        )
        if calibrationExempt {
            Self.log.info("关断残留对账跳过：读回 \(readback)% > 期望 \(expected)% ∧ 校准可疑近似命中（percent ≥95 充电 ∧ target ≤90）——MCL 保持，引导 daemon 指纹接管（下轮 30s 重评；近似豁免可能漏抑制对账一轮）")
            return
        }
        // 补偿 set（唯一执行通道——0.23.0 §② 快捷指令 fallback 退役）。
        let executor = MCLSetLimitExecutor(client: mclClient)
        do {
            let setValue = try await executor.execute(target: expected)
            let verified = await Task.detached { client.readLimit() }.value
            mclReadbackValue = verified
            reconcileFailureStreak = 0      // 补偿成功——退避复位（0.21.1 §3.2）
            reconcileBackoffExpected = nil
            // setValue Int?（0.22.4 协议签名）：nil 分支在执行体内抛错，成功路径
            // 恒非 nil——map 展示仅为类型面适配。
            Self.log.info("关断残留补偿：读回 \(readback)% ≠ 期望 \(expected)% → set \(setValue.map(String.init) ?? "未写")%（补偿后读回 \(verified.map(String.init) ?? "不可用")）")
        } catch {
            // 失败仅 os_log（控制横幅不进——关断本身已成功；残留由 doctor 检查 20
            // 可见化 + 下轮对账重试，诚实呈现不静默）。0.21.1 §3.2：连续失败计数
            // 喂退避（≥3 会话停试——30s 循环不再每拍空打）。
            reconcileFailureStreak += 1
            reconcileBackoffExpected = expected
            Self.log.error("关断残留补偿失败（期望 \(expected)%，读回 \(readback)%）：\(String(describing: error))——下轮对账重试（连续失败 ≥\(Self.reconcileFailureBackoffLimit) 次退避停试）")
        }
    }

    // MARK: - 0.22.1 suppression 自动恢复（App 侧恢复写执行臂；方案 §1.4）

    /// 恢复写派发（判定函数命中拍调用，ingest 同拍——主 actor 入口）：
    /// `MCLClient.setLimit(openValue)` 经 Task.detached 承载（阻塞 ObjC 调用离主
    /// actor——MCLSetLimitExecutor 既有线程纪律），走 agent 自身 API 通道保
    /// FeatureState=1——§11.11 定谳：daemon 的 defaults 裸写翻不转 agent 对
    /// 机制的关闭持有态（52 轮拉锯实证），UI 手动设 80 有效正因走了 agent
    /// 通道，恢复写同理。后续链全部既有机制：daemon 锁存期重写受
    /// reassertionCooldown 门控 → 冷却到期重写域值 → agent 分钟级跟随停在
    /// 上限 → 读回一致锁存释放（端到端最长 ~12 min，方案 §0）。
    /// **0.22.2 §1.1 写值 = SuppressionRecovery.openValue(for: upperLimit)**
    /// = max(目标, 80)（非 100 值 = 开启指令——0.22.1 实证 setMCLLimit(100)
    /// 不携带开启指令、机制开关不受该调用影响；入参 status = ingest 入参同款
    /// 纪律，防 self.daemonStatus 陈旧拍，评审 P2-2）。目标 ≥80 时值即目标
    /// 一步收敛；目标 <80 时写 80 作开启垫脚石——**0.22.4 模型 v2**：此后域写值
    /// 直接流入 MCL 执法〔M1〕，补偿臂在域承载态静默不再写 100（13:32 互搏元凶
    /// 退役），域即时接管。
    /// **派发时刻即落 lastSuppressionRecoveryAt**（评审 P2-1：防在途窗重复
    /// 派发——setMCLLimit 挂起时 NSLock 排队无界堆积，0.20.1 wedge 同通道
    /// 实证）；完成回主 actor 落横幅数据源
    /// suppressionRecoveryInfo（0.22.2 §4），再按结果分流通知（评审 P1-4：
    /// 通知一律由完成回调驱动）——成功 → recovered；失败 → 手动指引（各自
    /// 1h 静态限频兜底，冷却重试拍失败静默）+ os_log 错误可见化（MCLSetFailure
    /// 描述）。**0.22.4**：结果锁存 lastSuppressionRecoverySucceeded 随
    /// shouldAttempt 单一口径化（成功门删除）一并退役——重试唯一口径 = 冷却节奏。
    func dispatchSuppressionRecovery(_ status: DaemonStatus) {
        let openValue = SuppressionRecovery.openValue(for: status.upperLimit)
        let dispatchedAt = Date()
        lastSuppressionRecoveryAt = dispatchedAt
        let client = mclClient
        Task.detached { [weak self] in
            // 内层 detached 承载阻塞 ObjC 调用（外层 Task.detached 语境即后台，
            // MCLSetLimitExecutor 同款双层形态——语义显式化）。
            let result = await Task.detached { client.setLimit(openValue) }.value
            // 结果分流（Result 无 isSuccess——stdlib 仅 get()，switch 取布尔）。
            let recovered: Bool
            switch result {
            case .success:
                recovered = true
                Self.log.info("suppression 自动恢复写成功：MCL set \(openValue)（0.22.2 写开启值语义——非 100 值即开启指令，agent 通道保 FeatureState=1；目标 \(status.upperLimit)）——daemon 冷却到期重写域值、agent 跟随后读回一致即锁存释放")
            case .failure(let failure):
                recovered = false
                Self.log.error("suppression 自动恢复写失败：\(String(describing: failure), privacy: .public)——冷却窗（10 min）后自动重试；通知侧转手动指引")
            }
            await MainActor.run {
                guard let self else { return }
                // §4 横幅数据源——赋值钉死在 MainActor.run 块内（StatusController
                // 自持 @Published）。0.22.4：结果锁存随成功门删除一并退役。
                self.suppressionRecoveryInfo = (at: dispatchedAt, recovered: recovered)
                self.onSuppressionRecoveryOutcome?(recovered)
            }
        }
    }

    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "limit-execution")

    /// 0.21.1 §3.2 补偿重试退避阈值（M1a P3-2——照 WP3 读回失配退避 ≥3 同形态）。
    fileprivate static let reconcileFailureBackoffLimit = 3
}
