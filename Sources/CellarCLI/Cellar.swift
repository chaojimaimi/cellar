import ArgumentParser

/// cellar CLI 根命令（WP5 规格 §0.1 命令树）。
///
/// 读写子命令齐备：控制写路径（set/enable/disable）经 root 守护进程 XPC 执行，
/// 安装/卸载走 sudo 手工路线（与 App 的 SMAppService 托管路线互斥，双向守卫）。
@main
struct Cellar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cellar",
        abstract: "macOS 电池管理工具（限充管理 + 诊断；App 菜单栏面板见项目主页）",
        version: "0.2.0-alpha",
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