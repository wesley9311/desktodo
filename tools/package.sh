#!/bin/bash
# 打包：两次 swiftc → lipo → 组装 → 自检 → 由内向外签名 → dmg → sha256 → build-info。
# 不碰 ~/Applications，不 push、不打 tag。CI 与本机共用这一条路径。
#
# 用法：./tools/package.sh [--channel local|release]
#   local（默认）：本机开发包，文件名带 -local，不上传 Release
#   release：正式发行物，要求 tag == HEAD 且工作区干净；由 CI 从 tag 调用
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP_NAME="DeskTodo"
BIN="DeskTodo"
CHANNEL="local"
while [ $# -gt 0 ]; do
  case "$1" in
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --channel=*) CHANNEL="${1#--channel=}"; shift ;;
    *) echo "未知参数：${1}（可用：--channel local|release）" >&2; exit 2 ;;
  esac
done
case "$CHANNEL" in local|release) ;; *) echo "channel 只能是 local 或 release" >&2; exit 2 ;; esac

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
CORE="${VERSION%%-*}"
PLIST_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Info.plist" 2>/dev/null || echo '')"
if [ "$CORE" != "$PLIST_VER" ]; then
  echo "版本不一致：VERSION 核心=${CORE}，Info.plist=$PLIST_VER" >&2
  exit 1
fi

SUFFIX="local"
[ "$CHANNEL" = "release" ] && SUFFIX=""
OUT="$DIST/$APP_NAME-$VERSION-universal${SUFFIX:+-$SUFFIX}.dmg"
APP="$BUILD/pkg/$APP_NAME.app"
STAGE="$BUILD/dmg"

if [ "$CHANNEL" = "release" ]; then
  if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "release 通道要求工作区干净（打包前请提交）" >&2
    exit 1
  fi
  if ! "$ROOT/tools/version-check.sh" --mode tag >/tmp/package-version.log 2>&1; then
    cat /tmp/package-version.log >&2
    echo "release 通道要求版本治理检查通过（tag == HEAD）" >&2
    exit 1
  fi
else
  if ! "$ROOT/tools/version-check.sh" --mode local >/tmp/package-version.log 2>&1; then
    cat /tmp/package-version.log >&2
    echo "本地包的版本治理检查失败" >&2
    exit 1
  fi
fi

echo "==> 前端"
"$ROOT/tools/bundle.sh"

mkdir -p "$BUILD" "$DIST"
rm -rf "$BUILD/pkg" "$STAGE"

echo "==> 编译 arm64"
swiftc -O -whole-module-optimization -target arm64-apple-macos12.0 \
  -o "$BUILD/$BIN-arm64" "$SRC"/*.swift \
  -framework Cocoa -framework WebKit -framework EventKit

echo "==> 编译 x86_64"
swiftc -O -whole-module-optimization -target x86_64-apple-macos12.0 \
  -o "$BUILD/$BIN-x86_64" "$SRC"/*.swift \
  -framework Cocoa -framework WebKit -framework EventKit

echo "==> lipo universal"
lipo -create "$BUILD/$BIN-arm64" "$BUILD/$BIN-x86_64" -output "$BUILD/$BIN-universal"
lipo -info "$BUILD/$BIN-universal"

echo "==> 组装"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$BIN-universal" "$APP/Contents/MacOS/$BIN"
cp "$BUILD/Resources/index.html" "$APP/Contents/Resources/index.html"
cp "$BUILD/Resources/styles.css" "$APP/Contents/Resources/styles.css"
cp "$BUILD/Resources/app.js" "$APP/Contents/Resources/app.js"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 数据层自检（构建闸门）"
TMPHOME="$(mktemp -d)"
if ! DESKTODO_TEST_HOME="$TMPHOME" "$APP/Contents/MacOS/$BIN" --selftest; then
  echo "!! 自检没通过，不打包" >&2
  rm -rf "$TMPHOME"
  exit 1
fi
rm -rf "$TMPHOME"

echo "==> 签名（由内向外，不用 --deep）"
# ad-hoc 签名（--sign -）的产物永远无法公证；这不是"暂时不公证"，是这条路走不到公证。
# hardened runtime 用 NO_HARDENED=1 可关闭（仅当实测发现它破坏 WKWebView 时使用）。
# 需要访问受保护资源时，在 src/DeskTodo.entitlements 提供 entitlement；有就自动带上。
SIGN_OPTS=(--force)
if [ "${NO_HARDENED:-0}" != "1" ]; then SIGN_OPTS+=(--options runtime); fi
if [ -f "$SRC/DeskTodo.entitlements" ]; then SIGN_OPTS+=(--entitlements "$SRC/DeskTodo.entitlements"); fi
SIGN_OPTS+=(--sign -)
if [ -d "$APP/Contents/Frameworks" ]; then
  for fw in "$APP/Contents/Frameworks/"*.framework; do
    [ -e "$fw" ] || continue
    codesign "${SIGN_OPTS[@]}" "$fw"
  done
fi
for b in "$APP/Contents/MacOS/"*; do
  [ -f "$b" ] || continue
  codesign "${SIGN_OPTS[@]}" "$b"
done
codesign "${SIGN_OPTS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> 校验 entitlements（P0-1：日历 / 提醒事项）"
[ -f "$SRC/DeskTodo.entitlements" ] || {
  echo "!! 缺少 src/DeskTodo.entitlements：hardened runtime 下日历/提醒授权会被系统直接拒绝" >&2
  exit 1
}
ENT="$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)"
for key in com.apple.security.personal-information.calendars com.apple.security.personal-information.reminders; do
  case "$ENT" in
    *"$key"*) ;;
    *) echo "!! 签名里缺少 entitlement：$key" >&2; exit 1 ;;
  esac
done
echo "    entitlements 含日历 + 提醒事项"

echo "==> 组装 dmg 目录"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -sfn /Applications "$STAGE/Applications"
"$ROOT/tools/mkreadme.sh" > "$STAGE/Read Me.txt"

echo "==> 生成 dmg（diskutil 主路径 / hdiutil 回落）"
rm -f "$OUT"
if diskutil image create from "$STAGE" --volumeName "$APP_NAME" --format UDZO "$OUT" >/dev/null 2>&1; then
  echo "    dmg via diskutil"
elif hdiutil create -srcfolder "$STAGE" -format UDZO -volname "$APP_NAME" "$OUT" >/dev/null; then
  echo "    dmg via hdiutil (fallback)"
else
  echo "!! 两条 dmg 路径都失败" >&2
  exit 1
fi

echo "==> sha256"
( cd "$DIST" && shasum -a 256 "$(basename "$OUT")" > SHA256SUMS.txt && cat SHA256SUMS.txt )

echo "==> build-info"
SCHEMA="$(grep -oE 'storeSchemaVersion = [0-9]+' "$SRC/Storage.swift" | grep -oE '[0-9]+$' | head -1)"
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
DIRTY="false"; [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ] && DIRTY="true"
TOOLCHAIN="$(swiftc --version 2>/dev/null | head -1 | tr '\n' ' ')"
CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$DIST/build-info.json" <<JSON
{
  "version": "$VERSION",
  "build": "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SRC/Info.plist")",
  "channel": "$CHANNEL",
  "commit": "$COMMIT",
  "dirty": $DIRTY,
  "toolchain": "$TOOLCHAIN",
  "schemaVersion": ${SCHEMA:-0},
  "createdAt": "$CREATED",
  "dmg": "$(basename "$OUT")"
}
JSON
cat "$DIST/build-info.json"

echo "==> 完成：$OUT"
if [ "$CHANNEL" = "release" ]; then
  echo "    正式发行物；CI 从 tag 构建，本机不直接上传。"
else
  echo "    本地开发包（-local），不得上传 Release。"
fi
