// CellarCoreCheck —— suppression 自动恢复决策场景域（0.22.1 §1.1 判定规则钉死
// + §4 清单 ≥7 case：①边沿 false→true ②首样本 nil→true 破例 ③current
// nil/false 全拒（26 红线）④mode 非 active skip ⑤锁存持续未到冷却 skip
// ⑥冷却已过 attempt（重试臂）⑦lastAttemptAt nil ∧ 持续锁存 attempt；
// 0.22.2 §1.1 增补：openValue 写值 3 case；
// **0.22.4 §3.3 翻新（本域现状口径）**：lastOutcomeSucceeded 参数删除（0.22.2
// 成功门退役——其防护的补偿互搏面已随补偿臂静默门 NativeLimitSet.
// compensationSilenced 结构性消失，单一口径 = 冷却节奏）+ 边沿臂加冷却（F5
// 拍动亚态防护——边沿不再旁路 retryCooldown）+ 新增 fullOpenWindow 输入（两窗
// 任一在位不派发——锁存跨窗时恢复写 80 对抗窗语义 100，常规 P1-4）。

import CellarCore
import Foundation

/// suppression 恢复决策场景域入口（Main.main 调用）。
func runSuppressionRecoveryDomainScenarios() {
    let t0 = Date(timeIntervalSince1970: 3_000_000)
    func tick(_ n: Int) -> Date { t0.addingTimeInterval(Double(n) * 30) }   // 30s tick 节奏

    // ---- 同源常量（评审 P3-6：勿复制 600 字面量）----

    // 恢复-0：retryCooldown 与 Topoff.reassertionCooldown 同源（App 重试节奏与
    // daemon 锁存期重写限频同窗防漂移）。
    expectEqual(SuppressionRecovery.retryCooldown, Topoff.reassertionCooldown,
                "恢复-0", "retryCooldown 引用 Topoff.reassertionCooldown 同源")

    // ---- 0.22.2 §1.1 openValue 写值（H-A 命题——非 100 值 = 开启指令）----

    // 恢复-V1：target < 80 → 写 80（开启垫脚石——先把机制打开，0.22.4 模型 v2
    // 起域写值直接流入 MCL 执法，补偿臂域承载态静默、域即时接管；75 即走查现场
    // 目标）。
    expectEqual(SuppressionRecovery.openValue(for: 75), 80,
                "恢复-V1", "openValue(75) == 80（<80 目标写开启垫脚石值）")
    // 恢复-V2：target ≥ 80 → 值即目标（agent 直接停在该值，一步收敛）。
    expectEqual(SuppressionRecovery.openValue(for: 85), 85,
                "恢复-V2", "openValue(85) == 85（≥80 目标恒等）")
    // 恢复-V3：target == 100 边界 → 恒等（退化为 0.22.1 行为可接受——
    // suppression 语义下 owned 拍 target < 100 恒成立）。
    expectEqual(SuppressionRecovery.openValue(for: 100), 100,
                "恢复-V3", "openValue(100) == 100（上边界恒等）")

    // ---- ①② 触发臂（边沿 / 首包破例——0.22.4 边沿受冷却、首包保留立即）----

    // 恢复-1：边沿 false→true ∧ 本会话未派发过 → attempt（机制刚被关闭即恢复；
    // 冷却判定对 nil lastAttemptAt 放行——边沿与持续锁存共用该臂）。
    check(SuppressionRecovery.shouldAttempt(
        previous: false, current: true, modeActive: true,
        lastAttemptAt: nil, fullOpenWindow: false, now: tick(1)),
        "恢复-1", "边沿 false→true ∧ 未尝试过 → 尝试恢复")

    // 恢复-1b（0.22.4 F5 翻新钉面）：边沿 ∧ 冷却内 → skip（边沿不再旁路冷却——
    // 旧「边沿优先于冷却臂」随拍动亚态 b′ 防护废除：高频「释放→再关→再锁存」
    // 边沿由统一冷却限速，写节奏 ≥10 min）。
    check(!SuppressionRecovery.shouldAttempt(
        previous: false, current: true, modeActive: true,
        lastAttemptAt: tick(1), fullOpenWindow: false, now: tick(2)),
        "恢复-1b", "边沿 ∧ 距上次尝试 < 10 min → 冷却内跳过（F5——边沿不再旁路冷却）")

    // 恢复-1c：边沿 ∧ 冷却已过 → attempt（合法再恢复——冷却到期即放行，边沿与
    // 持续锁存同判据）。
    check(SuppressionRecovery.shouldAttempt(
        previous: false, current: true, modeActive: true,
        lastAttemptAt: tick(1), fullOpenWindow: false,
        now: tick(1).addingTimeInterval(SuppressionRecovery.retryCooldown + 30)),
        "恢复-1c", "边沿 ∧ 冷却已过 → 尝试恢复（统一冷却口径）")

    // 恢复-2：首样本 nil→true → attempt（首包破例——菜单栏独占场景 App 重启后
    // 首包即恢复，不等第二包；对齐 0.22.0 通知边沿首包破例语义）。
    check(SuppressionRecovery.shouldAttempt(
        previous: nil, current: true, modeActive: true,
        lastAttemptAt: nil, fullOpenWindow: false, now: tick(1)),
        "恢复-2", "首样本 nil→true → 首包破例尝试恢复")

    // 恢复-2b：首包 ∧ 近期有派发记录（重启前遗留 lastAttemptAt 语义同拍构造）
    // → attempt（**首包臂保留立即**——App 重启无在途恢复写，立即派发无风险；
    // 0.22.4 唯一旁路冷却的臂）。
    check(SuppressionRecovery.shouldAttempt(
        previous: nil, current: true, modeActive: true,
        lastAttemptAt: tick(1), fullOpenWindow: false, now: tick(2)),
        "恢复-2b", "首包 ∧ 冷却内 → 仍尝试（首包臂保留立即——重启无在途风险）")

    // ---- ③ 26 红线（nil 全拒）+ current false ----

    // 恢复-3：current nil / false → skip（26/旧 daemon wire 恒 nil 零触及——
    // 执行层仅由判定函数 true 触发，nil 输入不可达执行层）。
    check(!SuppressionRecovery.shouldAttempt(
        previous: true, current: nil, modeActive: true,
        lastAttemptAt: nil, fullOpenWindow: false, now: tick(1)),
        "恢复-3", "current nil（26/旧 daemon）→ 零触及")
    check(!SuppressionRecovery.shouldAttempt(
        previous: false, current: false, modeActive: true,
        lastAttemptAt: nil, fullOpenWindow: false, now: tick(1)),
        "恢复-3", "current false（锁存未置位）→ 零触及")
    // 双 nil（26 首包）同拒——首包破例不越过 current nil 拒绝门（门序：current
    // 最先判）。
    check(!SuppressionRecovery.shouldAttempt(
        previous: nil, current: nil, modeActive: true,
        lastAttemptAt: nil, fullOpenWindow: false, now: tick(1)),
        "恢复-3", "current nil 首包（26 首包）→ 零触及")

    // ---- ④ mode 门（尊重停用意图；陈旧锁存兜住）----

    // 恢复-4：mode 非 active → skip（各臂先于 mode 门的形态全拒——边沿/首包/
    // 冷却到期重试三输入同验）。
    check(!SuppressionRecovery.shouldAttempt(
        previous: false, current: true, modeActive: false,
        lastAttemptAt: nil, fullOpenWindow: false, now: tick(1)),
        "恢复-4", "mode 非 active ∧ 边沿 → 尊重停用意图不恢复")
    check(!SuppressionRecovery.shouldAttempt(
        previous: nil, current: true, modeActive: false,
        lastAttemptAt: nil, fullOpenWindow: false, now: tick(1)),
        "恢复-4", "mode 非 active ∧ 首包破例 → 同拒（mode 门先于破例臂）")
    check(!SuppressionRecovery.shouldAttempt(
        previous: true, current: true, modeActive: false,
        lastAttemptAt: tick(0), fullOpenWindow: false,
        now: tick(0).addingTimeInterval(Topoff.reassertionCooldown * 2)),
        "恢复-4", "mode 非 active ∧ 冷却早已过 → 同拒（陈旧锁存靠 mode 门兜住）")

    // ---- ⑤⑥⑦ 锁存持续态（true→true）冷却三分支（0.22.4 单一口径）----

    // 恢复-5：锁存持续 ∧ 未到冷却 → skip（派发时刻即落值——在途窗/近期已试
    // 防重复派发；边界 -30s 内）。
    check(!SuppressionRecovery.shouldAttempt(
        previous: true, current: true, modeActive: true,
        lastAttemptAt: tick(1), fullOpenWindow: false,
        now: tick(1).addingTimeInterval(SuppressionRecovery.retryCooldown - 30)),
        "恢复-5", "锁存持续 ∧ 距上次尝试 < 10 min → 冷却内跳过")
    // 恰好到冷却边界 → attempt（≥ 判定语义钉面）。
    check(SuppressionRecovery.shouldAttempt(
        previous: true, current: true, modeActive: true,
        lastAttemptAt: tick(1), fullOpenWindow: false,
        now: tick(1).addingTimeInterval(SuppressionRecovery.retryCooldown)),
        "恢复-5", "锁存持续 ∧ 距上次尝试 == 10 min → 冷却到期重试（瞬时失败自愈）")

    // 恢复-6（0.22.4 翻新）：锁存持续 ∧ 冷却已过 → attempt（重试臂——0.22.4
    // 起写成功/写失败同口径：旧「上次失败才重试」的 lastOutcomeSucceeded 条件
    // 随成功门删除，锁存释放前每 10 min 稳定重试）。
    check(SuppressionRecovery.shouldAttempt(
        previous: true, current: true, modeActive: true,
        lastAttemptAt: tick(1), fullOpenWindow: false,
        now: tick(1).addingTimeInterval(SuppressionRecovery.retryCooldown + 30)),
        "恢复-6", "锁存持续 ∧ 冷却已过 → 重试臂尝试恢复（单一口径——不再区分上次结果）")

    // 恢复-7：锁存持续 ∧ lastAttemptAt nil → attempt（本会话尚未尝试过——
    // 例如 App 在锁存态启动后首包之后的后续包）。
    check(SuppressionRecovery.shouldAttempt(
        previous: true, current: true, modeActive: true,
        lastAttemptAt: nil, fullOpenWindow: false, now: tick(5)),
        "恢复-7", "锁存持续 ∧ lastAttemptAt nil → 立即尝试（尚未尝试过）")

    // ---- 0.22.4 两窗门（fullOpenWindow——常规 P1-4）----

    // 恢复-W1：两窗在位 ∧ 持续锁存 ∧ 冷却已过 → skip（窗语义 = 完全放开 100，
    // 恢复写 80 对抗窗语义——窗内不派发；窗出后下一拍冷却判定自然放行）。
    check(!SuppressionRecovery.shouldAttempt(
        previous: true, current: true, modeActive: true,
        lastAttemptAt: tick(1), fullOpenWindow: true,
        now: tick(1).addingTimeInterval(SuppressionRecovery.retryCooldown * 2)),
        "恢复-W1", "fullOpenWindow ∧ 持续锁存 → 窗内不派发（窗语义 100 优先）")

    // 恢复-W2：两窗在位 ∧ 边沿 → skip（窗门先于边沿臂——daemon 权威窗态不因
    // 锁存边沿让位）。
    check(!SuppressionRecovery.shouldAttempt(
        previous: false, current: true, modeActive: true,
        lastAttemptAt: nil, fullOpenWindow: true, now: tick(1)),
        "恢复-W2", "fullOpenWindow ∧ 边沿 → 窗内不派发（窗门先于边沿臂）")

    // 恢复-W3：两窗在位 ∧ 首包 → skip（code-review P3 补钉：窗门先于**首包臂**
    // ——防未来重构把首包臂提至窗门前时场景域不红；首包立即语义只在窗外成立）。
    check(!SuppressionRecovery.shouldAttempt(
        previous: nil, current: true, modeActive: true,
        lastAttemptAt: nil, fullOpenWindow: true, now: tick(1)),
        "恢复-W3", "fullOpenWindow ∧ 首包 → 窗内不派发（窗门先于首包臂）")
}
