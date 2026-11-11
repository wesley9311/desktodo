#!/bin/bash
# 产物完整性矩阵。对同一份产物在三个来源各跑一遍：本地构建 / CI 构建 / 下载回验。
# 第 9 项（Gatekeeper）对 ad-hoc 签名会返回拒绝，这是预期；照实记录，不做美化。
#
# 用法：
#   ./tools/integrity.sh --app build/pkg/DeskTodo.app
#   ./tools/integrity.sh --dmg dist/DeskTodo-<版本>-universal.dmg --sums dist/SHA256SUMS.txt
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP=""
DMG=""
SUMS=""
SOURCE="local"
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --dmg) DMG="$2"; shift 2 ;;
    --sums) SUMS="$2"; shift 2 ;;
    --source) SOURCE="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
if [ -z "$APP" ] && [ -z "$DMG" ]; then
  echo "用法：--app <path> 或 --dmg <path>（可加 --sums、--source）" >&2
  exit 2
fi

FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '    %s\n' "$1"; }

MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then
    hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
    rmdir "$MOUNT" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "完整性矩阵 · 来源：$SOURCE"

if [ -n "$DMG" ]; then
  [ -f "$DMG" ] || { bad "dmg 不存在：$DMG"; exit 1; }
  MOUNT="$(mktemp -d /tmp/dt-mount.XXXXXX)"
  echo "[7] dmg 可挂载"
  if hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null 2>&1; then
    ok "hdiutil attach 成功"
  else
    bad "hdiutil attach 失败"
    exit 1
  fi
  APP="$(find "$MOUNT" -maxdepth 2 -name '*.app' -type d | head -1)"
  if [ -z "$APP" ]; then bad "挂载卷里没有 .app"; exit 1; fi
fi

[ -d "$APP" ] || { bad "app 不存在：$APP"; exit 1; }
BIN="$APP/Contents/MacOS/DeskTodo"
[ -f "$BIN" ] || { bad "可执行文件不存在：$BIN"; exit 1; }

echo "[1] 签名有效"
if codesign --verify --strict --verbose=2 "$APP" >/tmp/ic-codesign.log 2>&1; then
  ok "codesign --verify 通过"
else
  bad "codesign --verify 失败（见 /tmp/ic-codesign.log）"
fi

echo "[2] 双切片"
ARCHS="$(lipo -info "$BIN" 2>/dev/null || true)"
case "$ARCHS" in
  *x86_64*arm64*|*arm64*x86_64*) ok "$ARCHS" ;;
  *) bad "不是 universal：$ARCHS" ;;
esac

echo "[3] 最低系统"
MINOS="$(vtool -show-build "$BIN" 2>/dev/null | awk '/minos/{print $2; exit}')"
if [ "$MINOS" = "12.0" ]; then ok "minos 12.0"; else bad "minos=${MINOS}（期望 12.0）"; fi

echo "[4] 无第三方链接"
BADLIB="$(otool -L "$BIN" 2>/dev/null | awk 'NR>1{print $1}' | grep -vE '^(/System/|/usr/lib/)' || true)"
if [ -z "$BADLIB" ]; then ok "只链接系统库"; else bad "存在非系统链接"; echo "$BADLIB" | while IFS= read -r l; do info "$l"; done; fi

echo "[5] 无路径泄漏"
NUSER="$(strings -a "$BIN" 2>/dev/null | grep -c '/Users/' || true)"
if [ "$NUSER" = "0" ]; then ok "strings 里 /Users/ 为 0"; else bad "strings 里出现 $NUSER 处 /Users/"; fi

echo "[6] 哈希"
if [ -n "$SUMS" ] && [ -f "$SUMS" ]; then
  BASE="$(basename "$DMG")"
  EXPECT="$(awk -v f="$BASE" '$2==f{print $1}' "$SUMS")"
  ACTUAL="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  if [ -n "$EXPECT" ] && [ "$EXPECT" = "$ACTUAL" ]; then ok "sha256 与 SHA256SUMS.txt 一致"; else bad "sha256 不一致（期望 ${EXPECT:-无}，实际 ${ACTUAL}）"; fi
else
  info "跳过：未提供 --sums"
fi

echo "[8] 挂载后 app 仍有效"
if [ -n "$MOUNT" ]; then
  if codesign --verify --strict --verbose=2 "$APP" >/dev/null 2>&1; then ok "挂载卷内 app 签名有效"; else bad "挂载卷内 app 签名无效"; fi
else
  info "跳过：本次输入是 app 目录，不是 dmg"
fi

echo "[9] Gatekeeper 门禁（ad-hoc 预期被拒）"
SPCTL="$(spctl -a -vv "$APP" 2>&1 || true)"
info "$SPCTL"
info "未公证 → 拒绝是预期；用户首次需在「系统设置 → 隐私与安全性」手动允许。"

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m完整性检查通过（第 9 项按实际记录，不计入失败）\033[0m\n'
else
  printf '\033[31m完整性检查失败 %d 项\033[0m\n' "$FAIL"
fi
exit "$FAIL"
