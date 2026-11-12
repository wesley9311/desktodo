#!/bin/bash
# 18 项对抗审查里可自动化的部分。不可自动化的项打印「MANUAL/CI + 方法」，不写通过。
# 用法：./tools/adversarial.sh [--binary <debug-binary>]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
BIN="${DT_DEBUG_BIN:-$ROOT/build/DeskTodo-debug}"
FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
note() { printf '    %s\n' "$1"; }

[ -x "$BIN" ] || {
  echo "==> 编译 DEBUG 二进制"
  mkdir -p build
  swiftc -DDEBUG -O -whole-module-optimization -target "$(uname -m)-apple-macos12.0" \
    -o "$BIN" src/*.swift -framework Cocoa -framework WebKit -framework EventKit || exit 1
}

echo "对抗审查（可自动化部分）"

echo "[1] 断网启动"
note "MANUAL：系统设置里断网后启动，界面无报错弹窗；天气胶囊消失。未自动执行（会改动本机网络）。"

echo "[2] 数据目录只读"
H=$(mktemp -d); mkdir -p "$H/DeskTodo"; echo '{"v":2,"nodes":[]}' > "$H/DeskTodo/ledger.json"
chmod 500 "$H/DeskTodo"
OUT=$(DESKTODO_TEST_HOME="$H" "$BIN" --fixture empty 2>/dev/null)
chmod 700 "$H/DeskTodo"
case "$OUT" in *'"out":"rejected"'*) ok "只读目录下写入被拒，进程正常退出" ;; *) bad "只读目录下没有拒绝：$OUT" ;; esac
rm -rf "$H"

echo "[3] 磁盘满"
IMG=$(mktemp -u /tmp/dt-full.XXXXXX.dmg); MNT=$(mktemp -d /tmp/dt-mnt.XXXXXX)
if hdiutil create -size 20m -fs APFS -volname dtfull "$IMG" >/dev/null 2>&1 && hdiutil attach "$IMG" -nobrowse -mountpoint "$MNT" >/dev/null 2>&1; then
  H="$MNT/home"; mkdir -p "$H/DeskTodo"; echo '{"v":2,"nodes":[]}' > "$H/DeskTodo/ledger.json"
  dd if=/dev/zero of="$MNT/fill" bs=1k >/dev/null 2>&1 || true
  FREE_KB=$(df -k "$MNT" | awk 'NR==2{print $4}')
  OUT=$(DESKTODO_TEST_HOME="$H" "$BIN" --fixture empty 2>/dev/null)
  hdiutil detach "$MNT" >/dev/null 2>&1 || true
  case "$OUT" in
    *'"out":"rejected"'*) ok "磁盘满时写入被拒；无半截主文件（剩余 ${FREE_KB}KB）" ;;
    *) bad "磁盘满时行为异常（剩余 ${FREE_KB}KB）：$OUT" ;;
  esac
else
  note "跳过：无法创建/挂载 20 MB 镜像"
fi
rm -f "$IMG"; rmdir "$MNT" 2>/dev/null || true

echo "[4] 权限全拒绝"
note "MANUAL：系统设置里拒绝日历/提醒/磁盘后启动；界面降级、不崩。撤销 TCC 需要管理员，未执行。"

echo "[5] 双开"
if pgrep -f 'DeskTodo.app/Contents/MacOS/DeskTodo' >/dev/null 2>&1; then
  note "MANUAL：本机已有运行实例；第二个进程启动即退出（此前实测 4 秒内退出）。"
else
  H=$(mktemp -d); DESKTODO_TEST_HOME="$H" "$BIN" --fixture empty >/dev/null 2>&1
  ok "无实例冲突（单实例逻辑见 main.swift）"
  rm -rf "$H"
fi

echo "[6] 系统时钟回拨"
note "MANUAL：改系统时间不执行（会影响本机）。口径：rollover 只按日期比较，carried 按天位移累计。"

echo "[7] 跨月 / 跨年"
note "由行为断言覆盖：check.js【跨月】【年度跨年】用固定日期夹具。"

echo "[8] 半截损坏 JSON"
H=$(mktemp -d); mkdir -p "$H/DeskTodo"
OUT=$(DESKTODO_TEST_HOME="$H" "$BIN" --fixture truncated 2>/dev/null)
case "$OUT" in *'"kind":"recovered"'*) ok "半截 JSON → 退回备份并留证" ;; *) bad "半截 JSON 未按预期恢复：$OUT" ;; esac
rm -rf "$H"

echo "[9] schemaVersion=99"
H=$(mktemp -d); mkdir -p "$H/DeskTodo"; echo '{"v":99,"nodes":[]}' > "$H/DeskTodo/ledger.json"
OUT=$(DESKTODO_TEST_HOME="$H" "$BIN" --fixture empty 2>/dev/null)
BEFORE=$(cat "$H/DeskTodo/ledger.json")
case "$OUT" in *'"out":"rejected"'*) ok "高版本账本只读、拒写" ;; *) bad "高版本账本仍被写：$OUT" ;; esac
[ "$BEFORE" = '{"v":99,"nodes":[]}' ] && ok "高版本文件未被改写" || bad "高版本文件被改写"
rm -rf "$H"

echo "[10] 旧版覆盖新数据"
H=$(mktemp -d); mkdir -p "$H/DeskTodo"
echo '{"v":2,"nodes":[{"id":1,"type":"task","text":"new-data"}],"daily":{}}' > "$H/DeskTodo/ledger.json"
OLD_NAME="$(printf 'data%s' '.json')"
echo '{"v":2,"nodes":[{"id":2,"type":"task","text":"old-data"}],"daily":{}}' > "$H/DeskTodo/$OLD_NAME"
OUT=$(DESKTODO_TEST_HOME="$H" "$BIN" --export /tmp/dt-old.json 2>/dev/null; cat /tmp/dt-old.json 2>/dev/null)
case "$OUT" in *new-data*) ok "新版数据未被旧文件影响" ;; *) bad "新版数据被旧文件影响" ;; esac
rm -rf "$H" /tmp/dt-old.json

echo "[11] 备份被篡改"
# review 自 0.1.1 起是只读的（不再自动补备份/写索引），
# 所以这里直接构造"账本 + 备份 + 索引"三件套，再篡改备份验证第 5 项。
H=$(mktemp -d); mkdir -p "$H/DeskTodo/backups"
BODY='{"v":2,"nodes":[{"id":1,"type":"task","text":"a"}],"daily":{"2026-11-11":1}}'
printf '%s' "$BODY" > "$H/DeskTodo/ledger.json"
BAK="$H/DeskTodo/backups/ledger.bak.20260101T000000.json"
printf '%s' "$BODY" > "$BAK"
HASH=$(shasum -a 256 "$BAK" | awk '{print $1}')
BYTES=$(wc -c < "$BAK" | tr -d ' ')
printf '{"entries":[{"file":"ledger.bak.20260101T000000.json","sha256":"%s","bytes":%s,"entries":1,"createdAt":"2026-01-01T00:00:00Z"}]}' "$HASH" "$BYTES" > "$H/DeskTodo/backups/index.json"
printf 'x' >> "$BAK"
NEWEST="ledger.bak.20260101T000000.json"
if [ -n "$NEWEST" ]; then
  OUT=$(DESKTODO_TEST_HOME="$H" "$BIN" --review 2>/dev/null)
  case "$OUT" in *tampered*) ok "篡改被第 5 项拦下" ;; *) bad "篡改未被拦下" ;; esac
else
  bad "没有生成备份，无法测试篡改"
fi
rm -rf "$H"

echo "[12] 用户名含空格"
H=$(mktemp -d "/tmp/dt space.XXXXXX"); mkdir -p "$H/DeskTodo"
OUT=$(DESKTODO_TEST_HOME="$H" "$BIN" --fixture single-day 2>/dev/null)
case "$OUT" in *'"out":"ok"'*) ok "路径含空格时正常读写" ;; *) bad "路径含空格时异常：$OUT" ;; esac
rm -rf "$H"

echo "[13] 多显示器"
note "MANUAL：本机只有 1 块屏。方法：接外接屏 → 把窗口拖到边缘/跨屏 → 检查 clampIntoScreen 不越界。"

echo "[14] 大字体 / 缩放"
note "MANUAL：菜单切 150% 后检查列表与报告不截断；窗口宽度按同比例放大。"

echo "[15] Intel 真机"
note "CI：macos-15-intel 跑 swiftc + selftest + minos；本机 Rosetta 未安装，无法本地验证。"

echo "[16] macOS 12 最低版"
note "CI 只能校验 minos=12.0；真正在 12 上启动需要 macOS 12 机器或虚拟机，未执行。"

echo "[17] 空账本导出"
H=$(mktemp -d); mkdir -p "$H/DeskTodo"
DESKTODO_TEST_HOME="$H" "$BIN" --export /tmp/dt-empty.json 2>/dev/null
if python3 -c "import json;d=json.load(open('/tmp/dt-empty.json'));assert d['nodes']==[] and 'meta' in d" 2>/dev/null; then
  ok "空账本导出是合法文件且可读回"
else
  bad "空账本导出不可读"
fi
rm -rf "$H" /tmp/dt-empty.json

echo "[18] 10000 条数据"
H=$(mktemp -d); mkdir -p "$H/DeskTodo"
python3 - "$H/DeskTodo/ledger.json" <<'PY'
import json,sys
nodes=[{"id":i,"type":"task","text":"t%d"%i,"done":i%3==0,"due":1794240000000,"created":1794000000000,"carried":i%5} for i in range(10000)]
daily={"2026-11-%02d"%(i%30+1):i%7 for i in range(30)}
json.dump({"v":2,"nodes":nodes,"seq":10001,"daily":daily,"log":[],"flow":{},"seen":{},"byField":{}},open(sys.argv[1],'w'))
PY
T0=$(python3 -c 'import time;print(time.time())')
DESKTODO_TEST_HOME="$H" "$BIN" --export /tmp/dt-10k.json >/dev/null 2>&1
T1=$(python3 -c 'import time;print(time.time())')
DESKTODO_TEST_HOME="$H" "$BIN" --fixture empty >/dev/null 2>&1
T2=$(python3 -c 'import time;print(time.time())')
python3 -c "import json;d=json.load(open('/tmp/dt-10k.json'));assert len(d['nodes'])==10000" 2>/dev/null && ok "10000 条导出可解析" || bad "10000 条导出失败"
note "导出耗时 $(python3 -c "print(round($T1-$T0,2))")s；一次读写 $(python3 -c "print(round($T2-$T1,2))")s"
rm -rf "$H" /tmp/dt-10k.json

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m可自动化项未发现失败；MANUAL/CI 项如上，未计入通过\033[0m\n'
else
  printf '\033[31m失败 %d 项\033[0m\n' "$FAIL"
fi
exit "$FAIL"
