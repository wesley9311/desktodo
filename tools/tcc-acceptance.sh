#!/bin/bash
# DeskTodo 真机 TCC 验收取证（v3，多阶段）—— 只允许在"隔离测试机/VM"内运行。
#
# 安全闸门（任一不满足即非零退出，绝不输出误导性 PASS）：
#   1. 必须有 /etc/desktodo-tcc-isolated，且内容与 --test-machine-id 完全一致；
#   2. 不使用 --i-am-in-vm 之类自述开关；
#   3. prepare 阶段若检测到真实安装/真实数据目录/登录项/运行中实例 → exit 4；
#   4. 不覆盖已有安装，不做 rm -rf；
#   5. identity.env 按字段白名单解析，绝不 source/eval；
#   6. 签名、候选身份一致性、授权实际返回、读取条数、重启保持均为硬性条件。
#
# 阶段：
#   prepare  校验 dmg/签名/entitlements → 记录身份与起始时间 → 安装 → 启动
#   collect  仅采集"本次测试启动之后"的 EventKit/tccd 证据 → 硬判定
#   restart  退出 + 重启 → 验证授权保持（无新弹窗、仍能读取）
#   denial   重置 TCC → 启动 → 人工点"不允许" → 验证不崩溃、不误报连接成功
#   screenshot <name>  截图存证（若系统允许）
#
# 用法（隔离测试机）：
#   sudo sh -c 'uuidgen > /etc/desktodo-tcc-isolated'
#   ID="$(sudo cat /etc/desktodo-tcc-isolated)"
#   EXPECTED_SHA=<dmg sha256> ./tools/tcc-acceptance.sh prepare --test-machine-id "${ID}" \
#       --dmg /path/DeskTodo-0.1.1-universal-local.dmg --evidence-dir ~/DeskTodo-TCC-evidence
#   # 人工：允许日历/提醒 + 菜单「数据来源」读取一次 + 建 1 事件 1 提醒
#   ./tools/tcc-acceptance.sh collect --test-machine-id "${ID}" --evidence-dir ~/DeskTodo-TCC-evidence
#   ./tools/tcc-acceptance.sh restart --test-machine-id "${ID}" --evidence-dir ~/DeskTodo-TCC-evidence
#   ./tools/tcc-acceptance.sh denial  --test-machine-id "${ID}" --evidence-dir ~/DeskTodo-TCC-evidence
#
# 退出码：0 通过；2 参数/环境错误；3 隔离标识问题；4 检测到真实安装/数据/实例；5 判定失败。
set -uo pipefail

MARKER="/etc/desktodo-tcc-isolated"
APP="/Applications/DeskTodo.app"
DATA="${HOME}/Library/Application Support/DeskTodo"
AGENT="${HOME}/Library/LaunchAgents/local.desktodo.plist"
MODE=""; TEST_ID=""; DMG=""; EVID=""; EXPECTED_SHA="${EXPECTED_SHA:-}"
REQUIRE_EVENTS="${REQUIRE_EVENTS:-1}"; MNT=""

die() { local code="$1"; shift; echo "ERROR: $*" >&2; echo "PHASE_$(printf '%s' "${MODE:-UNKNOWN}" | tr '[:lower:]' '[:upper:]')_FAIL"; exit "${code}"; }
note() { echo "  · $*"; }
okc() { echo "  ✓ $*"; }

cleanup() { [ -n "${MNT}" ] && [ -d "${MNT}" ] && { hdiutil detach "${MNT}" -quiet >/dev/null 2>&1 || true; rmdir "${MNT}" 2>/dev/null || true; }; }
trap cleanup EXIT

if [ $# -eq 0 ]; then sed -n '2,32p' "$0"; exit 2; fi
MODE="$1"; shift
case "${MODE}" in
  prepare|collect|restart|denial) ;;
  screenshot) ;;
  *) die 2 "未知阶段：${MODE}" ;;
esac
SS_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --test-machine-id) TEST_ID="${2:-}"; shift 2 ;;
    --dmg) DMG="${2:-}"; shift 2 ;;
    --evidence-dir) EVID="${2:-}"; shift 2 ;;
    --require-events) REQUIRE_EVENTS="${2:-1}"; shift 2 ;;
    --name) SS_NAME="${2:-}"; shift 2 ;;
    *) die 2 "未知参数：$1" ;;
  esac
done

# ── 隔离闸门 ─────────────────────────────────────────────
[ -n "${TEST_ID}" ] || die 2 "必须提供 --test-machine-id（取自 ${MARKER}）"
[ -f "${MARKER}" ] || die 3 "缺少隔离测试机标识 ${MARKER}；本机不是已声明的隔离测试机"
MARKER_ID="$(tr -d '[:space:]' < "${MARKER}" 2>/dev/null || true)"
[ -n "${MARKER_ID}" ] || die 3 "标识文件为空"
[ "${MARKER_ID}" = "${TEST_ID}" ] || die 3 "标识不匹配：文件=${MARKER_ID} 参数=${TEST_ID}"
[ -z "${EVID}" ] && EVID="${HOME}/DeskTodo-TCC-evidence"
mkdir -p "${EVID}" || die 2 "无法创建证据目录 ${EVID}"

refuse() { echo "检测到疑似真实主机状态：$1" >&2; die 4 "拒绝运行（隔离测试机不允许存在真实安装/数据/实例）"; }
check_no_real_state() {
  [ -e "${APP}" ]   && refuse "已存在 ${APP}"
  [ -e "${DATA}" ]  && refuse "已存在真实数据目录 ${DATA}"
  [ -e "${AGENT}" ] && refuse "已存在登录项 ${AGENT}"
  pgrep -f "DeskTodo.app/Contents/MacOS/DeskTodo" >/dev/null 2>&1 && refuse "已有 DeskTodo 在运行"
  return 0
}
check_app_exists() { [ -d "${APP}" ] || die 4 "未检测到测试安装 ${APP}（请先跑 prepare）"; }

app_field() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
app_cdhash() { codesign -dvvv "$1" 2>&1 | grep -o 'CDHash=[0-9a-f]*' | head -1 | cut -d= -f2; }
check_entitlements() {
  local app="$1" ent; ent="$(codesign -d --entitlements :- "${app}" 2>/dev/null || true)"
  case "${ent}" in *com.apple.security.personal-information.calendars*) ;; *) return 1 ;; esac
  case "${ent}" in *com.apple.security.personal-information.reminders*) ;; *) return 1 ;; esac
  return 0
}
validate_sha()   { case "$1" in *[!0-9a-f]*|'') return 1 ;; esac; [ ${#1} -eq 64 ]; }
validate_ver()   { case "$1" in ''|*[!0-9A-Za-z.-]*) return 1 ;; esac; }
validate_build() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
validate_bid()   { case "$1" in ''|*[!A-Za-z0-9.-]*) return 1 ;; esac; }
validate_hash()  { case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac; }

# identity.env 安全解析（只认白名单字段，不 source、不 eval）
read_identity() {
  local f="${EVID}/identity.env" line k v
  [ -f "${f}" ] || die 2 "缺少 identity.env（请先跑 prepare）"
  ID_SHA=""; ID_VERSION=""; ID_BUILD=""; ID_BID=""; ID_CDHASH=""
  ID_START_ISO=""; ID_START_UTC_KEY=""; ID_START_LOCAL=""; ID_START_EPOCH=""; ID_MACHINE=""
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in ''|'#'*) continue ;; esac
    case "${line}" in *=*) ;; *) die 2 "identity.env 行格式非法" ;; esac
    k="${line%%=*}"; v="${line#*=}"
    case "${k}" in
      EXPECTED_SHA) validate_sha "${v}" || die 2 "identity.env: EXPECTED_SHA 非法"; ID_SHA="${v}" ;;
      VERSION) validate_ver "${v}" || die 2 "identity.env: VERSION 非法"; ID_VERSION="${v}" ;;
      BUILD) validate_build "${v}" || die 2 "identity.env: BUILD 非法"; ID_BUILD="${v}" ;;
      BUNDLE_ID) validate_bid "${v}" || die 2 "identity.env: BUNDLE_ID 非法"; ID_BID="${v}" ;;
      CDHASH) validate_hash "${v}" || die 2 "identity.env: CDHASH 非法"; ID_CDHASH="${v}" ;;
      TEST_START_ISO) ID_START_ISO="${v}" ;;
      TEST_START_UTC_KEY) printf '%s' "${v}" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' || die 2 "identity.env: 起始时间格式非法"; ID_START_UTC_KEY="${v}" ;;
      TEST_START_LOCAL) printf '%s' "${v}" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' || die 2 "identity.env: 本地起始时间格式非法"; ID_START_LOCAL="${v}" ;;
      TEST_START_EPOCH) validate_build "${v}" || die 2 "identity.env: EPOCH 非法"; ID_START_EPOCH="${v}" ;;
      TEST_MACHINE_ID) ID_MACHINE="${v}" ;;
      *) die 2 "identity.env 含未知字段：${k}" ;;
    esac
  done < "${f}"
  [ -n "${ID_SHA}${ID_VERSION}${ID_BUILD}${ID_BID}${ID_CDHASH}${ID_START_UTC_KEY}${ID_START_LOCAL}" ] || die 2 "identity.env 字段不完整"
  [ "${ID_MACHINE}" = "${TEST_ID}" ] || die 3 "identity.env 的测试机标识与本次不一致"
}

# 只保留"本次测试启动之后"的日志行（同一 UTC 格式，字符串比较即可）
filter_since() {  # $1=file  $2="YYYY-MM-DD HH:MM:SS" UTC
  awk -v start="$2" '{ k=$1" "$2; if (k >= start) print }' "$1"
}

verify_installed_identity() {
  check_app_exists
  [ "$(app_field "${APP}" CFBundleShortVersionString)" = "${ID_VERSION}" ] || die 4 "已安装版本不一致"
  [ "$(app_field "${APP}" CFBundleVersion)" = "${ID_BUILD}" ] || die 4 "已安装构建号不一致"
  [ "$(app_field "${APP}" CFBundleIdentifier)" = "${ID_BID}" ] || die 4 "已安装 Bundle ID 不一致"
  codesign --verify --strict "${APP}" >/dev/null 2>&1 || die 5 "已安装应用签名校验失败"
  local cdh; cdh="$(app_cdhash "${APP}")"
  [ -n "${cdh}" ] && [ "${cdh}" = "${ID_CDHASH}" ] || die 5 "已安装应用 CDHash 与候选不一致（${cdh} != ${ID_CDHASH}）"
  check_entitlements "${APP}" || die 5 "已安装应用签名缺少日历/提醒 entitlements"
  return 0
}

verdict_reset() { : > "${EVID}/$1"; }
claim_ok()   { echo "  ✓ $1" | tee -a "${EVID}/$2" >/dev/null; }
claim_fail() { echo "  ✗ $1" | tee -a "${EVID}/$2" >/dev/null; FAILS=$((FAILS+1)); }

# ═══════════════════ prepare ═══════════════════
if [ "${MODE}" = "prepare" ]; then
  [ -n "${DMG}" ] || die 2 "prepare 需要 --dmg"
  [ -f "${DMG}" ] || die 2 "dmg 不存在：${DMG}"
  [ -n "${EXPECTED_SHA}" ] || die 2 "prepare 需要 EXPECTED_SHA（非空）"
  check_no_real_state
  ACTUAL_SHA="$(shasum -a 256 "${DMG}" | awk '{print $1}')"
  [ "${ACTUAL_SHA}" = "${EXPECTED_SHA}" ] || die 5 "dmg sha256 不一致"
  note "dmg sha256 一致"

  MNT="$(mktemp -d /tmp/dt-tcc-mnt.XXXXXX)"
  hdiutil attach "${DMG}" -nobrowse -mountpoint "${MNT}" -quiet || die 5 "dmg 挂载失败"
  SRC_APP="${MNT}/DeskTodo.app"; [ -d "${SRC_APP}" ] || die 5 "dmg 内没有 DeskTodo.app"
  SRC_CDHASH="$(app_cdhash "${SRC_APP}")"
  [ -n "${SRC_CDHASH}" ] || die 5 "无法读取候选 CDHash"
  check_entitlements "${SRC_APP}" || die 5 "候选签名缺少 entitlements"

  START_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  START_UTC_KEY="$(date -u +"%Y-%m-%d %H:%M:%S")"
  START_LOCAL="$(date +"%Y-%m-%d %H:%M:%S")"
  START_EPOCH="$(date +%s)"
  {
    echo "== 时间 =="; echo "${START_ISO}"; date
    echo "== 系统 =="; sw_vers; uname -a
    echo "== 隔离标识 =="; echo "marker=${MARKER_ID}"
    echo "== dmg =="; shasum -a 256 "${DMG}"
    echo "== 版本/构建号/BundleID/CDHash =="
    app_field "${SRC_APP}" CFBundleShortVersionString; app_field "${SRC_APP}" CFBundleVersion; app_field "${SRC_APP}" CFBundleIdentifier; echo "CDHash=${SRC_CDHASH}"
    echo "== 签名 =="; codesign -dv --verbose=4 "${SRC_APP}" 2>&1 | grep -E "Identifier|Format|Signature|Runtime Version|flags"
    echo "== hardened runtime =="; codesign -d --verbose=2 "${SRC_APP}" 2>&1 | grep -i runtime || echo "（未显示）"
    echo "== entitlements =="; codesign -d --entitlements :- "${SRC_APP}" 2>&1
    echo "== spctl（ad-hoc 预期 rejected）=="; spctl -a -vv "${SRC_APP}" 2>&1 || true
    echo "== 架构/minos =="; lipo -info "${SRC_APP}/Contents/MacOS/DeskTodo" 2>&1; vtool -show-build "${SRC_APP}/Contents/MacOS/DeskTodo" 2>/dev/null | grep minos
  } > "${EVID}/01-artifact.txt" 2>&1
  {
    echo "EXPECTED_SHA=${ACTUAL_SHA}"
    echo "VERSION=$(app_field "${SRC_APP}" CFBundleShortVersionString)"
    echo "BUILD=$(app_field "${SRC_APP}" CFBundleVersion)"
    echo "BUNDLE_ID=$(app_field "${SRC_APP}" CFBundleIdentifier)"
    echo "CDHASH=${SRC_CDHASH}"
    echo "TEST_START_ISO=${START_ISO}"
    echo "TEST_START_UTC_KEY=${START_UTC_KEY}"
    echo "TEST_START_LOCAL=${START_LOCAL}"
    echo "TEST_START_EPOCH=${START_EPOCH}"
    echo "TEST_MACHINE_ID=${TEST_ID}"
  } > "${EVID}/identity.env"
  note "候选身份与测试起始时间已记录"

  ditto "${SRC_APP}" "${APP}" || die 5 "安装失败"
  codesign --verify --strict "${APP}" || die 5 "安装后签名校验失败"
  [ "$(app_cdhash "${APP}")" = "${SRC_CDHASH}" ] || die 5 "安装后 CDHash 变化"
  okc "已安装（未覆盖任何已有安装）"
  pkill -f "DeskTodo.app/Contents/MacOS/DeskTodo" >/dev/null 2>&1 || true
  open -a "${APP}" || die 5 "启动失败"
  sleep 8
  pgrep -f "DeskTodo.app/Contents/MacOS/DeskTodo" >/dev/null 2>&1 || die 5 "启动后进程不存在"
  okc "已启动"
  cat > "${EVID}/02-next-steps.txt" <<'STEPS'
请人工完成（在隔离测试机里）：
1) 系统弹窗允许「日历」与「提醒事项」。
2) 菜单 →「数据来源」让应用读取一次。
3) 创建 ≥1 个测试日历事件 + ≥1 个测试提醒事项（不要用真实个人数据）。
4) 建议截图：两个授权弹窗、数据来源页、日历/提醒各一条。
然后运行 collect → restart → denial。
STEPS
  echo "PHASE_PREPARE_OK"; echo "证据目录：${EVID}"; exit 0
fi

# ═══════════════════ screenshot ═══════════════════
if [ "${MODE}" = "screenshot" ]; then
  [ -n "${SS_NAME}" ] || die 2 "screenshot 需要 --name"
  OUT="${EVID}/shot-${SS_NAME}.png"
  if screencapture -x "${OUT}" 2>/dev/null && [ -s "${OUT}" ]; then okc "已截图：${OUT}"; exit 0; else
    echo "!! 截图失败（可能需要屏幕录制权限）。请手动把截图放入 ${EVID}/"; echo "PHASE_SCREENSHOT_FAIL"; exit 5; fi
fi

# ═══════════════════ collect ═══════════════════
if [ "${MODE}" = "collect" ]; then
  read_identity; verify_installed_identity
  LOG="${DATA}/logs/desktodo.log"
  [ -f "${LOG}" ] || die 5 "找不到应用日志 ${LOG}（应用是否启动过？）"
  filter_since "${LOG}" "${ID_START_UTC_KEY}" | tail -800 > "${EVID}/03-eventkit-raw.txt" 2>/dev/null || : > "${EVID}/03-eventkit-raw.txt"
  grep -E "requestAccess|ext cal=|ext rem=" "${EVID}/03-eventkit-raw.txt" > "${EVID}/03-eventkit-log.txt" 2>/dev/null || : > "${EVID}/03-eventkit-log.txt"
  log show --start "${ID_START_LOCAL}" --predicate 'process == "tccd" AND (eventMessage CONTAINS[c] "deskTODO" OR eventMessage CONTAINS[c] "kTCCServiceCalendar" OR eventMessage CONTAINS[c] "kTCCServiceReminders")' 2>&1 | tail -400 > "${EVID}/04-tcc-log.txt" 2>/dev/null || : > "${EVID}/04-tcc-log.txt"
  pgrep -fl "DeskTodo.app/Contents/MacOS/DeskTodo" > "${EVID}/05-process.txt" 2>&1 || true

  VER="${EVID}/90-verdict.txt"; verdict_reset "$(basename "${VER}")"; FAILS=0
  grep -qE "requestAccess\(cal\) ok=true" "${EVID}/03-eventkit-log.txt" && claim_ok "requestAccess(cal) ok=true（实际返回）" "$(basename "${VER}")" || claim_fail "没有 requestAccess(cal) ok=true（实际授权返回）" "$(basename "${VER}")"
  grep -qE "requestAccess\(rem\) ok=true" "${EVID}/03-eventkit-log.txt" && claim_ok "requestAccess(rem) ok=true（实际返回）" "$(basename "${VER}")" || claim_fail "没有 requestAccess(rem) ok=true" "$(basename "${VER}")"
  CAL_LINE="$(grep -oE 'ext cal=ok/[0-9]+/[0-9]+d?' "${EVID}/03-eventkit-log.txt" | tail -1 || true)"
  REM_LINE="$(grep -oE 'ext rem=ok/[0-9]+/[0-9]+d?' "${EVID}/03-eventkit-log.txt" | tail -1 || true)"
  CAL_N="$(printf '%s' "${CAL_LINE}" | grep -oE 'ok/[0-9]+/' | head -1 | tr -dc '0-9' || true)"
  REM_N="$(printf '%s' "${REM_LINE}" | grep -oE 'ok/[0-9]+/' | head -1 | tr -dc '0-9' || true)"
  [ -n "${CAL_N}" ] && [ "${CAL_N}" -ge "${REQUIRE_EVENTS}" ] 2>/dev/null && claim_ok "日历读取 ${CAL_N} 条（本次启动后）" "$(basename "${VER}")" || claim_fail "日历读取条数不足（${CAL_N:-无}，要求 ≥${REQUIRE_EVENTS}）" "$(basename "${VER}")"
  [ -n "${REM_N}" ] && [ "${REM_N}" -ge "${REQUIRE_EVENTS}" ] 2>/dev/null && claim_ok "提醒事项读取 ${REM_N} 条（本次启动后）" "$(basename "${VER}")" || claim_fail "提醒读取条数不足（${REM_N:-无}，要求 ≥${REQUIRE_EVENTS}）" "$(basename "${VER}")"
  grep -qiE "Prompting policy" "${EVID}/04-tcc-log.txt" && claim_ok "tccd 记录到授权弹窗（Prompting policy）" "$(basename "${VER}")" || claim_fail "tccd 未记录授权弹窗（无法证明弹窗出现）" "$(basename "${VER}")"
  grep -qiE "requires entitlement" "${EVID}/04-tcc-log.txt" && claim_fail "tccd 出现 entitlement 缺失（P0-1 未修复）" "$(basename "${VER}")" || claim_ok "tccd 无 entitlement 缺失" "$(basename "${VER}")"
  grep -iE "kTCCService(Calendar|Reminders)" "${EVID}/04-tcc-log.txt" | grep -qi "denied" && claim_fail "tccd 对日历/提醒出现 denied" "$(basename "${VER}")" || claim_ok "tccd 对日历/提醒无 denied" "$(basename "${VER}")"
  echo "== 判定（collect）==" >> "${VER}"
  if [ "${FAILS}" -gt 0 ]; then echo "PHASE_COLLECT_FAIL (fails=${FAILS})"; echo "证据：${EVID}"; exit 5; fi
  echo "PHASE_COLLECT_OK"; echo "证据：${EVID}"; exit 0
fi

# ═══════════════════ restart ═══════════════════
if [ "${MODE}" = "restart" ]; then
  read_identity; verify_installed_identity
  [ -f "${EVID}/90-verdict.txt" ] && ! grep -q "✗" "${EVID}/90-verdict.txt" || die 5 "collect 未通过，不能做重启保持测试"
  osascript -e 'tell application "DeskTodo" to quit' >/dev/null 2>&1 || true
  sleep 3
  pkill -f "DeskTodo.app/Contents/MacOS/DeskTodo" >/dev/null 2>&1 || true
  sleep 2
  pgrep -f "DeskTodo.app/Contents/MacOS/DeskTodo" >/dev/null 2>&1 && die 5 "退出失败，进程仍在"
  okc "已退出"
  R_START_UTC_KEY="$(date -u +"%Y-%m-%d %H:%M:%S")"
  R_START_LOCAL="$(date +"%Y-%m-%d %H:%M:%S")"
  open -a "${APP}" || die 5 "重启失败"
  sleep 10
  pgrep -f "DeskTodo.app/Contents/MacOS/DeskTodo" >/dev/null 2>&1 || die 5 "重启后进程不存在"
  okc "已重启"
  LOG="${DATA}/logs/desktodo.log"
  filter_since "${LOG}" "${R_START_UTC_KEY}" | tail -400 > "${EVID}/06-restart-log.txt"
  log show --start "${R_START_LOCAL}" --predicate 'process == "tccd" AND (eventMessage CONTAINS[c] "deskTODO" OR eventMessage CONTAINS[c] "kTCCServiceCalendar" OR eventMessage CONTAINS[c] "kTCCServiceReminders")' 2>&1 | tail -200 > "${EVID}/06-restart-tcc.txt" 2>/dev/null || : > "${EVID}/06-restart-tcc.txt"
  VER="${EVID}/91-restart-verdict.txt"; verdict_reset "$(basename "${VER}")"; FAILS=0
  grep -qE "ext cal=ok/[0-9]+/" "${EVID}/06-restart-log.txt" && claim_ok "重启后日历仍可读取（授权保持）" "$(basename "${VER}")" || claim_fail "重启后日历不可读（授权未保持）" "$(basename "${VER}")"
  grep -qiE "Prompting policy" "${EVID}/06-restart-tcc.txt" && claim_fail "重启后再次出现授权弹窗（应保持已授权）" "$(basename "${VER}")" || claim_ok "重启后无新的授权弹窗" "$(basename "${VER}")"
  if [ "${FAILS}" -gt 0 ]; then echo "PHASE_RESTART_FAIL (fails=${FAILS})"; exit 5; fi
  echo "PHASE_RESTART_OK"; exit 0
fi

# ═══════════════════ denial ═══════════════════
if [ "${MODE}" = "denial" ]; then
  read_identity; verify_installed_identity
  osascript -e 'tell application "DeskTodo" to quit' >/dev/null 2>&1 || true
  sleep 2; pkill -f "DeskTodo.app/Contents/MacOS/DeskTodo" >/dev/null 2>&1 || true
  tccutil reset Calendar "${ID_BID}" >/dev/null 2>&1 || true
  tccutil reset Reminders "${ID_BID}" >/dev/null 2>&1 || true
  D_START_UTC_KEY="$(date -u +"%Y-%m-%d %H:%M:%S")"
  open -a "${APP}" || die 5 "启动失败"
  echo "请在弹窗上点「不允许」（日历与提醒各一次），最多等待 180 秒……"
  LOG="${DATA}/logs/desktodo.log"
  SECS=0
  while [ "${SECS}" -lt 180 ]; do
    if [ -f "${LOG}" ] && filter_since "${LOG}" "${D_START_UTC_KEY}" | grep -qE "requestAccess\((cal|rem)\) ok=false"; then break; fi
    sleep 5; SECS=$((SECS+5))
  done
  pgrep -f "DeskTodo.app/Contents/MacOS/DeskTodo" >/dev/null 2>&1 && ALIVE=1 || ALIVE=0
  filter_since "${LOG}" "${D_START_UTC_KEY}" | tail -300 > "${EVID}/07-denial-log.txt"
  VER="${EVID}/92-denial-verdict.txt"; verdict_reset "$(basename "${VER}")"; FAILS=0
  [ "${ALIVE}" = "1" ] && claim_ok "拒绝授权后应用仍在运行（未崩溃）" "$(basename "${VER}")" || claim_fail "拒绝授权后应用不在运行（疑似崩溃）" "$(basename "${VER}")"
  grep -qE "requestAccess\((cal|rem)\) ok=false" "${EVID}/07-denial-log.txt" && claim_ok "记录到实际拒绝返回 ok=false" "$(basename "${VER}")" || claim_fail "未记录到 ok=false（可能未拒绝或未触发请求）" "$(basename "${VER}")"
  grep -qE "ext cal=ok/|ext rem=ok/" "${EVID}/07-denial-log.txt" && claim_fail "拒绝后仍出现 ok 读取（错误宣称连接成功）" "$(basename "${VER}")" || claim_ok "拒绝后没有错误宣称读取成功" "$(basename "${VER}")"
  if [ "${FAILS}" -gt 0 ]; then echo "PHASE_DENIAL_FAIL (fails=${FAILS})"; exit 5; fi
  echo "PHASE_DENIAL_OK"; exit 0
fi
