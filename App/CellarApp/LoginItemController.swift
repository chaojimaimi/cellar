import CellarCore
import Combine
import Foundation
import ServiceManagement

/// 登录项开关控制器（开机启动偏好，规格 §2.4 接线）。
///
/// SMAppService 的登录项注册/注销为同步 IPC——一体遵循 WP2 主线程纪律：
/// 后台执行 + 结果回主 actor；成功即持久化 AppConfig（用户域 actor）。
/// 开关乐观更新，失败回滚并上屏文案（不静默）。
///
/// ⚠️ API 落点：本 App 的「开机启动」= 当前 App 自身注册为登录项 →
/// `SMAppService.mainApp`（登录项注册的 SDK 形态；`loginItem(identifier:)` 是
/// 另行打包 helper app 时的形态，不适用）。
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var launchAtLogin = false
    @Published private(set) var busy = false
    @Published private(set) var feedback: String?

    private let store: AppConfigStore

    init(store: AppConfigStore = AppConfigStore(url: AppConfigStore.defaultURL)) {
        self.store = store
    }

    /// 面板打开时加载持久化偏好（actor 读在后台，不阻塞主线程）。
    func load() {
        Task { [store] in
            let config = await store.load()
            launchAtLogin = config.launchAtLogin
        }
    }

    /// 开关切换：乐观置态 → 后台 register/unregister → 成功保存偏好；
    /// 失败回滚 + 反馈文案（错误原文，不静默）。
    func toggle(_ on: Bool) {
        guard !busy else { return }
        busy = true
        feedback = nil
        launchAtLogin = on
        Task.detached { [store, weak self] in
            do {
                // register 仅同步变体（异步上下文仍解析同步）；unregister 在异步
                // 上下文偏好 async 变体（编译器按各自签名选择，见 SDK 导入面）。
                if on {
                    try SMAppService.mainApp.register()
                } else {
                    try await SMAppService.mainApp.unregister()
                }
                try await store.save(AppConfig(launchAtLogin: on))
                await MainActor.run {
                    guard let self else { return }
                    self.busy = false
                    self.feedback = on ? "已开启开机启动" : "已关闭开机启动"
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.busy = false
                    self.launchAtLogin = !on   // 回滚乐观态
                    self.feedback = "切换开机启动失败：\(error.localizedDescription)"
                }
            }
        }
    }
}