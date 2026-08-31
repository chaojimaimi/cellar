import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// daemon 持久化策略（policy.json 的 Codable 形态）。
///
/// ⚠️ 安全面（评审 A-2/P0）：本类型是 60% 硬地板持久化回流的唯一入口——
/// 一切解码/载入路径必须经 `validated` 强校验，禁止绕过它直接构造。
public struct DaemonPolicy: Codable, Equatable, Sendable {
    /// 模式："active"（限充管理中）/ "disabled"（已停用：daemon 运行但不再执行策略，
    /// 控制键已恢复使能态）。语义校验在 `validated`，类型保持 String（JSON 原样承载）。
    public var mode: String
    /// 充电上限（60...100，复用 LimitPolicy 硬地板）。
    public var upperLimit: Int
    /// 滞回幅度（1...20）；恢复阈值 = upperLimit - hysteresis。
    public var hysteresis: Int

    public init(mode: String, upperLimit: Int, hysteresis: Int) {
        self.mode = mode
        self.upperLimit = upperLimit
        self.hysteresis = hysteresis
    }

    public static let `default` = DaemonPolicy(mode: "active", upperLimit: 80, hysteresis: 2)

    /// 校验：mode ∈ {active, disabled}；`try LimitPolicy(upperLimit:hysteresis:)` 成功。
    /// 任何非法（含 upperLimit=30 这类可绕过 60 地板的持久化回流）→ nil（评审 A-2/P0）。
    public static func validated(mode: String, upperLimit: Int, hysteresis: Int) -> DaemonPolicy? {
        guard mode == "active" || mode == "disabled" else { return nil }
        guard (try? LimitPolicy(upperLimit: upperLimit, hysteresis: hysteresis)) != nil else {
            return nil
        }
        return DaemonPolicy(mode: mode, upperLimit: upperLimit, hysteresis: hysteresis)
    }
}

/// 策略持久化（policy.json 原子写 + 校验式读）。
///
/// - 读：文件缺失 / 非 JSON / 解码成功但 `validated == nil` → nil（调用方落默认策略）。
/// - 写：同目录临时文件（0644）+ rename（原子替换）；父目录由安装器保证 root:wheel 0755。
public struct PolicyStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `/Library/Application Support/Cellar/policy.json`（安装器创建父目录）。
    public static var defaultURL: URL {
        URL(fileURLWithPath: "/Library/Application Support/Cellar/policy.json")
    }

    /// 原子读 + 强校验（评审 A-2）：任何非法形态 → nil，绝不回落"半合法"策略。
    public func load() -> DaemonPolicy? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(DaemonPolicy.self, from: data) else {
            return nil
        }
        return DaemonPolicy.validated(
            mode: decoded.mode,
            upperLimit: decoded.upperLimit,
            hysteresis: decoded.hysteresis
        )
    }

    /// 原子写（同目录临时文件 + rename），文件权限 0644。
    /// 父目录缺失等错误原样上抛（安装器保证目录存在；daemon 侧持久化失败仅记日志不阻断）。
    public func save(_ policy: DaemonPolicy) throws {
        try Self.write(policy, to: url)
    }

    /// 实现：编码 → 写临时文件 → chmod 0644 → POSIX rename（原子替换既有文件）。
    /// 临时文件与目标同目录，保证 rename 不跨文件系统。
    private static func write(_ policy: DaemonPolicy, to url: URL) throws {
        let data = try JSONEncoder().encode(policy)
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".policy.json.tmp")
        // 清理：任何失败路径都尽力移除临时文件（不覆盖原错误）。
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try data.write(to: temporaryURL, options: [])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: temporaryURL.path
        )
        #if canImport(Darwin)
        guard rename(temporaryURL.path, url.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        #else
        // 非 Darwin 兜底（本包仅 macOS，此路径仅保持可编译性）：非原子替换。
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
        #endif
    }
}