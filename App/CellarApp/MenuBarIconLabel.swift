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
    /// 低电量告警阈值（%）——填充与徽标转红的判定点（具名常量集中调整）。
    static let lowBatteryThresholdPercent = 15
    /// 电池主符号字号（0.18.4 以来沿用基准）。
    private static let glyphFont = Font.system(size: 13)
    /// 状态徽标字号（闪电/插头同为加粗——0.18.6 统一，删逐态 weight 分叉）。
    private static let badgeFont = Font.system(size: 8, weight: .bold)
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
    /// 失效也不丢语义）；其余分支不加全局 foregroundStyle 保持 template 跟随
    /// 系统菜单栏着色（电池分支内部的低电量红色分叉除外——0.18.6）。百分比
    /// 文字各分支同附加（间距 3pt；电池分支 2pt——0.18.6 徽标平铺后收紧）。
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
            // 电池电量形态（0.18.6 第五轮渲染方案）：**五档符号就近映射 + 徽标
            // HStack 平铺**。渲染纪律（五轮真机实证收敛的硬边界）——菜单栏 label
            // 管道只渲染裸 Image/Text + HStack 平铺：variableValue ✗（恒满格）、
            // Canvas ✗（整只不渲染，0.18.4）、frame/clipped 裁剪层 ✗ 与
            // ZStack/offset 覆盖徽标 ✗（0.18.5 真机截图实证：只有底层空腔轮廓
            // 上屏）。因此电量填充走五档离散符号（连续填充无可用机制，NSImage
            // 位图路线留待 spike 实证后再评估），徽标与文字全部同级平铺。
            HStack(spacing: 2) {
                if battery.percent < Self.lowBatteryThresholdPercent {
                    // 低电量转红：.renderingMode(.original) + foregroundStyle
                    // 照 alert 分支在产先例（彩色告警唯一实证路径）。renderingMode
                    // 是 Image 专属修饰符——必须紧跟 Image 调用（font 之后即失配）。
                    Image(systemName: quantizedBatterySymbolName(battery.percent))
                        .renderingMode(.original)
                        .font(Self.glyphFont)
                        .foregroundStyle(Color.red)
                        .accessibilityLabel(CellarL10n.s("common.axMenuBarIcon"))
                    if let badge = statusBadgeName(charging: battery.charging,
                                                   plugged: battery.plugged) {
                        Image(systemName: badge)
                            .renderingMode(.original)
                            .font(Self.badgeFont)
                            .foregroundStyle(Color.red)
                            .accessibilityHidden(true)
                    }
                } else {
                    Image(systemName: quantizedBatterySymbolName(battery.percent))
                        .font(Self.glyphFont)
                        .accessibilityLabel(CellarL10n.s("common.axMenuBarIcon"))
                    if let badge = statusBadgeName(charging: battery.charging,
                                                   plugged: battery.plugged) {
                        Image(systemName: badge)
                            .font(Self.badgeFont)
                            .accessibilityHidden(true)
                    }
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

    /// 电量 → 五档符号就近映射（阈值 12.5/37.5/62.5/87.5，最大误差 ±12.5%：
    /// 80% → 75percent，不顶满也不落空）。全族 SF Symbols 1.0 起在档，五档
    /// 名 macOS 26 本机 NSImage 探测实测全在位——静态表无需回退链。
    private func quantizedBatterySymbolName(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// 状态徽标符号名（nil = 无徽标）：充电中 → bolt.fill；外接未充电（维持/
    /// 停充）→ powerplug.fill；电池供电无徽标。**plug.fill 在 macOS 26 不存在**
    /// （0.18.5 徽标消失的第二根因——NSImage 探测 MISSING），改用实测在位的
    /// powerplug.fill；符号经运行时存在性校验，缺失降级为无徽标不伤本体
    /// （powerplug.slash 验收事故同款守卫）。
    private func statusBadgeName(charging: Bool, plugged: Bool) -> String? {
        let candidate: String?
        if charging {
            candidate = "bolt.fill"
        } else if plugged {
            candidate = "powerplug.fill"
        } else {
            candidate = nil
        }
        guard let candidate,
              NSImage(systemSymbolName: candidate, accessibilityDescription: nil) != nil
        else { return nil }
        return candidate
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
