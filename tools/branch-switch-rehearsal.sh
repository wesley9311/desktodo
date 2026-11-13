#!/bin/bash
# 默认分支切换演练（只在 /tmp 里跑，不碰任何远端）。
# 目标：验证"推新名 + 删旧名"的两次更名不需要 force push，且 tag/历史不受影响；
#       并演示 allow_deletions=false 时删除会被拦，必须在获准后临时调整保护才能继续。
#
# 用法：./tools/branch-switch-rehearsal.sh [--legacy-repo <旧历史仓库路径>]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEGACY="${LEGACY_REPO:-$ROOT/../desk-todo}"
WORK="$(mktemp -d /tmp/dt-branch-sim.XXXXXX)"
BARE="$WORK/origin.git"
REPO="$WORK/work"
PASS=0; FAIL=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
cleanup() { cd /tmp 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

[ -d "$LEGACY/.git" ] || { echo "!! 旧历史仓库不存在：$LEGACY" >&2; exit 2; }
echo "演练目录：$WORK"

# 1) 造一个"远端"：旧 main + 新 clean-main + v0.1.0 tag
git init -q --bare "$BARE"
git init -q "$REPO"
cd "$REPO"
git remote add origin "$BARE"
git remote add legacy "$LEGACY"
git remote add newrepo "$ROOT"
git fetch -q legacy main:refs/remotes/legacy/main
git fetch -q newrepo main:refs/remotes/newrepo/main
OLD_SHA="$(git rev-parse refs/remotes/legacy/main)"
NEW_SHA="$(git rev-parse refs/remotes/newrepo/main)"
echo "  旧历史 = $(git rev-parse --short "$OLD_SHA")　新历史 = $(git rev-parse --short "$NEW_SHA")"
git push -q origin "$OLD_SHA":refs/heads/main "$NEW_SHA":refs/heads/clean-main
git tag -d v0.1.0 >/dev/null 2>&1 || true   # fetch 可能带回了远端 tag；演练里重建一个一致的
git tag -a v0.1.0 -m "DeskTodo 0.1.0" "$OLD_SHA"
git push -q origin refs/tags/v0.1.0
git --git-dir="$BARE" symbolic-ref HEAD refs/heads/main

# 2) 模拟 allow_deletions=false
cat > "$BARE/hooks/update" <<'HOOK'
#!/bin/bash
REF="$1"; OLD="$2"; NEW="$3"
if [ "$NEW" = "0000000000000000000000000000000000000000" ] && [ "$REF" = "refs/heads/main" ]; then
  echo "deny: protected branch deletion (allow_deletions=false)" >&2
  exit 1
fi
exit 0
HOOK
chmod +x "$BARE/hooks/update"

echo
echo "[1] 切换默认分支（模拟 GitHub default_branch）"
git --git-dir="$BARE" symbolic-ref HEAD refs/heads/clean-main
[ "$(git --git-dir="$BARE" symbolic-ref --short HEAD)" = "clean-main" ] && ok "默认分支 → clean-main" || bad "默认分支未切换"

echo
echo "[2] 保护未调整时尝试删除旧 main（应被拦）"
git push -q origin "$OLD_SHA":refs/heads/main-legacy 2>/dev/null || true
if git push -q origin :refs/heads/main 2>/tmp/dt-del.err; then
  bad "保护规则未拦住删除（演练环境异常）"
else
  ok "删除旧 main 被保护规则拦下（allow_deletions=false）"
  sed 's/^/    /' /tmp/dt-del.err | head -2
fi
git push -q origin :refs/heads/main-legacy 2>/dev/null || true   # 清掉这次预推的新名，保持原状

echo
echo "[3] 获准后临时放行删除：推新名 + 删旧名（无 force push）"
rm -f "$BARE/hooks/update"
# 3a 旧 main → main-legacy：先推新名，再删旧名（此时默认分支是 clean-main，可删）
git push -q origin "$OLD_SHA":refs/heads/main-legacy && git push -q origin :refs/heads/main \
  && ok "旧 main → main-legacy（无 force）" || bad "旧 main 更名失败"
# 3b clean-main → main：先把新历史推到 main（此时 main 不存在，属于新建，不需要 force）
git push -q origin "$NEW_SHA":refs/heads/main \
  && ok "新历史写入 main（无 force）" || bad "新历史写入 main 失败"
# 3c 切默认分支到 main，之后才能删除 clean-main
git --git-dir="$BARE" symbolic-ref HEAD refs/heads/main
git push -q origin :refs/heads/clean-main \
  && ok "clean-main → main（删除旧名，无 force）" || bad "clean-main 更名失败"

echo
echo "[4] 切换后校验：引用 / tag / 可达性"
HEADS="$(git --git-dir="$BARE" for-each-ref --format='%(refname:short)' refs/heads | sort | tr '\n' ' ')"
[ "$HEADS" = "main main-legacy " ] && ok "分支集合 = main + main-legacy" || bad "分支集合异常：$HEADS"
[ "$(git --git-dir="$BARE" rev-parse main)" = "$NEW_SHA" ] && ok "main = 新历史" || bad "main 不指向新历史"
[ "$(git --git-dir="$BARE" rev-parse main-legacy)" = "$OLD_SHA" ] && ok "main-legacy = 旧历史" || bad "main-legacy 不指向旧历史"
BARE_TAG="$(git --git-dir="$BARE" rev-parse "refs/tags/v0.1.0^{commit}" 2>/dev/null || true)"
[ "$BARE_TAG" = "$OLD_SHA" ] && ok "v0.1.0 仍指向旧提交（未受影响）" || bad "tag 受影响（bare=${BARE_TAG} old=${OLD_SHA}）"
git --git-dir="$BARE" cat-file -e "v0.1.0^{commit}" && ok "tag 对象可解析" || bad "tag 对象丢失"

echo
echo "[5] 回滚：反向更名（同样无 force）"
# 5a main(新) → clean-main：先推新名，再切默认到 clean-main，才能删 main
git push -q origin "$NEW_SHA":refs/heads/clean-main || true
git --git-dir="$BARE" symbolic-ref HEAD refs/heads/clean-main
git push -q origin :refs/heads/main \
  && ok "main(新) → clean-main（无 force）" || bad "main(新) → clean-main 失败"
# 5b main-legacy(旧) → main：main 已不存在，可直接新建
git push -q origin "$OLD_SHA":refs/heads/main \
  && ok "main-legacy → main（无 force）" || bad "main-legacy → main 失败"
# 5c 默认分支切回 main，再删除 clean-main
git --git-dir="$BARE" symbolic-ref HEAD refs/heads/main
git push -q origin :refs/heads/main-legacy 2>/dev/null || true
HEADS2="$(git --git-dir="$BARE" for-each-ref --format='%(refname:short)' refs/heads | sort | tr '\n' ' ')"
[ "$HEADS2" = "clean-main main " ] && ok "回滚后分支集合 = main + clean-main" || bad "回滚后分支集合异常：$HEADS2"
[ "$(git --git-dir="$BARE" rev-parse main)" = "$OLD_SHA" ] && ok "回滚后 main = 旧历史" || bad "回滚后 main 不正确"
[ "$(git --git-dir="$BARE" rev-parse clean-main)" = "$NEW_SHA" ] && ok "回滚后 clean-main = 新历史" || bad "回滚后 clean-main 不正确"
[ "$(git --git-dir="$BARE" rev-parse v0.1.0^{commit})" = "$OLD_SHA" ] && ok "回滚后 tag 仍完好" || bad "回滚后 tag 异常"

echo
echo "演练结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
