#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 5 v1.2 走查修复批：l10n catalog 增量合并（311 → 314）。

工单 1/3 文案变更清点（方案 §2 F1/F3）：
- 新增 10 key：vocabulary.*.dashboard*（5 词条 × {amber, native} 双风格——
  仪表板五处文案词汇化，F1 §2.1 对账表）；
- 更新 1 key：flow.ax.holding 改单参数串（F3 §2.5——移除 supplyLine 实参，
  zh「功率流：已停充，%@ 电量，适配器直供系统」/ en 对应）；
- 删除 7 key：flow.edge.neutralAB/BS（F3 §2.3 中性虚线标签失效）+ dashboard.
  state.{charging,holding,battery}/dashboard.panel.gauge/dashboard.tile.temp
  （F1 §2.4 死 key——消费点替换后零引用）。

只增删改上述 key，不动其余条目；写入前逐 key 断言。幂等：已存在的 key
一律跳过（重跑安全），目标 key 删除幂等。
"""
import json
import sys
from pathlib import Path

# 仓库根相对推导（照 CellarUICheck main.swift #filePath 先例）。
CATALOG = Path(__file__).resolve().parents[1] / "Sources/CellarUI/Resources/Localizable.xcstrings"

# (key, zh, en) —— F1 对账表：amber = 酒窖语汇 / native = 直白中性词。
NEW_KEYS = [
    # ---- amber 五词条（酒窖语汇，en 侧 cellar 味）----
    ("vocabulary.amber.dashboardGaugeTitle", "藏酒量", "Wine Reserve"),
    ("vocabulary.amber.dashboardTileTemp", "窖温", "Cellar Temp"),
    ("vocabulary.amber.dashboardStateCharging", "充电中 · 酒液入窖", "Charging · Must into the cellar"),
    ("vocabulary.amber.dashboardStateHolding", "已停充 · 窖藏中", "Holding · In the cellar"),
    ("vocabulary.amber.dashboardStateBattery", "电池供电 · 开窖出行", "On Battery · Cellar outing"),
    # ---- native 五词条（直白中性）----
    ("vocabulary.native.dashboardGaugeTitle", "电量", "Charge Gauge"),
    ("vocabulary.native.dashboardTileTemp", "温度", "Temperature"),
    ("vocabulary.native.dashboardStateCharging", "充电中", "Charging"),
    ("vocabulary.native.dashboardStateHolding", "已停充", "Holding"),
    ("vocabulary.native.dashboardStateBattery", "电池供电", "On Battery"),
]

# F3 §2.5：flow.ax.holding 改单参数串（移除 supplyLine 实参）。
UPDATE_KEYS = {
    "flow.ax.holding": (
        "功率流：已停充，%@ 电量，适配器直供系统",
        "Power flow: paused, %@ level, adapter supplies the system directly",
    ),
}

# F1 §2.4 死 key + F3 §2.3 中性虚线标签 key。
REMOVE_KEYS = [
    "flow.edge.neutralAB",
    "flow.edge.neutralBS",
    "dashboard.state.battery",
    "dashboard.state.charging",
    "dashboard.state.holding",
    "dashboard.panel.gauge",
    "dashboard.tile.temp",
]


def main() -> int:
    with open(CATALOG, encoding="utf-8") as f:
        data = json.load(f)
    strings = data["strings"]

    for key in REMOVE_KEYS:
        if key not in strings:
            print(f"skip（不存在，幂等）: {key}")
            continue
        del strings[key]
        print(f"删除: {key}")

    for key, (zh, en) in UPDATE_KEYS.items():
        if key not in strings:
            print(f"错误：待更新 key 不存在: {key}")
            return 1
        loc = strings[key]["localizations"]
        loc["zh-Hans"]["stringUnit"]["value"] = zh
        loc["en"]["stringUnit"]["value"] = en
        print(f"更新: {key}")

    for key, zh, en in NEW_KEYS:
        if key in strings:
            print(f"skip（已存在）: {key}")
            continue
        entry = {
            "extractionState": "manual",
            "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": en}},
                "zh-Hans": {"stringUnit": {"state": "translated", "value": zh}},
            },
        }
        # 就近插入保持 vocabulary.<style>.* 子块字典序（全域重排会 churn 无关行）。
        style_prefix: str = key[: key.rindex(".") + 1]
        after = [k for k in strings if k.startswith(style_prefix) and k < key]
        before = [k for k in strings if k.startswith(style_prefix) and k > key]
        anchor = after[-1] if after else None
        # 构造新有序 dict：在 anchor 之后逐 key 重建（锚点后整体重排该子块）。
        new_strings: dict = {}
        inserted = False
        for k, v in strings.items():
            new_strings[k] = v
            if k == anchor:
                new_strings[key] = entry
                inserted = True
        if not inserted:
            print(f"错误：插入锚点缺失: {key}（anchor={anchor}）")
            return 1
        # 断言锚点子块内排序仍成立（同前缀子块键全部有序）。
        block = sorted(k for k in new_strings if k.startswith(style_prefix))
        if block != [k for k in new_strings if k.startswith(style_prefix)]:
            print(f"错误：插入后子块乱序: {style_prefix}")
            return 1
        strings = new_strings
        print(f"新增: {key}（anchor: {anchor}）")

    data["strings"] = strings
    with open(CATALOG, "w", encoding="utf-8") as f:
        f.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    print(f"合并完成，catalog 总 key 数 = {len(data['strings'])}（目标 314）")
    return 0


if __name__ == "__main__":
    sys.exit(main())