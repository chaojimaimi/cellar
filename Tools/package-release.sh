#!/bin/bash
# Cellar 发布打包脚本（Phase 2 WP6 §2.5）。
#
# 流程：Release 构建（xcodebuild → App/.release-build/）→ codesign 深度校验 →
# spctl 评估（容错，ad-hoc 签名预期 rejected，仅信息输出）→ ditto 打 zip 至
# dist/ → 产物清单。幂等：每次执行重新构建并覆盖旧 zip。
set -euo pipefail

# 仓库根（脚本位于仓库根 Tools/，与 m0 脚本同层）。
cd "$(dirname "$0")/.."

# 版本号单变量：zip 文件名由此派生；发布时与 App/CLI/daemon 版本串保持一致。
VERSION=0.2.0-alpha

PROJECT="App/CellarApp.xcodeproj"
SCHEME="CellarApp"
DERIVED_DATA="App/.release-build"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Cellar.app"
ZIP_PATH="dist/Cellar-v${VERSION}.zip"

echo "==> 1/5 Release 构建（xcodebuild）"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release -derivedDataPath "$DERIVED_DATA" build

echo "==> 2/5 签名校验（codesign -v，深度）"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> 3/5 Gatekeeper 评估（spctl）"
# 容错仅信息输出：ad-hoc 签名 + 未公证，预期被拒绝（rejected）；此步不阻断打包。
spctl -a -vv "$APP_PATH" || true

echo "==> 4/5 打包 zip（ditto，zip 根 = Cellar.app/）"
mkdir -p dist
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> 5/5 产物清单"
ls -lh "$ZIP_PATH"
ls -ld "$APP_PATH"
echo "完成：$ZIP_PATH"