// CellarCoreCheck —— WP5 菜单栏图标 powerOverride 场景域（方案 §2.4）
//
// override 非 nil 时**替换** daemonStatus.lastExternalConnected/lastChargingEnabled
// 参与规则 4/5 判定（图标即时翻转）；规则 1/2/3（失联/未安装/禁用）优先级更高，
// 不受 override 影响。override nil = 既有行为零变化（用例 85 穷举已钉死两参签名，
// 本域只抽查三参 nil 与两参一致的规则点）。

import CellarCore
import Foundation

/// 图标 override 场景域入口（Main.main 调用）。
func runIconOverrideDomainScenarios() {
    func status(mode: String = "active", external: Bool? = nil, charging: Bool? = nil) -> DaemonStatus {
        DaemonStatus(
            version: "fixture", mode: mode, upperLimit: 80, hysteresis: 2,
            lastExternalConnected: external, lastChargingEnabled: charging
        )
    }

    // 图标-1：override 替换语义（规则 4/5 即时翻转，daemon 快照滞后不影响）。
    check(menuBarIconState(
        status: status(external: true, charging: true), connection: .connected,
        powerOverride: PowerOverride(externalConnected: false, isCharging: true)
    ) == .discharging, "图标-1", "拔电：override external=false → 即时 .discharging（daemon 快照仍为外接）")

    check(menuBarIconState(
        status: status(external: false, charging: false), connection: .connected,
        powerOverride: PowerOverride(externalConnected: true, isCharging: true)
    ) == .charging, "图标-1", "插电：override isCharging=true → 即时 .charging（daemon 快照仍为电池态）")

    check(menuBarIconState(
        status: status(external: true, charging: true), connection: .connected,
        powerOverride: PowerOverride(externalConnected: true, isCharging: false)
    ) == .holding, "图标-1", "外接 + 未充电（override isCharging=false）→ .holding（替换语义，nil 拦截不适用）")

    // 图标-2：规则 1/2/3 优先级高于 override。
    check(menuBarIconState(
        status: status(external: true, charging: true), connection: .unreachable,
        powerOverride: PowerOverride(externalConnected: true, isCharging: true)
    ) == .alert, "图标-2", "失联 → .alert（规则 1 优先，override 不干预）")

    check(menuBarIconState(
        status: nil, connection: .connected,
        powerOverride: PowerOverride(externalConnected: true, isCharging: true)
    ) == .disabled, "图标-2", "status nil → .disabled（规则 2 优先）")

    check(menuBarIconState(
        status: status(mode: "disabled", external: true, charging: true), connection: .connected,
        powerOverride: PowerOverride(externalConnected: true, isCharging: true)
    ) == .disabled, "图标-2", "mode=disabled → .disabled（规则 3 优先）")

    // 图标-3：override nil = 两参签名行为零变化（抽查规则点；穷举面见用例 85）。
    check(menuBarIconState(
        status: status(external: false, charging: true), connection: .connected,
        powerOverride: nil
    ) == .discharging, "图标-3", "override nil：external=false → .discharging（现行为）")
    check(menuBarIconState(
        status: status(external: true, charging: true), connection: .connected,
        powerOverride: nil
    ) == .charging, "图标-3", "override nil：charging=true → .charging（现行为）")
    check(menuBarIconState(
        status: status(external: true, charging: nil), connection: .connected,
        powerOverride: nil
    ) == .holding, "图标-3", "override nil：双 nil 字段保持 .holding 初态语义")
}