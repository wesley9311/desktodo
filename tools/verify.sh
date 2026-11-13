#!/bin/bash
# 一键验证。给维护者与体验官用：一条命令跑完所有能自动运行的闸门。
# 用法：./tools/verify.sh [--artifact <dmg>]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
note() { printf '    %s\n' "$1"; }
ARTIFACT=""
[ "${1:-}" = "--artifact" ] && ARTIFACT="${2:-}"

echo "==> [1/9] 边界审计"
if ./tools/audit.sh >/tmp/v-audit.log 2>&1; then ok "8 类 16 项"; else bad "见 /tmp/v-audit.log"; fi

echo "==> [2/9] 行为断言"
if ./tools/bundle.sh >/tmp/v-bundle.log 2>&1 && node tools/check.js >/tmp/v-check.log 2>&1; then
  ok "断言 $(grep -oE 'PASS [0-9]+' /tmp/v-check.log | awk '{s+=$2} END{print s}') 条"
else
  bad "见 /tmp/v-check.log"
fi

echo "==> [3/9] 文档数字"
if ./tools/docs-check.sh >/tmp/v-docs.log 2>&1; then ok "文档与实测一致"; else bad "见 /tmp/v-docs.log"; fi

echo "==> [4/9] 数据层自检"
mkdir -p build
swiftc -DDEBUG -O -whole-module-optimization -target "$(uname -m)-apple-macos12.0" \
  -o build/DeskTodo-debug src/*.swift -framework Cocoa -framework WebKit -framework EventKit 2>/tmp/v-build.log
if [ $? -eq 0 ]; then
  H=$(mktemp -d)
  if DESKTODO_TEST_HOME="$H" ./build/DeskTodo-debug --selftest >/tmp/v-selftest.log 2>&1; then
    ok "自检 $(grep -c '^PASS' /tmp/v-selftest.log) 项"
  else
    bad "自检失败（见 /tmp/v-selftest.log）"
  fi
  rm -rf "$H"
else
  bad "编译失败（见 /tmp/v-build.log）"
fi

echo "==> [5/9] 夹具金标"
if [ -x build/DeskTodo-debug ]; then
  D=0
  for f in tools/fixtures/expected/*.json; do
    N="$(basename "$f" .json)"
    H=$(mktemp -d)
    DESKTODO_TEST_HOME="$H" ./build/DeskTodo-debug --fixture "$N" > /tmp/v-fx.json 2>/dev/null
    rm -rf "$H"
    if ! diff -q "$f" /tmp/v-fx.json >/dev/null; then bad "夹具 $N 与金标不一致"; D=$((D+1)); fi
  done
  [ "$D" = "0" ] && ok "10 组夹具与金标一致"
else
  bad "缺少 build/DeskTodo-debug"
fi

echo "==> [6/9] 对抗审查（可自动化部分）"
if DT_DEBUG_BIN="$PWD/build/DeskTodo-debug" ./tools/adversarial.sh >/tmp/v-adv.log 2>&1; then
  ok "未发现失败（MANUAL/CI 项见日志）"
else
  bad "见 /tmp/v-adv.log"
fi
if ./tools/tcc-fixtures-test.sh >/tmp/v-tcc.log 2>&1; then
  ok "TCC 日志解析/阶段判定/截图核验夹具 47 项"
else
  bad "TCC 夹具失败（见 /tmp/v-tcc.log）"
fi

echo "==> [7/9] 产物完整性"
if [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ]; then
  if ./tools/integrity.sh --dmg "$ARTIFACT" --sums dist/SHA256SUMS.txt --source local >/tmp/v-int.log 2>&1; then
    ok "9 项矩阵通过（第 9 项照实记录）"
  else
    bad "见 /tmp/v-int.log"
  fi
else
  note "跳过：未给 --artifact <dmg>"
fi

echo "==> [8/9] Git 对抗性审查"
if ./tools/git-audit.sh >/tmp/v-git.log 2>&1; then ok "提交/标签/数据边界"; else bad "见 /tmp/v-git.log"; fi

echo "==> [9/9] 版本治理"
if ./tools/version-check.sh --mode auto >/tmp/v-version.log 2>&1; then ok "版本/构建号/schema/历史引用"; else bad "见 /tmp/v-version.log"; fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m验证通过（可自动化项）\033[0m\n'
else
  printf '\033[31m验证失败 %d 项\033[0m\n' "$FAIL"
fi
exit "$FAIL"
