import Foundation
import os

// MARK: - Phase 5 v1.4 校准运行时状态（方案 §2.2 StateStore；UD-3 配置/状态分离）

/// 校准运行时状态（calibration-state.json 的 Codable 形态）。与调度配置分离：
/// policy.json 的「非法整包 nil」校验语义不连累状态数据（UD-3）。
public struct CalibrationState: Codable, Equatable, Sendable {
    /// 上次校准终态记录（UD-5 三点口径写入；nil = 无记录——App「尚未校准」占位）。
    public struct LastCalibrationRecord: Codable, Equatable, Sendable {
        /// 启动时刻（epoch 秒；与 `CalibrationState.lastStartedAt` 同源——去重键，
        /// UD-5 第③点）。
        public var startedAt: Int
        /// 终态时刻（epoch 秒）。
        public var endedAt: Int
        /// 终态归一词（CalibrationOutcome rawValue：done/cancel/timeout/safety/
        /// crash-recovery；wire 格式永不本地化）。
        public var outcome: String

        public init(startedAt: Int, endedAt: Int, outcome: String) {
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.outcome = outcome
        }
    }

    /// 启动锚点（epoch 秒；startCalibration 成功路径写入——手动+自动统一刷新
    /// （UD-4：手动校准后周期重新起算）；nil = 从未启动——首次启用调度视为就绪）。
    public var lastStartedAt: Int?
    public var lastCalibration: LastCalibrationRecord?

    public init(lastStartedAt: Int? = nil, lastCalibration: LastCalibrationRecord? = nil) {
        self.lastStartedAt = lastStartedAt
        self.lastCalibration = lastCalibration
    }

    /// 空状态（读失败容错回落形态；nil 锚点即「首次就绪」语义，丢失后果 = 锚点
    /// 重置多发一次校准，低害——非宝贵资产定位，方案 §2.2）。
    public static let empty = CalibrationState()
}

/// 校准状态持久化（`/Library/Application Support/Cellar/calibration-state.json`）。
///
/// - 读：文件缺失 / 非 JSON / 解码失败 → **空状态容错**（非宝贵资产；损坏记
///   os_log error 不静默）；
/// - 写：同目录临时文件（0644）+ rename（原子替换，照 ActionStore OneShot.swift
///   模式——独立实现不共享写路径）；错误原样上抛，daemon 侧仅记日志不阻塞主流程。
public struct CalibrationStateStore: Sendable {
    public let url: URL

    /// 路径注入缝（照 ActionStore 先例——CellarCoreCheck 用临时目录直测）。
    public init(url: URL) {
        self.url = url
    }

    /// `/Library/Application Support/Cellar/calibration-state.json`（安装器创建父目录）。
    public static var defaultURL: URL {
        URL(fileURLWithPath: "/Library/Application Support/Cellar/calibration-state.json")
    }

    /// 容错式读：缺失/损坏/读失败 → 空状态（绝不抛错打断 daemon 启动路径）。
    /// 读失败与「文件不存在」分流入日志（P3-2）：缺失 = 首启正常形态静默回空状态；
    /// 其他读失败（权限等）记 error 可见化——绝不静默。
    public func load() -> CalibrationState {
        do {
            let data = try Data(contentsOf: url)
            guard let decoded = try? JSONDecoder().decode(CalibrationState.self, from: data) else {
                Self.log.error("calibration-state.json 损坏（非 JSON 或字段不符），按空状态处理（锚点重置 = 可能多发一次校准，低害）")
                return .empty
            }
            return decoded
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .empty   // 文件不存在：首启/未写过的正常形态（静默）。
        } catch {
            Self.log.error("calibration-state.json 读取失败（\(error)），按空状态处理（锚点重置 = 可能多发一次校准，低害）")
            return .empty
        }
    }

    /// 原子写（同目录临时文件 + rename），文件权限 0644。
    /// 父目录缺失等错误原样上抛（daemon 侧持久化失败仅记日志不阻塞主流程）。
    public func save(_ state: CalibrationState) throws {
        let data = try JSONEncoder().encode(state)
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".calibration-state.json.tmp")
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

    /// 日志（struct 静态成员非隔离；Logger Sendable，跨隔离界安全——ActionStore 同款）。
    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "calibration-state")
}
