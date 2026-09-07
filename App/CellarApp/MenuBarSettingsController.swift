import CellarCore
import CellarUI
import Foundation
import os

/// 菜单栏设置控制器（v1.10 M2 T1；照 StyleController 同构：AppConfig 第四写者）：
/// 启动自标定 load 持久化偏好 → @Published percentageVisible 驱动菜单栏 label
/// 重渲染。加载完成前呈现默认关——加载期闪变为登记的已知态（照 StyleController）。
///
/// 切换 = toggle()：内存先行（即时生效链路）→ 共享 store 的 actor 原子 update()
/// 写盘（评审 P0-1：与 launchAtLogin/style/onboardingCompleted 三写者字段互不
/// 覆盖——**只写本字段**，其余字段保持）；写失败回滚内存态（不静默，os_log）。
///
/// ⚠️ load 必须随实例诞生自启动（StyleController.init 注释先例）：App.init 早期
/// 访问 @StateObject 拿到的是被 SwiftUI 丢弃的临时实例——外部在 App.init 调
/// load()，其 Task 醒来时实例已释放、静默失效；自启动写法在两种实例生命周期
/// 模型下都安全（正式实例的 init 必自跑 load）。
@MainActor
final class MenuBarSettingsController: ObservableObject {
    /// 菜单栏电量百分比显隐（nil = 未设置 = 关；本文件内自写，可用 private(set)）。
    @Published private(set) var percentageVisible = false
    /// 持久化偏好是否已加载（PanelView 页脚 Toggle 在 loaded 前禁用，防半程态回写）。
    @Published private(set) var loaded = false

    private let store: AppConfigStore
    private let log = Logger(subsystem: "com.cellar", category: "app-config")

    init(store: AppConfigStore = AppConfigStore(url: AppConfigStore.defaultURL)) {
        self.store = store
        load()
    }

    /// 启动加载：nil = 未设置 = 关（默认合法态，不记日志）。
    private func load() {
        // 强捕获 self（一次性短任务；storage 自 init 起强持有本实例，无循环）——
        // StyleController.load 同款：弱捕获反而复现「临时实例中途释放 → 静默失效」。
        Task {
            self.percentageVisible = await store.load().menuBarPercentageVisible == true
            self.loaded = true
        }
    }

    /// 切换显隐（PanelView 页脚 Toggle 唯一入口）：内存先行即时生效，随后经共享
    /// store 原子 update 写盘；写失败回滚内存态并 os_log（不静默）。loaded 前为
    /// 视图层禁用兜底（防半程态回写）。
    func toggle() {
        guard loaded else { return }
        let previous = percentageVisible
        percentageVisible.toggle()
        let target = percentageVisible   // 跨 actor 值捕获（@Sendable 闭包不触碰 MainActor self）。
        Task { [store, weak self] in
            do {
                // 原子读改写：只写 menuBarPercentageVisible 字段，launchAtLogin/
                // style/onboardingCompleted 保持（第四写者互不覆盖）。
                _ = try await store.update { $0.menuBarPercentageVisible = target }
            } catch {
                // 仅当内存态仍是本次请求的目标（无后续切换接管）才回滚——
                // 防 stale 回滚覆盖用户后续选择（StyleController 同款）。
                guard let self, self.percentageVisible == target else { return }
                self.percentageVisible = previous
                self.log.error("菜单栏百分比开关写盘失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
