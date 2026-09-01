#!/usr/bin/env bash
#
# make-icons.sh — Cellar 图标生产管线（幂等；无网络 / 无 brew 依赖）
#
# 用途：从单一 SVG 设计源生成 App 图标与菜单栏图标的全部 PNG 资产及其
# Contents.json，并做 icns 校验。
#
# 输入（与本脚本同目录）：
#   cellar-icon.svg     App 图标彩色设计源（窖灯）
#   menubar-icon.svg    菜单栏单色设计源（template 渲染）
#
# 输出：
#   ../CellarApp/Resources/Assets.xcassets/AppIcon.appiconset/
#       10 尺寸 PNG（16/32/64/128/256/512/1024 及 @2x 命名）+ Contents.json
#   ../CellarApp/Resources/Assets.xcassets/MenuBarIcon.imageset/
#       16@1x / 32@2x PNG + Contents.json
#
# 渲染策略：
#   主路径 qlmanage -t（QuickLook/WebKit 管线，支持 SVG filter 与透明度）；
#   任一尺寸输出缺失或像素尺寸不符时，单文件切换备选 WebKit 渲染器
#   render-svg.swift（WKWebView takeSnapshot，零外部依赖）。
# 1024 原生渲染一次后 sips 降采样 512/256/128；16/32/64 单独原生渲染，
# 避免 64 倍降采样糊化小尺寸弧段。
# icns 由 iconutil 生成到临时目录仅作校验，不落仓库（appiconset PNG 为准源）。
#
# 用法：bash App/Tools/make-icons.sh
# 依赖：qlmanage / sips / iconutil / swift（macOS 系统自带）
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLOR_SVG="$SCRIPT_DIR/cellar-icon.svg"
MENUBAR_SVG="$SCRIPT_DIR/menubar-icon.svg"
RENDERER="$SCRIPT_DIR/render-svg.swift"
ASSETS_DIR="$SCRIPT_DIR/../CellarApp/Resources/Assets.xcassets"
APPICON_DIR="$ASSETS_DIR/AppIcon.appiconset"
MENUBAR_DIR="$ASSETS_DIR/MenuBarIcon.imageset"

for f in "$COLOR_SVG" "$MENUBAR_SVG"; do
    [[ -f "$f" ]] || { echo "make-icons.sh: 缺少输入 $f" >&2; exit 1; }
done

# verify_png <png> <size>：像素尺寸精确 + 四角透明（0=合格，1/2=不合格）。
verify_png() {
    swift "$RENDERER" verify "$1" "$2" >/dev/null 2>&1
}

# render_png <svg> <out.png> <size>：主路径 qlmanage；尺寸不符或角部不透明
# （QuickLook 会给 SVG 垫白底）时切备选 WebKit 渲染器。
render_png() {
    local src="$1" out="$2" size="$3" tmp probe
    tmp="$(mktemp -d)"
    if qlmanage -t -s "$size" -o "$tmp" "$src" >/dev/null 2>&1; then
        probe="$tmp/$(basename "$src").png"
        if [[ -s "$probe" ]] && verify_png "$probe" "$size"; then
            cp "$probe" "$out"
            rm -rf "$tmp"
            return 0
        fi
    fi
    rm -rf "$tmp"
    echo "make-icons.sh: qlmanage 输出不合格（尺寸或透明背景），改用 WebKit 渲染器 ($src @ ${size}px)" >&2
    swift "$RENDERER" render "$src" "$out" "$size"
    verify_png "$out" "$size" || {
        echo "make-icons.sh: WebKit 渲染仍不合格: $out" >&2
        return 1
    }
}

# downscale <in.png> <out.png> <size>：sips 等比缩到方尺寸。
downscale() {
    sips -z "$3" "$3" "$1" --out "$2" >/dev/null
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> 渲染彩色 1024 原图"
render_png "$COLOR_SVG" "$work/1024.png" 1024

echo "==> 降采样 512/256/128"
downscale "$work/1024.png" "$work/512.png" 512
downscale "$work/1024.png" "$work/256.png" 256
downscale "$work/1024.png" "$work/128.png" 128

echo "==> 原生渲染 64/32/16（避免降采样糊化弧段）"
render_png "$COLOR_SVG" "$work/64.png" 64
render_png "$COLOR_SVG" "$work/32.png" 32
render_png "$COLOR_SVG" "$work/16.png" 16

mkdir -p "$APPICON_DIR"
cp "$work/16.png"   "$APPICON_DIR/icon_16x16.png"
cp "$work/32.png"   "$APPICON_DIR/icon_16x16@2x.png"
cp "$work/32.png"   "$APPICON_DIR/icon_32x32.png"
cp "$work/64.png"   "$APPICON_DIR/icon_32x32@2x.png"
cp "$work/128.png"  "$APPICON_DIR/icon_128x128.png"
cp "$work/256.png"  "$APPICON_DIR/icon_128x128@2x.png"
cp "$work/256.png"  "$APPICON_DIR/icon_256x256.png"
cp "$work/512.png"  "$APPICON_DIR/icon_256x256@2x.png"
cp "$work/512.png"  "$APPICON_DIR/icon_512x512.png"
cp "$work/1024.png" "$APPICON_DIR/icon_512x512@2x.png"

echo "==> 渲染菜单栏图标（64 原生 → 16@1x / 32@2x）"
render_png "$MENUBAR_SVG" "$work/mb-64.png" 64
downscale "$work/mb-64.png" "$work/mb-32.png" 32
downscale "$work/mb-64.png" "$work/mb-16.png" 16
mkdir -p "$MENUBAR_DIR"
cp "$work/mb-16.png" "$MENUBAR_DIR/MenuBarIcon-16.png"
cp "$work/mb-32.png" "$MENUBAR_DIR/MenuBarIcon-32.png"

cat > "$ASSETS_DIR/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

cat > "$APPICON_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

cat > "$MENUBAR_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "MenuBarIcon-16.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "MenuBarIcon-32.png", "idiom" : "universal", "scale" : "2x" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}
JSON

echo "==> icns 校验（临时目录，不落仓库）"
# 挂在 $work 的 EXIT trap 下，iconutil 失败中止时也随之清理。
icns_tmp="$work/icns"
# iconutil 只接受 .iconset 命名的目录（.appiconset + Contents.json 会被拒绝），
# 故复制 PNG 到临时 .iconset 目录做校验；仓库内的 appiconset 仍为准源。
mkdir -p "$icns_tmp/Cellar.iconset"
cp "$APPICON_DIR"/icon_*.png "$icns_tmp/Cellar.iconset/"
iconutil -c icns "$icns_tmp/Cellar.iconset" -o "$icns_tmp/Cellar.icns"

echo "==> 完成：App 图标 10 尺寸 + 菜单栏 16@1x/32@2x，icns 校验通过"