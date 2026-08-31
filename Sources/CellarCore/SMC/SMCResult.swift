/// 驱动回包 offset 40 的结果码常量（macOS 26 实测定版）。
enum SMCResult {
    /// 成功。
    static let success: UInt8 = 0
    /// 键不存在 / 对当前身份不可见。
    static let keyNotFound: UInt8 = 132
    /// 缺少期望尺寸（如读输入 offset28 与 keyInfo 尺寸不符）→ 按 unexpectedResult 上抛。
    static let missingDataSize: UInt8 = 137
}
