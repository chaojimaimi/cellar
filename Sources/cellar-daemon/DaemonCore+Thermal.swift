import Foundation
import CellarCore

// MARK: - Phase 5 v1.5 setThermal（方案 §2.2；全部锁内）

/// setThermal 的 daemon 侧实现（**独立扩展文件**——R1 P3 定版，UD-6 两套配置分离
/// 的文件面落地；可见性/属主不变量与 DaemonCore+Fan.swift 同款：cellar-daemon 为
/// executable target，internal 符号模块外不可达。全部锁内，复用 DaemonCore.lock
/// 单一锁，禁新锁）。
extension DaemonCore {
    /// setThermalConfig：校验（缺席保持合并 + validated 整包强校验）→ 应用 policy
    /// （**不改 mode**——setLimits 的「更新即切 active」语义不适用，照 setFanConfig
    /// 先例）→ 持久化 → 返回状态。无即时 tick 必要——下一 tick 守卫/保活即按新值
    /// 判定（30s 心跳内生效，方案 §2.2）。
    func setThermalConfig(_ wire: ThermalWire) throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }

        guard let merged = wire.mergedPolicy(base: policy.thermal ?? ThermalPolicy.default) else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "setThermal 拒绝：热暂停参数越界（validated 整包 nil——绝不落半合法策略）"
            ))
            throw ThermalSetError.invalidParameters
        }
        // F-1 纪律：applyPolicyLocked 之外的直接字段更新——policy.thermal 是本命令
        // 的专属修改面（模式/限值/风扇/调度不动），与 setLimits/disable/enable 的
        // 重建点互斥（照 setFanConfig :83 先例）。
        policy.thermal = merged
        persistPolicyLocked(events: &events)
        events.append(LogEvent(
            category: .control, level: .info,
            message: "热暂停配置已更新：≥"
                + String(format: "%.1f", Double(merged.pauseCentiC) / 100)
                + "°C 暂停 / 滞回 "
                + String(format: "%.1f", Double(merged.hysteresisCentiC) / 100)
                + "°C（下一 tick 守卫即按新值判定）"
        ))
        return buildStatusLocked()
    }
}

/// setThermal 拒绝（message = 用户可读文案；XPC errorReply 原文透传，App 上屏；
/// 形态照 FanSetError）。
enum ThermalSetError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 参数越界（validated 整包 nil——不落半合法策略）。
    case invalidParameters

    public var message: String {
        switch self {
        case .invalidParameters: return "热暂停参数越界（暂停阈值 35-45°C，滞回 1-8°C）"
        }
    }

    public var description: String { message }
}
