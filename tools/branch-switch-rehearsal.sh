#!/bin/bash
# 默认分支切换演练（只在 /tmp 里跑，不碰任何远端）。
# 目标：验证"推新名 + 删旧名"的两次更名不需要 force push，且 tag/历史不受影响；
#       并演示 allow_deletions=false 时删除会被拦，必须在获准后临时调整保护才能继续。
#
# 用法：./tools/branch-switch-rehearsal.sh [--legacy-repo <旧历史仓库路径>]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEGACY="${LEGACY_REPO:-${ROOT}/../desk-todo}"
WORK="$(mktemp -d /tmp/dt-branch-sim.XXXXXX)"
BARE="${WORK}/origin.git"
REPO="${WORK}/work"
PASS=0; FAIL=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
cleanup() { cd /tmp 2>/dev/null; rm -rf "${WORK}"; }
trap cleanup EXIT

[ -d "${LEGACY}/.git" ] || { echo "!! 旧历史仓库不存在：${LEGACY}" >&2; exit 2; }
echo "演练目录：${WORK}"

# 1) 造一个"远端"：旧 main + 新 clean-main + 既有的 release tag
git init -q --bare "${BARE}"
git init -q "${REPO}"
cd "${REPO}"
git remote add origin "${BARE}"
git remote add legacy "${LEGACY}"
git remote add newrepo "${ROOT}"
git fetch -q legacy main:refs/remotes/legacy/main
git fetch -q legacy "refs/tags/*:refs/tags/*"   # 取回真实 annotated tag 对象本身
git fetch -q newrepo main:refs/remotes/newrepo/main
OLD_SHA="$(git rev-parse refs/remotes/legacy/main)"
REL_TAG="$(git -C "${LEGACY}" tag -l 'v[0-9]*' --sort=-v:refname | head -1)"
[ -n "${REL_TAG}" ] || { echo "!! 旧历史仓库没有可参照的 release tag" >&2; exit 2; }
TAG_OBJ_ORIG="$(git -C "${LEGACY}" rev-parse "refs/tags/${REL_TAG}")"
TAG_PEEL_ORIG="$(git -C "${LEGACY}" rev-parse "refs/tags/${REL_TAG}^{commit}")"
TAG_TYPE_ORIG="$(git -C "${LEGACY}" cat-file -t "refs/tags/${REL_TAG}")"
[ "${TAG_TYPE_ORIG}" = "tag" ] || { echo "!! ${REL_TAG} 不是 annotated tag（类型 ${TAG_TYPE_ORIG}），无法做保真演练" >&2; exit 2; }
echo "  tag 对象 = ${TAG_OBJ_ORIG}　peeled = $(git rev-parse --short "${TAG_PEEL_ORIG}")　旧 main HEAD = $(git rev-parse --short "${OLD_SHA}")"
NEW_SHA="$(git rev-parse refs/remotes/newrepo/main)"
echo "  旧历史 = $(git rev-parse --short "${OLD_SHA}")　新历史 = $(git rev-parse --short "${NEW_SHA}")"
git push -q origin "${OLD_SHA}":refs/heads/main "${NEW_SHA}":refs/heads/clean-main
# 推送的是上面 fetch 回来的**原始 tag 对象**，不重新签发
git push -q origin "refs/tags/${REL_TAG}"
git --git-dir="${BARE}" symbolic-ref HEAD refs/heads/main

# 2) 模拟 allow_deletions=false
cat > "${BARE}/hooks/update" <<'HOOK'
#!/bin/bash
REF="$1"; OLD="$2"; NEW="$3"
if [ "${NEW}" = "0000000000000000000000000000000000000000" ] && [ "${REF}" = "refs/heads/main" ]; then
  echo "deny: protected branch deletion (allow_deletions=false)" >&2
  exit 1
fi
exit 0
HOOK
chmod +x "${BARE}/hooks/update"

echo
echo "[0] 初始保真校验（真实 tag 对象）"
[ "$(git --git-dir="${BARE}" rev-parse "refs/tags/${REL_TAG}")" = "${TAG_OBJ_ORIG}" ] && ok "远端 tag object SHA 与原始一致" || bad "tag object SHA 不一致"
[ "$(git --git-dir="${BARE}" rev-parse "refs/tags/${REL_TAG}^{commit}")" = "${TAG_PEEL_ORIG}" ] && ok "peeled commit 与原始一致" || bad "peeled commit 不一致"
[ "$(git --git-dir="${BARE}" cat-file -t "refs/tags/${REL_TAG}")" = "tag" ] && ok "tag 仍是 annotated（非 lightweight）" || bad "tag 类型异常"
[ "${TAG_PEEL_ORIG}" != "${OLD_SHA}" ] && ok "tag 指向旧 main 的非 HEAD 祖先（与真实仓库一致）" || bad "tag 意外指向旧 main HEAD"
SNAP_BEFORE="$(git --git-dir="${BARE}" for-each-ref --format='%(refname) %(objectname)' | sort)"

echo
echo "[1] 切换默认分支（模拟 GitHub default_branch）"
git --git-dir="${BARE}" symbolic-ref HEAD refs/heads/clean-main
[ "$(git --git-dir="${BARE}" symbolic-ref --short HEAD)" = "clean-main" ] && ok "默认分支 → clean-main" || bad "默认分支未切换"

echo
echo "[2] 保护未调整时尝试删除旧 main（应被拦）"
git push -q origin "${OLD_SHA}":refs/heads/main-legacy 2>/dev/null || true
if git push -q origin :refs/heads/main 2>/tmp/dt-del.err; then
  bad "保护规则未拦住删除（演练环境异常）"
else
  ok "删除旧 main 被保护规则拦下（allow_deletions=false）"
  sed 's/^/    /' /tmp/dt-del.err | head -2
fi
git push -q origin :refs/heads/main-legacy 2>/dev/null || true   # 清掉这次预推的新名，保持原状

echo
echo "[3] 获准后临时放行删除：推新名 + 删旧名（无 force push）"
rm -f "${BARE}/hooks/update"
# 3a 旧 main → main-legacy：先推新名，再删旧名（此时默认分支是 clean-main，可删）
git push -q origin "${OLD_SHA}":refs/heads/main-legacy && git push -q origin :refs/heads/main \
  && ok "旧 main → main-legacy（无 force）" || bad "旧 main 更名失败"
# 3b clean-main → main：先把新历史推到 main（此时 main 不存在，属于新建，不需要 force）
git push -q origin "${NEW_SHA}":refs/heads/main \
  && ok "新历史写入 main（无 force）" || bad "新历史写入 main 失败"
# 3c 切默认分支到 main，之后才能删除 clean-main
git --git-dir="${BARE}" symbolic-ref HEAD refs/heads/main
git push -q origin :refs/heads/clean-main \
  && ok "clean-main → main（删除旧名，无 force）" || bad "clean-main 更名失败"

echo
echo "[4] 切换后校验：引用 / tag / 可达性"
HEADS="$(git --git-dir="${BARE}" for-each-ref --format='%(refname:short)' refs/heads | sort | tr '\n' ' ')"
[ "${HEADS}" = "main main-legacy " ] && ok "分支集合 = main + main-legacy" || bad "分支集合异常：${HEADS}"
[ "$(git --git-dir="${BARE}" rev-parse main)" = "${NEW_SHA}" ] && ok "main = 新历史" || bad "main 不指向新历史"
[ "$(git --git-dir="${BARE}" rev-parse main-legacy)" = "${OLD_SHA}" ] && ok "main-legacy = 旧历史" || bad "main-legacy 不指向旧历史"
BARE_TAG_OBJ="$(git --git-dir="${BARE}" rev-parse "refs/tags/${REL_TAG}" 2>/dev/null || true)"
BARE_TAG_PEEL="$(git --git-dir="${BARE}" rev-parse "refs/tags/${REL_TAG}^{commit}" 2>/dev/null || true)"
[ "${BARE_TAG_OBJ}" = "${TAG_OBJ_ORIG}" ] && ok "切换后 tag object SHA 未变" || bad "切换后 tag object SHA 变了"
[ "${BARE_TAG_PEEL}" = "${TAG_PEEL_ORIG}" ] && ok "切换后 peeled commit 未变（仍为 $(git rev-parse --short "${TAG_PEEL_ORIG}")）" || bad "切换后 peeled commit 变了"
[ "$(git --git-dir="${BARE}" cat-file -t "refs/tags/${REL_TAG}")" = "tag" ] && ok "切换后 tag 仍是 annotated" || bad "切换后 tag 类型变了"

echo
echo "[5] 回滚：反向更名（同样无 force）"
# 5a main(新) → clean-main：先推新名，再切默认到 clean-main，才能删 main
git push -q origin "${NEW_SHA}":refs/heads/clean-main || true
git --git-dir="${BARE}" symbolic-ref HEAD refs/heads/clean-main
git push -q origin :refs/heads/main \
  && ok "main(新) → clean-main（无 force）" || bad "main(新) → clean-main 失败"
# 5b main-legacy(旧) → main：main 已不存在，可直接新建
git push -q origin "${OLD_SHA}":refs/heads/main \
  && ok "main-legacy → main（无 force）" || bad "main-legacy → main 失败"
# 5c 默认分支切回 main，再删除 clean-main
git --git-dir="${BARE}" symbolic-ref HEAD refs/heads/main
git push -q origin :refs/heads/main-legacy 2>/dev/null || true
HEADS2="$(git --git-dir="${BARE}" for-each-ref --format='%(refname:short)' refs/heads | sort | tr '\n' ' ')"
[ "${HEADS2}" = "clean-main main " ] && ok "回滚后分支集合 = main + clean-main" || bad "回滚后分支集合异常：${HEADS2}"
[ "$(git --git-dir="${BARE}" rev-parse main)" = "${OLD_SHA}" ] && ok "回滚后 main = 旧历史" || bad "回滚后 main 不正确"
[ "$(git --git-dir="${BARE}" rev-parse clean-main)" = "${NEW_SHA}" ] && ok "回滚后 clean-main = 新历史" || bad "回滚后 clean-main 不正确"
[ "$(git --git-dir="${BARE}" rev-parse "refs/tags/${REL_TAG}")" = "${TAG_OBJ_ORIG}" ] && ok "回滚后 tag object SHA 与原始一致" || bad "回滚后 tag object SHA 不一致"
[ "$(git --git-dir="${BARE}" rev-parse "refs/tags/${REL_TAG}^{commit}")" = "${TAG_PEEL_ORIG}" ] && ok "回滚后 peeled commit 与原始一致" || bad "回滚后 peeled commit 不一致"
SNAP_AFTER="$(git --git-dir="${BARE}" for-each-ref --format='%(refname) %(objectname)' | sort)"
[ "${SNAP_BEFORE}" = "${SNAP_AFTER}" ] && ok "回滚后完整引用快照与初始一致（branches + tags）" || { bad "回滚后引用快照不一致"; diff <(printf '%s\n' "${SNAP_BEFORE}") <(printf '%s\n' "${SNAP_AFTER}") | sed 's/^/    /'; }

echo
echo "演练结果：PASS=${PASS} FAIL=${FAIL}"
[ "${FAIL}" -eq 0 ]
