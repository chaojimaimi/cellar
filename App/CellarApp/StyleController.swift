import CellarCore
import Foundation
import os

/// 面板风格控制器（WP3 §3.3 组合根接线）：启动异步 load 持久化 style →
/// validating 解析 → @Published style 驱动 environment 全树刷新。加载完成前呈现
/// .native——加载期闪变为登记的已知态（面板默认收起影响可忽略）。
///
/// 切换 = setStyle：内存先行（即时生效链路）→ 共享 store 的 actor 原子 update()
/// 写盘（评审 P0-1：与登录项/引导完成标志字段互不覆盖）；写失败回滚内存态 +
/// 反馈上屏（不静默）。
@MainActor
final class StyleController: ObservableObject {
    /// 当前生效风格（resolve 注入链的唯一输入；变更即触发全树重算）。
    @Published private(set) var style: PanelStyle = .native
    /// 持久化偏好是否已加载（设置外观 Picker 在 loaded 前禁用，防半程态回写）。
    @Published private(set) var loaded = false
    /// 风格写盘失败反馈（外观 Tab 上屏，不静默；成功切换时清空）。
    @Published private(set) var saveFeedback: String?

    private let store: AppConfigStore
    private let log = Logger(subsystem: "com.cellar", category: "app-config")

    init(store: AppConfigStore = AppConfigStore(url: AppConfigStore.defaultURL)) {
        self.store = store
        // load 必须随实例诞生自启动，禁止外部（如 CellarApp.init）调用——WP3 真机
        // 实证（2026-09-02）：外部在 App.init 中调用 load()，其 Task 醒来时实例已
        // 被释放、静默失效（loaded 恒 false）；自启动写法在两种实例生命周期模型下
        // 都安全（正式实例的 init 必自跑 load）。机制细节未深究，现象与修复为准。
        load()
    }

    /// 启动加载：未知 style（手改 JSON 等）→ error 日志（含原始值 + 重选指引，
    /// 不静默）并回退 native；nil = 未设置（默认合法态，不记日志）。⚠️ 仅回退
    /// 呈现、不回写修正用户文件（评审 P2-4：每次启动 log error 属预期行为）。
    private func load() {
        // 强捕获 self：一次性短任务，storage 自 init 起强持有本实例，无循环；
        // 弱捕获反而复现「临时实例中途释放→静默失效」形态（见 init 注释）。
        Task {
            let raw = await store.load().style
            if let resolved = PanelStyle.validating(raw) {
                style = resolved
            } else {
                if let raw {
                    log.error("app-config style 未知值「\(raw, privacy: .public)」，回退原生风格；请在设置→外观重新选择")
                }
                style = .native
            }
            loaded = true
        }
    }

    /// 切换风格（外观 Picker 唯一入口）：内存先行即时生效（§3.3 链路），随后经
    /// 共享 store 原子 update 写盘；写失败回滚内存态并上屏反馈（不静默）。
    /// loaded 前为视图层禁用兜底（防半程态回写）。
    func setStyle(_ newStyle: PanelStyle) {
        guard loaded, newStyle != style else { return }
        let previous = style
        style = newStyle
        saveFeedback = nil
        Task { [store, weak self] in
            do {
                // 原子读改写：只写 style 字段，launchAtLogin/onboardingCompleted 保持。
                _ = try await store.update { $0.style = newStyle.rawValue }
            } catch {
                // 仅当内存态仍是本次请求的目标（无后续切换接管）才回滚——防 stale
                // 回滚覆盖用户后续选择（native→amber 失败时 amber→native 已接管，
                // 回滚成 amber 会让 Picker 与磁盘背离）。
                guard let self, self.style == newStyle else { return }
                self.style = previous
                self.saveFeedback = "风格保存失败：\(error.localizedDescription)"
            }
        }
    }
}
