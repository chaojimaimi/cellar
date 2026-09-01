import SwiftUI

@main
struct CellarApp: App {
    // 组合根提升（规格 §2.8）：控制器常驻 App 层——面板视图重建不断供数据源；
    // App 启动即刷新注册态，图标新鲜度不依赖面板首开。
    @StateObject private var installer = DaemonInstaller()
    @StateObject private var statusController = StatusController()
    @StateObject private var loginItems = LoginItemController()

    init() {
        installer.refresh()
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(installer)
                .environmentObject(statusController)
                .environmentObject(loginItems)
        } label: {
            MenuBarIconLabel(controller: statusController)
        }
        .menuBarExtraStyle(.window)
        // §2.8 启动接线：registration → StatusController——enabled 即进 60s 图标
        // 新鲜度档；离开 .enabled → 停轮询 + 清空运行态（防残留 .unreachable
        // 图标永久 .alert）。面板内另有同款 onChange（就近处理，幂等双触发无害）。
        .onChange(of: installer.registration) {
            statusController.registrationChanged(installer.registration)
        }
    }
}
