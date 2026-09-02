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
        // WP2' L1：与 DaemonXPC.daemonVersion 同步（0.3.1-alpha-dev——防 CLI 对
        // stale daemon 诊断混淆，评审 F-3 同款核对依据）。
        version: "0.3.1-alpha-dev",
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