#!/bin/bash
# Cellar macOS 27 GA 遥测实况 spike（S4，只读零风险先行）— 方案 docs/plans/phase5-0.20-macos27-ga-spike.md §6 v3 定稿
# 主判据走产品真实数据通路：CellarCoreCheck --battery root/非 root 双跑 PASS（§6——唯一能证明「产品在 GA 上读数正常」）。
# 信息项（成档不进判定）：必需 8 字段三层落点矩阵 / ioreg 四形态可见性矩阵 / SMC TB0T–TB2T / BCF0·B0RM 探测提示 /
#   PowerTelemetryData 恒等式抽查。
# 预注册映射（§6）：任一必需字段仅 AppleSmartBatteryPack 子层可见 = 解析器未覆盖该层 → 0.19.x 热修输入；
#   ioreg -rc 取不到必需字段同理。
# 用法（root/非 root 各跑一遍；concl 汇总双跑）：
#   Tools/spike-ga-telemetry.sh run      # 当前身份执行 a–f 全段（默认子命令）
#   sudo Tools/spike-ga-telemetry.sh run # root 身份再跑一遍
#   Tools/spike-ga-telemetry.sh concl    # 汇总双跑结果 + 主判定
# 构建前置：swift build -c release → .build/release/CellarCoreCheck（缺产物时本工具如实记录 fail(binary-missing) 并提示）

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
CORECHECK="${ROOT}/.build/release/CellarCoreCheck"
STATE="/tmp/spike-ga-state-telemetry.json"
RESULTS="/tmp/spike-ga-results-telemetry.txt"
TMPDIR_TELEM="/tmp/spike-ga-telemetry-work"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="/tmp/spike-ga-telemetry-${TS}.log"

REQUIRED_FIELDS="CurrentCapacity Voltage Amperage Temperature IsCharging ExternalConnected CycleCount DesignCapacity"
OPTIONAL_FIELDS="NominalChargeCapacity AppleRawCurrentCapacity PowerTelemetryData notChargingReason"

log() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "${1}" | tee -a "${LOG}"
}
concl() {
    log "concl.telemetry.${1}=${2}"
}
rec() {
    printf '%s=%s\n' "${1}" "${2}" >>"${RESULTS}"
}
kv_get() {
    [ -f "${RESULTS}" ] || { printf ''; return; }
    sed -n "s/^${1}=//p" "${RESULTS}" | tail -1
}
uid_tag() {
    if [ "$(id -u)" -eq 0 ]; then printf 'root'; else printf 'nonroot'; fi
}
field_in() {  # field_in <输出文本> <字段名> → yes/no
    case "${1}" in
        *"\"${2}\""*) printf 'yes' ;;
        *) printf 'no' ;;
    esac
}

cmd="${1:-run}"

case "${cmd}" in
    help|--help|-h)
        sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    concl)
        # 纯汇总：不重测，只读结果文件出主判定
        log "=== concl：CellarCoreCheck 双跑汇总（结果文件 ${RESULTS}）==="
        root_r="$(kv_get corecheck_root)"
        nonroot_r="$(kv_get corecheck_nonroot)"
        concl "corecheck.root" "${root_r:-未跑}"
        concl "corecheck.nonroot" "${nonroot_r:-未跑}"
        if [ -n "${root_r}" ] && [ -n "${nonroot_r}" ]; then
            if [ "${root_r}" = "pass" ] && [ "${nonroot_r}" = "pass" ]; then
                concl "main" "pass(CellarCoreCheck root+非 root 双跑 PASS——GA 覆盖确认，不出热修)"
            else
                concl "main" "FAIL(root=${root_r} nonroot=${nonroot_r}——按信息项矩阵定位缺层 → 0.19.x 热修立项)"
            fi
        else
            concl "main" "pending(双跑未齐：root=${root_r:-未跑} nonroot=${nonroot_r:-未跑})"
        fi
        po="$(kv_get matrix.pack_only_fields)"
        if [ -n "${po}" ]; then
            concl "matrix.packOnly" "yes(${po}——§6 预注册映射=热修输入)"
        else
            concl "matrix.packOnly" "no"
        fi
        log "=== 判定汇总见上方 concl.telemetry.* ==="
        exit 0
        ;;
esac

log "=== GA 遥测 spike（S4，只读）uid=$(id -u)($(uid_tag)) macOS=$(sw_vers -productVersion) 日志=${LOG} ==="
mkdir -p "${TMPDIR_TELEM}"

# ── a) 主判据：CellarCoreCheck --battery（产品同 API 桥 + 解析器）──────
tag="$(uid_tag)"
if [ -x "${CORECHECK}" ]; then
    log "=== a) CellarCoreCheck --battery（${tag}）==="
    "${CORECHECK}" --battery >"${TMPDIR_TELEM}/corecheck-${tag}.txt" 2>&1
    rc=$?
    head -14 "${TMPDIR_TELEM}/corecheck-${tag}.txt" | tee -a "${LOG}"
    if [ "${rc}" -eq 0 ] && ! grep -q "❌" "${TMPDIR_TELEM}/corecheck-${tag}.txt"; then
        rec "corecheck_${tag}" "pass"
        concl "corecheck.${tag}" "pass(rc=0 无错误标记)"
    else
        rec "corecheck_${tag}" "fail(rc=${rc})"
        concl "corecheck.${tag}" "fail(rc=${rc}——详见日志；GA 解析器缺陷即 0.19.x 热修输入)"
    fi
else
    log "=== a) CellarCoreCheck 缺产物（${CORECHECK}）——构建前置：swift build -c release（仓库根执行）==="
    rec "corecheck_${tag}" "fail(binary-missing)"
    concl "corecheck.${tag}" "fail(binary-missing)——先 swift build -c release 再重跑"
fi

# ── b) 必需 8 字段三层落点矩阵（顶层 / BatteryData / AppleSmartBatteryPack）──
log "=== b) 必需字段三层落点矩阵（解析器当前两层回退：顶层→BatteryData；Pack 层缺口=热修输入）==="
ioreg -rc AppleSmartBattery >"${TMPDIR_TELEM}/asb.txt" 2>/dev/null
ioreg -rc AppleSmartBatteryPack >"${TMPDIR_TELEM}/pack.txt" 2>/dev/null
# BatteryData 子字典块提取（同缩进 } 收口）
awk '/"BatteryData" = \{/{flag=1} flag{print} flag&&/^\}/{flag=0}' "${TMPDIR_TELEM}/asb.txt" >"${TMPDIR_TELEM}/bd.txt" 2>/dev/null
pack_present=no
grep -q "AppleSmartBatteryPack" "${TMPDIR_TELEM}/pack.txt" && pack_present=yes
log "AppleSmartBatteryPack 条目存在性=${pack_present}"
matrix_line=""
packonly_fields=""
for f in ${REQUIRED_FIELDS}; do
    top="$(field_in "$(cat "${TMPDIR_TELEM}/asb.txt")" "${f}")"
    bd="$(field_in "$(cat "${TMPDIR_TELEM}/bd.txt")" "${f}")"
    pk="$(field_in "$(cat "${TMPDIR_TELEM}/pack.txt")" "${f}")"
    log "  必需 ${f}: 顶层=${top} BatteryData=${bd} Pack=${pk}"
    matrix_line="${matrix_line} ${f}(top=${top},bd=${bd},pack=${pk})"
    if [ "${top}" = "no" ] && [ "${bd}" = "no" ] && [ "${pk}" = "yes" ]; then
        packonly_fields="${packonly_fields} ${f}"
    fi
done
opt_line=""
for f in ${OPTIONAL_FIELDS}; do
    top="$(field_in "$(cat "${TMPDIR_TELEM}/asb.txt")" "${f}")"
    opt_line="${opt_line} ${f}(top=${top})"
done
log "可选项单列：${opt_line}"
rec "matrix.required" "${matrix_line}"
rec "matrix.optional" "${opt_line}"
rec "matrix.pack_entry_present" "${pack_present}"
if [ -n "${packonly_fields}" ]; then
    rec "matrix.pack_only_fields" "${packonly_fields}"
    concl "matrix.packOnly" "yes(${packonly_fields} 仅 Pack 层可见——解析器无 Pack 回退=0.19.x 热修输入，§6 预注册映射)"
else
    concl "matrix.packOnly" "no"
fi

# ── c) ioreg 四形态可见性矩阵（-a 静默省略坑量化，§6）────────────────
log "=== c) ioreg 四形态可见性矩阵 ==="
ioreg -rc AppleSmartBattery >"${TMPDIR_TELEM}/f1.txt" 2>/dev/null
ioreg -rn -c AppleSmartBattery >"${TMPDIR_TELEM}/f2.txt" 2>/dev/null
ioreg -a -c AppleSmartBattery >"${TMPDIR_TELEM}/f3.txt" 2>/dev/null
ioreg -l >"${TMPDIR_TELEM}/f4.txt" 2>/dev/null
forms_line=""
for f in ${REQUIRED_FIELDS}; do
    v1=no v2=no v3=no v4=no
    grep -q "\"${f}\"" "${TMPDIR_TELEM}/f1.txt" && v1=yes
    grep -q "\"${f}\"" "${TMPDIR_TELEM}/f2.txt" && v2=yes
    grep -q "\"${f}\"" "${TMPDIR_TELEM}/f3.txt" && v3=yes
    grep -q "\"${f}\"" "${TMPDIR_TELEM}/f4.txt" && v4=yes
    log "  ${f}: -rc=${v1} -rn-c=${v2} -a-c=${v3} -l=${v4}"
    forms_line="${forms_line} ${f}(${v1}/${v2}/${v3}/${v4})"
done
grep -q "AppleSmartBattery" "${TMPDIR_TELEM}/f3.txt" && a_entry=yes || a_entry=no
log "四形态列序=-rc / -rn -c / -a -c / -l；-a 形态 AppleSmartBattery 条目呈现=${a_entry}（§6：-a 静默省略坑量化）"
rec "forms.matrix" "${forms_line}"
rec "forms.a_entry_visible" "${a_entry}"
concl "forms" "matrix=(逐字段 -rc/-rn-c/-a-c/-l 四列见 ${RESULTS} forms.matrix)"

# ── d) SMC TB0T/TB1T/TB2T 读值（内嵌调用编译产物；无产物如实跳过）────
log "=== d) SMC TB0T/TB1T/TB2T 读值对照（TB0T=0.1℃ 精度新候选源，§6）==="
probe_bin=""
for cand in "${ROOT}/.build/release/m0-smc-probe" "/tmp/spike-ga-m0-smc-probe" "${ROOT}/.build/debug/m0-smc-probe"; do
    [ -x "${cand}" ] && { probe_bin="${cand}"; break; }
done
if [ -z "${probe_bin}" ] && [ -f "${ROOT}/Tools/m0-smc-probe.swift" ] && command -v swiftc >/dev/null 2>&1; then
    log "无编译产物——尝试 swiftc 单文件编译到 /tmp/spike-ga-m0-smc-probe（一次性，只读用途）"
    if swiftc -O "${ROOT}/Tools/m0-smc-probe.swift" -o /tmp/spike-ga-m0-smc-probe 2>>"${LOG}"; then
        probe_bin=/tmp/spike-ga-m0-smc-probe
    else
        log "编译失败（原样保留错误于日志）——SMC 段跳过"
    fi
fi
if [ -n "${probe_bin}" ]; then
    "${probe_bin}" >"${TMPDIR_TELEM}/smc-probe.txt" 2>&1
    tb_hit=no
    for k in TB0T TB1T TB2T; do
        line="$(grep "^${k} " "${TMPDIR_TELEM}/smc-probe.txt" | head -1)"
        if [ -n "${line}" ]; then
            tb_hit=yes
            log "  ${line}"
        else
            log "  ${k}=不可读（132 语义或键不存在——如实记录）"
        fi
        rec "smc.${k}" "${line:-unavailable}"
    done
    concl "smc.tbkeys" "${tb_hit}(详见 ${RESULTS} smc.* 原始行)"
else
    log "SMC 探针无产物且无法编译——SMC 段跳过（如实标注）。后续可手动：swiftc -O Tools/m0-smc-probe.swift -o /tmp/spike-ga-m0-smc-probe 后重跑"
    rec "smc.section" "skipped(no-artifact)"
    concl "smc.tbkeys" "skipped(无探针产物)"
fi

# ── e) BCF0/B0RM keyInfo 探测提示段（GA 报告 4B→1B / 字节序反转）──────
log "=== e) BCF0（社区报告 4B→1B）/ B0RM（字节序反转）keyInfo 探测 ==="
if [ -n "${probe_bin:-}" ] && [ "$(id -u)" -eq 0 ]; then
    log "root + 探针产物在位——尝试全量枚举比对："
    if "${probe_bin}" --enum >"${TMPDIR_TELEM}/enum.txt" 2>&1; then
        hit_line="$(grep -E "^(BCF0|B0RM) " "${TMPDIR_TELEM}/enum.txt" | head -4)"
        if [ -n "${hit_line}" ]; then
            printf '%s\n' "${hit_line}" | tee -a "${LOG}"
            rec "smc.bcf0_b0rm" "found($(printf '%s' "${hit_line}" | tr '\n' ';'))"
        else
            log "全量枚举中无 BCF0/B0RM——如实记录（GA 固件可能已删/已改名）"
            rec "smc.bcf0_b0rm" "not-in-enum"
        fi
    else
        log "全量枚举失败（需 root）——保留提示"
        rec "smc.bcf0_b0rm" "enum-failed"
    fi
else
    log "提示段（keyInfo 探测命令，供 root 终端执行）："
    log "  1) swiftc -O Tools/m0-smc-probe.swift -o /tmp/spike-ga-m0-smc-probe"
    log "  2) sudo /tmp/spike-ga-m0-smc-probe --enum | grep -E '^(BCF0|B0RM)'   # 键存在性 + type/size"
    log "  3) 若在列：把键名加入 m0-smc-probe.swift probeKeys 复刻只读读值（勿写）"
    rec "smc.bcf0_b0rm" "hinted(非 root 或无产物)"
fi

# ── f) PowerTelemetryData 恒等式抽查（SystemPowerIn = SystemLoad + BatteryPower）──
log "=== f) PowerTelemetryData 恒等式抽查 ==="
spi="$(sed -n 's/.*"SystemPowerIn" = \([0-9-]*\).*/\1/p' "${TMPDIR_TELEM}/asb.txt" | head -1)"
sld="$(sed -n 's/.*"SystemLoad" = \([0-9-]*\).*/\1/p' "${TMPDIR_TELEM}/asb.txt" | head -1)"
bpw="$(sed -n 's/.*"BatteryPower" = \([0-9-]*\).*/\1/p' "${TMPDIR_TELEM}/asb.txt" | head -1)"
if [ -n "${spi}" ] && [ -n "${sld}" ] && [ -n "${bpw}" ]; then
    delta=$(( spi - sld - bpw ))
    if [ "${spi}" -ne 0 ]; then
        pct=$(( delta * 100 / spi ))
        [ "${pct}" -lt 0 ] && pct=$(( -pct ))
    else
        pct=0
    fi
    if [ "${pct}" -le 5 ]; then ident=pass; else ident=fail; fi
    log "SystemPowerIn=${spi} SystemLoad=${sld} BatteryPower=${bpw} → Δ=${delta}（${pct}%，容差 ±5%）→ 恒等式 ${ident}"
    rec "identity.ptd" "${ident}(SystemPowerIn=${spi} SystemLoad=${sld} BatteryPower=${bpw} delta=${delta})"
    concl "identity" "${ident}(Δ=${delta}/${pct}%)"
else
    log "PowerTelemetryData 字段缺失（SystemPowerIn=${spi:-无} SystemLoad=${sld:-无} BatteryPower=${bpw:-无}）——抽查 n/a（如实记录）"
    rec "identity.ptd" "n-a(fields-missing)"
    concl "identity" "n/a(GA 上 PowerTelemetryData 字段缺失)"
fi

# ── 主判定汇总（双跑齐了才出 main）──────────────────────────────────
root_r="$(kv_get corecheck_root)"
nonroot_r="$(kv_get corecheck_nonroot)"
concl "run.${tag}" "done(本段 concl 见上；a) 主判据=$(kv_get corecheck_${tag}))"
if [ -n "${root_r}" ] && [ -n "${nonroot_r}" ]; then
    if [ "${root_r}" = "pass" ] && [ "${nonroot_r}" = "pass" ]; then
        concl "main" "pass(CellarCoreCheck root+非 root 双跑 PASS——GA 覆盖确认，不出热修)"
    else
        concl "main" "FAIL(root=${root_r} nonroot=${nonroot_r}——按信息项矩阵定位缺层 → 0.19.x 热修立项)"
    fi
else
    concl "main" "pending(双跑未齐：root=${root_r:-未跑} nonroot=${nonroot_r:-未跑}——请以另一身份重跑 run)"
fi
log "=== 本轮（${tag}）完成。双跑汇总：sudo … run + 非 root … run 后执行 concl ==="
exit 0
