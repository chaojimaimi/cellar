import Foundation

// MARK: - 0.22.1 suppression 自动恢复决策纯函数（方案 §1.1；App 侧恢复臂的唯一
// 判定入口——决策逻辑下沉 CellarCore 供 CellarCoreCheck 场景域钉死，执行层为
// App 层无 harness 走查验收，UD-7 同待遇）

/// suppression 锁存自动恢复判定（**0.22.4 v2 单一口径**；输入全部由调用方注入，
/// 零 IO 零时钟——纯函数）：
/// - `current != true` → false（含 nil = 26/旧 daemon，wire 恒 nil 零触及——
///   26 红线：nil 全拒，执行层仅由本函数 true 触发，nil 输入不可达执行层）；
/// - `modeActive != true` → false（用户已让 Cellar 停管时不强推机制——尊重
///   停用意图；陈旧锁存靠本门兜住，方案 §6 风险表）；
/// - `fullOpenWindow == true` → false（0.22.4 常规 P1-4：fullOnce /
///   chargingDisabled 两窗语义 = 完全放开 100——锁存跨入两窗时恢复写 80 与窗
///   语义对抗，窗内不派发；窗位 wire 既有字段，窗出后下一拍自然重评）；
/// - **首样本破例**：previous == nil ∧ current == true → true（对齐 0.22.0
///   通知边沿首包破例——菜单栏独占场景 App 重启后首包即恢复，不等第二包；
///   App 重启无在途恢复写，立即派发无风险——0.22.4 保留立即语义）；
/// - 其余（边沿 false→true 与持续锁存 true→true）：**统一冷却判定**（0.22.4
///   F5——边沿不再旁路，与持续锁存同受 retryCooldown 约束）：
///   `lastAttemptAt == nil ∨ now - lastAttemptAt ≥ retryCooldown` → true，
///   否则 false（冷却内跳过，防在途窗重复派发）。
///
/// **0.22.4 删除 `lastOutcomeSucceeded` 参数（单一口径）**：0.22.2「上次写成功
/// → 持续锁存不重试」防护的动机是防恢复写 80 与对账补偿臂写 100 互搏（补偿互搏）
/// ——该互搏面已随 0.22.4 补偿臂门控（NativeLimitSet.compensationSilenced）结构性
/// 消失（域承载态补偿静默，不再有 100 写入），成功门失去保护对象；且 13:32 事故
/// 链中「成功后锁存未释放却永不再试」恰是恢复停滞的一翼——删除后恢复臂唯一口径
/// = 冷却节奏（写失败/写成功一致对待，锁存释放前每 10 min 重试，拍动亚态 b′ 写
/// 节奏 ≥10 min 限速）。
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
    /// **与 `Topoff.degradedWriteValue(for:)` 公式互钉**（0.23.0 §④ 红队 F7 附注
    /// ——同 `max(target, 80)` 形态，App 恢复写 vs daemon 降级稳态域写；公式
    /// 任一侧改动必须同步审视另一侧）。
    public static func openValue(for target: Int) -> Int {
        max(target, 80)
    }

    /// 应否尝试恢复（true = 派发恢复写 `MCLClient.setLimit(openValue(for:))`）。
    /// 输入：previous/现值 wire 态（nil = 26/旧 daemon 或首包）、daemon mode
    /// 是否 active、两窗是否任一在位（fullOnce ∨ chargingDisabled——窗内不派发）、
    /// 上次恢复写派发时刻、now。0.22.4 起无「上次结果」输入（单一口径，头注）。
    public static func shouldAttempt(
        previous: Bool?, current: Bool?, modeActive: Bool,
        lastAttemptAt: Date?, fullOpenWindow: Bool, now: Date
    ) -> Bool {
        // 26 红线门（首判）：current nil（26/旧 daemon）与 false（锁存未置位）
        // 全拒——nil 不可达执行层。
        guard current == true else { return false }
        // mode 门：非 active（用户停用）不恢复；先于首包破例/边沿/重试各臂。
        guard modeActive else { return false }
        // 两窗门（0.22.4 P1-4）：窗语义 = 完全放开 100，恢复写 80 对抗窗语义——
        // 窗内不派发（先于首包破例：窗是 daemon 权威态，破例不越窗）。
        guard !fullOpenWindow else { return false }
        // 首样本破例：previous == nil ∧ current == true → true（旁路冷却——
        // App 重启无在途恢复写，首包即恢复语义保持；0.22.4 唯一立即臂）。
        if previous == nil { return true }
        // 边沿（false→true）与持续锁存（true→true）统一冷却判定（0.22.4 F5：
        // 边沿不再旁路——拍动亚态 b′ 下「释放→再关→再锁存」高频边沿由冷却限速，
        // 写节奏 ≥10 min）。lastAttemptAt nil = 本会话尚未尝试过 → 立即。
        guard let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= retryCooldown
    }
}
