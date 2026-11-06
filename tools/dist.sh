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
OUTDIR="$ROOT/dist"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Info.plist")"
# 顶层套一个文件夹：解压后必定是一坨完整的，不会四个文件散在"下载"里。
# 名字带版本号，用户手里同时有两版时能分清哪个是新的。
PKGNAME="$APPNAME-$VERSION"
PKG="$STAGE/$PKGNAME"
APP="$PKG/$APPNAME.app"
# 文件名用 ASCII：GitHub 上传附件时会把中文名整个换成连字符，
# 变成 "-.-<版本>.zip" 这种谁也不敢下的东西。zip 里面的文件名照旧是中文。
ZIP="$OUTDIR/DeskTodo-$VERSION.zip"

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
# 设计原则：任何一步失败都要停下来把话说清楚。
# 用 set -e 的话，一出错 Terminal 窗口一闪就关，用户只看到"它闪了一下"，
# 这是最容易让人放弃的失败方式——比报错本身更糟。
cat > "$PKG/安装.command" <<'EOS'
#!/bin/bash
# 双击前请先：右键 →「打开」。第一次一定会被系统拦一次，右键打开就绕过这一层。
#
# 这个脚本只做一件事：把同目录的 app 拷进 ~/Applications，然后打开它。
# 你的记录不在这里，所以反复安装、换版本都不会动它。

cd "$(dirname "$0")" || { echo "进不去脚本所在的文件夹"; read -n 1 -s; exit 1; }

APPNAME="浮窗待办"
SRC="$APPNAME.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/$SRC"

# 失败时停住。Terminal 的默认设置是"正常退出就关窗"，
# 所以出错后必须停在这里，否则用户只会看到窗口闪一下。
die() {
  echo
  echo "✗ $1"
  [ -n "${2:-}" ] && echo "  $2"
  echo
  echo "── 按任意键关闭这个窗口 ──"
  read -n 1 -s
  exit 1
}

echo
echo "  浮窗待办 · 安装"
echo "  ────────────────────"
echo

# 1) 源文件齐不齐。只解压了一半、或者被人单独挪走了，都在这里露出来。
[ -d "$SRC" ] || die "没找到「$SRC」" \
  "「安装.command」必须和「$SRC」待在同一个文件夹里。如果你把它单独拷出来了，请回到解压出来的文件夹里双击。"
[ -x "$SRC/Contents/MacOS/DeskTodo" ] || die "「$SRC」是残缺的" \
  "里面的程序文件不见了，多半是压缩包没解压完整。重新下载一次再试。"

# 2) 目标目录
mkdir -p "$DEST_DIR" 2>/dev/null || die "建不了 $DEST_DIR" \
  "你的用户目录可能没有写权限。可以在 Finder 里手动新建一个「应用程序」文件夹试试。"

# 3) 旧版本：先让它退出，不然替换会失败
if [ -d "$DEST" ]; then
  echo "  · 发现已装的版本，先退它（你的记录不会被碰）"
  osascript -e 'tell application "浮窗待办" to quit' >/dev/null 2>&1
  for _ in 1 2 3; do
    pgrep -x DeskTodo >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -x DeskTodo >/dev/null 2>&1
  sleep 1
  rm -rf "$DEST" 2>/dev/null || die "删不掉旧版本" \
    "请手动打开访达，到「个人文件夹 → 应用程序」，把「浮窗待办」拖进废纸篓，再运行一次这个脚本。"
fi

# 4) 拷过去
echo "  · 正在复制到 $DEST_DIR"
cp -R "$SRC" "$DEST" 2>/dev/null || die "复制失败" \
  "常见原因是磁盘空间不够，或者 ~/Applications 没有写权限。"

# 5) 摘掉"从网络下载"的隔离标记，否则第一次启动会被系统拦住
xattr -dr com.apple.quarantine "$DEST" >/dev/null 2>&1

# 6) 自检：装完的东西是不是真的能跑
[ -x "$DEST/Contents/MacOS/DeskTodo" ] || die "装完却找不到程序文件" \
  "这次复制没成功，请重新运行一次；还不行就换一种解压方式（用系统自带的「归档实用工具」）。"

if ! codesign --verify --deep --strict "$DEST" >/dev/null 2>&1; then
  echo "  · 签名校验没通过（这个版本没买苹果公证，通常不影响使用）"
fi

# 7) 打开
echo "  · 启动"
open "$DEST" 2>/dev/null || die "装好了，但打不开" \
  "去访达「个人文件夹 → 应用程序」里找到「浮窗待办」，按住 Control 点它 →「打开」，试一次。"

echo
echo "✓ 装好了。"
echo
echo "  它没有 Dock 图标。现在应该能看到："
echo "    · 屏幕右上角菜单栏，多了个小图标"
echo "    · 桌面右下角，有个小圆点"
echo
echo "  都没出现的话，再双击一次 ~/Applications/浮窗待办.app 就好。"
echo
echo "  你的记录存在 ~/Library/Application Support/DeskTodo/"
echo "  以后删掉 app、换新版本，记录都不会丢。"
echo
echo "── 按任意键关闭这个窗口 ──"
read -n 1 -s
EOS
chmod +x "$PKG/安装.command"

# ---- 读我 ----
cat > "$PKG/读我.txt" <<'EOT'
浮窗待办 · 体验版
=================

这是什么
--------
一个贴在桌面上的待办浮窗：常驻最上层，随手写、随手勾。
干完勾掉，年底能翻回来看这一年到底做了多少、哪天在做、哪天没有。

一句话原则：所有数据只在这台电脑上。没有账号、没有服务器、
没有任何上报——它连你打开过几次都不知道。


怎么装
------
你现在这个文件夹里有四样东西：

    浮窗待办.app      程序本身，别直接双击它
    安装.command      你要点的是这个
    读我.txt          就是这一份
    体验清单.md       用之前扫一眼，不用全看

【第 1 步】右键点「安装.command」→ 选「打开」→ 弹窗里再点一次「打开」

    为什么不让你直接双击？
    这个版本没买苹果的开发者认证（99 美元/年），系统看到"来路不明的
    程序"会拦一下——那是它在保护你，不是坏了。

    直接双击的话，弹窗里只有「移到废纸篓」和「取消」。
    看到那个别慌：点「取消」，然后照上面说的右键打开。
    只需要做这一次，以后不用再右键。

【第 2 步】等它跑完。它会自己装到「个人文件夹 → 应用程序」并打开。
    中途任何一步出问题，它都会停下来告诉你原因，不会一闪就没。

装完应该看到：
    · 屏幕右上角菜单栏，多了个小图标
    · 桌面右下角，有个小圆点（能拖动）
都没有的话：去「个人文件夹 → 应用程序」，双击「浮窗待办」。


第一次打开会被问两件事
----------------------
· 日历 / 提醒事项：点「允许」或「不允许」都行。
  允许了，它会读你日历里有没有会，只用来看"有会 vs 没会，
  干活差多少"。只读，绝不改你的日历。

· 完全磁盘访问：**可以不弄**。
  只用来读系统「屏幕使用时间」。不给，那一行就不显示，
  其它功能一点不受影响。


数据在哪
--------
    ~/Library/Application Support/DeskTodo/data.json

纯文本，任何编辑器都能打开，字段名是人话。

菜单「导出全部数据…」→ 一个 zip：原始 data.json + 一份人能读的说明。
菜单「清空全部数据…」→ 真的删干净，不进废纸篓、不留副本。


怎么更新
--------
下载新版本 → 解压 → 还是右键「安装.command」→ 打开。

它会自己退出旧版、替换、再打开。记录在 ~/Library 里，一个都不会少。


怎么卸载
--------
把「个人文件夹 → 应用程序 → 浮窗待办」拖进废纸篓就行。

记录不会跟着删。想彻底清干净：先打开它，菜单里「清空全部数据…」，
再删 app。


怎么反馈
--------
见 体验清单.md。最值钱的一条是：**这一周里哪一天你根本没打开它，为什么。**

菜单里「复制诊断信息」会复制一段纯计数和状态，不含任何任务内容，
直接粘给我就行。

EOT

# 版本号只有 Info.plist 一个来源，正文里不写死（写了就会过期）。
# 0.x 不是谦虚，是实情：还没有外人把它当日常工具用过。这句话要和使用者见面。
awk -v v="$VERSION" 'NR==2{print; print ""; print "版本 " v "｜0.x 的意思是：还没有外人连续用过它。请按测试版对待。"; next}1' \
  "$PKG/读我.txt" > "$PKG/读我.txt.new" && mv "$PKG/读我.txt.new" "$PKG/读我.txt"

# ---- 体验清单 ----
cat > "$PKG/体验清单.md" <<'EOT'
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
( cd "$STAGE" && ditto -c -k --keepParent --norsrc --noextattr "$PKGNAME" "$ZIP" )

SIZE=$(du -h "$ZIP" | cut -f1)
# 变量后面紧跟中文标点时必须写成 ${ZIP}：zsh 会把多字节字符当成变量名的一部分
echo "==> 完成：${ZIP}（${SIZE}）"
echo
echo "包里：$APPNAME.app · 安装.command · 读我.txt · 体验清单.md"
echo "签名：ad-hoc（没有开发者身份，所以对方第一次要右键打开）"
