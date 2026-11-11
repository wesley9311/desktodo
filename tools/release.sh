#!/bin/bash
# 发版前预检。**不 push、不打 tag、不发 Release** —— 这些动作只给命令，由维护者执行。
#
# 用法：
#   ./tools/release.sh              只跑预检（不构建产物）
#   ./tools/release.sh --full       预检 + 出 universal dmg
#   ./tools/release.sh --print-commands   打印后续远端动作命令
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

FULL=0
PRINT=0
for arg in "$@"; do
  case "$arg" in
    --full) FULL=1 ;;
    --print-commands) PRINT=1 ;;
    *) echo "未知参数：${arg}（可用：--full / --print-commands）" >&2; exit 2 ;;
  esac
done

FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
note() { printf '    %s\n' "$1"; }

VERSION="$(tr -d '[:space:]' < VERSION)"
echo "发版预检 · 版本 $VERSION"
echo

echo "[1] 工作区"
if [ -z "$(git status --porcelain)" ]; then
  ok "工作区干净"
else
  bad "工作区有未提交改动（发版前必须干净）"
  git status --porcelain | while IFS= read -r l; do note "$l"; done
fi

echo
echo "[2] 四同步"
PLIST_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' src/Info.plist 2>/dev/null || echo '')"
if [ "$VERSION" = "$PLIST_VER" ]; then ok "VERSION = Info.plist（${VERSION}）"; else bad "VERSION=${VERSION}，Info.plist=$PLIST_VER"; fi
if grep -q "^## $VERSION " CHANGELOG.md 2>/dev/null; then ok "CHANGELOG 有 $VERSION 条目"; else bad "CHANGELOG 最新条目不是 $VERSION"; fi
TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  if [ "$(git rev-list -n1 "$TAG")" = "$(git rev-parse HEAD)" ]; then
    ok "tag $TAG 指向 HEAD"
  else
    bad "tag $TAG 不指向 HEAD"
  fi
else
  note "尚未打 tag（发布前：git tag ${TAG}）"
fi

echo
echo "[3] 措辞扫描（不得出现当前版本以外的 0.x.y 版本号）"
EXTRA="$(git grep -hoE '0\.[0-9]+\.[0-9]+' -- '*.md' '*.sh' '*.yml' '*.swift' '*.js' '*.txt' 2>/dev/null \
  | grep -vx "$VERSION" | sort -u || true)"
if [ -z "$EXTRA" ]; then
  ok "没有其他 0.x.y 版本号"
else
  bad "发现不在许可范围内的版本号字面量："
  echo "$EXTRA" | while IFS= read -r l; do note "$l"; done
fi

echo
echo "[4] 闸门"
if ./tools/docs-check.sh >/tmp/release-docs.log 2>&1; then ok "文档数字一致"; else bad "文档数字不一致（见 /tmp/release-docs.log）"; fi
if ./tools/audit.sh >/tmp/release-audit.log 2>&1; then ok "边界审计通过"; else bad "边界审计失败（见 /tmp/release-audit.log）"; fi
if ./tools/bundle.sh >/tmp/release-bundle.log 2>&1 && node tools/check.js >/tmp/release-check.log 2>&1; then
  ok "行为断言通过（$(grep -oE 'PASS [0-9]+' /tmp/release-check.log | awk '{s+=$2} END{print s}') 条）"
else
  bad "行为断言失败（见 /tmp/release-check.log）"
fi

if [ "$FULL" = "1" ]; then
  echo
  echo "[5] 完整打包（universal dmg）"
  if ./tools/package.sh >/tmp/release-package.log 2>&1; then ok "打包完成"; else bad "打包失败（见 /tmp/release-package.log）"; fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m预检通过。注意：本脚本没有 push、没有打 tag。\033[0m\n'
else
  printf '\033[31m预检失败 %d 项。\033[0m\n' "$FAIL"
fi

if [ "$PRINT" = "1" ]; then
  cat <<EOM

后续远端动作（需你手动执行，本脚本不代做）：
  git push origin main
  git tag $TAG
  git push origin $TAG
  # 旧 Release 降级为 Pre-release（不删改）：
  for t in \$(git tag --sort=-v:refname | tail -n +2); do gh release edit "\$t" --prerelease; done
  # 新版本发布后设 latest：
  gh release edit v$VERSION --latest
EOM
fi

exit "$FAIL"
