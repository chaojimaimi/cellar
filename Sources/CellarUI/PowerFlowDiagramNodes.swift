import SwiftUI

// MARK: - 功率流三角图：节点层 Canvas 绘制与 AX 摘要（与 PowerFlowDiagramView.swift
// 拆分——红线 6 文件 ≤400 行；同类型 internal extension）
//
// v1.2 走查批 F2：节点卡改 **Canvas 测量驱动**——布局阶段 resolve+measure 两行
// 文字测宽定卡宽（修「在位」「12.1 V」超出卡边框：旧实现卡宽固定比例、文字按
// 缩放字号直接 draw，无测量/无截断）；F3 语义统一（holding 直供边流动、nodata
// 三灰卡无连线——语义见 View 侧 canvasLayer）。
//
// M3.5 修复遗留说明：节点层由 SwiftUI 视图（.position/.frame 归一化定位，真窗
// 破损）改为 GraphicsContext 绘制——与边层同 Canvas 单坐标系，消除视图定位路径。

extension PowerFlowDiagramView {
    // MARK: - 节点层（Canvas 单坐标系）

    /// 节点字号/几何缩放（P0-1 修复：去 1.0 下限 → width ≤ 896 时 scale ≡
    /// unitX=width/560 **全域统一缩放**——旧实现 1.0 下限使窄域（默认窗侧栏场景
    /// 流图内宽 ~368，unitX=0.658）卡几何按 unitX 压缩而文字按原尺寸绘制，双
    /// 坐标系分裂 → 走查原始溢出缺陷复现；560pt 快照恒 1.0 故三门全绿未拦。
    /// 取舍：字号下限让位于全域统一缩放——溢出比字小更不可接受；> 896 封顶
    /// 1.6（宽窗「排版松散」治理保留）。
    static func nodeScale(for width: CGFloat) -> CGFloat {
        min(width / 560, 1.6)
    }

    // MARK: F2 自适应几何常量（全部 mock viewBox 560×244 归一化坐标系单位）

    /// 卡锚点（F2 §2.2）：适配器左缘固定向右长 / 系统右缘固定向左长 / 电池
    /// 中线固定对称长；卡高与顶 y 恒 mock 值（只动宽度）。
    static let adapterMinX: CGFloat = 24
    static let systemMaxX: CGFloat = 536
    static let batteryMidX: CGFloat = 280
    static let topCardsY: CGFloat = 18
    static let batteryY: CGFloat = 164
    static let cardHeight: CGFloat = 62

    /// 图标区块宽 = 10 + 26 + 10（卡左缘 padding + 图标圈径 + 文字间距，×scale）。
    static let iconBlockUnits: CGFloat = 46
    /// 卡宽下限 = mock 比例宽 × 0.8（F2 §2.3——短文本不塌成贴字窄条）。
    static let minCardWidthUnits: CGFloat = 136 * 0.8
    /// 卡宽上限 = 相邻间隙可用宽 − 12（F2 §2.3；12 = 直供边/曲线呼吸空间）：
    /// 顶排两卡互以对方 mock 位为界（400−24−12 / 536−160−12 = 364）；电池
    /// 对称增长至左右间隙各留 6（min(280−160, 400−280) − 6 → 2×114 = 228）。
    static let adapterMaxWidthUnits: CGFloat = 400 - 24 - 12
    static let systemMaxWidthUnits: CGFloat = 536 - 160 - 12
    static let batteryMaxWidthUnits: CGFloat = 2 * (min(280 - 160, 400 - 280) - 6)

    /// 单节点卡布局（布局阶段产出，绘制阶段按布局落笔——两行文字已测宽定宽，
    /// 副行可能已收缩字号/硬截断）。
    struct CardLayout {
        let rect: CGRect            // 最终卡 rect（容器坐标，锚点按卡型固定）
        let title: String
        let subline: String         // 可能已硬截断（含 …）
        let sublineSize: CGFloat    // 副行字号（viewBox 单位；10.5 起逐级收缩，下限 9）
        let icon: String
        let emphasized: Bool
        let dimmed: Bool
    }

    /// 三卡布局集合（边层端点推导消费——F2 §2.4 全部由最终卡 rect 出）。
    struct CardLayouts {
        let adapter: CardLayout
        let system: CardLayout
        let battery: CardLayout
    }

    private enum HorizontalPin { case leading, trailing, center }

    /// 三卡布局入口（F2 §2.1/§2.3）：标题/副行照绘制同款样式 resolve+measure
    /// （宽窗 scale 下测值 / scale = viewBox 单位——字号线性缩放，测宽线性成立）；
    /// 内容宽 = 图标区块 + max(两行)，卡宽 = clamp(内容宽, 108.8 下限, 各卡上限)。
    func layoutCards(context: inout GraphicsContext, size: CGSize, scale: CGFloat) -> CardLayouts {
        CardLayouts(
            adapter: layoutCard(
                context: &context, size: size, scale: scale,
                pin: .leading, pinX: Self.adapterMinX, topY: Self.topCardsY,
                maxWidthUnits: Self.adapterMaxWidthUnits,
                title: CellarL10n.s("statusline.adapter"),
                subline: state == .nodata ? CellarL10n.s("common.nodata") : adapterLine,
                icon: "bolt.fill", emphasized: false,
                dimmed: state == .battery || state == .nodata
            ),
            system: layoutCard(
                context: &context, size: size, scale: scale,
                pin: .trailing, pinX: Self.systemMaxX, topY: Self.topCardsY,
                maxWidthUnits: Self.systemMaxWidthUnits,
                title: CellarL10n.s("flow.node.system"),
                subline: state == .nodata ? CellarL10n.s("common.nodata") : systemLine,
                icon: "laptopcomputer", emphasized: false,
                dimmed: state == .nodata
            ),
            // 电池 = 主角位（mock 强调卡：accent 描边 + 微暖底；nodata 降档）。
            // P3-2：非 nodata 且 percent 缺席（字段缺失）→ 显「—」，禁止造 0%。
            battery: layoutCard(
                context: &context, size: size, scale: scale,
                pin: .center, pinX: Self.batteryMidX, topY: Self.batteryY,
                maxWidthUnits: Self.batteryMaxWidthUnits,
                title: CellarL10n.s("flow.node.battery"),
                subline: state == .nodata || batteryPercent == nil
                    ? CellarL10n.s("common.nodata")
                    : CellarL10n.s("flow.batterySubline", batteryPercentText, batteryVoltage),
                icon: "battery.75", emphasized: state != .nodata,
                dimmed: state == .nodata
            )
        )
    }

    /// 单卡布局：测宽 → 定宽（clamp）→ 副行溢出兜底（收缩/截断）→ 按锚点
    /// 构建最终 rect。WHY 布局与绘制分离：卡宽决定三边端点（F2 §2.4 动态推导），
    /// 端点必须先于边层绘制——同一 Canvas 内一次性测完再画。
    private func layoutCard(
        context: inout GraphicsContext, size: CGSize, scale: CGFloat,
        pin: HorizontalPin, pinX: CGFloat, topY: CGFloat, maxWidthUnits: CGFloat,
        title: String, subline: String, icon: String,
        emphasized: Bool, dimmed: Bool
    ) -> CardLayout {
        let unitX = size.width / 560
        let unitY = size.height / 244

        // 测宽（viewBox 单位）：与绘制同款样式（标题 semibold / 副行 monospacedDigit）。
        let titleUnits = measureWidth(
            context: &context, scale: scale,
            Text(title).font(.system(size: 12 * scale, weight: .semibold))
        )
        let sublineUnits = measureWidth(
            context: &context, scale: scale,
            Text(subline).font(.system(size: 10.5 * scale)).monospacedDigit()
        )
        let contentUnits = Self.iconBlockUnits + max(titleUnits, sublineUnits)
        let widthUnits = min(max(contentUnits, Self.minCardWidthUnits), maxWidthUnits)

        // 副行兜底（F2 §2.5）：容量 = 卡宽 − 图标区块；溢出 → 字号 0.25 步进收缩
        // （下限 9pt）→ 仍溢出逐字截断加 …（上限钳制后卡宽不再增长，副行向内适配）。
        let capacityUnits = widthUnits - Self.iconBlockUnits
        let fitted = fitSubline(context: &context, text: subline, capacityUnits: capacityUnits, scale: scale)

        // 锚点定 rect（points）：leading 右长 / trailing 左长 / center 对称。
        let heightUnits = Self.cardHeight
        let originX: CGFloat
        switch pin {
        case .leading: originX = pinX * unitX
        case .trailing: originX = pinX * unitX - widthUnits * unitX
        case .center: originX = pinX * unitX - widthUnits * unitX / 2
        }
        return CardLayout(
            rect: CGRect(x: originX, y: topY * unitY, width: widthUnits * unitX, height: heightUnits * unitY),
            title: title, subline: fitted.text, sublineSize: fitted.sizeUnits,
            icon: icon, emphasized: emphasized, dimmed: dimmed
        )
    }

    /// 测文本宽（points → viewBox 单位：除以 scale——字号随 scale 线性缩放）。
    private func measureWidth(context: inout GraphicsContext, scale: CGFloat, _ text: Text) -> CGFloat {
        context.resolve(text)
            .measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            .width / scale
    }

    /// 副行溢出兜底（F2 §2.5）：容量内原样；溢出 → 字号 0.25 步进收缩（下限
    /// 9pt）；9pt 仍溢出 → 逐字截断加「…」（9pt 测量判定，恒收敛——「…」单字
    /// 必小于容量）。
    private func fitSubline(
        context: inout GraphicsContext, text: String, capacityUnits: CGFloat, scale: CGFloat
    ) -> (text: String, sizeUnits: CGFloat) {
        func width(_ candidate: String, sizeUnits: CGFloat) -> CGFloat {
            measureWidth(
                context: &context, scale: scale,
                Text(candidate).font(.system(size: sizeUnits * scale)).monospacedDigit()
            )
        }
        if width(text, sizeUnits: 10.5) <= capacityUnits { return (text, 10.5) }
        var sizeUnits = 10.5
        while sizeUnits > 9 {
            sizeUnits -= 0.25
            if width(text, sizeUnits: sizeUnits) <= capacityUnits { return (text, sizeUnits) }
        }
        var prefix = text
        while !prefix.isEmpty {
            let candidate = prefix + "…"
            if width(candidate, sizeUnits: 9) <= capacityUnits { return (candidate, 9) }
            prefix.removeLast()
        }
        return ("…", 9)
    }

    /// 三节点卡全量绘制（与旧 nodeLayer 同判定：适配器/系统常态、电池主角位
    /// 强调、nodata 全降档；dimmed 整卡降档由 context.opacity 承载——布局已在
    /// layoutCards 完成，本步纯落笔）。
    func drawNodes(context: inout GraphicsContext, scale: CGFloat, cards: CardLayouts) {
        drawNodeCard(context: &context, scale: scale, layout: cards.adapter)
        drawNodeCard(context: &context, scale: scale, layout: cards.system)
        drawNodeCard(context: &context, scale: scale, layout: cards.battery)
    }

    /// 单节点卡 Canvas 绘制（旧 nodeCard 的 GraphicsContext 等价）：
    /// - 卡底/描边 = Path(roundedRect).fill/.stroke（圆角 12 ×scale 随容器）；
    /// - 图标圈 = Path(ellipseIn) 填充 + `context.draw(Text(Image(systemName:))…,
    ///   at:anchor: .center)`（SF Symbol 经 Text 内嵌保类型——GraphicsContext
    ///   draw 无 Image 候选，符号按 Text 字号渲染、随 scale 缩放，确定性成立）；
    /// - 两行文字 = `context.draw(Text, at:anchor: .leading)`——行高按 SF 系统
    ///   字体度量近似（字号 × 1.2），两行 + 2×scale 间距整块垂直居中于卡
    ///   （旧 VStack(spacing: 2) 布局语义）；副行字号/文本经 F2 兜底已定
    ///   （layout.sublineSize/layout.subline）；
    /// - 卡内全部几何 ×scale（宽窗比例贴近 mock）；dimmed 整卡降档（opacity
    ///   在卡底前设置——含底/描边/内容全部降档，与旧 .opacity 施加点一致）。
    func drawNodeCard(context: inout GraphicsContext, scale: CGFloat, layout: CardLayout) {
        let rect = layout.rect
        let cardPath = Path(roundedRect: rect, cornerRadius: 12 * scale)
        context.opacity = layout.dimmed ? 0.45 : 1
        context.fill(cardPath, with: .color(nodeFill(emphasized: layout.emphasized)))
        context.stroke(cardPath, with: .color(nodeBorder(emphasized: layout.emphasized)))

        let iconDiameter = 26 * scale
        let iconCenter = CGPoint(
            x: rect.minX + 10 * scale + iconDiameter / 2, y: rect.midY
        )
        let iconCircle = CGRect(
            x: iconCenter.x - iconDiameter / 2, y: iconCenter.y - iconDiameter / 2,
            width: iconDiameter, height: iconDiameter
        )
        context.fill(Path(ellipseIn: iconCircle), with: .color(iconTint(layout.icon).opacity(0.12)))
        context.draw(
            Text(Image(systemName: layout.icon))
                .font(.system(size: 12 * scale, weight: .medium))
                .foregroundColor(iconTint(layout.icon)),
            at: iconCenter, anchor: .center
        )

        let titleSize = 12 * scale
        let sublineSize = layout.sublineSize * scale
        let titleHeight = titleSize * 1.2
        let sublineHeight = sublineSize * 1.2
        let blockHeight = titleHeight + 2 * scale + sublineHeight
        let textX = rect.minX + 10 * scale + iconDiameter + 10 * scale
        let titleCenter = CGPoint(
            x: textX, y: rect.midY - blockHeight / 2 + titleHeight / 2
        )
        let sublineCenter = CGPoint(
            x: textX, y: rect.midY + blockHeight / 2 - sublineHeight / 2
        )
        context.draw(
            Text(layout.title)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundColor(theme.secondaryText),
            at: titleCenter, anchor: .leading
        )
        context.draw(
            Text(layout.subline)
                .font(.system(size: sublineSize))
                .monospacedDigit()
                .foregroundColor(theme.tertiaryText),
            at: sublineCenter, anchor: .leading
        )
        context.opacity = 1
    }

    /// 图标着色：适配器/电池 accent（主角位），系统 always secondary——
    /// mock 的系统图标恒 ink2 灰（适配器灰仅电池态由整卡降档承载）。
    func iconTint(_ icon: String) -> Color {
        if state == .nodata { return theme.secondaryText }
        return icon == "laptopcomputer" ? theme.secondaryText : theme.accent
    }

    /// 节点底色：主角位（电池）accent 微底；其余 secondaryText 微底——mock
    /// surface3/surface2 无独立 token，取既有 token 降档近似（风格 C 留位）。
    func nodeFill(emphasized: Bool) -> Color {
        if state == .nodata { return theme.secondaryText.opacity(0.06) }
        return emphasized ? theme.accent.opacity(0.08) : theme.secondaryText.opacity(0.08)
    }

    /// 节点描边：主角位 accent 混边；其余 line2 近似（secondaryText 降档）。
    func nodeBorder(emphasized: Bool) -> Color {
        if state == .nodata { return theme.secondaryText.opacity(0.3) }
        return emphasized ? theme.accent.opacity(0.35) : theme.secondaryText.opacity(0.45)
    }

    // MARK: - 可访问性摘要（整图单元素：中文语义摘要）

    /// 电量文本投影（P3-2：percent 缺席 → 「—」，禁止造 0%；格式参数随
    /// flow.ax.* / flow.batterySubline 的 %@ 串）。
    var batteryPercentText: String {
        batteryPercent.map { "\($0)%" } ?? CellarL10n.s("common.nodata")
    }

    var axSummary: String {
        switch state {
        case .charging:
            return CellarL10n.s(
                "flow.ax.charging",
                batteryPercentText,
                powerAB ?? CellarL10n.s("common.nodata"),
                supplyLine ?? CellarL10n.s("common.nodata")
            )
        case .holding:
            // F3 §2.5：改单参数串（移除 supplyLine 实参；属性保留——direct 边
            // 标签消费在 View 侧 drawEdgeLabel）。
            return CellarL10n.s(
                "flow.ax.holding",
                batteryPercentText
            )
        case .battery:
            return CellarL10n.s(
                "flow.ax.battery",
                batteryPercentText,
                powerBS ?? CellarL10n.s("common.nodata")
            )
        case .nodata:
            return CellarL10n.s("flow.ax.nodata")
        }
    }
}