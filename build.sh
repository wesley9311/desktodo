#!/bin/bash
# 构建 + 自检 + 安装。前端只改 HTML/CSS/JS 时不要跑这个，用 tools/hot.sh（不重签，权限不丢）。
#
# 三条硬规矩（以前都是"靠人记得"，现在写进脚本）：
#   1. 数据层自检不过 → 不安装（宁可这次白编，也不装一个会丢账的包）；
#   2. 找不到本机固定证书 → 默认**失败**，不静默降级成 ad-hoc。
#      ad-hoc 每次重编 cdhash 都变，等于每次更新都把日历/提醒/磁盘授权清一次；
#      确实要临时用，显式传 --adhoc。
#   3. 装之前先把正在跑的旧进程停掉，不然更新完就是两个实例同时写一份数据。
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

ALLOW_ADHOC=0
for arg in "$@"; do
  case "$arg" in
    --adhoc) ALLOW_ADHOC=1 ;;
    --skip-selftest) SKIP_SELFTEST=1 ;;
    *) echo "未知参数：${arg}（可用：--adhoc / --skip-selftest）"; exit 2 ;;
  esac
done

echo "==> 边界审计（不过就不编译）"
"$ROOT/tools/audit.sh"

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

# 自检必须在签名/安装之前：它只跑数据层，不碰真实数据（DESKTODO_TEST_HOME 指向临时目录）。
if [ "${SKIP_SELFTEST:-0}" != "1" ]; then
  echo "==> 数据层自检（构建闸门）"
  TMPHOME="$(mktemp -d)"
  if ! DESKTODO_TEST_HOME="$TMPHOME" "$APP/Contents/MacOS/$BIN_NAME" --selftest; then
    echo "!! 数据层自检没通过，这次不安装（--skip-selftest 可以跳过，但不建议）"
    rm -rf "$TMPHOME"
    exit 1
  fi
  rm -rf "$TMPHOME"
fi

echo "==> 签名"
# 自签证书不会被系统信任，所以不能用 -v（-v 只列受信任的身份）；
# 签名本身不需要受信任，只需要私钥在钥匙串里。
PASSFILE="$HOME/.desktodo-signing-pass"
if [ -f "$PASSFILE" ] && [ -f "$SIGN_KEYCHAIN" ]; then
  security unlock-keychain -p "$(cat "$PASSFILE")" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
fi
SIGNED=""
if security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --deep --sign "$SIGN_ID" --keychain "$SIGN_KEYCHAIN" "$APP" >/dev/null
  SIGNED="self"
  echo "    用固定证书签名（重建不掉权限）"
elif [ "$ALLOW_ADHOC" = "1" ]; then
  codesign --force --deep --sign - "$APP" >/dev/null
  SIGNED="adhoc"
  echo "    ad-hoc 签名（--adhoc 显式要求）"
  echo "    !! cdhash 每次重建都变 → 日历/提醒/完全磁盘访问会被系统清零，需要重新授权"
else
  echo "!! 找不到固定证书「$SIGN_ID」（钥匙串：$SIGN_KEYCHAIN）"
  echo "   先跑 tools/mkcert.sh 生成；确实要临时用 ad-hoc，传 --adhoc（会丢权限）"
  exit 1
fi

echo "==> 校验签名"
codesign --verify --deep --strict "$APP"
echo "    签名校验通过（${SIGNED}）"

echo "==> 停掉正在跑的旧版本（避免更新后两个实例同时写一份数据）"
if pgrep -f "$DEST/Contents/MacOS/$BIN_NAME" >/dev/null 2>&1; then
  pkill -f "$DEST/Contents/MacOS/$BIN_NAME" || true
  sleep 1
fi

echo "==> 安装到 ~/Applications"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo "==> 完成：$DEST"
echo "    打开：open \"$DEST\""
