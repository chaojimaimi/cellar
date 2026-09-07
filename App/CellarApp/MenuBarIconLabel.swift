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
            // 充电态 bolt 小徽标叠加（R2：bolt 单体变体不支持 variableValue 恒满格
            // ——改连续填充电池 + 徽标承载充电语义；template 渲染下徽标同色）。
            HStack(spacing: 3) {
                if battery.charging {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: battery.name, variableValue: battery.variableValue)
                            .accessibilityLabel(CellarL10n.s("common.axMenuBarIcon"))
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8, weight: .bold))
                            .offset(x: 3, y: -2)
                    }
                } else {
                    Image(systemName: battery.name, variableValue: battery.variableValue)
                        .accessibilityLabel(CellarL10n.s("common.axMenuBarIcon"))
                }
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
    /// powerOverride?.isCharging ?? false`（powerOverride 经 IOPS 恒新鲜）。
    private var batteryForm: (name: String, variableValue: Double?, charging: Bool)? {
        guard let percent = controller.batterySnapshot?.percent
                ?? controller.daemonStatus?.lastPercent else { return nil }
        let isCharging = controller.batterySnapshot?.isCharging
            ?? (controller.powerOverride?.isCharging ?? false)
        return resolvedBatterySymbol(percent: percent, isCharging: isCharging)
    }

    /// 电池符号解析（三级回退纪律承接自 MainWindowView.resolvedBatterySymbol——
    /// 该实现随 brandHeader 图标移除已退役、本方法为其唯一存续点；候选表静态维护
    /// 不可靠，主选不存在时 NSImage(systemSymbolName:) 探测降级，保证恒有可见
    /// 字形）：**全状态统一 `battery.100percent` + variableValue 连续
    /// 填充**（0.18.3 修正——充电态原走 `battery.100percent.bolt` 单体变体，该
    /// 符号不支持 variableValue 恒显满格，用户走查实测反馈；充电语义改由 bolt
    /// 小徽标叠加承载，放电/维持自然由填充电量表达）→ 离散档位 battery.0/25/
    /// 50/75/100（variableValue 不被档位符号消费，传 nil）→ 终极兜底 circle.dashed。
    private func resolvedBatterySymbol(percent: Int, isCharging: Bool) -> (name: String, variableValue: Double?, charging: Bool) {
        func exists(_ symbol: String) -> Bool {
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        }
        let variable = "battery.100percent"
        if exists(variable) { return (variable, Double(percent) / 100, isCharging) }
        // 回退离散档位。
        let discrete: String
        switch percent {
        case ..<13: discrete = "battery.0percent"
        case ..<38: discrete = "battery.25percent"
        case ..<63: discrete = "battery.50percent"
        case ..<88: discrete = "battery.75percent"
        default: discrete = "battery.100percent"
        }
        if exists(discrete) { return (discrete, nil, isCharging) }
        return ("circle.dashed", nil, false)
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
