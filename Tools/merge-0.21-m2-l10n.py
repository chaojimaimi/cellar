#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""0.21.0 M2 批：l10n catalog 增量合并（§3.2 校准横幅 + §5 sub80 状态明细）。
新增文案清点（工单验收项）：
- panel.calibration.suspected.banner : 校准抑制横幅（§3.2 面板状态行/横幅）；
- panel.sub80.detail                 : sub80 状态明细行前缀（§5 功能概览页）；
- panel.sub80.state.active/degraded/hysteresis/off : 四态词（复用 Sub80StatusView
  词汇域——degraded/hysteresis 与既有横幅语汇同源措辞）；
- panel.sub80.healProgress           : 自愈探针进度行（§5 自愈进度）。
仅新增 key，不改既有条目；幂等：已存在的 key 一律跳过（重跑安全）。
"""
import json
import sys
from pathlib import Path

# 仓库根相对推导（照 merge-m3-l10n.py 先例——不硬编码私有绝对路径）。
CATALOG = Path(__file__).resolve().parents[1] / "Sources/CellarUI/Resources/Localizable.xcstrings"

# (key, zh, en)
NEW_KEYS = [
    # ---- §3.2 校准抑制横幅（面板；status/doctor 行为 CLI 恒中文不本地化）----
    ("panel.calibration.suspected.banner",
     "系统校准中（限充暂缓——校准结束自动恢复）",
     "System battery calibration in progress (charging limit paused — resumes automatically when it ends)"),
    # ---- §5 sub80 状态明细（功能概览页；参数驱动组件 Sub80StatusView）----
    ("panel.sub80.detail",
     "通道状态：%1$@",
     "Channel: %1$@"),
    ("panel.sub80.state.active",
     "执法承载中（topoff 通道）",
     "enforcing (topoff channel)"),
    ("panel.sub80.state.degraded",
     "已降级（回退 80% 钳制）",
     "degraded (fell back to 80%)"),
    ("panel.sub80.state.hysteresis",
     "迟滞备用通道执法中",
     "backup channel enforcing (CHIE hysteresis)"),
    ("panel.sub80.state.off",
     "已关断（限充释放）",
     "shut down (limit released)"),
    ("panel.sub80.healProgress",
     "自愈重探中（第 %1$@/%2$@ 拍）",
     "Self-heal probe %1$@/%2$@"),
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
    # 保序追加（0.21 M2 修正：不整包重排——Xcode canonical 顺序保留，仅尾部
    # 追加新 key；重建脚本实证 HEAD 字节级零扰动 + 纯追加最小 diff）。
    with open(CATALOG, "w", encoding="utf-8") as f:
        f.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    print(f"新增 {len(NEW_KEYS)} keys，catalog 总 key 数 = {len(data['strings'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
