import ArgumentParser

/// cellar CLI 根命令（WP5 规格 §0.1 命令树）。
///
/// 只读子命令（status/doctor）已可用；写路径子命令（set/enable/disable/
/// install/uninstall）为占位，由后续版本的充电管理守护进程提供。
@main
struct Cellar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cellar",
        abstract: "macOS 电池管理工具（只读诊断已可用；控制功能由后续版本提供）",
        version: "0.1.0-alpha-dev",
        subcommands: [
            StatusCommand.self,
            DoctorCommand.self,
            SetCommand.self,
            EnableCommand.self,
            DisableCommand.self,
            InstallCommand.self,
            UninstallCommand.self,
        ]
    )
}