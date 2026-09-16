import Foundation

// MARK: - v0.19.20 Shortcuts 编排决策核心（方案 §2.1；daemon 决策 / App 执行）

/// 架构定论（方案 §0/§1）：决策在 daemon，执行在 App（唯一合法快捷指令执行环境
/// ——S2 实证 root 恒失败，daemon 直连通道 NO-GO）。daemon 30s tick 观测段评估
/// 断言需求 → DaemonStatus.orchestration.pendingToken 发布 → App ShortcutRunner
/// 执行 `shortcuts run -i` → reportOrchestration 回报确认。

/// 编排 wire 键与输入面常量（照 ChargeScheduleWireKeys 先例：XPCServer 臂 /
/// DaemonXPCClient / validateRequest 三处同源）。
public enum OrchestrationWireKeys {
    /// setOrchestration 命令字面量（编排开关写入通道——R1 P0-2：原本没有任何
    /// 写入通道）。
    public static let command = "setOrchestration"
    /// reportOrchestration 命令字面量（App 执行回报——确认链）。
    public static let reportCommand = "reportOrchestration"
    /// setOrchestration 单键（UINT64 0/1——R2 P3：统一既有开关键型，照 auto/
    /// magSafeLedMode 先例，不引入新键型）。
    public static let enabled = "orchestrationEnabled"
    /// reportOrchestration token 键（STRING ≤64——幂等消费键，daemon 签发 UUID）。
    public static let token = "orchestrationToken"
    /// reportOrchestration ok 键（UINT64 0/1）。
    public static let ok = "orchestrationOk"
    /// reportOrchestration detail 键（STRING ≤8192——上限照 scheduleJson 先例；
    /// 可选：ok=true 时缺席）。
    public static let detail = "orchestrationDetail"
    /// token 字节长度上限。
    public static let maxTokenLength = 64
    /// detail 字节长度上限（与 validateRequest 白名单 / XPCServer 臂同源）。
    public static let maxDetailLength = 8192

    /// 开关值域（0/1 白名单——与 Discharge.validAutoFlag 同尺）。
    public static func validEnabled(_ raw: UInt64) -> Bool { raw <= 1 }

    /// token 校验（非空 + ≤64 字节；字节口径与 xpc_string_get_length 一致）。
    public static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= maxTokenLength
    }

    /// detail 校验（≤8192 字节；空串合法 = 无详情）。
    public static func validDetail(_ detail: String) -> Bool {
        detail.utf8.count <= maxDetailLength
    }
}

/// reportOrchestration 请求载荷（三键缺席保持 nil——类型混淆已在 validateRequest
/// 整包拒绝，值域由 XPCServer 臂复核）。
public struct OrchestrationReportWire: Equatable, Sendable {
    public var token: String?
    public var ok: UInt64?
    public var detail: String?

    public init(token: String? = nil, ok: UInt64? = nil, detail: String? = nil) {
        self.token = token
        self.ok = ok
        self.detail = detail
    }
}

/// 编排状态载荷（DaemonStatus.orchestration 可选字段——buildStatusLocked **恒填**
/// 照 magSafeLed 先例：内存组装零读盘，UD-7 防 ingest 整体覆盖触发「旧 daemon」
/// 闪断；合成 Codable decodeIfPresent——旧 daemon 回包缺席 → nil 天然兼容）。
public struct OrchestrationStatus: Codable, Equatable, Sendable {
    /// 编排开关（policy.orchestrationEnabled 回读）。
    public var enabled: Bool
    /// 待执行断言 token（nil = 无待执行）。App 消费后经 reportOrchestration 回报；
    /// TTL（=冷却窗 600s）过期后 daemon 重发（R2 P1：防非管理员回报被鉴权拒 →
    /// pending 永不清 → 编排死锁）。
    public var pendingToken: String?
    /// 待执行目标百分比（与 pendingToken 同拍签发；App 执行 `shortcuts run -i`
    /// 的百分数输入——daemon 只发数字，名字仅 App 侧消费，R1 P0-2）。
    public var pendingTarget: Int?
    /// 最近一次确认生效的目标（ok 回报写入；daemon 重启即丢——不持久化，首 tick
    /// valueChange 幂等误发一次，S3 已证同值重设无痕，R1 P2 取舍）。
    public var lastApplied: Int?
    /// 最近一次失败回报详情（ok=false 回报写入；成功回报即清）。
    public var lastError: String?

    public init(
        enabled: Bool, pendingToken: String? = nil, pendingTarget: Int? = nil,
        lastApplied: Int? = nil, lastError: String? = nil
    ) {
        self.enabled = enabled
        self.pendingToken = pendingToken
        self.pendingTarget = pendingTarget
        self.lastApplied = lastApplied
        self.lastError = lastError
    }
}

/// daemon 编排运行时状态（DaemonCore.orchestrationState 存储组；**锁内内存态
/// 不持久化**——R1 P2 取舍登记：重启后 lastApplied 丢失 → 首 tick valueChange
/// 幂等误发一次 + 冷却窗重置，换零新增落盘面，照 lastAutoDischargeCompletedAt
/// 内存态先例）。
public struct OrchestrationState: Equatable, Sendable {
    /// 已签发未消费的断言 token（单槽——同一时刻至多一个 pending）。
    public var pendingToken: String?
    /// 与 pendingToken 同拍签发的目标值（ok 回报时写入 lastApplied 的来源）。
    public var pendingTarget: Int?
    /// 最近一次断言签发时刻（TTL 与冷却门共用——R2 P1 钉死 TTL=冷却窗）。
    public var lastRequestAt: Date?
    /// 最近一次确认生效的目标（ok 回报写入）。
    public var lastAppliedTarget: Int?
    /// 最近一次失败回报详情（ok=false 写入；ok=true 清空）。
    public var lastError: String?

    public init(
        pendingToken: String? = nil, pendingTarget: Int? = nil, lastRequestAt: Date? = nil,
        lastAppliedTarget: Int? = nil, lastError: String? = nil
    ) {
        self.pendingToken = pendingToken
        self.pendingTarget = pendingTarget
        self.lastRequestAt = lastRequestAt
        self.lastAppliedTarget = lastAppliedTarget
        self.lastError = lastError
    }

    /// 空状态（daemon 启动初值）。
    public static let empty = OrchestrationState()

    /// 是否有未消费断言（真值表规则 3 输入）。
    public var hasOutstanding: Bool { pendingToken != nil }
}

/// 断言决策（orchestrationTickLocked 执行依据：none = 本拍不动；assert = 签发
/// pendingToken + 记 lastRequestAt，等 App 下轮轮询消费）。
public enum AssertionDecision: Equatable, Sendable {
    case none
    case assert(reason: AssertionReason)
}

/// 断言动因（诊断可见性；wire 不承载——仅 daemon 日志/测试断言消费）。
public enum AssertionReason: Equatable, Sendable {
    /// 目标变化（lastApplied != desired——不受冷却限制，幂等直达）。
    case valueChange
    /// 行为验证（S4：当前上限无读回通道——外接 ∧ 充电中 ∧ 电量已达目标时重申，
    /// 冷却门内静默）。
    case enforcement
}

/// 编排决策纯函数家族（无状态无 IO；daemon 侧状态由调用方持有传入）。
public enum NativeOrchestration {
    /// 默认冷却窗 / outstanding TTL（R2 P1：TTL = 冷却窗——签发时刻超窗视为过期
    /// 可重发，churn 上界从每 tick 收敛为每窗一次；确认链降级可用、编排不停摆）。
    public static let defaultCooldown: TimeInterval = 600

    /// 快捷指令默认动作名（App 侧 UserDefaults 缺省值 + doctor 检查 17 探测比对
    /// 同源——单一真相，勿双处字面量）。
    public static let defaultShortcutName = "设定电池充电上限"

    /// 目标映射：effectiveLimit → 原生编排目标（S6：27 原生范围硬限 80-100）。
    /// - `>= 80` → `(min(effectiveLimit, 100), false)`；
    /// - `< 80` → `(80, true)`——UI 标注「原生最低 80」。
    public static func nativeTarget(effectiveLimit: Int) -> (target: Int, clamped: Bool) {
        guard effectiveLimit >= 80 else { return (80, true) }
        return (min(effectiveLimit, 100), false)
    }

    /// 重申决策真值表（R2 复审定版，判定次序逐条短路——次序即契约，勿重排）：
    /// 1. `desired == nil ∨ !modeActive`（编排关 / mode != active——27 上 disable
    ///    无物理动作，语义 = 停止编排）→ .none
    /// 2. `actionActive`（fullOnce 等在轨）→ .none（不对抗；27 上 fullOnce 本就被
    ///    拒绝启动（WP-5），本规则兜底 26- 与未来动作）
    /// 3. `hasOutstanding ∧ 未过期`（outstanding 带 TTL=冷却窗——签发时刻超 TTL
    ///    视为过期可重发；App 缺席期去抖目标保留：churn 上界每 TTL 一次）→ .none
    /// 4. `lastApplied != desired` → .assert(.valueChange)（**不受冷却限制**——
    ///    动作终态后 lastApplied != desired 自然立即补发，R1 P2 actionActive 优先
    ///    于 valueChange 的配套语义）
    /// 5. `lastApplied == desired ∧ external ∧ isCharging ∧ percent >= desired`
    ///    → 冷却门外 .assert(.enforcement)、门内 .none
    /// 6. 其余 → .none
    ///
    /// 边界钉死：`now - lastRequestAt >= cooldown` 同时判定 TTL 过期（规则 3）与
    /// 冷却门外（规则 5）。lastRequestAt == nil 一律视为已过期/冷却门外（规则 4/5
    /// 接管）——daemon 不变量保证 pendingToken 在场则 lastRequestAt 同拍在场
    /// （orchestrationTickLocked 同拍签发、reportOrchestration 同拍清空），nil 角点
    /// 生产不可达（0.19.20 评审 P3-1：注释与实现对齐）。
    public static func assertionRequest(
        desired: Int?, lastApplied: Int?, lastRequestAt: Date?, now: Date,
        external: Bool, isCharging: Bool, percent: Int,
        cooldown: TimeInterval = defaultCooldown, actionActive: Bool, modeActive: Bool,
        hasOutstanding: Bool
    ) -> AssertionDecision {
        // 1) 编排关 / mode 门。
        guard desired != nil, modeActive else { return .none }
        // 2) 动作在轨一律不对抗。
        guard !actionActive else { return .none }
        // 签发时刻起算的流逝（nil = 从未签发）。
        let elapsed: TimeInterval?
        if let lastRequestAt {
            elapsed = now.timeIntervalSince(lastRequestAt)
        } else {
            elapsed = nil
        }
        let windowElapsed = (elapsed ?? .infinity) >= cooldown
        // 3) 未消费断言未过期 → 去抖（过期可重发——规则 4/5 接管）。
        if hasOutstanding && !windowElapsed { return .none }
        // 4) 目标变化：不受冷却限制。
        if lastApplied != desired { return .assert(reason: .valueChange) }
        // 5) 行为验证重申（冷却门外）。
        if external, isCharging, percent >= desired ?? 0 {
            return windowElapsed ? .assert(reason: .enforcement) : .none
        }
        // 6) 其余。
        return .none
    }
}
