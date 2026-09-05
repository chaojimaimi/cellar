import Foundation
import os

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
    /// WP2' 自动放电开关（nil = 未设置，视为 false；daemon 构造点必须显式携带
    /// 当前值——防「改上限/启停用把开关静默重置」）。合成 Codable 的
    /// decodeIfPresent/encodeIfPresent——旧 policy.json 无本键 → nil 兼容。
    public var autoDischargeEnabled: Bool?
    /// Phase 5 v1.1 风扇策略（nil = 未配置，视为全默认关）。⚠️ **F-1 全构造点
    /// 透传强制条款（R1 P0-2 扩面）**：不止 PolicyStore.load()——daemon 内存重建
    /// 三处（setLimits/disable/enable 的显式构造）都必须携带当前值，走 init 默认
    /// nil 会把用户已配置的风扇设置静默清空并落盘（与 0.4.1 F-1 同型事故）。
    /// 合成 Codable decodeIfPresent——旧 policy.json 无本键 → nil 兼容。
    public var fan: FanPolicy?
    /// Phase 5 v1.4 校准调度策略（nil = 未配置，视为全默认关）。⚠️ **F-1 全构造点
    /// 透传强制条款（v1.4 扩面，与 fan 同守）**：setLimits/disable/enable 三处
    /// 显式构造都必须携带当前值，走 init 默认 nil 会把用户已配置的调度静默清空
    /// 并落盘。合成 Codable decodeIfPresent——旧 policy.json 无本键 → nil 兼容。
    /// 值域非法仅丢字段（PolicyStore.load 校验块）——与 fan 整包 nil 分层不同：
    /// 调度为非关键 opt-in 配置，不连累 mode/限值（CalibrationSchedulePolicy.validated
    /// 注记）。
    public var calibrationSchedule: CalibrationSchedulePolicy?
    /// Phase 5 v1.5 充电热暂停策略（nil = 未配置，视为 .default 40/37）。⚠️ **F-1
    /// 全构造点透传强制条款（v1.5 扩面，与 fan/calibrationSchedule 同守）**：
    /// setLimits/disable/enable 三处显式构造都必须携带当前值，走 init 默认 nil 会
    /// 把用户已配置的热暂停静默清空并落盘（与 0.4.1 F-1 同型事故）。
    /// 合成 Codable decodeIfPresent——旧 policy.json 无本键 → nil 兼容。
    /// 值域非法仅丢字段（PolicyStore.load 校验块）——照 calibrationSchedule 仅丢
    /// 字段分层（UD-3：热暂停为保护配置但 default 40/37 保护仍在，不连累
    /// mode/限值/风扇；勿照 fan 整包 nil）。
    public var thermal: ThermalPolicy?

    public init(
        mode: String, upperLimit: Int, hysteresis: Int,
        autoDischargeEnabled: Bool? = nil, fan: FanPolicy? = nil,
        calibrationSchedule: CalibrationSchedulePolicy? = nil,
        thermal: ThermalPolicy? = nil
    ) {
        self.mode = mode
        self.upperLimit = upperLimit
        self.hysteresis = hysteresis
        self.autoDischargeEnabled = autoDischargeEnabled
        self.fan = fan
        self.calibrationSchedule = calibrationSchedule
        self.thermal = thermal
    }

    public static let `default` = DaemonPolicy(mode: "active", upperLimit: 80, hysteresis: 2)

    /// 校验：mode ∈ {active, disabled}；`try LimitPolicy(upperLimit:hysteresis:)` 成功。
    /// 任何非法（含 upperLimit=30 这类可绕过 60 地板的持久化回流）→ nil（评审 A-2/P0）。
    /// fan 一律透传（F-1：fan 的语义合法由 FanPolicy 自身保证——DaemonPolicy
    /// 不额外校验，nil 与非 nil 都原样携带）。
    public static func validated(
        mode: String, upperLimit: Int, hysteresis: Int,
        autoDischargeEnabled: Bool? = nil, fan: FanPolicy? = nil,
        calibrationSchedule: CalibrationSchedulePolicy? = nil,
        thermal: ThermalPolicy? = nil
    ) -> DaemonPolicy? {
        guard mode == "active" || mode == "disabled" else { return nil }
        guard (try? LimitPolicy(upperLimit: upperLimit, hysteresis: hysteresis)) != nil else {
            return nil
        }
        return DaemonPolicy(
            mode: mode, upperLimit: upperLimit, hysteresis: hysteresis,
            autoDischargeEnabled: autoDischargeEnabled, fan: fan,
            calibrationSchedule: calibrationSchedule, thermal: thermal
        )
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
    /// ⚠️ 0.4.1 安全审计 F-1：autoDischargeEnabled 必须透传 validated——缺失会让
    /// daemon 重启/SIGHUP 后自动放电开关静默复位（持久化回流完整性）。
    /// ⚠️ Phase 5 v1.1 F-1 扩面：`fan` 语义非法（阈值越界等）→ **整包 nil**——
    /// 绝不回落半合法风扇配置（FanGuard 决策建立在越界语义上），与 A-2 同纪律。
    public func load() -> DaemonPolicy? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(DaemonPolicy.self, from: data) else {
            return nil
        }
        let fan: FanPolicy?
        if let decodedFan = decoded.fan {
            guard let validatedFan = FanPolicy.validated(
                enabled: decodedFan.enabled,
                strategy: decodedFan.strategy,
                thresholdCentiC: decodedFan.thresholdCentiC,
                releaseHysteresisCentiC: decodedFan.releaseHysteresisCentiC,
                speedPercent: decodedFan.speedPercent,
                stage2Percent: decodedFan.stage2Percent,
                stage2RiseCentiC: decodedFan.stage2RiseCentiC
            ) else { return nil }
            fan = validatedFan
        } else {
            fan = nil
        }
        // Phase 5 v1.4：校准调度字段校验——**值域非法仅丢该字段**（R1 P1-2 定版，
        // 与 fan 整包 nil 分层不同：调度为非关键 opt-in 配置，不连累 mode/限值/
        // 风扇；Logger error 可见化）。类型错乱（整包 JSONDecoder 解码失败）走上方
        // decoded == nil → 整包 nil 落默认策略（合成 Codable 行为，与 fan 同形）。
        var calibrationSchedule: CalibrationSchedulePolicy?
        if let decodedSchedule = decoded.calibrationSchedule {
            if let validatedSchedule = CalibrationSchedulePolicy.validated(
                enabled: decodedSchedule.enabled,
                intervalDays: decodedSchedule.intervalDays,
                startHour: decodedSchedule.startHour
            ) {
                calibrationSchedule = validatedSchedule
            } else {
                Self.log.error(
                    "policy.json 校准调度字段值域非法（intervalDays 应 1-180 / startHour 应 0-23），仅丢弃该字段（mode/限值/风扇不受连累）"
                )
                calibrationSchedule = nil
            }
        }
        // Phase 5 v1.5：热暂停字段校验——**值域非法仅丢该字段**（UD-3 定版，照
        // calibrationSchedule 仅丢字段分层：回落 default 40/37 保护仍在，不连累
        // mode/限值/风扇；勿照 fan 整包 nil；Logger error 可见化）。类型错乱
        //（整包 JSONDecoder 解码失败）走上方 decoded == nil → 整包 nil 落默认
        // 策略（合成 Codable 行为，与 fan/calibrationSchedule 同形）。
        var thermal: ThermalPolicy?
        if let decodedThermal = decoded.thermal {
            if let validatedThermal = ThermalPolicy.validated(
                pauseCentiC: decodedThermal.pauseCentiC,
                hysteresisCentiC: decodedThermal.hysteresisCentiC
            ) {
                thermal = validatedThermal
            } else {
                Self.log.error(
                    "policy.json 热暂停字段值域非法（pause 应 3500-4500 / hysteresis 应 100-800 厘摄氏度），仅丢弃该字段（mode/限值/风扇不受连累，回落默认 40/37 保护仍在）"
                )
                thermal = nil
            }
        }
        return DaemonPolicy.validated(
            mode: decoded.mode,
            upperLimit: decoded.upperLimit,
            hysteresis: decoded.hysteresis,
            autoDischargeEnabled: decoded.autoDischargeEnabled,
            fan: fan,
            calibrationSchedule: calibrationSchedule,
            thermal: thermal
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

    /// 日志（struct 静态成员非隔离；Logger Sendable，跨隔离界安全——ActionStore 同款）。
    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "policy-store")
}