#!/usr/bin/env python3
# MARK: - Cellar macOS 27 powerd 原生限充 spike（0.19.10 M0，写实验需 root）
#
# 用途：验证 powerd 原生充电策略（/Library/Preferences/com.apple.powerd.charging.plist，
# v1.7 测绘的 ChargeCtrlPolicy NSKeyedArchiver）能否作为 macOS 27 上的限充执法后端。
#
# ⚠️ 三步协作流程（每步后观察充电状态）：
#   1) 系统设置 → 电池 → 充电上限 设为 85%（任意档）→ 触发 powerd 注册真实策略
#   2) sudo python3 Tools/spike-macos27-powerd.py capture
#      → 解码真实归档骨架存 /tmp/powerd-policy-capture.json（后续复制的模板）
#   3) sudo python3 Tools/spike-macos27-powerd.py set 75
#      → 按捕获骨架改写 soclimit=75（低于 UI 范围 80-100 的表达力探针）
#      观察：充电是否停止/系统设置 UI 是否显示 75%
#   4) sudo python3 Tools/spike-macos27-powerd.py status   # 随时查现状
#   5) sudo python3 Tools/spike-macos27-powerd.py clear    # 恢复空策略（收尾必做）
#
# 预注册判据：
#   [判据一] capture 解码出 ChargeCtrlPolicy 对象（soclimit/reason 字段在）→ 归档
#            骨架可复制（set 有效的保真前提）；解码失败 → 本路线 NO-GO
#   [判据二] set 75 后：System Settings 显示 75% 或充电在 75% 停止 → powerd 接受
#            超范围值（Cellar 日程 75 可完整表达）；显示钳到 80 → Cellar 侧钳制
#   [判据三] set 后充电行为变化（Amperage→0 / NotChargingReason 位 2^24）→ plist
#            写入即可生效（无需 mach 通道）→ Cellar 后端可实施；无变化 → 需
#            powerd 触发面（killall -HUP / mach 逆向），风险升级再评估
#
# 安全：set/clear 仅写 powerd 策略 plist（root）；clear 恢复空数组即升级前原态。
#       全程不动 SMC 键。

import plistlib, sys, os, uuid, json, subprocess

PLIST = "/Library/Preferences/com.apple.powerd.charging.plist"
CAPTURE = "/tmp/powerd-policy-capture.json"

def load():
    with open(PLIST, "rb") as f:
        return plistlib.load(f)

def save(d):
    with open(PLIST, "wb") as f:
        plistlib.dump(d, f, fmt=plistlib.FMT_BINARY)

def decode_policies(d):
    pol = d.get("policies")
    if isinstance(pol, bytes):
        return plistlib.loads(pol)
    return pol

def battery_snapshot():
    out = subprocess.run(
        ["ioreg", "-r", "-c", "AppleSmartBattery"],
        capture_output=True, text=True).stdout
    import re
    def g(k):
        m = re.search(r'"%s"=([0-9-]+)' % k, out)
        return m.group(1) if m else "?"
    amp = re.search(r'"Amperage"=(-?\d+)', out)
    return {"percent": g("CurrentCapacity"), "isCharging": g("IsCharging"),
            "amperage": amp.group(1) if amp else "?"}

def cmd_probe():
    """CFPreferences 通道 vs 裸文件对照——27 头号嫌疑：直写/直读文件被 cfprefsd 架空。"""
    print("== CFPreferences 通道（cfprefsd 实时值）==")
    for domain in ["/Library/Preferences/com.apple.powerd.charging",
                   "com.apple.powerd.charging",
                   "com.apple.batteryui.charging.mac"]:
        r = subprocess.run(["defaults", "read", domain], capture_output=True, text=True)
        head = (r.stdout.strip() or r.stderr.strip())[:400]
        print(f"-- {domain} --\n{head}")
    print("== 电池实况 ==")
    print(battery_snapshot())
    print("== pmset 充电相关 ==")
    r = subprocess.run(["pmset", "-g"], capture_output=True, text=True)
    for ln in r.stdout.split("\n"):
        if any(k in ln.lower() for k in ["charge", "power"]):
            print(ln.strip())

def cmd_status():
    d = load()
    pol = decode_policies(d)
    print("== plist 现态 ==")
    print("bootSessionUUID:", d.get("bootSessionUUID", "?"))
    if isinstance(pol, dict) and "$objects" in pol:
        print("policies 归档对象数:", len(pol["$objects"]) - 1)
        for i, o in enumerate(pol["$objects"]):
            print(f"  [{i}]", json.dumps(o, ensure_ascii=False, default=str)[:300])
    else:
        print("policies:", pol)
    print("== 电池实况 ==")
    print(battery_snapshot())

def cmd_capture():
    d = load()
    pol = decode_policies(d)
    if not (isinstance(pol, dict) and "$objects" in pol) or all(
            isinstance(o, dict) and o.get("$classname", "").endswith("Array") for o in pol["$objects"][1:]):
        print("⚠️ policies 为空——策略未注册或已自终止（一次性语义）。请先在系统设置设置充电上限再 capture。")
        sys.exit(1)
    with open(CAPTURE, "w", encoding="utf-8") as f:
        json.dump({"decoded": json.loads(json.dumps(pol, default=str)),
                   "bootSessionUUID": d.get("bootSessionUUID", "")},
                  f, ensure_ascii=False, indent=1, default=str)
    with open(CAPTURE + ".bplist", "wb") as f:
        f.write(d["policies"])  # 原始归档字节（set 复制的保真模板）
    # 找 ChargeCtrlPolicy 实例与类链
    objs = pol["$objects"]
    hits = [(i, o) for i, o in enumerate(objs)
            if isinstance(o, dict) and "soclimit" in o]
    print("== capture ==")
    if not hits:
        print("❌ 归档中未见 soclimit 对象——UI 注册形态与 v1.7 测绘不同，dump 已存", CAPTURE)
        for i, o in enumerate(objs):
            print(f"  [{i}]", json.dumps(o, ensure_ascii=False, default=str)[:300])
        sys.exit(1)
    for i, o in hits:
        print(f"[{i}] soclimit={o.get('soclimit')} reason={o.get('reason')} "
              f"drain={o.get('drain')} isEndOfCharge={o.get('isEndOfCharge')} "
              f"terminated={o.get('terminated')} owner={o.get('owner')}")
        cls = objs[o["$class"].data] if o.get("$class") else None
        print("    class:", cls)
    print("✅ 真实骨架已存", CAPTURE, "——可执行 set N（N=目标百分比）")

def build_policy_archive(soclimit):
    """真实注册态的精确复刻（2026-09-15 status 解码 558 字节实测 8 对象布局）：
    $objects = [$null, 数组实例, NSMutableArray类, ChargeCtrlPolicy实例, "manualChargeLimit",
                NSUUID实例, NSUUID类, ChargeCtrlPolicy类]；顶层 root=UID(1)。"""
    token = uuid.uuid4().bytes  # NSUUID 16 字节
    return {
        "$version": 100000, "$archiver": "NSKeyedArchiver",
        "$top": {"root": plistlib.UID(1)},
        "$objects": [
            "$null",
            {"NS.objects": [plistlib.UID(2)], "$class": plistlib.UID(7)},
            {"reason": plistlib.UID(3), "owner": 659, "soclimit": int(soclimit),
             "$class": plistlib.UID(6), "drain": True, "terminated": False,
             "noChargeToFull": False, "isEndOfCharge": True, "token": plistlib.UID(4)},
            "manualChargeLimit",
            {"NS.uuidbytes": token, "$class": plistlib.UID(5)},
            {"$classname": "NSUUID", "$classes": ["NSUUID", "NSObject"]},
            {"$classname": "ChargeCtrlPolicy", "$classes": ["ChargeCtrlPolicy", "NSObject"]},
            {"$classname": "NSMutableArray", "$classes": ["NSMutableArray", "NSArray", "NSObject"]},
        ],
    }

def cmd_set(n):
    # v2：不再依赖 capture 模板——直接按真实注册态布局构建（布局已从 558 字节
    # 实测解码钉死）。策略为一次性语义（到位后自终止），观察窗口要抓紧。
    d = build_policy_archive(n)
    d["bootSessionUUID"] = load().get("bootSessionUUID", "")
    save(d)
    print(f"== 已写入 soclimit={n}（一次性语义——到位后可能自终止，daemon 需周期重注册维持）==")
    print("观察项：①充电是否立即停止（当前电量高于 %s%% 时）" % n)
    print("        ②系统设置 → 电池 → 充电上限 显示值（75 被接受？钳到 80？）")
    print("        ③电量降到 %s%% 后：停住维持？还是恢复充回 100（一次性终止）？" % n)
    print("        ④若完全无反应：sudo killall -HUP powerd 后再观察一次")
    print("恢复：sudo python3 %s clear" % sys.argv[0])
    print("观察项：①充电是否在 %s%% 停止（当前电量若已高于该值应立即停）" % n)
    print("        ②系统设置 → 电池 → 充电上限 显示是否变为 %s%%" % n)
    print("        ③若无任何变化 → 尝试触发面：sudo killall -HUP powerd 后再观察")
    print("恢复：sudo python3 %s clear" % sys.argv[0])

def cmd_clear():
    d = {"$version": 100000, "$archiver": "NSKeyedArchiver",
         "$top": {"root": plistlib.UID(1)},
         "$objects": ["$null",
                      {"NS.objects": [], "$class": plistlib.UID(2)},
                      {"$classname": "NSMutableArray",
                       "$classes": ["NSMutableArray", "NSArray", "NSObject"]}]}
    save(d)
    print("== 已恢复空策略（升级前原态）==")

if __name__ == "__main__":
    if getuid := os.getuid() != 0:
        print("❌ 请用 sudo 运行（plist 为 root 所有）")
        sys.exit(1)
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "capture": cmd_capture()
    elif cmd == "set": cmd_set(sys.argv[2] if len(sys.argv) > 2 else "80")
    elif cmd == "clear": cmd_clear()
    elif cmd == "probe": cmd_probe()
    else: cmd_status()
