import Foundation

/// 冲突检测（WP5 规格 §0.2 三层模型）：匹配/扫描。
///
/// 只读路径组成部分：不写任何 SMC 键，不做任何系统修改。
/// 两个 SMC 写入者会互相打架，检测他人工具属共存安全所需（业界常规互操作实践）；
/// 检测标识符为互操作必需，请勿按去品牌化原则移除（维护准则见内部笔记）。

/// 扫描结果：层 1 精确标识命中 / 层 2 通用词根命中（条目名，去重排序）。
public struct ConflictScanResult: Equatable, Sendable {
    /// 层 1 精确标识命中（条目名）。
    public let exact: [String]
    /// 层 2 词根命中（条目名）。
    public let generic: [String]

    public init(exact: [String], generic: [String]) {
        self.exact = exact
        self.generic = generic
    }

    public var hasConflict: Bool { !exact.isEmpty || !generic.isEmpty }
}

/// 匹配与扫描（分类为纯函数，可测；scan 为便捷封装）。
public enum ConflictScan {
    /// 已知共存充电管理工具的条目标识（互操作检测白名单；维护准则：仅收录确认会写
    /// 充电控制键的第三方条目，维护记录见内部笔记）。
    ///
    /// 清单：apphousekitchen / aldente-pro / batt.daemon / com.battery.helper /
    /// batterytoolkit / bclm（层 1）。
    public static let knownIdentifiers: [String] = [
        "apphousekitchen",
        "aldente-pro",
        "batt.daemon",
        "com.battery.helper",
        "batterytoolkit",
        "bclm",
    ]

    /// 通用词根（大小写不敏感）：batter / charg / smc / power（层 2）。
    /// `power` 词根最易误报（系统级 power 条目众多），命中在报告 detail 标注"疑似"。
    public static let genericKeywords: [String] = ["batter", "charg", "smc", "power"]

    /// 纯函数：条目名 → 命中分类。
    ///
    /// - `com.apple.` 前缀条目豁免（系统条目，层 3）。
    /// - 大小写不敏感；条目名去重且排序后返回。
    /// - 精确标识优先：命中层 1 的条目不再进入层 2。
    public static func classify(_ entryNames: [String]) -> ConflictScanResult {
        var exactHits: [String] = []
        var genericHits: [String] = []
        for entry in entryNames {
            let lower = entry.lowercased()
            guard !lower.hasPrefix("com.apple.") else { continue }
            if knownIdentifiers.contains(where: { lower.contains($0) }) {
                exactHits.append(entry)
            } else if genericKeywords.contains(where: { lower.contains($0) }) {
                genericHits.append(entry)
            }
        }
        return ConflictScanResult(
            exact: Array(Set(exactHits)).sorted(),
            generic: Array(Set(genericHits)).sorted()
        )
    }

    /// 便捷扫描：列出四个目录的条目名 → classify（层 3 目录范围）。
    /// 目录不存在/不可读按空处理（已登记取舍）；同步调用、不跨隔离域捕获
    /// （FileManager 非 Sendable，登记于规格 §7 风险表）。
    public static func scan(fileManager: FileManager = .default) -> ConflictScanResult {
        var entries: [String] = []
        let homeLaunchAgents = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents").path
        let directories = [
            "/Library/PrivilegedHelperTools",
            "/Library/LaunchDaemons",
            "/Library/LaunchAgents",
            homeLaunchAgents,
        ]
        for directory in directories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            entries.append(contentsOf: names)
        }
        return classify(entries)
    }
}