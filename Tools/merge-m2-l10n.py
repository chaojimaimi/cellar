#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 5 v1.2 M2：l10n catalog 增量合并（224 → 313）。
对照 docs/design/dashboard-mock.html v2 全文案逐条清点（工单 7 必做产出），
zh/en 双语落地。仅新增 key，不改既有条目；写入前逐 key 断言不存在。
幂等：已存在的 key 一律跳过（重跑安全）。
"""
import json
import sys
from pathlib import Path

# 仓库根相对推导（照 CellarUICheck main.swift #filePath 先例）——
# 不硬编码私有绝对路径（公开仓库纪律，P2-1）。
CATALOG = Path(__file__).resolve().parents[1] / "Sources/CellarUI/Resources/Localizable.xcstrings"

# (key, zh, en) —— 全部 key 见 M2 工单 7 清点清单（与 mock v2 逐条对照）
NEW_KEYS = [
    # ---- 侧栏（主窗口路由 + footer 状态行）----
    ("main.window.title", "主窗口", "Main Window"),
    ("main.page.dashboard", "仪表板", "Dashboard"),
    ("main.page.control", "充电控制", "Charging Control"),
    ("main.page.stats", "统计", "Statistics"),
    ("main.page.calibration", "校准", "Calibration"),
    ("main.page.automation", "自动化", "Automation"),
    ("main.page.about", "外观与关于", "Appearance & About"),
    ("main.sidebar.status.connected", "daemon 已连接 · 执法中", "daemon connected · enforcing"),
    ("main.sidebar.status.unreachable", "daemon 未连接", "daemon unreachable"),
    ("main.sidebar.status.unknown", "daemon 状态未知", "daemon state unknown"),
    ("main.sidebar.route.appManaged", "路线：App 托管", "Route: app-managed"),
    ("main.sidebar.route.manual", "路线：手工 LaunchDaemon", "Route: manual LaunchDaemon"),
    ("main.sidebar.route.unknown", "路线：未知", "Route: unknown"),
    ("main.sidebar.policy", "上限 %lld%% · 滞回 %lld", "Limit %lld%% · Hysteresis %lld"),
    ("main.sidebar.policy.fan", " · 风扇 %@", " · Fan %@"),
    ("main.page.stats.version", "v1.3", "v1.3"),
    ("main.page.calibration.version", "v1.4", "v1.4"),
    ("main.page.automation.version", "v1.6", "v1.6"),
    ("main.page.version.alpha", "随 0.7.0-alpha 同批", "Ships with 0.7.0-alpha"),
    ("main.page.control.scope",
     "上限滑杆与预设（80/70/60）· 总开关 · 放电到上限 · 风扇降温入口——自菜单栏面板迁入主窗口，控制逻辑与安全门控零变化。",
     "Limit slider with presets (80/70/60) · master switch · discharge to limit · fan cooling entry — "
     "moved from the menu-bar panel into the main window, control logic and safety gates unchanged."),
    ("main.page.stats.scope",
     "电量 / 窖温 / 功耗历史曲线 · 最大容量趋势 · 循环与健康档案——SQLite 周期采样（后台分钟级，不成为耗电源）。",
     "Level / cellar temperature / power history · max-capacity trend · cycle and health archive — "
     "periodic SQLite sampling (minute-level in the background, never a power drain)."),
    ("main.page.calibration.scope",
     "校准调度与引导式流程（当前版本可在菜单栏面板发起一次性校准）——四相状态机可视化 + 完成度追踪。",
     "Calibration scheduling and guided flow (the current build can start one-shot calibration from the "
     "menu-bar panel) — four-phase state machine visualization + progress tracking."),
    ("main.page.automation.scope",
     "Shortcuts 捷径 · 充电日程（按星期/时段自动切换上限与总开关）· 场景联动。",
     "Shortcuts · charging schedules (auto-switch limit and master switch by weekday/time) · scene automation."),
    ("main.page.about.scope",
     "风格切换（原生 / 酒窖琥珀）· 诊断摘要复制 · 通用与高级设置并入侧栏——现有设置窗内容重组迁入。",
     "Style switching (Native / Cellar Amber) · diagnostic summary copy · general and advanced settings "
     "fold into the sidebar — existing settings window content is regrouped and moved in."),
    # ---- 仪表板头栏 ----
    ("dashboard.live", "实时 · 1s 采样", "Live · 1s sampling"),
    ("dashboard.lowPower.on", "低电量模式 · 开", "Low Power Mode · On"),
    ("dashboard.lowPower.off", "低电量模式 · 关", "Low Power Mode · Off"),
    ("dashboard.state.charging", "充电中 · 酒液入窖", "Charging · wine into the cellar"),
    ("dashboard.state.holding", "已停充 · 窖藏中", "Paused · stored in the cellar"),
    ("dashboard.state.battery", "电池供电 · 开窖出行", "On battery · uncorked on the go"),
    # ---- 英雄区面板头 ----
    ("dashboard.panel.flow", "功率流向", "Power Flow"),
    ("dashboard.panel.flow.subtitle", "电池侧实测口径 · V×I", "Battery-side measurement · V×I"),
    ("dashboard.panel.gauge", "藏酒量", "Cellar Level"),
    ("dashboard.panel.gauge.subtitle", "限充区间弧 %lld–%lld%%", "Limit band %lld–%lld%%"),
    # ---- 四指标带 ----
    ("dashboard.tile.temp", "窖温", "Cellar Temp"),
    ("dashboard.tile.temp.sub", "电池组 · B0AT", "Battery Pack · B0AT"),
    ("dashboard.tile.time.charging", "满电还需", "Time to Full"),
    ("dashboard.tile.time.battery", "预计可用", "Est. Remaining"),
    ("dashboard.tile.time.sub.charging", "按当前速率外推", "At current rate"),
    ("dashboard.tile.time.sub.holding", "已停充 · 不适用", "Paused · n/a"),
    ("dashboard.tile.time.sub.battery", "按近 15 分钟功耗外推", "From last 15 minutes of draw"),
    ("dashboard.tile.health", "电池健康", "Battery Health"),
    ("dashboard.tile.health.sub", "标称 / 设计容量", "Nominal / Design Capacity"),
    ("dashboard.tile.cycle", "循环次数", "Cycle Count"),
    ("dashboard.tile.cycle.sub", "官方口径", "Official Metric"),
    # ---- 时间展示粒度 ----
    ("dashboard.time.unit.minute", "分钟", "min"),
    ("dashboard.time.unit.hour", "小时", "h"),
    ("dashboard.time.unit.minutePart", "分", "min"),
    # ---- 电池规格卡 ----
    ("dashboard.card.spec", "电池规格", "Battery Specs"),
    ("dashboard.card.spec.capacity", "当前电量", "Current Charge"),
    ("dashboard.card.spec.design", "设计容量", "Design Capacity"),
    ("dashboard.card.spec.power", "功率", "Power"),
    # ---- 电池健康卡 ----
    ("dashboard.card.health.nominalDesign", "标称 %lld · 设计 %lld mAh", "Nominal %lld · Design %lld mAh"),
    ("dashboard.card.health.maxCapacity", "最大容量", "Max Capacity"),
    # ---- 适配器卡 ----
    ("dashboard.card.adapter.rated", "额定功率", "Rated Power"),
    ("dashboard.card.adapter.voltage", "适配器电压", "Adapter Voltage"),
    ("dashboard.card.adapter.current", "适配器电流", "Adapter Current"),
    ("dashboard.card.adapter.type", "类型", "Type"),
    ("dashboard.card.adapter.status", "状态", "Status"),
    ("dashboard.card.adapter.status.charging", "直供 + 充电", "Direct + Charging"),
    ("dashboard.card.adapter.status.holding", "直供系统", "Direct Supply"),
    ("dashboard.card.adapter.empty", "适配器未接入", "Adapter Not Connected"),
    ("dashboard.card.adapter.emptyHint", "接入后显示规格与实时状态", "Connect to see specs and live status"),
    ("dashboard.card.adapter.type.wireless", "无线", "Wireless"),
    ("dashboard.card.adapter.type.wired", "有线", "Wired"),
    # ---- 三角图数据行（App 侧组装串）----
    ("dashboard.adapter.line.present", "%lld W · 在位", "%lld W · Connected"),
    ("dashboard.adapter.line.absent", "未接入", "Not Connected"),
    ("dashboard.sysLine.load", "%.1f W 负载", "%.1f W Load"),
    ("dashboard.flow.powerIn", "%+.1f W", "%+.1f W"),
    ("dashboard.flow.powerOut", "%.1f W", "%.1f W"),
    ("dashboard.supply", "直供", "Direct"),
    # ---- 功率流三角图（组件内文案 flow.*）----
    ("flow.node.system", "系统", "System"),
    ("flow.node.battery", "电池", "Battery"),
    ("flow.batterySubline", "%lld%% · %@", "%lld%% · %@"),
    ("flow.edge.neutralAB", "— 不流动 —", "— No Flow —"),
    ("flow.edge.neutralBS", "— 已停充 —", "— Paused —"),
    ("flow.ax.charging", "功率流：充电中，%lld%% 电量，%@ 入电池，%@",
     "Power flow: charging, %lld%% level, %@ into battery, %@"),
    ("flow.ax.holding", "功率流：已停充，%lld%% 电量，%@ 直供系统",
     "Power flow: paused, %lld%% level, %@ to system"),
    ("flow.ax.battery", "功率流：电池供电，%lld%% 电量，%@ 出电池",
     "Power flow: on battery, %lld%% level, %@ from battery"),
    ("flow.ax.nodata", "功率流：遥测不可用", "Power flow: telemetry unavailable"),
    # ---- 藏酒环 hero 副词 ----
    ("gauge.target", "TARGET %lld–%lld%%", "TARGET %lld–%lld%%"),
    # ---- 通用占位 ----
    ("common.nodata", "—", "—"),
    # ---- 仪表板单位词（tile/卡片的数值单位，双语落地）----
    ("dashboard.unit.percent", "%", "%"),
    ("dashboard.unit.count", "次", "cycles"),
    ("dashboard.unit.celsius", "°C", "°C"),
    ("dashboard.unit.volt", "V", "V"),
    ("dashboard.unit.ampere", "A", "A"),
    ("dashboard.unit.watt", "W", "W"),
    ("dashboard.unit.milliampereHour", "mAh", "mAh"),
]


def main() -> int:
    with open(CATALOG, encoding="utf-8") as f:
        data = json.load(f)
    strings = data["strings"]
    existing = set(strings.keys())
    for key, zh, en in NEW_KEYS:
        if key in existing:
            print(f"skip（已存在）: {key}")
            continue
        strings[key] = {
            "extractionState": "manual",
            "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": en}},
                "zh-Hans": {"stringUnit": {"state": "translated", "value": zh}},
            },
        }
    # 字典序重排（与既有文件风格一致：keys 全量排序）
    data["strings"] = dict(sorted(strings.items(), key=lambda kv: kv[0]))
    with open(CATALOG, "w", encoding="utf-8") as f:
        f.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    print(f"新增 {len(NEW_KEYS)} keys，catalog 总 key 数 = {len(data['strings'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())