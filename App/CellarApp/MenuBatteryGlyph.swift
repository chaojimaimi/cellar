import SwiftUI

/// 菜单栏自绘电池图标（0.18.4）。
///
/// 背景：SF Symbols `battery.100percent` 的 variableValue 电量填充在菜单栏
/// template 单色渲染下不可见（符号默认形态即满格轮廓，两轮走查实测恒显满格）
/// ——弃系统符号，自绘几何逐元素可控。
///
/// 形态（demo docs/design/menubar-battery-icon-mock.html 用户确认）：
/// - 外壳圆角描边 + 右端子 + 内部按电量比例填充；
/// - 充电中：填充区上闪电挖空（drawLayer destinationOut 层内擦除——透出菜
///   单栏背景，原生充电图标同款设计语言）；低电量充电：红填充 + 白闪电实绘
///   （低填充区挖孔悬空不可见，白闪电保证充电语义可见）；
/// - 外接未充电（维持）：插头挖空 / 低电量红填充 + 白插头；
/// - 电池供电：无标识，填充随放电下降；
/// - 低电量（< 15% 具名常量）：填充转红告警（彩色先例 = 告警态红图标在产）。
///
/// 全部 Canvas Shape 绘制，无系统符号渲染行为依赖；App 层零 SMC 写。
struct MenuBatteryGlyph: View {
    let percent: Int
    /// 充电中（isCharging 取值链）。
    let charging: Bool
    /// 外接供电（externalConnected 取值链）——维持态判定。
    let plugged: Bool

    /// 低电量告警阈值（%）。低于此值填充转红（具名常量，调整点集中此处）。
    static let lowBatteryThresholdPercent = 15

    // 几何基准（pt）——Canvas 坐标系按此设计，绘制时按 frame 等比缩放。
    private static let bodyW: CGFloat = 22
    private static let bodyH: CGFloat = 12.5
    private static let capW: CGFloat = 2.2
    private static let pad: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 25, size.height / 12.5)
            context.translateBy(x: 0, y: (size.height - Self.bodyH * scale) / 2)
            context.scaleBy(x: scale, y: scale)

            let low = percent < Self.lowBatteryThresholdPercent
            let fillColor: Color = low ? .red : .primary
            let fillRect = CGRect(
                x: Self.pad, y: Self.pad,
                width: (Self.bodyW - Self.pad * 2 - Self.capW) * CGFloat(percent) / 100,
                height: Self.bodyH - Self.pad * 2
            )

            // 外壳描边 + 端子（前景色，跟随菜单栏深浅）。
            let shell = Path(roundedRect: CGRect(x: 0, y: 0, width: Self.bodyW, height: Self.bodyH), cornerRadius: 3.2)
            context.stroke(shell, with: .color(.primary), lineWidth: 1.4)
            context.fill(
                Path(roundedRect: CGRect(x: Self.bodyW + 0.4, y: (Self.bodyH - 5.2) / 2, width: Self.capW, height: 5.2), cornerRadius: 1),
                with: .color(.primary)
            )

            // 状态标识（画入电池内部中央，固定尺寸不随填充缩放——低填充窄条上
            // 标识仍清晰可辨，code-review P1-1/P2-2）。
            let markCenter = CGPoint(x: Self.bodyW / 2, y: Self.bodyH / 2)
            switch (charging, plugged) {
            case (true, _):
                // 充电：闪电标识。
                if low {
                    // 低电量充电：红填充 + 白闪电实绘（红底白形对比最大）。
                    context.fill(Path(roundedRect: fillRect, cornerRadius: 1.6), with: .color(.red))
                    context.fill(Self.boltPath(centeredAt: markCenter), with: .color(.white))
                } else {
                    // 常规充电：闪电挖空——离屏层内先 .normal 画填充、再切
                    // destinationOut 画闪电（擦除填充像素），层合成回 Canvas 后
                    // 挖孔透出菜单栏背景（原生充电图标同款观感）。⚠️ blendMode
                    // 须在填充之后设置——先设则首笔打在空层上恒 0（code-review
                    // P0：全透明空电池壳回归）。
                    context.drawLayer { layer in
                        layer.fill(Path(roundedRect: fillRect, cornerRadius: 1.6), with: .color(.primary))
                        layer.blendMode = .destinationOut
                        layer.fill(Self.boltPath(centeredAt: markCenter), with: .color(.primary))
                    }
                }
            case (false, true):
                // 维持（外接未充电）：插头标识。
                if low {
                    context.fill(Path(roundedRect: fillRect, cornerRadius: 1.6), with: .color(.red))
                    context.fill(Self.plugPath(centeredAt: markCenter), with: .color(.white))
                } else {
                    context.drawLayer { layer in
                        layer.fill(Path(roundedRect: fillRect, cornerRadius: 1.6), with: .color(.primary))
                        layer.blendMode = .destinationOut
                        layer.fill(Self.plugPath(centeredAt: markCenter), with: .color(.primary))
                    }
                }
            default:
                // 电池供电 / 未外接静息：无标识，纯电量填充。
                context.fill(Path(roundedRect: fillRect, cornerRadius: 1.6), with: .color(fillColor))
            }
        }
        .frame(width: 26, height: 14.5)
        // a11y 由调用方 MenuBarIconLabel 统一挂（此处硬编码英文串会被外层遮蔽
        // 且未走 CellarL10n——code-review P3-1 判死代码删除）。
    }

    /// 闪电 path（viewBox 0 0 10 14，0.82 固定缩放、中心对齐给定锚点——固定
    /// 尺寸不随填充宽度缩放，code-review P1-1）。
    static func boltPath(centeredAt c: CGPoint) -> Path {
        let s: CGFloat = 0.82
        var p = Path()
        p.move(to: CGPoint(x: 6.2, y: 0))
        p.addLine(to: CGPoint(x: 0.8, y: 8.2))
        p.addLine(to: CGPoint(x: 4.6, y: 8.2))
        p.addLine(to: CGPoint(x: 3.4, y: 14))
        p.addLine(to: CGPoint(x: 9.6, y: 5.2))
        p.addLine(to: CGPoint(x: 5.6, y: 5.2))
        p.addLine(to: CGPoint(x: 7.4, y: 0))
        p.closeSubpath()
        return p.applying(CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: c.x - 5 * s, ty: c.y - 7 * s))
    }

    /// 插头 path（viewBox 0 0 10 11，0.82 固定缩放、中心对齐锚点；本体下缘圆角
    /// 由 roundedRect cornerSize 钳制近似——R1 P3-2 登记备查）。
    static func plugPath(centeredAt c: CGPoint) -> Path {
        let s: CGFloat = 0.82
        var p = Path()
        p.addRect(CGRect(x: 2.6, y: 0, width: 1.5, height: 3.2))
        p.addRect(CGRect(x: 5.9, y: 0, width: 1.5, height: 3.2))
        p.addRoundedRect(in: CGRect(x: 1.2, y: 2.6, width: 7.6, height: 5.5), cornerSize: CGSize(width: 3.8, height: 3.8))
        p.addRect(CGRect(x: 4.4, y: 7.6, width: 1.2, height: 3.4))
        return p.applying(CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: c.x - 5 * s, ty: c.y - 5.5 * s))
    }
}
