import Foundation
import os

// MARK: - 一次性动作类型（Phase 3 WP2 §1.1）

/// 一次性动作（action.json 的 Codable 形态；当前唯一动作类型为 fullOnce「充满一次」）。
///
/// daemon 侧 lastAction 字面量契约（与通知分类互为镜像，CellarCoreCheck 钉死）：
/// `\(kind):start` / `\(kind):done` / `\(kind):cancel` / `\(kind):timeout` /
/// `\(kind):cancel(crash-recovery)`。
public struct OneShotAction: Codable, Equatable, Sendable {
    /// 动作类型字面量（当前仅 "fullOnce"；"/Library/Application Support/Cellar/action.json"
    /// 载入时 kind != "fullOnce" → 视为缺失）。
    public var kind: String
    /// 启动时刻。
    public var startedAt: Date
    /// 超时截止（start 时捕获的**绝对 Date**；SIGHUP 重载不重算，规格 §1.1）。
    public var deadline: Date

    public init(kind: String = OneShot.fullOnceKind, startedAt: Date, deadline: Date) {
        self.kind = kind
        self.startedAt = startedAt
        self.deadline = deadline
    }
}

// MARK: - 状态转移纯函数家族（规格 §1.3 安全约束）

/// fullOnce 判定纯函数（无状态、无 IO——去抖计数由调用方持有传入）。
public enum OneShot {
    /// 动作类型字面量（当前唯一动作）。
    public static let fullOnceKind = "fullOnce"
    /// 超时窗口（4 小时；deadline 为 start 时绝对 Date，SIGHUP 不重算）。
    public static let fullOnceTimeout: TimeInterval = 4 * 3600
    /// 完成判定去抖所需连续 tick 数（30s tick ×2 = 60s 去抖，规格 §1.3）。
    public static let fullOnceDebounceTicks = 2

    /// 创建一次性动作（deadline = now + 超时窗口）。
    public static func onshotStart(now: Date, kind: String = fullOnceKind) -> OneShotAction {
        OneShotAction(kind: kind, startedAt: now, deadline: now.addingTimeInterval(fullOnceTimeout))
    }

    /// 完成判定（规格 §1.3）：
    /// - 主判据：`fullyCharged == true && !isCharging`
    /// - 降级（FullyCharged 键缺/类型不符 → nil 的解析容错）：`percent >= 99 && !isCharging`
    /// - `fullyCharged == false` 恒不成立（键在位即为真实语义，本机实测 91% 时 = No）——
    ///   降级仅覆盖 nil，不覆盖 false。
    public static func isFullOnceComplete(fullyCharged: Bool?, isCharging: Bool, percent: Int) -> Bool {
        guard !isCharging else { return false }
        if let fullyCharged { return fullyCharged }
        return percent >= 99
    }

    /// 超时判定：now >= deadline → 超时。
    public static func isTimedOut(action: OneShotAction, now: Date) -> Bool {
        now >= action.deadline
    }

    /// 去抖推进（计数由调用方持有传入、回传；条件不满足即归零——中断归零语义）：
    /// 返回 satisfied = 连续达到 requiredConsecutive 个满足 tick。
    public static func debounceTick(
        conditionSatisfied: Bool,
        counter: Int,
        requiredConsecutive: Int = fullOnceDebounceTicks
    ) -> (satisfied: Bool, counter: Int) {
        guard conditionSatisfied else { return (false, 0) }
        let next = counter + 1
        return (next >= requiredConsecutive, next)
    }
}

// MARK: - lastAction 字面量契约（与 daemon/通知分类隐式契约，规格 §1.7）

/// 动作字面量构造（daemon 侧 lastAction 输出与 CellarCoreCheck 钉死值同源）。
public enum OneShotLiteral {
    public static func start(kind: String = OneShot.fullOnceKind) -> String { "\(kind):start" }
    public static func done(kind: String = OneShot.fullOnceKind) -> String { "\(kind):done" }
    public static func cancel(kind: String = OneShot.fullOnceKind) -> String { "\(kind):cancel" }
    public static func timeout(kind: String = OneShot.fullOnceKind) -> String { "\(kind):timeout" }
    public static func cancelCrashRecovery(kind: String = OneShot.fullOnceKind) -> String { "\(kind):cancel(crash-recovery)" }
}

// MARK: - 启动前置（纯函数，规格 §1.1/§1.3）

/// fullOnce 启动前置拒绝（daemon 上抛 → XPC errorReply 原文；description = 用户可读文案）。
public enum OneShotStartRejection: Error, Equatable, Sendable, CustomStringConvertible {
    /// mode != "active"（含 disabled——60% 地板不适用，但 mode == "disabled" 拒绝，§1.3）。
    case modeNotActive
    /// 未确认外接电源（未外接或外接状态未知——快照失败且无上次已知值）。
    case noExternalPower
    /// action.json 写入失败（动作不启动——持久化是动作存活的前提）。
    case persistenceFailed

    public var message: String {
        switch self {
        case .modeNotActive: return "「充满一次」需要限充处于启用状态（当前已停用）"
        case .noExternalPower: return "「充满一次」需要连接外接电源"
        case .persistenceFailed: return "「充满一次」启动失败：无法写入动作文件"
        }
    }

    public var description: String { message }
}

/// fullOnce 启动前置（规格 §1.1/§1.3）：外接电源 && mode == "active"。
/// externalConnected 为 nil（快照失败且无上次已知值）→ 拒绝（不无据启动）。
public func fullOnceStartPrecondition(mode: String, externalConnected: Bool?) -> OneShotStartRejection? {
    guard mode == "active" else { return .modeNotActive }
    guard externalConnected == true else { return .noExternalPower }
    return nil
}

// MARK: - 六路径门控状态机（规格 §1.1 表格；daemon 锁内单实例持有）

/// 轨道 tick 的决策结果（daemon 依此执行副作用：写 CHTE / 删文件 / 字面量落状态）。
public enum OneShotTickOutcome: Equatable, Sendable {
    /// 完成（连续达标）→ 恢复限充（写 CHTE 停充）+ done 终态。
    case completed
    /// 超时 → 恢复限充 + timeout 终态。
    case timedOut
    /// 轨道空载（防御分支：daemon 在活跃分支内不会遇到）。
    case idle
    /// 未完成未超时 → 保活充电 + start 字面量。
    case keepAlive
}

/// 一次性动作轨道状态机：**规格 §1.1 六路径门控的纯值实现**——activeAction、
/// 终态字面量锁存（P0-2 方案 a）、完成去抖计数全部经本类型转移，daemon 在调用点
/// 依返回值执行 IO/日志副作用。锁纪律不变：本类型被 daemon 锁内单实例持有。
public struct OneShotTrack: Equatable, Sendable {
    public private(set) var action: OneShotAction?
    /// 终态字面量锁存（P0-2 方案 a）：fullOnce:* 终态被锁存，常规 tick 不覆盖，
    /// 直到下一次用户动作（setLimits/enable/disable/fullOnce 重启）才清除。
    public private(set) var latchedLiteral: String?
    /// 完成判定去抖计数（连续满足条件 tick 数；中断归零）。
    public private(set) var debounceTicks = 0

    public init() {}

    public var isActive: Bool { action != nil }

    /// fullOnce 启动（前置已在调用方校验——mode/external）：已活跃 → false
    /// （幂等语义：daemon 回当前状态而非错误）；否则接管动作 + 清锁存（用户动作
    /// 清除锁存，P0-2）+ 去抖归零。
    @discardableResult
    public mutating func startIfIdle(now: Date, kind: String = OneShot.fullOnceKind) -> Bool {
        guard !isActive else { return false }
        action = OneShot.onshotStart(now: now, kind: kind)
        latchedLiteral = nil
        debounceTicks = 0
        return true
    }

    /// 维护 tick（performTickLocked 动作分支的纯决策，规格 §1.1 tick 行）：
    /// 完成判定（主判据 + 降级）→ 连续 2 tick 去抖（中断归零）→ completed；
    /// 未完成且 now >= deadline → timedOut；**同 tick 完成与超时并存 → 完成优先**
    /// （长睡唤醒场景报 done 而非 timeout）；否则 keepAlive。
    public mutating func tick(
        now: Date,
        fullyCharged: Bool?,
        isCharging: Bool,
        percent: Int
    ) -> OneShotTickOutcome {
        guard let action else { return .idle }
        let completedNow = OneShot.isFullOnceComplete(
            fullyCharged: fullyCharged, isCharging: isCharging, percent: percent
        )
        let step = OneShot.debounceTick(conditionSatisfied: completedNow, counter: debounceTicks)
        debounceTicks = step.counter
        // 完成优先：completedNow 成立时（含去抖未满）不判超时——长睡唤醒报 done 而非 timeout。
        let timedOutNow = !completedNow && OneShot.isTimedOut(action: action, now: now)
        if step.satisfied || timedOutNow {
            debounceTicks = 0
            latchedLiteral = step.satisfied
                ? OneShotLiteral.done(kind: action.kind)
                : OneShotLiteral.timeout(kind: action.kind)
            self.action = nil
            return step.satisfied ? .completed : .timedOut
        }
        return .keepAlive
    }

    /// 用户/隐式取消（setLimits / disable / restoreAndExit / SIGHUP-disabled /
    /// XPC cancelAction）：终态字面量 `fullOnce:cancel` **不锁存**（调用方直写
    /// lastStatus）+ 动作清除 + 清锁存。空轨 → nil（幂等成功语义）。
    @discardableResult
    public mutating func cancel() -> String? {
        guard let action else { return nil }
        let literal = OneShotLiteral.cancel(kind: action.kind)
        self.action = nil
        latchedLiteral = nil
        debounceTicks = 0
        return literal
    }

    /// 崩溃恢复取消（P0-2，startup）：发现 action.json → **一律取消、不恢复执行**；
    /// 终态字面量 `fullOnce:cancel(crash-recovery)` **锁存**（重启后首个 tick/轮询
    /// 不覆盖——App 轮询必见终态）。空轨 → nil（无动作启动）。
    @discardableResult
    public mutating func cancelForCrashRecovery() -> String? {
        guard let action else { return nil }
        let literal = OneShotLiteral.cancelCrashRecovery(kind: action.kind)
        self.action = nil
        latchedLiteral = literal
        debounceTicks = 0
        return literal
    }

    /// SIGHUP 重载语义（P1-1）：cancelled（重载后 mode == "disabled"）→ 取消动作；
    /// 否则动作存活（本方法不触碰 deadline——deadline 与完成判定不重算）。
    @discardableResult
    public mutating func reload(cancelled: Bool) -> String? {
        cancelled ? cancel() : nil
    }

    /// lastAction 生效值（P0-2 锁存）：锁存字面量优先于本次构造值（常规 tick 不覆盖）。
    public func effectiveLastAction(_ constructed: String?) -> String? {
        latchedLiteral ?? constructed
    }

    /// 用户动作清除终态锁存（setLimits/enable/disable 的通道；P0-2：锁存只活到
    /// 下一次用户动作）。newLatch 是幂等清除——无锁存时无操作。
    public mutating func clearUserActionLatch() {
        latchedLiteral = nil
    }
}

// MARK: - 一次性动作持久化（独立于 policy.json——格式红线不动，规格 §6）

/// 动作持久化（/Library/Application Support/Cellar/action.json；原子写 + 校验式读）。
///
/// - 读：文件缺失 / 非 JSON / 解码失败 / kind != "fullOnce" → nil + os_log
///   （损坏 treat-as-absent，与 PolicyStore 同模式独立实现——不复用其写路径）。
/// - 写：同目录临时文件（0644）+ rename（原子替换；失败原样上抛，daemon 侧记日志）。
/// - 删：幂等（缺失视为成功——终态/取消后清理，双删不报错）。
public struct ActionStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `/Library/Application Support/Cellar/action.json`（daemon 自举目录后可用）。
    public static var defaultURL: URL {
        URL(fileURLWithPath: "/Library/Application Support/Cellar/action.json")
    }

    /// 文件是否存在（daemon 启动崩溃恢复区分「缺失」与「损坏/未知动作类型」）。
    public var fileExists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// 校验式读：缺失 / 损坏 / kind 不符 → nil + 日志（绝不回落部分动作）。
    public func load() -> OneShotAction? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(OneShotAction.self, from: data) else {
            Self.log.error("action.json 损坏（非 JSON 或字段不符），按缺失处理")
            return nil
        }
        guard decoded.kind == OneShot.fullOnceKind else {
            Self.log.error("action.json 动作类型未知（kind=\(decoded.kind)）——仅支持 fullOnce，按缺失处理")
            return nil
        }
        return decoded
    }

    /// 原子写（同目录临时文件 + rename），文件权限 0644。
    /// 父目录缺失等错误原样上抛（daemon main 已自举目录；写失败拒绝动作启动）。
    public func save(_ action: OneShotAction) throws {
        let data = try JSONEncoder().encode(action)
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".action.json.tmp")
        // 清理：任何失败路径都尽力移除临时文件（不覆盖原错误）。
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try data.write(to: temporaryURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: temporaryURL.path
        )
        #if canImport(Darwin)
        guard rename(temporaryURL.path, url.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        #else
        // 非 Darwin 兜底（本包仅 macOS，此路径仅保持可编译性）：非原子替换。
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
        #endif
    }

    /// 删除动作文件（终态/取消/崩溃恢复后清理）。缺失视为成功（幂等删除）。
    public func delete() throws {
        if fileExists {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// 日志（struct 静态成员非隔离；Logger Sendable，跨隔离界安全）。
    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "action-store")
}