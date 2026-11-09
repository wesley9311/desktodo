#!/bin/bash
# 边界审计。这条脚本的目的不是"检查代码风格"，而是守住几条**一旦破了就不该发版**的线。
#
# 为什么这件事不能只写在文档里：文档不会拦人。一个 PR 加一行 URLSession 就能把
# "数据不出机器"变成假话，而且 CI 全绿、界面照旧。所以每条边界都做成一条能失败的检查。
#
# 用法：./tools/audit.sh        任何一条 FAIL 就非 0 退出
# 这一版修掉了上一版"检查存在但不生效"的五处：
#   1. 口径唯一性按"实现处数"计数（以前按"文件数"，同一文件写两份也算 1）；
#   2. 域名白名单按 URL 逐个校验（以前按整行放行，同行再带别的域名也过）；
#   3. 扫描范围加上 html / css / plist（以前只扫 swift / js）；
#   4. 遥测词表补全；
#   5. 权限白名单删掉 NSAppleEventsUsageDescription（自动化权限不再能无感加入）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

FAIL=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
note() { printf '    %s\n' "$1"; }

echo "边界审计 $ROOT"

# ─────────────────────────────────────────────────────────────
# 1. 网络出口白名单：唯一允许联网的代码只能是天气
# ─────────────────────────────────────────────────────────────
echo
echo "[1] 网络出口"
NET_HITS="$(grep -rnE 'URLSession|URLRequest|NSURLConnection|CFStream|NWConnection|socket\(' \
  --include='*.swift' src 2>/dev/null | grep -v '^src/AppDelegate+Weather.swift:' || true)"
if [ -z "$NET_HITS" ]; then
  pass "Swift 里除天气外没有网络调用"
else
  fail "天气文件之外出现网络调用："
  echo "$NET_HITS" | while IFS= read -r l; do note "$l"; done
fi

# 只有天气文件能调用 httpJSON（它是唯一出口；别的文件调它 = 绕过闸门的入口）
JSON_CALLERS="$(grep -rn 'httpJSON(' --include='*.swift' src 2>/dev/null \
  | grep -v '^src/AppDelegate+Weather.swift:' | grep -v 'func httpJSON' || true)"
if [ -z "$JSON_CALLERS" ]; then
  pass "只有天气文件调用 httpJSON"
else
  fail "天气文件之外调用了唯一网络出口 httpJSON："
  echo "$JSON_CALLERS" | while IFS= read -r l; do note "$l"; done
fi

# 闸门必须在出口函数第一行附近（"不联网"不能有第二条路）
if grep -A3 'func httpJSON' src/AppDelegate+Weather.swift 2>/dev/null | grep -q 'weatherOffline'; then
  pass "httpJSON 的「不联网」闸门在第一行"
else
  fail "httpJSON 里没有 weatherOffline 闸门（「不联网」会被绕过）"
fi

JS_NET="$(grep -rnE 'fetch\s*\(|XMLHttpRequest|WebSocket|sendBeacon|EventSource|import\s*\(' \
  --include='*.js' src/js 2>/dev/null || true)"
if [ -z "$JS_NET" ]; then
  pass "页面里没有任何网络 API（file:// 下也不该有）"
else
  fail "页面里出现网络 API："
  echo "$JS_NET" | while IFS= read -r l; do note "$l"; done
fi

# 域名白名单：把源码里出现的每个 URL 都抠出来，逐个看主机名。
# 以前按"整行"过滤：同一行里再写一个 evil.example.com 也会被放过。
ALLOWED_HOSTS='^(ipwho\.is|api\.open-meteo\.com|geocoding-api\.open-meteo\.com)$'
BAD_URL=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in *'DOCTYPE plist'*|*'www.apple.com/DTDs'*) continue ;; esac
  file="${line%%:*}"
  rest="${line#*:}"; rest="${rest#*:}"
  url="$(printf '%s' "$rest" | grep -oE 'https?://[^"[:space:]<>)]+' | head -1)"
  [ -z "$url" ] && continue
  host="$(printf '%s' "$url" | sed -E 's#^https?://##; s#[/:?#].*##')"
  if ! printf '%s' "$host" | grep -qE "$ALLOWED_HOSTS"; then
    BAD_URL="$BAD_URL\n      $file → $url"
  elif [ "$file" != "src/AppDelegate+Weather.swift" ]; then
    BAD_URL="$BAD_URL\n      $file → ${url}（白名单域名出现在天气文件之外）"
  fi
done < <(grep -rnoE 'https?://[^"[:space:]<>)]+' --include='*.swift' --include='*.js' \
          --include='*.html' --include='*.css' --include='*.plist' src 2>/dev/null || true)
if [ -z "$BAD_URL" ]; then
  pass "所有 URL 都在白名单里，且只出现在天气文件"
else
  fail "出现白名单外的 URL 或位置不对："
  printf '%b\n' "$BAD_URL" | while IFS= read -r l; do [ -n "$l" ] && note "$l"; done
fi

# ─────────────────────────────────────────────────────────────
# 2. 反遥测：出现即拦。这类代码一旦进来，用户是察觉不到的
# ─────────────────────────────────────────────────────────────
echo
echo "[2] 遥测 / 统计 SDK"
TRACK="$(grep -rniE 'analytics|telemetry|mixpanel|amplitude|sentry|bugsnag|firebase|umeng|友盟|appsflyer|adjust\.com|fingerprint|posthog|crashlytics|datadog|plausible|segment\.io|gtag|googletag|countly|umami' \
  --include='*.swift' --include='*.js' --include='*.html' --include='*.plist' src 2>/dev/null || true)"
if [ -z "$TRACK" ]; then
  pass "没有埋点 / 崩溃上报 / 统计 SDK"
else
  fail "出现疑似遥测代码："
  echo "$TRACK" | while IFS= read -r l; do note "$l"; done
fi

# ─────────────────────────────────────────────────────────────
# 3. 隐私面锁：Info.plist 里的权限说明只能减少，不能悄悄增加
# ─────────────────────────────────────────────────────────────
echo
echo "[3] 权限面"
ALLOWED_KEYS='CFBundleIconFile|CFBundleName|CFBundleDisplayName|CFBundleExecutable|CFBundleIdentifier|CFBundleInfoDictionaryVersion|CFBundlePackageType|CFBundleShortVersionString|CFBundleVersion|LSMinimumSystemVersion|NSCalendarsUsageDescription|NSCalendarsFullAccessUsageDescription|NSRemindersUsageDescription|NSRemindersFullAccessUsageDescription|LSUIElement|LSMultipleInstancesProhibited|NSHighResolutionCapable|NSHumanReadableCopyright|CFBundleDevelopmentRegion'
EXTRA_KEYS="$(grep -oE '<key>[^<]+</key>' src/Info.plist | sed -E 's/<\/?key>//g' \
  | grep -vE "^($ALLOWED_KEYS)$" || true)"
if [ -z "$EXTRA_KEYS" ]; then
  pass "Info.plist 没有名单外的键（只有日历 / 提醒事项，且都是只读）"
else
  fail "Info.plist 出现名单外的键，必须停下来问：这真的必要吗？"
  echo "$EXTRA_KEYS" | while IFS= read -r l; do note "$l"; done
fi

# ─────────────────────────────────────────────────────────────
# 4. 数据不入库：仓库里永远不能有真实数据、密钥、证书
# ─────────────────────────────────────────────────────────────
echo
echo "[4] 数据与密钥"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  TRACKED="$(git ls-files | grep -E '(^|/)(data\.json|data\.json\.bak|focus\.json|data\.corrupt-[0-9-]+\.json|data\.bak\.corrupt-[0-9-]+\.json|data\.conflict-[0-9-]+\.json|data\.backup-[0-9-]+\.json)$|\.(p12|pem|key|keychain|keychain-db)$|\.desktodo-signing-pass$|^dist/|^build/' || true)"
  if [ -z "$TRACKED" ]; then
    pass "已跟踪文件里没有数据文件 / 密钥 / 构建产物"
  else
    fail "这些文件被 git 跟踪了，必须移除："
    echo "$TRACKED" | while IFS= read -r l; do note "$l"; done
  fi
else
  note "（还不是 git 仓库，跳过跟踪检查）"
fi

GN=".gitignore"
if [ -f "$GN" ] \
   && grep -qE '^build/' "$GN" \
   && grep -qE '^dist/' "$GN" \
   && grep -qE 'data\.json' "$GN" \
   && grep -qE 'data\.conflict-' "$GN" \
   && grep -qE 'snapshots/' "$GN" \
   && grep -qE 'keychain' "$GN"; then
  pass ".gitignore 覆盖构建产物 / 导出包 / 数据 / 备份快照 / 钥匙串"
else
  fail ".gitignore 不完整（至少要挡 build/ dist/ data.json data.conflict-* snapshots/ *.keychain*）"
fi

# ─────────────────────────────────────────────────────────────
# 5. 不含个人路径：源码里不许出现某台机器的家目录
# ─────────────────────────────────────────────────────────────
echo
echo "[5] 可移植性"
PERSONAL="$(grep -rnE '/Users/[A-Za-z0-9._-]+' --include='*.swift' --include='*.js' --include='*.sh' \
  --include='*.html' --include='*.css' src tools build.sh 2>/dev/null | grep -vE '/Users/\$|/Users/\(|example' || true)"
if [ -z "$PERSONAL" ]; then
  pass "源码与脚本里没有写死的家目录路径"
else
  fail "出现写死的个人路径："
  echo "$PERSONAL" | while IFS= read -r l; do note "$l"; done
fi

# ─────────────────────────────────────────────────────────────
# 6. 「不伪造数据」的最后一道：口径只允许有一个实现
#    这个产品已经三次把"没记录"算成 0 件。三次的原因都不是写错算术，
#    而是**同一件事有两份实现**，改了一份忘了另一份。
#    这一版改成按"实现处数"计数：同一文件里写两份 dayDone 也会被抓住。
# ─────────────────────────────────────────────────────────────
echo
echo "[6] 统计口径"
D1="$(grep -rhoE 'function dayDone' --include='*.js' src/js 2>/dev/null | wc -l | tr -d ' ')"
D2="$(grep -rhoE 'function dayObserved' --include='*.js' src/js 2>/dev/null | wc -l | tr -d ' ')"
if [ "$D1" = "1" ] && [ "$D2" = "1" ]; then
  pass "dayDone / dayObserved 各只有一处实现"
else
  fail "口径函数被重复实现（dayDone 有 $D1 处，dayObserved 有 $D2 处）—— 改一处会漏另一处"
fi

BAD_STAT="$(grep -rnE 'dailyMap\(\)\[' --include='*.js' src/js 2>/dev/null \
  | grep -v 'src/js/05-today.js:' || true)"
if [ -z "$BAD_STAT" ]; then
  pass "没有人绕过 dayDone 直接翻账本"
else
  fail "有地方直接索引 daily，绕过了口径函数："
  echo "$BAD_STAT" | while IFS= read -r l; do note "$l"; done
fi

# ─────────────────────────────────────────────────────────────
# 7. 调试后门：只能由 --dev 打开，且不许有"无确认清空"这种开关
# ─────────────────────────────────────────────────────────────
echo
echo "[7] 调试入口"
# 注释里提到这些名字是允许的（解释为什么删掉）；只查真正执行的行
if grep -rn 'dbgWipe' --include='*.swift' src 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*//' | grep -q .; then
  fail "出现了 dbgWipe（启动即无确认清空全部数据）"
else
  pass "没有 dbgWipe 这类「启动即清空」的开关"
fi
BAD_DEV=""
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  f="${hit%%:*}"; rest="${hit#*:}"; ln="${rest%%:*}"
  ctx="$(sed -n "$((ln > 2 ? ln - 2 : 1)),$((ln + 2))p" "$f" 2>/dev/null || true)"
  case "$ctx" in *devMode*) ;; *) BAD_DEV="$BAD_DEV\n      $hit" ;; esac
done < <(grep -rnE 'DESKTODO_HTML|dbgExport|dbgReport' --include='*.swift' src 2>/dev/null \
          | grep -vE ':[0-9]+:[[:space:]]*//' || true)
if [ -z "$BAD_DEV" ]; then
  pass "调试入口都要求显式 --dev"
else
  fail "这些调试入口没有 --dev 守卫："
  printf '%b\n' "$BAD_DEV" | while IFS= read -r l; do [ -n "$l" ] && note "$l"; done
fi

# ─────────────────────────────────────────────────────────────
# 8. 诊断日志：不许再写 /tmp（全机可读），且只由一处写
# ─────────────────────────────────────────────────────────────
echo
echo "[8] 诊断日志"
if grep -rn '"/tmp/desktodo.log"' --include='*.swift' src 2>/dev/null | grep -q .; then
  fail "还在写 /tmp/desktodo.log（0644、全机可读）"
else
  pass "诊断日志不在 /tmp"
fi
LOGOWNERS="$(grep -rln 'Logs/DeskTodo' --include='*.swift' src 2>/dev/null | wc -l | tr -d ' ')"
if [ "$LOGOWNERS" = "1" ]; then
  pass "日志路径只在一个文件里出现"
else
  fail "日志路径出现在 $LOGOWNERS 个文件里（应集中在一处）"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m边界审计全部通过\033[0m\n'
  exit 0
fi
printf '\033[31m边界审计失败 %d 项 —— 不要发版\033[0m\n' "$FAIL"
exit 1
