import Foundation
import os
import SQLite3

// 采样行值类型（StatsSample + 功率符号推导）见 StatsSample.swift；
// 分桶纯函数（StatsBucketing + StatsBucket + StatsChargingState）见 StatsBucketing.swift；
// 趋势纯函数（DailyHealthRollup/StatsTrend/WeeklyBand/CycleProjection）见 StatsTrend.swift。

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
    /// Schema 当前版本（迁移序：user_version 0 → 1 → 2 → 3；0.22.0 §2.2 能耗六列；
    /// 0.23.17 §2.1 daily_health 每日下采样表）。
    private static let schemaVersion: Int32 = 3
    /// 保留窗口：原始行 35 天（> 30 天月视图，边界不缺数据——§2.1）。
    public static let retentionInterval: TimeInterval = 35 * 24 * 3600

    /// 采样行 SELECT 列清单（readSample 列序单一真相——insert/latest/rawRows
    /// 三处共用，防列序漂移；0.22.0 §2.2 尾接能耗六列）。
    private static let sampleColumns = """
    ts, percent, temp_centi, power_mw, external, charging, cycle,
    max_cap_pct, nominal_mah, design_mah,
    acc_load, acc_load_count, acc_discharge, acc_discharge_count,
    daily_min_soc, daily_max_soc
    """

    /// 默认位置：用户域 `~/Library/Application Support/Cellar/stats.sqlite`
    /// （UD-3，AppSide.swift 用户域先例；**不进** /Library/Cellar——那是 daemon 策略域）。
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cellar/stats.sqlite")
    }

    /// daily_health 建表 DDL（§2.1；迁移 v2→v3 与 v0 直建两路共用单源）。
    /// 不做 prune——1 行/天年增 365 行，永久保留即特性本体（调研 A3 约束 3）。
    private static let dailyHealthDDL = """
    CREATE TABLE IF NOT EXISTS daily_health (
      day TEXT PRIMARY KEY,
      cycle_max INTEGER NOT NULL,
      health_centi_pct INTEGER,
      upper_mode INTEGER,
      sample_count INTEGER NOT NULL
    )
    """

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
              (\(Self.sampleColumns))
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
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
                // 能耗六列（0.22.0 §2.2，全可空——快照键缺席 → NULL 不造 0）。
                Self.bindOptional(statement, 11, sample.accSystemLoadMWs)
                Self.bindOptional(statement, 12, sample.accSystemLoadCount)
                Self.bindOptional(statement, 13, sample.accBatteryDischarge)
                Self.bindOptional(statement, 14, sample.accBatteryDischargeCount)
                Self.bindOptional(statement, 15, sample.dailyMinSoc)
                Self.bindOptional(statement, 16, sample.dailyMaxSoc)
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

    /// 能耗差分聚合查询（0.22.0 §2.2）：range 过滤取 ts 升序原始行 →
    /// EnergyAggregation 纯函数（聚合不藏 SQL 同构照 query → StatsBucketing）。
    /// 桶径能耗卡专属（24h→3600s / 7d、30d→86400s，与曲线卡解耦）。失败返回
    /// 空摘要（卡片门控隐藏，不挂页）。
    public func energyBuckets(range: Range<Date>, bucketSeconds: Int) -> EnergySummary {
        EnergyAggregation.aggregate(
            samples: rawRows(in: range), bucketSeconds: bucketSeconds, range: range
        )
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

    /// 最新一条采样（页头「记录自 X」+ 最大容量趋势 + 今日 SOC 区间行消费；空库 → nil）。
    public func latest() -> StatsSample? {
        runWithRecovery { db in
            try Self.rows(db, """
            SELECT \(Self.sampleColumns) FROM samples ORDER BY ts DESC LIMIT 1
            """).first
        } ?? nil
    }

    /// 当日健康行 upsert（0.23.17 §2.2 滚动聚合写入——StatsSampler.tick 每跳顺带
    /// 调用）：SQL 全收 store 内（聚合不藏 SQL，评审 P2 修正）——day 串派生当地
    /// 日界区间（Calendar 派生，禁 86400 乘法）→ 当日范围 SELECT → DailyHealthRollup.
    /// dayRow 纯函数聚合（与回填共用聚合核——口径单源）→ INSERT OR REPLACE。每
    /// tick 全量重算当日行（≤1440 行，代价可忽略）——幂等、自愈、崩溃安全，无
    /// 增量状态机；时钟回拨日重算覆盖，历史行不受影响。失败仅记日志（遥测可弃）。
    public func upsertDailyHealth(day: String, upperHistogram: [Int: Int]) {
        guard let range = Self.localDayRange(day) else {
            Self.log.error("当日健康行 upsert 跳过：日串非法（\(day, privacy: .public)）")
            return
        }
        _ = runWithRecovery { db in
            let samples = try Self.rows(db, """
            SELECT \(Self.sampleColumns)
            FROM samples WHERE ts >= ?1 AND ts < ?2 ORDER BY ts ASC
            """) { statement in
                sqlite3_bind_int64(statement, 1, Int64(range.lowerBound.timeIntervalSince1970))
                sqlite3_bind_int64(statement, 2, Int64(range.upperBound.timeIntervalSince1970))
            }
            // 当日零样本 → 跳过不写（dayRow 空输入防御行不得入库——生产路径
            // 不可达〔upsert 前必有本跳样本〕，仅防御 insert/upsert 间隙的时钟
            // 回拨跨日形态；空日如实无行）。
            guard !samples.isEmpty else { return () }
            try Self.upsertDailyHealthRow(
                db, DailyHealthRollup.dayRow(samples: samples, upperHistogram: upperHistogram)
            )
            return ()
        }
    }

    /// 每日健康行全表读（0.23.17 §2.2 读 API——趋势卡数据源）：day ASC；
    /// `day <= 今天` 过滤未来行（时钟前跳产生的未来日期行不参与，评审 P3 登记）。
    /// actor 内执行（主线程零 SQLite 红线不变）；失败返回 []（空态呈现，不挂页）。
    public func dailyHealth() -> [DailyHealthRow] {
        let today = DailyHealthRollup.dayString(for: Date())
        return runWithRecovery { db in
            try Self.readDailyHealthRows(db, """
            SELECT day, cycle_max, health_centi_pct, upper_mode, sample_count
            FROM daily_health WHERE day <= ?1 ORDER BY day ASC
            """) { statement in
                sqlite3_bind_text(statement, 1, today, -1, Self.sqliteTransient)
            }
        } ?? []
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
            try migrate(db)
            return db
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    /// Schema 迁移（user_version 0 → 1 → 2 → 3，逐步走 case fallthrough——v1
    /// 旧库一次打开直达当前版，每步独立单事务，中途崩溃落在任一步界都重入安全）。
    /// > 当前版本 = 未来版本库 → 显式报错（本构建不认识该 schema，绝不盲写——诚实纪律）。
    private nonisolated static func migrate(_ db: OpaquePointer) throws {
        let version = Int32(truncatingIfNeeded: scalar(db, "PRAGMA user_version") ?? 0)
        switch version {
        case 0:
            // Schema v3 直建（0.23.17 §2.1；v2 基线 + daily_health）：新装用户
            // v0 直达当前版。power_mw 为推导值（|V|×|I|/1000，符号源 isCharging
            // ——**禁止裸 V×I**，Amperage 符号未定纪律）；容量与能耗族全可空。
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
              design_mah INTEGER,
              acc_load INTEGER,
              acc_load_count INTEGER,
              acc_discharge INTEGER,
              acc_discharge_count INTEGER,
              daily_min_soc INTEGER,
              daily_max_soc INTEGER
            )
            """)
            try exec(db, dailyHealthDDL)
            try exec(db, "PRAGMA user_version = \(schemaVersion)")
        case 1:
            // v1 → v2（0.22.0 §2.2）：6 条 ALTER + user_version **包单事务**
            // （BEGIN IMMEDIATE … COMMIT，失败 ROLLBACK）——逐语句隐式提交的
            // 形态在迁移中途崩溃会留「版本 1 + 部分列已加」半态，重跑 duplicate
            // column 非损坏类错误 → init 永抛统计静默死亡（评审 P2-1）。SQLite
            // 中 PRAGMA user_version 赋值事务性生效，单事务后中途崩溃可整体
            // 回滚，重开重入安全。旧行新列 NULL（不参与能耗差分——配对要求
            // 两端非 NULL）。落位 user_version = 2（中间版），fallthrough 续走
            // v2 → v3（0.23.17 起迁移逐步化，两步各自独立事务）。
            try exec(db, "BEGIN IMMEDIATE")
            do {
                for column in ["acc_load", "acc_load_count", "acc_discharge",
                               "acc_discharge_count", "daily_min_soc", "daily_max_soc"] {
                    try exec(db, "ALTER TABLE samples ADD COLUMN \(column) INTEGER")
                }
                try exec(db, "PRAGMA user_version = 2")
                try exec(db, "COMMIT")
            } catch {
                // 尽力回滚（库级故障时 ROLLBACK 本身也可能失败——不掩原错误）。
                try? exec(db, "ROLLBACK")
                throw error
            }
            fallthrough
        case 2:
            // v2 → v3（0.23.17 §2.1）：daily_health 建表 + samples 一次性回填 +
            // user_version **包单事务**（v1→v2 先例形态——中途崩溃 ROLLBACK，
            // 库仍 v2 重开重入安全）。回填 = 迁移内查询 samples 全表现有行
            // （Swift 侧聚合 DailyHealthRollup.backfillRows 纯函数，与滚动写入
            // 共用聚合核——口径单源）→ 批量 INSERT；回填日 upper_mode = NULL
            // （历史无策略上下文，如实）。回填只读 samples 不删不改，最坏情形
            // = 删库重建（既有损坏自愈路径，代价仅历史统计——§8）。
            try exec(db, "BEGIN IMMEDIATE")
            do {
                try exec(db, dailyHealthDDL)
                let samples = try rows(db, "SELECT \(sampleColumns) FROM samples")
                try insertDailyHealthRows(db, DailyHealthRollup.backfillRows(samples: samples))
                try exec(db, "PRAGMA user_version = \(schemaVersion)")
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
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

    /// SQLITE_TRANSIENT（SQLite 令 bind 的 C 串在本步内自拷贝；C 常量 Swift 无
    /// 直接暴露，-1 位型转换即 transient 语义——SQLite.Swift 同款）。
    private nonisolated static var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    /// 日串 → 当地日界区间 [startOfDay, nextDay)（Calendar 派生——DST 日 23/25
    /// 小时由 Calendar 承接，**禁 86400 乘法**，评审 P2 修正）。日串非法 → nil。
    private nonisolated static func localDayRange(_ day: String) -> Range<Date>? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayNumber = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayNumber
        let calendar = Calendar.current
        guard let date = calendar.date(from: components) else { return nil }
        let start = calendar.startOfDay(for: date)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return start..<next
    }

    /// daily_health 批量插入（迁移回填专用——事务内语句单次 prepare，逐行
    /// reset/step；回填行 upper_mode 恒 NULL 由 DailyHealthRollup.backfillRows
    /// 承诺，此处照值绑定不另造）。
    private nonisolated static func insertDailyHealthRows(
        _ db: OpaquePointer, _ rows: [DailyHealthRow]
    ) throws {
        let statement = try prepare(db, """
        INSERT INTO daily_health (day, cycle_max, health_centi_pct, upper_mode, sample_count)
        VALUES (?1, ?2, ?3, ?4, ?5)
        """, bind: { _ in })
        defer { sqlite3_finalize(statement) }
        for row in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, row.day, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 2, Int64(row.cycleMax))
            bindOptional(statement, 3, row.healthCentiPct)
            bindOptional(statement, 4, row.upperMode)
            sqlite3_bind_int64(statement, 5, Int64(row.sampleCount))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw StatsError.sqlFailed(code: sqlite3_errcode(db))
            }
        }
    }

    /// 单行 INSERT OR REPLACE（当日行全量重算覆盖写——幂等自愈语义的存储侧）。
    private nonisolated static func upsertDailyHealthRow(
        _ db: OpaquePointer, _ row: DailyHealthRow
    ) throws {
        try stepToDone(db, """
        INSERT OR REPLACE INTO daily_health (day, cycle_max, health_centi_pct, upper_mode, sample_count)
        VALUES (?1, ?2, ?3, ?4, ?5)
        """) { statement in
            sqlite3_bind_text(statement, 1, row.day, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 2, Int64(row.cycleMax))
            bindOptional(statement, 3, row.healthCentiPct)
            bindOptional(statement, 4, row.upperMode)
            sqlite3_bind_int64(statement, 5, Int64(row.sampleCount))
        }
    }

    /// daily_health 行读取（列序与 SELECT 清单一致；可空列 SQLITE_NULL → nil，
    /// readSample optionalInt 先例；收尾步骤也须 DONE——错误不得静默伪装空结果）。
    private nonisolated static func readDailyHealthRows(
        _ db: OpaquePointer,
        _ sql: String,
        bind: (OpaquePointer) -> Void = { _ in }
    ) throws -> [DailyHealthRow] {
        let statement = try prepare(db, sql, bind: bind)
        defer { sqlite3_finalize(statement) }
        var result: [DailyHealthRow] = []
        while true {
            let rc = sqlite3_step(statement)
            guard rc == SQLITE_ROW else {
                guard rc == SQLITE_DONE else {
                    throw StatsError.sqlFailed(code: sqlite3_errcode(db))
                }
                break
            }
            func optionalInt(_ index: Int32) -> Int? {
                sqlite3_column_type(statement, index) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int64(statement, index))
            }
            result.append(DailyHealthRow(
                day: sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "",
                cycleMax: Int(sqlite3_column_int64(statement, 1)),
                healthCentiPct: optionalInt(2),
                upperMode: optionalInt(3),
                sampleCount: Int(sqlite3_column_int64(statement, 4))
            ))
        }
        return result
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
            designCapacityMAh: optionalInt(9),
            // 能耗六列（0.22.0 §2.2；可空列 SQLITE_NULL → nil，optionalInt 先例）。
            accSystemLoadMWs: optionalInt(10),
            accSystemLoadCount: optionalInt(11),
            accBatteryDischarge: optionalInt(12),
            accBatteryDischargeCount: optionalInt(13),
            dailyMinSoc: optionalInt(14),
            dailyMaxSoc: optionalInt(15)
        )
    }

    /// 原始行读取（range 过滤 + ts 升序——桶末样本语义依赖有序输入）。
    private func rawRows(in range: Range<Date>) -> [StatsSample] {
        let start = Int64(range.lowerBound.timeIntervalSince1970)
        let end = Int64(range.upperBound.timeIntervalSince1970)
        return runWithRecovery { db in
            try Self.rows(db, """
            SELECT \(Self.sampleColumns)
            FROM samples WHERE ts >= ?1 AND ts < ?2 ORDER BY ts ASC
            """) { statement in
                sqlite3_bind_int64(statement, 1, start)
                sqlite3_bind_int64(statement, 2, end)
            }
        } ?? []
    }
}
