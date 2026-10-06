import AppKit
import CellarCore
import Foundation
import os

// MARK: - 0.23.0 §⑥ GitHub 更新提示（第一档）——App 层更新检查器
//
// 网络面（SECURITY.md 声明同步）：**唯一出站请求** = `https://api.github.com/repos/
// chaojimaimi/cellar/releases/latest` 只读 GET（10s 超时；无遥测、无自动下载/安装
// ——第二档留待 Developer ID 决策，FAQ 透明化）。决策（是否新版）在 CellarCore
// AppVersion.isNewer 纯函数（CellarCoreCheck 场景域钉死），本类只做 IO 与节流。
//
// 节流纪律（红队 F11/F9 硬化）：
// - **失败静默不写节流戳**——网络失败/解析失败/畸形版本一律不动 lastCheckAt，
//   下次启动重试（成功〔含「无更新」结论〕才写 24h 节流戳）；
// - **同版本只通知一次**（lastNotifiedVersion 去重——手动检查绕过 24h 节流但不绕过
//   同版本去重）；手动检查直接绕过 24h 窗（用户显式意图优先）。
// - 结果经 @Published 透出（latestVersion/releaseURL?——关于页新版本行数据源）；
//   系统通知经 NotificationService.deliverUpdateAvailable（不扩
//   CellarNotificationEvent 枚举——防污染 notificationEvents 纯函数域）。

@MainActor
final class UpdateChecker: ObservableObject {
    /// 最新 release 版本（nil = 无新版 / 未检出 / 检查不可用）。
    @Published private(set) var latestVersion: String?
    /// 下载页 URL（**白名单校验后**才透出——scheme https ∧ host == github.com，
    /// 红 F10 fail-closed；nil = 不渲染「前往下载」）。
    @Published private(set) var releaseURL: URL?
    /// 手动检查进行中（按钮防重入）。
    @Published private(set) var checking = false

    /// 24h 节流戳（UserDefaults 键——成功检查才写）。⚠️ nonisolated static let
    ///（@MainActor 类的存储静态默认 actor 隔离——nonisolated 消费面在 nonisolated
    /// static 函数内）。
    private nonisolated static let lastCheckAtKey = "com.cellar.update.lastCheckAt"
    /// 同版本通知去重戳（红 F9——只通知一次）。
    private nonisolated static let lastNotifiedVersionKey = "com.cellar.update.lastNotifiedVersion"
    /// 节流窗（24h）。
    private nonisolated static let throttleInterval: TimeInterval = 24 * 3600
    /// 唯一出站端点（只读 releases/latest；无查询参数、无鉴权头、无遥测体）。
    private nonisolated static let releasesURL = URL(string: "https://api.github.com/repos/chaojimaimi/cellar/releases/latest")!
    /// 下载页白名单域（红 F10：仅 github.com over https——本库首个外部数据→open 面）。
    private nonisolated static let allowedDownloadHost = "github.com"

    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "update-checker")
    private let defaults: UserDefaults
    /// 通知出口（CellarApp 注入——deliverUpdateAvailable 直投，不走事件枚举）。
    var onUpdateAvailable: ((String) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 启动检查**不在 init 自启**（@StateObject 临时实例会预写节流戳挤掉幸存
        // 实例通知面）——挂 CellarApp MenuBarExtra scene .task 调 checkIfDue()。
    }

    /// 启动检查（节流门内跳过；手动入口绕本门）。
    func checkIfDue() {
        let last = defaults.object(forKey: Self.lastCheckAtKey) as? Date
        if let last, Date().timeIntervalSince(last) < Self.throttleInterval {
            return
        }
        Task { await performCheck() }
    }

    /// 手动检查结果（code-review P3：失败与「已是最新」必须分流——手动面造假
    /// 反馈违反诚实呈现纪律；后台检查不受影响仍静默）。
    enum CheckOutcome {
        case found
        case upToDate
        case failed
    }

    /// 关于页手动「检查更新」（绕 24h 节流——用户显式意图；**不绕同版本通知去重**
    /// ——红 F9 口径恒定；结果经返回值给按钮反馈，不经节流戳）。
    func checkNow() async -> CheckOutcome {
        return await performCheck(manual: true)
    }

    /// 检查执行体：请求 → 解析 tag_name → AppVersion.isNewer 判定 → 状态落地。
    /// 失败静默（os_log 可见化；**不写节流戳**——红 F11）；成功（含无更新）写戳。
    private func performCheck(manual: Bool = false) async -> CheckOutcome {
        guard !checking else { return .failed }
        checking = true
        defer { checking = false }
        var request = URLRequest(url: Self.releasesURL, timeoutInterval: 10)
        request.httpMethod = "GET"
        // GitHub API 需要 UA（缺失被 403）；静态串，无遥测语义。
        request.setValue("cellar-update-check", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Self.log.error("更新检查失败：HTTP \(String(describing: (response as? HTTPURLResponse)?.statusCode ?? -1))——静默跳过（不写节流戳，下拍/下次启动重试）")
                return .failed
            }
            guard let tag = Self.parseLatestTag(from: data) else {
                Self.log.error("更新检查失败：releases/latest 响应缺 tag_name——静默跳过（不写节流戳）")
                return .failed
            }
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            guard AppVersion.isNewer(current: current, latest: tag) else {
                // 无更新：成功结论——写节流戳（红 F11），清呈现态。
                Self.log.info("更新检查完成：当前 \(current, privacy: .public) 已是最新（latest \(tag, privacy: .public)）")
                defaults.set(Date(), forKey: Self.lastCheckAtKey)
                latestVersion = nil
                releaseURL = nil
                return .upToDate
            }
            // 有更新：判定成功同样写节流戳（24h 内不重复请求）；呈现态 + 同版本
            // 去重通知（手动检查不绕去重）。
            Self.log.info("更新检查完成：发现新版本 \(tag, privacy: .public)（当前 \(current, privacy: .public)）")
            defaults.set(Date(), forKey: Self.lastCheckAtKey)
            latestVersion = tag
            releaseURL = Self.sanitizedDownloadURL(from: tag)
            if defaults.string(forKey: Self.lastNotifiedVersionKey) != tag {
                defaults.set(tag, forKey: Self.lastNotifiedVersionKey)
                if !manual {
                    onUpdateAvailable?(tag)
                }
            }
            return .found
        } catch {
            // 失败静默：不写节流戳（红 F11——失败后下次启动立即重试）。
            Self.log.error("更新检查失败：\(error.localizedDescription)——静默跳过（不写节流戳）")
            return .failed
        }
    }

    /// 解析 releases/latest 响应的 tag_name（畸形/缺席 → nil——畸形在 isNewer 内
    /// 再折为 false，双保险）。
    private nonisolated static func parseLatestTag(from data: Data) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data),
            let dict = obj as? [String: Any],
            let tag = dict["tag_name"] as? String,
            !tag.isEmpty
        else { return nil }
        return tag
    }

    /// 下载页 URL 白名单校验（红 F10 fail-closed）：由 tag 构造 releases/tag 页；
    /// scheme 必须 https ∧ host 必须 == github.com，否则 nil（不渲染「前往下载」）。
    private nonisolated static func sanitizedDownloadURL(from tag: String) -> URL? {
        // tag 仅取安全字符构造路径段（字母数字 . - _ +）——防注入路径/查询分隔符。
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_+")
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        guard let url = URL(string: "https://github.com/chaojimaimi/cellar/releases/tag/\(trimmed)"),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == allowedDownloadHost
        else { return nil }
        return url
    }

    /// 「前往下载」执行（关于页消费；open 前二次白名单校验——呈现态可能跨会话
    /// 陈旧，open 面恒 fail-closed）。
    func openDownloadPage() {
        guard let url = releaseURL,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == Self.allowedDownloadHost else {
            Self.log.error("下载页打开拒绝：URL 白名单校验未过（fail-closed）")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
