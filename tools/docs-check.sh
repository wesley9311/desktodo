#!/bin/bash
# 文档数字校验：README / DEVELOPMENT 里写死的行数、文件数、断言数必须和实测一致。
#
# 为什么要有这个：上一版 README 把 3789 行写成 4700，DEVELOPMENT 又停在 3789，
# 而代码已经 3821 —— 同一件事三处数字，全不一样。数字写进文档就会过期，
# 唯一可靠的解决办法是让"过期"变成一次失败。
#
# 用法：./tools/docs-check.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

FAIL=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

SW_N=$(ls src/*.swift 2>/dev/null | wc -l | tr -d ' ')
SW_L=$(cat src/*.swift 2>/dev/null | wc -l | tr -d ' ')
JS_N=$(ls src/js/*.js 2>/dev/null | wc -l | tr -d ' ')
JS_L=$(cat src/js/*.js 2>/dev/null | wc -l | tr -d ' ')
CSS_L=$(wc -l < src/styles.css 2>/dev/null | tr -d ' ')
HTML_L=$(wc -l < src/index.html 2>/dev/null | tr -d ' ')

echo "文档数字校验"
echo "  实测：Swift ${SW_L} 行 / ${SW_N} 个文件 · JS ${JS_L} 行 / ${JS_N} 个分片 · CSS ${CSS_L} · HTML ${HTML_L}"

check() {
  local what="$1" pat="$2" file="$3"
  if grep -qE "$pat" "$file" 2>/dev/null; then
    pass "$what"
  else
    fail "${what}（${file} 里的数字与实测不一致）"
  fi
}

check "README：Swift 行数/文件数" "原生壳（${SW_L} 行 / ${SW_N} 个文件）" README.md
check "README：JS 行数/分片数" "页面（${JS_L} 行 / ${JS_N} 个分片）" README.md
check "README：CSS 行数" "样式（${CSS_L} 行）" README.md
check "DEVELOPMENT：Swift 行数/文件数" "原生壳 ${SW_N} 个文件 / ${SW_L} 行" docs/DEVELOPMENT.md
check "DEVELOPMENT：JS 行数/分片数" "页面 ${JS_N} 个分片 / ${JS_L} 行" docs/DEVELOPMENT.md
check "DEVELOPMENT：CSS 行数" "样式 ${CSS_L} 行" docs/DEVELOPMENT.md

# 断言数：check.js 跑完会写 build/Resources/assert-count.txt。
# 有就用它校验；没有（比如没装 Chrome）就跳过，不假装检查过。
if [ -f build/Resources/assert-count.txt ]; then
  A=$(tr -d '[:space:]' < build/Resources/assert-count.txt)
  if [ -n "$A" ]; then
    check "README：断言数" "${A} 条断言" README.md
    check "README：用例数不写成断言数——断言数是 ${A}" "${A} 条断言" README.md
    check "CONTRIBUTING：断言数" "${A} 条行为断言" CONTRIBUTING.md
    check "DEVELOPMENT：断言数" "${A} 条 / " docs/DEVELOPMENT.md
  fi
else
  echo "  · 跳过断言数校验（还没有 build/Resources/assert-count.txt；先跑 node tools/check.js）"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m文档数字一致\033[0m\n'
  exit 0
fi
printf '\033[31m文档数字有 %d 处过期 —— 改完再发版\033[0m\n' "$FAIL"
exit 1
