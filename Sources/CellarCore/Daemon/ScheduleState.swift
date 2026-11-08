import Foundation
import os

// MARK: - Phase 5 v1.6 充电日程运行时状态（方案 §2.2 StateStore；UD-3 配置/状态分离）

/// 充电日程运行时状态（schedule-state.json 的 Codable 形态）。与调度配置分离：
/// policy.json 的「非法整包 nil」校验语义不连累状态数据（UD-3）。
public struct ScheduleState: Codable, Equatable, Sendable {
    /// 当前已应用条目 id（applyEntry 成功后写入；退出恢复成功后清空——转移原子性，
    /// UD-3「状态只在成功之后写」）。nil = 无在窗应用。
    public var lastAppliedEntryId: String?
    /// base 快照：进窗时刻的 policy.upperLimit（R1 P0 定版——退出恢复**快照值**，
    /// 非退出时刻现值；窗口内手动修改 = 临时覆盖，UD-2）。
    public var baseUpperLimit: Int?
    /// base 快照：进窗时刻的 policy.mode（UD-5：base.mode=="disabled" 时恢复后
    /// 仍 disabled——日程不越过总闸）。
    public var baseMode: String?
    /// 最近一次应用时刻（epoch 秒；诊断用途）。
    public var lastAppliedAt: Int?

    public init(
        lastAppliedEntryId: String? = nil, baseUpperLimit: Int? = nil,
        baseMode: String? = nil, lastAppliedAt: Int? = nil
    ) {
        self.lastAppliedEntryId = lastAppliedEntryId
        self.baseUpperLimit = baseUpperLimit
        self.baseMode = baseMode
        self.lastAppliedAt = lastAppliedAt
    }

    /// 空状态（读失败容错回落形态；nil lastApplied 即「无事可复/待补判」语义——
    /// 丢失后果：在窗中途丢失 = base 快照失不可得 → 条目值成为新 base（R-8 已知
    /// 边界，低概率非宝贵资产定位））。
    public static let empty = ScheduleState()
}

/// 充电日程状态持久化（`/Library/Application Support/Cellar/schedule-state.json`）。
/// 照 CalibrationStateStore 同款（独立实现不共享写路径——ActionStore OneShot.swift
/// 模式）：原子写 tmp 0644 + rename、缓存写透由 daemon 侧承担、读失败/损坏回空
/// 绝不抛错、路径注入缝可测。
public struct ScheduleStateStore: Sendable {
    public let url: URL

    /// 路径注入缝（照 ActionStore/CalibrationStateStore 先例——CellarCoreCheck 用临时目录直测）。
    public init(url: URL) {
        self.url = url
    }

    /// `/Library/Application Support/Cellar/schedule-state.json`（安装器创建父目录）。
    public static var defaultURL: URL {
        URL(fileURLWithPath: "/Library/Application Support/Cellar/schedule-state.json")
    }

    /// 容错式读：缺失/损坏/读失败 → 空状态（绝不抛错打断 daemon 启动路径）。
    /// 读失败与「文件不存在」分流入日志（P3-2 同款）：缺失 = 首启正常形态静默回空；
    /// 其他读失败（权限等）记 error 可见化——绝不静默。损坏回空后由日程臂无侧重算
    /// 自愈（UD-3）。
    public func load() -> ScheduleState {
        do {
            let data = try Data(contentsOf: url)
            guard let decoded = try? JSONDecoder().decode(ScheduleState.self, from: data) else {
                Self.log.error("schedule-state.json 损坏（非 JSON 或字段不符），按空状态处理（在窗丢失 = base 快照失不可得，R-8 已知边界）")
                return .empty
            }
            return decoded
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .empty   // 文件不存在：首启/未写过的正常形态（静默）。
        } catch {
            Self.log.error("schedule-state.json 读取失败（\(error)），按空状态处理（R-8 已知边界）")
            return .empty
        }
    }

    /// 原子写（同目录临时文件 + rename），文件权限 0644。
    /// 父目录缺失等错误原样上抛（daemon 侧持久化失败仅记日志不阻塞主流程）。
    public func save(_ state: ScheduleState) throws {
        let data = try JSONEncoder().encode(state)
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".schedule-state.json.tmp")
        // 清理：任何失败路径都尽力移除临时文件（不覆盖原错误）。
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        // 0.23.11 B5-1：O_EXCL 写（CWE-59/61 写操作级纵深——目录权限防线
        // verifyRootOwnedDirectory 为启动/安装时刻一次性判定，此后目录被变更时
        // 本防线独立成立）。O_EXCL|O_CREAT 对已存在路径（含指向不存在目标的
        // symlink）恒 EEXIST——预置符号链接不可跟随；EEXIST = 疑似竞态残留或
        // 上次崩溃残留（普通崩溃残留由 lstat 守卫清除；symlink 残留本次拒写、
        // defer removeItem 清除后下次重写），fail-closed 拒写不跟随。
        // 既有 tmp 仅普通文件（上次崩溃残留）可清——symlink/其他形态不消费，
        // 交给 O_EXCL open 拒写（方案场景：预置 symlink → save throw 且目标
        // 文件未跟随；removeItem 无条件消费 symlink 会洗白竞态现场）。
        var tmpStatus = stat()
        if lstat(temporaryURL.path, &tmpStatus) == 0,
           (tmpStatus.st_mode & S_IFMT) == S_IFREG {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        let fd = open(temporaryURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else {
            throw CocoaError(.fileWriteNoPermission)   // EEXIST/其他——不区分，统一拒写
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw error   // closeOnDealloc 兜底关闭；defer removeItem 清理
        }
        // 显式 chmod（open mode 受 umask 影响——保既有 0644 语义）
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

    /// 日志（struct 静态成员非隔离；Logger Sendable，跨隔离界安全——CalibrationStateStore 同款）。
    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "schedule-state")
}
