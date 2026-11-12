#!/bin/bash
# 只改页面（HTML/CSS/JS）时用这个：重新打包 → 直接替换 app 里那三个文件 → 重启。
# 不重新编译、不重新签名 → 已授的日历/提醒事项/完全磁盘访问都不会丢。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/浮窗待办.app"
RES="$APP/Contents/Resources"

[ -d "$APP" ] || { echo "还没装过：先跑 ./build.sh"; exit 1; }

"$ROOT/tools/bundle.sh"
cp "$ROOT/build/Resources/index.html" "$RES/index.html"
cp "$ROOT/build/Resources/styles.css" "$RES/styles.css"
cp "$ROOT/build/Resources/app.js" "$RES/app.js"

pkill -f "浮窗待办.app/Contents/MacOS/DeskTodo" 2>/dev/null || true
sleep 1
open -a "$APP"
echo "已热替换并重启（未重编译，权限保留）"
