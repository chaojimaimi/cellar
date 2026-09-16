import CellarCore
import Foundation

// MARK: - v0.19.20 WP-2 编排执行通道（决策在 daemon，执行在 App——唯一合法
// 快捷指令执行环境，方案 §0 S1/S2：用户会话 `shortcuts run -i` 可用、root 恒失败）

/// Shortcuts 执行抽象（注入缝——StatusController 消费面与 Process 实现解耦；
/// 照 ShortcutsRunning 协议先例命名，方案 §3）。
protocol ShortcutsRunning {
    /// 执行快捷指令：`/usr/bin/shortcuts run -i <百分数临时文件> <name>`。
    /// 抛错 = 执行失败（超时 / 非零退出——stderr 并入错误详情）。
    func run(name: String, percent: Int) async throws
}

/// Process 默认实现：10s 超时 kill；stderr 进错误详情；临时文件即用即删。
/// 阻塞语义（waitUntilExit + 信号量限时）——调用方（StatusController）必须在
/// detached Task 中执行（@MainActor 防主线程卡 10s，runControl 先例）。
struct ShortcutProcessRunner: ShortcutsRunning {
    /// 执行超时（秒；方案 §3 钉死 10s）。
    static let timeoutSeconds: TimeInterval = 10

    enum RunError: Error, CustomStringConvertible {
        /// 超时（进程已 terminate，结果视为失败）。
        case timeout
        /// 非零退出（stderr 合并输出截断后随错误上抛 → 回报 detail → 通用页上屏）。
        case failed(exitCode: Int32, stderr: String)

        var description: String {
            switch self {
            case .timeout:
                return "快捷指令执行超时（\(Int(ShortcutProcessRunner.timeoutSeconds))s）"
            case .failed(let exitCode, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = trimmed.isEmpty ? "无错误输出" : String(trimmed.prefix(300))
                return "快捷指令执行失败（exit \(exitCode)）：\(detail)"
            }
        }
    }

    func run(name: String, percent: Int) async throws {
        try await Task.detached {
            try Self.runBlocking(name: name, percent: percent)
        }.value
    }

    /// 阻塞执行体（detached 上下文；输入文件即用即删——defer 无条件清理）。
    private static func runBlocking(name: String, percent: Int) throws {
        // 输入 = 百分数字符串临时文件（S1 实证 -i 传输入、动态传参生效）。
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-orchestration-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: inputURL) }
        try String(percent).write(to: inputURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", "-i", inputURL.path, name]
        let pipe = Pipe()
        process.standardError = pipe
        // stdout 不消费（执行结果以退出码 + 行为验证为准，S4 无读回通道）。

        try process.run()
        let waiter = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            waiter.signal()
        }
        let outcome = waiter.wait(timeout: .now() + timeoutSeconds)
        if outcome == .timedOut {
            process.terminate()
            throw RunError.timeout
        }
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            throw RunError.failed(
                exitCode: process.terminationStatus,
                stderr: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }
}

// MARK: - 编排偏好（R1 P0-2：快捷指令名不进 daemon policy——daemon 只发 target
// 数字，名字仅 App 执行时消费 → App 侧 UserDefaults；DisplaySettingsController
// 式控制器承载 UI 输入框，执行侧经 static 只读辅助直接读同一键，规避
// App.init 早期访问 @StateObject 临时实例陷阱）

@MainActor
final class OrchestrationSettings: ObservableObject {
    /// 缺省动作名（与 daemon/doctor 探测同源——CellarCore
    /// NativeOrchestration.defaultShortcutName 单一真相，勿双处字面量）。
    nonisolated static let defaultShortcutName = NativeOrchestration.defaultShortcutName
    /// UserDefaults 存储键（执行侧 static 读取同一键）。
    nonisolated static let storageKey = "cellar.orchestration.shortcutName"

    /// 执行时读取（StatusController 消费面——不经实例，规避临时实例陷阱）。
    nonisolated static func currentShortcutName(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: storageKey) ?? defaultShortcutName
    }

    @Published var shortcutName: String

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.shortcutName = defaults.string(forKey: Self.storageKey) ?? Self.defaultShortcutName
    }

    /// 输入框变更回写（实时落盘；空串回缺省名——防止手滑清空后编排空名执行）。
    func updateShortcutName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = trimmed.isEmpty ? Self.defaultShortcutName : trimmed
        shortcutName = target
        defaults.set(target, forKey: Self.storageKey)
    }
}
