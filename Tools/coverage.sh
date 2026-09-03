#!/bin/bash
# CellarCore 状态机覆盖率（Phase 4 v1.0 收口批项 A；PLAN「状态机覆盖率 ≥80%」）
#
# 口径：圈定纯逻辑文件集 Sources/CellarCore/{Control,Daemon}/——排除 SMC/、
# Monitor/、Diagnostics/ 等 IOKit/SMAppService 硬件耦合文件（CellarCoreCheck 为
# mock 场景驱动，真硬件路径只有 root+真机可跑，全量口径不可达成也不符 PLAN 措辞）。
# 指标：line ≥80%（llvm-cov -fail-under-lines 原生门禁，低于阈值退出非零）。
#
# ⚠️ 执行细节：插桩构建后必须直接执行 .build/debug/CellarCoreCheck 并以
# LLVM_PROFILE_FILE 指定 profraw 落点——`swift run` 会以无 flag 的构建计划触发
# 重编译，覆盖掉插桩二进制。
set -euo pipefail
cd "$(dirname "$0")/.."

THRESHOLD="${1:-80}"
PROFILE_DIR=$(mktemp -d)
trap 'rm -rf "$PROFILE_DIR"' EXIT
export LLVM_PROFILE_FILE="$PROFILE_DIR/cellar-%p.profraw"

echo "==> 1/4 插桩构建（debug + profile）"
swift build -c debug -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping

echo "==> 2/4 运行 CellarCoreCheck（场景全量）"
.build/debug/CellarCoreCheck

echo "==> 3/4 合并 profraw"
xcrun llvm-profdata merge -sparse "$PROFILE_DIR"/*.profraw -o "$PROFILE_DIR/merged.profdata"

echo "==> 4/4 状态机文件集覆盖率（line 阈值 ${THRESHOLD}%）"
# Xcode 工具链的 llvm-cov 不支持 -fail-under-lines——解析 TOTAL 行的 Lines Cover
# 列（第 10 列）与阈值比较，低于阈值退出非零（CI 门禁语义）。
REPORT=$(xcrun llvm-cov report .build/debug/CellarCoreCheck \
  -instr-profile="$PROFILE_DIR/merged.profdata" \
  -ignore-filename-regex='.*/CellarCore/(SMC|Monitor|Diagnostics)/' \
  Sources/CellarCore)
echo "$REPORT"
LINE_COVER=$(echo "$REPORT" | awk '$1 == "TOTAL" {gsub("%", "", $10); print $10}')
echo "状态机 line 覆盖率：${LINE_COVER}%（阈值 ${THRESHOLD}%）"
awk -v v="$LINE_COVER" -v t="$THRESHOLD" 'BEGIN { exit (v+0 < t+0) ? 1 : 0 }'
