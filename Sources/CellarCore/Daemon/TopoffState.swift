import Foundation
import os

// MARK: - 0.20.2 §2 TopoffState 诚实性字段持久化（方案 §2；M1b 遗留 R1 重设计）
//
// 动机：daemon 重启 → 诚实性状态丢失——degraded 降级态被「重启洗白」、strikes
// 计数清零（×3 降级防线弱化）、off 关断态丢失。持久化字段**仅五项**（degraded /
// strikes / off / lastViolationAt / lastHealProbeAt）；瞬态字段（lastWrittenLimit /
// lastWriteAt / violationTicks / healProbeActive / activeTarget / healProbeTicks /
// lastReassertAt）一律 fresh 不持久化——首拍幂等重写本身就是停机期间域实况漂移的
// 最便宜对账（R1-P2），保留它、不与持久化对抗。
//
// 加载语义（方案钉死）：policy 装载后、daemon startup() 内合成；degraded=true 跨
// 重启 → 首 tick 走 healTick 降级稳态（**域值 80 物理持久不重写**——「稳态下不重写」
// 不变量保持，healTick 探针照跑 lastHealProbeAt 连续）；off=true 跨重启 → 关断清理
// 幂等守卫兼容（Topoff.shutdownCleanupNeeded）；strikes 跨重启累计 + 载入侧值域
// 钳制；缺失/损坏/越界 → fail-open fresh（域写幂等兜底）。
//
// 写入纪律（方案钉死）：写入点钉在 sub80 门内（daemon 侧——26 不生成状态文件，
// 红线）；主锁内 tmp+rename 直写（topoffState 单写者 = tick 持锁线程）；触发源仅
// strike / 降级跳变 / off 关断（域写不触发——无持久化字段变更，R2-P3），低频。

/// 诚实性五字段持久化形态（topoff-state.json 的 Codable 形态；Date 随 JSONEncoder
/// 默认 = epoch 秒）。
public struct TopoffPersistedState: Codable, Equatable, Sendable {
    /// 降级态（域随写 80 + 编排钳 80 + 每小时自愈重探）。
    public var degraded: Bool
    /// 已耗 strike 数（×3 降级防线跨重启累计；载入侧值域钳制 [0, 3]）。
    public var strikes: Int
    /// 关断清理已执行（sub80State=off 源；通道重新承载即清除）。
    public var off: Bool
    /// 最近违规时刻（24h violationResetWindow 判定输入——持久化后跨重启正确）。
    public var lastViolationAt: Date?
    /// 上次自愈重探时刻（1h 节奏连续；nil → healTick `?? true` 立即首探）。
    public var lastHealProbeAt: Date?

    public init(
        degraded: Bool, strikes: Int, off: Bool,
        lastViolationAt: Date?, lastHealProbeAt: Date?
    ) {
        self.degraded = degraded
        self.strikes = strikes
        self.off = off
        self.lastViolationAt = lastViolationAt
        self.lastHealProbeAt = lastHealProbeAt
    }

    /// 解码后值域钳制（R1-P3 纵深）：`strikes ∈ [0, 3]`，越界置 0（fail-open 方向
    /// ——钳 0 使 ×3 降级防线从头计，绝不因越界值直接跳降级/永久压制）。
    public func clamped() -> TopoffPersistedState {
        var state = self
        if !(0...Topoff.strikeLimit).contains(state.strikes) {
            state.strikes = 0
        }
        return state
    }
}

public extension TopoffChannelState {
    /// 0.20.2 §2：fresh 基底 + 诚实性五字段回填（瞬态字段一律 fresh——首拍幂等
    /// 重写对账停机漂移、healProbe 窗重开、lastReassertAt 冷却重置均无害）。
    init(honestyFrom persisted: TopoffPersistedState) {
        self.init()
        degraded = persisted.degraded
        strikes = persisted.strikes
        off = persisted.off
        lastViolationAt = persisted.lastViolationAt
        lastHealProbeAt = persisted.lastHealProbeAt
    }

    /// 当前诚实性五字段快照（持久化写入形态——仅触发源命中时落盘，低频）。
    var honestySnapshot: TopoffPersistedState {
        TopoffPersistedState(
            degraded: degraded, strikes: strikes, off: off,
            lastViolationAt: lastViolationAt, lastHealProbeAt: lastHealProbeAt
        )
    }
}

public extension Topoff {
    /// 0.20.2 §2 加载合成（纯函数钉面——daemon startup() 消费）：fresh 基底 +
    /// 诚实性五字段回填；nil（缺失/损坏/读取失败 fail-open）→ 恒 fresh。
    static func restoredState(persisted: TopoffPersistedState?) -> TopoffChannelState {
        guard let persisted else { return TopoffChannelState() }
        return TopoffChannelState(honestyFrom: persisted)
    }

    /// 0.20.2 §2 持久化触发判定（纯函数钉面——触发源仅三项，R2-P3）：
    /// strike（strikes 跳变）/ 降级跳变（degraded 跳变，含降级与自愈恢复双向）/
    /// off 关断（off 跳变）。lastViolationAt / lastHealProbeAt 随命中拍的五字段
    /// 快照落盘；**域写（lastWrittenLimit/lastWriteAt）与观察窗簿记
    ///（violationTicks/healProbeActive/activeTarget/lastReassertAt 及两 Date 单独
    /// 变化）不触发**——无持久化字段变更或低价值单字段漂移，不写。
    static func shouldPersistHonestyChange(
        previous: TopoffChannelState, current: TopoffChannelState
    ) -> Bool {
        previous.strikes != current.strikes
            || previous.degraded != current.degraded
            || previous.off != current.off
    }
}

/// topoff 诚实性状态持久化（`/Library/Application Support/Cellar/topoff-state.json`）。
/// 照 ScheduleStateStore 同款独立实现（不共享写路径）：固定名临时文件
/// （.topoff-state.json.tmp——PolicyStore 0.4.1 F-3 纪律；目录 root 属主校验由
/// daemon 启动闸承担）0644 + rename 原子替换；读缺失/损坏 → nil（fail-open fresh，
/// 绝不抛错打断启动）；路径注入缝可测（CellarCoreCheck 临时目录直测）。
public struct TopoffStateStore: Sendable {
    public let url: URL

    /// 路径注入缝（照 ActionStore/ScheduleStateStore 先例——CellarCoreCheck 用临时目录直测）。
    public init(url: URL) {
        self.url = url
    }

    /// `/Library/Application Support/Cellar/topoff-state.json`（安装器创建父目录）。
    public static var defaultURL: URL {
        URL(fileURLWithPath: "/Library/Application Support/Cellar/topoff-state.json")
    }

    /// 容错式读：文件缺失（首启/26 平台——写入点钉在 sub80 门内，从未写过）→
    /// nil 静默；损坏（非 JSON/字段不符）与读取失败 → nil + error 可见化
    /// （fail-open fresh——域写幂等兜底，绝不抛错打断 daemon 启动路径）。
    /// 解码成功经 `clamped()` 值域钳制（R1-P3 纵深）。
    public func load() -> TopoffPersistedState? {
        do {
            let data = try Data(contentsOf: url)
            guard let decoded = try? JSONDecoder().decode(TopoffPersistedState.self, from: data) else {
                Self.log.error("topoff-state.json 损坏（非 JSON 或字段不符），按 fresh 处理（fail-open——域写幂等兜底）")
                return nil
            }
            return decoded.clamped()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil   // 文件不存在：首启/26 平台正常形态（静默）。
        } catch {
            Self.log.error("topoff-state.json 读取失败（\(error)），按 fresh 处理（fail-open——域写幂等兜底）")
            return nil
        }
    }

    /// 原子写（同目录固定名临时文件 + rename），文件权限 0644。错误原样上抛
    /// （调用方 persistLog 可见化，不阻断通道——fail-open）。
    public func save(_ state: TopoffPersistedState) throws {
        let data = try JSONEncoder().encode(state)
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".topoff-state.json.tmp")
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

    /// 日志（struct 静态成员非隔离；Logger Sendable，跨隔离界安全——ScheduleStateStore 同款）。
    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "topoff-state")
}
