#!/bin/bash
# 构建 + 安装。前端只改 HTML/CSS/JS 时不要跑这个，用 tools/hot.sh（不重签，权限不丢）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
BUILD="$ROOT/build"
APP="$BUILD/浮窗待办.app"
DEST="$HOME/Applications/浮窗待办.app"
BIN_NAME="DeskTodo"
# 固定身份的本地自签证书（tools/mkcert.sh 生成）。存在就用它签，cdhash 才稳定，
# TCC（日历/提醒事项/完全磁盘访问）不会每次重建都清零。
SIGN_ID="DeskTodo Local Signing"
SIGN_KEYCHAIN="$HOME/Library/Keychains/desktodo-signing.keychain-db"

echo "==> 清理"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 打包前端"
"$ROOT/tools/bundle.sh"
cp "$BUILD/Resources/index.html" "$APP/Contents/Resources/index.html"
cp "$BUILD/Resources/styles.css" "$APP/Contents/Resources/styles.css"
cp "$BUILD/Resources/app.js" "$APP/Contents/Resources/app.js"

echo "==> 编译 Swift"
swiftc -O -whole-module-optimization \
  -target "$(uname -m)-apple-macos12.0" \
  -o "$BUILD/$BIN_NAME" \
  "$SRC"/*.swift \
  -framework Cocoa -framework WebKit -framework EventKit

echo "==> 组装 App Bundle"
cp "$BUILD/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 签名"
# 自签证书不会被系统信任，所以不能用 -v（-v 只列受信任的身份）；
# 签名本身不需要受信任，只需要私钥在钥匙串里。
PASSFILE="$HOME/.desktodo-signing-pass"
if [ -f "$PASSFILE" ] && [ -f "$SIGN_KEYCHAIN" ]; then
  security unlock-keychain -p "$(cat "$PASSFILE")" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
fi
if security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --deep --sign "$SIGN_ID" --keychain "$SIGN_KEYCHAIN" "$APP" >/dev/null
  echo "    用固定证书签名（重建不掉权限）"
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
    && echo "    ad-hoc 签名（cdhash 每次变 → 权限会被系统清零）" \
    || echo "    ad-hoc 签名失败，忽略（仍可运行）"
fi

echo "==> 安装到 ~/Applications"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo "==> 完成：$DEST"
