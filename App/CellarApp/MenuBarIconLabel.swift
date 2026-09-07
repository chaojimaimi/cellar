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
            // 电池电量形态（0.18.4 第四轮渲染方案）：**双层 SF Symbols 裁剪**——
            // 底层空腔轮廓（恒显示）+ 顶层满格电池按电量比例宽度裁剪。渲染路径
            // 全 Image（0.17 以来在产机制，无 Canvas/variableValue 依赖——前者
            // 菜单栏 label 不渲染、后者 template 单色下恒满格，两轮教训）。
            HStack(spacing: 3) {
                batteryGlyph(percent: battery.percent,
                             charging: battery.charging,
                             plugged: battery.plugged)
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

    /// 电池电量图标（0.18.4 第四轮：**双层 SF Symbols 裁剪**——替代两轮失败的
    /// variableValue/Canvas 路线）：
    /// - 底层 `battery.0percent` = 空腔轮廓（恒全宽显示）；
    /// - 顶层 `battery.100percent`（满格填充）按电量比例宽度裁剪——「裁剪显示」
    ///   是纯 SwiftUI frame/clipped 机制，不依赖 variable 渲染与 Canvas；
    /// - 充电中叠 bolt 徽标；外接未充电（维持）叠 plug 徽标；电池供电无徽标；
    /// - 低电量（< Self.lowBatteryThresholdPercent = 15 具名常量）转红
    ///   （.renderingMode(.original) 照 alert 先例——彩色告警在产）；其余
    ///   template 单色跟随菜单栏。
    ///
    /// 低电量阈值常量 `lowBatteryThresholdPercent = 15`（struct 顶部声明）。
    ///
    /// 尺寸基准：font 13pt 下 battery 符号总宽 ≈ 25pt、内腔填充区 ≈ 18pt
    /// （估算值——真机走查校准点；偏大则填充早于 100% 顶满）。
    @ViewBuilder
    private func batteryGlyph(percent: Int, charging: Bool, plugged: Bool) -> some View {
        let low = percent < Self.lowBatteryThresholdPercent
        let bodyFont = Font.system(size: 13)
        // 内腔填充裁剪宽（符号总宽 25 × 内腔占比 ~0.72 × 电量比）。
        let fillW = 25.0 * 0.72 * Double(percent) / 100
        ZStack(alignment: .leading) {
            // 底：空腔轮廓（恒全宽）。
            Image(systemName: "battery.0percent")
                .font(bodyFont)
            // 上：满格填充层，裁剪至电量比例宽度（leading 对齐显左侧部分）。
            Image(systemName: "battery.100percent")
                .font(bodyFont)
                .frame(width: fillW, height: 15, alignment: .leading)
                .clipped()
            // 状态徽标（右上角；电池供电无）。
            HStack {
                Spacer(minLength: 0)
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold))
                } else if plugged {
                    Image(systemName: "plug.fill").font(.system(size: 7, weight: .semibold))
                }
            }
            .offset(x: 1, y: -5)
        }
        .foregroundStyle(low ? Color.red : .primary)
        .accessibilityLabel(CellarL10n.s("common.axMenuBarIcon"))
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
