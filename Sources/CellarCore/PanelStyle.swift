import Foundation

// MARK: - 面板风格（Phase 3 WP3 §3.1：解析层枚举，存储保持 String?）

/// 面板风格。只活在解析层：AppConfig.style 保持 `String?` 线格式不变（新旧 App
/// 互读兼容），enum 仅经 validating 解析产生，不直接参与持久化。
public enum PanelStyle: String, Sendable {
    /// 系统原生（默认基线：语义色 + 系统容器材质）。
    case native
    /// 酒窖琥珀（Phase 3 WP3 B 风格）。
    case amber

    /// 解析持久化的原始值。返回 nil 的两种语义由调用方日志分界：
    /// - 入参 nil = 「未设置」（用户从未选择过，取 native 属默认合法态，**不记日志**）；
    /// - 入参非 nil 返回 nil = 「未知值」（手改 JSON 等——调用方须 os_log error
    ///   含原始值 + 重选指引，不静默）。
    ///
    /// 大小写敏感（"Amber"/空串等 → nil，走未知值路径）。
    public static func validating(_ raw: String?) -> PanelStyle? {
        guard let raw else { return nil }
        return PanelStyle(rawValue: raw)
    }

    /// 语汇本地化 key（App target Localizable.xcstrings 的词条名，§3.6）：
    /// `"vocabulary.<style>.<word>"`（例：vocabulary.amber.statusHoldingExternal）。
    /// 纯函数，CellarCoreCheck 可钉死形态。
    public static func vocabularyKey(style: PanelStyle, word: VocabularyWord) -> String {
        "vocabulary.\(style.rawValue).\(word.rawValue)"
    }
}

// MARK: - 语汇词条（WP3 §3.5 对账表定版成员）

/// 面板语汇词条枚举——只收录真实渲染面（§3.5 对账表定版 7 词条 + WP2' 新增 4）。
/// WP2' 新增词条（powerFlow×3 + health×1，en 译文随本包 catalog 先行——时序声明
/// WP4 S3 本地化串冻结显式排后）。
///
/// **显式延后，不建词条、不留死键**（§3.5/§1.7 克制原则裁定）：badge 行（demo
/// 「窖藏中」徽章——现 UI 无宿主，交付须新增面板头部行，预算外）；告警词（与
/// 「错误横幅不 B 化」规则冲突，横幅外无宿主）；g-st 状态词（GaugeView 中心现
/// 仅数字）。同理恒不 B 化：一切数字/单位/参数语义（80%、60 地板、滞回幅度、
/// 版本行）、错误横幅/控制反馈、无障碍标签（gaugeAxLabel 等）、安装区/引导文案、
/// 通知文案常量（与 lastAction 契约同源）。
public enum VocabularyWord: String, CaseIterable, Sendable {
    /// 电源段充电态（native「外接 · 充电中」）。
    case statusChargingExternal
    /// 电源段停充态（native「外接 · 已停充」）。
    case statusHoldingExternal
    /// 电源段电池态（native「电池供电」）。
    case statusBattery
    /// 动作区一次性充满按钮（native「充满一次：…」，amber 含「醒酒 · 」前缀）。
    case actionFullOnce
    /// 面板页脚退出按钮（native「退出 Cellar」）。
    case quit
    /// 状态行温度段标签（native「温度」）。
    case tempLabel
    /// 控制区上限标签（native「充电上限」）。
    case limitLabel
    /// WP2' 功率流向短标签——充电中（PowerFlowView；en: Charging）。
    case powerFlowCharging
    /// WP2' 功率流向短标签——外接停充漂浮（PowerFlowView；en: Floating）。
    case powerFlowFloating
    /// WP2' 功率流向短标签——电池供电（PowerFlowView；en: On Battery）。
    case powerFlowOnBattery
    /// WP2' 健康度段标签（StatusLineView 循环段「… · 健康 N%」；en: Health）。
    case healthLabel
}
