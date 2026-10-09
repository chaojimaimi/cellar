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
// 统计7  user_version 迁移（0→2 直建，0.22.0 Schema v2 起；独立原始连接核验 + 幂等重开）
// 统计8  WAL 并发读写（同库双连接读写交错，零丢写）
// 统计9  空库查询（buckets 空 + latest nil）
// 统计10 同 ts OR REPLACE（后写胜出）
// 统计11 最大容量 NULL 容错（单 NULL 桶 nil / 混合桶只平均非 NULL）
// 统计12 chargingState 桶末态折叠（末样本决定 + 乱序防御 + 折叠函数全枚举）
// 统计13 健康度聚合（nominal/design×100 均值——完整样本入均值，与 maxCap 口径独立）
// 统计14 健康度混合缺席（缺 nominal / 缺 design / design≤0 跳过，只均完整样本）
// 统计15 健康度全缺席桶 nil（纯函数 + DB 往返贯通——缺席机型不造数，R-6）
// 统计39 ChartAxisStride 分档（0.23.4 容量卡横轴步长：三档内值/档界/防御端点九向量）
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
    design: Int? = 8694,
    accLoad: Int? = nil,
    accLoadCount: Int? = nil,
    accDischarge: Int? = nil,
    accDischargeCount: Int? = nil,
    dailyMin: Int? = nil,
    dailyMax: Int? = nil
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
        designCapacityMAh: design,
        accSystemLoadMWs: accLoad,
        accSystemLoadCount: accLoadCount,
        accBatteryDischarge: accDischarge,
        accBatteryDischargeCount: accDischargeCount,
        dailyMinSoc: dailyMin,
        dailyMaxSoc: dailyMax
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

    // 统计7：user_version 迁移（0→2 直建——0.22.0 §2.2 新库全列建表）——独立原始连接核验；重开幂等。
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
        expectEqual(version, 2, "统计7", "user_version 0→2（v2 直建，独立连接核验——新库含能耗六列）")
        var countStatement: OpaquePointer?
        var rowCount: Int64 = -1
        if sqlite3_prepare_v2(raw, "SELECT COUNT(*) FROM samples", -1, &countStatement, nil) == SQLITE_OK,
           let statement = countStatement, sqlite3_step(statement) == SQLITE_ROW {
            rowCount = sqlite3_column_int64(statement, 0)
        }
        sqlite3_finalize(countStatement)
        expectEqual(rowCount, 0, "统计7", "samples 表已建且为空（迁移即建表）")
        check(makeStatsStore(url, scenario: "统计7") != nil, "统计7", "重开幂等（version=2 不再迁移不报错）")
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

    // 统计13：健康度聚合——健康样本（nominal/design 齐备）逐样本折算 % 后取均值。
    // 数值取二进制精确组合（4608/8192=56.25、5632/8192=68.75，均值为 62.5），
    // 断言零浮点容差。与 avgMaxCapacityPercent 口径独立（MaxCapacity 键语义漂移，
    // 走查批 F5 换源——健康度与仪表板「健康」同源 nominal/design）。
    do {
        let t0 = 1_700_000_000
        let range = Date(timeIntervalSince1970: TimeInterval(t0))..<Date(timeIntervalSince1970: TimeInterval(t0 + 100))
        let samples = [
            statsSample(ts: t0 + 1, nominal: 4608, design: 8192),   // 56.25%
            statsSample(ts: t0 + 2, nominal: 5632, design: 8192),   // 68.75%
        ]
        let buckets = StatsBucketing.bucket(samples: samples, bucketSeconds: 100, range: range)
        guard let bucket = buckets.first else {
            check(false, "统计13", "聚合产出为空")
            return
        }
        expectEqual(bucket.avgHealthPercent, 62.5, "统计13", "AVG(health)=(56.25+68.75)/2=62.5（两完整样本）")
        check(bucket.avgMaxCapacityPercent == nil, "统计13", "maxCap 缺席 → avgMaxCapacityPercent=nil（健康度口径独立，互不污染）")
    }

    // 统计14：健康度混合缺席——缺 nominal / 缺 design / design≤0（除零防御，
    // 视同缺席）的样本逐个跳过，只均完整样本（缺席不造数，R-6）。
    do {
        let t0 = 1_700_000_000
        let range = Date(timeIntervalSince1970: TimeInterval(t0))..<Date(timeIntervalSince1970: TimeInterval(t0 + 100))
        let samples = [
            statsSample(ts: t0 + 1, nominal: 4608, design: 8192),   // 56.25%（参与）
            statsSample(ts: t0 + 2, nominal: nil, design: 8192),    // 缺 nominal → 跳过
            statsSample(ts: t0 + 3, nominal: 4608, design: nil),    // 缺 design → 跳过
            statsSample(ts: t0 + 4, nominal: 4608, design: 0),      // design≤0 → 跳过（防除零毒化均值）
        ]
        let buckets = StatsBucketing.bucket(samples: samples, bucketSeconds: 100, range: range)
        guard let bucket = buckets.first else {
            check(false, "统计14", "聚合产出为空")
            return
        }
        expectEqual(bucket.sampleCount, 4, "统计14", "4 样本全入桶（缺席只影响健康度均值，不影响桶产出）")
        expectEqual(bucket.avgHealthPercent, 56.25, "统计14", "仅完整样本参与均值（4608/8192×100=56.25）")
    }

    // 统计15：健康度全缺席桶 → nil（纯函数不造数）+ DB 往返贯通（nominal/design
    // 列随采样入出库，query 聚合出同值——存储胶水层不吞列）。
    do {
        let t0 = 1_700_000_000
        let range = Date(timeIntervalSince1970: TimeInterval(t0))..<Date(timeIntervalSince1970: TimeInterval(t0 + 100))
        let allMissing = [
            statsSample(ts: t0 + 1, nominal: nil, design: nil),
            statsSample(ts: t0 + 2, nominal: nil, design: 8192),
        ]
        let buckets = StatsBucketing.bucket(samples: allMissing, bucketSeconds: 100, range: range)
        check(buckets.first?.avgHealthPercent == nil, "统计15", "全缺席桶 avgHealthPercent=nil（缺席机型不造数）")

        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = makeStatsStore(dir.appendingPathComponent("stats.sqlite"), scenario: "统计15") else { return }
        await store.insert(statsSample(ts: now, nominal: 4608, design: 8192))          // 桶 A：健康样本
        await store.insert(statsSample(ts: now + 1, nominal: 5632, design: 8192))      // 桶 A：健康样本（异秒防 OR REPLACE 覆盖）
        await store.insert(statsSample(ts: now + 3600, nominal: nil, design: nil))     // 桶 B：全缺席
        let stored = await store.query(
            range: Date(timeIntervalSince1970: TimeInterval(now - 10))..<Date(timeIntervalSince1970: TimeInterval(now + 4000)),
            bucketSeconds: 60
        )
        check(stored.count == 2, "统计15", "DB 两点位（now 桶 + now+3600 桶）")
        guard stored.count == 2 else { return }
        expectEqual(stored[0].avgHealthPercent, 62.5, "统计15", "DB 往返：健康列贯通聚合（62.5 与纯函数同值）")
        check(stored[1].avgHealthPercent == nil, "统计15", "DB 全缺席行聚合 nil（NULL 列不入均值）")
    }

    // ---- 0.22.0 能耗统计批（§2.1 parser 新键 / §2.2 Schema v2 / §2.3-§3.1 聚合）----

    // 统计16：parser 累加器四键在场——同字典提取（键名 §11.7/§11.8 实测）。
    do {
        var props = batteryProps()
        props["PowerTelemetryData"] = [
            "SystemPowerIn": 62_767, "SystemLoad": 30_540, "BatteryPower": 32_227,
            "AdapterEfficiencyLoss": 8_000, "SystemVoltageIn": 19_446, "SystemCurrentIn": 3_227,
            "AccumulatedSystemLoad": 294_000_000_000, "SystemLoadAccumulatorCount": 294_369,
            "AccumulatedBatteryDischarge": 55_000_000_000, "BatteryDischargeAccumulatorCount": 55_890,
        ] as [String: Any]
        let telemetry: PowerTelemetry?
        do {
            telemetry = try BatterySnapshotParser.parse(
                props, timestamp: Date(timeIntervalSince1970: TimeInterval(now))).telemetry
        } catch {
            check(false, "统计16", "快照解析失败：\(error)")
            return
        }
        check(telemetry?.accSystemLoadMWs == 294_000_000_000
                && telemetry?.accSystemLoadCount == 294_369
                && telemetry?.accBatteryDischarge == 55_000_000_000
                && telemetry?.accBatteryDischargeCount == 55_890,
              "统计16", "累加器四键全提取（AccumulatedSystemLoad/Count + BatteryDischarge/Count）")
    }

    // 统计17：parser 累加器键缺席 → 该字段 nil（26 红线：键缺席零触及）。
    do {
        var props = batteryProps()
        // PTD 在场但只含既有六键（27.0.1 早期构建/26 机器形态）。
        props["PowerTelemetryData"] = ["SystemPowerIn": 62_767, "SystemLoad": 30_540] as [String: Any]
        let absent: BatterySnapshot?
        do {
            absent = try BatterySnapshotParser.parse(
                props, timestamp: Date(timeIntervalSince1970: TimeInterval(now)))
        } catch {
            check(false, "统计17", "快照解析失败：\(error)")
            return
        }
        check(absent?.telemetry?.accSystemLoadMWs == nil && absent?.telemetry?.accSystemLoadCount == nil
                && absent?.telemetry?.accBatteryDischarge == nil
                && absent?.telemetry?.accBatteryDischargeCount == nil,
              "统计17", "PTD 在场但累加器键缺席 → 四字段全 nil（不造 0）")
        // PTD 整体缺席 → telemetry nil（既有路径零变化）。
        let noPTD: BatterySnapshot?
        do {
            noPTD = try BatterySnapshotParser.parse(
                batteryProps(), timestamp: Date(timeIntervalSince1970: TimeInterval(now)))
        } catch {
            check(false, "统计17", "快照解析失败：\(error)")
            return
        }
        check(noPTD?.telemetry == nil && noPTD?.dailyMinSoc == nil && noPTD?.dailyMaxSoc == nil,
              "统计17", "PTD 整体缺席 → telemetry nil + SOC nil（快照可用性不受影响）")
    }

    // 统计18：parser 累加器键类型不符 → 该字段 nil（字段级容错，其余照提）。
    do {
        var props = batteryProps()
        props["PowerTelemetryData"] = [
            "AccumulatedSystemLoad": "not-a-number", "SystemLoadAccumulatorCount": 294_369,
        ] as [String: Any]
        let snapshot: BatterySnapshot?
        do {
            snapshot = try BatterySnapshotParser.parse(
                props, timestamp: Date(timeIntervalSince1970: TimeInterval(now)))
        } catch {
            check(false, "统计18", "快照解析失败：\(error)")
            return
        }
        check(snapshot?.telemetry?.accSystemLoadMWs == nil
                && snapshot?.telemetry?.accSystemLoadCount == 294_369,
              "统计18", "类型不符 → 该字段 nil、其余字段照提（字段级容错先例）")
    }

    // 统计19：parser SOC Pack 层查找——DailyMinSoc/DailyMaxSoc 位于 Pack 层
    // BatteryData（§11.7 实测）；无 packProperties → nil；顶层 BatteryData 不查。
    do {
        var props = batteryProps()
        props["BatteryData"] = ["CellVoltage": [4072], "FccComp1": 7616,
                                "DailyMinSoc": 25, "DailyMaxSoc": 90] as [String: Any]
        let packLayer: [String: Any] = [
            "Temperature": 3159,
            "BatteryData": ["DailyMinSoc": 25, "DailyMaxSoc": 90] as [String: Any],
        ]
        let snapshot: BatterySnapshot?
        do {
            snapshot = try BatterySnapshotParser.parse(
                props, timestamp: Date(timeIntervalSince1970: TimeInterval(now)), packProperties: packLayer)
        } catch {
            check(false, "统计19", "快照解析失败：\(error)")
            return
        }
        check(snapshot?.dailyMinSoc == 25 && snapshot?.dailyMaxSoc == 90,
              "统计19", "Pack 层 BatteryData DailyMin/MaxSoc 提取（§11.7 实测位置）")
        // packProperties 缺席 → nil（26 红线零触及）。
        let noPack: BatterySnapshot?
        do {
            noPack = try BatterySnapshotParser.parse(
                props, timestamp: Date(timeIntervalSince1970: TimeInterval(now)))
        } catch {
            check(false, "统计19", "快照解析失败：\(error)")
            return
        }
        check(noPack?.dailyMinSoc == nil && noPack?.dailyMaxSoc == nil,
              "统计19", "无 packProperties → SOC 双 nil（顶层 BatteryData 不查——两键实测仅 Pack 层）")
    }

    // 统计20：classifyPair 正常对——系统通道递增 / 放电通道递减同判正常。
    do {
        expectEqual(
            EnergyAggregation.classifyPair(acc0: 100, count0: 10, acc1: 200, count1: 11,
                                           accDecreasingIsNormal: false),
            .normal, "统计20", "系统语义：acc 递增 ∧ 计数不减 → normal")
        expectEqual(
            EnergyAggregation.classifyPair(acc0: 200, count0: 10, acc1: 100, count1: 11,
                                           accDecreasingIsNormal: true),
            .normal, "统计20", "放电语义：acc 递减 ∧ 计数不减 → normal")
    }

    // 统计21：classifyPair 复位对——计数回退优先判（两通道同判）；系统语义
    // acc 下降（计数正常）亦判复位。
    do {
        expectEqual(
            EnergyAggregation.classifyPair(acc0: 100, count0: 10, acc1: 50, count1: 9,
                                           accDecreasingIsNormal: false),
            .reset, "统计21", "计数回退 → reset（独立判据优先，§11.8 活体捕获）")
        expectEqual(
            EnergyAggregation.classifyPair(acc0: 100, count0: 10, acc1: 50, count1: 9,
                                           accDecreasingIsNormal: true),
            .reset, "统计21", "放电通道计数回退 → reset（先复位防护，评审 P1-1）")
        expectEqual(
            EnergyAggregation.classifyPair(acc0: 200, count0: 10, acc1: 100, count1: 11,
                                           accDecreasingIsNormal: false),
            .reset, "统计21", "系统语义 acc 下降（计数正常）→ reset")
    }

    // 统计22：classifyPair NULL 端——任一字段缺席（旧行/键缺席机型）→ nullEnd。
    do {
        expectEqual(
            EnergyAggregation.classifyPair(acc0: nil, count0: 10, acc1: 200, count1: 11,
                                           accDecreasingIsNormal: false),
            .nullEnd, "统计22", "前值 acc 缺席 → nullEnd（基线重建点）")
        expectEqual(
            EnergyAggregation.classifyPair(acc0: 100, count0: nil, acc1: 200, count1: 11,
                                           accDecreasingIsNormal: false),
            .nullEnd, "统计22", "前值 count 缺席 → nullEnd")
        expectEqual(
            EnergyAggregation.classifyPair(acc0: 100, count0: 10, acc1: nil, count1: 11,
                                           accDecreasingIsNormal: true),
            .nullEnd, "统计22", "当前端 acc 缺席 → nullEnd")
    }

    // 统计23：classifyPair 等值——Δacc=0（计数不减）→ equal（零贡献非异常）。
    do {
        expectEqual(
            EnergyAggregation.classifyPair(acc0: 100, count0: 10, acc1: 100, count1: 11,
                                           accDecreasingIsNormal: false),
            .equal, "统计23", "系统语义 Δacc=0 → equal")
        expectEqual(
            EnergyAggregation.classifyPair(acc0: 100, count0: 10, acc1: 100, count1: 11,
                                           accDecreasingIsNormal: true),
            .equal, "统计23", "放电语义 Δacc=0 → equal（零贡献）")
    }

    // 统计24：classifyPair 递增（放电语义专属）——充电窗语义未定谳态。
    do {
        expectEqual(
            EnergyAggregation.classifyPair(acc0: 100, count0: 10, acc1: 200, count1: 11,
                                           accDecreasingIsNormal: true),
            .increasing, "统计24", "放电语义 acc 递增 → increasing（跳过不猜符号）")
    }

    // 统计25：正常差分 + K 数值断言——Δacc=3.6e6 mW·s → 系统 1101 mWh
    //（×1.101/3600）放电 825 mWh（×0.825/3600），双通道独立累计。
    do {
        let t0 = 1_700_000_000
        let range = Date(timeIntervalSince1970: TimeInterval(t0))..<Date(timeIntervalSince1970: TimeInterval(t0 + 120))
        let samples = [
            statsSample(ts: t0 + 1, accLoad: 1_000_000, accLoadCount: 920,
                        accDischarge: 2_000_000, accDischargeCount: 830),
            statsSample(ts: t0 + 61, accLoad: 4_600_000, accLoadCount: 982,
                        accDischarge: -1_600_000, accDischargeCount: 892),
        ]
        let summary = EnergyAggregation.aggregate(samples: samples, bucketSeconds: 3600, range: range)
        expectEqual(summary.resets, 0, "统计25", "正常对零复位")
        expectEqual(summary.dischargeResets, 0, "统计25", "正常对零放电复位")
        expectEqual(summary.unknownDischargeSpans, 0, "统计25", "正常对零未定谳跳过")
        guard let bucket = summary.buckets.first else {
            check(false, "统计25", "聚合产出为空")
            return
        }
        expectEqual(bucket.systemMWh, 1101.0, "统计25", "Δacc 3.6e6 × 1.101 / 3600 = 1101 mWh（K 数值断言）")
        expectEqual(bucket.dischargeMWh, 825.0, "统计25", "|Δacc| 3.6e6 × 0.825 / 3600 = 825 mWh（dischargeK 断言）")
    }

    // 统计26：系统复位对——计数回退 → 剔除该对能量 + resets+1 + 对端基线重建
    //（后续对从新基线继续差分）。
    do {
        let t0 = 1_700_000_000
        let range = Date(timeIntervalSince1970: TimeInterval(t0))..<Date(timeIntervalSince1970: TimeInterval(t0 + 3600))
        let samples = [
            statsSample(ts: t0 + 1, accLoad: 1_000_000, accLoadCount: 1000),
            statsSample(ts: t0 + 2, accLoad: 990_000_000, accLoadCount: 3),   // 复位后首样本
            statsSample(ts: t0 + 3, accLoad: 990_008_600, accLoadCount: 65),  // 新基线起正常对（复位后低基线 + 8600）
        ]
        let summary = EnergyAggregation.aggregate(samples: samples, bucketSeconds: 3600, range: range)
        expectEqual(summary.resets, 1, "统计26", "计数回退对 → resets=1")
        // 复位对能量剔除：仅 8600 mW·s 计入 = 8600×1.101/3600。
        guard let bucket = summary.buckets.first else {
            check(false, "统计26", "聚合产出为空")
            return
        }
        expectEqual(bucket.systemMWh, 8_600.0 * EnergyScale.systemK / 3600,
                    "统计26", "复位对能量剔除 + 新基线正常对 8600 mW·s 计入（基线重建）")
    }

    // 统计27：放电通道计数回退复位——dischargeResets=1，递减能量不误计。
    do {
        let t0 = 1_700_000_000
        let range = Date(timeIntervalSince1970: TimeInterval(t0))..<Date(timeIntervalSince1970: TimeInterval(t0 + 3600))
        let samples = [
            statsSample(ts: t0 + 1, accDischarge: 10_000_000, accDischargeCount: 8300),
            statsSample(ts: t0 + 61, accDischarge: 2_000, accDischargeCount: 50),  // 计数回退
        ]
        let summary = EnergyAggregation.aggregate(samples: samples, bucketSeconds: 3600, range: range)
        expectEqual(summary.dischargeResets, 1, "统计27", "放电计数回退 → dischargeResets=1")
        check(summary.buckets.isEmpty, "统计27", "复位对能量剔除（无正常对 → 空桶）")
    }

    // 统计28：放电 |Δ| 合理性上限——计数单调但 |Δacc| > 对时长×200W 折算 → 亦判
    // 复位；恰在限内正常计入（边界不含）。
    do {
        let t0 = 1_700_000_000
        let range = Date(timeIntervalSince1970: TimeInterval(t0))..<Date(timeIntervalSince1970: TimeInterval(t0 + 3600))
        // 60s 对时长上限 = 60 × 200 × 1000 = 12,000,000 mW·s。
        let overCap = [
            statsSample(ts: t0 + 1, accDischarge: 20_000_000, accDischargeCount: 55_000),
            statsSample(ts: t0 + 61, accDischarge: 7_999_999, accDischargeCount: 55_055),
        ]
        let overSummary = EnergyAggregation.aggregate(samples: overCap, bucketSeconds: 3600, range: range)
        expectEqual(overSummary.dischargeResets, 1, "统计28", "|Δ|=12,000,001 > 60s×200W 折算上限 → 判复位（长间隙兜底）")
        let atCap = [
            statsSample(ts: t0 + 1, accDischarge: 20_000_000, accDischargeCount: 55_000),
            statsSample(ts: t0 + 61, accDischarge: 8_000_000, accDischargeCount: 55_055),
        ]
        let atSummary = EnergyAggregation.aggregate(samples: atCap, bucketSeconds: 3600, range: range)
        expectEqual(atSummary.dischargeResets, 0, "统计28", "|Δ|=12,000,000 恰在限内 → 正常对（边界不含超限）")
        guard let bucket = atSummary.buckets.first else {
            check(false, "统计28", "聚合产出为空")
            return
        }
        expectEqual(bucket.dischargeMWh, 12_000_000.0 * EnergyScale.dischargeK / 3600,
                    "统计28", "限内能量正常计入（2750 mWh）")
    }

    // 统计29：一端 NULL（v1 旧行）——该对不计、作基线重建点，后续对照常差分。
    do {
        let t0 = 1_700_000_000
        let range = Date(timeIntervalSince1970: TimeInterval(t0))..<Date(timeIntervalSince1970: TimeInterval(t0 + 3600))
        let samples = [
            statsSample(ts: t0 + 1),                                          // 旧行（acc 全 nil）
            statsSample(ts: t0 + 2, accLoad: 1_000_000, accLoadCount: 920),   // 基线重建点
            statsSample(ts: t0 + 3, accLoad: 1_086_000, accLoadCount: 999),
        ]
        let summary = EnergyAggregation.aggregate(samples: samples, bucketSeconds: 3600, range: range)
        expectEqual(summary.resets, 0, "统计29", "NULL 端不计复位（缺席 ≠ 复位）")
        guard let bucket = summary.buckets.first else {
            check(false, "统计29", "聚合产出为空")
            return
        }
        expectEqual(bucket.systemMWh, 86_000.0 * EnergyScale.systemK / 3600,
                    "统计29", "NULL 对不计 + 后续对从重建基线差分（86000 mW·s 计入）")
    }

    // 统计30：放电递增跳过（充电窗语义未定谳）——不计负能量、unknownDischargeSpans
    // 如实计数；系统通道同对照常差分（两通道独立）。
    do {
        let t0 = 1_700_000_000
        let range = Date(timeIntervalSince1970: TimeInterval(t0))..<Date(timeIntervalSince1970: TimeInterval(t0 + 3600))
        let samples = [
            statsSample(ts: t0 + 1, accLoad: 1_000_000, accLoadCount: 920,
                        accDischarge: 5_000_000, accDischargeCount: 4100),
            statsSample(ts: t0 + 61, accLoad: 1_086_000, accLoadCount: 982,
                        accDischarge: 5_860_000, accDischargeCount: 4150),   // 充电窗递增
        ]
        let summary = EnergyAggregation.aggregate(samples: samples, bucketSeconds: 3600, range: range)
        expectEqual(summary.unknownDischargeSpans, 1, "统计30", "递增对 → unknownDischargeSpans=1（宁缺毋假）")
        expectEqual(summary.dischargeResets, 0, "统计30", "递增对不计复位（非异常）")
        guard let bucket = summary.buckets.first else {
            check(false, "统计30", "聚合产出为空")
            return
        }
        expectEqual(bucket.dischargeMWh, 0.0, "统计30", "递增对能量跳过（零贡献）")
        expectEqual(bucket.systemMWh, 86_000.0 * EnergyScale.systemK / 3600, "统计30", "系统通道同对照常差分（独立）")
    }

    // 统计31：等值对零贡献——Δacc=0 → 不产桶（空桶跳过）。
    do {
        let t0 = 1_700_000_000
        let range = Date(timeIntervalSince1970: TimeInterval(t0))..<Date(timeIntervalSince1970: TimeInterval(t0 + 3600))
        let samples = [
            statsSample(ts: t0 + 1, accLoad: 1_000_000, accLoadCount: 920),
            statsSample(ts: t0 + 61, accLoad: 1_000_000, accLoadCount: 982),
        ]
        let summary = EnergyAggregation.aggregate(samples: samples, bucketSeconds: 3600, range: range)
        check(summary.buckets.isEmpty, "统计31", "等值对零贡献 → 空桶不产出")
        expectEqual(summary.resets, 0, "统计31", "等值非异常（零复位）")
    }

    // 统计32：间隙对如实计入（UD-5）——2h 断档 Δacc 是固件真实记录能量，计入
    // t1 所在桶（间隙不插值不剔除）。
    do {
        let t0 = 1_700_000_000
        let range = Date(timeIntervalSince1970: TimeInterval(t0))..<Date(timeIntervalSince1970: TimeInterval(t0 + 4 * 3600))
        let samples = [
            statsSample(ts: t0 + 1, accLoad: 1_000_000, accLoadCount: 920),
            statsSample(ts: t0 + 2 * 3600 + 1, accLoad: 3_600_000_000 + 1_000_000, accLoadCount: 6_000),
        ]
        let summary = EnergyAggregation.aggregate(samples: samples, bucketSeconds: 3600, range: range)
        guard let bucket = summary.buckets.first else {
            check(false, "统计32", "聚合产出为空")
            return
        }
        expectEqual(bucket.systemMWh, 3_600_000_000.0 * EnergyScale.systemK / 3600,
                    "统计32", "间隙对 Δacc 如实计入（3.6e9 mW·s = 1101000 mWh）")
        expectEqual(bucket.start, Date(timeIntervalSince1970: TimeInterval(t0 + 2 * 3600)),
                    "统计32", "能量计入 t1 所在桶（间隙后桶，非 t0 桶）")
    }

    // 统计33：防御臂——空输入 / bucketSeconds≤0 / 空 range → 空摘要（不崩）。
    do {
        let t0 = 1_700_000_000
        let range = Date(timeIntervalSince1970: TimeInterval(t0))..<Date(timeIntervalSince1970: TimeInterval(t0 + 3600))
        let empty = EnergyAggregation.aggregate(samples: [], bucketSeconds: 3600, range: range)
        check(empty == EnergySummary(buckets: [], resets: 0, dischargeResets: 0, unknownDischargeSpans: 0),
              "统计33", "空输入 → 空摘要")
        let badBucket = EnergyAggregation.aggregate(
            samples: [statsSample(ts: t0, accLoad: 1, accLoadCount: 1)], bucketSeconds: 0, range: range)
        check(badBucket.buckets.isEmpty, "统计33", "bucketSeconds=0 → 防御空摘要")
        // ⚠️ Swift Range<Date> 构造即 trap（lowerBound > upperBound 非法值）——
        // 空 range 以零跨度表达（t0..<t0），防御臂断言「空 range → 空摘要」。
        let badRange = EnergyAggregation.aggregate(
            samples: [], bucketSeconds: 3600, range: range.lowerBound..<range.lowerBound)
        check(badRange.buckets.isEmpty, "统计33", "空 range（零跨度）→ 防御空摘要")
    }

    // 统计34：桶界归属（StatsBucketing 同构——边界样本归后一桶）+ 多桶升序产出。
    do {
        let t0 = 1_700_000_000
        let range = Date(timeIntervalSince1970: TimeInterval(t0))..<Date(timeIntervalSince1970: TimeInterval(t0 + 7200))
        let samples = [
            statsSample(ts: t0 + 1, accLoad: 0, accLoadCount: 1),
            statsSample(ts: t0 + 3600, accLoad: 3_600_000, accLoadCount: 92),   // 恰在桶界 → 后桶
            statsSample(ts: t0 + 3660, accLoad: 7_560_000, accLoadCount: 98),
        ]
        let summary = EnergyAggregation.aggregate(samples: samples, bucketSeconds: 3600, range: range)
        expectEqual(summary.buckets.count, 1, "统计34", "t0+1→t0+3600 对归后桶 + 后桶内对——单桶（空首桶跳过）")
        guard let bucket = summary.buckets.first else { return }
        expectEqual(bucket.start, Date(timeIntervalSince1970: TimeInterval(t0 + 3600)),
                    "统计34", "桶界样本归后一桶（半开区间语义同 StatsBucketing）")
        expectEqual(bucket.systemMWh, 7_560_000.0 * EnergyScale.systemK / 3600,
                    "统计34", "两对能量同桶累计（3.6e6 + 3.96e6 = 7.56e6 mW·s）")
    }

    // 统计35：Schema v2 新库直建——user_version=2 + 16 列齐备 + 能耗六列读写回环。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stats.sqlite")
        guard let store = makeStatsStore(url, scenario: "统计35") else { return }
        await store.insert(statsSample(ts: now, percent: 86, accLoad: 1_000_000, accLoadCount: 920,
                                       accDischarge: 2_000_000, accDischargeCount: 830,
                                       dailyMin: 25, dailyMax: 90))
        let latest = await store.latest()
        check(latest?.accSystemLoadMWs == 1_000_000 && latest?.accSystemLoadCount == 920
                && latest?.accBatteryDischarge == 2_000_000 && latest?.accBatteryDischargeCount == 830
                && latest?.dailyMinSoc == 25 && latest?.dailyMaxSoc == 90,
              "统计35", "新库直建 v2：能耗六列读写回环保真")
        await StatsV2Helpers.verifySchemaV2(url: url, scenario: "统计35")
    }

    // 统计36：Schema v2 v1 旧库升级——预置 v1 库（含旧行）打开 → user_version=2、
    // 旧行新列 NULL（不参与能耗差分——配对要求两端非 NULL）、新行读写回环。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stats.sqlite")
        StatsV2Helpers.v1LegacyFixture(url: url, oldTs: Int64(now - 3600), percent: 70)
        guard let store = makeStatsStore(url, scenario: "统计36") else { return }
        await StatsV2Helpers.verifySchemaV2(url: url, scenario: "统计36")
        // 旧行新列 NULL（latest 取新写入行；旧行经 query 验证 acc 列读回 nil）。
        await store.insert(statsSample(ts: now, percent: 86, accLoad: 5_000_000, accLoadCount: 4600))
        let rows = await store.query(
            range: Date(timeIntervalSince1970: TimeInterval(now - 7200))..<Date(timeIntervalSince1970: TimeInterval(now + 60)),
            bucketSeconds: 7200
        )
        check(rows.count == 2, "统计36", "升级库查询可用（旧行 + 新行两点位两桶）")
        let raw = StatsV2Helpers.rawQuerySamples(url: url, scenario: "统计36")
        let oldRow = raw.first { $0.timestamp.timeIntervalSince1970 == TimeInterval(now - 3600) }
        let newRow = raw.first { $0.timestamp.timeIntervalSince1970 == TimeInterval(now) }
        check(oldRow?.accSystemLoadMWs == nil && oldRow?.dailyMaxSoc == nil,
              "统计36", "旧行新列 NULL（ALTER 迁移不造数）")
        check(newRow?.accSystemLoadMWs == 5_000_000 && newRow?.accSystemLoadCount == 4600,
              "统计36", "新行能耗列读写回环（升级库立即可写）")
    }

    // 统计37：Schema v2 迁移重入幂等——对已迁移库再开（version=2 不再迁移不报
    // 错）+ 结果态双断言（user_version==2 ∧ 6 列齐备）复验。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stats.sqlite")
        StatsV2Helpers.v1LegacyFixture(url: url, oldTs: Int64(now - 60), percent: 60, scenario: "统计37")
        guard makeStatsStore(url, scenario: "统计37") != nil else { return }
        check(makeStatsStore(url, scenario: "统计37") != nil, "统计37", "已迁移库重开幂等（v1→v2 只走一次）")
        await StatsV2Helpers.verifySchemaV2(url: url, scenario: "统计37")
    }

    // 统计38：StatsStore.energyBuckets 透传（聚合不藏 SQL 同构——DB 原始行 →
    // EnergyAggregation 纯函数，结果与直接聚合一致）。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = makeStatsStore(dir.appendingPathComponent("stats.sqlite"), scenario: "统计38") else { return }
        await store.insert(statsSample(ts: now - 120, accLoad: 1_000_000, accLoadCount: 920))
        await store.insert(statsSample(ts: now - 60, accLoad: 4_600_000, accLoadCount: 982))
        let range = Date(timeIntervalSince1970: TimeInterval(now - 3600))..<Date(timeIntervalSince1970: TimeInterval(now + 60))
        let summary = await store.energyBuckets(range: range, bucketSeconds: 3600)
        let direct = EnergyAggregation.aggregate(
            samples: [
                statsSample(ts: now - 120, accLoad: 1_000_000, accLoadCount: 920),
                statsSample(ts: now - 60, accLoad: 4_600_000, accLoadCount: 982),
            ],
            bucketSeconds: 3600, range: range)
        check(summary == direct, "统计38", "store 透传结果与直接聚合等值（同构管线）")
        guard let bucket = summary.buckets.first else {
            check(false, "统计38", "聚合产出为空")
            return
        }
        expectEqual(bucket.systemMWh, 3_600_000.0 * EnergyScale.systemK / 3600,
                    "统计38", "DB 往返能耗贯通（3.6e6 mW·s → 1101 mWh）")
    }

    // 统计39：ChartAxisStride 分档（0.23.4 容量卡横轴步长）——三档内值 / 档界 /
    // 防御端点九向量钉面（步长单元恒 .day，count 随档 1/2/5；tuple 无 Equatable
    // 一致性，component ∧ count 合取单断言）。
    do {
        let strideCases: [(days: Int, strideCount: Int)] = [
            (5, 1), (18, 2), (30, 5),           // 三档各自内值
            (12, 1), (13, 2), (24, 2), (25, 5), // 档界（<13 / 13...24 / ≥25）
            (0, 1), (35, 5),                    // 防御端点（空数据口径 / 保留窗满）
        ]
        for strideCase in strideCases {
            let stride = ChartAxisStride.capacity(dataSpanDays: strideCase.days)
            check(stride.component == .day && stride.count == strideCase.strideCount,
                  "统计39", "\(strideCase.days) 天跨度 → (.day, \(strideCase.strideCount))")
        }
    }
}

// MARK: - 0.22.0 Schema v2 场景助手（raw sqlite 直构与核验——统计7 独立连接先例）

private enum StatsV2Helpers {
    /// 预置 Schema v1 旧库（统计36/37 fixture）：v1 十列表 + 一行旧行 +
    /// user_version=1（独立原始连接写入后关闭）。
    static func v1LegacyFixture(url: URL, oldTs: Int64, percent: Int, scenario: String = "统计36") {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            check(false, scenario, "v1 fixture 建库失败")
            return
        }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        let create = """
        CREATE TABLE samples (
          ts INTEGER PRIMARY KEY, percent INTEGER NOT NULL, temp_centi INTEGER NOT NULL,
          power_mw INTEGER NOT NULL, external INTEGER NOT NULL, charging INTEGER NOT NULL,
          cycle INTEGER NOT NULL, max_cap_pct INTEGER, nominal_mah INTEGER, design_mah INTEGER
        );
        INSERT INTO samples VALUES (\(oldTs), \(percent), 3030, 0, 1, 0, 153, NULL, NULL, 8694);
        PRAGMA user_version = 1;
        """
        guard sqlite3_exec(db, create, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            check(false, scenario, "v1 fixture 写入失败：\(detail)")
            return
        }
        sqlite3_free(error)
    }

    /// 结果态双断言（复核 P3-3）：user_version==2 ∧ 6 列齐备（独立原始连接核验）。
    static func verifySchemaV2(url: URL, scenario: String) async {
        var raw: OpaquePointer?
        guard sqlite3_open(url.path, &raw) == SQLITE_OK, let raw else {
            check(false, scenario, "独立核验连接打开失败")
            return
        }
        defer { sqlite3_close(raw) }
        var version: Int64 = -1
        var versionStatement: OpaquePointer?
        if sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK,
           let statement = versionStatement, sqlite3_step(statement) == SQLITE_ROW {
            version = sqlite3_column_int64(statement, 0)
        }
        sqlite3_finalize(versionStatement)
        expectEqual(Int(version), 2, scenario, "user_version=2（独立连接核验）")
        var columns: [String] = []
        var tableStatement: OpaquePointer?
        if sqlite3_prepare_v2(raw, "PRAGMA table_info(samples)", -1, &tableStatement, nil) == SQLITE_OK,
           let statement = tableStatement {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let c = sqlite3_column_text(statement, 1) {
                    columns.append(String(cString: c))
                }
            }
        }
        sqlite3_finalize(tableStatement)
        let energyColumns = ["acc_load", "acc_load_count", "acc_discharge",
                             "acc_discharge_count", "daily_min_soc", "daily_max_soc"]
        check(energyColumns.allSatisfy { columns.contains($0) },
              scenario, "能耗六列齐备（table_info 核验：\(columns.count) 列）")
    }

    /// 全行直读（独立连接，绕过 StatsStore——旧行 NULL 列核验用）。
    static func rawQuerySamples(url: URL, scenario: String) -> [StatsSample] {
        var raw: OpaquePointer?
        guard sqlite3_open(url.path, &raw) == SQLITE_OK, let raw else {
            check(false, scenario, "直读连接打开失败")
            return []
        }
        defer { sqlite3_close(raw) }
        var result: [StatsSample] = []
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
                raw, "SELECT ts, percent, acc_load, acc_load_count FROM samples ORDER BY ts ASC",
                -1, &statement, nil) == SQLITE_OK,
              let select = statement else {
            check(false, scenario, "直读语句准备失败")
            return []
        }
        defer { sqlite3_finalize(select) }
        while sqlite3_step(select) == SQLITE_ROW {
            let ts = sqlite3_column_int64(select, 0)
            let percent = Int(sqlite3_column_int64(select, 1))
            let accLoad: Int? = sqlite3_column_type(select, 2) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(select, 2))
            let accLoadCount: Int? = sqlite3_column_type(select, 3) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(select, 3))
            result.append(statsSample(ts: Int(ts), percent: percent,
                                      accLoad: accLoad, accLoadCount: accLoadCount))
        }
        return result
    }
}
