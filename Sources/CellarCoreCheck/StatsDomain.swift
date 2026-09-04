// CellarCoreCheck —— Phase 5 v1.3 统计域场景（方案 §2.3 十二项，独立标签 统计1–12）
//
// 覆盖清单（方案 §2.3 逐项对齐）：
// 统计1  insert→query 往返（单样本字段保真）
// 统计2  bucket 边界（跨桶 / 空桶跳过 / 单点桶 / 边界点归后一桶）
// 统计3  AVG 正确性（AVG / MIN / MAX / NULL 不参与均值）
// 统计4  power 符号推导（amperage=−741 ∧ charging=true → 正值入库；符号只随
//        isCharging 翻转，与 Amperage 自身符号无关——「Amperage 符号未定」纪律）
// 统计5  retention prune（>35 天剔除、边界恰在 cutoff 保留）
// 统计6  损坏重建（写坏文件 + 脏 sidecar → 三件套清理 → 重建成功可往返）
// 统计7  user_version 迁移（0→1；独立原始连接核验 + 幂等重开）
// 统计8  WAL 并发读写（同库双连接读写交错，零丢写）
// 统计9  空库查询（buckets 空 + latest nil）
// 统计10 同 ts OR REPLACE（后写胜出）
// 统计11 最大容量 NULL 容错（单 NULL 桶 nil / 混合桶只平均非 NULL）
// 统计12 chargingState 桶末态折叠（末样本决定 + 乱序防御 + 折叠函数全枚举）
//
// ⚠️ DB 一律临时目录注入（不碰真实用户域 ~/Library/Application Support/Cellar）；
// ⚠️ 场景采样时刻取「当前时刻取整秒」附近——insert 自带的滚动窗口 prune
//（cutoff = 所写样本 ts−35d）对近期时间戳为 no-op，不与断言竞争（retention 场景
// 除外，其断言本就是剔除后状态，显式 prune 保证确定性）。
import CellarCore
import Foundation
import SQLite3

/// 取整后的当前 epoch 秒（全部场景的时间基准——秒级对齐，防亚秒边界 flake）。
private func statsCheckNow() -> Int {
    Int(Date().timeIntervalSince1970)
}

/// 临时目录（每场景独立；defer 清理由调用方负责）。
private func makeStatsTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cellar-stats-check-\(UUID().uuidString)")
    // 创建失败由后续 StatsStore 打开路径兜底（其自带 createDirectory）。
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 采样构造（默认值即 batteryProps 同源口径；测试只覆写关注的字段）。
private func statsSample(
    ts: Int,
    percent: Int = 50,
    tempCenti: Int = 3030,
    powerMW: Int = 0,
    external: Bool = true,
    charging: Bool = false,
    cycle: Int = 153,
    maxCap: Int? = nil,
    nominal: Int? = nil,
    design: Int? = 8694
) -> StatsSample {
    StatsSample(
        timestamp: Date(timeIntervalSince1970: TimeInterval(ts)),
        percent: percent,
        temperatureCentiC: tempCenti,
        powerMW: powerMW,
        externalConnected: external,
        isCharging: charging,
        cycleCount: cycle,
        maxCapacityPercent: maxCap,
        nominalChargeCapacityMAh: nominal,
        designCapacityMAh: design
    )
}

/// 存储构造（init 失败 = 场景失败而非 crash——统计域契约：故障可见化不入异常路径）。
private func makeStatsStore(_ url: URL, scenario: String) -> StatsStore? {
    do {
        return try StatsStore(url: url)
    } catch {
        check(false, scenario, "StatsStore 初始化失败：\(error)")
        return nil
    }
}

/// 统计域场景入口（Main.main 调用；断言经 MainEntry.swift 的 internal 助手）。
func runStatsDomainScenarios() async {
    let now = statsCheckNow()

    // 统计1：insert→query 往返——单样本全字段经库保真（含 ts 整秒截断语义）。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = makeStatsStore(dir.appendingPathComponent("stats.sqlite"), scenario: "统计1") else { return }
        await store.insert(statsSample(ts: now, percent: 86, powerMW: 9048, charging: true))
        let buckets = await store.query(
            range: Date(timeIntervalSince1970: TimeInterval(now - 10))..<Date(timeIntervalSince1970: TimeInterval(now + 10)),
            bucketSeconds: 60
        )
        check(buckets.count == 1, "统计1", "单样本单桶（range 20s < bucket 60s）")
        guard let bucket = buckets.first else { return }
        expectEqual(bucket.sampleCount, 1, "统计1", "sampleCount=1")
        expectEqual(bucket.avgPercent, 86.0, "统计1", "percent 往返保真")
        expectEqual(bucket.minPercent, 86, "统计1", "min=percent（单点）")
        expectEqual(bucket.maxPercent, 86, "统计1", "max=percent（单点）")
        expectEqual(bucket.avgTempCentiC, 3030.0, "统计1", "temp_centi 往返保真")
        expectEqual(bucket.avgPowerMW, 9048.0, "统计1", "power_mw 往返保真")
        check(bucket.chargingState == .charging, "统计1", "chargingState=charging（charging∧external）")
        check(bucket.start == Date(timeIntervalSince1970: TimeInterval(now - 10)), "统计1", "桶界对齐 range 下界")
    }

    // 统计2：bucket 边界——跨桶 / 空桶跳过 / 单点桶 / 边界点归后一桶（半开区间）。
    do {
        let t0 = 1_700_000_000
        let range = Date(timeIntervalSince1970: TimeInterval(t0))..<Date(timeIntervalSince1970: TimeInterval(t0 + 300))
        // 桶 1 [t0,t0+100) 有 1 点；桶 2 [t0+100,t0+200) 空 → 跳过；桶 3 有 1 点（单点桶）。
        let samples = [statsSample(ts: t0 + 10, percent: 50), statsSample(ts: t0 + 290, percent: 52)]
        let buckets = StatsBucketing.bucket(samples: samples, bucketSeconds: 100, range: range)
        check(buckets.count == 2, "统计2", "空桶跳过（3 桶位仅产出 2 桶）")
        check(buckets[0].start == Date(timeIntervalSince1970: TimeInterval(t0)), "统计2", "首桶对齐 range 下界")
        check(buckets[1].start == Date(timeIntervalSince1970: TimeInterval(t0 + 200)), "统计2", "第三桶起点 = t0+200（空桶不占位）")
        check(buckets.allSatisfy { $0.sampleCount == 1 }, "统计2", "两桶皆单点桶")
        // 边界点 ts=t0+100 恰在桶界 → 归后一桶（与 SQL ts >= 下界 AND ts < 上界一致）。
        let boundary = StatsBucketing.bucket(
            samples: [statsSample(ts: t0 + 100, percent: 60)], bucketSeconds: 100, range: range
        )
        check(boundary.count == 1 && boundary[0].start == Date(timeIntervalSince1970: TimeInterval(t0 + 100)),
              "统计2", "边界样本归后一桶")
    }

    // 统计3：AVG 正确性——AVG/MIN/MAX 全对；NULL 不参与平均（也不造 0）。
    do {
        let t0 = 1_700_000_000
        let range = Date(timeIntervalSince1970: TimeInterval(t0))..<Date(timeIntervalSince1970: TimeInterval(t0 + 100))
        let samples = [
            statsSample(ts: t0 + 1, percent: 50, tempCenti: 3000, powerMW: 1000, maxCap: 79),
            statsSample(ts: t0 + 2, percent: 52, tempCenti: 3100, powerMW: 3000, maxCap: 81),
            statsSample(ts: t0 + 3, percent: 51, tempCenti: 3050, powerMW: 2000, maxCap: nil),
        ]
        let buckets = StatsBucketing.bucket(samples: samples, bucketSeconds: 100, range: range)
        guard let bucket = buckets.first else {
            check(false, "统计3", "聚合产出为空")
            return
        }
        expectEqual(bucket.sampleCount, 3, "统计3", "3 样本入桶")
        expectEqual(bucket.avgPercent, 51.0, "统计3", "AVG(percent)=(50+52+51)/3=51")
        expectEqual(bucket.minPercent, 50, "统计3", "MIN=50")
        expectEqual(bucket.maxPercent, 52, "统计3", "MAX=52")
        expectEqual(bucket.avgTempCentiC, 3050.0, "统计3", "AVG(temp)=3050")
        expectEqual(bucket.avgPowerMW, 2000.0, "统计3", "AVG(power)=2000")
        expectEqual(bucket.avgMaxCapacityPercent, 80.0, "统计3", "AVG(maxCap)=79,81 非 NULL 两点均值 80（NULL 不参与）")
    }

    // 统计4：power 符号推导——amperage=−741 ∧ charging=true → 正值入库；
    // 符号只随 isCharging 翻转，与 Amperage 自身符号无关（禁裸 V×I 纪律）。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = makeStatsStore(dir.appendingPathComponent("stats.sqlite"), scenario: "统计4") else { return }
        // fixture 复用 batteryProps()（Amperage=−741 / Voltage=12211 / IsCharging=true）。
        let sample: StatsSample
        do {
            let snapshot = try BatterySnapshotParser.parse(
                batteryProps(), timestamp: Date(timeIntervalSince1970: TimeInterval(now))
            )
            sample = StatsSample(snapshot: snapshot)
        } catch {
            check(false, "统计4", "快照 fixture 解析失败：\(error)")
            return
        }
        expectEqual(sample.powerMW, 9048, "统计4", "|12211|×|−741|/1000=9048，charging=true → 正值")
        check(sample.powerMW > 0, "统计4", "充电方向为正（Amperage 负值不透传符号）")
        // 符号矩阵：四象限恒等——幅值取 |V|×|I|，方向仅由 isCharging 决定。
        expectEqual(StatsSample.powerMilliwatts(voltageMV: 12211, amperageMA: 741, isCharging: true), 9048,
                    "统计4", "charging=true ∧ amperage=+741 仍为 +9048")
        expectEqual(StatsSample.powerMilliwatts(voltageMV: 12211, amperageMA: -741, isCharging: false), -9048,
                    "统计4", "charging=false → 负（放电输出）")
        expectEqual(StatsSample.powerMilliwatts(voltageMV: -12211, amperageMA: 741, isCharging: false), -9048,
                    "统计4", "电压负值取 |V|（幅值恒正）")
        // 入库正号验证：正值经 DB 往返不丢失。
        await store.insert(sample)
        let buckets = await store.query(
            range: Date(timeIntervalSince1970: TimeInterval(now - 10))..<Date(timeIntervalSince1970: TimeInterval(now + 10)),
            bucketSeconds: 60
        )
        check(buckets.first?.avgPowerMW == 9048.0, "统计4", "正值 power_mw 入库往返（avg=9048>0）")
    }

    // 统计5：retention prune——>35 天剔除、边界恰在 cutoff 保留（ts < cutoff 半开）。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = makeStatsStore(dir.appendingPathComponent("stats.sqlite"), scenario: "统计5") else { return }
        let day = 86_400
        await store.insert(statsSample(ts: now - 36 * day, percent: 30))   // 36 天前 → 剔除
        await store.insert(statsSample(ts: now - 35 * day, percent: 40))   // 恰在 cutoff → 保留
        await store.insert(statsSample(ts: now, percent: 86))              // 当下 → 保留
        await store.prune(olderThan: Date(timeIntervalSince1970: TimeInterval(now - 35 * day)))
        let buckets = await store.query(
            range: Date(timeIntervalSince1970: TimeInterval(now - 40 * day))..<Date(timeIntervalSince1970: TimeInterval(now + 60)),
            bucketSeconds: day
        )
        check(buckets.count == 2, "统计5", "36 天前行已剔（3 点剩 2 桶）")
        check(buckets.first?.start == Date(timeIntervalSince1970: TimeInterval(now - 35 * day))
                && buckets.first?.avgPercent == 40.0,
              "统计5", "边界样本（恰 = cutoff）保留")
        check(buckets.last?.start == Date(timeIntervalSince1970: TimeInterval(now))
                && buckets.last?.avgPercent == 86.0,
              "统计5", "当日样本保留")
        check(StatsStore.retentionInterval == 35 * 24 * 3600.0, "统计5", "保留窗常量 = 35 天（>30 天月视图）")
    }

    // 统计6：损坏重建——主库垃圾字节 + 脏 sidecar → 三件套清理 → 重建成功可往返。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stats.sqlite")
        try? Data("this is definitely not a sqlite database ..........".utf8).write(to: url)
        try? Data("junk-wal".utf8).write(to: dir.appendingPathComponent("stats.sqlite-wal"))
        try? Data("junk-shm".utf8).write(to: dir.appendingPathComponent("stats.sqlite-shm"))
        guard let store = makeStatsStore(url, scenario: "统计6") else { return }
        await store.insert(statsSample(ts: now, percent: 86))
        let buckets = await store.query(
            range: Date(timeIntervalSince1970: TimeInterval(now - 10))..<Date(timeIntervalSince1970: TimeInterval(now + 10)),
            bucketSeconds: 60
        )
        check(buckets.count == 1 && buckets.first?.avgPercent == 86.0, "统计6", "重建成功：写读往返恢复")
        guard let again = makeStatsStore(url, scenario: "统计6") else { return }
        let latest = await again.latest()
        check(latest?.percent == 86, "统计6", "二次打开同库健康（重建产物可持续）")
    }

    // 统计7：user_version 迁移 0→1——独立原始连接核验版本号与表存在；重开幂等。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stats.sqlite")
        guard makeStatsStore(url, scenario: "统计7") != nil else { return }
        var raw: OpaquePointer?
        guard sqlite3_open(url.path, &raw) == SQLITE_OK, let raw else {
            check(false, "统计7", "独立核验连接打开失败")
            return
        }
        defer { sqlite3_close(raw) }
        var versionStatement: OpaquePointer?
        var version: Int64 = -1
        if sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK,
           let statement = versionStatement, sqlite3_step(statement) == SQLITE_ROW {
            version = sqlite3_column_int64(statement, 0)
        }
        sqlite3_finalize(versionStatement)
        expectEqual(version, 1, "统计7", "user_version 0→1（独立连接核验）")
        var countStatement: OpaquePointer?
        var rowCount: Int64 = -1
        if sqlite3_prepare_v2(raw, "SELECT COUNT(*) FROM samples", -1, &countStatement, nil) == SQLITE_OK,
           let statement = countStatement, sqlite3_step(statement) == SQLITE_ROW {
            rowCount = sqlite3_column_int64(statement, 0)
        }
        sqlite3_finalize(countStatement)
        expectEqual(rowCount, 0, "统计7", "samples 表已建且为空（迁移即建表）")
        check(makeStatsStore(url, scenario: "统计7") != nil, "统计7", "重开幂等（version=1 不再迁移不报错）")
    }

    // 统计8：WAL 并发读写——同库双连接（写者/读者各持句柄）读写交错，零丢写。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stats.sqlite")
        guard let writer = makeStatsStore(url, scenario: "统计8"),
              let reader = makeStatsStore(url, scenario: "统计8") else { return }
        let queryRange = Date(timeIntervalSince1970: TimeInterval(now - 10))..<Date(timeIntervalSince1970: TimeInterval(now + 60))
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask { await writer.insert(statsSample(ts: now + index, percent: 50 + index % 10)) }
                group.addTask { _ = await reader.query(range: queryRange, bucketSeconds: 3600) }
            }
        }
        let buckets = await reader.query(range: queryRange, bucketSeconds: 3600)
        expectEqual(buckets.reduce(0) { $0 + $1.sampleCount }, 30, "统计8", "WAL 并发交错：写连接 30 条对读连接全量可见（零丢写）")
        let ownLatest = await writer.latest()
        check(ownLatest != nil, "统计8", "写连接自身可读（WAL 双连接互不阻塞）")
    }

    // 统计9：空库查询——buckets 空 + latest nil（空态呈现数据源，不造点）。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = makeStatsStore(dir.appendingPathComponent("stats.sqlite"), scenario: "统计9") else { return }
        let buckets = await store.query(
            range: Date(timeIntervalSince1970: TimeInterval(now - 3600))..<Date(timeIntervalSince1970: TimeInterval(now + 60)),
            bucketSeconds: 60
        )
        check(buckets.isEmpty, "统计9", "空库查询返回空桶序列")
        let latest = await store.latest()
        check(latest == nil, "统计9", "空库 latest 为 nil")
    }

    // 统计10：同 ts OR REPLACE——后写胜出（时钟回拨/同秒重采样行为可预期）。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = makeStatsStore(dir.appendingPathComponent("stats.sqlite"), scenario: "统计10") else { return }
        await store.insert(statsSample(ts: now, percent: 50, charging: false))
        await store.insert(statsSample(ts: now, percent: 60, charging: true))
        let buckets = await store.query(
            range: Date(timeIntervalSince1970: TimeInterval(now - 10))..<Date(timeIntervalSince1970: TimeInterval(now + 10)),
            bucketSeconds: 60
        )
        check(buckets.count == 1, "统计10", "同 ts 收敛为单桶")
        guard let bucket = buckets.first else { return }
        expectEqual(bucket.sampleCount, 1, "统计10", "单行（OR REPLACE 无重复行）")
        expectEqual(bucket.avgPercent, 60.0, "统计10", "后写胜出（60 覆盖 50）")
        check(bucket.chargingState == .charging, "统计10", "胜出行状态字段同步覆盖")
        let latest = await store.latest()
        check(latest?.percent == 60, "统计10", "latest 亦见后写行")
    }

    // 统计11：最大容量 NULL 容错——全 NULL 桶 avg=nil（不造 0）；混合桶只均非 NULL。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = makeStatsStore(dir.appendingPathComponent("stats.sqlite"), scenario: "统计11") else { return }
        await store.insert(statsSample(ts: now, percent: 50, maxCap: nil))       // 桶 A：NULL
        await store.insert(statsSample(ts: now + 1, percent: 51, maxCap: 80))    // 桶 A：80 → 均值 80
        await store.insert(statsSample(ts: now + 3600, percent: 52, maxCap: nil)) // 桶 B：仅 NULL
        let buckets = await store.query(
            range: Date(timeIntervalSince1970: TimeInterval(now - 10))..<Date(timeIntervalSince1970: TimeInterval(now + 4000)),
            bucketSeconds: 60
        )
        check(buckets.count == 2, "统计11", "两点位（now 桶 + now+3600 桶）")
        guard buckets.count == 2 else { return }
        expectEqual(buckets[0].avgMaxCapacityPercent, 80.0, "统计11", "混合桶：仅非 NULL 参与均值（80）")
        check(buckets[1].avgMaxCapacityPercent == nil, "统计11", "全 NULL 桶：avgMaxCapacityPercent=nil（缺席不造数）")
        let latest = await store.latest()
        check(latest?.maxCapacityPercent == nil && latest?.percent == 52, "统计11", "NULL 行 latest 读回不崩")
    }

    // 统计12：chargingState 桶末态折叠——末样本决定 + 乱序防御 + 折叠函数全枚举。
    do {
        let t0 = 1_700_000_000
        let range = Date(timeIntervalSince1970: TimeInterval(t0))..<Date(timeIntervalSince1970: TimeInterval(t0 + 100))
        // 桶内序列 (charging,external)：(T,T) → (F,T)，末样本 (F,T) → .holding。
        let holdTail = [
            statsSample(ts: t0 + 1, charging: true),
            statsSample(ts: t0 + 2, charging: false),
        ]
        let holdBucket = StatsBucketing.bucket(samples: holdTail, bucketSeconds: 100, range: range)
        check(holdBucket.first?.chargingState == .holding, "统计12", "末样本 (charging=F,external=T) → holding")
        // 乱序输入防御：末样本按 ts 判定（后到者胜，非数组末位）。
        let shuffled = [
            statsSample(ts: t0 + 5, charging: false),   // ts 最大 → 末样本
            statsSample(ts: t0 + 2, charging: true),
        ]
        let shuffledBucket = StatsBucketing.bucket(samples: shuffled, bucketSeconds: 100, range: range)
        check(shuffledBucket.first?.chargingState == .holding, "统计12", "乱序输入按 ts 取末样本（非数组序）")
        // 折叠函数全枚举（total function）。
        check(StatsChargingState(charging: true, externalConnected: true) == .charging, "统计12", "折叠：charging∧external→charging")
        check(StatsChargingState(charging: false, externalConnected: true) == .holding, "统计12", "折叠：停充∧external→holding")
        check(StatsChargingState(charging: true, externalConnected: false) == .discharging, "统计12", "折叠：无外接→discharging（异常态如实归放电）")
        check(StatsChargingState(charging: false, externalConnected: false) == .discharging, "统计12", "折叠：无外接∧停充→discharging")
    }
}
