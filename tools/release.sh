#!/bin/bash
# 发版前预检。**不 push、不打 tag、不发 Release** —— 这些动作只给命令，由维护者执行。
#
# 用法：
#   ./tools/release.sh                只跑预检（当前分支/当前状态）
#   ./tools/release.sh --full         预检 + 出正式发行物（要求 tag == HEAD）
#   ./tools/release.sh --print-commands  打印后续远端动作命令（不执行）
#
# 发布后 main 的复验：tag 允许是 HEAD 的祖先，不再误判为失败。
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
TAG="v$VERSION"

# tag 构建 → tag 模式；main/本地 → main 模式（tag 作为祖先即可）
if [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
  VMODE="tag"
elif [ "${GITHUB_REF_TYPE:-}" = "branch" ]; then
  VMODE="main"
elif git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1 \
  && [ "$(git rev-list -n1 "$TAG")" = "$(git rev-parse HEAD)" ]; then
  VMODE="tag"
elif git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1 \
  && git merge-base --is-ancestor "$TAG" HEAD 2>/dev/null; then
  VMODE="main"
else
  VMODE="local"   # 打 tag 之前的预检：允许没有 tag，构建号仍需递增
fi

echo "发版预检 · 版本 $VERSION · 检查模式 $VMODE"
echo

echo "[1] 工作区"
if [ -z "$(git status --porcelain)" ]; then
  ok "工作区干净"
else
  bad "工作区有未提交改动（发版前必须干净）"
  git status --porcelain | while IFS= read -r l; do note "$l"; done
fi

echo
echo "[2] 版本治理（版本号 / 构建号 / schema / tag / 历史引用 / latest）"
if ./tools/version-check.sh --mode "$VMODE" >/tmp/release-version.log 2>&1; then
  sed 's/^/  /' /tmp/release-version.log
  ok "版本治理检查通过"
else
  sed 's/^/  /' /tmp/release-version.log
  bad "版本治理检查失败（见上）"
fi

echo
echo "[3] 闸门"
if ./tools/docs-check.sh >/tmp/release-docs.log 2>&1; then ok "文档数字一致"; else bad "文档数字不一致（见 /tmp/release-docs.log）"; fi
if ./tools/audit.sh >/tmp/release-audit.log 2>&1; then ok "边界审计通过"; else bad "边界审计失败（见 /tmp/release-audit.log）"; fi
if ./tools/bundle.sh >/tmp/release-bundle.log 2>&1 && node tools/check.js >/tmp/release-check.log 2>&1; then
  ok "行为断言通过（$(grep -oE 'PASS [0-9]+' /tmp/release-check.log | awk '{s+=$2} END{print s}') 条）"
else
  bad "行为断言失败（见 /tmp/release-check.log）"
fi

if [ "$FULL" = "1" ]; then
  echo
  echo "[4] 正式发行物（--channel release，要求 tag == HEAD）"
  if ./tools/package.sh --channel release >/tmp/release-package.log 2>&1; then
    ok "打包完成"
  else
    bad "打包失败（见 /tmp/release-package.log）"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m预检通过。注意：本脚本没有 push、没有打 tag。\033[0m\n'
else
  printf '\033[31m预检失败 %d 项。\033[0m\n' "$FAIL"
fi

if [ "$PRINT" = "1" ]; then
  CORE="${VERSION%%-*}"
  MAJOR="${CORE%%.*}"
  SUFFIX=""
  case "$VERSION" in *-*) SUFFIX="${VERSION#*-}" ;; esac
  cat <<EOM

后续远端动作（需你手动执行，本脚本不代做）：
  git push origin main
EOM
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "  # tag $TAG 已存在：不要重建、不要移动；main 上的复验不需要再推 tag"
  else
    echo "  git tag -a $TAG -m \"DeskTodo $VERSION\""
    echo "  git push origin $TAG"
  fi
  if [ "$MAJOR" -ge 1 ] && [ -z "$SUFFIX" ]; then
    echo "  # 正式版发布后："
    echo "  gh release edit $TAG --latest"
  else
    echo "  # 0.x / 预发布：不要执行 gh release edit --latest"
    echo "  # （GitHub 会返回 422：Latest release cannot be draft or prerelease）"
  fi
fi

exit "$FAIL"
