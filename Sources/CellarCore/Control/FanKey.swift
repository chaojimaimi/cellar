import Foundation

// MARK: - Phase 5 v1.12 M1 风扇键名帮助函数（方案 §2-D2/§4 M1）

/// 风扇 SMC 键名帮助函数（F0/F1 各五键，同构——spike U5' 实证键族定版，
/// docs/SMC-NOTES.md §10）。
///
/// WHY（唯一字符串真相源）：daemon 写/读/探测路径的键名全部经本枚举取，
/// 杜绝手写 "F1Tg" 类字面量的拼写回归——键名错 = 写错硬件寄存器。帮助函数
/// 自身的字符串形态由 CellarCoreCheck 命名钉场景全量钉死（"F0Tg"/"F1Tg" 等
/// 十键逐字断言），防帮助函数拼错时静默生成非法键。
public enum FanKey {
    /// 模式寄存器（"F0Md"/"F1Md"；0=系统自动 1=手动直写——Md=0 下 Tg 写固件级拒绝）。
    public static func md(_ index: Int) -> String { "F\(index)Md" }
    /// 目标转速（"F0Tg"/"F1Tg"；flt LE，Md=1 手动态驻留可写）。
    public static func tg(_ index: Int) -> String { "F\(index)Tg" }
    /// 当前实际转速（"F0Ac"/"F1Ac"；flt LE，Md=0/1 下都活跃——写跟随证据源）。
    public static func ac(_ index: Int) -> String { "F\(index)Ac" }
    /// 下界转速（"F0Mn"/"F1Mn"；只读 clamp 下界——U6 实测写必被拒 result=134）。
    public static func mn(_ index: Int) -> String { "F\(index)Mn" }
    /// 上界转速（"F0Mx"/"F1Mx"；只读 clamp 上界）。
    public static func mx(_ index: Int) -> String { "F\(index)Mx" }
}
