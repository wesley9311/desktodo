#!/bin/bash
# 版本治理检查：版本号 / 构建号 / schemaVersion / tag / 历史引用 / latest。
# 只读：不创建 tag、不改文件、不访问网络（--check-github 除外，只 GET）。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

MODE="auto"
CHECK_GH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-auto}"; shift 2 ;;
    --mode=*) MODE="${1#--mode=}"; shift ;;
    --check-github) CHECK_GH=1; shift ;;
    -h|--help) echo "用法: $0 [--mode auto|tag|main|local] [--check-github]"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
case "$MODE" in auto|tag|main|local) ;; *) echo "mode 只能是 auto/tag/main/local" >&2; exit 2 ;; esac

FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null)"
[ -n "$VERSION" ] || { echo "缺少 VERSION"; exit 1; }

# 1) 版本号格式
CORE="$VERSION"
SUFFIX=""
if [[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-(alpha|beta|rc)\.([1-9][0-9]*))?$ ]]; then
  MAJOR="${BASH_REMATCH[1]}"; MINOR="${BASH_REMATCH[2]}"; PATCH="${BASH_REMATCH[3]}"
  SUFFIX="${BASH_REMATCH[4]}"
  CORE="$MAJOR.$MINOR.$PATCH"
  ok "版本号格式：${VERSION}（核心 $CORE${SUFFIX:+，后缀 $SUFFIX}）"
else
  bad "版本号格式非法：${VERSION}（应为 MAJOR.MINOR.PATCH[-alpha.N|-beta.N|-rc.N]）"
  MAJOR=0; MINOR=0; PATCH=0
fi

# 2) Info.plist 映射
PLIST="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' src/Info.plist 2>/dev/null || echo '')"
[ "$PLIST" = "$CORE" ] && ok "Info.plist 短版本 = 数字核心（${CORE}）" || bad "Info.plist=${PLIST}，应为 ${CORE}（后缀只放 VERSION/tag）"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' src/Info.plist 2>/dev/null || echo '')"
if [[ "$BUILD" =~ ^([0-9]{8})([0-9]{2})$ ]]; then
  BDATE="${BASH_REMATCH[1]}"; BNN="${BASH_REMATCH[2]}"
  if [ "$(date -j -f "%Y%m%d" "$BDATE" "+%Y%m%d" 2>/dev/null)" = "$BDATE" ] && [ "$BNN" -ge 1 ] && [ "$BNN" -le 99 ]; then
    ok "构建号格式：${BUILD}（YYYYMMDDnn，日期合法，nn=${BNN}）"
  else
    bad "构建号日期或 nn 非法：$BUILD"
  fi
else
  bad "构建号格式非法：${BUILD}（应为 10 位 YYYYMMDDnn）"
fi

# 3) CHANGELOG 条目
if grep -q "^## ${VERSION} " CHANGELOG.md 2>/dev/null; then
  ok "CHANGELOG 有 $VERSION 条目"
else
  bad "CHANGELOG 缺少 '## $VERSION ' 条目"
fi

# 4) tag 模式与四同步
TAG="v$VERSION"
HAS_TAG=0
TAG_COMMIT=""
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  HAS_TAG=1
  TAG_COMMIT="$(git rev-list -n1 "$TAG")"
fi
if [ "$MODE" = "auto" ]; then
  if [ "$HAS_TAG" = "1" ] && [ "$TAG_COMMIT" = "$(git rev-parse HEAD)" ]; then
    MODE="tag"
  elif [ "$HAS_TAG" = "1" ] && git merge-base --is-ancestor "$TAG" HEAD 2>/dev/null; then
    MODE="main"
  else
    MODE="local"
  fi
fi
note "检查模式：$MODE"

# 收集所有 tag 的构建号与 schema
TAG_BUILDS=""
for t in $(git tag --list 'v*' 2>/dev/null); do
  b="$(git show "$t":src/Info.plist 2>/dev/null | sed -n '/CFBundleVersion/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' | tr -d '[:space:]' | head -1)"
  [ -n "$b" ] && TAG_BUILDS="$TAG_BUILDS$t $b\n"
done
build_of() { printf '%b' "$TAG_BUILDS" | awk -v t="$1" '$1==t{print $2; exit}'; }

case "$MODE" in
  tag)
    [ "$HAS_TAG" = "1" ] && ok "tag $TAG 存在" || bad "缺少 tag $TAG"
    [ "$TAG_COMMIT" = "$(git rev-parse HEAD)" ] && ok "tag 指向 HEAD" || bad "tag 不指向 HEAD（tag 模式要求正好是发布提交）"
    [ "$(git cat-file -t "$TAG" 2>/dev/null)" = "tag" ] && ok "tag 是 annotated" || bad "tag 不是 annotated"
    TB="$(build_of "$TAG")"
    [ "$TB" = "$BUILD" ] && ok "tag 构建号与 Info.plist 一致（${BUILD}）" || bad "同版本重签名/重构建必须换版本：tag 构建号=${TB}，Info.plist=$BUILD"
    ;;
  main)
    [ "$HAS_TAG" = "1" ] || bad "main 复验缺少 tag $TAG"
    if [ "$HAS_TAG" = "1" ]; then
      git merge-base --is-ancestor "$TAG" HEAD 2>/dev/null && ok "tag 是 HEAD 的祖先（发布后 main 可继续前进）" || bad "tag 不在 HEAD 历史里"
      TB="$(build_of "$TAG")"
      [ "$TB" = "$BUILD" ] && ok "tag 构建号与 Info.plist 一致（${BUILD}）" || bad "tag 构建号=${TB}，Info.plist=$BUILD"
    fi
    ;;
  local)
    note "本地构建：不要求 tag；正式发布必须走 tag 模式"
    ;;
esac

# 5) 构建号唯一 + 严格递增（排除自己的 tag）
MAX_OTHER=0
DUP=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  t="${line%% *}"; b="${line##* }"
  [ "$t" = "$TAG" ] && continue
  [ -n "$b" ] || continue
  if [ "$b" = "$BUILD" ]; then DUP="$DUP $t"; fi
  if [ "$b" -gt "$MAX_OTHER" ] 2>/dev/null; then MAX_OTHER="$b"; fi
done < <(printf '%b' "$TAG_BUILDS")
if [ -z "$DUP" ]; then ok "构建号未被其他 tag 使用"; else bad "构建号 $BUILD 已被这些 tag 使用：$DUP"; fi
if [ "$BUILD" -gt "$MAX_OTHER" ] 2>/dev/null; then
  ok "构建号严格大于其他 tag（$BUILD > ${MAX_OTHER}）"
else
  bad "构建号没有严格递增：$BUILD <= ${MAX_OTHER}（其他 tag 最大值）"
fi

# 6) schemaVersion 的 PATCH 约束
SCHEMA="$(grep -oE 'storeSchemaVersion = [0-9]+' src/Storage.swift 2>/dev/null | grep -oE '[0-9]+$' | head -1)"
[ -n "$SCHEMA" ] && ok "schemaVersion = ${SCHEMA}（src/Storage.swift）" || bad "找不到 storeSchemaVersion"
PREV_TAG=""; PREV_BUILD=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  t="${line%% *}"; b="${line##* }"
  [ "$t" = "$TAG" ] && continue
  [ -n "$b" ] || continue
  if [ "$b" -lt "$BUILD" ] 2>/dev/null && [ "$b" -gt "$PREV_BUILD" ] 2>/dev/null; then PREV_BUILD="$b"; PREV_TAG="$t"; fi
done < <(printf '%b' "$TAG_BUILDS")
if [ -n "$PREV_TAG" ] && [ -n "$SCHEMA" ]; then
  PREV_SCHEMA="$(git show "$PREV_TAG":src/Storage.swift 2>/dev/null | grep -oE 'storeSchemaVersion = [0-9]+' | grep -oE '[0-9]+$' | head -1)"
  PREV_VER="${PREV_TAG#v}"; PREV_CORE="${PREV_VER%%-*}"
  if [ "$PREV_SCHEMA" = "$SCHEMA" ]; then
    ok "schemaVersion 与上一发布 $PREV_TAG 一致（${SCHEMA}）"
  else
    PMAJ="${PREV_CORE%%.*}"; REST="${PREV_CORE#*.}"; PMIN="${REST%%.*}"
    if [ "$MAJOR" = "$PMAJ" ] && [ "$MINOR" = "$PMIN" ]; then
      bad "PATCH 不得改 schemaVersion：$PREV_TAG=${PREV_SCHEMA}，当前=${SCHEMA}（应升 MINOR）"
    else
      ok "schemaVersion 变化伴随 MINOR/MAJOR：$PREV_TAG=$PREV_SCHEMA → $SCHEMA"
    fi
  fi
else
  note "没有更早的可比发布，跳过 schemaVersion 对比"
fi

# 7) 历史版本引用范围
HIST="$(git grep -hoE '0\.[0-9]+\.[0-9]+' -- '*.md' '*.sh' '*.yml' '*.swift' '*.js' '*.txt' 2>/dev/null | sort -u)"
BAD_REF=""
for v in $HIST; do
  [ "$v" = "$VERSION" ] && continue
  [ "$v" = "$CORE" ] && continue   # 当前版是预发布时，其数字核心不算历史号
  files="$(git grep -lF "$v" -- '*.md' '*.sh' '*.yml' '*.swift' '*.js' '*.txt' 2>/dev/null | tr '\n' ' ')"
  [ -z "$files" ] && continue
  for f in $files; do
    case "$f" in
      VERSIONING.md|CHANGELOG.md|SECURITY.md|docs/MIGRATION*.md|docs/audits/*) ;;
      *) BAD_REF="$BAD_REF $v($f)" ;;
    esac
  done
done
[ -z "$BAD_REF" ] && ok "历史版本引用只在允许的文件里（CHANGELOG/VERSIONING/SECURITY/迁移/审计）" || bad "历史版本出现在不允许的文件：$BAD_REF"

# 8) latest 规则
if [ "$MODE" = "tag" ] && [ "$MAJOR" -ge 1 ] && [ -z "$SUFFIX" ]; then
  note "正式版：发布后可执行 gh release edit $TAG --latest"
elif [ "$MAJOR" -lt 1 ] || [ -n "$SUFFIX" ]; then
  ok "0.x / 预发布：不得执行 --latest（GitHub 也会拒绝）"
fi

# 9) GitHub 实际保护配置（只读，可选）
if [ "$CHECK_GH" = "1" ]; then
  echo
  echo "GitHub 实际配置（只读）"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo '')"
    if [ -n "$REPO" ]; then
      BP="$(gh api "repos/$REPO/branches/main/protection" 2>/dev/null || echo '{}')"
      echo "$BP" | grep -q '"required_status_checks":null' && warn "main 无 required status checks" || note "main 的保护 JSON 见下"
      echo "$BP" | head -c 400; echo
      RS="$(gh api "repos/$REPO/rulesets" 2>/dev/null || echo '[]')"
      [ "$RS" = "[]" ] && warn "没有 rulesets（tag 保护为空）" || note "rulesets: $RS"
    else
      warn "无法读取仓库名"
    fi
  else
    warn "gh 未登录，跳过 GitHub 配置检查"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m版本治理检查通过（%s）\033[0m\n' "$MODE"
else
  printf '\033[31m版本治理检查失败 %d 项\033[0m\n' "$FAIL"
fi
exit "$FAIL"
