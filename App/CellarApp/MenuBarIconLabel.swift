import AppKit
import CellarCore
import SwiftUI

/// 菜单栏动态图标（规格 §2.2 多状态符号 + alert 变色增强）。
///
/// label closure 内的专用视图：仅观察 StatusController（iconState 推导），
/// 状态刷新不依赖面板窗口的生命周期（组合根提升后控制器在 App 层常驻）。
struct MenuBarIconLabel: View {
    @ObservedObject var controller: StatusController
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
    /// 跟随系统菜单栏着色。
    @ViewBuilder
    private var labelContent: some View {
        if controller.iconState == .alert {
            Image(systemName: resolvedSymbol(for: controller.iconState))
                .renderingMode(.original)
                .foregroundStyle(theme.alert)
                .accessibilityLabel("Cellar 电池状态")
        } else {
            Image(systemName: resolvedSymbol(for: controller.iconState))
                .accessibilityLabel("Cellar 电池状态")
        }
    }
}