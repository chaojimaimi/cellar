import Foundation
import os
import SQLite3

// 采样行值类型（StatsSample + 功率符号推导）见 StatsSample.swift；
// 分桶纯函数（StatsBucketing + StatsBucket + StatsChargingState）见 StatsBucketing.swift。

// MARK: - 存储（actor）

/// 统计采样存储（方案 §2.1）：SQLite WAL 单写者模型，actor 隔离串行化全部
/// 句柄操作——主线程零 SQLite 调用（红线 4）。
///
/// 故障语义（登记：遥测数据非宝贵资产）：损坏（SQLITE_CORRUPT/NOTADB）→ 删
/// 三件套重建一次；非损坏错误（FULL/BUSY 等）→ 跳过本跳不重建。操作路径不向
/// 调用方抛错（错误可见化于日志）——统计故障不挂 App（UD-3：本地文件无遥测）。
///
/// 结构说明：SQLite 句柄操作全部收拢在 `nonisolated static` 助手（句柄作参数），
/// 仅由 actor 方法/构造器调用——SQLite 调用只发生在 actor 执行器（或构造器
/// 所在线程）上，实例状态只有 `handle` 一项。
public actor StatsStore {
    /// Schema 当前版本（迁移序：user_version 0 → 1，v1.3 定版）。
    private static let schemaVersion: Int32 = 1
    /// 保留窗口：原始行 35 天（> 30 天月视图，边界不缺数据——§2.1）。
    public static let retentionInterval: TimeInterval = 35 * 24 * 3600

    /// 默认位置：用户域 `~/Library/Application Support/Cellar/stats.sqlite`
    /// （UD-3，AppSide.swift 用户域先例；**不进** /Library/Cellar——那是 daemon 策略域）。
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cellar/stats.sqlite")
    }

    /// 日志（actor 静态成员非隔离；Logger Sendable，跨隔离界安全——AppSide 同款）。
    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "stats")

    /// 错误（仅 init 路径上抛；操作路径内部消化）。
    public enum StatsError: Error, Equatable {
        /// 打开失败（含目录创建失败——统一归 CANTOPEN）。
        case openFailed(code: Int32)
        /// SQL 执行失败（损坏分类见 isCorruption）。
        case sqlFailed(code: Int32)
        /// 库版本比本构建新（未来版本 schema，绝不盲写——诚实纪律）。
        case schemaTooNew(version: Int32)

        /// 损坏类 = 三件套重建的唯一触发条件（R-8：非损坏错误不重建）。
        /// CORRUPT 判定加扩展码掩码（& 0xFF）——CORRUPT 的派生扩展码
        /// （SQLITE_CORRUPT_VTAB 等）同属损坏，不得漏判；NOTADB 无扩展码族，
        /// 精确比对即可。
        var isCorruption: Bool {
            switch self {
            case .sqlFailed(let code): return code & 0xFF == SQLITE_CORRUPT || code == SQLITE_NOTADB
            case .openFailed, .schemaTooNew: return false
            }
        }
    }

    /// 库文件位置（注入缝：CellarCoreCheck 用临时目录，App 用 defaultURL）。
    public let url: URL
    /// SQLite 连接句柄（nil = 未开）。
    /// ⚠️ nonisolated(unsafe)：deinit（非隔离）需释放连接；读写仅发生在 actor
    /// 方法内（单一持有者，无数据竞争面——PowerSourceMonitor.runLoopSource 同款）。
    private nonisolated(unsafe) var handle: OpaquePointer?

    /// 打开 + 迁移（构造完成即可用）。⚠️ 构造器为同步 nonisolated——SQLite 打开
    /// 阻塞发生在调用方线程；App 侧经 StatsSampler 在后台 actor 上构造（主线程
    /// 零 SQLite 调用，红线 4）。损坏文件 → 三件套重建（一次机会，再失败上抛）。
    public init(url: URL) throws {
        self.url = url
        self.handle = try Self.openWithRecovery(url: url)
    }

    deinit {
        // deinit 持排他访问：直接释放连接（WAL sidecar 交由下次打开处理）。
        if let handle {
            sqlite3_close(handle)
        }
    }

    // MARK: 公开 API（全部非 throws——遥测可弃、App 不挂）

    /// 写入一条采样（INSERT OR REPLACE：同 ts **后写胜出**——时钟回拨 / NTP 跳变 /
    /// 唤醒密集时同秒采样不抛 CONSTRAINT，行为可预期，R1 P2-1）。失败仅记日志。
    /// 顺带异步滚动窗口 prune（保留 35 天，工单 3）。
    public func insert(_ sample: StatsSample) {
        _ = runWithRecovery { db in
            try Self.stepToDone(db, """
            INSERT OR REPLACE INTO samples
              (ts, percent, temp_centi, power_mw, external, charging, cycle,
               max_cap_pct, nominal_mah, design_mah)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            """) { statement in
                // ts 截为整秒（Schema v1 秒级主键；同秒重采样由 OR REPLACE 收敛）。
                sqlite3_bind_int64(statement, 1, Int64(sample.timestamp.timeIntervalSince1970))
                sqlite3_bind_int64(statement, 2, Int64(sample.percent))
                sqlite3_bind_int64(statement, 3, Int64(sample.temperatureCentiC))
                sqlite3_bind_int64(statement, 4, Int64(sample.powerMW))
                sqlite3_bind_int64(statement, 5, sample.externalConnected ? 1 : 0)
                sqlite3_bind_int64(statement, 6, sample.isCharging ? 1 : 0)
                sqlite3_bind_int64(statement, 7, Int64(sample.cycleCount))
                Self.bindOptional(statement, 8, sample.maxCapacityPercent)
                Self.bindOptional(statement, 9, sample.nominalChargeCapacityMAh)
                Self.bindOptional(statement, 10, sample.designCapacityMAh)
            }
        }
        // 滚动窗口（工单 3）：insert 顺带异步 prune——Task 继承 actor 隔离，串行
        // 排在本跳写之后，不阻塞写路径；35 天 > 30 天月视图，边界不缺数据。
        // ⚠️ cutoff 以所写样本 ts 为基准（非当下时刻）：对测试历史时间戳天然
        // no-op（不与断言竞争），生产语义 = 「相对所写数据滚动」而非相对墙钟。
        let cutoff = sample.timestamp.addingTimeInterval(-Self.retentionInterval)
        Task { self.prune(olderThan: cutoff) }
    }

    /// 范围查询 + 分桶（bucketSeconds：24h → 120 / 7d → 1800 / 30d → 7200）。
    /// **聚合不藏 SQL**（R1 P2-3b）：此处只做 range 过滤取原始行，分桶聚合全部
    /// 在 StatsBucketing 纯函数完成。失败返回 []（空态呈现，不挂页）。
    public func query(range: Range<Date>, bucketSeconds: Int) -> [StatsBucket] {
        StatsBucketing.bucket(samples: rawRows(in: range), bucketSeconds: bucketSeconds, range: range)
    }

    /// 删除早于 cutoff 的原始行（滚动窗口；`ts < cutoff` 半开——恰在边界的保留）。
    public func prune(olderThan cutoff: Date) {
        let cutoffSeconds = Int64(cutoff.timeIntervalSince1970)
        _ = runWithRecovery { db in
            try Self.stepToDone(db, "DELETE FROM samples WHERE ts < ?1") { statement in
                sqlite3_bind_int64(statement, 1, cutoffSeconds)
            }
        }
    }

    /// 最新一条采样（页头「记录自 X」+ 最大容量趋势消费；空库 → nil）。
    public func latest() -> StatsSample? {
        runWithRecovery { db in
            try Self.rows(db, """
            SELECT ts, percent, temp_centi, power_mw, external, charging, cycle,
                   max_cap_pct, nominal_mah, design_mah
            FROM samples ORDER BY ts DESC LIMIT 1
            """).first
        } ?? nil
    }

    // MARK: - actor 内调度（损坏恢复 + 错误可见化）

    /// 统一操作包装：损坏 → 删三件套重建后重试一次（R-8）；非损坏错误（FULL/
    /// BUSY 等）→ 不重建，跳过本跳。两路都只记日志——统计故障不上抛不挂 App。
    private func runWithRecovery<T>(_ operation: (OpaquePointer) throws -> T) -> T? {
        do {
            try ensureOpen()
            guard let handle else { return nil }
            return try operation(handle)
        } catch let error as StatsError where error.isCorruption {
            Self.log.error("统计库损坏，删除三件套重建：\(String(describing: error), privacy: .public)")
            // 先关旧句柄再删三件套（开着句柄删除会被存活连接的 checkpoint 复写）。
            // 抛错路径的语句均已 finalize（prepare/stepToDone/rows 的 defer），
            // sqlite3_close 此处安全。
            if let stale = handle {
                sqlite3_close(stale)
            }
            handle = nil
            Self.closeAndDeleteTrio(url: url)
            do {
                handle = try Self.openOnce(url: url)
                return try operation(handle!)
            } catch {
                handle = nil
                Self.log.error("统计库重建后仍失败，放弃本跳：\(String(describing: error), privacy: .public)")
                return nil
            }
        } catch {
            Self.log.error("统计操作失败（非损坏不重建，跳过本跳）：\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 惰性打开（handle 为空时；构造期失败 = 打开即损坏已被 init 的恢复路径处理）。
    private func ensureOpen() throws {
        guard handle == nil else { return }
        handle = try Self.openWithRecovery(url: url)
    }

    // MARK: - SQLite 助手（nonisolated static：句柄作参数，错误分类 StatsError）

    /// 打开 + 损坏恢复：损坏 → 三件套重建一次；重建后再失败原样上抛（磁盘级
    /// 故障非重建可救，不无限重试）。
    private nonisolated static func openWithRecovery(url: URL) throws -> OpaquePointer {
        do {
            return try openOnce(url: url)
        } catch let error as StatsError where error.isCorruption {
            log.error("统计库打开即损坏，重建三件套：\(String(describing: error), privacy: .public)")
            closeAndDeleteTrio(url: url)
            return try openOnce(url: url)
        }
    }

    /// 打开 + PRAGMA + 迁移（单次，无恢复——恢复语义在调用方）。
    private nonisolated static func openOnce(url: URL) throws -> OpaquePointer {
        // 首写建目录（用户域无需特权；AppSide.swift Intermediates 同款先例）。
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw StatsError.openFailed(code: SQLITE_CANTOPEN)
        }
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let db else {
            sqlite3_close(db)   // 失败路径也须释放（SQLite 语义：句柄资源必须回收）
            throw StatsError.openFailed(code: rc)
        }
        do {
            // journal_mode = WAL：读写并发（查询不被写阻塞）；synchronous =
            // NORMAL：遥测数据可容忍断电丢失窗口，性能优先（§2.1）。
            try exec(db, "PRAGMA journal_mode = WAL")
            try exec(db, "PRAGMA synchronous = NORMAL")
            try migrateToV1(db)
            return db
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    /// Schema v1 迁移（user_version 0 → 1）。> 当前版本 = 未来版本库 → 显式报错
    /// （本构建不认识该 schema，绝不盲写——诚实纪律）。
    private nonisolated static func migrateToV1(_ db: OpaquePointer) throws {
        let version = Int32(truncatingIfNeeded: scalar(db, "PRAGMA user_version") ?? 0)
        switch version {
        case 0:
            // Schema v1（§2.1 定版）：power_mw 为推导值（|V|×|I|/1000，符号源
            // isCharging——**禁止裸 V×I**，Amperage 符号未定纪律）；三个容量列可空。
            try exec(db, """
            CREATE TABLE IF NOT EXISTS samples (
              ts INTEGER PRIMARY KEY,
              percent INTEGER NOT NULL,
              temp_centi INTEGER NOT NULL,
              power_mw INTEGER NOT NULL,
              external INTEGER NOT NULL,
              charging INTEGER NOT NULL,
              cycle INTEGER NOT NULL,
              max_cap_pct INTEGER,
              nominal_mah INTEGER,
              design_mah INTEGER
            )
            """)
            try exec(db, "PRAGMA user_version = \(schemaVersion)")
        case schemaVersion:
            break   // 已是当前版本（幂等重开）
        default:
            throw StatsError.schemaTooNew(version: version)
        }
    }

    /// 关句柄 + 删三件套（主库 + `-wal` + `-shm`）。只删主库会残留 sidecar 脏
    /// 文件，重开仍报损坏（R-8）。删除失败吞掉尽力而为（重建路径以重开成败为准）。
    private nonisolated static func closeAndDeleteTrio(url: URL) {
        let basePath = url.path
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: basePath + suffix)
        }
    }

    /// 执行无绑定/无结果 SQL（PRAGMA/DDL）。
    private nonisolated static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let code = sqlite3_errcode(db)
            // 细节入日志（本地日志）；错误载荷仅携 code（不泄路径/内部细节）。
            let detail = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            log.error("SQL 失败（code=\(code)）：\(detail, privacy: .public)")
            throw StatsError.sqlFailed(code: code)
        }
        sqlite3_free(errorMessage)   // 成功路径一般 nil；free(nil) 为安全 no-op
    }

    /// 绑定参数单步执行（INSERT/DELETE，期望 DONE）。
    private nonisolated static func stepToDone(
        _ db: OpaquePointer,
        _ sql: String,
        bind: (OpaquePointer) -> Void
    ) throws {
        let statement = try prepare(db, sql, bind: bind)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StatsError.sqlFailed(code: sqlite3_errcode(db))
        }
    }

    /// 查询多行（SELECT，期望 ROW 循环 + DONE 收尾）。
    private nonisolated static func rows(
        _ db: OpaquePointer,
        _ sql: String,
        bind: (OpaquePointer) -> Void = { _ in }
    ) throws -> [StatsSample] {
        let statement = try prepare(db, sql, bind: bind)
        defer { sqlite3_finalize(statement) }
        var result: [StatsSample] = []
        while true {
            let rc = sqlite3_step(statement)
            guard rc == SQLITE_ROW else {
                // 收尾步骤也须 DONE——损坏等错误不得静默伪装成「空结果」。
                guard rc == SQLITE_DONE else {
                    throw StatsError.sqlFailed(code: sqlite3_errcode(db))
                }
                break
            }
            result.append(readSample(from: statement))
        }
        return result
    }

    /// 单行标量（PRAGMA user_version 等；无行 → nil）。defer 注册在 prepare
    /// 之后、step 之前——step 失败路径同样 finalize，语句句柄零泄漏。
    private nonisolated static func scalar(_ db: OpaquePointer, _ sql: String) -> Int64? {
        guard let statement = try? prepare(db, sql, bind: { _ in }) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    /// 语句准备 + 绑定（prepare 失败抛 sqlFailed——损坏分类见 StatsError）。
    private nonisolated static func prepare(
        _ db: OpaquePointer,
        _ sql: String,
        bind: (OpaquePointer) -> Void
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let code = sqlite3_errcode(db)
            sqlite3_finalize(statement)
            throw StatsError.sqlFailed(code: code)
        }
        bind(statement)
        return statement
    }

    /// 可空整数列绑定（缺席 → NULL，不造 0）。
    private nonisolated static func bindOptional(
        _ statement: OpaquePointer,
        _ index: Int32,
        _ value: Int?
    ) {
        if let value {
            sqlite3_bind_int64(statement, index, Int64(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    /// 行 → 采样（列序与 SELECT 清单一致；可空列 SQLITE_NULL → nil）。
    private nonisolated static func readSample(from statement: OpaquePointer) -> StatsSample {
        func requiredInt(_ index: Int32) -> Int {
            Int(sqlite3_column_int64(statement, index))
        }
        func optionalInt(_ index: Int32) -> Int? {
            sqlite3_column_type(statement, index) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int64(statement, index))
        }
        let seconds = sqlite3_column_int64(statement, 0)
        return StatsSample(
            timestamp: Date(timeIntervalSince1970: TimeInterval(seconds)),
            percent: requiredInt(1),
            temperatureCentiC: requiredInt(2),
            powerMW: requiredInt(3),
            externalConnected: sqlite3_column_int64(statement, 4) != 0,
            isCharging: sqlite3_column_int64(statement, 5) != 0,
            cycleCount: requiredInt(6),
            maxCapacityPercent: optionalInt(7),
            nominalChargeCapacityMAh: optionalInt(8),
            designCapacityMAh: optionalInt(9)
        )
    }

    /// 原始行读取（range 过滤 + ts 升序——桶末样本语义依赖有序输入）。
    private func rawRows(in range: Range<Date>) -> [StatsSample] {
        let start = Int64(range.lowerBound.timeIntervalSince1970)
        let end = Int64(range.upperBound.timeIntervalSince1970)
        return runWithRecovery { db in
            try Self.rows(db, """
            SELECT ts, percent, temp_centi, power_mw, external, charging, cycle,
                   max_cap_pct, nominal_mah, design_mah
            FROM samples WHERE ts >= ?1 AND ts < ?2 ORDER BY ts ASC
            """) { statement in
                sqlite3_bind_int64(statement, 1, start)
                sqlite3_bind_int64(statement, 2, end)
            }
        } ?? []
    }
}
