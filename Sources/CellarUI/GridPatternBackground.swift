import SwiftUI

// 面板细线网格底纹（Phase 5 v1.9 风格 C Tier 2，D-B2）：24pt 方格网格工业面板
// 语汇。消费点收窄两处签名面（panelBackground 全部消费点不铺开）：①PanelView
// 菜单栏弹窗背景层；②MainWindowView 主窗口内容区背景层——两处均在 App target
// （CellarUICheck 为 SPM target，结构性不可快照，R1 P1-2）→ 本组件容器形态由
// CellarUICheck GridPattern_ 快照 case 覆盖，App 层实际着装效果列人工走查项。

/// 24pt 方格网格底纹（横竖线宽 1，色 = `theme.panelGrid`）。绘制层级 = 
/// panelBackground 之上、内容之下（消费点在 `.background` 闭包内紧邻其上叠放）。
/// **panelGrid == nil → 整层不进入视图树**（A/B 哑值纪律零绘制；组件层零
/// `if style == .industrial` 枚举分支——token 值分支合法，消费点零条件分支）。
public struct GridPatternBackground: View {
    @Environment(\.cellarTheme) private var theme

    public init() {}

    public var body: some View {
        if let grid = theme.panelGrid {
            Canvas { context, size in
                // 方格步长 24pt（D-B2 定版）；线从 0 起、步进 24，边缘半格
                // 属画布裁剪内确定性渲染。透明度钳制在 token 定义处（Theme.swift
                // ≤0.08，R-2：不压文本可读性）。
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += 24
                }
                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += 24
                }
                context.stroke(path, with: .color(grid), lineWidth: 1)
            }
        }
    }
}
