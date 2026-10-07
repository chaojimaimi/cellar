import Foundation

// MARK: - 0.21.0 §1 set 路径决策核心（方案 §1.1/§1.3/§1.5；CellarCoreCheck 场景域钉死）
//
// 架构总纲（方案 §0）：27 上限充执行走 App 侧免 root set 路径（80-100 区间）——
// daemon 保留 <80 topoff、放电等 root 职责。**0.23.0 §② Shortcuts 备用通道退役**
// ——set 是唯一执行通道（旧快捷指令 fallback 链随批删除）。决策纯函数进 CellarCore
// （照 NativeOrchestration/Topoff 先例），App 侧执行体（MCLClient set 面）与 daemon
// 分支（fullOnce 27 复活）只消费。

/// set 路径常量与决策纯函数（无状态无 IO——MCL I/O 在 App 侧 MCLClient）。
public enum NativeLimitSet {
    /// MCL set 原生下限（S3 定谳：setMCLLimit <80 被 PowerUISmartChargingErrorDomain
    /// Code=4 拒绝——更低由 Cellar 限充域直接执法，不经本通道）。
    public static let minimumSetLimit = 80
    /// set 上限（充满语义）。
    public static let maximumSetLimit = 100
    /// §1.3 fullOnce 27 临时放开目标（**0.23.1 编排退役注记**：原 pending(100)
    /// 产出链随批删除——本常量降级为语义钉面〔= maximumSetLimit〕，域随写 100
    /// 由 Topoff.shutdownLimit 承担；保留供场景域断言引用）。
    public static let fullOnceTarget = 100

    /// 恢复臂 XPC 命令字面量（§1.3 恢复：**0.23.1 R5 重写形态**——daemon 清窗 +
    /// 清锁存 + 即时 tick 域写 target，不再置 pending）。与既有命令命名同域
    ///（fullOnce / cancelAction / setOrchestration）。
    public static let restoreCommand = "restoreChargeLimit"

    /// set 执行目标映射（**0.22.4 模型 v2 退役版**——<80 → nil 不写）：
    /// target ≥80 → 原值直写；target <80 → **nil**（无 set 值——执行体跳过）。
    /// 历史：0.21.0「钳 80」为三分支模型对齐前的有害形态（MCL 80 主导顶掉域
    /// 75——G1/G2 实证，0.21.3 废除）；0.21.3「<80 → set 100」基于旧期望表
    /// 「域执法需 MCL=100」——已被 13:32 事故证伪（恢复写 80 成功 2s 后被自家
    /// 补偿臂打回 100）：新模型 **域写值直接流入 MCL 执法（含 <80）**，MCL=100
    /// = 无限制且诱发 agent 再关（M2/M4）。v2 口径：<80 时 MCL 无需任何 set——
    /// 恢复臂 max(target,80) 开启垫脚石后域即时接管（M1），任何 100 写入都只会
    /// 造 M2 环境拖慢收敛。**0.23.1 编排退役**：原 W1 consumeOrchestrationPending
    /// 消费点随 App 执行链删除——生产调用点仅剩 W4/W1 共用执行体
    /// MCLSetLimitExecutor（expected ∈ {80,100,≥80} 恒非 nil——nil 分支防御性
    /// 处理）。
    public static func setTarget(for pendingTarget: Int) -> Int? {
        pendingTarget >= minimumSetLimit ? pendingTarget : nil
    }

    /// 0.22.4 补偿臂静默门（W4 关断残留对账 30s 循环 + reconcileShutdownResidualNow
    /// 即时变体共用；CellarCoreCheck 场景域钉死——App 只消费）。
    ///
    /// 根因模型 v2（13:32 事故定谳）：域写值直接流入 MCL 执法（agent 跟随域值，
    /// 含 <80 区间），MCL=100 = 无限制且诱发 agent 自主再关（M2/M4）——补偿臂在
    /// 域承载态写 100 与域 75 互搏（期望表旧模型「域执法需 MCL=100」证伪）。
    ///
    /// 静默判据：mode active ∧ 两窗不在位 ∧（自愈探针观察窗让位（F2——探针只在
    /// degraded 态跑，本项先于域承载判定）∨ **宽读钉死：sub80State == .active 即
    /// 静默（全目标区间含 <80 与 ≥80——0.23.1 编排退役定版）**）。
    ///
    /// **0.23.1 宽读语义（红队 §0.9 钉面）**：域承载（.active）覆盖全区间——
    /// 域写值直接流入 MCL 执法（模型 v2 M1），任何区间补偿写都对域写值对抗；
    /// 窄读（仅 <80 或编排关区间）会在「新 App + 旧 daemon 混装窗」复活 G1
    /// （旧 daemon 编排开 ∧ ≥80 域不承载但 wire sub80State 仍 .active——新 App
    /// 补偿写 100 与旧 daemon MCL 主导执法互搏）。编排开关入参随编排退役删除
    ///（冻结偏好零消费断言面）。
    ///
    /// **显式排除（裁决记录，随代码落注）**：
    /// - degraded 稳态（无探针）：W4 写 max(target,80) =「域通道死亡最后防线」，
    ///   与域镜像同值零对抗——保留写；
    /// - sub80State == .off / nil：26/通道关——既有行为不变（26 红线：nil 恒不
    ///   静默，恒走原对账）。
    /// - mode 关 / 两窗在位：期望恒 100（放开语义），无互搏面——不静默（W4-now
    ///   即时变体语义保留）。
    public static func compensationSilenced(
        modeActive: Bool,
        fullOnceWindow: Bool,
        chargingDisabledWindow: Bool,
        healProbeActive: Bool,
        sub80State: Sub80State?
    ) -> Bool {
        guard modeActive else { return false }
        // 两窗在位 = 显式放开意图（期望恒 100 与域随写 100 同值——无互搏面）。
        guard !fullOnceWindow, !chargingDisabledWindow else { return false }
        // F2 override：探针观察窗让位（先于域承载判定——探针只在 degraded 态，
        // 静默让观察窗可达）。
        if healProbeActive { return true }
        // 宽读钉死：域承载态（.active）即静默——全目标区间（含 ≥80），防混装
        // G1 复活（见头注）。degraded/off/nil → 不静默（显式排除面）。
        return sub80State == .active
    }

    /// MCL 对账期望值（**0.23.1 编排退役定版四行表**——原 0.21.3 §2.1 八行表随
    /// 编排开关决策面退役收敛；App 态驱动对账与 doctor 检查 20 同源消费；
    /// 优先级自上而下）：
    ///
    /// 1. fullOnce 窗            → 100（窗覆盖——优先级最高）
    /// 2. chargingDisabled 日程窗 → 100（完全放开——两窗同权）
    /// 3. mode 关（disable）     → 100（API 写全开语义；分支 2 路径保机制使能）
    /// 4. degraded → `Topoff.degradedWriteValue(for:)` = max(target,80)（降级稳态
    ///    钳同源——<80 目标 80〔域通道死亡最后防线〕、≥80 目标随 target；
    ///    W4 写值与四写点同源，防 D2×W4 互搏）；非 degraded → 100（**域承载
    ///    全区间新常态**——daemon 域值随汇聚目标，MCL 让域管；原「编排开 ∧ ≥80
    ///    → target」行随编排退役删除——域承载即 MCL 主导替代，App 侧该区间由
    ///    宽读静默门兜住不再补偿）。
    ///
    /// App 对账补偿执行统一走 API set（保机制使能——分支 2 路径）。
    /// nil 不再出现于 27 正常态（四行恒有期望值）；两窗输入由 wire
    /// `fullOnceWindowActive`/`chargingDisabledWindowActive` 供给（27 恒填；
    /// 26 缺省 false = 既有语义）。缺省参数保源兼容（既有构造点零 diff）。
    public static func shutdownExpectation(
        modeActive: Bool,
        upperLimit: Int,
        degraded: Bool = false,
        fullOnceWindowActive: Bool = false,
        chargingDisabledWindowActive: Bool = false
    ) -> Int? {
        if fullOnceWindowActive { return maximumSetLimit }            // 行 1
        if chargingDisabledWindowActive { return maximumSetLimit }    // 行 2
        if !modeActive { return maximumSetLimit }                     // 行 3
        // 行 4：degraded 钳 max(target,80)（0.23.0 §④ 公式；<80 恒 80）/ 非
        // degraded 域承载全区间 → 100。
        return degraded
            ? Topoff.degradedWriteValue(for: upperLimit)
            : maximumSetLimit
    }
}

/// §1.1 set 失败链的结构化失败分类（App MCLClient.setLimit 产出；文案照 daemon
/// 拒绝串先例硬编码 zh——daemonError 原文通道上屏，不静默）。
public enum MCLSetFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// PowerUISmartChargingErrorDomain Code=4（80 下限）——结构化拒绝（S3 定谳）。
    case nativeFloorMinimum
    /// 类缺席（sticky 平台终态——计实例级失败连击）。
    case channelUnavailable
    /// 其他调用失败（实例级——实例丢弃重建自愈；计实例级失败连击）。
    case callFailed(domain: String, code: Int, message: String)

    /// NSError 分类入口（domain/code → 结构化 case；无 NSError 的 BOOL=false 同样
    /// 折叠为 callFailed——不猜测语义）。
    public static func classify(domain: String, code: Int, message: String) -> MCLSetFailure {
        if domain == PowerUISmartChargingErrorDomain && code == floorRejectionCode {
            return .nativeFloorMinimum
        }
        return .callFailed(domain: domain, code: code, message: message)
    }

    /// PowerUI 智能充电动画错误域字面量（S3 spike 实测；字符串常量单一真相）。
    public static let PowerUISmartChargingErrorDomain = "PowerUISmartChargingErrorDomain"
    /// 80 下限拒绝 Code（S3 定谳）。
    public static let floorRejectionCode = 4

    public var description: String {
        switch self {
        case .nativeFloorMinimum:
            // 0.23.0 §③ 实验性摘帽：措辞去「实验性通道」（<80 目标由 Cellar 限充
            // 域直接执法——模型 v2，无需系统设置退路）。
            return "系统原生限充最低 80——更低目标由 Cellar 限充通道直接执法"
        case .channelUnavailable:
            return "原生限充 set 通道不可用（PowerUISmartChargeClient 类缺席）"
        case .callFailed(let domain, let code, let message):
            return "原生限充 set 调用失败（\(domain) Code=\(code)）\(message.isEmpty ? "" : "：\(message)")"
        }
    }
}
