// CellarCoreCheck —— 0.23.0 §⑥ GitHub 更新提示：AppVersion.isNewer 纯函数场景域
//
// 覆盖清单（方案 §8：≥9 用例——等值/大小/跨位/alpha→final 提醒/同后缀不重复/
// v 前缀/畸形恒 false ×2）：
// ① 数值比较（patch/minor/major 严格大于；等值/更旧恒 false）
// ② alpha→final 同号提醒（current 带后缀 ∧ latest 无后缀 ∧ 数值相等 → true）
// ③ 同后缀不重复 / 正式→预发布不提醒
// ④ v 前缀容错 / 空白容错
// ⑤ 畸形恒 false（任一侧无法解析——红队 F11 fail-silent 方向）
//
// 纯函数面（无 IO）；UpdateChecker 的网络/节流/通知面在 App 层（无 harness——
// 照 SuppressionRecovery 执行层同待遇，代码走查 + 真机验收兜底）。

import CellarCore
import Foundation

/// AppVersion 场景域入口（Main.main 调用）。
func runAppVersionDomainScenarios() {
    // 版本-1：完全等值（无后缀）→ false。
    check(!AppVersion.isNewer(current: "0.23.0", latest: "0.23.0"), "版本-1",
          "等值 → 不提示（重复提醒防抖基线）")

    // 版本-2：patch/minor/major 各位严格大于 → true。
    check(AppVersion.isNewer(current: "0.23.0", latest: "0.23.1"), "版本-2",
          "patch 0→1 → 提示")
    check(AppVersion.isNewer(current: "0.23.0", latest: "0.24.0"), "版本-2",
          "minor 23→24 → 提示")
    check(AppVersion.isNewer(current: "0.22.4", latest: "0.23.0"), "版本-2",
          "minor 22→23 跨位（0.22.4 → 0.23.0 真实升级路径）→ 提示")
    check(AppVersion.isNewer(current: "0.23.9", latest: "1.0.0"), "版本-2",
          "major 0→1 → 提示")

    // 版本-3：latest 更旧 → false（降级不提示）。
    check(!AppVersion.isNewer(current: "0.23.1", latest: "0.23.0"), "版本-3",
          "latest patch 更旧 → 不提示")
    check(!AppVersion.isNewer(current: "1.0.0", latest: "0.99.9"), "版本-3",
          "latest major 更旧 → 不提示")

    // 版本-4：alpha→final 同版本号提醒（常规 P3 采纳）。
    check(AppVersion.isNewer(current: "0.23.0-alpha", latest: "0.23.0"), "版本-4",
          "current 预发布 ∧ latest 正式 ∧ 数值相等 → 提示（alpha→final 升级提醒）")
    check(AppVersion.isNewer(current: "0.23.0-alpha", latest: "0.23.1"), "版本-4",
          "current 预发布 ∧ latest 正式更高 → 提示（数值优先）")

    // 版本-5：同后缀不重复 / 反向不提醒。
    check(!AppVersion.isNewer(current: "0.23.0-alpha", latest: "0.23.0-alpha"), "版本-5",
          "同后缀等值 → 不提示（同版本 alpha 重复检查去重）")
    check(!AppVersion.isNewer(current: "0.23.0", latest: "0.23.0-alpha"), "版本-5",
          "current 正式 ∧ latest 预发布（同号）→ 不提示（降级到预发布不提醒）")
    check(!AppVersion.isNewer(current: "0.23.0-alpha", latest: "0.23.0-beta"), "版本-5",
          "alpha → beta 同号 → 不提示（预发布间互换非升级信号）")

    // 版本-6：v 前缀 / 空白容错（GitHub release tag 形态 vX.Y.Z）。
    check(AppVersion.isNewer(current: "0.23.0", latest: "v0.24.0"), "版本-6",
          "latest 带 v 前缀 → 提示（tag 形态容错）")
    check(!AppVersion.isNewer(current: "v0.23.0", latest: "0.23.0"), "版本-6",
          "current 带 v 前缀等值 → 不提示（前缀不参与比较）")

    // 版本-7：畸形恒 false（红队 F11——任一侧无法解析即不提示）。
    check(!AppVersion.isNewer(current: "dev", latest: "0.24.0"), "版本-7",
          "current 畸形（非三段数值）→ 恒 false（本地构建无版本号形态）")
    check(!AppVersion.isNewer(current: "0.23.0", latest: "not-a-version"), "版本-7",
          "latest 畸形（API 返回异常形态）→ 恒 false（漏提示优于误提示）")
    check(!AppVersion.isNewer(current: "0.23", latest: "0.24.0"), "版本-7",
          "current 两段 → 畸形恒 false（段数不符不猜测）")
    check(!AppVersion.isNewer(current: "0.23.0.1", latest: "0.24.0"), "版本-7",
          "current 四段 → 畸形恒 false（同上）")
}
