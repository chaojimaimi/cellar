#if canImport(Darwin)
import Darwin
#endif
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

    // MARK: - 进程层扫描（WP5 §2.2；层 1 knownIdentifiers 专用）

    /// 进程名 → 层 1 命中（纯函数；CellarCoreCheck 注入名单可测）。
    ///
    /// 与目录条目扫描的两个关键差异（评审 P0-1）：
    /// - **genericKeywords 不用于进程名**：`power` 词根必命中系统必驻进程 powerd，
    ///   每台正常机器都会误报；
    /// - `com.apple.` 前缀豁免不适用：进程名是裸 comm（无 bundle 前缀）。
    /// 空 comm（会话/内核线程残留）过滤；exclude 大小写不敏感（self 排除）。
    public static func classifyProcesses(_ processNames: [String], exclude: Set<String>) -> ConflictScanResult {
        var hits: [String] = []
        for name in processNames {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased()
            guard !exclude.contains(where: { $0.lowercased() == lower }) else { continue }
            if knownIdentifiers.contains(where: { lower.contains($0) }) {
                hits.append(trimmed)
            }
        }
        return ConflictScanResult(exact: Array(Set(hits)).sorted(), generic: [])
    }

    /// 进程扫描（真机枚举；processNames 注入供测试——注入路径输出纯进程名，
    /// 真机路径命中项为「进程名[PID]」展示形态，PID 来自内核快照）。
    /// self（cellar / cellar-daemon）由调用方经 exclude 传入。
    public static func scanProcesses(
        exclude: Set<String>,
        processNames: [String]? = nil
    ) -> ConflictScanResult {
        if let processNames {
            return classifyProcesses(processNames, exclude: exclude)
        }
        var hits: [String] = []
        for entry in enumerateProcesses() {
            let lower = entry.name.lowercased()
            guard !exclude.contains(where: { $0.lowercased() == lower }) else { continue }
            guard knownIdentifiers.contains(where: { lower.contains($0) }) else { continue }
            hits.append("\(entry.name)[\(entry.pid)]")
        }
        return ConflictScanResult(exact: Array(Set(hits)).sorted(), generic: [])
    }

    /// 进程枚举：sysctl(KERN_PROC_ALL) 两次调用取尺寸、循环至稳定（进程数在两次
    /// 调用间会变化——评审 P2-2）；有界 4 轮防病态；用户态可用（KERN_PROC_ALL
    /// 无需 root）。**`p_comm` 截断 ≤ MAXCOMLEN(16)**：`com.battery.helper`（18
    /// 字符）永不匹配进程扫描（已登记取舍——进程层覆盖不到的条目由目录层兜底）。
    /// 僵尸/空 comm 过滤。
    private static func enumerateProcesses() -> [(name: String, pid: Int32)] {
        for _ in 0..<4 {
            var size = 0
            guard sysctlbyname("kern.proc.all", nil, &size, nil, 0) == 0, size > 0 else { return [] }
            let capacity = size / MemoryLayout<kinfo_proc>.stride
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var actualSize = size
            guard sysctlbyname("kern.proc.all", &buffer, &actualSize, nil, 0) == 0 else { return [] }
            let count = actualSize / MemoryLayout<kinfo_proc>.stride
            if count < capacity {
                return parseProcesses(buffer, count: count)
            }
            // 回包恰好占满缓冲：两次调用间进程数可能增长（快照可能截断），重试一轮。
        }
        return []
    }

    private static func parseProcesses(_ buffer: [kinfo_proc], count: Int) -> [(name: String, pid: Int32)] {
        var entries: [(name: String, pid: Int32)] = []
        for process in buffer.prefix(count) {
            // 僵尸进程（SZOMB）无实际执行体，过滤。
            guard Int32(process.kp_proc.p_stat) != SZOMB else { continue }
            let comm = withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard !comm.isEmpty else { continue }
            entries.append((comm, process.kp_proc.p_pid))
        }
        return entries
    }
}