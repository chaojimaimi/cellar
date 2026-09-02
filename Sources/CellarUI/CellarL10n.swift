import Foundation

// MARK: - 本地化解析门面（WP4 §2.2，评审 P0-1 定版）

/// 跨模块唯一资源通路：`Bundle.module` 是 internal 访问器，App target 不可引用
/// ——全部串解析经本门面（内部固定查 CellarUI 资源 bundle）。**删除 bundle 参数
/// 双机制**（v1.0「默认 Bundle.main」作废——SwiftUI LocalizedStringKey 字面量
/// 入口走 Bundle.main，与 catalog 所在 bundle 错位 = 静默回退显示原文，无编译/
/// 运行错误，故必须单落点收口）。
///
/// 三路径核对（WP4 §2.2）：①App 宿主进程 ✓（xcodebuild 自动嵌入 package 资源
/// bundle）②CellarUICheck 进程 ✓（SPM 产物旁 bundle）③通知 ✓（compose 时在
/// App 进程内解析）。双档部署均可用。
///
/// **bundle 资源双形态（S1a 实证）**：同一 catalog 随构建系统不同落盘形态不同——
/// - xcodebuild：xcstrings 编译为 `<locale>.lproj/Localizable.strings`（标准
///   bundle 查找命中）；
/// - `swift build`：SwiftPM 仅**拷贝**原始 .xcstrings（无编译步骤，实查构建日志
///   "Copying"，bundle 内无 lproj）→ 标准查找 miss、`String(localized:)` 静默
///   返回 key。因此本门面在标准查找 miss 后回退解析原始 catalog（②路径），两条
///   构建链路的解析语义对齐；App 进程（编译形态）② 路径零命中、零开销。
public enum CellarL10n {
    /// 解析 key（可选格式化参数）。缺 key 时返回 key 本身（Foundation miss 同款
    /// 语义）——调用方不得依赖静默回退，--l10n 门禁负责缺译可见化。
    public static func s(_ key: String.LocalizationValue, _ args: CVarArg...) -> String {
        // key 文本还原：LocalizationValue 无公开 key 访问器，经
        // LocalizedStringResource 转换取（公开 API，S1a 实证可编译）。
        let keyText = LocalizedStringResource(key).key
        let format = value(forKey: keyText, localeIdentifier: preferredLocaleIdentifier)
        // 无参数直返原值：绕过 String(format:)，防串内 % 字面量被误当格式符。
        guard !args.isEmpty else { return format }
        return String(format: format, arguments: args)
    }

    /// 显式语言的解析（--l10n 门禁专用：逐 key × 逐语言断言，不依赖进程语言）。
    /// 常规解析走 `s(_:)`（按进程偏好语言）。
    public static func value(forKey key: String, localeIdentifier: String) -> String {
        // ① 编译形态：lproj 子 bundle 的标准查找（与 String(localized:) 同路径）。
        if let path = Bundle.module.path(forResource: localeIdentifier, ofType: "lproj"),
           let lproj = Bundle(path: path) {
            let value = lproj.localizedString(forKey: key, value: key, table: nil)
            if value != key { return value }
        }
        // ② 原始 catalog 形态：swift build 拷贝的 .xcstrings 直接解析。
        if let value = rawCatalogValue(forKey: key, locale: localeIdentifier) {
            return value
        }
        return key
    }

    /// 进程偏好语言与本 bundle 本地化的最优交集（s(_:) 的语言选择，与 Foundation
    /// 标准查找同判据）；空 bundle/无交集 → 开发语言 → 终值兜底 zh-Hans（catalog
    /// 源语言，defaultLocalization 对齐）。
    static var preferredLocaleIdentifier: String {
        Bundle.module.preferredLocalizations.first
            ?? Bundle.module.developmentLocalization
            ?? "zh-Hans"
    }

    // MARK: 原始 catalog 解析（② 路径）

    /// 原始 catalog 内存表（key → locale → value）。static let = 一次性线程安全
    /// 求值；编译形态进程（App 宿主）无 .xcstrings 资源 → nil，零解析开销。
    private static let rawCatalog: [String: [String: String]]? = loadRawCatalog()

    private static func loadRawCatalog() -> [String: [String: String]]? {
        guard let url = Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: Any] else {
            return nil
        }
        // xcstrings 形态：strings.<key>.localizations.<locale>.stringUnit.value。
        var table: [String: [String: String]] = [:]
        for (key, entryAny) in strings {
            guard let entry = entryAny as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else { continue }
            var perLocale: [String: String] = [:]
            for (locale, unitAny) in localizations {
                guard let unit = unitAny as? [String: Any],
                      let stringUnit = unit["stringUnit"] as? [String: Any],
                      let value = stringUnit["value"] as? String else { continue }
                perLocale[locale] = value
            }
            table[key] = perLocale
        }
        return table
    }

    private static func rawCatalogValue(forKey key: String, locale: String) -> String? {
        rawCatalog?[key]?[locale]
    }
}
