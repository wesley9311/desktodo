#!/bin/bash
# 打一个可以发给别人装的分发包。
#
# 和 build.sh 的区别只有一个，但很关键：
#   build.sh  用**本机的固定自签证书**签（私钥在这台机器的钥匙串里）——
#             换来"重建不掉 TCC 权限"，代价是只有这台机器认。
#   dist.sh   用 **ad-hoc 签名**（codesign -s -）——没有身份，谁都能跑，
#             代价是 Gatekeeper 会拦一次，得靠安装脚本去掉隔离属性。
#
# 私钥不外传：分发包永远不该带本机证书签名，那等于把签名身份送出去。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src"
STAGE="$ROOT/build/dist"
APPNAME="浮窗待办"
APP="$STAGE/$APPNAME.app"
OUTDIR="$ROOT/dist"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Info.plist")"
ZIP="$OUTDIR/$APPNAME-体验版-$VERSION.zip"

echo "==> 清理"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUTDIR"

echo "==> 打包前端"
"$ROOT/tools/bundle.sh"
cp "$ROOT/build/Resources/index.html" "$APP/Contents/Resources/index.html"
cp "$ROOT/build/Resources/styles.css" "$APP/Contents/Resources/styles.css"
cp "$ROOT/build/Resources/app.js" "$APP/Contents/Resources/app.js"

echo "==> 编译 Swift"
swiftc -O -whole-module-optimization \
  -target "$(uname -m)-apple-macos12.0" \
  -o "$ROOT/build/DeskTodo-dist" \
  "$SRC"/*.swift \
  -framework Cocoa -framework WebKit -framework EventKit

cp "$ROOT/build/DeskTodo-dist" "$APP/Contents/MacOS/DeskTodo"
# 编译产物不放 STAGE：那是要压缩的目录，多一个裸二进制别人会问"这是啥"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP" 2>&1 | sed 's/^/    /' || {
  echo "    ad-hoc 签名失败"; exit 1; }
codesign --verify --deep --strict "$APP" && echo "    校验通过"

# ---- 安装脚本 ----
cat > "$STAGE/安装.command" <<'EOS'
#!/bin/bash
# 双击前请先：右键 →「打开」。（第一次会被系统拦一次，右键打开就绕过这一层。
# 应用没有做苹果的开发者公证，原因写在 读我.txt 里。）
set -e
cd "$(dirname "$0")"
SRC_APP="浮窗待办.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/浮窗待办.app"

echo "正在安装到 $DEST"
mkdir -p "$DEST_DIR"

if [ -d "$DEST" ]; then
  echo "发现旧版本，先退出再替换（数据在 ~/Library/Application Support/DeskTodo，不会动）"
  osascript -e 'tell application "浮窗待办" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "$DEST"
fi

cp -R "$SRC_APP" "$DEST"
# 去掉"从网络下载"的隔离标记，否则第一次启动会被 Gatekeeper 拦住
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "装好了，正在打开。"
echo "如果窗口没出来，看屏幕右上角菜单栏——这个应用没有 Dock 图标。"
open "$DEST"

echo
echo "按任意键关闭这个窗口。"
read -n 1 -s
EOS
chmod +x "$STAGE/安装.command"

# ---- 读我 ----
cat > "$STAGE/读我.txt" <<'EOT'
浮窗待办 · 体验版
=================

这是什么
--------
一个放在桌面上的待办窗口：常驻在最上面，随手写、随手勾。
它还有一本账：每天勾掉几件，一年下来能画出你的"年轮"。

一句话原则：所有数据只在这台电脑上。没有账号、没有服务器、
没有任何上报——它连你打开过几次都不知道。


怎么装（两步）
--------------
1. 双击这个文件夹里的「安装.command」
   第一次会被系统拦住，改成：右键点它 →「打开」→ 再点「打开」
2. 装好后窗口会自己出来

如果窗口没出来：看屏幕右上角菜单栏，有个小图标。
这个应用故意没有 Dock 图标——它是个浮窗，不是正经窗口应用。


第一次打开会问你两件事
----------------------
· 日历 / 提醒事项：点「允许」或「不允许」都行。
  允许了，它会读你日历里有没有会，用来对照"这天有会 vs 没会，
  干活差多少"。只读，不改你的日历。

· 完全磁盘访问：**可以不弄**。
  这个权限只用来读系统「屏幕使用时间」。不给，那一行就不显示，
  其它功能一点不受影响。想弄的话在报告里点那行链接，会跳到设置页，
  把这个 app 拖进列表就行。


数据在哪
--------
~/Library/Application Support/DeskTodo/data.json

纯文本，用任何编辑器都能打开。
菜单里「导出全部数据…」会给你一个 zip：原始 data.json + 一份人能读的说明。
菜单里「清空全部数据…」是真的删干净——不进废纸篓、不留副本。


怎么反馈
--------
见 体验清单.md。核心三条：
  1. 哪里看不懂（这个最重要）
  2. 哪里数不对
  3. 什么时候你不想打开它

菜单里「复制诊断信息」会复制一段纯计数和状态，不含任何任务内容，
直接粘给我就行。
EOT

# ---- 体验清单 ----
cat > "$STAGE/体验清单.md" <<'EOT'
# 体验时请重点看这几件事

不用全部做完。挑你在意的看，看不下去的直接说，那本身就是结论。

## 1. 第一天：能不能不加思考地用起来

- 打开后，你知道该在哪里打字吗？（不需要读任何说明吗）
- 随手写三件今天要做的事，勾掉一件。发生了什么？你预期会发生什么？
- 窗口的高度、位置、遮挡，第一天就想调吗？还是忍了？

**只看一件事：第一次打开后的 30 秒内，有没有一次"这是干嘛的？"**

## 2. 数对不对（这条最值钱）

打开报告，逐个数字问自己一句："这个数，跟我真实的感受对得上吗？"

- 今日完成 / 待办
- 连续天数
- 30 天、半年、年轮三档
- 有会 / 没会的对照

如果某个数跟你感觉不一样，**先别管对错，记下当时的直觉**——
"我觉得这周做得比图上多"这种话比"可能是口径问题"有用一百倍。

## 3. 状态：它出错的时候，你知道发生了什么吗

- 断网（关掉 Wi-Fi）十分钟，它有什么变化？
- 退出再打开，清单还在吗？
- 把 `~/Library/Application Support/DeskTodo/data.json` 改成一段乱码，
  再打开——它会说什么？你怎么理解那句话？

**好的错误状态是：你不用查文档就知道下一步做什么。**

## 4. 反感点：什么时候你不想看见它

这条最容易被忽略，但它决定你会不会用超过一周：

- 它一直在最上面，什么时候让你烦？
- 有没有那句话/那个数字，让你觉得被评判了？
- 有没有哪一刻你想把它关掉、又有点舍不得？

## 5. 反馈怎么给我

菜单（右上角 ···）→「复制诊断信息」，粘贴过来。
那段文字只有计数和状态，**不含任何任务内容、日历标题、文件名**。

如果你愿意，再附上「导出全部数据…」生成的 zip——里面有你的真实数据，
只在你主动发的时候才离开你的电脑。不愿意发完全没问题，
上面那段诊断信息已经足够定位大部分问题了。
EOT

echo "==> 压缩"
rm -f "$ZIP"
( cd "$STAGE" && ditto -c -k --norsrc --noextattr . "$ZIP" )

SIZE=$(du -h "$ZIP" | cut -f1)
# 变量后面紧跟中文标点时必须写成 ${ZIP}：zsh 会把多字节字符当成变量名的一部分
echo "==> 完成：${ZIP}（${SIZE}）"
echo
echo "包里：$APPNAME.app · 安装.command · 读我.txt · 体验清单.md"
echo "签名：ad-hoc（没有开发者身份，所以对方第一次要右键打开）"
