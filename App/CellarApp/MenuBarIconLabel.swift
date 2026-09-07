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
    /// 失效也不丢语义）；其余分支不加全局 foregroundStyle 保持 template 跟随
    /// 系统菜单栏着色。百分比文字各分支同附加（间距 3pt）。
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
            // 电池电量形态（0.18.7 第六轮：**自绘位图单 Image**——spike 实证路线）。
            // 五轮实证收敛：菜单栏 label 管道从 label 视图只提取「单 Image + 单
            // Text」，多 Image 层全被丢弃（0.18.6 双 Image 平铺复现）——但
            // `Image(nsImage:)` 自绘位图**整体渲染**且非模板位图**显色**（本机
            // spike A-G 七形态对照实证）。因此电量轮廓 + 连续比例填充 + 状态徽标
            // （充电 bolt/维持 plug 合成进位图）+ 低电量红全部画进一张位图，
            // 连续填充与 demo 设计形态就此回归（0.18.6 五档量化退役）。
            HStack(spacing: 3) {
                Image(nsImage: MenuBarBatteryIconRenderer.image(
                    percent: battery.percent,
                    charging: battery.charging,
                    plugged: battery.plugged,
                    low: battery.percent < Self.lowBatteryThresholdPercent))
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

/// 菜单栏电池位图渲染器（0.18.7 第六轮）。
///
/// **为什么是位图**（六轮真机/spike 实证链的终点）：菜单栏 label 渲染管道从
/// label 视图只提取「单 Image + 单 Text」，第二个及以后的 Image 一律丢弃
/// （0.18.6 双 Image 平铺复现实锤）；variableValue（恒满格）/Canvas（不渲染）/
/// frame+clipped（层丢弃）各版本先后失败。本机 spike 七形态对照实证：
/// `Image(nsImage:)` 自绘位图**整体渲染**、位图内合成元素**全部可见**、
/// 非模板彩色位图**显色**——连续比例填充 + 状态徽标 + 低电量红在此路线全部可行。
///
/// 布局（pt，AppKit y 向上）：画布 26×16.5；电池本体轮廓 20.6×12.1 圆角矩形 +
/// 右侧端子；内腔填充按电量**连续比例**（x 起点 2.8，满宽 16.4）；状态徽标
/// 叠在右上角（充电 bolt / 外接维持 plug，先 destinationOut 挖出透明环再填
/// 形状——徽标与填充/轮廓之间留出对比缝隙，任何填充量下都可读）。
///
/// 着色：常规态 `isTemplate = true`（纯 alpha 掩膜，跟随菜单栏明暗着色）；
/// 低电量态非模板 + systemRed 实绘（spike G 实证显色）。
///
/// @MainActor：仅被 View body（主线程）调用；Swift 6 严格并发下缓存随之
/// 主线程隔离，无需额外锁。
@MainActor
private enum MenuBarBatteryIconRenderer {
    /// 位图缓存键（label 刷新频繁，同参数复用；参数域有界，字典容量无虞）。
    private struct Key: Hashable {
        let percent: Int, charging: Bool, plugged: Bool, low: Bool
    }

    private static var cache: [Key: NSImage] = [:]

    static func image(percent: Int, charging: Bool, plugged: Bool, low: Bool) -> NSImage {
        let key = Key(percent: percent, charging: charging, plugged: plugged, low: low)
        if let hit = cache[key] { return hit }
        let image = draw(key)
        cache[key] = image
        return image
    }

    // MARK: - 绘制

    private static func draw(_ key: Key) -> NSImage {
        let canvas = NSSize(width: 26, height: 16.5)
        let scale: CGFloat = 2 // Retina 2x 背衬（point 尺寸不变，位图像素翻倍）
        let tint = key.low ? NSColor.systemRed : NSColor.black
        let image = NSImage(size: canvas)
        image.addRepresentation(bitmapRepresentation(canvas: canvas, scale: scale) {
            drawBatteryBody(key: key, tint: tint)
            drawStatusBadge(key: key, tint: tint)
        })
        image.isTemplate = !key.low
        return image
    }

    /// 电池本体：轮廓描边 + 端子 + 内腔连续比例填充（percent 钳制 0...100）。
    private static func drawBatteryBody(key: Key, tint: NSColor) {
        tint.setStroke()
        tint.setFill()
        let body = NSBezierPath(roundedRect: NSRect(x: 0.7, y: 0.7, width: 20.6, height: 12.1),
                                xRadius: 3.2, yRadius: 3.2)
        body.lineWidth = 1.4
        body.stroke()
        NSBezierPath(roundedRect: NSRect(x: 22.3, y: 4.5, width: 2.4, height: 4.5),
                     xRadius: 1.2, yRadius: 1.2).fill()
        let fraction = CGFloat(max(0, min(100, key.percent))) / 100
        let fillWidth = 16.4 * fraction
        guard fillWidth >= 1.5 else { return } // 过窄不画，空腔语义
        NSBezierPath(roundedRect: NSRect(x: 2.8, y: 2.8, width: fillWidth, height: 7.9),
                     xRadius: 1.6, yRadius: 1.6).fill()
    }

    /// 状态徽标：充电中 bolt；外接未充电（维持/停充）plug；电池供电无。
    /// 先以 destinationOut 挖出透明环（与填充/轮廓的对比缝隙），再填徽标
    /// 形状——保证任何填充量下徽标可读（0.18.4 挖孔悬空教训）。合成操作走
    /// NSGraphicsContext 全局设置（NSBezierPath 无逐路径合成参数）。
    private static func drawStatusBadge(key: Key, tint: NSColor) {
        let badge = badgePath(charging: key.charging, plugged: key.plugged)
        guard !badge.isEmpty, let context = NSGraphicsContext.current else { return }
        context.compositingOperation = .destinationOut
        NSColor.black.setFill()
        badge.lineWidth = 2.2
        badge.stroke()
        badge.fill()
        context.compositingOperation = .sourceOver
        tint.setFill()
        badge.fill()
    }

    /// 徽标路径（空 = 无徽标）。
    private static func badgePath(charging: Bool, plugged: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        if charging {
            // 闪电（7 点多边形，右上角朝上收尖）。
            path.move(to: NSPoint(x: 22.5, y: 16.1))
            path.line(to: NSPoint(x: 18.9, y: 11.1))
            path.line(to: NSPoint(x: 20.9, y: 11.1))
            path.line(to: NSPoint(x: 20.0, y: 7.9))
            path.line(to: NSPoint(x: 23.9, y: 12.5))
            path.line(to: NSPoint(x: 21.8, y: 12.5))
            path.line(to: NSPoint(x: 23.2, y: 16.1))
            path.close()
        } else if plugged {
            // 电源插头：本体 + 双脚（朝下插向电池）+ 顶部线缆短桩。
            path.append(NSBezierPath(roundedRect: NSRect(x: 19.3, y: 10.6, width: 4.8, height: 3.4),
                                     xRadius: 1.5, yRadius: 1.5))
            path.append(NSBezierPath(roundedRect: NSRect(x: 20.3, y: 8.1, width: 0.85, height: 2.6),
                                     xRadius: 0.4, yRadius: 0.4))
            path.append(NSBezierPath(roundedRect: NSRect(x: 21.95, y: 8.1, width: 0.85, height: 2.6),
                                     xRadius: 0.4, yRadius: 0.4))
            path.append(NSBezierPath(roundedRect: NSRect(x: 21.15, y: 13.8, width: 1.1, height: 1.7),
                                     xRadius: 0.55, yRadius: 0.55))
        }
        return path
    }

    // MARK: - 位图基建

    /// 建立位图上下文并执行绘制（**rep.size 必须回设 point 尺寸**——否则像素
    /// 被按 point 解释导致图标 2 倍过大；2x 建立失败回退 1x）。
    private static func bitmapRepresentation(
        canvas: NSSize, scale: CGFloat, draw: @escaping () -> Void
    ) -> NSBitmapImageRep {
        for attemptScale in [scale, 1 as CGFloat] {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * attemptScale),
                pixelsHigh: Int(canvas.height * attemptScale), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            guard let rep, let ctx = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            rep.size = canvas
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.cgContext.scaleBy(x: attemptScale, y: attemptScale)
            draw()
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        // 不可达兜底（固定参数分配不可能失败）：返回 1px 空 rep，渲染为不可见
        // （与缺失符号同等降级），不崩溃。
        return NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    }
}

