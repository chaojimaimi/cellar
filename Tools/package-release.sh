#!/bin/bash
# Cellar 发布打包脚本（Phase 2 WP6 §2.5；v1.4 起附带 dmg）。
#
# 流程：SPM release 同步重建（CLI + daemon，含版本一致性断言）→ Release 构建
# （xcodebuild → App/.release-build/）→ codesign 深度校验 → spctl 评估（容错，
# ad-hoc 签名预期 rejected，仅信息输出）→ ditto 打 zip + hdiutil 打 dmg（拖拽
# 安装布局，v0.9.0 首次附带）至 dist/ → 产物清单。
# 幂等：每次执行重新构建并覆盖旧产物。
set -euo pipefail

# 仓库根（脚本位于仓库根 Tools/，与 m0 脚本同层）。
cd "$(dirname "$0")/.."

# 版本号单变量：zip/dmg 文件名由此派生；发布时与 App/CLI/daemon 版本串保持一致。
VERSION=0.21.0-alpha

PROJECT="App/CellarApp.xcodeproj"
SCHEME="CellarApp"
DERIVED_DATA="App/.release-build"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Cellar.app"
ZIP_PATH="dist/Cellar-v${VERSION}.zip"
DMG_PATH="dist/Cellar-v${VERSION}.dmg"

echo "==> 1/7 SPM release 同步重建（CLI + daemon）"
# xcodebuild 只经 App 的脚本相重建 daemon，CLI 会静默停在上一版——0.18.6 与
# 0.19.3 两次踩坑：install 的版本核对拿 CLI 自身常量当期望值，半旧 CLI 会把它
# 误报成「stale daemon？」，且异常级联成「daemon 启动校验失败」。此处统一重建
# 两个 SPM 产物并断言版本串，把偏斜挡在打包之前。
swift build -c release
for product in cellar cellar-daemon; do
    if ! grep -aqF -- "$VERSION" ".build/release/$product"; then
        echo "❌ .build/release/$product 版本串不含 ${VERSION}（半旧构建）——中止打包"
        exit 1
    fi
done

echo "==> 2/7 Release 构建（xcodebuild）"
# CFBundleVersion 派生（0.19.8 起）：数值 = major×10000 + minor×100 + patch
# （0.19.8 → 1908，随发版自动递增）。背景：CFBundleVersion 恒 "2" 使 BTM 按
# bundle id+version 无法区分新旧 bundle——macOS 27 升级回放了远古 App 托管注册
# 抢占守护进程标签（幽灵 daemon 事故促成因子）。约束 minor<100（0.100.0 会与
# 1.0.0 撞号——现实版本域内成立）。
CF_BUNDLE_VERSION=$(echo "$VERSION" | sed 's/-.*//' | awk -F. '{ print $1*10000 + $2*100 + $3 }')
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CF_BUNDLE_VERSION" App/CellarApp/Info.plist
echo "CFBundleVersion → $CF_BUNDLE_VERSION"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release -derivedDataPath "$DERIVED_DATA" build

# App 版本串断言（最后一个偏斜面：Info.plist 是唯一随 zip/dmg 分发的版本）。
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")
if [ "$APP_VERSION" != "$VERSION" ]; then
    echo "❌ App 版本 ${APP_VERSION} ≠ ${VERSION}——中止打包"
    exit 1
fi
# CFBundleVersion 构建后断言（镜像 APP_VERSION 先例——只写不验等于没写）。
APP_BUILD=$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")
if [ "$APP_BUILD" != "$CF_BUNDLE_VERSION" ]; then
    echo "❌ App CFBundleVersion ${APP_BUILD} ≠ ${CF_BUNDLE_VERSION}——中止打包"
    exit 1
fi

echo "==> 3/7 签名校验（codesign -v，深度）"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> 4/7 Gatekeeper 评估（spctl）"
# 容错仅信息输出：ad-hoc 签名 + 未公证，预期被拒绝（rejected）；此步不阻断打包。
spctl -a -vv "$APP_PATH" || true

echo "==> 5/7 打包 zip（ditto，zip 根 = Cellar.app/）"
mkdir -p dist
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> 6/7 打包 dmg（diskutil image create from 压缩只读，拖拽安装布局）"
# staging 布局：Cellar.app + /Applications 符号链接（访达拖拽安装惯例）；
# UDZO = 只读压缩，系统工具零第三方依赖。
# 0.20.2 §4：hdiutil create 弃用警告迁移 macOS 27 真实命令 diskutil image create
# from（spike 实证：folder 源保留 bundle 结构与 /Applications 符号链接，产物
# hdiutil attach 挂载验证通过；UDZO 同格式）。
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP_PATH" "$STAGING/Cellar.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG_PATH"
diskutil image create from --format UDZO --volname "Cellar v${VERSION}" \
    "$STAGING" "$DMG_PATH" > /dev/null   # stderr 放行（R3-P2：失败根因可见；弃用告警不在 stderr）

# 产物可挂载验证（0.20.2 §4 门禁：迁移后 dmg 必须可挂载且拖拽布局完整——失败即
# 打包失败，防坏产物流出）。attach 走 diskutil image attach（hdiutil attach 同为
# 弃用面）；detach 无 diskutil 等价子命令，保留 hdiutil detach（非弃用告警面）。
VERIFY_MNT="$(mktemp -d)"
if ! diskutil image attach --readOnly --nobrowse --mountPoint "$VERIFY_MNT" "$DMG_PATH" > /dev/null; then
    echo "❌ dmg 挂载验证失败（diskutil image 迁移产物不可挂载）——中止打包" >&2
    rm -rf "$VERIFY_MNT"
    exit 1
fi
if [ ! -d "$VERIFY_MNT/Cellar.app" ] || [ ! -L "$VERIFY_MNT/Applications" ]; then
    echo "❌ dmg 内容验证失败（Cellar.app / Applications 链接缺席）——中止打包" >&2
    hdiutil detach "$VERIFY_MNT" -quiet || true
    rm -rf "$VERIFY_MNT"
    exit 1
fi
hdiutil detach "$VERIFY_MNT" -quiet > /dev/null
rm -rf "$VERIFY_MNT"
echo "dmg 挂载验证通过（Cellar.app + Applications 拖拽布局）"

echo "==> 7/7 产物清单与 SHA-256 校验和"
ls -lh "$ZIP_PATH" "$DMG_PATH"
ls -ld "$APP_PATH"
shasum -a 256 "$ZIP_PATH" "$DMG_PATH"
echo "完成：$ZIP_PATH + $DMG_PATH"
