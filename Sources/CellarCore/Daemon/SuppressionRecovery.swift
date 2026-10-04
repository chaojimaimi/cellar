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
///   通知边沿首包破例——菜单栏独占场景 App 重启后首包即恢复，不等第二包；
///   **旁路成功门**——首包无「上次结果」可言）；
/// - 边沿：previous == false ∧ current == true → true（机制刚被关闭即恢复；
///   **旁路成功门**——重新压制 = 新事件，与上次写结果无关）；
/// - 非边沿的锁存持续态（true→true）：`lastOutcomeSucceeded == true` → false
///   （**0.22.2 重试互搏防护**——上次恢复写已成功、MCL 已开，持续锁存只是
///   收敛链尚未走完（daemon 冷却重写/agent 跟随在读回一致前 wire 恒 true）；
///   此时冷却重试只会重开 ≤30s 的 80 窗与对账补偿 100 互搏、反复重置 daemon
///   锁存释放检查）；否则（nil = 结果未知 / false = 上次失败）沿用冷却判定：
///   `lastAttemptAt == nil ∨ now - lastAttemptAt ≥ retryCooldown` → true
///   （**瞬时失败自愈**——恢复写失败后每 10 min 重试直至锁存释放）；否则
///   false（冷却内跳过，防在途窗重复派发）。
public enum SuppressionRecovery {
    /// 冷却窗：直接引用 Topoff.reassertionCooldown（public 常量，Topoff.swift:26）
    /// ——同值同源防漂移（评审 P3-6；daemon 侧锁存期重写限频同窗，App 重试
    /// 节奏与 daemon 重写节奏对齐）。
    public static let retryCooldown: TimeInterval = Topoff.reassertionCooldown

    /// 0.22.2 §1.1 恢复写值（H-A 命题：开启指令的载体 = 非 100 值——0.22.1
    /// 实证 `setMCLLimit(100)` 不携带开启指令，机制开关状态不受该调用影响；
    /// UI 设 80 有效 + S3 客户端方法面无独立 enable 方法 ⇒ 值必须自带语义）。
    /// 写 `max(target, 80)`：target ≥ 80 时值即目标（agent 直接停在该值，一步
    /// 收敛）；target < 80 时写 80 作开启垫脚石（先把机制打开，App 对账补偿臂
    /// 随后 API 写 100 让域接管——开态写 100 保持开，0.20-0.21 对账史定谳）。
    /// target 100 时退化为写 100 可接受：suppression 语义下 owned 拍
    /// target < 100 恒成立。
    public static func openValue(for target: Int) -> Int {
        max(target, 80)
    }

    /// 应否尝试恢复（true = 派发恢复写 `MCLClient.setLimit(openValue(for:))`）。
    /// 输入：previous/现值 wire 态（nil = 26/旧 daemon 或首包）、daemon mode
    /// 是否 active、上次恢复写派发时刻、上次恢复写结果（nil = 尚无结果——
    /// 派发后在途回调前/历史会话）、now。
    public static func shouldAttempt(
        previous: Bool?, current: Bool?, modeActive: Bool,
        lastAttemptAt: Date?, lastOutcomeSucceeded: Bool?, now: Date
    ) -> Bool {
        // 26 红线门（首判）：current nil（26/旧 daemon）与 false（锁存未置位）
        // 全拒——nil 不可达执行层。
        guard current == true else { return false }
        // mode 门：非 active（用户停用）不恢复；先于首包破例/边沿/重试各臂。
        guard modeActive else { return false }
        // 首样本破例：previous == nil ∧ current == true → true（旁路成功门）。
        if previous == nil { return true }
        // 边沿：previous == false ∧ current == true → true（机制刚被关闭即恢复；
        // 旁路成功门——wire false→true = 机制再次被关，合法再恢复）。
        if previous == false { return true }
        // 锁存持续（true→true）：上次写成功 → 不再冷却重试（0.22.2 防护）；
        // 否则未尝试过 → 立即，冷却到期才重试。
        if lastOutcomeSucceeded == true { return false }
        guard let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= retryCooldown
    }
}
