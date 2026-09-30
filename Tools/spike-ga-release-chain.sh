#!/bin/bash
# Cellar macOS 27 GA 发布链路走查（S6，只读零写入）— 方案 docs/plans/phase5-0.20-macos27-ga-spike.md §8 v3 定稿
# 内容（§8）：a) xattr 四件套（App 主二进制+Info.plist / LaunchDaemons plist / PrivilegedHelperTools daemon）
#   b) launchctl print system/com.cellar.daemon 运行态（0.19.20 在役即活体证据）
#   c) 后台项 UI 呈现人工走查清单（「停止后台运行」影响面只在专门走查日验证，平时仅记录呈现）
#   d) quarantine 传播判定：无传播=现行安装器安全（登记结论）；有传播=真问题进 0.21 批 5 修复清单
# 无 GO/NO-GO（§8 判据：成档即输入）。无 root 可跑（launchctl print system 域与部分项 root 更全）。
# 用法：Tools/spike-ga-release-chain.sh [run]

set -u

RESULTS="/tmp/spike-ga-results-release-chain.txt"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="/tmp/spike-ga-release-chain-${TS}.log"
APP_PLIST="/Applications/Cellar.app/Contents/Info.plist"
DAEMON_PLIST="/Library/LaunchDaemons/com.cellar.daemon.plist"
HELPER_BIN="/Library/PrivilegedHelperTools/com.cellar.daemon"

log() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "${1}" | tee -a "${LOG}"
}
concl() {
    log "concl.releasechain.${1}=${2}"
}
rec() {
    printf '%s=%s\n' "${1}" "${2}" >>"${RESULTS}"
}
kv_get() {
    [ -f "${RESULTS}" ] || { printf ''; return; }
    sed -n "s/^${1}=//p" "${RESULTS}" | tail -1
}

log "=== GA 发布链路走查（S6，只读）uid=$(id -u) macOS=$(sw_vers -productVersion) 日志=${LOG} ==="
rm -f "${RESULTS}"

# ── a) xattr 四件套 ─────────────────────────────────────────────────
app_bin="/Applications/Cellar.app/Contents/MacOS/Cellar"
if [ ! -x "${app_bin}" ]; then
    # P3-6：二进制名以 plutil 读 CFBundleExecutable 为准（原 sed 模式 [\s] 在 BRE 不生效——死代码）
    exec_name="$(plutil -extract CFBundleExecutable raw "${APP_PLIST}" 2>/dev/null | head -1)"
    if [ -n "${exec_name}" ] && [ -x "/Applications/Cellar.app/Contents/MacOS/${exec_name}" ]; then
        app_bin="/Applications/Cellar.app/Contents/MacOS/${exec_name}"
    else
        app_bin="$(find /Applications/Cellar.app/Contents/MacOS -type f -perm +111 2>/dev/null | head -1)"
    fi
fi

quar_total=0
xattr_item() {  # xattr_item <标签> <路径>
    local label="${1}" path="${2}" out q
    if [ ! -e "${path}" ]; then
        log "[a] ${label}: 路径不存在（${path}）——如实记录"
        rec "xattr.${label}" "path-missing(${path})"
        return
    fi
    out="$(xattr -l "${path}" 2>&1)"
    if printf '%s' "${out}" | grep -q "com.apple.quarantine"; then
        q=yes
        quar_total=$(( quar_total + 1 ))
    else
        q=no
    fi
    local other
    other="$(printf '%s' "${out}" | sed -n 's/^\([a-z.]*\): .*/\1/p' | grep -v '^com.apple.quarantine$' | tr '\n' ',' )"
    log "[a] ${label}: quarantine=${q}（其他 xattr=${other:-无}）路径=${path}"
    rec "xattr.${label}" "quarantine=${q} others=${other:-none} path=${path}"
}
log "=== a) xattr 四件套（com.apple.quarantine 有无逐件列出）==="
xattr_item "app_binary" "${app_bin}"
xattr_item "app_infoplist" "${APP_PLIST}"
# LaunchDaemons 逐个扫 *cellar*（预注册主对象=com.cellar.daemon.plist；注意文件名以 com. 开头）
daemon_plists="$(find /Library/LaunchDaemons -maxdepth 1 -name '*cellar*' 2>/dev/null)"
if [ -n "${daemon_plists}" ]; then
    while IFS= read -r dp; do
        xattr_item "daemon_plist_$(basename "${dp}" .plist)" "${dp}"
    done <<EOF2
${daemon_plists}
EOF2
else
    log "[a] /Library/LaunchDaemons 无 *cellar* plist——如实记录"
    rec "xattr.daemon_plist" "none-found"
fi
xattr_item "helper_binary" "${HELPER_BIN}"

# ── b) daemon 运行态 ────────────────────────────────────────────────
log "=== b) launchctl print system/com.cellar.daemon 运行态 ==="
lc_out="$(launchctl print system/com.cellar.daemon 2>&1)"
lc_rc=$?
if [ "${lc_rc}" -eq 0 ]; then
    state="$(printf '%s' "${lc_out}" | sed -n 's/^[[:space:]]*state = \(.*\)$/\1/p' | head -1)"
    pid="$(printf '%s' "${lc_out}" | sed -n 's/^[[:space:]]*pid = \([0-9]*\)$/\1/p' | head -1)"
    runs="$(printf '%s' "${lc_out}" | sed -n 's/^[[:space:]]*runs = \([0-9]*\)$/\1/p' | head -1)"
    log "[b] daemon 运行态：state=${state:-?} pid=${pid:-无} runs=${runs:-?}（在役活体证据）"
    rec "daemon.state" "${state:-unknown}"
    rec "daemon.pid" "${pid:-none}"
    rec "daemon.runs" "${runs:-unknown}"
else
    log "[b] launchctl print 失败（rc=${lc_rc}）——非 root 对 system 域受限或服务未注册；root 重跑更全（如实记录）"
    log "[b] 错误头部：$(printf '%s' "${lc_out}" | head -1)"
    rec "daemon.state" "unavailable(rc=${lc_rc}；root 重跑可更全)"
fi

# ── c) 后台项 UI 呈现人工走查清单（平时仅记录呈现）──────────────────
log "=== c) 后台项呈现人工走查清单（§8：影响面只在专门走查日验证——平时仅记录呈现）==="
log "  走查 1：系统设置 → 通用 → 登录项与扩展 → 「后台运行」允许列表：Cellar（App）与 cellar-daemon/Cellar 守护项 呈现形态（名称/图标/开关态）逐一记录"
log "  走查 2：记录 Cellar 条目是否出现在「通知/登录项」等其他分组（呈现位置漂移是 GA 行为变化信号）"
log "  走查 3：【仅专门走查日】对 Cellar 条目执行「停止后台运行」后观察：daemon 是否被 bootout、限充/风扇执法是否中断、重启 App 后恢复路径——平时不执行"
rec "ui.walkthrough" "checklist-printed(执行日与执行人由用户回填)"

# ── d) 传播判定与成档结论（无 GO/NO-GO）─────────────────────────────
log "=== d) quarantine 传播判定（基于实况，§8 判据②）==="
app_bin_q="$(kv_get xattr.app_binary)"
plist_q="$(kv_get xattr.daemon_plist_com.cellar.daemon)"
[ -z "${plist_q}" ] && plist_q="$(kv_get xattr.daemon_plist)"
helper_q="$(kv_get xattr.helper_binary)"
log "四件套 quarantine 明细："
log "  App 主二进制: ${app_bin_q:-未记录}"
log "  App Info.plist: $(kv_get xattr.app_infoplist || printf '未记录')"
log "  daemon plist: ${plist_q:-未记录}"
log "  helper 二进制: ${helper_q:-未记录}"
any_quar=no
for v in "${app_bin_q}" "$(kv_get xattr.app_infoplist)" "${plist_q}" "${helper_q}"; do
    case "${v}" in *quarantine=yes*) any_quar=yes ;; esac
done
if [ "${any_quar}" = "no" ]; then
    concl "propagation" "none(四件套均无 quarantine——现行 dmg→App→install 链天然不传播，安装器安全，登记结论)"
else
    concl "propagation" "FOUND(${quar_total} 件带 quarantine——真问题，进 0.21 批 5 修复清单)"
fi
concl "daemon.alive" "$(kv_get daemon.state || printf '未记录')"
concl "verdict" "n-a(§8：无 GO/NO-GO——产出即输入)"
log "=== 走查完成：逐件明细见 ${RESULTS} 与日志 ==="
exit 0
