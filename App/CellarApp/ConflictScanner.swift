import AppKit
import CellarCore
import Foundation

/// 冲突扫描（WP5 §2.2 目录 + 运行进程双源；分类纯函数零改动）。
///
/// 运行进程采集：NSRunningApplication 的 bundleIdentifier 与 executable 名——
/// 只见用户会话 GUI app；root 竞品 daemon、非 bundle 的 launchd 代理不可见，
/// BTM 注册竞品目录扫描也 miss（双盲区登记，规格 §1.5）——由 daemon 侧
/// enforce:verifyFailed 运行时通知兜底（唯一兜底通道）。
enum ConflictScanner {
    /// 自身排除清单（冗余防御：目录扫描不自报、进程名/bundle id 不含词根——
    /// 经核实现无自报路径，保留属防御）。大小写不敏感比对。
    static let excludedIdentifiers: [String] = [
        "com.cellar.app",
        "com.cellar.daemon",
        "cellar",
        "cellar-daemon",
    ]

    /// 运行进程条目采集（bundleIdentifier + executable 名；自身排除）。
    nonisolated static func runningEntryNames() -> [String] {
        var names: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            for name in [app.bundleIdentifier, app.executableURL?.lastPathComponent] {
                guard let name, !name.isEmpty else { continue }
                guard !excludedIdentifiers.contains(where: { $0.lowercased() == name.lowercased() }) else {
                    continue
                }
                names.append(name)
            }
        }
        return names
    }

    /// 双源合并扫描（后台执行，只读、毫秒级——主线程纪律）。
    /// 目录走既有 ConflictScan.scan()、进程条目单独喂 classify 后合并：classify
    /// 逐条分类与整批分类等价（条目独立判定），去重排序语义一致。
    nonisolated static func appScan() async -> ConflictScanResult {
        await Task.detached(priority: .userInitiated) {
            let directory = ConflictScan.scan()
            let process = ConflictScan.classify(runningEntryNames())
            return ConflictScanResult(
                exact: Array(Set(directory.exact + process.exact)).sorted(),
                generic: Array(Set(directory.generic + process.generic)).sorted()
            )
        }.value
    }

    /// 扫描结果 → 门控枚举（§2.2 门控语义）：exact = 硬阻断（红线 3 确认同类
    /// 工具）；generic = 软警示（「疑似」可继续——对疑似硬拒会锁死误报用户）；
    /// 其余 clear。
    static func fold(_ result: ConflictScanResult) -> ConflictGateOutcome {
        if !result.exact.isEmpty { return .exactBlocked }
        if !result.generic.isEmpty { return .genericNeedsConfirm }
        return .clear
    }
}