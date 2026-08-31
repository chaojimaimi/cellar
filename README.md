# Cellar（芯仓）

> Cell（电芯）+ Cellar（酒窖）——给 MacBook 电池一个"恒温恒湿"的储存环境。

[![CI](https://github.com/chaojimaimi/cellar/actions/workflows/ci.yml/badge.svg)](https://github.com/chaojimaimi/cellar/actions/workflows/ci.yml)

**开源的 Apple Silicon Mac 电池限充工具**：把电量维持在你设定的区间，避免长期满电插电存放损耗电池。菜单栏常驻 + CLI 控制，免费、开源、无遥测、无网络依赖。

> 状态：**0.1.0-alpha**——核心限充已在 macOS 26 / Apple Silicon 真机端到端验证，无 GUI（菜单栏 App 在路线图中）。欢迎试用与反馈，接口与行为可能调整。

## 功能

- **任意上限限充**（60–100%）：含系统原生不支持的低于 80% 区间
- **滞回保持**：充到上限即停，自放电至恢复阈值（默认上限 −2%）才重新充电，避免频繁启停
- **只读监测无需 root**：电量、充放状态、电压、电流、温度、循环次数、设计/满充容量、电芯电压、适配器详情
- **CLI + root daemon**：一次安装，开机自动管理；`doctor` 一键诊断
- 三种内置界面风格（原生极简 / 酒窖琥珀 / 仪表盘工业）为路线图项（Phase 2）

## 系统要求

| 组件 | 要求 |
|---|---|
| 机型 | Apple Silicon MacBook |
| 系统 | macOS 26+（Tahoe 控制后端，真机验证）；更早系统为实验性 Legacy 后端（未验证） |
| 权限 | 读取无需特权；**写入/限充需要 root**（LaunchDaemon） |

## 构建与安装

需要 Swift 6 工具链（Xcode 或 Command Line Tools）。

```bash
git clone https://github.com/chaojimaimi/cellar.git
cd cellar
swift build -c release

# 安装 root daemon（复制二进制 + 注册 LaunchDaemon + 启动）
sudo .build/release/cellar install
```

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
- **最小权限**：读取无需特权；写入收敛到单一 root daemon；XPC 变更命令仅接受 root 调用方，带类型白名单与限流
- **不静默失败**：写入后回读校验，校验失败（含外部写者冲突）类型化上报
- **无遥测、无网络**：除包解析外零第三方依赖

## 验证

```bash
swift run CellarCoreCheck   # 76 个场景：决策矩阵穷举（700+ 边界组合）、
                            # 封包/解析、XPC 校验、策略持久化
```

硬件在环验收（安装 → 限充 → 放电恢复 → 睡眠唤醒 → 卸载）随版本发布执行，记录于 CHANGELOG。

## 路线图

- Phase 2：菜单栏 App（GUI）、`install` 走系统框架、统计面板
- Phase 3+：校准模式、热保护、充电日程、Shortcuts 集成

完整路线图与设计文档见发布说明。

## 参与

Issue 与 PR 欢迎。提交前请运行 `swift run CellarCoreCheck` 确认全部场景通过。

## 许可

[GPL-3.0](LICENSE)

## 免责声明

本软件按"现状"提供（见 LICENSE 免责条款）。电池充放电行为存在硬件差异，请自行评估风险并保留系统恢复手段。
