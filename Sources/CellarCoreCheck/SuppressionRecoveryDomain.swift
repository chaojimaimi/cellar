// CellarCoreCheck —— 0.22.1 suppression 自动恢复决策场景域（方案 §1.1 判定规则
// 钉死 + §4 清单 ≥7 case：①边沿 false→true ②首样本 nil→true 破例 ③current
// nil/false 全拒（26 红线）④mode 非 active skip ⑤锁存持续未到冷却 skip
// ⑥冷却已过 attempt（重试臂）⑦lastAttemptAt nil ∧ 持续锁存 attempt）。

import CellarCore
import Foundation

/// 0.22.1 suppression 恢复决策场景域入口（Main.main 调用）。
func runSuppressionRecoveryDomainScenarios() {
    let t0 = Date(timeIntervalSince1970: 3_000_000)
    func tick(_ n: Int) -> Date { t0.addingTimeInterval(Double(n) * 30) }   // 30s tick 节奏

    // ---- 同源常量（评审 P3-6：勿复制 600 字面量）----

    // 恢复-0：retryCooldown 与 Topoff.reassertionCooldown 同源（App 重试节奏与
    // daemon 锁存期重写限频同窗防漂移）。
    expectEqual(SuppressionRecovery.retryCooldown, Topoff.reassertionCooldown,
                "恢复-0", "retryCooldown 引用 Topoff.reassertionCooldown 同源")

    // ---- ①② 触发臂（边沿 / 首包破例）----

    // 恢复-1：边沿 false→true → attempt（机制刚被关闭即恢复）。
    check(SuppressionRecovery.shouldAttempt(
        previous: false, current: true, modeActive: true,
        lastAttemptAt: nil, now: tick(1)),
        "恢复-1", "边沿 false→true → 尝试恢复")

    // 恢复-1b：边沿臂优先于冷却臂（code-review P3——重新压制 = 新事件，立即
    // 恢复不受上次尝试冷却约束；钉死门序防「统一冷却门」重构悄悄翻转优先级，
    // 方案 §6 MDM 拉锯限速论证隐含此序）。
    check(SuppressionRecovery.shouldAttempt(
        previous: false, current: true, modeActive: true,
        lastAttemptAt: tick(1), now: tick(2)),
        "恢复-1b", "边沿优先于冷却——冷却未到期的新边沿仍尝试")

    // 恢复-2：首样本 nil→true → attempt（首包破例——菜单栏独占场景 App 重启后
    // 首包即恢复，不等第二包；对齐 0.22.0 通知边沿首包破例语义）。
    check(SuppressionRecovery.shouldAttempt(
        previous: nil, current: true, modeActive: true,
        lastAttemptAt: nil, now: tick(1)),
        "恢复-2", "首样本 nil→true → 首包破例尝试恢复")

    // ---- ③ 26 红线（nil 全拒）+ current false ----

    // 恢复-3：current nil / false → skip（26/旧 daemon wire 恒 nil 零触及——
    // 执行层仅由判定函数 true 触发，nil 输入不可达执行层）。
    check(!SuppressionRecovery.shouldAttempt(
        previous: true, current: nil, modeActive: true,
        lastAttemptAt: nil, now: tick(1)),
        "恢复-3", "current nil（26/旧 daemon）→ 零触及")
    check(!SuppressionRecovery.shouldAttempt(
        previous: false, current: false, modeActive: true,
        lastAttemptAt: nil, now: tick(1)),
        "恢复-3", "current false（锁存未置位）→ 零触及")
    // 双 nil（26 首包）同拒——首包破例不越过 current nil 拒绝门（门序：current
    // 最先判）。
    check(!SuppressionRecovery.shouldAttempt(
        previous: nil, current: nil, modeActive: true,
        lastAttemptAt: nil, now: tick(1)),
        "恢复-3", "current nil 首包（26 首包）→ 零触及")

    // ---- ④ mode 门（尊重停用意图；陈旧锁存兜住）----

    // 恢复-4：mode 非 active → skip（各臂先于 mode 门的形态全拒——边沿/首包/
    // 冷却到期重试三输入同验）。
    check(!SuppressionRecovery.shouldAttempt(
        previous: false, current: true, modeActive: false,
        lastAttemptAt: nil, now: tick(1)),
        "恢复-4", "mode 非 active ∧ 边沿 → 尊重停用意图不恢复")
    check(!SuppressionRecovery.shouldAttempt(
        previous: nil, current: true, modeActive: false,
        lastAttemptAt: nil, now: tick(1)),
        "恢复-4", "mode 非 active ∧ 首包破例 → 同拒（mode 门先于破例臂）")
    check(!SuppressionRecovery.shouldAttempt(
        previous: true, current: true, modeActive: false,
        lastAttemptAt: tick(0), now: tick(0).addingTimeInterval(Topoff.reassertionCooldown * 2)),
        "恢复-4", "mode 非 active ∧ 冷却早已过 → 同拒（陈旧锁存靠 mode 门兜住）")

    // ---- ⑤⑥⑦ 锁存持续态（true→true）三分支 ----

    // 恢复-5：锁存持续 ∧ 未到冷却 → skip（派发时刻即落值——在途窗/近期已试
    // 防重复派发；边界 -30s 内）。
    check(!SuppressionRecovery.shouldAttempt(
        previous: true, current: true, modeActive: true,
        lastAttemptAt: tick(1), now: tick(1).addingTimeInterval(SuppressionRecovery.retryCooldown - 30)),
        "恢复-5", "锁存持续 ∧ 距上次尝试 < 10 min → 冷却内跳过")
    // 恰好到冷却边界 → attempt（≥ 判定语义钉面）。
    check(SuppressionRecovery.shouldAttempt(
        previous: true, current: true, modeActive: true,
        lastAttemptAt: tick(1), now: tick(1).addingTimeInterval(SuppressionRecovery.retryCooldown)),
        "恢复-5", "锁存持续 ∧ 距上次尝试 == 10 min → 冷却到期重试（瞬时失败自愈）")

    // 恢复-6：锁存持续 ∧ 冷却已过 → attempt（重试臂——写失败后每 10 min 重试
    // 直至锁存释放）。
    check(SuppressionRecovery.shouldAttempt(
        previous: true, current: true, modeActive: true,
        lastAttemptAt: tick(1), now: tick(1).addingTimeInterval(SuppressionRecovery.retryCooldown + 30)),
        "恢复-6", "锁存持续 ∧ 冷却已过 → 重试臂尝试恢复")

    // 恢复-7：锁存持续 ∧ lastAttemptAt nil → attempt（本会话尚未尝试过——
    // 例如 App 在锁存态启动后首包之后的后续包）。
    check(SuppressionRecovery.shouldAttempt(
        previous: true, current: true, modeActive: true,
        lastAttemptAt: nil, now: tick(5)),
        "恢复-7", "锁存持续 ∧ lastAttemptAt nil → 立即尝试（尚未尝试过）")
}
