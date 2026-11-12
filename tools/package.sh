#!/bin/bash
# 打 universal 分发包：两次 swiftc → lipo → 组装 → 自检 → 由内向外签名 → dmg → sha256。
# 不碰 ~/Applications，不 push、不打 tag。CI 与本机共用这一条路径。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP_NAME="DeskTodo"
BIN="DeskTodo"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
PLIST_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Info.plist" 2>/dev/null || echo '')"
if [ "$VERSION" != "$PLIST_VER" ]; then
  echo "版本不一致：VERSION=${VERSION}，Info.plist=$PLIST_VER" >&2
  exit 1
fi

APP="$BUILD/pkg/$APP_NAME.app"
STAGE="$BUILD/dmg"
OUT="$DIST/$APP_NAME-$VERSION-universal.dmg"

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
SIGN_OPTS=(--force --sign -)
if [ "${NO_HARDENED:-0}" != "1" ]; then SIGN_OPTS=(--force --options runtime --sign -); fi
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

echo "==> 完成：$OUT"
echo "    注意：未公证，spctl 会拒绝；用户首次需要在系统设置里手动允许。"
