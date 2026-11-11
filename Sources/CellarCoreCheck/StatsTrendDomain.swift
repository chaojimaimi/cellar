// CellarCoreCheck —— 0.23.17 健康趋势外推批场景域（方案 §4 统计40+；独立文件
// ——「场景域每域一文件」纪律，StatsDomain.swift 已 993 行超 800 硬上限，新场景
// 组落新文件注册 MainEntry.runXxx；断言风格照 StatsDomain 统计39 向量表先例，
// 场景编号接续统计40-59 全局唯一）。
//
// 覆盖清单（方案 §4 逐项对齐）：
// 统计40 v0 直建 v3（daily_health 五列在位 + 空表）
// 统计41 v2→v3 迁移 + 一次性回填（跨多日 fixture 逐行对账 + 旧行零增删）
// 统计42 回填 upper_mode=NULL 如实（历史无策略上下文不造数）
// 统计43 v3 幂等重开（版本不动 + 行集不变）
// 统计44 schemaTooNew 边界（v4 未来库拒开）
// 统计45 dayRow 幂等（同日重算同值 + 输入序无关）
// 统计46 dayRow 众数直方图（并列取小 / 空 nil / 空样本防御行）
// 统计47 weeklyBands 奇偶桶中位数 + 窗界串 + samples 合计
// 统计48 weeklyBands 缺席跳过（窗内 nil 不参与 + 全缺席窗整窗跳过）
// 统计49 weeklyBands 尾窗丢弃 + 单点窗
// 统计50 cycleProjection 正速率向量（30 天 30 循环基准）
// 统计51 cycleProjection 零负速率 nil + 阈值已过 monthsToThreshold nil
// 统计52 cycleProjection 跨度一天 + 同日防御
// 统计53 presentationState 13/14/89/90 × 12/13 全组合边界
// 统计54 跨日数口径（crossDayCount：月界/年界/闰日/同日/非法 nil）
// 统计55 ChartAxisStride 1-400 逐值扫描 ≤15（105-179 洞区间被扫描覆盖）
// 统计56 ChartAxisStride 档界六点（59/60/99/100/179/180）+ 既有档回归
// 统计57 upsert 滚动写入对账 + 重 upsert 幂等
// 统计58 dailyHealth 未来行过滤（时钟前跳行不参与）
// 统计59 localMidnight 本地午夜出口（趋势卡 X 轴消费）
//
// ⚠️ DB 一律临时目录注入（不碰真实用户域）；日界基准走 statsLocalDayStart
// （Calendar 口径——禁 86400 乘法，与聚合核同一本地日语义）。
import CellarCore
import Foundation
import SQLite3

/// 场景域入口（Main.main 调用；断言经 MainEntry.swift 的 internal 助手）。
func runStatsTrendDomainScenarios() async {

    // MARK: 0.23.17 §2.1/§2.3（统计40-59）：schema v3 daily_health + 趋势纯函数

    /// 日行构造（weeklyBands/cycleProjection 向量 fixture——值类型行直构）。
    func healthRow(_ day: String, cycleMax: Int = 100, health: Int?, mode: Int? = nil, count: Int = 1) -> DailyHealthRow {
        DailyHealthRow(day: day, cycleMax: cycleMax, healthCentiPct: health,
                       upperMode: mode, sampleCount: count)
    }

    // 统计40：v0 直建 v3——新装用户直达（user_version=3 + daily_health 五列在位 + 空表）。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stats.sqlite")
        guard makeStatsStore(url, scenario: "统计40") != nil else { return }
        await StatsV2Helpers.verifySchemaV3(url: url, scenario: "统计40")
        let rows = StatsV3Helpers.readDailyHealth(url: url, scenario: "统计40")
        check(rows.isEmpty, "统计40", "v0 直建 daily_health 空表（迁移即建表不造数）")
    }

    // 统计41：v2→v3 迁移 + 一次性回填——跨多日 v2 fixture（16 列 samples）打开后
    // user_version=3，daily_health 逐行对账（cycle max / 健康度厘百分点截断 max /
    // 计数；期望硬编码——与聚合核互为第二双眼睛）。健康度基准：7616×10000/8694
    // = 8760（整数截断）、7612×10000/8694 = 8755；日值取 max → 8760。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stats.sqlite")
        let dayMinus2 = statsLocalDayStart(offsetDays: 2)
        let dayMinus1 = statsLocalDayStart(offsetDays: 1)
        let dayZero = statsLocalDayStart(offsetDays: 0)
        StatsV3Helpers.v2LegacyFixture(url: url, samples: [
            (ts: Int64(dayMinus2 + 3600), cycle: 150, nominal: 7612, design: 8694),
            (ts: Int64(dayMinus2 + 7200), cycle: 151, nominal: 7616, design: 8694),
            (ts: Int64(dayMinus1 + 3600), cycle: 152, nominal: nil, design: 8694),
            (ts: Int64(dayZero + 3600), cycle: 153, nominal: 7100, design: 0),
        ], scenario: "统计41")
        guard let store = makeStatsStore(url, scenario: "统计41") else { return }
        await StatsV2Helpers.verifySchemaV3(url: url, scenario: "统计41")
        let rows = await store.dailyHealth()
        expectEqual(rows.count, 3, "统计41", "三日 fixture → 三行（day ASC）")
        let expected: [(day: String, cycleMax: Int, health: Int?, count: Int)] = [
            (DailyHealthRollup.dayString(for: Date(timeIntervalSince1970: TimeInterval(dayMinus2))), 151, 8760, 2),
            (DailyHealthRollup.dayString(for: Date(timeIntervalSince1970: TimeInterval(dayMinus1))), 152, nil, 1),
            (DailyHealthRollup.dayString(for: Date(timeIntervalSince1970: TimeInterval(dayZero))), 153, nil, 1),
        ]
        for (row, want) in zip(rows, expected) {
            expectEqual(row.day, want.day, "统计41", "日串对账（本地日口径）")
            expectEqual(row.cycleMax, want.cycleMax, "统计41", "cycle max 对账（日内取大）")
            expectEqual(row.healthCentiPct, want.health, "统计41", "健康度厘百分点截断 max 对账（design≤0/缺席不参与）")
            expectEqual(row.sampleCount, want.count, "统计41", "sample_count 对账")
        }
        expectEqual(StatsV3Helpers.readSampleCount(url: url, scenario: "统计41"), 4,
                    "统计41", "回填只读 samples——旧行零增删")
    }

    // 统计42：回填 upper_mode=NULL 如实——历史无策略上下文，health 在位也不造 mode。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stats.sqlite")
        StatsV3Helpers.v2LegacyFixture(url: url, samples: [
            (ts: Int64(statsLocalDayStart(offsetDays: 1) + 3600), cycle: 151, nominal: 7616, design: 8694),
        ], scenario: "统计42")
        guard let store = makeStatsStore(url, scenario: "统计42") else { return }
        let rows = await store.dailyHealth()
        check(rows.count == 1 && rows[0].upperMode == nil && rows[0].healthCentiPct == 8760,
              "统计42", "回填行 upper_mode=NULL（health_centi_pct 8760 在位——mode 缺席如实，不造数）")
    }

    // 统计43：v3 幂等重开——已迁库重开零再迁移（版本不动 + 行集不变）。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stats.sqlite")
        let dayMinus1 = statsLocalDayStart(offsetDays: 1)
        let dayZero = statsLocalDayStart(offsetDays: 0)
        StatsV3Helpers.v2LegacyFixture(url: url, samples: [
            (ts: Int64(dayMinus1 + 3600), cycle: 151, nominal: 7616, design: 8694),
            (ts: Int64(dayZero + 3600), cycle: 152, nominal: nil, design: 8694),
        ], scenario: "统计43")
        guard let first = makeStatsStore(url, scenario: "统计43") else { return }
        let firstRows = await first.dailyHealth()
        expectEqual(firstRows.count, 2, "统计43", "迁移回填两行")
        guard let second = makeStatsStore(url, scenario: "统计43") else { return }
        let secondRows = await second.dailyHealth()
        check(firstRows == secondRows, "统计43", "重开行集逐值相等（回填不重复——幂等重入）")
        var raw: OpaquePointer?
        var version: Int64 = -1
        if sqlite3_open(url.path, &raw) == SQLITE_OK, let raw {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
               let versionStatement = statement, sqlite3_step(versionStatement) == SQLITE_ROW {
                version = sqlite3_column_int64(versionStatement, 0)
            }
            sqlite3_finalize(statement)
            sqlite3_close(raw)
        }
        expectEqual(Int(version), 3, "统计43", "重开后版本仍 3（case 3 落 break 臂）")
    }

    // 统计44：schemaTooNew 边界——未来版本库（v4）拒绝打开（诚实纪律，绝不盲写）。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stats.sqlite")
        StatsV3Helpers.rawExec(url: url, sql: "PRAGMA user_version = 4;", scenario: "统计44")
        do {
            _ = try StatsStore(url: url)
            check(false, "统计44", "v4 库应拒绝打开——但 init 未抛错")
        } catch let error as StatsStore.StatsError {
            check(error == .schemaTooNew(version: 4), "统计44", "v4 → .schemaTooNew(4)（未来 schema 不盲写）")
        } catch {
            check(false, "统计44", "v4 → 抛错类型错误：\(error)")
        }
    }

    // 统计45：dayRow 幂等——同日重算同值（输入序无关——INSERT OR REPLACE 自愈
    // 语义的聚合侧前提）。
    do {
        let dayZero = statsLocalDayStart(offsetDays: 0)
        let samples = [
            statsSample(ts: dayZero + 3600, cycle: 150, nominal: 7612, design: 8694),
            statsSample(ts: dayZero + 7200, cycle: 151, nominal: 7616, design: 8694),
        ]
        let forward = DailyHealthRollup.dayRow(samples: samples, upperHistogram: [80: 2])
        let backward = DailyHealthRollup.dayRow(samples: samples.reversed(), upperHistogram: [80: 2])
        check(forward == backward, "统计45", "同日重算同值（输入序无关）")
        expectEqual(forward.cycleMax, 151, "统计45", "cycle max（日内取大）")
        expectEqual(forward.healthCentiPct, 8760, "统计45", "健康度截断 max（8755/8760 取大）")
        expectEqual(forward.sampleCount, 2, "统计45", "计数")
        expectEqual(forward.day,
                    DailyHealthRollup.dayString(for: Date(timeIntervalSince1970: TimeInterval(dayZero))),
                    "统计45", "日串 = 当地日（dayString 同核投影）")
    }

    // 统计46：dayRow 众数直方图——并列取更小值（确定性钉死，偏保守限值语义）/
    // 单值直取 / 空直方图 nil（失联日如实）/ 空样本防御行（生产不可达）。
    do {
        let dayZero = statsLocalDayStart(offsetDays: 0)
        let one = [statsSample(ts: dayZero + 3600, cycle: 150)]
        let tie = DailyHealthRollup.dayRow(samples: one, upperHistogram: [80: 3, 75: 3])
        expectEqual(tie.upperMode, 75, "统计46", "众数并列取更小值（80:3 vs 75:3 → 75）")
        expectEqual(DailyHealthRollup.dayRow(samples: one, upperHistogram: [80: 1]).upperMode, 80,
                    "统计46", "单值直取")
        check(DailyHealthRollup.dayRow(samples: one, upperHistogram: [:]).upperMode == nil,
              "统计46", "空直方图 → upper_mode nil（daemon 失联日如实）")
        let defensive = DailyHealthRollup.dayRow(samples: [], upperHistogram: [80: 1])
        check(defensive.day.isEmpty && defensive.sampleCount == 0 && defensive.cycleMax == 0,
              "统计46", "空样本防御行（upsert 前必有本跳样本入库——生产不可达路径）")
    }

    // 统计47：weeklyBands 奇偶桶中位数 + 窗界串（锚首日 7 天顺序窗）+ samples 合计。
    do {
        let bands = StatsTrend.weeklyBands(daily: [
            healthRow("2026-01-01", health: 8750, count: 3),
            healthRow("2026-01-04", health: 8770),
            healthRow("2026-01-07", health: 8760),
            healthRow("2026-01-08", health: 8750),
            healthRow("2026-01-14", health: 8770, count: 2),
        ])
        expectEqual(bands.count, 2, "统计47", "跨 14 天 → 两完整窗（窗满才出）")
        expectEqual(bands[0].startDay, "2026-01-01", "统计47", "窗锚 = 首日（不追自然周）")
        expectEqual(bands[0].endDay, "2026-01-07", "统计47", "窗界 = start+6（含端 7 天）")
        expectEqual(bands[0].median, 8760.0, "统计47", "奇数桶中值（8750/8770/8760 → 8760）")
        expectEqual(bands[0].min, 8750, "统计47", "窗内 min")
        expectEqual(bands[0].max, 8770, "统计47", "窗内 max")
        expectEqual(bands[0].samples, 5, "统计47", "samples = sample_count 合计（3+1+1）")
        expectEqual(bands[1].startDay, "2026-01-08", "统计47", "第二窗锚 = 首日+7")
        expectEqual(bands[1].median, 8760.0, "统计47", "偶数桶两中值均值（(8750+8770)/2 = 8760）")
    }

    // 统计48：weeklyBands 缺席跳过——窗内 health 缺席行不参与（只均非空集）+
    // 全缺席窗整窗跳过（断档如实）。
    do {
        let bands = StatsTrend.weeklyBands(daily: [
            healthRow("2026-01-01", health: 8750),
            healthRow("2026-01-03", health: nil),
            healthRow("2026-01-10", health: nil),   // 落窗 1（01-08..01-14）
            healthRow("2026-01-15", health: 8760),  // 落窗 2 → 尾窗丢弃
        ])
        expectEqual(bands.count, 1, "统计48", "全缺席窗跳过 + 尾窗丢弃 → 单带（跨 15 天完整窗 2 个）")
        expectEqual(bands[0].startDay, "2026-01-01", "统计48", "产出带 = 窗 0")
        expectEqual(bands[0].median, 8750.0, "统计48", "窗内缺席行不参与中位数（8750 单值）")
        expectEqual(bands[0].samples, 2, "统计48", "samples 计缺席行样本（1+1——数据质量指示含缺席）")
    }

    // 统计49：weeklyBands 尾窗丢弃 + 单点窗——跨 8 天完整窗仅 1 个（第 8 天整窗
    // 丢弃）；单行完整窗 median=min=max 单值。
    do {
        let tail = StatsTrend.weeklyBands(daily: [
            healthRow("2026-01-01", health: 8750),
            healthRow("2026-01-08", health: 8760),   // 窗 1（01-08..01-14）不满 7 天窗龄
        ])
        expectEqual(tail.count, 1, "统计49", "尾窗不满 7 天整窗丢弃（窗满才出——评审 P2 修正）")
        expectEqual(tail[0].endDay, "2026-01-07", "统计49", "产出带止于窗 0")
        let single = StatsTrend.weeklyBands(daily: [
            healthRow("2026-01-01", cycleMax: 900, health: 8755),
            healthRow("2026-01-08", health: 8760),   // 尾窗丢弃
        ])
        expectEqual(single[0].median, 8755.0, "统计49", "单点窗中位数 = 单值")
        check(single[0].min == 8755 && single[0].max == 8755, "统计49", "单点窗 min=max=单值（带宽零）")
    }

    // 统计50：cycleProjection 正速率向量——30 天 30 循环基准（rate/day=1.0），
    // months = (1000−900)/1/30.44。
    do {
        let projection = StatsTrend.cycleProjection(
            first: healthRow("2026-01-01", cycleMax: 870, health: 8750),
            last: healthRow("2026-01-31", cycleMax: 900, health: 8740)
        )
        guard let projection else {
            check(false, "统计50", "正速率应产出投影")
            return
        }
        expectEqual(projection.cyclesPerMonth, 30.44, "统计50", "速率 = Δcycle/跨日 × 30.44（1.0×30.44）")
        expectEqual(projection.monthsToThreshold, 100.0 / 30.44, "统计50", "月数 =（阈值−末cycle）/速率/30.44")
    }

    // 统计51：cycleProjection 零/负速率 nil（不外推如实）+ 阈值已过 monthsToThreshold
    // nil（投影仍在——速率可呈，呈现层退化句承接）。
    do {
        check(StatsTrend.cycleProjection(
            first: healthRow("2026-01-01", cycleMax: 870, health: nil),
            last: healthRow("2026-01-31", cycleMax: 870, health: nil)) == nil,
              "统计51", "零速率 → nil（平台期无到达语义）")
        check(StatsTrend.cycleProjection(
            first: healthRow("2026-01-01", cycleMax: 900, health: nil),
            last: healthRow("2026-01-31", cycleMax: 870, health: nil)) == nil,
              "统计51", "负速率 → nil（换电池/计数器回退不外推）")
        let passed = StatsTrend.cycleProjection(
            first: healthRow("2026-01-01", cycleMax: 900, health: nil),
            last: healthRow("2026-01-31", cycleMax: 1000, health: nil)
        )
        check(passed?.monthsToThreshold == nil && passed != nil,
              "统计51", "阈值恰已过（last==threshold）→ monthsToThreshold nil")
        let beyond = StatsTrend.cycleProjection(
            first: healthRow("2026-01-01", cycleMax: 900, health: nil),
            last: healthRow("2026-01-31", cycleMax: 1010, health: nil)
        )
        check(beyond?.monthsToThreshold == nil && beyond != nil,
              "统计51", "阈值越过（last>threshold）→ monthsToThreshold nil")
    }

    // 统计52：cycleProjection 跨度一天（rate = Δcycle/1）+ 同日防御（跨日数 0 → nil）。
    do {
        let oneDay = StatsTrend.cycleProjection(
            first: healthRow("2026-01-01", cycleMax: 100, health: nil),
            last: healthRow("2026-01-02", cycleMax: 105, health: nil)
        )
        guard let oneDay else {
            check(false, "统计52", "跨度一天应产出投影")
            return
        }
        expectEqual(oneDay.cyclesPerMonth, 5.0 * 30.44, "统计52", "跨度一天速率 = Δcycle/1（5×30.44）")
        expectEqual(oneDay.monthsToThreshold, 895.0 / 5.0 / 30.44, "统计52", "月数 =（1000−105）/5/30.44")
        check(StatsTrend.cycleProjection(
            first: healthRow("2026-01-01", cycleMax: 100, health: nil),
            last: healthRow("2026-01-01", cycleMax: 200, health: nil)) == nil,
              "统计52", "同日（跨日数 0）→ nil 防御（无可观测速率）")
    }

    // 统计53：presentationState 全组合边界——13/14/89/90 天 × 12/13 桶
    // （调研决策点 2 锁定值；常量单源 StatsTrend）。
    do {
        let cases: [(days: Int, buckets: Int, expected: TrendPresentation)] = [
            (13, 12, .insufficient), (13, 13, .insufficient),   // <14 天恒 insufficient
            (14, 12, .band), (14, 13, .band),                   // 14 天起 band（桶数不抬级）
            (89, 12, .band), (89, 13, .band),                   // <90 天恒 band
            (90, 12, .band), (90, 13, .numeric),                // ≥90 ∧ ≥13 桶才 numeric
        ]
        for caseItem in cases {
            let state = StatsTrend.presentationState(daysOfData: caseItem.days, weeklyBucketCount: caseItem.buckets)
            check(state == caseItem.expected,
                  "统计53", "\(caseItem.days) 天 × \(caseItem.buckets) 桶 → \(caseItem.expected)")
        }
    }

    // 统计54：跨日数口径（crossDayCount——daysOfData 唯一出口）：同日 0 / 跨月 /
    // 跨年 / 闰日 / 非平年二月差 / 非法日串 nil（断档不虚高——口径 = 日历天数非日行数）。
    do {
        expectEqual(StatsTrend.crossDayCount(firstDay: "2026-01-01", today: "2026-01-01"), 0,
                    "统计54", "同日 = 0")
        expectEqual(StatsTrend.crossDayCount(firstDay: "2026-01-31", today: "2026-02-01"), 1,
                    "统计54", "跨月 = 1（日历口径）")
        expectEqual(StatsTrend.crossDayCount(firstDay: "2026-12-31", today: "2027-01-01"), 1,
                    "统计54", "跨年 = 1")
        expectEqual(StatsTrend.crossDayCount(firstDay: "2024-02-28", today: "2024-02-29"), 1,
                    "统计54", "闰日 = 1")
        expectEqual(StatsTrend.crossDayCount(firstDay: "2024-02-28", today: "2024-03-01"), 2,
                    "统计54", "闰年跨二月 = 2")
        expectEqual(StatsTrend.crossDayCount(firstDay: "2026-02-28", today: "2026-03-01"), 1,
                    "统计54", "平年跨二月 = 1")
        check(StatsTrend.crossDayCount(firstDay: "2026-1-1", today: "2026-01-02") == nil
                  && StatsTrend.crossDayCount(firstDay: "abc", today: "2026-01-02") == nil,
              "统计54", "非法日串 → nil（严格形态）")
    }

    // 统计55：ChartAxisStride 扩档扫描——1-400 天逐值断步长恒 .day 且标签数
    // ≤15（floor(跨度/步长)+1 模型；洞区间 105-179 必须被扫描覆盖，不得只钉
    // 吉祥数点——评审 P1 修正二轮）。
    do {
        var scanOK = true
        var badSpan = -1
        var badLabels = -1
        for span in 1...400 {
            let stride = ChartAxisStride.capacity(dataSpanDays: span)
            let labels = span / stride.count + 1
            if stride.component != .day || labels > 15 {
                scanOK = false
                badSpan = span
                badLabels = labels
                break
            }
        }
        check(scanOK, "统计55", "1-400 天逐值扫描全过（首个违规 \(badSpan) 天 → \(badLabels) 标签）")
    }

    // 统计56：ChartAxisStride 档界六点（59/60/99/100/179/180）+ 既有 <60 天档
    // 回归（0.23.4 三档零漂移）。
    do {
        let boundaries: [(days: Int, strideCount: Int)] = [
            (59, 5), (60, 7), (99, 7), (100, 14), (179, 14), (180, 30),
        ]
        for boundary in boundaries {
            let stride = ChartAxisStride.capacity(dataSpanDays: boundary.days)
            check(stride.component == .day && stride.count == boundary.strideCount,
                  "统计56", "档界 \(boundary.days) 天 → (.day, \(boundary.strideCount))")
        }
        let regression: [(days: Int, strideCount: Int)] = [
            (0, 1), (12, 1), (13, 2), (24, 2), (25, 5), (35, 5),
        ]
        for regressionCase in regression {
            let stride = ChartAxisStride.capacity(dataSpanDays: regressionCase.days)
            check(stride.component == .day && stride.count == regressionCase.strideCount,
                  "统计56", "既有档回归 \(regressionCase.days) 天 → (.day, \(regressionCase.strideCount))（0.23.4 零漂移）")
        }
    }

    // 统计57：upsert 滚动写入对账（store 级）——insert → upsert（直方图 75 众数）
    // → dailyHealth 读回逐值；重 upsert 幂等（不增行 + 直方图演化覆盖写）。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = makeStatsStore(dir.appendingPathComponent("stats.sqlite"), scenario: "统计57") else { return }
        let dayZero = statsLocalDayStart(offsetDays: 0)
        await store.insert(statsSample(ts: dayZero + 3600, cycle: 150, nominal: 7612, design: 8694))
        await store.insert(statsSample(ts: dayZero + 7200, cycle: 151, nominal: 7616, design: 8694))
        let today = DailyHealthRollup.dayString(for: Date(timeIntervalSince1970: TimeInterval(dayZero)))
        await store.upsertDailyHealth(day: today, upperHistogram: [80: 3, 75: 5])
        let rows = await store.dailyHealth()
        expectEqual(rows.count, 1, "统计57", "当日单行")
        expectEqual(rows[0].day, today, "统计57", "日串对账")
        expectEqual(rows[0].cycleMax, 151, "统计57", "cycle max 对账")
        expectEqual(rows[0].healthCentiPct, 8760, "统计57", "健康度截断 max 对账")
        expectEqual(rows[0].upperMode, 75, "统计57", "众数对账（75:5 > 80:3）")
        expectEqual(rows[0].sampleCount, 2, "统计57", "当日样本计数对账")
        await store.upsertDailyHealth(day: today, upperHistogram: [80: 9])
        let again = await store.dailyHealth()
        expectEqual(again.count, 1, "统计57", "重 upsert 不增行（INSERT OR REPLACE 幂等）")
        expectEqual(again[0].upperMode, 80, "统计57", "直方图演化当日覆盖写（自愈语义）")
        expectEqual(again[0].sampleCount, 2, "统计57", "样本计数重算不变（同日 samples 集不变）")
    }

    // 统计58：dailyHealth 未来行过滤——时钟前跳产生的未来日期行不参与（评审 P3
    // 登记），day ASC 有序如常。
    do {
        let dir = makeStatsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = makeStatsStore(dir.appendingPathComponent("stats.sqlite"), scenario: "统计58") else { return }
        let dayZero = statsLocalDayStart(offsetDays: 0)
        let today = DailyHealthRollup.dayString(for: Date(timeIntervalSince1970: TimeInterval(dayZero)))
        await store.insert(statsSample(ts: dayZero + 3600, cycle: 151, nominal: 7616, design: 8694))
        await store.upsertDailyHealth(day: today, upperHistogram: [80: 1])
        StatsV3Helpers.insertDailyHealthRaw(
            url: dir.appendingPathComponent("stats.sqlite"), scenario: "统计58",
            day: "2999-12-31", cycleMax: 9999, health: 9900, mode: 100, count: 1
        )
        let rows = await store.dailyHealth()
        expectEqual(rows.count, 1, "统计58", "未来行（2999-12-31）被过滤（day ≤ 今天）")
        expectEqual(rows[0].day, today, "统计58", "仅今日行保留")
    }

    // 统计59：localMidnight 本地午夜出口（趋势卡 X 轴消费）——日串按本地日历解读
    // （X 轴月日标签不漂移）；非法日串 nil。
    do {
        let date = StatsTrend.localMidnight(forDay: "2026-11-10")
        check(date != nil, "统计59", "合法日串解析成功")
        if let date {
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date)
            check(components.year == 2026 && components.month == 11 && components.day == 10
                      && components.hour == 0,
                  "统计59", "本地午夜语义（Y/M/D 对齐 + 0 时）")
        }
        check(StatsTrend.localMidnight(forDay: "bad") == nil
                  && StatsTrend.localMidnight(forDay: "2026-01") == nil,
              "统计59", "非法日串 → nil")
    }
    // MARK: 源钉（方案 §4 源钉清单——照 MenuPresetDomain 形态，源文件读取零渲染零进程）

    // 统计60：趋势卡三态门槛常量单源反钉——门槛常量（14/90/13）只存在于
    // StatsTrend.swift 单源，UI 侧一律经 StatsTrend 函数消费（禁散落魔法数）。
    do {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/CellarCoreCheck
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // 仓库根
        func source(_ relativePath: String) -> String {
            let url = repoRoot.appendingPathComponent(relativePath)
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                check(false, "统计60", "源文件读取失败：\(relativePath)（结构钉面依赖仓库布局）")
                return ""
            }
            return text
        }
        let trendSrc = source("Sources/CellarCore/Stats/StatsTrend.swift")
        check(trendSrc.contains("public static let bandMinDays = 14")
                  && trendSrc.contains("public static let numericMinDays = 90")
                  && trendSrc.contains("public static let numericMinBuckets = 13")
                  && trendSrc.contains("public static let cycleThreshold = 1000"),
              "统计60", "三态门槛 + cycle 阈值常量单源在位（StatsTrend.swift——调研决策点 2 锁定值）")
        let pageSrc = source("App/CellarApp/StatsPageView.swift")
        let cardsSrc = source("App/CellarApp/StatsPageViewCards.swift")
        let cardSrc = source("App/CellarApp/StatsTrendCard.swift")
        check(pageSrc.contains("if trendShowsCard {")
                  && pageSrc.contains("StatsTrendCard(theme: theme, dailyRows: dailyHealthRows)"),
              "统计60", "趋势卡装配在位（容量卡之后 + trendShowsCard 门控——StatsPageView body）")
        let uiSrc = pageSrc + cardsSrc + cardSrc
        check(uiSrc.contains("StatsTrend.presentationState(")
                  && uiSrc.contains("StatsTrend.crossDayCount(")
                  && uiSrc.contains("StatsTrend.weeklyBands(daily:"),
              "统计60", "UI 门槛/跨日数/周桶全经 StatsTrend 函数消费（零本地复算）")
        check(!uiSrc.contains("< 14") && !uiSrc.contains("< 90") && !uiSrc.contains(">= 13"),
              "统计60", "UI 侧零散落魔法数（14/90/13 门槛只在 CellarCore 单源——反钉缺席面）")
        check(cardSrc.contains("Double(StatsTrend.windowDays) * 86_400"),
              "统计60", "hover 桶径 = 窗宽常量派生（禁 7×86400 字面量——windowDays 单源）")
    }

    // 统计61：StatsTrend import 闭包恰 Foundation（纯函数无 IO——无 SQLite/UI/
    // os 通路；聚合不藏 SQL 红线的结构面）。
    do {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("Sources/CellarCore/Stats/StatsTrend.swift")
        guard let data = try? Data(contentsOf: url),
              let trendSrc = String(data: data, encoding: .utf8) else {
            check(false, "统计61", "StatsTrend.swift 读取失败（结构钉面依赖仓库布局）")
            return
        }
        let imports = trendSrc.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("import ") }
        check(imports == ["import Foundation"],
              "统计61", "StatsTrend import 闭包恰 = Foundation（零 SQLite/CellarUI/os 通路）")
    }

    // 统计62：catalog 新键双语直读 + 键数增量登记（482 → 491 有意增量 9——§3）。
    do {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repoRoot.appendingPathComponent("Sources/CellarUI/Resources/Localizable.xcstrings")
        if let data = try? Data(contentsOf: catalogURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let strings = root["strings"] as? [String: Any] {
            let expectations: [String: (zh: String, en: String)] = [
                "stats.trend.title": ("健康趋势", "Health Trend"),
                "stats.trend.subtitle": ("口径：标称满充容量 / 设计容量 · 周桶中位数与循环外推",
                                         "Caliber: nominal / design capacity · weekly median and cycle projection"),
                "stats.trend.band.hint": ("趋势积累中（%1$lld/%2$lld 天）", "Accumulating trend (%1$lld/%2$lld days)"),
                "stats.trend.cycle.rate": ("按当前约 %.1f 循环/月", "At ≈%.1f cycles/month"),
                "stats.trend.cycle.eta": ("，预计 %1$.1f 个月后到达 %2$lld 循环阈值",
                                          ", reaching the %2$lld-cycle threshold in ≈%1$.1f months"),
                "stats.trend.cycle.reached": ("循环数已达阈值", "Cycle count has reached the threshold"),
                "stats.trend.chart.median": ("周中位数", "Weekly median"),
                "stats.trend.chart.band": ("周最小–最大带", "Weekly min–max band"),
                "stats.trend.a11y.summary": ("健康趋势：积累 %lld 天，最新周中位数 %.1f%%",
                                             "Health trend: %lld days accumulated, latest weekly median %.1f%%"),
            ]
            func localized(_ key: String, _ locale: String) -> String? {
                if let entry = strings[key] as? [String: Any],
                   let localizations = entry["localizations"] as? [String: Any],
                   let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any] {
                    return unit["value"] as? String
                }
                return nil
            }
            var allPresent = true
            for (key, expected) in expectations {
                if localized(key, "zh-Hans") != expected.zh || localized(key, "en") != expected.en {
                    allPresent = false
                }
            }
            check(allPresent, "统计62", "catalog 新键九项双语在位（stats.trend.* §3 清单逐字）")
            expectEqual(strings.count, 513, "统计62", "键数增量登记 507 → 511（0.23.18 commit 4：+5 −1——panel.versionLine3/handshake 三键/btmDrift 入库、panel.versionLine 退役——本域九键 482 → 491、profile 批 491 → 507）→ 513（0.23.22 commit 2：+2——panel.daemon.stalePin/reRegister 两键入库——stale-pin 精确行 + 一键重注册；断言值随批推进）")
        } else {
            check(false, "统计62", "catalog 键结构缺席（双语源钉红）")
        }
    }

    // 统计63：PolicyContextBox + tick 滚动聚合接线源钉（§2.2）——NSLock 单值盒 /
    // 失联置 nil / 直方图跨日重置 / upsert 接线 / 日界 Calendar 纪律（禁 86400
    // 乘法）/ ingest 写盒。
    do {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func source(_ relativePath: String) -> String {
            let url = repoRoot.appendingPathComponent(relativePath)
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                check(false, "统计63", "源文件读取失败：\(relativePath)（结构钉面依赖仓库布局）")
                return ""
            }
            return text
        }
        let samplerSrc = source("App/CellarApp/StatsSampler.swift")
        let statusSrc = source("App/CellarApp/StatusController.swift")
        check(samplerSrc.contains("final class PolicyContextBox: @unchecked Sendable")
                  && samplerSrc.contains("private let lock = NSLock()")
                  && samplerSrc.contains("func set(_ value: Int?)")
                  && samplerSrc.contains("func latest() -> Int?")
                  && samplerSrc.contains("static let shared = PolicyContextBox()"),
              "统计63", "PolicyContextBox 在位（NSLock 单值盒 + 单例——StatusController 写 / StatsSampler 读跨隔离域传递）")
        check(samplerSrc.contains("upperHistogram[upperLimit, default: 0] += 1")
                  && samplerSrc.contains("if histogramDay != day {")
                  && samplerSrc.contains("await store?.upsertDailyHealth(day: day, upperHistogram: upperHistogram)")
                  && samplerSrc.contains("await store?.insert(sample)\n        await recordDailyHealth()"),
              "统计63", "tick 顺带滚动聚合接线在位（insert 后 recordDailyHealth：直方图累计 + 跨日重置 + 当日 upsert）")
        check(samplerSrc.contains("DailyHealthRollup.dayString(for: Date())")
                  && !samplerSrc.contains("* 86400") && !samplerSrc.contains("/ 86400")
                  && !samplerSrc.contains("* 86_400") && !samplerSrc.contains("/ 86_400"),
              "统计63", "日界 = dayString（Calendar.startOfDay 派生）——零 86400 乘除（禁令纪律，评审 P2 修正）")
        check(samplerSrc.contains("func queryDailyHealth() async -> [DailyHealthRow]")
                  && samplerSrc.contains("return await store.dailyHealth()"),
              "统计63", "queryDailyHealth actor 透传在位（趋势卡数据源——主线程零 SQLite）")
        check(statusSrc.contains("PolicyContextBox.shared.set(status?.upperLimit)"),
              "统计63", "ingest 写盒在位（status == nil 置 nil——陈旧限值不喂直方图，评审 P2 修正）")
    }
}


/// 本地日零点 epoch 秒（相对今天 -offsetDays 天）：跨多日 fixture 的日界基准
/// ——与 DailyHealthRollup.dayString 同一 Calendar 口径（本地日对齐，免
/// 86400 回退在零点附近跨日漂移）。
private func statsLocalDayStart(offsetDays: Int) -> Int {
    let calendar = Calendar.current
    let dayStart = calendar.date(
        byAdding: .day, value: -offsetDays, to: calendar.startOfDay(for: Date())
    ) ?? Date()
    return Int(dayStart.timeIntervalSince1970)
}

// MARK: - 0.23.17 Schema v3 场景助手（raw sqlite 直构与核验——StatsV2Helpers 先例）

private enum StatsV3Helpers {
    /// 原始 SQL 直执行（未来版本库注入等——独立原始连接，用后即关）。
    static func rawExec(url: URL, sql: String, scenario: String) {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            check(false, scenario, "raw 连接打开失败")
            return
        }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            check(false, scenario, "raw SQL 执行失败：\(detail)")
            return
        }
        sqlite3_free(error)
    }

    /// 预置 Schema v2 旧库（统计41/42/43 fixture）：v2 十六列表 + 跨多日样本 +
    /// user_version=2（独立原始连接写入后关闭；容量列可空注入，其余按默认值）。
    static func v2LegacyFixture(
        url: URL,
        samples: [(ts: Int64, cycle: Int, nominal: Int?, design: Int?)],
        scenario: String
    ) {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            check(false, scenario, "v2 fixture 建库失败")
            return
        }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        let create = """
        CREATE TABLE samples (
          ts INTEGER PRIMARY KEY, percent INTEGER NOT NULL, temp_centi INTEGER NOT NULL,
          power_mw INTEGER NOT NULL, external INTEGER NOT NULL, charging INTEGER NOT NULL,
          cycle INTEGER NOT NULL, max_cap_pct INTEGER, nominal_mah INTEGER, design_mah INTEGER,
          acc_load INTEGER, acc_load_count INTEGER, acc_discharge INTEGER,
          acc_discharge_count INTEGER, daily_min_soc INTEGER, daily_max_soc INTEGER
        );
        PRAGMA user_version = 2;
        """
        guard sqlite3_exec(db, create, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            check(false, scenario, "v2 fixture 建表失败：\(detail)")
            return
        }
        sqlite3_free(error)
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        INSERT INTO samples (ts, percent, temp_centi, power_mw, external, charging, cycle,
                             max_cap_pct, nominal_mah, design_mah)
        VALUES (?1, 50, 3030, 0, 1, 0, ?2, NULL, ?3, ?4)
        """, -1, &insert, nil) == SQLITE_OK, let statement = insert else {
            check(false, scenario, "v2 fixture 插入语句准备失败")
            return
        }
        defer { sqlite3_finalize(statement) }
        for sample in samples {
            sqlite3_reset(statement)
            sqlite3_bind_int64(statement, 1, sample.ts)
            sqlite3_bind_int64(statement, 2, Int64(sample.cycle))
            if let nominal = sample.nominal {
                sqlite3_bind_int64(statement, 3, Int64(nominal))
            } else {
                sqlite3_bind_null(statement, 3)
            }
            if let design = sample.design {
                sqlite3_bind_int64(statement, 4, Int64(design))
            } else {
                sqlite3_bind_null(statement, 4)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                check(false, scenario, "v2 fixture 插入失败（ts=\(sample.ts)）")
                return
            }
        }
    }

    /// daily_health 全行直读（独立连接，绕过 StatsStore——迁移/建表结果核验；
    /// 表缺席（直建路径漏表）→ 查询失败即场景红）。
    static func readDailyHealth(
        url: URL, scenario: String
    ) -> [(day: String, cycleMax: Int, health: Int?, mode: Int?, count: Int)] {
        var raw: OpaquePointer?
        guard sqlite3_open(url.path, &raw) == SQLITE_OK, let raw else {
            check(false, scenario, "daily_health 直读连接打开失败")
            return []
        }
        defer { sqlite3_close(raw) }
        var result: [(day: String, cycleMax: Int, health: Int?, mode: Int?, count: Int)] = []
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
                raw, """
                SELECT day, cycle_max, health_centi_pct, upper_mode, sample_count
                FROM daily_health ORDER BY day ASC
                """,
                -1, &statement, nil) == SQLITE_OK,
              let select = statement else {
            check(false, scenario, "daily_health 直读语句准备失败（表在位性核验）")
            return []
        }
        defer { sqlite3_finalize(select) }
        while sqlite3_step(select) == SQLITE_ROW {
            func optionalInt(_ index: Int32) -> Int? {
                sqlite3_column_type(select, index) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(select, index))
            }
            result.append((
                day: sqlite3_column_text(select, 0).map { String(cString: $0) } ?? "",
                cycleMax: Int(sqlite3_column_int64(select, 1)),
                health: optionalInt(2),
                mode: optionalInt(3),
                count: Int(sqlite3_column_int64(select, 4))
            ))
        }
        return result
    }

    /// 原始直插 daily_health 行（统计58 未来行 fixture——绕过 StatsStore 写面）。
    static func insertDailyHealthRaw(
        url: URL, scenario: String,
        day: String, cycleMax: Int, health: Int?, mode: Int?, count: Int
    ) {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            check(false, scenario, "直插连接打开失败")
            return
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        INSERT INTO daily_health (day, cycle_max, health_centi_pct, upper_mode, sample_count)
        VALUES (?1, ?2, ?3, ?4, ?5)
        """, -1, &statement, nil) == SQLITE_OK, let insert = statement else {
            check(false, scenario, "直插语句准备失败")
            return
        }
        defer { sqlite3_finalize(insert) }
        sqlite3_bind_text(insert, 1, day, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(insert, 2, Int64(cycleMax))
        if let health {
            sqlite3_bind_int64(insert, 3, Int64(health))
        } else {
            sqlite3_bind_null(insert, 3)
        }
        if let mode {
            sqlite3_bind_int64(insert, 4, Int64(mode))
        } else {
            sqlite3_bind_null(insert, 4)
        }
        sqlite3_bind_int64(insert, 5, Int64(count))
        guard sqlite3_step(insert) == SQLITE_DONE else {
            check(false, scenario, "直插失败（day=\(day)）")
            return
        }
    }

    /// samples 行数直读（回填零增删核验——独立连接）。
    static func readSampleCount(url: URL, scenario: String) -> Int {
        var raw: OpaquePointer?
        guard sqlite3_open(url.path, &raw) == SQLITE_OK, let raw else {
            check(false, scenario, "samples 行数直读连接打开失败")
            return -1
        }
        defer { sqlite3_close(raw) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(raw, "SELECT COUNT(*) FROM samples", -1, &statement, nil) == SQLITE_OK,
              let select = statement, sqlite3_step(select) == SQLITE_ROW else {
            sqlite3_finalize(statement)
            check(false, scenario, "samples 行数查询失败")
            return -1
        }
        let count = Int(sqlite3_column_int64(select, 0))
        sqlite3_finalize(select)
        return count
    }
}
