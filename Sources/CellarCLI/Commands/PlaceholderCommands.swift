import ArgumentParser

/// 占位子命令（WP5 只交付只读路径；写路径由后续版本的充电管理守护进程提供）。
///
/// 契约（规格 §0.1）：
/// - 指引文案固定一句，不出现任何内部工作包编号；
/// - 退出码 69（EX_UNAVAILABLE，避免与 doctor 的 2 撞语义）；
/// - 除接受参数外不实现任何逻辑。
enum PlaceholderGuides {
    static let unavailableMessage = "此子命令将由充电管理守护进程提供，请先运行 cellar install（后续版本）"

    static func failUnavailable() throws -> Never {
        print(unavailableMessage)
        throw ExitCode(69)
    }
}

/// cellar set —— 设置限充百分比（后续版本提供）。
struct SetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "设置限充百分比（后续版本提供）"
    )

    /// 限充上限百分比（仅接受参数以便 `cellar set 80` 形式成立；不处理）。
    @Argument var threshold: Int?

    func run() throws {
        try PlaceholderGuides.failUnavailable()
    }
}

/// cellar enable —— 允许充电（后续版本提供）。
struct EnableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "允许充电（后续版本提供）"
    )

    func run() throws {
        try PlaceholderGuides.failUnavailable()
    }
}

/// cellar disable —— 停止充电（后续版本提供）。
struct DisableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "停止充电（后续版本提供）"
    )

    func run() throws {
        try PlaceholderGuides.failUnavailable()
    }
}

/// cellar install —— 安装充电管理守护进程（后续版本提供）。
struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "安装充电管理守护进程（后续版本提供）"
    )

    func run() throws {
        try PlaceholderGuides.failUnavailable()
    }
}

/// cellar uninstall —— 卸载充电管理守护进程（后续版本提供）。
struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "卸载充电管理守护进程（后续版本提供）"
    )

    func run() throws {
        try PlaceholderGuides.failUnavailable()
    }
}