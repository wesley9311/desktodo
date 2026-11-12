#!/bin/bash
# Git 对抗性自动审查：只查"提交进仓库的东西"，不查构建产物。
# 旧版本号 / 旧品牌 / 旧文件名在脚本里用运行时拼接，避免审查脚本自己违反同一规则。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
note() { printf '    %s\n' "$1"; }

VERSION="$(tr -d '[:space:]' < VERSION)"
OLD_FILE="$(printf 'data%s' '.json')"
BRAND="$(python3 -c 'print("\u5e74\u8f6e")')"

echo "Git 对抗性审查（版本 ${VERSION}）"

echo
echo "[1] 工作区与分支"
[ -z "$(git status --porcelain)" ] && ok "工作区干净" || { bad "工作区有未提交改动"; git status --porcelain | while IFS= read -r l; do note "$l"; done; }
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] && ok "当前分支 main" || bad "不在 main 分支"

echo
echo "[2] 版本治理（版本号 / 构建号 / schema / tag / 历史引用）"
if ./tools/version-check.sh --mode auto >/tmp/git-audit-version.log 2>&1; then
  ok "version-check 通过（模式见日志）"
else
  bad "version-check 失败（见 /tmp/git-audit-version.log）"
  sed 's/^/    /' /tmp/git-audit-version.log | head -12
fi
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null 2>&1; then
  [ "$(git cat-file -t "v$VERSION")" = "tag" ] && ok "tag 是 annotated" || bad "tag 不是 annotated"
else
  note "当前版本尚未打 tag（本地开发状态）；发布时必须存在 v$VERSION"
fi

echo
echo "[3] 措辞（旧品牌 / 旧文件名；历史版本引用由 version-check 限定范围）"
B="$(git grep -n "$BRAND" 2>/dev/null | head -1 || true)"
[ -z "$B" ] && ok "没有旧品牌字面量" || bad "出现旧品牌字面量：$B"
F="$(git grep -n "$OLD_FILE" 2>/dev/null | grep -v '^src/LegacyPaths.swift:' | grep -v '^CHANGELOG.md:' | grep -v '^docs/MANUAL.md:' | head -3 || true)"
[ -z "$F" ] && ok "旧文件名只出现在 LegacyPaths.swift（常量）与 CHANGELOG / MANUAL（回滚说明）" || bad "旧文件名出现在别处：$F"

echo
echo "[4] 新提交规范（历史基准之后）"
BADMSG=""
# 历史基准动态化：默认取当前历史的根提交（孤立 Clean Baseline 时即根本身）。
# 换任务书/旧仓库时可用 GIT_AUDIT_BASE=<sha> 显式覆盖；基准不存在时报失败，不再静默假绿。
BASE="${GIT_AUDIT_BASE:-$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)}"
if [ -z "$BASE" ] || ! git cat-file -e "$BASE^{commit}" 2>/dev/null; then
  bad "历史基准不可用（BASE=${BASE:-空}；可设 GIT_AUDIT_BASE=<sha> 覆盖）"
else
  SHORT="$(git rev-parse --short "$BASE" 2>/dev/null || echo "$BASE")"
  N="$(git rev-list --count "$BASE"..HEAD 2>/dev/null || echo 0)"
  for c in $(git rev-list "$BASE"..HEAD 2>/dev/null); do
    S="$(git log -1 --format=%s "$c")"
    case "$S" in
      feat*|fix*|refactor*|docs*|build*|test*|ci*|chore*|perf*|revert*) ;;
      *) BADMSG="$BADMSG$c $S\n" ;;
    esac
    V2="$(printf '%s' "$S" | grep -oE '0\.[0-9]+\.[0-9]+' | grep -vx "$VERSION" || true)"
    [ -n "$V2" ] && BADMSG="${BADMSG}${c} ${S}（含旧号 ${V2}）\n"
  done
  if [ -z "$BADMSG" ]; then
    ok "$N 个新提交前缀合规、不含旧号（基准 ${SHORT}）"
    [ "$N" = "0" ] && note "基准即 HEAD，暂无新提交"
  else
    bad "提交不合规："
    printf '%b' "$BADMSG" | while IFS= read -r l; do [ -n "$l" ] && note "$l"; done
  fi
  if git rev-parse -q --verify refs/remotes/origin/main >/dev/null 2>&1; then
    [ "$(git rev-list --merges --count origin/main..HEAD 2>/dev/null)" = "0" ] && ok "线性历史（无 merge 提交）" || bad "存在 merge 提交"
  else
    note "没有 origin/main，跳过线性历史检查（新分支首次推送前为正常态）"
  fi
fi

echo
echo "[5] 数据 / 密钥 / 构建产物"
TRACKED="$(git ls-files | grep -E '(^|/)(ledger|data)\.json|(^|/)data\.json|(^|/)focus\.json|(^|/)backups/|(^|/)logs/|(^|/)snapshots/|\.(p12|pem|key|keychain|keychain-db)$|^dist/|^build/' || true)"
[ -z "$TRACKED" ] && ok "没有跟踪数据文件 / 密钥 / 构建产物" || { bad "这些被跟踪了："; echo "$TRACKED" | while IFS= read -r l; do note "$l"; done; }
grep -qE '^build/' .gitignore && grep -qE '^dist/' .gitignore && grep -qE 'ledger\.json' .gitignore && grep -qE 'data\*?\.json' .gitignore && grep -qE 'keychain' .gitignore \
  && ok ".gitignore 覆盖产物 / 数据 / 钥匙串" || bad ".gitignore 不完整"

echo
echo "[6] 卫生"
[ -z "$(git ls-files | grep -E '\.DS_Store$|__MACOSX|\._')" ] && ok "没有 .DS_Store / __MACOSX / ._*" || bad "存在系统垃圾文件"
BIG="$(git ls-files -z | xargs -0 -I{} sh -c 'test -f "{}" && [ $(stat -f%z "{}") -gt 2097152 ] && echo "{}"' 2>/dev/null || true)"
[ -z "$BIG" ] && ok "没有 >2MB 的跟踪文件" || { bad "有大文件："; echo "$BIG" | while IFS= read -r l; do note "$l"; done; }
LEAK="$(git grep -nE '/Users/[a-z][A-Za-z0-9._-]*' -- '*.md' '*.swift' '*.js' '*.sh' '*.yml' 2>/dev/null | grep -vE 'LegacyPaths|sanitize|diagnostic|fakePath|"/Users/"|/Users/<user>|/Users/\$' | head -3 || true)"
[ -z "$LEAK" ] && ok "没有写死的个人路径" || { bad "出现个人路径："; echo "$LEAK" | while IFS= read -r l; do note "$l"; done; }

echo
echo "[7] 远端状态（只读）"
REMOTE="$(git remote get-url origin 2>/dev/null || echo '')"
[ -n "$REMOTE" ] && ok "origin: $REMOTE" || bad "没有 origin"
if git rev-parse -q --verify refs/remotes/origin/main >/dev/null 2>&1; then
  AHEAD="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo '?')"
  note "本地领先 origin/main：$AHEAD 个提交（不 push 是当前约束）"
else
  note "没有 origin/main 引用，跳过领先计数（新分支首次推送前为正常态）"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mGit 审查通过\033[0m\n'
else
  printf '\033[31mGit 审查失败 %d 项\033[0m\n' "$FAIL"
fi
exit "$FAIL"
