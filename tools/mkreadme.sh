#!/bin/bash
# 把 docs/MANUAL.md 转成 dmg 里的 Read Me.txt（纯文本，ASCII 文件名）。
# 同源：只有 MANUAL 一份内容，dmg 里的读我由它生成，不手工维护第二份。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
MANUAL="$ROOT/docs/MANUAL.md"
[ -f "$MANUAL" ] || { echo "缺少 $MANUAL" >&2; exit 1; }

echo "DeskTodo $VERSION · Read Me"
echo "================================"
echo
sed -E \
  -e 's/^#{1,6} //' \
  -e 's/\[([^]]*)\]\([^)]*\)/\1/g' \
  -e 's/\*\*//g' \
  -e 's/`//g' \
  -e 's/^\| ?//' \
  -e 's/ ?\| ?/  /g' \
  "$MANUAL" | sed -E 's/^[[:space:]]+$//'
