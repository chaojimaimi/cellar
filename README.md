# Cellar（芯仓）

> Cell（电芯）+ Cellar（酒窖）——给 MacBook 电池一个"恒温恒湿"的储存环境。

[![CI](https://github.com/chaojimaimi/cellar/actions/workflows/ci.yml/badge.svg)](https://github.com/chaojimaimi/cellar/actions/workflows/ci.yml)

**开源的 Apple Silicon Mac 电池限充工具**：把电量维持在你设定的区间，避免长期满电插电存放损耗电池。菜单栏常驻 + CLI 控制，免费、开源、无遥测、无网络依赖。

> 状态：**0.2.0-alpha**——核心限充与菜单栏图形界面已随 0.2.0-alpha 发布，在 macOS 26 / Apple Silicon 真机完成端到端验收（安装 → 限充 → 放电恢复 → 睡眠唤醒 → 卸载）。欢迎试用与反馈，接口与行为可能调整。

## 功能

- **任意上限限充**（60–100%）：含系统原生不支持的低于 80% 区间
- **滞回保持**：充到上限即停，自放电至恢复阈值（默认上限 −2%）才重新充电，避免频繁启停
- **只读监测无需 root**：电量、充放状态、电压、电流、温度、循环次数、设计/满充容量、电芯电压、适配器详情
- **CLI + root daemon**：一次安装，开机自动管理；`doctor` 一键诊断

## 图形界面（App）

菜单栏图标常驻的图形界面（App/CellarApp.xcodeproj），与 CLI 共用同一套核心与守护进程。

### 功能概览

- **菜单栏电量面板**：电量弧、限充区间、实时状态行（电量 / 充放 / 控制键 / 模式），上限与滞回可面板直调
- **首启四步引导**：欢迎 → 环境检查（冲突门）→ 守护进程安装授权 → 设定上限
- **通知**：已达上限、写入失败、疑似外部写者冲突三类提醒（同类型 10 分钟冷却）
- **开机自启登录项**：随登录自动常驻菜单栏
- **内嵌 root 守护进程**：随 App 由系统框架（SMAppService）注册托管，App 更新随 bundle 整体升级

### 安装要求（必须）

**Cellar.app 必须放入 `/Applications`**。内嵌的 root 守护进程由 launchd 启动，实测 launchd 拒绝从家目录等深层路径 spawn 该进程（连续多次 spawn 失败，而同一二进制以用户态直跑正常）；装入 `/Applications` 后守护进程正常常驻。请勿从下载目录等位置直接运行 App。

### Gatekeeper 引导

App 为 ad-hoc 签名、未公证分发，首次打开若提示「App 已损坏」或无法打开：

1. **主路径**：终端执行 `xattr -cr /Applications/Cellar.app`，然后重新打开
2. **备选**：系统设置 → 隐私与安全性 →「仍要打开」

（macOS 15 起右击 →「打开」的旁路已被移除，请勿尝试。）

### 首启引导（4 步）

1. **欢迎**：Cellar 是什么、将安装 root 守护进程并接管限充（60% 下限说明）
2. **环境检查**：扫描本机其他充电管理类软件/守护进程；精确命中会阻断安装，疑似命中需确认后继续
3. **安装守护进程**：点击安装 → 系统设置「登录项」弹窗授权 → 授权完成自动继续
4. **设定上限**：选择限充目标（60–100%）与滞回带宽，完成

中途关闭面板不会丢失进度，重新打开可续走引导。

### 卸载

面板 → 卸载（注销守护进程、恢复系统默认充电），再将 Cellar.app 移入废纸篓。曾以 CLI 方式安装过手工 LaunchDaemon 的机器，面板会先给出迁移指引。

### 与其他充电管理工具互斥

Cellar 与其他充电管理类工具/守护进程应互斥使用：双方都可能改写同一充电控制键，同时运行会互相干扰（Cellar 的写入后回读校验会检测到外部写者并显式告警）。安装 Cellar 前请先停用或卸载其他充电管理软件。

## 系统要求

| 组件 | 要求 |
|---|---|
| 机型 | Apple Silicon MacBook |
| 系统 | macOS 26+（Tahoe 控制后端，真机验证）；更早系统为实验性 Legacy 后端（未验证） |
| 图形界面（App） | macOS 26+（硬性） |
| 权限 | 读取无需特权；写入经 root 守护进程（CLI 需 sudo；App 经系统设置授权，需管理员账户） |

## 构建与安装

需要 Swift 6 工具链（Xcode 或 Command Line Tools）；构建图形界面 App 需要 Xcode 26。

```bash
git clone https://github.com/chaojimaimi/cellar.git
cd cellar
swift build -c release

# 安装 root daemon（复制二进制 + 注册 LaunchDaemon + 启动）
sudo .build/release/cellar install
```

图形界面路线：用 Xcode 打开 `App/CellarApp.xcodeproj` 构建，将产物 **Cellar.app 放入 /Applications** 后运行（安装要求见「图形界面（App）」）。

## 使用

```bash
cellar status          # 状态一览（后端、电量、充放、控制键、daemon 状态）
cellar doctor          # 七项诊断报告（退出码 0/1/2 可用于脚本）
sudo cellar set 80     # 设置上限 80%（范围 60–100，可加 --hysteresis n）
sudo cellar disable    # 停用限充管理，恢复系统默认充电
sudo cellar enable     # 恢复限充管理
sudo cellar uninstall  # 卸载并恢复系统默认充电
```

- `cellar status` / `doctor` 无需 sudo 即可给出可信结论
- daemon 与 CLI 任一更新后，重跑 `sudo .build/release/cellar install` 即可升级
- `cellar doctor` 会检测机器上其他充电管理类工具/助手并给出共存警示

## 安全与设计

- **限充下限 60%**：三层强制（CLI 参数校验 / XPC 权限与复核 / daemon 策略构造），持久化文件同样无法绕过
- **可恢复性**：SIGTERM、disable、uninstall 均自动恢复系统默认充电；daemon 崩溃由 launchd 重拉并立即校对状态
- **最小权限**：读取无需特权；写入收敛到单一 root daemon；XPC 变更命令仅接受 root 或 admin 组（gid 80）成员调用，带类型白名单与限流
- **不静默失败**：写入后回读校验，校验失败（含外部写者冲突）类型化上报
- **无遥测、无网络**：除包解析外零第三方依赖

## 验证

```bash
swift run CellarCoreCheck   # 94 个场景、234 项检查：决策矩阵穷举（700+ 边界组合）、
                            # 封包/解析、XPC 校验、策略持久化、通知分类矩阵
```

硬件在环验收（安装 → 限充 → 放电恢复 → 睡眠唤醒 → 卸载）随版本发布执行，记录于 CHANGELOG。

## 路线图

- ✅ **Phase 2（已完成，0.2.0-alpha）**：菜单栏 App（GUI）、`install` 走系统框架、统计面板
- Phase 3+：三种内置界面风格（原生极简 / 酒窖琥珀 / 仪表盘工业）、校准模式、热保护、充电日程、Shortcuts 集成

完整路线图与设计文档见发布说明。

## 参与

Issue 与 PR 欢迎。提交前请运行 `swift run CellarCoreCheck` 确认全部 94 个场景通过；构建 App（图形界面）需要 Xcode 26。

## 许可

[GPL-3.0](LICENSE)

## 免责声明

本软件按"现状"提供（见 LICENSE 免责条款）。电池充放电行为存在硬件差异，请自行评估风险并保留系统恢复手段。