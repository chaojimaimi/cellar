import CellarCore
import CellarUI
import SwiftUI

/// 主窗口（Phase 5 v1.2 §2.1/§2.2；M3.5 修复 + 用户决策「设置窗退役」；
/// v1.3 统计实页化；v1.5 侧栏打磨——品牌区 + 三段导航组 + 全行命中 + 括号
/// 指示条 + 外观关于合并页）：**HStack 自绘侧栏**——替换
/// NavigationSplitView + List(selection:)（系统组件在切页/全屏/最小化时侧栏
/// 空白、选中行蓝块跳出窗顶的怪癖）；左列定宽 216（VStack：品牌区 + 三导航
/// 组 + footer daemon 状态行）+ Divider + 右侧 detail 切页。
///
/// 路由七页：主组（仪表板/充电控制）→ 规划组（统计 v1.3 实页 / 校准 v1.4 /
/// 自动化 v1.6 占位）→ 设置组（通用 / 外观与关于合并页）；设置组页消费共享
/// 内容子视图（GeneralSections/AppearanceSections/AboutSections，设置窗内容
/// 统一并入，双入口收敛为单入口）。
/// 采样多表面仲裁：onAppear/onDisappear 对称上报主窗口表面（§2.3——最小化不
/// 触发 onDisappear，视同可见属已登记可接受行为）。
struct MainWindowView: View {
    @EnvironmentObject private var statusController: StatusController
    @EnvironmentObject private var installer: DaemonInstaller
    @Environment(\.cellarTheme) private var theme

    @State private var selection: MainWindowPage = .dashboard
    /// 悬停行（逐行判别；自绘行的 hover 态 = 照面板 FooterLinks hover 语汇）。
    @State private var hoveredPage: MainWindowPage?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 216)
            Divider()
            detailPage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 920, minHeight: 620)
        .onAppear { statusController.setMainWindowVisible(true) }
        .onDisappear { statusController.setMainWindowVisible(false) }
    }

    // MARK: - 侧栏（自绘：品牌区 + 三段导航组 + footer daemon 状态行）

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                brandHeader
                // 品牌区与导航组间距（spec 16-18pt，取 16——侧栏总高富余，
                // footer 照旧钉在底部）。
                Spacer().frame(height: 16)
                // 三段导航组：组内行距 2、组间 16pt——组间距须显著大于行距
                // （走查：10/2 差距过近读不出分组节奏，显「间距不均匀」）。
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(MainWindowPage.navigationGroups, id: \.self) { group in
                        VStack(spacing: 2) {
                            ForEach(group) { navigationRow($0) }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)

            Spacer(minLength: 8)
            daemonFooter
        }
    }

    /// 品牌区（v1.5 打磨，照 mock .brand）：accent 渐变圆角块内白色窖灯 +
    /// 「芯仓」显示字体主文字色 + 「CELLAR」字距小字。SF Symbol lightbulb.fill
    /// 替代 mock 自绘灯形（全 macOS 版本存在，无需运行时检查）；accent 无
    /// ink token——主文字走默认 foregroundStyle（primary，G2 零字面量）。
    private var brandHeader: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.accentGradient)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text("芯仓")
                    .font(theme.displayFont)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text("CELLAR")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.tertiaryText)
                    .tracking(2)
            }
        }
    }

    /// 单导航行：Button = 点击设 selection（无 List selection 系统行为）。
    /// 选中态 = accent 12% 底 + accent 字 + 前缘 3pt 括号形 accent 条（v1.5
    /// 打磨：指示条随行圆角弧线成「(」左括号形，用户裁决「比竖线更美观」）；
    /// hover 态 accent 字 + secondaryText 6% 微底（与选中底色互斥——选中行
    /// 不叠加 hover 底）。mock 的 ink 色无独立 token——G2 零字面量，取 accent
    /// 为强调体（与面板 FooterLinks hover 语汇同一 token）。
    private func navigationRow(_ page: MainWindowPage) -> some View {
        Button {
            selection = page
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.icon)
                    .frame(width: 16)
                Text(pageTitle(page))
                Spacer(minLength: 0)
                // 版本徽章（mock nav small：校准/自动化标注目标版本；
                // 统计已 v1.3 实页化，其余页无徽章）。
                if let badge = pageVersionBadge(page) {
                    Text(badge)
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.tertiaryText)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(rowColor(for: page))
            .fontWeight(selection == page ? .semibold : .regular)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 全行命中（v1.5 修复）：未选中行无背景填充，plain Button 命中区
            // 只含不透明内容（图标+文字）——contentShape 把透明区域纳入可点区。
            .contentShape(Rectangle())
            .background {
                if selection == page {
                    RoundedRectangle(cornerRadius: 8).fill(theme.accent.opacity(0.12))
                } else if hoveredPage == page {
                    // hover 微底（背景三分支之二：选中 accent 12% / hover
                    // secondaryText 6% / 常态无）。
                    RoundedRectangle(cornerRadius: 8).fill(theme.secondaryText.opacity(0.06))
                }
            }
            .overlay(alignment: .leading) {
                if selection == page {
                    // 「(」左括号形：整行圆角描边取左缘 5pt 蒙版——描边在上/
                    // 下 8pt 圆角处自然弯出弧线（与行背景圆角同心）。旧方案
                    // 3pt 宽条上用 8pt 圆角会被钳制到宽/2 退化为直线（SwiftUI
                    // 圆角上限 = 短边一半），括号形丢失。
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(theme.accent, lineWidth: 5)
                        .mask(alignment: .leading) { Rectangle().frame(width: 5) }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredPage = hovering ? page : nil
        }
    }

    /// 行文案色：选中/悬停 accent（强调语汇——hover 与选中同强调体，差异由
    /// 选中态底色/前缘条承载，照 FooterLinks 单钮强调形态），常态 secondaryText。
    private func rowColor(for page: MainWindowPage) -> Color {
        if selection == page || hoveredPage == page { return theme.accent }
        return theme.secondaryText
    }

    /// footer daemon 状态行（照 mock：绿点 + 状态 + 路线 + 策略摘要）。
    private var daemonFooter: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(connected ? theme.success : theme.secondaryText.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(daemonStatusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
            Text("\(CellarL10n.s(String.LocalizationValue(routeLineKey)))\n\(policySummary)")
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryText)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay(alignment: .top) {
            // 分隔线（mock .side .foot border-top）。
            Rectangle()
                .fill(theme.secondaryText.opacity(0.25))
                .frame(height: 1)
        }
        .background {
            if let panelBackground = theme.panelBackground {
                panelBackground
            }
        }
    }

    /// 连接态判定（daemon 有回包即绿；未知/失联灰——mock 绿点形态）。
    private var connected: Bool {
        statusController.connection == .connected
    }

    private var daemonStatusLine: String {
        switch statusController.connection {
        case .connected: return CellarL10n.s("main.sidebar.status.connected")
        case .unreachable: return CellarL10n.s("main.sidebar.status.unreachable")
        case .unknown: return CellarL10n.s("main.sidebar.status.unknown")
        }
    }

    /// 安装路线（DaemonInstaller 探测 result：App 托管 / 手工 / 未知）。
    private var routeLineKey: String {
        switch installer.route {
        case .appManaged: return "main.sidebar.route.appManaged"
        case .manual: return "main.sidebar.route.manual"
        case .unknown: return "main.sidebar.route.unknown"
        }
    }

    /// 策略摘要（上限/滞回 + 风扇策略词；daemon 缺席 → 未知态）。
    private var policySummary: String {
        guard let status = statusController.daemonStatus else {
            return CellarL10n.s("common.unknown")
        }
        var summary = CellarL10n.s("main.sidebar.policy", status.upperLimit, status.hysteresis)
        if let fan = status.fan {
            summary += CellarL10n.s("main.sidebar.policy.fan", fanStrategyWord(fan))
        }
        return summary
    }

    private func fanStrategyWord(_ fan: FanStatus) -> String {
        switch fan.strategy {
        case .constantSpeed: return CellarL10n.s("fan.strategy.constantSpeed")
        case .minRaise: return CellarL10n.s("fan.strategy.minRaise")
        case .twoStage: return CellarL10n.s("fan.strategy.twoStage")
        case .emergency: return CellarL10n.s("fan.strategy.emergency")
        }
    }

    // MARK: - 路由（七页：主组/设置组实页 + 规划组占位）

    @ViewBuilder
    private var detailPage: some View {
        switch selection {
        case .dashboard:
            DashboardView()
        case .control:
            ControlPageView()
        case .general:
            GeneralPageView()
        case .about:
            // v1.5 打磨：外观+关于合并页（AppearanceSections 在前 + AboutSections
            // 在后），AppearancePageView 独立页退役。
            AboutPageView()
        case .stats:
            // v1.3 实页（方案 §3.0）：替换占位；侧栏徽章同步移除。
            StatsPageView()
        case .calibration, .automation:
            TBDPlaceholderView(
                icon: selection.icon,
                title: pageTitle(selection),
                scope: pageScope(selection),
                version: pageVersionBadge(selection) ?? CellarL10n.s("main.page.version.alpha")
            )
        }
    }

    private func pageTitle(_ page: MainWindowPage) -> String {
        CellarL10n.s(String.LocalizationValue(page.titleKey))
    }

    /// 占位页范围说明（仅校准/自动化消费；统计 scope key 已随 v1.3 实页化退役
    /// ——含早前 control/about 两 scope key 一并清出 catalog）。
    private func pageScope(_ page: MainWindowPage) -> String {
        CellarL10n.s(String.LocalizationValue(page.scopeKey))
    }

    /// 版本徽章（侧栏与占位页共用）：校准/自动化标注 v1.4/v1.6；统计已 v1.3
    /// 实页化不再有徽章；其余页无徽章（占位页版本 chip 落 main.page.version.alpha）。
    private func pageVersionBadge(_ page: MainWindowPage) -> String? {
        switch page {
        case .calibration: return CellarL10n.s("main.page.calibration.version")
        case .automation: return CellarL10n.s("main.page.automation.version")
        case .dashboard, .control, .general, .about, .stats: return nil
        }
    }
}

/// 主窗口路由（工单 4 扩路由——设置窗退役后设置内容并入侧栏；v1.5 打磨：
/// .appearance 独立页 case 删除，.about 承载「外观与关于」合并页；菜单顺序
/// 重排三段组主组→规划组→设置组）。
/// App 域枚举——CellarUICheck 不 import App target，无需下沉。
enum MainWindowPage: String, CaseIterable, Identifiable {
    case dashboard, control, general, about, stats, calibration, automation

    var id: String { rawValue }

    /// 侧栏三段导航组（v1.5 打磨）：主组（本期实页）→ 规划组（占位页——版本
    /// 徽章标注目标版本）→ 设置组（通用 + 外观与关于合并页）。
    static var navigationGroups: [[MainWindowPage]] {
        [
            [.dashboard, .control],
            [.stats, .calibration, .automation],
            [.general, .about],
        ]
    }

    /// 侧栏/占位页图标（SF Symbol——macOS 26 全存在：general/about 沿用设置
    /// 窗同款图标，入口语义延续；外观图标随独立页退役一并移除）。
    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .control: return "slider.horizontal.3"
        case .general: return "gearshape"
        case .about: return "info.circle"
        case .stats: return "chart.bar"
        case .calibration: return "clock.arrow.circlepath"
        case .automation: return "bolt.fill"
        }
    }

    var titleKey: String {
        "main.page.\(rawValue)"
    }

    /// 占位页范围说明 key（仅规划组消费——主组实页无 scope）。
    var scopeKey: String {
        "main.page.\(rawValue).scope"
    }
}