#!/bin/bash
# Cellar 发布打包脚本（Phase 2 WP6 §2.5；v1.4 起附带 dmg；0.23.3 起附带 appcast.xml）。
#
# 流程：tag 精确匹配断言（fail-fast）→ SPM release 同步重建（CLI + daemon，含版本
# 一致性断言）→ Release 构建（xcodebuild → App/.release-build/）→ codesign 深度
# 校验 → spctl 评估（容错，ad-hoc 签名预期 rejected，仅信息输出）→ ditto 打 zip +
# dmg（拖拽安装布局，v0.9.0 首次附带）至 dist/ → appcast 生成（Sparkle EdDSA 签名
# + 字段四件套自检，0.23.3 第 8 步）→ 产物清单。
# 幂等：每次执行重新构建并覆盖旧产物。
set -euo pipefail

# 仓库根（脚本位于仓库根 Tools/，与 m0 脚本同层）。
cd "$(dirname "$0")/.."

# 版本号单变量：zip/dmg 文件名由此派生；发布时与 App/CLI/daemon 版本串保持一致。
VERSION=0.23.3-alpha

PROJECT="App/CellarApp.xcodeproj"
SCHEME="CellarApp"
DERIVED_DATA="App/.release-build"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Cellar.app"
ZIP_PATH="dist/Cellar-v${VERSION}.zip"
DMG_PATH="dist/Cellar-v${VERSION}.dmg"
APPCAST_PATH="dist/appcast.xml"
# enclosure 固定 URL（0.23.3 §3.1——tag 资产 URL，latest/download 由 GitHub 302
# 解析到最新 release 自挂资产；appcast 内只写 tag 固定形态防「最新」漂移）。
REPO_SLUG="chaojimaimi/cellar"

# ── 0.23.3 §3.1 发布三断言之一（机制化·fail-fast 提到脚本头）：tag 精确匹配 ──
# --tags 必带：本库 tag 混有 lightweight（不带 --tags 只匹 annotated，恒红无意义）。
# 忘 bump VERSION = 全产物自称旧版 + enclosure 指旧 tag + Sparkle 永「已是最新」
# ——静默停更（红 5(b)）。此门必红，把停更挡在打包之前。
if ! git describe --exact-match --tags --match "v${VERSION}" HEAD >/dev/null 2>&1; then
    echo "❌ HEAD 无精确匹配 tag v${VERSION}（git describe --exact-match --tags）——忘 bump VERSION 或未打 tag，中止打包（防 appcast 静默停更）" >&2
    exit 1
fi
echo "==> 0/8 tag 断言通过：HEAD == v${VERSION}（--tags 精确匹配）"

echo "==> 1/8 SPM release 同步重建（CLI + daemon）"
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

echo "==> 2/8 Release 构建（xcodebuild）"
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

echo "==> 3/8 签名校验（codesign -v，深度）"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> 4/8 Gatekeeper 评估（spctl）"
# 容错仅信息输出：ad-hoc 签名 + 未公证，预期被拒绝（rejected）；此步不阻断打包。
spctl -a -vv "$APP_PATH" || true

echo "==> 5/8 打包 zip（ditto，zip 根 = Cellar.app/）"
mkdir -p dist
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> 6/8 打包 dmg（diskutil image create from 压缩只读，拖拽安装布局）"
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

# ── 0.23.3 §3.1 第 8 步（机制化）：appcast 生成 ──
# 独立函数封装（入参 zip/出参 appcast）——方案 §9 允许单独验证生成段（本地无
# tag 时 tag 断言必红，全脚本跑不完）；函数体 = 签名 → 解析纪律 → 生成 → 自检。
# 全局依赖：DERIVED_DATA / VERSION / CF_BUNDLE_VERSION / REPO_SLUG。
generate_appcast_xml() {
    local zip_path="$1" appcast_path="$2"
    # 工具路径解析：Sparkle 2.10.0 的 SPM binaryTarget 将 CLI 落
    # $DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin/（2026-10 实测）；
    # checkouts/Sparkle/bin/ 为方案钉的历史形态——两路探测，缺席 → set -e 中止
    #（无空 appcast 流出——红 2(a)）。
    local sign_update=""
    for candidate in \
        "$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
        "$DERIVED_DATA/SourcePackages/checkouts/Sparkle/bin/sign_update"; do
        if [ -x "$candidate" ]; then sign_update="$candidate"; break; fi
    done
    if [ -z "$sign_update" ]; then
        echo "❌ sign_update 缺席（$DERIVED_DATA/SourcePackages/{artifacts/sparkle/Sparkle,checkouts/Sparkle}/bin/ 均不在）——Sparkle 未 resolve 或 derivedDataPath 不符，中止" >&2
        exit 1
    fi
    # 签名 + 解析纪律（红 2(a) 硬化）：sparkle:edSignature= 行提取 + 非空断言。
    local sign_output sig length
    sign_output="$("$sign_update" "$zip_path")"
    sig="$(printf '%s\n' "$sign_output" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | head -n 1)"
    length="$(printf '%s\n' "$sign_output" | sed -n 's/.* length="\([0-9]*\)".*/\1/p' | head -n 1)"
    if [ -z "$sig" ]; then
        echo "❌ EdDSA 签名解析失败（sparkle:edSignature 为空）——中止，无 appcast 流出" >&2
        exit 1
    fi
    # 互验：sign_update 输出的 length 必须 == zip 实际字节数（stat -f %z）。
    local zip_size
    zip_size="$(stat -f %z "$zip_path")"
    if [ -z "$length" ] || [ "$length" != "$zip_size" ]; then
        echo "❌ length 互验失败（sign_update=${length:-缺席} vs stat -f %z=${zip_size}）——中止" >&2
        exit 1
    fi
    # 生成 appcast.xml——item 字段钉死全清单（红 5(d)）：sparkle:version =
    # CFBundleVersion（缺此字段 item 被 Sparkle 静默跳过——issue #848 实证）+
    # sparkle:shortVersionString = VERSION + sparkle:edSignature + **裸名 length**
    #（RSS 标准属性——勿加 sparkle: 前缀，缺则 Sparkle 读不到字节数）+
    # enclosure url（tag 固定 URL）+ minimumSystemVersion 26.0。
    local pub_date
    pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S GMT')"
    cat > "$appcast_path" <<EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Cellar</title>
        <link>https://github.com/${REPO_SLUG}</link>
        <description>Cellar release updates (EdDSA signed)</description>
        <language>en</language>
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${pub_date}</pubDate>
            <sparkle:version>${CF_BUNDLE_VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <minimumSystemVersion>26.0</minimumSystemVersion>
            <enclosure url="https://github.com/${REPO_SLUG}/releases/download/v${VERSION}/Cellar-v${VERSION}.zip" length="${zip_size}" type="application/octet-stream" sparkle:edSignature="${sig}"/>
        </item>
    </channel>
</rss>
EOF
    # 自检（字段四件套断言——逐项核对后才算过步；任一缺席 grep 非零 → set -e 中止）：
    # ① XML 良构（xmllint）②sparkle:version == CFBundleVersion ③sparkle:shortVersionString
    # ④sparkle:edSignature 非空 ⑤裸名 length == zip 字节数 ⑥minimumSystemVersion。
    xmllint --noout "$appcast_path"
    grep -q "<sparkle:version>${CF_BUNDLE_VERSION}</sparkle:version>" "$appcast_path"
    grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>" "$appcast_path"
    grep -q 'sparkle:edSignature="[^"]\+"' "$appcast_path"
    grep -q "length=\"${zip_size}\"" "$appcast_path"
    grep -q "<minimumSystemVersion>26.0</minimumSystemVersion>" "$appcast_path"
    echo "appcast 自检通过：xmllint 良构 + 字段四件套（version=${CF_BUNDLE_VERSION} / shortVersionString=${VERSION} / edSignature 非空 / length=${zip_size} 互验）"
}

echo "==> 7/8 appcast 生成（Sparkle EdDSA 签名 + 字段四件套自检）"
generate_appcast_xml "$ZIP_PATH" "$APPCAST_PATH"

echo "==> 8/8 产物清单与 SHA-256 校验和"
ls -lh "$ZIP_PATH" "$DMG_PATH" "$APPCAST_PATH"
ls -ld "$APP_PATH"
shasum -a 256 "$ZIP_PATH" "$DMG_PATH" "$APPCAST_PATH"
echo "完成：$ZIP_PATH + $DMG_PATH + $APPCAST_PATH（上传三件 + 发布后 curl 三断言——SMC-NOTES §11.18 发布纪律）"
