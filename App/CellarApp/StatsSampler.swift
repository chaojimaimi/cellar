import CellarCore
import Foundation
import os

/// 统计采样器（方案 §2.4）：60s Task 常驻循环，把电池快照周期落库。
///
/// - **与表面可见性解耦**（UD-2）：统计的历史价值恰恰在「没人看的时候也在记」
///   ——采样不受多表面仲裁约束（仲裁管 UI 刷新档位，不管记录）；60s 唤醒功耗
///   可忽略（PLAN 采样分级纪律：后台分钟级合规）。
/// - **主线程零 SQLite**（红线 4）：本类型为 actor，StatsStore 的构造与全部
///   调用都在本 actor 执行器（MainActor 外）完成。
/// - **临时实例自熄**：App 结构体每次求值都会重算属性初始值——被 SwiftUI 丢弃
///   的临时采样器靠循环内逐跳 weak-self 复查自熄（StatusController pollTask
///   同款形态）；幸存实例随 App 生命周期常驻，App 退出即停（无常驻后台需求）。
/// - **断档如实**（UD-5）：解析失败跳过本跳（日志可见化，不 crash）；睡眠/未
///   运行时段自然断档，无回填无插值。
/// - **累加器仪器化**（0.22.0 §2.3，观察期实验②③被动证据收集）：tick 内与
///   actor 内前值比对（分类判据复用 EnergyAggregation.classifyPair 共享纯函数
///   ——与聚合同一真相）——SystemLoad 计数回退记复位事件（os_log，实验③复位
///   条件定谳证据）；间隙 > 10 min 记 Δacc/Δcount/时长（实验②睡眠计入与否：
///   隔夜合盖首跳 Δacc 量级直接判读）。App 未运行期间无跳（前值跨启动失效）
///   ——启动后首跳只建前值不比对。
actor StatsSampler {
    /// 采样间隔：60s 定版（§8 明确不做设置项）。
    private static let sampleInterval: Duration = .seconds(60)
    /// 长间隙记录阈值（0.22.0 §2.3）：ts 间隙 > 10 min 视为睡眠/未运行间隙。
    private static let gapThreshold: TimeInterval = 10 * 60

    /// 日志（actor 静态成员非隔离；Logger Sendable——StatusController 同款）。
    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "stats")

    /// 统计库（惰性建库：首跳创建；失败本跳跳过、下跳重试——统计故障不挂 App）。
    private var store: StatsStore?

    /// 累加器比对前值（上一跳采样整体留存——acc 四元组 + ts 同源；actor 内存态
    /// 跨启动失效 = 首跳只建前值的天然实现）。
    private var previousSample: StatsSample?

    /// 自标定：构造即启动循环（@StateObject 早期访问陷阱教训——自标定在自身
    /// init，CellarApp.init 不触碰；actor 同步构造器本身 nonisolated，Task 在
    /// 全局执行器启动后逐跳 hop 进本 actor）。
    init() {
        Task { [weak self] in
            // 首跳立即采样（启动即有数据点，不等首个 60s）。⚠️ guard let self
            // 的强绑定只在本 do 块内——出块即释放，逐跳复查才成立。
            do {
                guard let self else { return }
                await self.tick()
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sampleInterval)
                // 每跳先复查 weak self——临时实例析构后循环自熄，防僵尸采样器
                // 多写者（guard 绑定同样限定在 do 块内，逐跳释放）。
                do {
                    guard let self, !Task.isCancelled else { return }
                    await self.tick()
                }
            }
        }
    }

    /// 单跳：建库（若需）→ `BatteryMonitor.makeDefault()` 独立实例直读（内部经
    /// BatterySnapshotParser 纯函数；与 StatusController 遥测循环并发读 IOKit
    /// 各自独立连接，安全——§2.4）→ 组装 StatsSample → 累加器仪器化比对 →
    /// 入库（顺带滚动窗口 prune）。
    private func tick() async {
        if store == nil {
            do {
                store = try StatsStore(url: StatsStore.defaultURL)
            } catch {
                Self.log.error("统计库初始化失败，本跳跳过（下跳重试）：\(String(describing: error), privacy: .public)")
                return
            }
        }
        let sample: StatsSample
        do {
            sample = StatsSample(snapshot: try BatteryMonitor.makeDefault().snapshot())
        } catch {
            Self.log.warning("统计采样失败，跳过本跳：\(String(describing: error), privacy: .public)")
            return
        }
        instrument(previous: previousSample, current: sample)
        previousSample = sample
        await store?.insert(sample)
    }

    /// 累加器仪器化（0.22.0 §2.3）：与前跳比对（共享分类器——聚合与日志同一
    /// 真相）；只记日志不改数据（聚合侧对复位对的处理是独立防线）。前值 nil =
    /// 启动后首跳（只建前值，调用方推进）。
    private func instrument(previous: StatsSample?, current: StatsSample) {
        guard let previous else { return }
        // 系统通道 Δacc/Δcount（复位与长间隙两路日志共用的投影；nil = 该跳
        // 键缺席——如实记 nil 不造 0）。
        let deltaAcc = current.accSystemLoadMWs.flatMap { currentAcc in
            previous.accSystemLoadMWs.map { currentAcc - $0 }
        }
        let deltaCount = current.accSystemLoadCount.flatMap { currentCount in
            previous.accSystemLoadCount.map { currentCount - $0 }
        }
        // 复位检测（实验③仪器）：SystemLoad 计数回退 → notice 记前后值 + 时刻
        // （复位条件定谳证据——下一次系统再启动自然捕获；放电通道计数回退由
        // 聚合侧 dischargeResets 承接，此处不重复）。
        let loadClass = EnergyAggregation.classifyPair(
            acc0: previous.accSystemLoadMWs, count0: previous.accSystemLoadCount,
            acc1: current.accSystemLoadMWs, count1: current.accSystemLoadCount,
            accDecreasingIsNormal: false
        )
        if loadClass == .reset {
            Self.log.notice("""
            累加器复位事件（SystemLoadAccumulatorCount 回退）：\
            前 \(previous.accSystemLoadCount.map(String.init) ?? "nil")@\
            \(Int(previous.timestamp.timeIntervalSince1970)) → \
            后 \(current.accSystemLoadCount.map(String.init) ?? "nil")@\
            \(Int(current.timestamp.timeIntervalSince1970))；\
            Δacc=\(deltaAcc.map(String.init) ?? "nil")mWs
            """)
        }
        // 长间隙记录（实验②仪器）：隔夜合盖后首跳的 Δacc 大小直接判读睡眠
        // 计入与否——近零 = 睡眠不计入，量级正常 = 计入（log show 查询指引
        // 见 SMC-NOTES §11.10）。
        let gap = current.timestamp.timeIntervalSince(previous.timestamp)
        guard gap > Self.gapThreshold else { return }
        Self.log.notice("""
        采样长间隙 \(Int(gap))s：Δacc(SystemLoad)=\(deltaAcc.map(String.init) ?? "nil")mWs \
        Δcount=\(deltaCount.map(String.init) ?? "nil")（间隙对能量如实计入聚合——UD-5）
        """)
    }

    /// 查询透传（M3 StatsPageView 消费；本批仅透传——查询经 StatsStore actor
    /// 执行，主线程零 SQLite；范围/桶径由消费方决定：24h→120 / 7d→1800 / 30d→7200）。
    func query(range: Range<Date>, bucketSeconds: Int) async -> [StatsBucket] {
        guard let store else { return [] }
        return await store.query(range: range, bucketSeconds: bucketSeconds)
    }

    /// 能耗差分聚合透传（0.22.0 §2.2；桶径能耗卡专属：24h→3600 / 7d、30d→86400）。
    func energyBuckets(range: Range<Date>, bucketSeconds: Int) async -> EnergySummary {
        guard let store else {
            return EnergySummary(buckets: [], resets: 0, dischargeResets: 0, unknownDischargeSpans: 0)
        }
        return await store.energyBuckets(range: range, bucketSeconds: bucketSeconds)
    }

    /// 最新采样透传（0.22.0 §3.3 今日 SOC 区间行——最新样本 dailyMin/MaxSoc 消费）。
    func latestSample() async -> StatsSample? {
        guard let store else { return nil }
        return await store.latest()
    }
}
