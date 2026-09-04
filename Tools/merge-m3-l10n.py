#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 5 v1.2 M3：l10n catalog 增量合并（313 → 315）。
M3 迁移页新增文案清点（工单 5 必做产出）：
- panel.footerMainWindow ：页脚三链接左端「主窗口」入口（§2.1/§4.2）；
- about.datasource     ：关于内容尾部数据源说明行（UD-2，§4.2）。
工单 1-4 其余文案全部复用既有 key（控制页复用 panel.* 与 main.page.control，
外观与关于页复用 settings.* 与 main.page.about——零新增）。
仅新增 key，不改既有条目；写入前逐 key 断言不存在。幂等：已存在的 key
一律跳过（重跑安全）。
"""
import json
import sys
from pathlib import Path

# 仓库根相对推导（照 CellarUICheck main.swift #filePath 先例）——
# 不硬编码私有绝对路径（公开仓库纪律，P2-1）。
CATALOG = Path(__file__).resolve().parents[1] / "Sources/CellarUI/Resources/Localizable.xcstrings"

# (key, zh, en)
NEW_KEYS = [
    # ---- 页脚三链接（§2.1 主窗口入口；LSUIElement 前置修正见 App 侧薄包装）----
    ("panel.footerMainWindow", "主窗口", "Main Window"),
    # ---- 关于页数据源说明（UD-2：IO 直读只读监测，不写 SMC）----
    ("about.datasource",
     "数据源：AppleSmartBattery（IOKit 直读）· SMC 只读键 · IOPowerSources——纯只读监测，不写 SMC",
     "Data source: AppleSmartBattery (read via IOKit) · SMC read-only keys · IOPowerSources — "
     "read-only monitoring, never writes to SMC"),
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