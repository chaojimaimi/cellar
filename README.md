# Cellar（芯仓）

> Cell（电芯）+ Cellar（酒窖）— 给 MacBook 电池一个"恒温恒湿"的储存环境。

**精致、可靠、完全开源的 Apple Silicon Mac 电池管理工具**（自主设计与开发，免费，无遥测）：
菜单栏 App + CLI + root 守护进程，把电量维持在你设定的区间，避免长期满电存放损耗电池。

**状态：规划中（pre-alpha）**。实施计划与长期路标见 [PLAN.md](PLAN.md)。

## 功能（按路标推进）

- ✅（计划 v0.1）任意上限限充（60–100%，含系统原生不支持的低于 80% 区间）
- ✅（计划 v0.1）区间保持（滞回控制，避免频繁启停充电）
- ✅（计划 v0.3）放电到上限 / 一次性充满
- ✅（计划 v0.3）菜单栏面板：环形电量仪表、温度/电流电压、快捷预设
- ✅（计划 v0.3）三种内置界面风格（原生极简 / 酒窖琥珀 / 仪表盘工业）随时切换，深浅色自适应
- 🗓（计划 v1.2）实时仪表板：功率流、电池规格与健康、电源适配器规格、电池温度、满电/剩余时间
- 🗓（计划 v1.x）历史曲线、校准模式、热保护、充电日程、Shortcuts 自动化

## 技术概要

- 支持：Apple Silicon MacBook + macOS 26+（全系，社区共建兼容矩阵）
- 机制：IOKit 读写 SMC 充电控制键（firmware 后端 `bfD0`/`bfE0`/`bfF0` 优先，legacy `CH0B`/`CH0C` 兜底，运行时探测自动选择）
- 架构：SwiftUI 菜单栏 App + root 守护进程（XPC，SMAppService 注册），核心逻辑独立为 CellarCore 包
- CLI：`cellar status / set / enable / disable / doctor`

## UI 风格提案

菜单栏面板的三种视觉方向（含深浅色与「风格切换」交互预览）见 [docs/design/style-demo.html](docs/design/style-demo.html)。
三种风格全部内置、可随时切换；默认风格为「酒窖琥珀」。

## ⚠️ 安全红线

- 限充下限 60%（防止深放电）
- 退出/崩溃/卸载自动恢复系统默认充电，`cellar disable` 一键还原
- 运行前须退出其他电池管理工具（会互相冲突）
- 本工具按"现状"提供，不构成电池保养建议，使用风险自负（详见 LICENSE 免责条款）

## 参与贡献

仓库：<https://github.com/chaojimaimi/cellar>
路线图、里程碑与待决问题见 [PLAN.md](PLAN.md)；设备兼容性报告与贡献流程将在 v0.1 就绪。

## 许可

[GPL-3.0](LICENSE)。
