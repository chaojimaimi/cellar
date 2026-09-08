import Foundation
import CellarCore

// MARK: - 风扇运行时状态与错误（Phase 5 v1.12 M1 槽位化，方案 §2-D2——自
// DaemonCore+Fan.swift 尾部拆出：纯移动零语义变化 + 新增 FanSlot 单槽结构。

/// 单风扇槽位状态机（D2/D3 核心）：per-fan 字段全集收进本结构，F0/F1 同温同策略
/// 独立决策执行——进入/冲突/能力/观察窗全部 per-slot（诚实隔离：F1 两步写失败
/// 不阻 F0；冲突漂移 latch 槽位独立，外部写者只废一扇，另一扇不受累）。
struct FanSlot {
    /// 槽位下标（0/1 → FanKey.md(index) 等键族——键名唯一字符串真相源）。
    let index: Int
    /// boost 活跃（两步写成功后置位；两步释放后清零）。
    var boostActive = false
    /// boost 以来风扇 tick 数（进入置 0，逐 tick +1，release 清零——R1 P3-4）。
    var boostTicks = 0
    /// 能力（sticky；仅开关翻转重置——setFanConfig）。
    var capability: FanCapability = .unverified
    /// 本机 F\(index)Mn/F\(index)Mx 探测缓存（nil = 未探测成功；boost 期失效 → 立即释放）。
    var facts: FanFacts?
    /// facts 探测成功时的客户端代际（≠ clientGeneration → 失效重探）。
    var factsProbeGeneration = -1
    /// 冲突标志（方案 §5.3：漂移 ≥2 → 置位；会话内暂停介入；开关翻转重置）。
    /// WHY per-slot：外部写者只废一扇，另一扇不受累（D3）。
    var conflictFlag = false
    /// 进入 boost 连续失败计数（≥3 → 该槽能力 unavailable，§13 R3）。
    var entryFailures = 0
    /// 状态行词（各决策副作用更新；初值 off = 未配置形态）。
    var word: FanStateWord = .off
    /// 最近一次写入目标 rpm（FanStatus.targetRPM / secondFanTargetRPM 载荷）。
    var targetRPM: Float?
    /// 最近一次 F\(index)Ac 活值（仅 boost 期采样；FanStatus.currentRPM /
    /// secondFanCurrentRPM 载荷）。
    var currentRPM: Float?
    /// 最近一次成功写入的 F\(index)Tg 字节（漂移检测比对基准）。
    var lastWrittenTg: [UInt8]?
    /// 进入 boost 时的 F\(index)Tg 原值快照（释放序列第一步的还原目标）。
    var originalTg: [UInt8]?
    /// 漂移连续计数（写后回读不一致/下 tick 回读漂移；清朗回读归零）。
    var driftTicks = 0
}

/// 风扇运行时状态（DaemonCore.swift 的单一存储属性 `var fanState`；本文件定义——
/// 扩展不能加存储属性。崩溃重启即清零——重启后由 startup 的 releaseFanLocked
/// 残留检查（F0Md≠0 → 写 0）收口，方案 §6.5）。
///
/// v1.12 M1 槽位化（方案 §2-D2）：per-fan 字段收进 FanSlot（slots 1 或 2 个）；
/// 温度采样三件/cpuSkin 探测三件/clientGeneration 为双扇共享（D1 同开关同策略
/// 同阈值驱动两扇——采样语义零变化）。
struct FanRuntimeState {
    /// 槽位数组（初始仅 F0；F1 在位探测成功（D4 sticky）后 append 槽 1——只增不删）。
    var slots: [FanSlot] = [FanSlot(index: 0)]
    /// F1 在位探测结论（D4 sticky 机型事实）：nil = 未探（smcClient 缺席窗口不置
    /// sticky，下 tick 重探——照 cpuSkinSupported 探测纪律）；false = F1Mn 键缺席
    ///（单风扇机型事实，sticky 永不重探，零后续 SMC 流量）；true = 在位（slot1
    /// 已建）。WHY：机型结构事实一次性定论——防每 tick 重复探测浪费 SMC 流量，
    /// 也防把「键缺席」误当传输故障反复计数。
    var fan1Presence: Bool?
    /// SMCClient 重建代际（establishBackendLocked 递增——facts 缓存失效信号）。
    var clientGeneration = 0
    /// 温度采样连续失败计数（≥3 → sampleHealthy=false；双扇共享——同温同源 D1）。
    var sampleFailures = 0
    /// 采样健康（BatterySnapshot 连续失败 ≥3 → false；恢复采样自动复位——
    /// capability 不因采样抖动重置，方案 §6.6；双扇共享）。
    var sampleHealthy = true
    /// 最近成功采样温度（采样失败期间沿用——F 行在温度比较前短路，值不参与判定；
    /// 双扇共享同温）。
    var lastTemperatureC: Double = 0
    /// CPU 表面温度源探测结论（v1.11 T3；nil = 未探——smcClient 缺席窗口不置
    /// sticky，下轮重探；true/false = 探测结论 sticky 不回落）。
    var cpuSkinSupported: Bool?
    /// CPU 表面温度键（探测命中时记录；nil = 未命中/未探）。
    var cpuSkinKey: String?
    /// 最近一次 CPU 表面温度采样 °C（FanStatus.cpuSkinTempC 载荷；源切换清残留）。
    var lastCpuSkinTempC: Double?
}

/// setFan 拒绝（message = 用户可读文案；XPC errorReply 原文透传，App 上屏）。
enum FanSetError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 参数越界（validated 整包 nil——不落半合法策略）。
    case invalidParameters
    /// cpuSkin 源请求但本机探测不支持（v1.11 T3 fail-visible，方案 D-3c）。
    case cpuSkinUnsupported

    public var message: String {
        switch self {
        case .invalidParameters: return "风扇参数越界（阈值 30-55°C，转速 40-100%，滞回 1-5°C）"
        case .cpuSkinUnsupported: return "本机不支持 CPU 表面温度源"
        }
    }

    public var description: String { message }
}

/// 风扇写回读校验失败（字节级不一致；description 进日志与 XPC 错误分支）。
enum FanBodyError: Error, Equatable, Sendable {
    case readbackMismatch(key: String, desiredHex: String, actualHex: String)
}

extension FanBodyError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .readbackMismatch(let key, let desiredHex, let actualHex):
            return "\(key) 写后回读不一致（期望 \(desiredHex)，实际 \(actualHex)）"
        }
    }
}

// MARK: - F1 在位探测（v1.12 D4 sticky 机型事实；状态与探测同文件——结论承载
// 于 FanRuntimeState.fan1Presence）

extension DaemonCore {
    /// F1 在位惰性探测：F1Mn keyInfo 一次定论，结论 sticky 于 fan1Presence
    /// （nil = 未探——smcClient 缺席窗口不置 sticky 下轮重探，照 cpuSkinSupported
    /// 纪律；false = 键缺席单风扇机型事实，sticky 永不重探、零后续 SMC 流量；
    /// true = 双槽在位且 slot1 已建——只 append 一次）。键形态门（flt/4B）不在此
    /// 做——归属 per-slot facts 探测（fail-visible 语义同 F0）。
    /// 返回值 = 本次产生的结论转移（供有日志通道的调用点可见化）；status 组装
    /// 路径照 cpuSkin 先例静默消费。传输类错误不置 sticky 不定论（下轮重探）——
    /// 防「传输抖动」被误判成「单风扇机型」永久屏蔽双扇能力。
    enum Fan1PresenceOutcome { case newlyPresent, newlyAbsent }

    @discardableResult
    func ensureFan1PresenceLocked() -> Fan1PresenceOutcome? {
        guard fanState.fan1Presence == nil, let client = smcClient else { return nil }
        do {
            _ = try client.keyInfo(FanKey.mn(1))
            fanState.fan1Presence = true
            fanState.slots.append(FanSlot(index: 1))
            return .newlyPresent
        } catch {
            if FanGuard.isKeyDomainError(error) {
                fanState.fan1Presence = false
                return .newlyAbsent
            }
            return nil
        }
    }
}
