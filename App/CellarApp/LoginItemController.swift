import CellarCore
import Combine
import Foundation
import ServiceManagement

/// 登录项注册态展示形态（SMAppService.Status 的 Sendable 投影——Status 的
/// notFound 携带 Error 关联值非 Sendable，跨隔离回传前先折叠为四态）。
enum LoginItemRegistration: Equatable {
    /// 已注册（系统登录项在册）。
    case enabled
    /// 已注册但待用户在系统设置批准。
    case requiresApproval
    /// 未注册（含 notFound——语义同为「系统当前没有本 App 的登录项」）。
    case notRegistered
    /// 尚未查询（启动初态）。
    case unknown
}

/// 登录项开关控制器（开机启动偏好，规格 §2.4 接线）。
///
/// SMAppService 的登录项注册/注销/状态查询为同步 IPC——一体遵循 WP2 主线程纪律：
/// 后台执行 + 结果回主 actor；成功即经共享 store 的 actor 原子 update() 持久化
/// AppConfig（WP3 §3.1 评审 P0-1：与风格/引导完成标志字段互不覆盖）。
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
    /// 登录项注册态（通用 Tab 注册态行；refreshRegistration 后台查询回填）。
    @Published private(set) var registration: LoginItemRegistration = .unknown

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

    /// 注册态查询（通用 Tab onAppear 调用）：SMAppService.status 同步 IPC 后台
    /// 执行（主线程纪律），折叠后回主线程刷新显示。
    func refreshRegistration() {
        Task.detached { [weak self] in
            let folded = Self.fold(SMAppService.mainApp.status)
            await MainActor.run {
                self?.registration = folded
            }
        }
    }

    /// SMAppService.Status → 展示态折叠（nonisolated：后台上下文调用）。
    private nonisolated static func fold(_ status: SMAppService.Status) -> LoginItemRegistration {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    /// 开关切换：乐观置态 → 后台 register/unregister → 成功经 update() 只翻转
    /// 登录项标志持久化；失败回滚 + 反馈文案（错误原文，不静默）。
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
                _ = try await store.update { $0.launchAtLogin = on }
                let folded = Self.fold(SMAppService.mainApp.status)
                await MainActor.run {
                    guard let self else { return }
                    self.busy = false
                    self.registration = folded
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

    /// 重新注册（通用 Tab 修复按钮；App 移动/重建后登录项掉注册的修复路径）：
    /// register 同步 IPC 后台执行——主线程纪律；成功经 update() 置开偏好 + 刷新
    /// 注册态显示；失败上屏（不静默）。View 不直呼 SMAppService（评审 P2-2）。
    func reregister() {
        guard !busy else { return }
        busy = true
        feedback = nil
        Task.detached { [store, weak self] in
            do {
                try SMAppService.mainApp.register()
                _ = try await store.update { $0.launchAtLogin = true }
                let folded = Self.fold(SMAppService.mainApp.status)
                await MainActor.run {
                    guard let self else { return }
                    self.busy = false
                    self.launchAtLogin = true
                    self.registration = folded
                    self.feedback = "已重新注册开机启动"
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.busy = false
                    self.feedback = "重新注册失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
