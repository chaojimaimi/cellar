import AppKit
import CellarCore
import CellarUI
import SwiftUI

/// 菜单栏动态图标（规格 §2.2 多状态符号 + alert 变色增强）。
///
/// label closure 内的专用视图：观察 StatusController（iconState 推导）与
/// DisplaySettingsController（v1.10 M2 电量百分比显隐；v1.11 T2 改名扩位）两个
/// 控制器——状态刷新不依赖面板窗口的生命周期（组合根提升后控制器在 App 层常驻）。
///
/// ⚠️ 状态源接线定案（v1.10 M2 工单 T1-4）：百分比显隐走**第二个 @ObservedObject
/// 直注**，不走 StatusController 弱引用——@ObservedObject 只订阅自身持有的对象，
/// weak 挂靠不产生 objectWillChange 传播；双控制器注入是更新传播正确性的最小形态。
struct MenuBarIconLabel: View {
    @ObservedObject var controller: StatusController
    /// 显示设置（电量百分比显隐；CellarApp label 闭包注入——组合根组合两观察源）。
    @ObservedObject var settings: DisplaySettingsController
    @Environment(\.cellarTheme) private var theme

    var body: some View {
        labelContent
    }

    /// 运行时存在性解析（验收事故回归）：候选表静态维护不可靠——powerplug.slash
    /// 在 macOS 26 不存在，Image(systemName:) 渲染为空 = 图标整只消失且无任何报错。
    /// 主选 → 回退 → 终极兜底三级降级，保证恒有可见字形。
    private func resolvedSymbol(for state: MenuBarIconState) -> String {
        let primary = menuBarSymbolName(for: state)
        if NSImage(systemSymbolName: primary, accessibilityDescription: nil) != nil {
            return primary
        }
        let fallback = menuBarSymbolFallbackName(for: state)
        if NSImage(systemSymbolName: fallback, accessibilityDescription: nil) != nil {
            return fallback
        }
        return "circle.dashed"
    }

    /// alert 态非 template 着色增强（形状为主、颜色为辅——模板模式下 tint
    /// 失效也不丢语义）；其余状态不加 foregroundStyle，保持 template 渲染
    /// 跟随系统菜单栏着色。百分比文字各分支同附加（间距 3pt）。
    ///
    /// 0.18 T3 D-3c 三分支：alert 保留原符号（告警语义优先，电池形态不遮蔽
    /// 失联告警）→ 电池电量形态（开关开 ∧ percent 取值链有值）→ 现状 iconState
    /// 符号（默认，与 0.17 逐字节一致）。
    @ViewBuilder
    private var labelContent: some View {
        if controller.iconState == .alert {
            HStack(spacing: 3) {
                Image(systemName: resolvedSymbol(for: controller.iconState))
                    .renderingMode(.original)
                    .foregroundStyle(theme.alert)
                    .accessibilityLabel(CellarL10n.s("common.axMenuBarIcon"))
                percentageText
            }
        } else if settings.menuBarBatteryIconVisible, let battery = batteryForm {
            // 自绘电池图形（0.18.4）：SF Symbols variableValue 在菜单栏 template
            // 单色渲染下填充不可见（两轮恒满格根因）——弃符号走自绘几何，状态
            // 标识（充电 ⚡ / 维持插头）入电池挖空呈现；低电量红填充告警。
            HStack(spacing: 3) {
                MenuBatteryGlyph(
                    percent: battery.percent,
                    charging: battery.charging,
                    plugged: battery.plugged
                )
                .accessibilityLabel(CellarL10n.s("common.axMenuBarIcon"))
                percentageText
            }
        } else {
            HStack(spacing: 3) {
                Image(systemName: resolvedSymbol(for: controller.iconState))
                    .accessibilityLabel(CellarL10n.s("common.axMenuBarIcon"))
                percentageText
            }
        }
    }

    /// 电池电量形态解析（0.18 T3 D-3c；nil = 回退现状 iconState 符号——label
    /// 必须恒渲染）：percent 取值链 `batterySnapshot?.percent ??
    /// daemonStatus?.lastPercent`（percentageText 同源先例——全表面不可见时遥测
    /// 循环不启动、batterySnapshot 冷启动恒 nil，daemonStatus 60s 轮询恒新鲜；
    /// 双 nil → nil 回退）；isCharging 取值链 `batterySnapshot?.isCharging ??
    /// powerOverride?.isCharging ?? false`；plugged 取值链
    /// `batterySnapshot?.externalConnected ?? isCharging`（external 缺席时以
    /// 充电态近似——保守方向，充电必外接）。
    private var batteryForm: (percent: Int, charging: Bool, plugged: Bool)? {
        guard let percent = controller.batterySnapshot?.percent
                ?? controller.daemonStatus?.lastPercent else { return nil }
        let isCharging = controller.batterySnapshot?.isCharging
            ?? (controller.powerOverride?.isCharging ?? false)
        // plugged 链（code-review P2-1）：externalConnected 缺席时走在产的
        // powerOverride.externalConnected（IOPS 恒新鲜、非可选）——跳过它会让
        // 冷启动/表面全关时维持态不可达、陈旧快照反向胜出。
        let plugged = controller.batterySnapshot?.externalConnected
            ?? (controller.powerOverride?.externalConnected ?? isCharging)
        return (percent, isCharging, plugged)
    }

    /// 电量百分比（v1.10 M2）：开关开 ∧ daemonStatus.lastPercent 非 nil 才渲染
    /// （断连/旧 daemon 无数字）；等宽数字防宽度抖动。**不加 foregroundStyle**
    /// ——跟随系统菜单栏模板着色，与图标 template 渲染语义一致。
    @ViewBuilder
    private var percentageText: some View {
        if settings.percentageVisible, let percent = controller.daemonStatus?.lastPercent {
            Text("\(percent)").monospacedDigit()
        }
    }
}
