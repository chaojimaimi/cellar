#!/bin/bash
# Cellar macOS 27 GA topoffprotection 直写 spike（S2）— 方案 docs/plans/phase5-0.20-macos27-ga-spike.md §4 v3 定稿
# 子命令风格参照 Tools/spike-macos27-powerd.py（capture/set/clear/status/probe 形态 → e0/e1/e2/e3/e4/restore/concl）。
# 机制（§4）：写 /var/root/Library/Preferences/com.apple.smartcharging.topoffprotection 域的 MCLFeatureState / mclLimitValue，
#   通知名 com.apple.smartcharging.defaultschanged；观察 pmset -g battlimit 读数臂 + 行为臂（回落/驻留双臂显式布尔）。
# 红线内建：R1（下界 40 硬终止；上界=目标+2 动态；E2 前置电量>77）、R2（daemon 卸载检查，S2 允许关编排开关备选需 ack）、
#   R3（原值 defaults read-type + read 落状态文件，先于首写）、R7（E4 c = UI 兜底）、R8（与 S1/S3 不同日——人工纪律）。
# 用法：
#   sudo Tools/spike-ga-topoff.sh e0            # 基线：域读取+battlimit 存在性+电量快照（battlimit_present 输出供判读臂选择）
#   sudo Tools/spike-ga-topoff.sh e1            # MCLFeatureState=1 + mclLimitValue=85 + 通知 → 5 分钟 battlimit 采样
#   sudo Tools/spike-ga-topoff.sh e2 [30|40|75]    # 前置电量>77 → mclLimitValue=75 → 观察窗（每 5 分钟采样；75=§11.5 决策点 B 纠正窗）
#   sudo Tools/spike-ga-topoff.sh e3 [check]    # pmset sleepnow → 唤醒后 10 分钟压住检查（check=仅检查，会话中断恢复用）
#   sudo Tools/spike-ga-topoff.sh e4            # 注销三梯 a/b/c（各 5 分钟观察，记录哪步真正撤销执法）
#   sudo Tools/spike-ga-topoff.sh restore       # 按状态文件还原 + 验证
#   sudo Tools/spike-ga-topoff.sh concl         # §4 判据①–⑤ 双臂布尔输出 + GO/NO-GO

set -u

DOMAIN="/var/root/Library/Preferences/com.apple.smartcharging.topoffprotection"
NOTIFY="com.apple.smartcharging.defaultschanged"
STATE="/tmp/spike-ga-state-topoff.json"
RESULTS="/tmp/spike-ga-results-topoff.txt"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="/tmp/spike-ga-topoff-${TS}.log"
TARGET_E1=85
TARGET_E2=75
E2_CEILING=77          # R1 动态上界 = 目标+2（回落臂驻留判读线）
E2_PRECHECK=77         # E2 前置：电量须已高于 77（§4 E2）
LOWER_HARD=40          # R1 下界硬终止
LOWER_WARN=45          # 红线：跌至 45 手动干预提示

log() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "${1}" | tee -a "${LOG}"
}
concl() {
    log "concl.topoff.${1}=${2}"
}
rec() {  # 记录结果 kv（跨子命令汇总用）
    printf '%s=%s\n' "${1}" "${2}" >>"${RESULTS}"
}
kv_get() {  # 从结果文件取 kv
    [ -f "${RESULTS}" ] || { printf ''; return; }
    sed -n "s/^${1}=//p" "${RESULTS}" | tail -1
}
state_get() {  # 从状态 JSON 取扁平键（值一律带引号）
    [ -f "${STATE}" ] || { printf ''; return; }
    sed -n 's/.*"'"${1}"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${STATE}" | tail -1
}
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log "❌ 请用 sudo 运行（写 /var/root 偏好域 + notifyutil 需 root）"
        exit 2
    fi
}
batt_percent() {
    ioreg -rc AppleSmartBattery 2>/dev/null | sed -n 's/.*"CurrentCapacity" = \([0-9]*\).*/\1/p' | head -1
}
batt_charging() {
    ioreg -rc AppleSmartBattery 2>/dev/null | sed -n 's/.*"IsCharging" = \([A-Za-z]*\).*/\1/p' | head -1
}
not_charging_reason() {
    ioreg -rc AppleSmartBattery 2>/dev/null | sed -n 's/.*"NotChargingReason" = \([0-9]*\).*/\1/p' | head -1
}
reason_power_hint() {  # 2^24=原生持有 / 2^59=CHTE 抑制（SMC-NOTES §5 执法签名）
    local v="${1}" l
    [ -n "${v}" ] || { printf 'none'; return; }
    l="$(awk -v v="${v}" 'BEGIN{l=log(v)/log(2); if (l==int(l) && l>0) printf "2^%d", l; else print "non-pow2"}')"
    case "${l}" in
        2^24) printf '%s(原生持有签名)' "${l}" ;;
        2^59) printf '%s(CHTE 抑制签名)' "${l}" ;;
        *) printf '%s' "${l}" ;;
    esac
}
battlimit_read() {  # 输出：数字或空（不存在/不支持）
    local out rc
    out="$(pmset -g battlimit 2>&1)"; rc=$?
    if [ "${rc}" -ne 0 ]; then printf ''; return; fi
    case "${out}" in
        *[Uu]sage*|*[Uu]nknown*|*option*) printf ''; return ;;
    esac
    printf '%s\n' "${out}" | sed -n 's/[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -1
}
notify_changed() {
    notifyutil -p "${NOTIFY}" >/dev/null 2>&1
    log "通知已发：notifyutil -p ${NOTIFY}"
}
observe_minutes() {  # observe_minutes <总分钟> <间隔秒> <标签>——采样电量/充电/NotChargingReason/battlimit
    local total_min="${1}" step_s="${2}" tag="${3}"
    local n=$(( total_min * 60 / step_s )) i p c r bl
    for i in $(seq 1 "${n}"); do
        [ "${i}" -gt 1 ] && sleep "${step_s}"
        p="$(batt_percent)"; c="$(batt_charging)"; r="$(not_charging_reason)"; bl="$(battlimit_read)"
        log "[${tag}] #${i}/${n} percent=${p}% isCharging=${c:-?} NotChargingReason=${r:-none}($(reason_power_hint "${r}")) battlimit=${bl:-无读数}"
        rec "${tag}.sample.${i}" "percent=${p} charging=${c:-?} reason=${r:-none} battlimit=${bl:-none}"
    done
}
daemon_gate() {  # R2：S2 允许「关编排开关」备选，但需 ack 显式确认
    local loaded=0 ack="${1:-}"
    pgrep -x com.cellar.daemon >/dev/null 2>&1 && loaded=1
    pgrep -x cellar-daemon >/dev/null 2>&1 && loaded=1
    launchctl print system/com.cellar.daemon >/dev/null 2>&1 && loaded=1
    [ "${loaded}" -eq 1 ] || { log "[R2] daemon 卸载=通过（pgrep 双名 + launchctl）"; return 0; }
    log "[R2] daemon 仍在（pgrep/launchctl 命中）——S2 备选=系统设置→通用→Cellar 编排开关关闭（只断编排域；风扇执法域仍在，本 spike 不涉及风扇）。确认已关闭请追加参数 ack 重跑；否则先 sudo launchctl bootout system/com.cellar.daemon"
    if [ "${ack}" != "ack" ]; then
        log "[R2] 未给 ack——拒绝进入实验"
        exit 3
    fi
    log "[R2] ack 已给——编排开关备选确认，继续"
}

cmd="${1:-help}"
case "${cmd}" in
    help|--help|-h)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac
require_root
log "=== GA topoffprotection spike（S2）uid=$(id -u) macOS=$(sw_vers -productVersion) 日志=${LOG} ==="

case "${cmd}" in
    # ── E0 基线（§4 E0）───────────────────────────────────────────────
    e0)
        daemon_gate "${2:-}"
        log "=== E0：基线（域读取 + battlimit 存在性 + 电量/NotChargingReason 快照）==="
        rm -f "${RESULTS}"
        if defaults read "${DOMAIN}" >/tmp/spike-ga-topoff-domain-dump.txt 2>&1; then
            log "域存在，内容头部："
            head -20 /tmp/spike-ga-topoff-domain-dump.txt | tee -a "${LOG}"
            rec "e0.domain_present" "yes"
        else
            log "域不存在（defaults read 失败——如实记录，不粉饰）"
            rec "e0.domain_present" "no"
        fi
        bl="$(battlimit_read)"
        if [ -n "${bl}" ]; then
            log "battlimit 读数=${bl} → battlimit_present=yes（读数臂可用）"
            rec "e0.battlimit_present" "yes"
            rec "e0.battlimit" "${bl}"
        else
            log "battlimit 无读数/不支持 → battlimit_present=no（预注册走行为判读臂，§4 判据②）"
            rec "e0.battlimit_present" "no"
        fi
        p="$(batt_percent)"; c="$(batt_charging)"; r="$(not_charging_reason)"
        log "电量=${p}% isCharging=${c:-?} NotChargingReason=${r:-none}($(reason_power_hint "${r}"))"
        rec "e0.percent" "${p:-unknown}"
        rec "e0.isCharging" "${c:-unknown}"
        rec "e0.reason" "${r:-none}"
        if [ -n "${p}" ] && [ "${p}" -lt "${LOWER_HARD}" ]; then
            log "[R1] 电量 ${p}% 低于硬下界 ${LOWER_HARD}%——拒绝进入实验"
            exit 3
        fi
        log "[R1] 电量下界检查=通过（${p:-?}% ≥ 硬下界 ${LOWER_HARD}%；E2 前置：需 >${E2_PRECHECK}%，不满足先充到位——上界=${E2_CEILING}%=目标+2）"
        rec "e0.done" "true"
        concl "e0" "done domain=$(kv_get e0.domain_present) battlimit_present=$(kv_get e0.battlimit_present)"
        ;;
    # ── E1 写通路（§4 E1：85 隔离变量 + 5 分钟 battlimit 读数臂）──────
    e1)
        [ "$(kv_get e0.done)" = "true" ] || { log "请先执行 e0"; exit 3; }
        if [ -f "${STATE}" ]; then log "残留状态文件存在——请先 restore（R3）"; exit 3; fi
        log "=== E1：MCLFeatureState=1 + mclLimitValue=85 + 通知 → 5 分钟 battlimit 采样 ==="
        # R3/P0-1：原值先落状态文件（键存在性 + read-type 精确类型）
        s_existed=no; s_type=""; s_val=""
        if defaults read "${DOMAIN}" MCLFeatureState >/dev/null 2>&1; then
            s_existed=yes; s_type="$(defaults read-type "${DOMAIN}" MCLFeatureState 2>/dev/null)"; s_val="$(defaults read "${DOMAIN}" MCLFeatureState 2>/dev/null | tr -d '[:space:]')"
        fi
        l_existed=no; l_type=""; l_val=""
        if defaults read "${DOMAIN}" mclLimitValue >/dev/null 2>&1; then
            l_existed=yes; l_type="$(defaults read-type "${DOMAIN}" mclLimitValue 2>/dev/null)"; l_val="$(defaults read "${DOMAIN}" mclLimitValue 2>/dev/null | tr -d '[:space:]')"
        fi
        cat >"${STATE}" <<EOF
{
  "created": "${TS}",
  "mcl_state_existed": "${s_existed}",
  "mcl_state_type": "${s_type}",
  "mcl_state_original": "${s_val}",
  "mcl_limit_existed": "${l_existed}",
  "mcl_limit_type": "${l_type}",
  "mcl_limit_original": "${l_val}",
  "battlimit_original": "$(battlimit_read)"
}
EOF
        chmod 600 "${STATE}"
        log "[R3] 状态文件已写入 ${STATE}（state_existed=${s_existed}${s_type:+/${s_type}} limit_existed=${l_existed}${l_type:+/${l_type}}）"
        # 键名/类型以 e0 实读为准；域无实读时按 Ampere 文档键名首写，失败进类型变体（最多二轮）
        defaults write "${DOMAIN}" MCLFeatureState -bool true 2>&1 | tee -a "${LOG}"
        defaults write "${DOMAIN}" mclLimitValue -int "${TARGET_E1}" 2>&1 | tee -a "${LOG}"
        notify_changed
        ok_state="$(defaults read "${DOMAIN}" MCLFeatureState 2>/dev/null | tr -d '[:space:]')"
        ok_limit="$(defaults read "${DOMAIN}" mclLimitValue 2>/dev/null | tr -d '[:space:]')"
        if [ "${ok_state}" != "1" ] || [ "${ok_limit}" != "${TARGET_E1}" ]; then
            log "E1 首写回读不符（state=${ok_state:-无} limit=${ok_limit:-无}）——进第二轮类型变体（MCLFeatureState -int 1；最多二轮，人工确认）"
            printf '二轮变体将写 MCLFeatureState -int 1 + mclLimitValue -int %s，继续？(y/N) ' "${TARGET_E1}"
            read -r ans
            case "${ans}" in
                y|Y)
                    defaults write "${DOMAIN}" MCLFeatureState -int 1 2>&1 | tee -a "${LOG}"
                    defaults write "${DOMAIN}" mclLimitValue -int "${TARGET_E1}" 2>&1 | tee -a "${LOG}"
                    notify_changed
                    ok_state="$(defaults read "${DOMAIN}" MCLFeatureState 2>/dev/null | tr -d '[:space:]')"
                    ok_limit="$(defaults read "${DOMAIN}" mclLimitValue 2>/dev/null | tr -d '[:space:]')"
                    ;;
                *) log "人工未确认——E1 中止（还原状态文件已录原值后可 restore）"; exit 3 ;;
            esac
        fi
        if [ "${ok_state}" != "1" ] || [ "${ok_limit}" != "${TARGET_E1}" ]; then
            log "二轮仍失败——键名/类型变体候选项（供下一轮实验人工考证）：MCLFeatureState/MCLFeatureEnabled/MCLLimitEnabled × mclLimitValue/MCLLimitValue/MCLChargeLimit；E1 如实判 fail"
            rec "e1.pass" "false"
            concl "e1" "fail(write-readback)"
            exit 1
        fi
        log "E1 写入回读一致（state=1 limit=${TARGET_E1}）——5 分钟 battlimit 读数臂采样"
        n85=0
        for i in 1 2 3 4 5 6 7 8 9 10; do
            [ "${i}" -gt 1 ] && sleep 30
            bl="$(battlimit_read)"
            log "[E1采样] #${i}/10 battlimit=${bl:-无读数}"
            rec "e1.sample.${i}" "${bl:-none}"
            [ "${bl}" = "${TARGET_E1}" ] && n85=$(( n85 + 1 ))
        done
        if [ "${n85}" -gt 0 ]; then
            rec "e1.pass" "true"
            rec "e1.readings85" "${n85}/10"
            concl "e1" "pass(battlimit 读出 ${TARGET_E1} ${n85}/10——判据①读数臂)"
        else
            rec "e1.pass" "false"
            concl "e1" "fail(battlimit 无 ${TARGET_E1} 读数——读数臂不通；行为臂在 e2 顺延判读)"
        fi
        ;;
    # ── E2 <80 表达力（§4 E2：前置电量>77 → 75 → 30–40 分钟窗）────────
    e2)
        [ "$(kv_get e0.done)" = "true" ] || { log "请先执行 e0"; exit 3; }
        # P1-3（R3）：STATE 守卫——无原值备份时 75 写入即 restore 盲区，拒绝进入
        if [ ! -f "${STATE}" ]; then
            log "[R3] 状态文件不存在（${STATE}）——mclLimitValue=75 写入将无原值备份（restore 盲区）。请先执行 e1（含原值备份）再跑 e2"
            exit 3
        fi
        dur="${2:-30}"
        case "${dur}" in 30|40|75) ;; *) log "窗长仅支持 30、40 或 75 分钟（§4 E2：30–40；75=SMC-NOTES §11.5 决策点 B 纠正窗——仅延长测量窗，判据一字不动）"; exit 2 ;; esac
        log "=== E2：mclLimitValue=75 + 通知 → ${dur} 分钟窗（每 5 分钟采样；执法签名 NotChargingReason 2^24/2^59）==="
        p="$(batt_percent)"
        [ -n "${p}" ] || { log "电量读取失败——中止"; exit 3; }
        if [ "${p}" -le "${E2_PRECHECK}" ]; then
            log "[前置] 电量 ${p}% 未高于 ${E2_PRECHECK}%——请先充到位（§4 E2 前置；R1 上界动态=${E2_CEILING}%）；充到位后重跑 e2"
            exit 3
        fi
        log "[前置] 电量 ${p}% > ${E2_PRECHECK}%——满足回落观察条件"
        defaults write "${DOMAIN}" mclLimitValue -int "${TARGET_E2}" 2>&1 | tee -a "${LOG}"
        notify_changed
        ok_limit="$(defaults read "${DOMAIN}" mclLimitValue 2>/dev/null | tr -d '[:space:]')"
        log "mclLimitValue 回读=${ok_limit:-无}（期望 ${TARGET_E2}）"
        rec "e2.writeback" "75→${ok_limit:-none}"
        rec "e2.startPercent" "${p}"
        [ "${ok_limit}" = "${TARGET_E2}" ] || log "[警示] 回读≠75——按实况继续观察（如实记录）"
        log "[红线] E2 期间用户须在场；电量跌至 ${LOWER_WARN}% 手动干预（中止还原走 e4 c）；${LOWER_HARD}% 硬终止"
        end_p="${p}"; min_p="${p}"; false_n=0; total=0; anomaly=no; reasons=""
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
            [ "${i}" -gt 1 ] && sleep 300
            [ $(( (i - 1) * 5 )) -gt "${dur}" ] && break
            cp_="$(batt_percent)"; c="$(batt_charging)"; r="$(not_charging_reason)"; bl="$(battlimit_read)"
            total=$(( total + 1 )); end_p="${cp_:-${end_p}}"
            [ -n "${cp_}" ] && [ "${cp_}" -lt "${min_p}" ] && min_p="${cp_}"
            [ "${c}" = "No" ] && false_n=$(( false_n + 1 ))
            case ":${reasons}:" in *":${r}:"*) ;; *) reasons="${reasons} ${r}" ;; esac
            # 校准强制 100 被动登记（信息项）：充电中且电量异常上行越起点+3
            if [ "${c}" = "Yes" ] && [ -n "${cp_}" ] && [ -n "${p}" ] && [ "${cp_}" -ge $(( p + 3 )) ]; then
                anomaly=yes
                log "[登记] 疑似 Apple 校准强制充电（isCharging=Yes 且电量 ${cp_}% ≥ 起点+3）——信息项"
            fi
            log "[E2] #${i} percent=${cp_}% isCharging=${c:-?} NotChargingReason=${r:-none}($(reason_power_hint "${r}")) battlimit=${bl:-无读数}"
            rec "e2.sample.${i}" "percent=${cp_} charging=${c:-?} reason=${r:-none} battlimit=${bl:-none}"
            if [ -n "${cp_}" ] && [ "${cp_}" -lt "${LOWER_WARN}" ] && [ "${cp_}" -ge "${LOWER_HARD}" ]; then
                log "[红线] 电量 ${cp_}% ≤ ${LOWER_WARN}%——请手动干预（中止还原走 e4 c）；观察暂停等待回车"
                read -r _
            fi
            if [ -n "${cp_}" ] && [ "${cp_}" -lt "${LOWER_HARD}" ]; then
                # P1-3（R1「终止并还原」）：退场前自动执行梯 a de-enforce（MCLFeatureState=0 + 通知，方向恒安全）
                log "[R1] 电量 ${cp_}% 低于硬下界 ${LOWER_HARD}%——自动 de-enforce（MCLFeatureState=0 + 通知，方向恒安全）后退场；随后请走 e4 c（UI 兜底）+ restore"
                defaults write "${DOMAIN}" MCLFeatureState -bool false 2>&1 | tee -a "${LOG}"
                notify_changed
                rec "e2.aborted" "below-${LOWER_HARD}(de-enforced)"
                exit 2
            fi
        done
        drop=$(( p - end_p ))
        rec "e2.endPercent" "${end_p}"
        rec "e2.minPercent" "${min_p}"
        rec "e2.drop" "${drop}"
        rec "e2.samples" "${total}"
        rec "e2.chargingFalseCount" "${false_n}"
        rec "e2.reasonsSeen" "${reasons}"
        rec "e2.calibrationAnomaly" "${anomaly}"
        # 双臂判读（显式布尔，结论细化在 concl）
        if [ "${p}" -gt "${E2_PRECHECK}" ]; then
            arm=fall; arm_result=no
            [ "${drop}" -ge 3 ] && [ "${end_p}" -le "${E2_CEILING}" ] && arm_result=yes
        else
            arm=dwell; arm_result=no
            [ "${total}" -ge 7 ] && [ "${false_n}" -eq "${total}" ] && arm_result=yes
        fi
        rec "e2.arm" "${arm}"
        rec "e2.armResult" "${arm_result}"
        concl "e2" "arm=${arm} result=${arm_result}（${p}%→${end_p}%，drop=${drop}，isCharging=false ${false_n}/${total}）"
        ;;
    # ── E3 睡眠存活（§4 E3：sleepnow → 唤醒后 10 分钟压住检查）─────────
    e3)
        if [ "${2:-}" != "check" ]; then
            [ "$(kv_get e2.startPercent)" != "" ] || { log "请先执行 e2"; exit 3; }
            log "=== E3：pmset sleepnow → 系统睡眠 → 唤醒后自动进入 10 分钟压住检查 ==="
            log "即将在 10s 后执行 pmset sleepnow（本进程随系统挂起，唤醒后自动续跑）。终端请保持前台。"
            for i in 10 9 8 7 6 5 4 3 2 1; do log "  ${i}s…" ; sleep 1; done
            rec "e3.sleepPercent" "$(batt_percent)"
            rec "e3.preClock" "$(date +%s)"
            if ! pmset sleepnow; then
                log "pmset sleepnow 失败——E3 如实判 fail"
                rec "e3.pass" "false"
                exit 1
            fi
        fi
        log "=== E3 检查：唤醒后 10 分钟压住（每 2 分钟 ×5：电量 ≤${E2_CEILING}% 且无充电）==="
        pass=yes; i=0
        while [ "${i}" -lt 5 ]; do
            [ "${i}" -gt 0 ] && sleep 120
            i=$(( i + 1 ))
            p="$(batt_percent)"; c="$(batt_charging)"
            log "[E3] #${i}/5 percent=${p}% isCharging=${c:-?}"
            rec "e3.check.${i}" "percent=${p} charging=${c:-?}"
            if [ -z "${p}" ] || [ "${p}" -gt "${E2_CEILING}" ] || [ "${c}" = "Yes" ]; then pass=no; fi
        done
        pre="$(kv_get e3.preClock)"; now="$(date +%s)"
        if [ -n "${pre}" ]; then
            log "[E3] 睡眠跨度=$(( (now - pre) / 60 )) 分钟（含唤醒；如实记录）"
        fi
        rec "e3.pass" "${pass}"
        concl "e3" "${pass}(唤醒后 10 分钟电量压住)"
        ;;
    # ── E4 注销路径（§4 E4：三梯，各 5 分钟，记录哪步真正撤销执法）────
    e4)
        log "=== E4：注销三梯 a) MCLFeatureState=0 b) defaults delete c) 系统 UI ==="
        log "[提示] 每梯观察 5 分钟后人工判读（充电恢复=执法撤销证据）；任一梯生效可停止后续。E4 c 亦是全程万能兜底。"
        found=none
        # 梯 a
        defaults write "${DOMAIN}" MCLFeatureState -bool false 2>&1 | tee -a "${LOG}"
        notify_changed
        observe_minutes 5 60 "E4a"
        printf '梯 a 后充电行为是否已恢复（执法撤销）？(y/N) '
        read -r ans
        case "${ans}" in y|Y) found=a ;; esac
        # 梯 b
        if [ "${found}" = "none" ]; then
            printf '继续梯 b（defaults delete 两键）？(Y/n) '
            read -r ans
            case "${ans}" in n|N) ;; *)
                defaults delete "${DOMAIN}" MCLFeatureState 2>&1 | tee -a "${LOG}"
                defaults delete "${DOMAIN}" mclLimitValue 2>&1 | tee -a "${LOG}"
                notify_changed
                observe_minutes 5 60 "E4b"
                printf '梯 b 后充电行为是否已恢复（执法撤销）？(y/N) '
                read -r ans
                case "${ans}" in y|Y) found=b ;; esac
            ;; esac
        fi
        # 梯 c（UI——永远可用，PowerUIAgent 正门）
        if [ "${found}" = "none" ]; then
            bl_before="$(battlimit_read)"
            log "梯 c：请在 系统设置 → 电池 → 充电上限 走 UI 操作（关闭/调整原生限充）。当前 battlimit=${bl_before:-无读数}。完成后回车。"
            read -r _
            observe_minutes 5 60 "E4c"
            bl_after="$(battlimit_read)"
            log "梯 c：UI 前 battlimit=${bl_before:-无读数} → UI 后=${bl_after:-无读数}"
            rec "e4c.battlimit.before" "${bl_before:-none}"
            rec "e4c.battlimit.after" "${bl_after:-none}"
            found=c
        fi
        rec "e4.pathfound" "${found}"
        concl "e4" "pathfound=${found}（可复现注销路径成档；仅 c 可用=产品化「关闭时弹指引」）"
        ;;
    # ── restore（E5：按状态文件还原 + 验证）───────────────────────────
    restore)
        log "=== restore：按状态文件还原（回到 E0 行为，无残留策略）==="
        if [ ! -f "${STATE}" ]; then
            log "无状态文件（${STATE}）——无需还原（如实记录）"
            concl "restore.last" "nothing-to-restore"
            exit 0
        fi
        s_existed="$(state_get mcl_state_existed)"; s_type="$(state_get mcl_state_type)"; s_val="$(state_get mcl_state_original)"
        l_existed="$(state_get mcl_limit_existed)"; l_type="$(state_get mcl_limit_type)"; l_val="$(state_get mcl_limit_original)"
        if [ "${s_existed}" = "yes" ]; then
            t="${s_type:-bool}"; case "${t}" in *"integer"*) w="-int" ;; *"boolean"*|"") w="-bool" ;; *"string"*) w="-string" ;; *) w="-bool" ;; esac
            defaults write "${DOMAIN}" MCLFeatureState ${w} "${s_val:-0}" 2>&1 | tee -a "${LOG}"
            log "已还原 MCLFeatureState=${s_val}（原类型 ${s_type:-bool}）"
        else
            defaults delete "${DOMAIN}" MCLFeatureState 2>/dev/null
            log "MCLFeatureState 原不存在——已 delete（回到 E0 无键态）"
        fi
        if [ "${l_existed}" = "yes" ]; then
            t="${l_type:-integer}"; case "${t}" in *"integer"*|"") w="-int" ;; *"boolean"*) w="-bool" ;; *"string"*) w="-string" ;; *) w="-int" ;; esac
            defaults write "${DOMAIN}" mclLimitValue ${w} "${l_val}" 2>&1 | tee -a "${LOG}"
            log "已还原 mclLimitValue=${l_val}（原类型 ${l_type:-integer}）"
        else
            defaults delete "${DOMAIN}" mclLimitValue 2>/dev/null
            log "mclLimitValue 原不存在——已 delete"
        fi
        notify_changed
        sleep 5
        ok=yes
        now_s="$(defaults read "${DOMAIN}" MCLFeatureState 2>/dev/null | tr -d '[:space:]')"
        now_l="$(defaults read "${DOMAIN}" mclLimitValue 2>/dev/null | tr -d '[:space:]')"
        if [ "${s_existed}" = "yes" ] && [ "${now_s}" != "${s_val}" ]; then ok=no; fi
        if [ "${s_existed}" = "no" ] && [ -n "${now_s}" ]; then ok=no; fi
        if [ "${l_existed}" = "yes" ] && [ "${now_l}" != "${l_val}" ]; then ok=no; fi
        if [ "${l_existed}" = "no" ] && [ -n "${now_l}" ]; then ok=no; fi
        c="$(batt_charging)"; p="$(batt_percent)"
        log "还原验证：MCLFeatureState=${now_s:-无} mclLimitValue=${now_l:-无} isCharging=${c:-?} percent=${p}%"
        if [ "${ok}" = "yes" ]; then
            rm -f "${STATE}"
            rec "restore.last" "verified"
            concl "restore.last" "verified"
            log "[检查单] 还原验证通过——请 bootstrap 恢复 daemon 并以 cellar doctor 三方 PASS 收尾（R2；S2 走编排开关备选的重新打开开关）"
        else
            rec "restore.last" "failed"
            concl "restore.last" "failed"
            log "还原验证失败——如实记录（保留状态文件与日志；可重跑 restore）"
            exit 1
        fi
        ;;
    # ── concl（§4 判据①–⑤ 双臂布尔 + GO/NO-GO）──────────────────────
    concl)
        log "=== concl：§4 判据①–⑤（结果文件 ${RESULTS}）==="
        [ -f "${RESULTS}" ] || { log "无结果文件——实验未执行"; exit 1; }
        e1="$(kv_get e1.pass)"
        arm="$(kv_get e2.arm)"; arm_result="$(kv_get e2.armResult)"
        start_p="$(kv_get e2.startPercent)"; end_p="$(kv_get e2.endPercent)"
        drop="$(kv_get e2.drop)"; false_n="$(kv_get e2.chargingFalseCount)"; total="$(kv_get e2.samples)"
        # ① E1 写通路：battlimit 读出 85（读数臂）或 E2 行为臂证据（双臂显式布尔）
        fall_arm=no; dwell_arm=no
        [ -n "${start_p}" ] && [ -n "${end_p}" ] && [ -n "${drop}" ] \
            && [ "${start_p}" -gt "${E2_PRECHECK}" ] && [ "${drop}" -ge 3 ] && [ "${end_p}" -le "${E2_CEILING}" ] && fall_arm=yes
        [ -n "${start_p}" ] && [ "${start_p}" -le "${E2_PRECHECK}" ] && [ -n "${total}" ] && [ "${total}" -ge 7 ] \
            && [ -n "${false_n}" ] && [ "${false_n}" -eq "${total}" ] && dwell_arm=yes
        c1=no
        { [ "${e1}" = "true" ] || [ "${fall_arm}" = "yes" ] || [ "${dwell_arm}" = "yes" ]; } && c1=yes
        concl "criterion.1" "${c1}(读数臂=e1(${e1:-未执行})；行为臂证据=回落臂(${fall_arm})/驻留臂(${dwell_arm}))"
        # ② E2 <80 生效（显式布尔，二选一臂）
        if [ "${arm}" = "fall" ]; then c2="${fall_arm}"; else c2="${dwell_arm}"; fi
        concl "criterion.2" "${c2}(回落臂=${fall_arm}：起点>${E2_PRECHECK}∧drop≥3∧终点≤${E2_CEILING}；驻留臂=${dwell_arm}：起点≤${E2_PRECHECK}∧30 分钟 isCharging=false ${false_n:-?}/${total:-?})"
        concl "criterion.2.detail" "${start_p:-?}%→${end_p:-?}% drop=${drop:-?} 校准强制登记=$(kv_get e2.calibrationAnomaly) 执法签名=$(kv_get e2.reasonsSeen)"
        # ③ E3 睡眠存活
        e3p="$(kv_get e3.pass)"
        concl "criterion.3" "${e3p:-未执行}(唤醒后 10 分钟 ≤${E2_CEILING}% 且无充电)"
        # ④ E4 ≥1 条可复现注销路径
        e4p="$(kv_get e4.pathfound)"
        concl "criterion.4" "$( [ "${e4p}" != "" ] && [ "${e4p}" != "none" ] && echo yes || echo no )(pathfound=${e4p:-未执行}；仅 c 可用=注销必须走 UI 引导)"
        # ⑤ E5 无残留
        rl="$(kv_get restore.last)"
        concl "criterion.5" "$( [ "${rl}" = "verified" ] && echo yes || echo no )(restore.last=${rl:-未执行})"
        # §4 判定：①② pass=<80 后端候选 GO；② fail 但 ① pass=通道仅等效 ≥80；① fail=通道死
        if [ "${c1}" = "yes" ] && [ "${c2}" = "yes" ]; then
            concl "go" "GO(<80 后端候选——topoffprotection 主路线成立；注销设计看判据④)"
        elif [ "${c1}" = "yes" ]; then
            concl "go" "NO-GO-for-lt80(① pass ② fail——通道仅等效 ≥80，与编排重复)"
        else
            concl "go" "NO-GO-channel-dead(① fail——topoffprotection 通道不可用)"
        fi
        log "=== 判定汇总见上方 concl.topoff.* ==="
        ;;
    *)
        log "未知子命令：${cmd}（可用：e0 e1 e2 e3 e4 restore concl help）"
        exit 2
        ;;
esac
