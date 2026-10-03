import Foundation

// MARK: - 0.22.1 suppression 自动恢复决策纯函数（方案 §1.1；App 侧恢复臂的唯一
// 判定入口——决策逻辑下沉 CellarCore 供 CellarCoreCheck 场景域钉死，执行层为
// App 层无 harness 走查验收，UD-7 同待遇）

/// suppression 锁存自动恢复判定（方案 §1.1 规则钉死；输入全部由调用方注入，
/// 零 IO 零时钟——纯函数）：
/// - `current != true` → false（含 nil = 26/旧 daemon，wire 恒 nil 零触及——
///   26 红线：nil 全拒，执行层仅由本函数 true 触发，nil 输入不可达执行层）；
/// - `modeActive != true` → false（用户已让 Cellar 停管时不强推机制——尊重
///   停用意图；陈旧锁存靠本门兜住，方案 §6 风险表）；
/// - **首样本破例**：previous == nil ∧ current == true → true（对齐 0.22.0
///   通知边沿首包破例——菜单栏独占场景 App 重启后首包即恢复，不等第二包）；
/// - 边沿：previous == false ∧ current == true → true（机制刚被关闭即恢复）；
/// - 非边沿的锁存持续态（true→true）：`lastAttemptAt == nil ∨
///   now - lastAttemptAt ≥ retryCooldown` → true（**瞬时失败自愈**——恢复写
///   失败后每 10 min 重试直至锁存释放）；否则 false（冷却内跳过，防在途窗
///   重复派发）。
public enum SuppressionRecovery {
    /// 冷却窗：直接引用 Topoff.reassertionCooldown（public 常量，Topoff.swift:26）
    /// ——同值同源防漂移（评审 P3-6；daemon 侧锁存期重写限频同窗，App 重试
    /// 节奏与 daemon 重写节奏对齐）。
    public static let retryCooldown: TimeInterval = Topoff.reassertionCooldown

    /// 应否尝试恢复（true = 派发恢复写 `MCLClient.setLimit(100)`）。
    /// 输入：previous/现值 wire 态（nil = 26/旧 daemon 或首包）、daemon mode
    /// 是否 active、上次恢复写派发时刻、now。
    public static func shouldAttempt(
        previous: Bool?, current: Bool?, modeActive: Bool,
        lastAttemptAt: Date?, now: Date
    ) -> Bool {
        // 26 红线门（首判）：current nil（26/旧 daemon）与 false（锁存未置位）
        // 全拒——nil 不可达执行层。
        guard current == true else { return false }
        // mode 门：非 active（用户停用）不恢复；先于首包破例/边沿/重试各臂。
        guard modeActive else { return false }
        // 首样本破例：previous == nil ∧ current == true → true。
        if previous == nil { return true }
        // 边沿：previous == false ∧ current == true → true（机制刚被关闭即恢复）。
        if previous == false { return true }
        // 锁存持续（true→true）：未尝试过 → 立即；否则冷却到期才重试。
        guard let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= retryCooldown
    }
}
