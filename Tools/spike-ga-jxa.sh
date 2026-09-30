#!/bin/bash
# Cellar macOS 27 GA JXA spike 包装（S3）— 方案 docs/plans/phase5-0.20-macos27-ga-spike.md §5 v3 定稿
# 职责：probe/set/restore/concl 子命令；set 一律在独立子进程跑（osascript 崩溃不波及包装器），
#   捕获退出码/信号形态（segfault 判别：退出码 139 或 128+SIGSEGV）；按 §5 判据①–④ 输出 concl.jxa.*。
# 用法：
#   Tools/spike-ga-jxa.sh probe               # E0 发现（只读；js 侧框架加载若 segfault 自动定位元凶并 --skip 续跑）
#   sudo Tools/spike-ga-jxa.sh set 85 [ack]   # E1 ≥80 设值（独立子进程 + 5 分钟 battlimit 读数臂采样 + 行为判读）
#   sudo Tools/spike-ga-jxa.sh set 75 [ack]   # E2 <80 拒绝形态定谳（预期 segfault（PR #480）或错误域）
#   sudo Tools/spike-ga-jxa.sh restore [ack]  # E4 还原（设回 100 / UI 兜底指引）
#   sudo Tools/spike-ga-jxa.sh concl          # §5 判据①–④ + GO/NO-GO
# 门禁（P1-4）：set/restore 入口带 R2 daemon 门禁（pgrep 双名 + launchctl 腿；S3 备选=关编排开关需 ack）
#   与 R1 电量下界 40% 硬拦截。
# 载体（2026-09-30）：CARRIER=swift|jxa（默认 jxa=PR #480 同款 osascript）。swift=spike-ga-jxa-set.swift
#   （ad-hoc 用户态进程直调——产品代表性载体；JXA 桥对无 bridgesupport 私有框架无方法回退，set 实锤失败后增补）。
#   swift 载体专属：R3 真还原锚（set 前经 getMCLLimitWithError 读回 mclLimit 原值入档）+ restore 按原值精确还原；
#   RESTORE_TARGET 环境变量 = swift 载体无原值锚时的还原目标（默认 100）。

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
JS="${DIR}/spike-ga-jxa.js"
SET_SWIFT="${DIR}/spike-ga-jxa-set.swift"
CARRIER="${CARRIER:-jxa}"
RESTORE_TARGET="${RESTORE_TARGET:-100}"
STATE="/tmp/spike-ga-state-jxa.json"
RESULTS="/tmp/spike-ga-results-jxa.txt"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="/tmp/spike-ga-jxa-${TS}.log"

log() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "${1}" | tee -a "${LOG}"
}
concl() {
    log "concl.jxa.${1}=${2}"
}
rec() {
    printf '%s=%s\n' "${1}" "${2}" >>"${RESULTS}"
}
kv_get() {
    [ -f "${RESULTS}" ] || { printf ''; return; }
    sed -n "s/^${1}=//p" "${RESULTS}" | tail -1
}
state_get() {
    [ -f "${STATE}" ] || { printf ''; return; }
    sed -n 's/.*"'"${1}"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${STATE}" | tail -1
}
batt_percent() {
    ioreg -rc AppleSmartBattery 2>/dev/null | sed -n 's/.*"CurrentCapacity" = \([0-9]*\).*/\1/p' | head -1
}
batt_charging() {
    ioreg -rc AppleSmartBattery 2>/dev/null | sed -n 's/.*"IsCharging" = \([A-Za-z]*\).*/\1/p' | head -1
}
battlimit_read() {
    local out rc
    out="$(pmset -g battlimit 2>&1)"; rc=$?
    [ "${rc}" -ne 0 ] && { printf ''; return; }
    case "${out}" in *[Uu]sage*|*[Uu]nknown*|*option*) printf ''; return ;; esac
    printf '%s\n' "${out}" | sed -n 's/[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -1
}
classify_exit() {  # $1=osascript 退出码 → 形态判语
    local rc="${1}"
    case "${rc}" in
        0) printf 'clean-exit' ;;
        139) printf 'SIGSEGV(139)——segfault 实锤（PR #480 形态）' ;;
        134) printf 'SIGABRT(134)——NSException/abort' ;;
        136) printf 'SIGFPE(136)' ;;
        1) printf 'script-error(rc=1，错误域返回/未捕获 JS 异常)' ;;
        128) printf 'rc=128(边界值，按信号线复核)' ;;
        *) if [ "${rc}" -gt 128 ] && [ "${rc}" -le 192 ]; then
               printf "SIG$(( rc - 128 ))($(( rc - 128 )) 号信号)"
           else
               printf "rc=${rc}(其他)"
           fi ;;
    esac
}
daemon_gate() {  # P1-4（R2，自 topoff 移植）：pgrep 双名（com.cellar.daemon 安装名/cellar-daemon 构建名）+ launchctl 腿；
    #              S3 属 R2 备选适用面（关编排开关），需 ack 显式确认
    local loaded=0 ack="${1:-}"
    pgrep -x com.cellar.daemon >/dev/null 2>&1 && loaded=1
    pgrep -x cellar-daemon >/dev/null 2>&1 && loaded=1
    launchctl print system/com.cellar.daemon >/dev/null 2>&1 && loaded=1
    [ "${loaded}" -eq 1 ] || { log "[R2] daemon 卸载=通过（pgrep 双名 + launchctl）"; return 0; }
    log "[R2] daemon 仍在（pgrep/launchctl 命中）——S3 备选=系统设置→通用→Cellar 编排开关关闭；确认已关闭请追加参数 ack 重跑，否则先 sudo launchctl bootout system/com.cellar.daemon"
    if [ "${ack}" != "ack" ]; then
        log "[R2] 未给 ack——拒绝进入实验"
        exit 3
    fi
    log "[R2] ack 已给——编排开关备选确认，继续"
}
r1_lower_guard() {  # P1-4（R1）：电量 <40% 硬拦截——拒绝进入任何写步
    local p
    p="$(batt_percent)"
    if [ -n "${p}" ] && [ "${p}" -lt 40 ]; then
        log "[R1] 电量 ${p}% 低于硬下界 40%——拒绝进入实验（下界在任何实验中都提供小时级缓冲）"
        exit 3
    fi
    log "[R1] 电量下界检查=通过（${p:-?}% ≥ 40%）"
}

cmd="${1:-help}"
case "${cmd}" in
    help|--help|-h)
        sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac
log "=== GA JXA spike 包装（S3）uid=$(id -u) macOS=$(sw_vers -productVersion) 日志=${LOG} ==="

case "${cmd}" in
    # ── E0 探测（只读；js 框架加载 segfault 时定位元凶并 --skip 续跑一轮）──
    probe)
        log "=== E0 probe：候选框架枚举 + NSBundle 加载 + 类解析 + 方法探针 ==="
        out="$(osascript -l JavaScript "${JS}" probe 2>&1)"
        rc=$?
        printf '%s\n' "${out}" | tee -a "${LOG}"
        shape="$(classify_exit "${rc}")"
        rec "probe.exit" "${rc}"
        rec "probe.shape" "${shape}"
        concl "probe" "rc=${rc} shape=${shape}"
        if [ "${rc}" -ge 128 ]; then
            culprit="$(printf '%s\n' "${out}" | sed -n 's/.*probe.bundleload=\([^:]*\): ok.*/\1/p' | tail -1)"
            if [ -n "${culprit}" ]; then
                log "[segfault 线] 崩溃疑在加载 ${culprit} 之后——--skip ${culprit} 续跑一轮（E0 多轮迭代）"
                out2="$(osascript -l JavaScript "${JS}" probe --skip "${culprit}" 2>&1)"
                rc2=$?
                printf '%s\n' "${out2}" | tee -a "${LOG}"
                rec "probe.skipExit" "${rc2}"
                rec "probe.skipCulprit" "${culprit}"
                concl "probe.skip" "culprit=${culprit} rc=${rc2} shape=$(classify_exit "${rc2}")"
            else
                log "[segfault 线] 无 bundleload=ok 记录——崩溃在更早段，保留日志人工判读"
            fi
        fi
        [ "$(kv_get probe.class_found)" != "" ] || {
            class_line="$(printf '%s\n' "${out}" | sed -n 's/^probe.class_found=//p' | tail -1)"
            [ -n "${class_line}" ] && rec "probe.class_found" "${class_line}"
        }
        cls="$(printf '%s\n' "${out}" | sed -n 's/^probe.class=//p' | tail -1)"
        [ -n "${cls}" ] && rec "probe.class_found" "yes" && rec "probe.class" "${cls}"
        ;;
    # ── E1/E2 设值（独立子进程 + 退出形态捕获 + 读数臂采样）────────────
    set)
        require_n="${2:-}"
        case "${require_n}" in ''|*[!0-9]*) log "用法：set <n>（0–100 整数，第三参可给 ack）"; exit 2 ;; esac
        if [ "${require_n}" -lt 0 ] || [ "${require_n}" -gt 100 ]; then log "n 超界（0–100）"; exit 2; fi
        daemon_gate "${3:-}"   # P1-4：R2 daemon 门禁（ack 备选适用 S3）
        r1_lower_guard         # P1-4：R1 下界 40% 硬拦截
        # R3：首写前记录 battlimit 原值与电量快照（JXA 通道无读取 API——以 pmset battlimit 为还原锚）
        if [ ! -f "${STATE}" ]; then
            cat >"${STATE}" <<EOF
{
  "created": "${TS}",
  "battlimit_original": "$(battlimit_read)",
  "percent_snapshot": "$(batt_percent)"
}
EOF
            chmod 600 "${STATE}"
            log "[R3] 状态文件已写入 ${STATE}（battlimit_original=$(state_get battlimit_original)）"
        fi
        # R3-swift（CARRIER=swift 专属）：实验前 mclLimit 回写入档——真还原锚（getMCLLimitWithError 读回通道，
        # battlimit 死信号给不了的证据；0.19.20 编排通道「无读回」痛点的直接解法候选）
        if [ "${CARRIER}" = "swift" ] && [ -z "$(kv_get swift.mcl.original)" ]; then
            swift_orig="$(swift "${SET_SWIFT}" get 2>/dev/null | sed -n 's/^get\.mclLimit=\([0-9][0-9]*\).*/\1/p' | tail -1)"
            if [ -n "${swift_orig}" ]; then
                rec "swift.mcl.original" "${swift_orig}"
                log "[R3-swift] 实验前 mclLimit=${swift_orig}（getMCLLimit 回写入档——restore 精确锚）"
            else
                log "[R3-swift] get 回读失败（不入档）——restore 将退回 RESTORE_TARGET=${RESTORE_TARGET}"
            fi
        fi
        log "=== set ${require_n}：独立子进程执行（载体=${CARRIER}；崩溃隔离），捕获退出码/信号形态 ==="
        if [ "${CARRIER}" = "swift" ]; then
            out="$(swift "${SET_SWIFT}" set "${require_n}" 2>&1)"
        else
            out="$(osascript -l JavaScript "${JS}" set "${require_n}" 2>&1)"
        fi
        rc=$?
        printf '%s\n' "${out}" | tee -a "${LOG}"
        shape="$(classify_exit "${rc}")"
        log "退出形态：rc=${rc} → ${shape}"
        rec "set${require_n}.exit" "${rc}"
        rec "set${require_n}.shape" "${shape}"
        # 载体输出簿记（swift 辅助器打印 probe/set85 kv——判据①③④素材不经单独 probe 也能入档）
        cls_line="$(printf '%s\n' "${out}" | sed -n 's/^probe\.class=//p' | tail -1)"
        [ -n "${cls_line}" ] && rec "probe.class_found" "yes" && rec "probe.class" "${cls_line}"
        rb_line="$(printf '%s\n' "${out}" | sed -n 's/^set85\.readback\.mclLimit=\([0-9][0-9]*\).*/\1/p' | tail -1)"
        [ -n "${rb_line}" ] && rec "set${require_n}.readback.mclLimit" "${rb_line}"
        if [ "${require_n}" -ge 80 ] && [ "${rc}" -eq 0 ]; then
            log "≥80 设值干净返回——E1 读数臂：5 分钟 battlimit 采样（每 30s）+ 行为判读（isCharging 停充 ∨ percent 驻留 ≤n 连续 2 采样）"
            hit=no
            consec=0; obs=""
            for i in 1 2 3 4 5 6 7 8 9 10; do
                [ "${i}" -gt 1 ] && sleep 30
                bl="$(battlimit_read)"
                bp="$(batt_percent)"; bc="$(batt_charging)"
                log "[E1采样] #${i}/10 battlimit=${bl:-无读数} percent=${bp:-?}% isCharging=${bc:-?}"
                rec "set85.sample.${i}" "battlimit=${bl:-none} percent=${bp:-unknown} charging=${bc:-unknown}"
                [ "${bl}" = "${require_n}" ] && hit=yes
                # P2-2：行为判读（判据②佐证臂）——停充或 percent 驻留 ≤n 连续 2 采样 → stopped（闩锁）
                if [ "${bc}" = "No" ] || { [ -n "${bp}" ] && [ "${bp}" -le "${require_n}" ]; }; then
                    consec=$(( consec + 1 ))
                else
                    consec=0
                fi
                if [ "${consec}" -ge 2 ] && [ -z "${obs}" ]; then obs="stopped"; fi
            done
            [ -z "${obs}" ] && obs="observed=no-stop"   # 未观察到行为判读成立——如实记录，不粉饰
            rec "set85.battlimit_hit" "${hit}"
            rec "set85.observe.charging" "${obs}"
            concl "set${require_n}" "rc=0 ${shape} battlimit_hit=${hit} 行为臂=${obs}"
        elif [ "${require_n}" -lt 80 ]; then
            log "<80 形态已定谳：${shape}——10 分钟短观察（错误域返回时看是否仍生效）"
            # 干净拒绝形态（swift 载体 ：error: 变体特有）：return=false + error 域——比 segfault 更好的产品形态，判据认
            refused="$(printf '%s\n' "${out}" | sed -n '/^set85\.return=false/p' | tail -1)"
            if [ -n "${refused}" ]; then
                errline="$(printf '%s\n' "${out}" | sed -n 's/^set85\.error=//p' | tail -1)"
                rec "set75.refused" "yes(return=false error=${errline:-none})"
                log "[E2] 干净拒绝实锤：return=false error=${errline:-none}"
            fi
            for i in 1 2; do
                [ "${i}" -gt 1 ] && sleep 300
                log "[E2观察] #${i}/2 battlimit=$(battlimit_read) percent=$(batt_percent)% isCharging=$(batt_charging)"
                rec "set75.observe.${i}" "battlimit=$(battlimit_read) percent=$(batt_percent) charging=$(batt_charging)"
            done
            concl "set${require_n}" "${shape}"
        else
            concl "set${require_n}" "${shape}"
        fi
        ;;
    # ── E4 还原 ──────────────────────────────────────────────────────
    restore)
        daemon_gate "${2:-}"   # P1-4：R2 daemon 门禁（restore 亦经 PowerUI 接口写——同受门禁约束）
        r1_lower_guard         # P1-4：R1 下界 40% 硬拦截
        if [ "${CARRIER}" = "swift" ]; then
            # swift 载体：按 swift.mcl.original（实验前回读真锚）精确还原；无锚退 RESTORE_TARGET；读回验证
            target="$(kv_get swift.mcl.original)"
            [ -n "${target}" ] || target="${RESTORE_TARGET}"
            log "=== restore（载体=swift）：还原目标 mclLimit=${target}（原值锚优先，退 ${RESTORE_TARGET}）==="
            out="$(swift "${SET_SWIFT}" set "${target}" 2>&1)"
            rc=$?
            printf '%s\n' "${out}" | tee -a "${LOG}"
            shape="$(classify_exit "${rc}")"
            rec "restore.exit" "${rc}"
            rec "restore.shape" "${shape}"
            sleep 5
            v="$(swift "${SET_SWIFT}" get 2>/dev/null | sed -n 's/^get\.mclLimit=\([0-9][0-9]*\).*/\1/p' | tail -1)"
            log "还原后 mclLimit 读回=${v:-无}（目标=${target}）"
            if [ -n "${v}" ] && [ "${v}" = "${target}" ]; then
                rec "restore.match" "yes"
                concl "restore" "clean(mclLimit 读回=${v} 与目标一致)"
            else
                rec "restore.match" "no"
                concl "restore" "unclear(读回=${v:-无} vs 目标=${target}——按 UI 兜底复核；如实记录不粉饰)"
            fi
        else
            log "=== restore（载体=jxa）：接口设回 100；失败时输出 UI 兜底指引 ==="
            out="$(osascript -l JavaScript "${JS}" restore 100 2>&1)"
            rc=$?
            printf '%s\n' "${out}" | tee -a "${LOG}"
            shape="$(classify_exit "${rc}")"
            rec "restore.exit" "${rc}"
            rec "restore.shape" "${shape}"
            sleep 5
            bl="$(battlimit_read)"
            orig="$(state_get battlimit_original)"
            log "还原后 battlimit=${bl:-无读数}（首写前原值=${orig:-未记录}）"
            if [ -n "${orig}" ] && [ "${bl}" = "${orig}" ]; then
                rec "restore.match" "yes"
                concl "restore" "clean(battlimit 回原值 ${orig})"
            elif [ -z "${orig}" ] && [ -z "${bl}" ]; then
                rec "restore.match" "yes"
                concl "restore" "clean(原无 battlimit 读数，现亦无)"
            else
                rec "restore.match" "no"
                concl "restore" "unclear(battlimit=${bl:-无} vs 原值=${orig:-无}——按 UI 兜底复核；如实记录不粉饰)"
            fi
        fi
        ;;
    # ── concl（§5 判据①–④）──────────────────────────────────────────
    concl)
        log "=== concl：§5 判据①–④（结果文件 ${RESULTS}）==="
        [ -f "${RESULTS}" ] || { log "无结果文件——实验未执行"; exit 1; }
        cls="$(kv_get probe.class)"
        set85_exit="$(kv_get set85.exit)"; set85_hit="$(kv_get set85.battlimit_hit)"
        set75_shape="$(kv_get set75.shape)"
        restore_match="$(kv_get restore.match)"
        # ① 类可解析且设值有可观察效果（三臂任一：battlimit 读数〔jxa 设想〕/ swift 读回==85 / 行为臂——battlimit 已实证死信号）
        c1=no
        set85_rb="$(kv_get set85.readback.mclLimit)"
        [ -n "${cls}" ] && [ "${set85_exit}" = "0" ] && { [ "${set85_hit}" = "yes" ] || [ "${set85_rb}" = "85" ] || [ "$(kv_get set85.observe.charging)" = "stopped" ]; } && c1=yes
        concl "criterion.1" "${c1}(class=${cls:-未解析} set85.rc=${set85_exit:-未执行} 读回=${set85_rb:-无} battlimit读数=${set85_hit:-未执行})"
        # ② ≥80 行为生效
        c2=no
        [ "${set85_exit}" = "0" ] && { [ "${set85_hit}" = "yes" ] || [ "$(kv_get set85.observe.charging)" = "stopped" ]; } && c2=yes
        concl "criterion.2" "${c2}(set85 rc=${set85_exit:-未执行} 读数臂=${set85_hit:-未执行}——判读臂与 S2 同款)"
        # ③ <80 拒绝形态定谳（segfault / 错误域 / 干净拒绝〔swift 载体 return=false+error〕三者皆算定谳）
        c3=no
        case "${set75_shape}" in
            *SIGSEGV*) c3=yes ;;
            *script-error*|*SIGABRT*) c3=yes ;;
        esac
        [ -n "$(kv_get set75.refused)" ] && case "$(kv_get set75.refused)" in yes*) c3=yes ;; esac
        concl "criterion.3" "${c3}(set75 形态=${set75_shape:-未执行} 拒绝=$(kv_get set75.refused:-未执行)——segfault/错误域/干净拒绝皆定谳，产品化按独立子进程隔离设计)"
        # ④ 还原干净
        c4=no
        [ "${restore_match}" = "yes" ] && c4=yes
        concl "criterion.4" "${c4}(restore.match=${restore_match:-未执行})"
        # §5 判定：①② pass = 二轨候选 GO；③④ 为 0.21 产品化设计输入
        if [ "${c1}" = "yes" ] && [ "${c2}" = "yes" ]; then
            concl "go" "GO(二轨候选——免用户建快捷指令的价值成立；③④ 作产品化设计输入)"
        else
            concl "go" "NO-GO-or-iterate(①=${c1} ②=${c2}——E0 允许多轮迭代，先按 probe.note 补确切方法名再重评)"
        fi
        log "=== 判定汇总见上方 concl.jxa.* ==="
        ;;
    *)
        log "未知子命令：${cmd}（可用：probe set restore concl help）"
        exit 2
        ;;
esac
