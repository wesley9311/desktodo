#!/bin/bash
# 边界审计。这条脚本的目的不是"检查代码风格"，而是守住几条**一旦破了就不该发版**的线。
#
# 为什么这件事不能只写在文档里：文档不会拦人。一个 PR 加一行 URLSession 就能把
# "数据不出机器"变成假话，而且 CI 全绿、界面照旧。所以每条边界都做成一条能失败的检查。
#
# 用法：./tools/audit.sh        任何一条 FAIL 就非 0 退出
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
#    （天气是外部数据，失败就不显示，不进任何统计；除它以外一次都不许连）
# ─────────────────────────────────────────────────────────────
echo
echo "[1] 网络出口"
NET_HITS="$(grep -rnE 'URLSession|URLRequest|NSURLConnection|NSURLSession|CFStream|NWConnection|socket\(' \
  --include='*.swift' src 2>/dev/null | grep -v '^src/AppDelegate+Weather.swift:' || true)"
if [ -z "$NET_HITS" ]; then
  pass "Swift 里除天气外没有网络调用"
else
  fail "天气文件之外出现网络调用："
  echo "$NET_HITS" | while IFS= read -r l; do note "$l"; done
fi

JS_NET="$(grep -rnE 'fetch\s*\(|XMLHttpRequest|WebSocket|sendBeacon|EventSource|import\s*\(' \
  --include='*.js' src/js 2>/dev/null || true)"
if [ -z "$JS_NET" ]; then
  pass "页面里没有任何网络 API（file:// 下也不该有）"
else
  fail "页面里出现网络 API："
  echo "$JS_NET" | while IFS= read -r l; do note "$l"; done
fi

# 域名白名单：只准这两个，且只准出现在天气文件里。
# 唯一的例外是 plist 的 DOCTYPE 声明（那不是请求，是一行格式声明）。
BAD_URL="$(grep -rnE 'https?://' --include='*.swift' --include='*.js' src 2>/dev/null \
  | grep -vE 'DOCTYPE plist' \
  | grep -vE '^src/AppDelegate\+Weather\.swift:.*(api\.open-meteo\.com|geocoding-api\.open-meteo\.com|ipwho\.is)|^src/AppDelegate\+Weather\.swift:[0-9]+:\s*//' \
  || true)"
if [ -z "$BAD_URL" ]; then
  pass "域名只在天气文件里，且只用了 open-meteo / ipwho.is"
else
  fail "出现白名单外的域名："
  echo "$BAD_URL" | while IFS= read -r l; do note "$l"; done
fi

# ─────────────────────────────────────────────────────────────
# 2. 反遥测：出现即拦。这类代码一旦进来，用户是察觉不到的
# ─────────────────────────────────────────────────────────────
echo
echo "[2] 遥测 / 统计 SDK"
TRACK="$(grep -rniE 'analytics|telemetry|mixpanel|amplitude|sentry|bugsnag|firebase|umeng|友盟|appsflyer|adjust\.com|fingerprint' \
  --include='*.swift' --include='*.js' src 2>/dev/null || true)"
if [ -z "$TRACK" ]; then
  pass "没有埋点 / 崩溃上报 / 统计 SDK"
else
  fail "出现疑似遥测代码："
  echo "$TRACK" | while IFS= read -r l; do note "$l"; done
fi

# ─────────────────────────────────────────────────────────────
# 3. 隐私面锁：Info.plist 里的权限说明只能减少，不能悄悄增加
#    新增一项就代表"这个 app 又要多看用户一个东西"，必须显式改这个名单
# ─────────────────────────────────────────────────────────────
echo
echo "[3] 权限面"
ALLOWED_KEYS='CFBundleIconFile|CFBundleName|CFBundleDisplayName|CFBundleExecutable|CFBundleIdentifier|CFBundleInfoDictionaryVersion|CFBundlePackageType|CFBundleShortVersionString|CFBundleVersion|LSMinimumSystemVersion|NSCalendarsUsageDescription|NSCalendarsFullAccessUsageDescription|NSRemindersUsageDescription|NSRemindersFullAccessUsageDescription|LSUIElement|NSHighResolutionCapable|NSHumanReadableCopyright|LSApplicationCategoryType|NSAppleEventsUsageDescription|CFBundleDevelopmentRegion'
EXTRA_KEYS="$(grep -oE '<key>[^<]+</key>' src/Info.plist | sed -E 's/<\/?key>//g' \
  | grep -vE "^($ALLOWED_KEYS)$" || true)"
if [ -z "$EXTRA_KEYS" ]; then
  pass "Info.plist 没有新增权限（只有日历 / 提醒事项，且都是只读）"
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
  TRACKED="$(git ls-files | grep -E '(^|/)(data\.json|data\.json\.bak|focus\.json|data\.corrupt-[0-9-]+\.json|data\.backup-[0-9-]+\.json)$|\.(p12|pem|key|keychain|keychain-db)$|\.desktodo-signing-pass$|^dist/|^build/|^\.snapshot/' || true)"
  if [ -z "$TRACKED" ]; then
    pass "已跟踪文件里没有数据文件 / 密钥 / 构建产物"
  else
    fail "这些文件被 git 跟踪了，必须移除："
    echo "$TRACKED" | while IFS= read -r l; do note "$l"; done
  fi
else
  note "（还不是 git 仓库，跳过跟踪检查）"
fi

if [ -f .gitignore ] && grep -qE '^build/' .gitignore && grep -qE '^dist/' .gitignore \
   && grep -qE 'data\.json' .gitignore && grep -qE 'keychain' .gitignore; then
  pass ".gitignore 覆盖构建产物 / 导出包 / 数据 / 钥匙串"
else
  fail ".gitignore 不完整（至少要挡 build/ dist/ data.json *.keychain*）"
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
#    所以这里锁的是"只许有一份"，不是"算术对不对"（那个由 check.js 管）。
# ─────────────────────────────────────────────────────────────
echo
echo "[6] 统计口径"
D1="$(grep -rcE '^  function dayDone' --include='*.js' src/js 2>/dev/null | grep -v ':0' | wc -l | tr -d ' ')"
D2="$(grep -rcE '^  function dayObserved' --include='*.js' src/js 2>/dev/null | grep -v ':0' | wc -l | tr -d ' ')"
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

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m边界审计全部通过\033[0m\n'
  exit 0
fi
printf '\033[31m边界审计失败 %d 项 —— 不要发版\033[0m\n' "$FAIL"
exit 1
