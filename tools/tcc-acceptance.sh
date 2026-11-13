#!/bin/bash
# DeskTodo 真机 TCC 验收取证脚本 —— 只允许在隔离 macOS VM / 专用测试 Mac 里运行。
# 禁止在本机（有真实 DeskTodo 安装与真实账本的机器）运行：会安装/覆盖 /Applications/DeskTodo.app。
#
# 用法（在 VM 内）：
#   ./tools/tcc-acceptance.sh --i-am-in-vm --dmg /path/DeskTodo-0.1.1-universal-local.dmg \
#       [--evidence-dir ~/DeskTodo-TCC-evidence]
#
# 产出（全部原始证据）：
#   00-host.txt              系统/硬件/是否已有旧安装
#   01-artifact.txt          dmg sha256、版本、构建号、Bundle ID、签名、hardened runtime、entitlements、spctl
#   02-install.txt           安装到 /Applications 的过程与结果
#   03-launch.txt            首次启动、进程、窗口状态
#   04-tcc-log.txt           tccd 原始日志（日历/提醒）
#   05-eventkit-log.txt      应用内 cal/rem 授权与读取结果日志
#   06-restart.txt           退出 + 重新启动结果
#   07-ledger.txt            仅在 VM 内：数据目录文件清单（不含内容）
set -uo pipefail

EXPECTED_SHA="${EXPECTED_SHA:-}"
DMG=""
EVID=""
VM_OK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --i-am-in-vm) VM_OK=1; shift ;;
    --dmg) DMG="${2:-}"; shift 2 ;;
    --evidence-dir) EVID="${2:-}"; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

if [ "$VM_OK" != "1" ]; then
  cat >&2 <<'MSG'
!! 拒绝运行：这是"隔离 Mac / VM 真机 TCC 验收"脚本。
   它会安装并启动 /Applications/DeskTodo.app，必须在没有真实数据的主机外环境执行。
   确认是隔离 VM 后，显式加 --i-am-in-vm 再跑。
MSG
  exit 2
fi

if [ -d /Applications/DeskTodo.app ] && [ -z "${ALLOW_OVERWRITE:-}" ]; then
  echo "!! /Applications/DeskTodo.app 已存在。隔离环境里也请先确认它不是真实安装；" >&2
  echo "   确认可覆盖后设 ALLOW_OVERWRITE=1 再跑。" >&2
  exit 2
fi

[ -n "$DMG" ] && [ -f "$DMG" ] || { echo "!! 需要 --dmg <0.1.1 dmg>" >&2; exit 2; }
EVID="${EVID:-$HOME/DeskTodo-TCC-evidence-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$EVID"
MNT="$(mktemp -d /tmp/dt-tcc-mnt.XXXXXX)"
cleanup() { hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

say() { printf '%s\n' "$*" | tee -a "$EVID/00-run.txt" >/dev/null; }
echo "证据目录：$EVID"

# 00 host
{
  echo "== 时间 =="; date -u +%Y-%m-%dT%H:%M:%SZ; date
  echo "== 系统 =="; sw_vers; uname -a
  echo "== 硬件 =="; system_profiler SPHardwareDataType 2>/dev/null | grep -E "Model Name|Model Identifier|Chip|Memory" | head -6
  echo "== 现有安装（隔离环境应为空）=="; ls -ld /Applications/DeskTodo.app 2>&1 || true
  echo "== 现有真实数据目录（隔离环境应为空）=="; ls -la "$HOME/Library/Application Support/DeskTodo" 2>&1 || true
} > "$EVID/00-host.txt" 2>&1

# 01 artifact
hdiutil attach "$DMG" -nobrowse -mountpoint "$MNT" -quiet || { echo "!! dmg 挂载失败" >&2; exit 1; }
APP="$MNT/DeskTodo.app"
{
  echo "== dmg =="; shasum -a 256 "$DMG"
  echo "== 期望 sha256 =="; echo "${EXPECTED_SHA:-（未提供 EXPECTED_SHA）}"
  echo "== 版本/构建号/BundleID =="
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null
  echo "== 签名 =="; codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Identifier|Format|CodeDirectory|Signature|TeamIdentifier|Runtime Version|flags"
  echo "== hardened runtime =="; codesign -d --verbose=2 "$APP" 2>&1 | grep -i "runtime" || echo "（未显示 runtime 标志）"
  echo "== entitlements =="; codesign -d --entitlements :- "$APP" 2>&1
  echo "== spctl（ad-hoc 预期 rejected）=="; spctl -a -vv "$APP" 2>&1 || true
  echo "== 架构/最低系统 =="; lipo -info "$APP/Contents/MacOS/DeskTodo" 2>&1; vtool -show-build "$APP/Contents/MacOS/DeskTodo" 2>/dev/null | grep minos
} > "$EVID/01-artifact.txt" 2>&1

if [ -n "$EXPECTED_SHA" ]; then
  ACTUAL_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    echo "!! sha256 不一致：$ACTUAL_SHA != $EXPECTED_SHA" | tee -a "$EVID/01-artifact.txt"
    exit 1
  fi
  echo "sha256 一致：$ACTUAL_SHA" >> "$EVID/01-artifact.txt"
fi

# 02 install
{
  echo "== 安装到 /Applications =="
  rm -rf /Applications/DeskTodo.app
  cp -R "$APP" /Applications/DeskTodo.app
  codesign --verify --strict --verbose=2 /Applications/DeskTodo.app 2>&1
  echo "安装完成：$?"
} > "$EVID/02-install.txt" 2>&1

# 03 launch
{
  echo "== 启动 =="
  open -a /Applications/DeskTodo.app
  sleep 8
  pgrep -fl "DeskTodo.app/Contents/MacOS/DeskTodo"
  echo "== 前台/窗口（辅助）=="
  osascript -e 'tell application "System Events" to get name of every process whose name contains "DeskTodo"' 2>&1 || true
} > "$EVID/03-launch.txt" 2>&1

# 04 TCC raw log（关键：授权弹窗/拒绝原因）
{
  echo "== tccd 日志（最近 10 分钟，DeskTodo 相关）=="
  log show --last 10m --predicate 'process == "tccd" AND (eventMessage CONTAINS[c] "deskTodo" OR eventMessage CONTAINS[c] "kTCCServiceCalendar" OR eventMessage CONTAINS[c] "kTCCServiceReminders")' 2>&1 | tail -200
} > "$EVID/04-tcc-log.txt" 2>&1

# 05 EventKit 结果（应用日志里 ext cal= / ext rem=）
{
  echo "== 应用日志（授权与读取结果）=="
  LOG="$HOME/Library/Application Support/DeskTodo/logs/desktodo.log"
  ls -l "$LOG" 2>&1 || true
  grep -E "ext cal=|ext rem=|requestAccess" "$LOG" 2>/dev/null | tail -40 || true
} > "$EVID/05-eventkit-log.txt" 2>&1

# 06 restart
{
  echo "== 退出 =="
  osascript -e 'tell application "DeskTodo" to quit' 2>/dev/null || pkill -f "DeskTodo.app/Contents/MacOS/DeskTodo" || true
  sleep 3
  pgrep -fl "DeskTodo.app/Contents/MacOS/DeskTodo" && echo "!! 进程仍在" || echo "已退出"
  echo "== 重新启动 =="
  open -a /Applications/DeskTodo.app
  sleep 6
  pgrep -fl "DeskTodo.app/Contents/MacOS/DeskTodo" && echo "重启成功" || echo "!! 重启失败"
} > "$EVID/06-restart.txt" 2>&1

# 07 ledger presence only（不读内容）
{
  echo "== 数据目录（只列文件，不输出内容）=="
  ls -la "$HOME/Library/Application Support/DeskTodo" 2>&1 || true
  ls -la "$HOME/Library/Application Support/DeskTodo/backups" 2>&1 || true
} > "$EVID/07-ledger.txt" 2>&1

echo "DONE 证据已写入：$EVID"
ls -1 "$EVID"
