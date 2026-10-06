import Foundation

// MARK: - 0.23.0 §⑥ GitHub 更新提示——版本比较纯函数（CellarCore 可测层）

/// App 版本比较（纯函数，零 IO——UpdateChecker 的唯一决策入口，CellarCoreCheck
/// 场景域钉死）。解析 `vX.Y.Z[-suffix]` 形态（去 `v` 前缀；major/minor/patch 数值
/// 比对）：
/// - 数值严格大于 → true；
/// - **current 带后缀 ∧ latest 无后缀 ∧ 数值相等 → true**（alpha/beta → final
///   同版本号发布提醒，常规 P3 采纳）；
/// - 其余（等值同形态 / latest 更旧 / 同后缀）→ false；
/// - **畸形容错恒 false**（红队 F11——任一侧无法解析即不提示，绝不误报）。
public enum AppVersion {
    /// 解析结果（suffix 有无参与 alpha→final 判定；数值三元组参与大小比较）。
    private typealias Components = (major: Int, minor: Int, patch: Int, hasSuffix: Bool)

    /// latest 是否比 current 新（应提示更新）。
    public static func isNewer(current: String, latest: String) -> Bool {
        guard let currentParts = parse(current), let latestParts = parse(latest) else {
            return false   // 畸形任一侧 → 恒 false（fail-silent 方向安全——漏提示优于误提示）
        }
        // 字典序元组比较（code-review P3：数值打包在超大版本段下整数溢出 trap——
        // 「合法形态但溢出」是 F11 契约漏洞；元组比较天然免溢出且语义等价）。
        let currentTuple = (currentParts.major, currentParts.minor, currentParts.patch)
        let latestTuple = (latestParts.major, latestParts.minor, latestParts.patch)
        if latestTuple != currentTuple {
            return latestTuple > currentTuple
        }
        // 数值相等：仅「current 预发布（带后缀）→ latest 正式（无后缀）」提示
        // ——同后缀（alpha→alpha 同号）不重复提醒，正式→预发布更不提醒。
        return currentParts.hasSuffix && !latestParts.hasSuffix
    }

    /// 解析 `vX.Y.Z[-suffix]`：去空白与可选 `v`/`V` 前缀 → 取 `-` 前数值主部 →
    /// 恰三段非负整数才合法（`0.23` / `0.23.0.1` / `abc` 均畸形）。后缀判定看
    /// 原串是否含 `-`（`0.23.0-alpha` / `0.23.0-alpha.1` 皆为带后缀形态）。
    private static func parse(_ raw: String) -> Components? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = trimmed
        if body.hasPrefix("v") || body.hasPrefix("V") {
            body.removeFirst()
        }
        let hasSuffix = body.contains("-")
        let numericPart = hasSuffix ? String(body[..<body.firstIndex(of: "-")!]) : body
        let segments = numericPart.split(separator: ".")
        guard segments.count == 3 else { return nil }
        let numbers = segments.map { Int($0) }
        guard numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return (numbers[0]!, numbers[1]!, numbers[2]!, hasSuffix)
    }
}
