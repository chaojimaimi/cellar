#!/bin/bash
# Cellar 发布打包脚本（Phase 2 WP6 §2.5；v1.4 起附带 dmg）。
#
# 流程：Release 构建（xcodebuild → App/.release-build/）→ codesign 深度校验 →
# spctl 评估（容错，ad-hoc 签名预期 rejected，仅信息输出）→ ditto 打 zip +
# hdiutil 打 dmg（拖拽安装布局，v0.9.0 首次附带）至 dist/ → 产物清单。
# 幂等：每次执行重新构建并覆盖旧产物。
set -euo pipefail

# 仓库根（脚本位于仓库根 Tools/，与 m0 脚本同层）。
cd "$(dirname "$0")/.."

# 版本号单变量：zip/dmg 文件名由此派生；发布时与 App/CLI/daemon 版本串保持一致。
VERSION=0.9.0-alpha

PROJECT="App/CellarApp.xcodeproj"
SCHEME="CellarApp"
DERIVED_DATA="App/.release-build"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Cellar.app"
ZIP_PATH="dist/Cellar-v${VERSION}.zip"
DMG_PATH="dist/Cellar-v${VERSION}.dmg"

echo "==> 1/6 Release 构建（xcodebuild）"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release -derivedDataPath "$DERIVED_DATA" build

echo "==> 2/6 签名校验（codesign -v，深度）"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> 3/6 Gatekeeper 评估（spctl）"
# 容错仅信息输出：ad-hoc 签名 + 未公证，预期被拒绝（rejected）；此步不阻断打包。
spctl -a -vv "$APP_PATH" || true

echo "==> 4/6 打包 zip（ditto，zip 根 = Cellar.app/）"
mkdir -p dist
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> 5/6 打包 dmg（hdiutil 压缩只读，拖拽安装布局）"
# staging 布局：Cellar.app + /Applications 符号链接（访达拖拽安装惯例）；
# UDZO = 只读压缩，系统工具零第三方依赖。
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP_PATH" "$STAGING/Cellar.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "Cellar v${VERSION}" -srcfolder "$STAGING" \
    -ov -format UDZO "$DMG_PATH" > /dev/null

echo "==> 6/6 产物清单与 SHA-256 校验和"
ls -lh "$ZIP_PATH" "$DMG_PATH"
ls -ld "$APP_PATH"
shasum -a 256 "$ZIP_PATH" "$DMG_PATH"
echo "完成：$ZIP_PATH + $DMG_PATH"
