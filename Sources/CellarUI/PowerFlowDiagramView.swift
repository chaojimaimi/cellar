import SwiftUI

// MARK: - 功率流向三角图（Phase 5 v1.2 §3.2；**参数驱动**——CellarUICheck 仅
// import CellarCore/CellarUI，App 侧薄包装桥接 StatusController；照 FanSectionView
// 先例）
//
// 文件拆分（红线 6 ≤400 行）：节点层 Canvas 绘制（layoutCards/drawNodes/
// drawNodeCard/着色/nodeScale）与 AX 摘要见 PowerFlowDiagramNodes.swift（同类型
// internal extension）。
//
// v1.2 走查批 F2：三边端点全部由**最终卡 rect 动态推导**（F2.4——系数按 mock
// 实测反推写死，全在 mock viewBox 560×244 归一化坐标系运算；卡宽自适应后端点
// 随卡缘迁移，标签锚点 = 各边中点）；F3：整图「流动才画线」——holding 只画
// 直供边（真实流动）+ 流光点，nodata 三灰卡无连线。
//
// M3.5 修复遗留说明：节点层与边层并入**同一 Canvas 单坐标系**——旧实现节点层
// 为 SwiftUI 视图（.position/.frame 归一化定位）叠于 Canvas 之上，ImageRenderer
// 快照正常而真窗破损 = 提案尺寸依赖型缺陷；图形全量经 GraphicsContext 绘制
// 后无视图定位路径（详见 canvasLayer WHY）。

/// 三角图视觉态（§3.1 视觉态矩阵的四态；三态映射复用 PowerFlowView 的
/// (ext, charging) 二元判定结论——含「ext∧charging 动作中=异常过渡态按
/// charging 呈现」）。
public enum PowerDiagramState: Equatable, Sendable {
    /// 外接 + 充电中：适配器→电池（+W，accent）+ 适配器→系统（直供，accent——
    /// 走查 2026-09-04 直供边 accent 化）
    /// 双活跃；满电还需（至上限）。
    case charging
    /// 外接 + 停充：仅适配器→系统直供（真实流动 + 流光点）；电池两缘无连线
    /// （F3：方向/流动只在有流动时呈现——停充态电池无进出，画线即误导）。
    case holding
    /// 电池供电：电池→系统（−W，warn）；适配器节点降档（未接入）。
    case battery
    /// 遥测快照 nil：三节点灰卡悬浮、无连线（组合空态，快照矩阵登记
    /// R-7 暂不入阵，走查兜底——v1.2 走查批入阵 4 张）。
    case nodata
}

/// 功率流向三角图：适配器（左上）/ 系统（右上）/ 电池（下中主角位）三节点卡 +
/// 流动路径曲线（ab 充电边 accent / bs 放电边 warn / 直供边 accent——真实流动
/// active flow 全 accent 强调，走查 2026-09-04）+ 流动
/// 光点（TimelineView 驱动 Canvas——60fps 目标；静帧/快照/reduceMotion 下固定
/// 相位静态渲染，确定性成立）。**只有真实流动的路径才画线**（F3 统一规则）：
/// charging = ab+direct 双活跃；holding = direct 单活跃；battery = bs 单活跃；
/// nodata = 无连线。
///
/// - 布局几何 = mock SVG viewBox 560×244 的归一化映射（mock 为唯一视觉事实源）；
/// - 文本全部经 CellarL10n（flow.*）；色值全 token 消费（G2：本组件零 Color
///   字面量——图形近似色均取既有 token 降档，不引入新字面量落点）；
/// - 整图 accessibilityElement(children: .combine) + 中文摘要 label。
public struct PowerFlowDiagramView: View {
    public let state: PowerDiagramState
    /// 电池电量（副行「N% · V」；nodata 忽略）。
    public let batteryPercent: Int?
    /// 电池电压串（App 侧组装如「12.3 V」；nodata 忽略）。
    public let batteryVoltage: String
    /// 适配器节点副行（App 侧组装如「65 W · 在位」/「未接入」；nodata 忽略）。
    public let adapterLine: String
    /// 系统节点副行（App 侧组装；nodata 忽略）。
    public let systemLine: String
    /// 适配器→电池边功率标签（充电态活跃；如「+33.4 W」）。
    public let powerAB: String?
    /// 电池→系统边功率标签（电池态活跃；如「−12.4 W」）。
    public let powerBS: String?
    /// 适配器→系统直供边标签（充电/停充态活跃；如「直供」）。
    public let supplyLine: String?
    /// 流动光点开关（快照注入口兼低性能降级开关；false = 边照画、点不画）。
    public let showsFlowDots: Bool
    /// 动画注入口（**快照渲染恒 false**——动画帧不确定会毁 golden 对比；
    /// reduceMotion 时同样强制静态）。
    public let initialAnimating: Bool

    @Environment(\.cellarTheme) var theme
    // 节点层拆分文件（PowerFlowDiagramNodes.swift）需要跨文件访问 theme——
    // internal 范围内（不导出模块外，公开面不变）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        state: PowerDiagramState,
        batteryPercent: Int?,
        batteryVoltage: String,
        adapterLine: String,
        systemLine: String,
        powerAB: String? = nil,
        powerBS: String? = nil,
        supplyLine: String? = nil,
        showsFlowDots: Bool = true,
        initialAnimating: Bool = true
    ) {
        self.state = state
        self.batteryPercent = batteryPercent
        self.batteryVoltage = batteryVoltage
        self.adapterLine = adapterLine
        self.systemLine = systemLine
        self.powerAB = powerAB
        self.powerBS = powerBS
        self.supplyLine = supplyLine
        self.showsFlowDots = showsFlowDots
        self.initialAnimating = initialAnimating
    }

    public var body: some View {
        GeometryReader { proxy in
            // 边层 + 节点层**同一 Canvas 单坐标系**（M3.5 修复：旧节点层是叠在
            // Canvas 上的 SwiftUI 视图（.position/.frame 归一化定位），真窗提案
            // 尺寸下卡片/文字消失、图标孤悬——快照正常而真窗破损 = 尺寸依赖型
            // 缺陷；图形全量经 GraphicsContext 绘制后无该路径。绘制顺序照 mock
            // SVG：节点卡 → 边 → 边标签 → 光点）。
            if animating {
                TimelineView(.animation) { timeline in
                    canvasLayer(width: proxy.size.width, height: proxy.size.height, phase: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                canvasLayer(width: proxy.size.width, height: proxy.size.height, phase: nil)
            }
        }
        // mock viewBox 560×244 归一化几何的前提：容器恒按该比例缩放（letterbox）。
        .aspectRatio(560.0 / 244.0, contentMode: .fit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(axSummary)
    }

    /// 动画判定：注入口为 true 且系统未开 reduceMotion（红线 4——reduceMotion
    /// → 流光点停，静态渲染；静帧时无 TimelineView → 零持续开销，R-1）。
    private var animating: Bool {
        initialAnimating && !reduceMotion && showsFlowDots
    }

    // MARK: - 三边端点动态推导（F2 §2.4）

    private enum EdgePath { case ab, bs, direct }

    /// 单边几何：端点/控制点/标签锚点全部由最终卡 rect 推导（**流动才画线**
    /// 后三边恒实线，无虚线形态；dash 参数随之退役）。
    private struct EdgeGeometry {
        let p0: CGPoint
        let c1: CGPoint
        let c2: CGPoint
        let p3: CGPoint
        /// 直线标记（direct 光点须线性匀速——P3-1：退化三次权重 1−3t²+2t³ 与
        /// 线性 1−t 不等价，t∈(0,1) 非匀速；t=0/0.5 静态相位两方案像素等价，
        /// golden 不变）。
        let isStraight: Bool
        /// 边中点（直线 (p0+p3)/2 = 通用公式 t=0.5 特例；ab/bs 三次 t=0.5 中点
        /// (p0+3c1+3c2+p3)/8——原相对偏移等比迁移后仍成立）。labelOffsetY 供
        /// direct 标签法向偏移（中点恰在线上，标签压线——恢复 mock 上方 10
        /// 单位偏移；ab/bs 曲线中点天然离线不偏移）。
        let labelAnchor: CGPoint

        init(p0: CGPoint, c1: CGPoint, c2: CGPoint, p3: CGPoint, isStraight: Bool = false, labelOffsetY: CGFloat = 0) {
            self.p0 = p0
            self.c1 = c1
            self.c2 = c2
            self.p3 = p3
            self.isStraight = isStraight
            self.labelAnchor = CGPoint(
                x: (p0.x + 3 * c1.x + 3 * c2.x + p3.x) / 8,
                y: (p0.y + 3 * c1.y + 3 * c2.y + p3.y) / 8 + labelOffsetY
            )
        }
    }

    /// 端点推导（系数 = mock 实测反推写死，全部按 mock viewBox 560×244 归一化
    /// 坐标系运算，含 +2/−6/+4 偏移；卡宽不变 == mock 比例宽 136 时推导值逐一
    /// 等于 mock 原坐标——自检核算表随工单交付）：
    /// - direct：`(adapter.maxX, 卡竖中)` → `(system.minX, 同高)`（mock 160/400/49）；
    /// - ab：`(adapter.minX + 72/136×宽, maxY+2)` → `(battery.minX + 34/136×宽,
    ///   minY−6)`（mock 96,82 → 246,158；72/136 = 0.529 精确分数）；
    /// - bs：`(battery.minX + 102/136×宽, minY−6)` → `(system.minX + 64/136×宽,
    ///   maxY+4)`（mock 314,158 → 464,84；64/136 = 0.47 精确分数）；
    /// - 控制点 = 原相对偏移按新端点等比迁移（保持 mock 弯度：ab 控制位移
    ///   20/150、76/150 × x 跨 + 36/76、60/76 × y 跨；bs 72/150、130/150 × x 跨
    ///   + 16/74、40/74 × y 跨——位移占比为常数，端点迁移时曲线形状同比保持）。
    private func edgeGeometry(_ edge: EdgePath, cards: CardLayouts, size: CGSize) -> EdgeGeometry {
        let unitY = size.height / 244
        switch edge {
        case .direct:
            let start = CGPoint(x: cards.adapter.rect.maxX, y: cards.adapter.rect.midY)
            let end = CGPoint(x: cards.system.rect.minX, y: cards.system.rect.midY)
            // isStraight = true：直线插值（P3-1——不用退化三次 c1=p0/c2=p3，
            // 光点须匀速；labelAnchor 公式对直线恒等于 (p0+p3)/2）。标签法向
            // 上移 10/244 单位（恢复 mock 上方偏移——免压线，见 labelAnchor 注）。
            return EdgeGeometry(
                p0: start, c1: start, c2: end, p3: end,
                isStraight: true, labelOffsetY: -10 * unitY
            )
        case .ab:
            let start = CGPoint(
                x: cards.adapter.rect.minX + cards.adapter.rect.width * 72 / 136,
                y: cards.adapter.rect.maxY + 2 * unitY
            )
            let end = CGPoint(
                x: cards.battery.rect.minX + cards.battery.rect.width * 34 / 136,
                y: cards.battery.rect.minY - 6 * unitY
            )
            let controls = cubicControls(
                start: start, end: end,
                x1: 20.0 / 150.0, y1: 36.0 / 76.0, x2: 76.0 / 150.0, y2: 60.0 / 76.0
            )
            return EdgeGeometry(p0: start, c1: controls.0, c2: controls.1, p3: end)
        case .bs:
            let start = CGPoint(
                x: cards.battery.rect.minX + cards.battery.rect.width * 102 / 136,
                y: cards.battery.rect.minY - 6 * unitY
            )
            let end = CGPoint(
                x: cards.system.rect.minX + cards.system.rect.width * 64 / 136,
                y: cards.system.rect.maxY + 4 * unitY
            )
            let controls = cubicControls(
                start: start, end: end,
                x1: 72.0 / 150.0, y1: 16.0 / 74.0, x2: 130.0 / 150.0, y2: 40.0 / 74.0
            )
            return EdgeGeometry(p0: start, c1: controls.0, c2: controls.1, p3: end)
        }
    }

    /// 控制点等比迁移：位移 = (端点跨 × 常数占比)（mock 弯度保持，F2 §2.4）。
    private func cubicControls(
        start: CGPoint, end: CGPoint, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat
    ) -> (CGPoint, CGPoint) {
        (
            CGPoint(x: start.x + x1 * (end.x - start.x), y: start.y + y1 * (end.y - start.y)),
            CGPoint(x: start.x + x2 * (end.x - start.x), y: start.y + y2 * (end.y - start.y))
        )
    }

    /// 光点节奏（mock animateMotion：AB 3 点 1.9s / BS 2 点 2s / AS 2 点 2.6s）。
    /// 半径 ×scale（P3-2：边层度量纳入 nodeScale 域——宽窗下光点与节点层
    /// 同比例，消边层相对漂移；560 快照恒 1.0 零扰动）。
    private func dotSpec(for edge: EdgePath, scale: CGFloat) -> (count: Int, duration: Double, radius: CGFloat) {
        switch edge {
        case .ab: return (3, 1.9, 3 * scale)
        case .bs: return (2, 2.0, 3 * scale)
        case .direct: return (2, 2.6, 2.6 * scale)
        }
    }

    // MARK: - 边层

    private func canvasLayer(width: CGFloat, height: CGFloat, phase: Double?) -> some View {
        Canvas { context, size in
            // 布局先行：节点卡测量定宽（节点层先画——mock SVG 组序 nAdp/nSys/nBat
            // 在边组之前；路径端点在卡缘，边/标签/光点叠于卡上）；三边端点由
            // 最终卡 rect 动态推导（F2.4）。
            let scale = Self.nodeScale(for: size.width)
            let cards = layoutCards(context: &context, size: size, scale: scale)
            drawNodes(context: &context, scale: scale, cards: cards)
            switch state {
            case .charging:
                drawEdge(context: &context, edge: .ab, geometry: edgeGeometry(.ab, cards: cards, size: size), color: theme.accent, scale: scale)
                drawEdge(context: &context, edge: .direct, geometry: edgeGeometry(.direct, cards: cards, size: size), color: theme.accent, scale: scale)
                drawEdgeLabel(context: &context, text: powerAB, color: theme.accent, semibold: true, anchor: edgeGeometry(.ab, cards: cards, size: size).labelAnchor, scale: scale)
                drawEdgeLabel(context: &context, text: supplyLine, color: theme.accent, semibold: false, anchor: edgeGeometry(.direct, cards: cards, size: size).labelAnchor, scale: scale)
            case .holding:
                // F3 §2.1：停充 = 适配器直供系统（真实流动 ~20W 无功率数字——
                // 诚实纪律）→ 只画直供边 + 流光点（activeDottedEdges 含 .direct）；
                // 电池两缘不画线（无进出流动，画中性虚线误导）。直供边 accent 化
                // （走查 2026-09-04：active flow 用 accent 强调——灰线灰点不可见
                // 致「停充无动态」观感）。
                drawEdge(context: &context, edge: .direct, geometry: edgeGeometry(.direct, cards: cards, size: size), color: theme.accent, scale: scale)
                drawEdgeLabel(context: &context, text: supplyLine, color: theme.accent, semibold: false, anchor: edgeGeometry(.direct, cards: cards, size: size).labelAnchor, scale: scale)
            case .battery:
                drawEdge(context: &context, edge: .bs, geometry: edgeGeometry(.bs, cards: cards, size: size), color: theme.warning, scale: scale)
                drawEdgeLabel(context: &context, text: powerBS, color: theme.warning, semibold: true, anchor: edgeGeometry(.bs, cards: cards, size: size).labelAnchor, scale: scale)
            case .nodata:
                // F3 §2.2：空态无流动语义——三节点灰卡悬浮，无连线。
                break
            }
            if showsFlowDots {
                drawDots(context: &context, size: size, phase: phase, cards: cards, scale: scale)
            }
        }
    }

    /// 单边曲线（直线/三次贝塞尔均由 EdgeGeometry 出点——端点已随卡迁移）。
    /// 线宽 ×scale（P3-2：mock stroke-width 为 560 域度量，随容器全域统一缩放）。
    private func drawEdge(
        context: inout GraphicsContext, edge: EdgePath,
        geometry: EdgeGeometry, color: Color, scale: CGFloat
    ) {
        var path = Path()
        switch edge {
        case .ab, .bs:
            path.move(to: geometry.p0)
            path.addCurve(
                to: geometry.p3,
                control1: geometry.c1,
                control2: geometry.c2
            )
        case .direct:
            path.move(to: geometry.p0)
            path.addLine(to: geometry.p3)
        }
        // 直供边 1.8、其余 2（mock stroke-width）；F3 后三边恒实线（无虚线形态）。
        let lineWidth: CGFloat = (edge == .direct ? 1.8 : 2) * scale
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth))
    }

    /// 边功率/状态标签（mono 字形；AB/BS 加粗、AS 常规——mock 字号层级）。
    /// 锚点 = 边中点（F2 §2.4：标签随边几何迁移，不落死坐标）；字号 ×scale
    /// （P3-2——节点层标题 12×scale 同域）。
    private func drawEdgeLabel(
        context: inout GraphicsContext, text: String?,
        color: Color, semibold: Bool, anchor: CGPoint, scale: CGFloat
    ) {
        guard let text, !text.isEmpty else { return }
        let label = Text(text)
            .font(.system(size: (semibold ? 11 : 10.5) * scale, weight: semibold ? .semibold : .regular))
            .monospacedDigit()
            .foregroundColor(color)
        context.draw(label, at: anchor, anchor: .center)
    }

    /// 流动光点：沿活跃边匀速推进（相位 = 时间/周期 + 点序错开，mod 1）。
    /// phase == nil（静态路径）→ 固定相位 i/count，快照/reduceMotion 确定性成立。
    private func drawDots(context: inout GraphicsContext, size: CGSize, phase: Double?, cards: CardLayouts, scale: CGFloat) {
        for edge in activeDottedEdges {
            let geometry = edgeGeometry(edge, cards: cards, size: size)
            let spec = dotSpec(for: edge, scale: scale)
            for index in 0..<spec.count {
                let offset = phase.map {
                    ($0 / spec.duration + Double(index) / Double(spec.count)).truncatingRemainder(dividingBy: 1)
                } ?? (Double(index) / Double(spec.count))
                let point = edgePoint(geometry, t: offset)
                let rect = CGRect(
                    x: point.x - spec.radius, y: point.y - spec.radius,
                    width: spec.radius * 2, height: spec.radius * 2
                )
                context.fill(Path(ellipseIn: rect), with: .color(edgeColor(edge)))
            }
        }
    }

    /// 活跃光点边（F3「流动才画线」同规则）：charging：AB 3 点 accent + AS 2 点
    /// accent（直供 accent 化）；holding：AS 2 点 accent（停充直供 = 真实流动）；
    /// battery：BS 2 点 warn；nodata 无连线无光点。
    private var activeDottedEdges: [EdgePath] {
        switch state {
        case .charging: return [.ab, .direct]
        case .holding: return [.direct]
        case .battery: return [.bs]
        case .nodata: return []
        }
    }

    private func edgeColor(_ edge: EdgePath) -> Color {
        switch edge {
        case .ab: return theme.accent
        case .bs: return theme.warning
        // direct 流光点 accent（走查 2026-09-04：直供 = 真实能量流动（适配器→
        // 系统），与 active flow 同色强调——灰点与灰线同样不可见）。
        case .direct: return theme.accent
        }
    }

    /// 路径上的点：direct 线性插值（p0→p3 匀速）；ab/bs 三次贝塞尔（端点/
    /// 控制点动态）。WHY 直线不用退化三次表示（P3-1 更正）：c1=p0、c2=p3 时
    /// 三次权重 1−3t²+2t³ ≠ 线性 1−t——t∈(0,1) 光点非匀速，动画流畅度与注释
    /// 数学断言都不能含糊；静态相位 t∈{0, 0.5} 两方案像素等价故 golden 不变。
    private func edgePoint(_ geometry: EdgeGeometry, t: Double) -> CGPoint {
        if geometry.isStraight {
            return CGPoint(
                x: geometry.p0.x + CGFloat(t) * (geometry.p3.x - geometry.p0.x),
                y: geometry.p0.y + CGFloat(t) * (geometry.p3.y - geometry.p0.y)
            )
        }
        let u = 1 - t
        let x = u * u * u * geometry.p0.x + 3 * u * u * t * geometry.c1.x + 3 * u * t * t * geometry.c2.x + t * t * t * geometry.p3.x
        let y = u * u * u * geometry.p0.y + 3 * u * u * t * geometry.c1.y + 3 * u * t * t * geometry.c2.y + t * t * t * geometry.p3.y
        return CGPoint(x: x, y: y)
    }
}