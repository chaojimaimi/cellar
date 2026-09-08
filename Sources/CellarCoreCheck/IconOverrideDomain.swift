// CellarCoreCheck —— WP5 菜单栏图标 powerOverride 场景域（方案 §2.4）
//
// override 非 nil 时**替换** daemonStatus.lastExternalConnected/lastChargingEnabled
// 参与规则 4/5 判定（图标即时翻转）；规则 1/2/3（失联/未安装/禁用）优先级更高，
// 不受 override 影响。override nil = 既有行为零变化（用例 85 穷举已钉死两参签名，
// 本域只抽查三参 nil 与两参一致的规则点）。
//
// v1.12.1 冻结修复配套：menuBarBatteryForm 电池形态取值链纯函数化——快照缺席
// （全表面关闭，refreshCadence 即时清空）时电源二值走 override、百分比走
// daemonPercent，「电池形态」域场景钉死回退链与优先级。

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

    // MARK: 电池形态取值链（v1.12.1 冻结修复配套——menuBarBatteryForm 纯函数化）

    // 元组逐字段断言（元组无 Equatable 协议遵循，helper 代替 ==）。
    func isForm(
        _ result: (percent: Int, charging: Bool, plugged: Bool)?,
        _ percent: Int, _ charging: Bool, _ plugged: Bool
    ) -> Bool {
        guard let result else { return false }
        return result.percent == percent
            && result.charging == charging
            && result.plugged == plugged
    }

    // 电池形态-1：快照在位（面板可见语义）→ 三值全走快照，override 相反值不夺权
    // （优先级钉死——0.18 冻结根因即快照第一优先，保留但配「全关即清」生命周期契约）。
    check(isForm(
        menuBarBatteryForm(
            snapshotPercent: 61, snapshotIsCharging: true, snapshotExternalConnected: true,
            powerOverride: PowerOverride(externalConnected: false, isCharging: false),
            daemonPercent: 99),
        61, true, true), "电池形态-1", "快照在位：三值全走快照（override 相反值不夺权）")

    // 电池形态-2..4：快照缺席（全表面关闭，v1.12.1 起即清空）→ 电源二值走
    // override（IOPS 活数据）、百分比走 daemonPercent——插拔电徽标即时翻转。
    check(isForm(
        menuBarBatteryForm(
            snapshotPercent: nil, snapshotIsCharging: nil, snapshotExternalConnected: nil,
            powerOverride: PowerOverride(externalConnected: true, isCharging: true),
            daemonPercent: 61),
        61, true, true), "电池形态-2", "快照缺席 + override 充电中 → 闪电（percent 走 daemon）")

    check(isForm(
        menuBarBatteryForm(
            snapshotPercent: nil, snapshotIsCharging: nil, snapshotExternalConnected: nil,
            powerOverride: PowerOverride(externalConnected: true, isCharging: false),
            daemonPercent: 61),
        61, false, true), "电池形态-3", "快照缺席 + override 外接未充 → 插头（维持态可达）")

    check(isForm(
        menuBarBatteryForm(
            snapshotPercent: nil, snapshotIsCharging: nil, snapshotExternalConnected: nil,
            powerOverride: PowerOverride(externalConnected: false, isCharging: false),
            daemonPercent: 61),
        61, false, false), "电池形态-4", "快照缺席 + override 电池供电 → 无徽标（拔电即时消失）")

    // 电池形态-5：快照与 override 双缺席（IOPS 订阅创建失败降级）→ 充电/外接
    // 按 false，百分比照显——诚实降级，与冷启动初态同语义。
    check(isForm(
        menuBarBatteryForm(
            snapshotPercent: nil, snapshotIsCharging: nil, snapshotExternalConnected: nil,
            powerOverride: nil, daemonPercent: 61),
        61, false, false), "电池形态-5", "override nil 降级 → 无徽标 + 百分比照显")

    // 电池形态-6：双 nil → 整体 nil，label 回退符号形态（恒渲染红线）。
    check(menuBarBatteryForm(
        snapshotPercent: nil, snapshotIsCharging: nil, snapshotExternalConnected: nil,
        powerOverride: nil, daemonPercent: nil) == nil,
        "电池形态-6", "快照与 daemonPercent 双 nil → 整体 nil（回退符号形态）")

    // 电池形态-7：override 在位时 plugged **不**回退 isCharging（external=false
    // 即 false——回退仅 override 整体 nil 时可达）；拔电瞬间边界（external=false
    // ∧ charging=true）的 bolt 由 charging 字段直驱（badgePath charging 优先），
    // 徽标不丢。钉死链的真实形状，与 0.18 原实现逐字段等价。
    check(isForm(
        menuBarBatteryForm(
            snapshotPercent: nil, snapshotIsCharging: nil, snapshotExternalConnected: nil,
            powerOverride: PowerOverride(externalConnected: false, isCharging: true),
            daemonPercent: 61),
        61, true, false), "电池形态-7", "override 在位：plugged 不回退 isCharging，bolt 由 charging 直驱不丢")

    // 电池形态-8：percent 直通不钳制（钳制在位图渲染层 drawBatteryBody——
    // 钉死分层，防链内加钳制造成回退形态分歧）。
    check(isForm(
        menuBarBatteryForm(
            snapshotPercent: nil, snapshotIsCharging: nil, snapshotExternalConnected: nil,
            powerOverride: PowerOverride(externalConnected: true, isCharging: false),
            daemonPercent: 0),
        0, false, true), "电池形态-8", "daemonPercent=0 直通（钳制归渲染层）")
}