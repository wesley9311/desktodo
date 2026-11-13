#!/bin/bash
# DeskTodo 真机 TCC 验收取证（v4，多阶段 + 纯函数判定）—— 只允许在"隔离测试机/VM"内运行。
#
# 真实日志格式（src/AppDelegate+Sources.swift:200-201，单行）：
#   <Date()> ext cal=<st>/<N>/<D>d rem=<st>/<Open>open/<Late>late screen=...
# 注意：提醒在同一行，字段是 "rem=ok/Nopen/Mlate"，没有 "ext rem=" 前缀。
#
# 安全闸门（任一不满足即非零退出，绝不输出误导性 PASS）：
#   1. 必须有 /etc/desktodo-tcc-isolated，且内容与 --test-machine-id 完全一致；
#   2. prepare 阶段检测到真实安装/数据目录/登录项/运行中实例 → exit 4；
#   3. 不覆盖已有安装、不做 rm -rf；
#   4. identity.env 按字段白名单严格解析（重复键/空值/未知字段/格式错都拒绝），不 source/eval；
#   5. 签名、CDHash、版本/构建号/BundleID、授权实际回调、cal/rem 读取、重启保持、拒绝路径均为硬性条件。
#
# 阶段：prepare / collect / restart / denial / screenshot <name>
# 退出码：0 通过；2 参数/环境错误；3 隔离标识问题；4 真实安装/数据/实例；5 判定失败。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/tcc-log-parse.sh"

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

if [ $# -eq 0 ]; then sed -n '2,24p' "$0"; exit 2; fi
MODE="$1"; shift
case "${MODE}" in prepare|collect|restart|denial|screenshot) ;; *) die 2 "未知阶段：${MODE}" ;; esac
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
[ "${MARKER_ID}" = "${TEST_ID}" ] || die 3 "标识不匹配"
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
verify_installed_identity() {
  check_app_exists
  [ "$(app_field "${APP}" CFBundleShortVersionString)" = "${ID_VERSION}" ] || die 4 "已安装版本不一致"
  [ "$(app_field "${APP}" CFBundleVersion)" = "${ID_BUILD}" ] || die 4 "已安装构建号不一致"
  [ "$(app_field "${APP}" CFBundleIdentifier)" = "${ID_BID}" ] || die 4 "已安装 Bundle ID 不一致"
  codesign --verify --strict "${APP}" >/dev/null 2>&1 || die 5 "已安装应用签名校验失败"
  local cdh; cdh="$(app_cdhash "${APP}")"
  [ -n "${cdh}" ] && [ "${cdh}" = "${ID_CDHASH}" ] || die 5 "已安装应用 CDHash 与候选不一致（${cdh} != ${ID_CDHASH}）"
  check_entitlements "${APP}" || die 5 "已安装应用缺少日历/提醒 entitlements"
  return 0
}
load_identity() { tcc_read_identity "${EVID}/identity.env" "${TEST_ID}" || die 2 "identity.env 校验失败"; }

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
  SRC_CDHASH="$(app_cdhash "${SRC_APP}")"; [ -n "${SRC_CDHASH}" ] || die 5 "无法读取候选 CDHash"
  check_entitlements "${SRC_APP}" || die 5 "候选签名缺少 entitlements"

  START_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
    echo "TEST_START_UTC_KEY=$(date -u +"%Y-%m-%d %H:%M:%S")"
    echo "TEST_START_LOCAL=$(date +"%Y-%m-%d %H:%M:%S")"
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
请人工完成：
1) 系统弹窗允许「日历」与「提醒事项」。
2) 菜单 →「数据来源」读取一次。
3) 创建 ≥1 个测试日历事件 + ≥1 个测试提醒事项（不要用真实个人数据）。
4) 截图两个授权弹窗、数据来源页、日历/提醒各一条，放入本证据目录（shot-*.png）。
然后依次运行 collect → restart → denial。
STEPS
  echo "PHASE_PREPARE_OK"; echo "证据目录：${EVID}"; exit 0
fi

# ═══════════════════ screenshot ═══════════════════
if [ "${MODE}" = "screenshot" ]; then
  [ -n "${SS_NAME}" ] || die 2 "screenshot 需要 --name"
  OUT="${EVID}/shot-${SS_NAME}.png"
  if screencapture -x "${OUT}" 2>/dev/null && [ -s "${OUT}" ]; then okc "已截图：${OUT}"; exit 0; fi
  echo "!! 截图失败（可能需要屏幕录制权限）。请手动把截图放入 ${EVID}/"; echo "PHASE_SCREENSHOT_FAIL"; exit 5
fi

# ═══════════════════ collect ═══════════════════
if [ "${MODE}" = "collect" ]; then
  load_identity; verify_installed_identity
  LOG="${DATA}/logs/desktodo.log"
  [ -f "${LOG}" ] || die 5 "找不到应用日志 ${LOG}（应用是否启动过？）"
  tcc_filter_since "${LOG}" "${ID_START_EPOCH}" > "${EVID}/03-eventkit-raw.txt" || : > "${EVID}/03-eventkit-raw.txt"
  tail -800 "${EVID}/03-eventkit-raw.txt" > "${EVID}/03-eventkit-log.txt"
  log show --start "${ID_START_LOCAL}" --predicate 'process == "tccd" AND (eventMessage CONTAINS[c] "deskTodo" OR eventMessage CONTAINS[c] "kTCCServiceCalendar" OR eventMessage CONTAINS[c] "kTCCServiceReminders")' 2>&1 | tail -400 > "${EVID}/04-tcc-log.txt" 2>/dev/null || : > "${EVID}/04-tcc-log.txt"
  pgrep -fl "DeskTodo.app/Contents/MacOS/DeskTodo" > "${EVID}/05-process.txt" 2>&1 || true

  SHOTS=0; ls "${EVID}"/shot-*.png >/dev/null 2>&1 && SHOTS=1
  TCC_FAILS=0
  if tcc_judge_collect "${EVID}/03-eventkit-log.txt" "${EVID}/04-tcc-log.txt" "${EVID}/90-verdict.txt" "${REQUIRE_EVENTS}" "${SHOTS}"; then
    echo "PHASE_COLLECT_OK"; echo "证据：${EVID}"; exit 0
  else
    echo "PHASE_COLLECT_FAIL (fails=${TCC_FAILS})"; echo "证据：${EVID}"; exit 5
  fi
fi

# ═══════════════════ restart ═══════════════════
if [ "${MODE}" = "restart" ]; then
  load_identity; verify_installed_identity
  [ -f "${EVID}/90-verdict.txt" ] && ! grep -q "✗" "${EVID}/90-verdict.txt" || die 5 "collect 未通过，不能做重启保持测试"
  osascript -e 'tell application "DeskTodo" to quit' >/dev/null 2>&1 || true
  sleep 3; pkill -f "DeskTodo.app/Contents/MacOS/DeskTodo" >/dev/null 2>&1 || true; sleep 2
  pgrep -f "DeskTodo.app/Contents/MacOS/DeskTodo" >/dev/null 2>&1 && die 5 "退出失败，进程仍在"
  okc "已退出"
  R_EPOCH="$(date +%s)"; R_LOCAL="$(date +"%Y-%m-%d %H:%M:%S")"
  open -a "${APP}" || die 5 "重启失败"
  sleep 10
  pgrep -f "DeskTodo.app/Contents/MacOS/DeskTodo" >/dev/null 2>&1 || die 5 "重启后进程不存在"
  okc "已重启"
  LOG="${DATA}/logs/desktodo.log"
  tcc_filter_since "${LOG}" "${R_EPOCH}" > "${EVID}/06-restart-log.txt"
  log show --start "${R_LOCAL}" --predicate 'process == "tccd" AND (eventMessage CONTAINS[c] "deskTODO" OR eventMessage CONTAINS[c] "kTCCServiceCalendar" OR eventMessage CONTAINS[c] "kTCCServiceReminders")' 2>&1 | tail -200 > "${EVID}/06-restart-tcc.txt" 2>/dev/null || : > "${EVID}/06-restart-tcc.txt"
  TCC_FAILS=0
  if tcc_judge_restart "${EVID}/06-restart-log.txt" "${EVID}/06-restart-tcc.txt" "${EVID}/91-restart-verdict.txt" "${REQUIRE_EVENTS}"; then
    echo "PHASE_RESTART_OK"; exit 0
  else
    echo "PHASE_RESTART_FAIL (fails=${TCC_FAILS})"; exit 5
  fi
fi

# ═══════════════════ denial ═══════════════════
if [ "${MODE}" = "denial" ]; then
  load_identity; verify_installed_identity
  osascript -e 'tell application "DeskTodo" to quit' >/dev/null 2>&1 || true
  sleep 2; pkill -f "DeskTodo.app/Contents/MacOS/DeskTodo" >/dev/null 2>&1 || true
  tccutil reset Calendar "${ID_BID}" >/dev/null 2>&1 || true
  tccutil reset Reminders "${ID_BID}" >/dev/null 2>&1 || true
  D_EPOCH="$(date +%s)"; D_LOCAL="$(date +"%Y-%m-%d %H:%M:%S")"
  open -a "${APP}" || die 5 "启动失败"
  echo "请在弹窗上点「不允许」（日历与提醒各一次），最多等待 180 秒……"
  LOG="${DATA}/logs/desktodo.log"
  SECS=0
  while [ "${SECS}" -lt 180 ]; do
    if [ -f "${LOG}" ] && tcc_filter_since "${LOG}" "${D_EPOCH}" | grep -qE 'requestAccess\((cal|rem)\) ok=false'; then break; fi
    sleep 5; SECS=$((SECS+5))
  done
  pgrep -f "DeskTodo.app/Contents/MacOS/DeskTodo" >/dev/null 2>&1 && ALIVE=1 || ALIVE=0
  tcc_filter_since "${LOG}" "${D_EPOCH}" > "${EVID}/07-denial-log.txt"
  log show --start "${D_LOCAL}" --predicate 'process == "tccd" AND (eventMessage CONTAINS[c] "deskTODO" OR eventMessage CONTAINS[c] "kTCCServiceCalendar" OR eventMessage CONTAINS[c] "kTCCServiceReminders")' 2>&1 | tail -200 > "${EVID}/07-denial-tcc.txt" 2>/dev/null || : > "${EVID}/07-denial-tcc.txt"
  TCC_FAILS=0
  if tcc_judge_denial "${EVID}/07-denial-log.txt" "${ALIVE}" "${EVID}/92-denial-verdict.txt"; then
    echo "PHASE_DENIAL_OK"; exit 0
  else
    echo "PHASE_DENIAL_FAIL (fails=${TCC_FAILS})"; exit 5
  fi
fi
