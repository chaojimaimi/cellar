import SwiftUI

/// 菜单栏占位面板（Phase 2 WP2 最小接线）：守护进程安装态（含路由来源）、
/// 安装/卸载按钮、迁移四象限文案。策略控制 UI 在后续工作包完成，这里不读取电池信息。
struct PanelPlaceholder: View {
    @StateObject private var installer = DaemonInstaller()

    var body: some View {
        VStack(spacing: 14) {
            ChargingDialPlaceholder()
                .frame(width: 150, height: 150)
                .padding(.top, 4)

            daemonSection

            Divider()

            Button("退出 Cellar") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(18)
        .frame(width: 340)
        .task { installer.refresh() }        // 面板出现/重开即重查（§2.6）
        .onDisappear { installer.stopPolling() }  // 面板关闭取消授权轮询
    }

    /// 守护进程状态区（§2.6）：状态行（含路由）+ 四象限文案 + 位置提示 + 操作按钮。
    private var daemonSection: some View {
        VStack(spacing: 8) {
            Text("守护进程：\(statusText) · 路线：\(routeText)")
                .font(.callout)
                .fontWeight(.medium)

            if !guidanceText.isEmpty {
                Text(guidanceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if installer.anomaly {
                Text("异常：守护进程可达，但本 app 内未找到嵌入配置（可能由另一副本注册）")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let error = installer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // 位置提示（spike 局限 1.9）：注册跟随 .app 位置，移动/删除后需重新注册。
            Text("提示：已注册的守护进程跟随 Cellar.app 位置；移动或删除应用后请重新安装。")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button(buttonTitle) {
                if installer.registration == .enabled {
                    installer.uninstall()
                } else {
                    installer.install()
                }
            }
            // 迁移象限禁用安装：防用户绕过引导直接安装，制造手工+托管混合态（评审 P2-6）。
            .disabled(
                installer.busy
                    || installer.registration == .pending
                    || installer.guidance == .migrateFromLegacy
            )
        }
    }

    private var statusText: String {
        switch installer.registration {
        case .notRegistered: return "未注册"
        case .pending: return "等待系统授权…"
        case .enabled: return "已启用"
        }
    }

    private var routeText: String {
        switch installer.route {
        case .appManaged: return "App 托管"
        case .manual: return "手工路线"
        case .unknown: return "未知"
        }
    }

    private var buttonTitle: String {
        switch installer.registration {
        case .enabled: return "卸载守护进程"
        case .pending: return "等待系统授权…"
        case .notRegistered: return "安装守护进程"
        }
    }

    /// 四象限文案（§2.2 表格逐行对应）。
    private var guidanceText: String {
        switch installer.guidance {
        case .normalInstall:
            return "守护进程未安装。点击「安装守护进程」注册，首次需在系统设置中批准。"
        case .running:
            return "守护进程随系统托管运行中。"
        case .migrateFromLegacy:
            return "检测到手工安装的守护进程。请先运行 sudo cellar uninstall，再点击「安装守护进程」。"
        case .cleanMixedState:
            return "检测到手工安装残留与托管注册并存。请先在本面板卸载，再运行 sudo cellar uninstall 清理残留，最后重新安装。"
        }
    }
}

/// 静态环形仪表占位：与窖灯图标同构（80% 弧段 + 芯点），琥珀渐变。
private struct ChargingDialPlaceholder: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.black.opacity(0.08), lineWidth: 14)

            Circle()
                .trim(from: 0, to: 0.8)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.71, green: 0.47, blue: 0.23),
                            Color(red: 0.94, green: 0.75, blue: 0.44),
                        ]),
                        center: .center,
                        startAngle: .degrees(90),
                        endAngle: .degrees(-270)
                    ),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Circle()
                .fill(Color(red: 0.96, green: 0.85, blue: 0.63))
                .frame(width: 12, height: 12)
        }
    }
}