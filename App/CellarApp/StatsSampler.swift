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
actor StatsSampler {
    /// 采样间隔：60s 定版（§8 明确不做设置项）。
    private static let sampleInterval: Duration = .seconds(60)

    /// 日志（actor 静态成员非隔离；Logger Sendable——StatusController 同款）。
    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "stats")

    /// 统计库（惰性建库：首跳创建；失败本跳跳过、下跳重试——统计故障不挂 App）。
    private var store: StatsStore?

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
    /// 各自独立连接，安全——§2.4）→ 组装 StatsSample → 入库（顺带滚动窗口 prune）。
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
        await store?.insert(sample)
    }

    /// 查询透传（M3 StatsPageView 消费；本批仅透传——查询经 StatsStore actor
    /// 执行，主线程零 SQLite；范围/桶径由消费方决定：24h→120 / 7d→1800 / 30d→7200）。
    func query(range: Range<Date>, bucketSeconds: Int) async -> [StatsBucket] {
        guard let store else { return [] }
        return await store.query(range: range, bucketSeconds: bucketSeconds)
    }
}
