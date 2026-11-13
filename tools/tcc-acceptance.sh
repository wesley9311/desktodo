#!/bin/bash
# DeskTodo 真机 TCC 验收取证脚本（两阶段）—— 只允许在"隔离测试机/VM"里运行。
#
# 安全设计（任何一条不满足都非零退出，绝不输出会误导的 DONE/PASS）：
#   1. 必须存在显式的隔离测试机标识文件 /etc/desktodo-tcc-isolated，且内容与 --test-machine-id 完全一致；
#   2. 不再接受 --i-am-in-vm 这种"自述式"开关；
#   3. 准备阶段：目标 /Applications/DeskTodo.app 必须不存在；真实数据目录、登录项、运行中实例任一存在即拒绝；
#   4. 不再无条件 rm -rf 安装目录，也不覆盖任何已有安装；
#   5. 两阶段：
#        prepare  —— 校验产物、安装测试应用、启动并提示你完成授权与创建测试事件；
#        collect  —— 用户完成授权/造数后，再采集 EventKit 与 tccd 证据并做通过判定。
#
# 用法（都在隔离测试机内）：
#   # 一次性建立标识（需要管理员，明确表示这是隔离机）
#   sudo sh -c 'uuidgen > /etc/desktodo-tcc-isolated'
#   ID="$(sudo cat /etc/desktodo-tcc-isolated)"
#
#   # 阶段 A
#   EXPECTED_SHA=<dmg sha256> ./tools/tcc-acceptance.sh prepare \
#       --test-machine-id "${ID}" --dmg /path/DeskTodo-0.1.1-universal-local.dmg \
#       --evidence-dir ~/DeskTodo-TCC-evidence
#
#   # 按提示在系统弹窗里允许日历/提醒，并创建至少 1 个日历事件 + 1 个提醒事项
#
#   # 阶段 B
#   ./tools/tcc-acceptance.sh collect \
#       --test-machine-id "${ID}" --evidence-dir ~/DeskTodo-TCC-evidence
#
# 退出码：0 通过；2 参数/环境错误；3 隔离标识不匹配；4 检测到真实安装/数据/实例；5 验收判定失败。
set -uo pipefail

MARKER="/etc/desktodo-tcc-isolated"
APP="/Applications/DeskTodo.app"
DATA="${HOME}/Library/Application Support/DeskTodo"
AGENT="${HOME}/Library/LaunchAgents/local.desktodo.plist"
EVID=""
MODE=""
TEST_ID=""
DMG=""
EXPECTED_SHA="${EXPECTED_SHA:-}"
REQUIRE_EVENTS="${REQUIRE_EVENTS:-1}"
MNT=""

die() { local code="$1"; shift; echo "ERROR: $*" >&2; echo "PHASE_$(printf '%s' "${MODE:-UNKNOWN}" | tr '[:lower:]' '[:upper:]')_FAIL"; exit "${code}"; }
note() { echo "  · $*"; }
okc() { echo "  ✓ $*"; }

cleanup() { [ -n "${MNT}" ] && [ -d "${MNT}" ] && { hdiutil detach "${MNT}" -quiet >/dev/null 2>&1 || true; rmdir "${MNT}" 2>/dev/null || true; }; }
trap cleanup EXIT

if [ $# -eq 0 ]; then
  sed -n '2,30p' "$0"; exit 2
fi
case "$1" in
  prepare|collect) MODE="$1"; shift ;;
  *) die 2 "第一个参数必须是 prepare 或 collect" ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --test-machine-id) TEST_ID="${2:-}"; shift 2 ;;
    --dmg) DMG="${2:-}"; shift 2 ;;
    --evidence-dir) EVID="${2:-}"; shift 2 ;;
    --require-events) REQUIRE_EVENTS="${2:-1}"; shift 2 ;;
    *) die 2 "未知参数：$1" ;;
  esac
done

# ── 通用安全闸门 ─────────────────────────────────────────────
[ -n "${TEST_ID}" ] || die 2 "必须提供 --test-machine-id（取自 ${MARKER}）"
[ -f "${MARKER}" ] || die 3 "缺少隔离测试机标识 ${MARKER}；本机不是已声明的隔离测试机"
MARKER_ID="$(tr -d '[:space:]' < "${MARKER}" 2>/dev/null)"
[ -n "${MARKER_ID}" ] || die 3 "标识文件为空：${MARKER}"
[ "${MARKER_ID}" = "${TEST_ID}" ] || die 3 "标识不匹配：文件=${MARKER_ID} 参数=${TEST_ID}"
[ -z "${EVID}" ] && EVID="${HOME}/DeskTodo-TCC-evidence"
mkdir -p "${EVID}" || die 2 "无法创建证据目录 ${EVID}"

refuse_real_host() {
  local why="$1"
  echo "检测到疑似真实主机状态：${why}" >&2
  die 4 "拒绝运行（隔离测试机不允许存在真实安装/数据/自启实例）"
}

check_no_real_state() {
  [ -e "${APP}" ] && refuse_real_host "已存在 ${APP}"
  [ -e "${DATA}" ] && refuse_real_host "已存在真实数据目录 ${DATA}"
  [ -e "${AGENT}" ] && refuse_real_host "已存在登录项 ${AGENT}"
  pgrep -f "DeskTodo.app/Contents/MacOS/DeskTodo" >/dev/null 2>&1 && refuse_real_host "已有 DeskTodo 在运行"
  return 0
}

app_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }
app_build()   { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist" 2>/dev/null; }
app_bid()     { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null; }

check_entitlements() {
  local app="$1" ent
  ent="$(codesign -d --entitlements :- "${app}" 2>/dev/null || true)"
  case "${ent}" in *com.apple.security.personal-information.calendars*) ;; *) return 1 ;; esac
  case "${ent}" in *com.apple.security.personal-information.reminders*) ;; *) return 1 ;; esac
  printf '%s' "${ent}" > "${EVID}/01-entitlements.txt"
  return 0
}

# ═══════════════════════ 阶段 A：prepare ═══════════════════════
if [ "${MODE}" = "prepare" ]; then
  [ -n "${DMG}" ] || die 2 "prepare 需要 --dmg"
  [ -f "${DMG}" ] || die 2 "dmg 不存在：${DMG}"
  [ -n "${EXPECTED_SHA}" ] || die 2 "prepare 需要 EXPECTED_SHA（产物 sha256），不接受空值"
  check_no_real_state

  ACTUAL_SHA="$(shasum -a 256 "${DMG}" | awk '{print $1}')"
  [ "${ACTUAL_SHA}" = "${EXPECTED_SHA}" ] || die 5 "dmg sha256 不一致：${ACTUAL_SHA} != ${EXPECTED_SHA}"
  note "dmg sha256 一致"

  MNT="$(mktemp -d /tmp/dt-tcc-mnt.XXXXXX)"
  hdiutil attach "${DMG}" -nobrowse -mountpoint "${MNT}" -quiet || die 5 "dmg 挂载失败"
  SRC_APP="${MNT}/DeskTodo.app"
  [ -d "${SRC_APP}" ] || die 5 "dmg 内没有 DeskTodo.app"

  {
    echo "== 时间 =="; date -u +%Y-%m-%dT%H:%M:%SZ
    echo "== 系统 =="; sw_vers; uname -a
    echo "== 隔离标识 =="; echo "marker=${MARKER_ID}"
    echo "== dmg =="; shasum -a 256 "${DMG}"
    echo "== 版本/构建号/BundleID =="; app_version "${SRC_APP}"; app_build "${SRC_APP}"; app_bid "${SRC_APP}"
    echo "== 签名 =="; codesign -dv --verbose=4 "${SRC_APP}" 2>&1 | grep -E "Identifier|Format|CodeDirectory|Signature|Runtime Version|flags"
    echo "== hardened runtime =="; codesign -d --verbose=2 "${SRC_APP}" 2>&1 | grep -i runtime || echo "（未显示 runtime 标志）"
    echo "== entitlements =="; codesign -d --entitlements :- "${SRC_APP}" 2>&1
    echo "== spctl（ad-hoc 预期 rejected）=="; spctl -a -vv "${SRC_APP}" 2>&1 || true
    echo "== 架构/最低系统 =="; lipo -info "${SRC_APP}/Contents/MacOS/DeskTodo" 2>&1; vtool -show-build "${SRC_APP}/Contents/MacOS/DeskTodo" 2>/dev/null | grep minos
  } > "${EVID}/01-artifact.txt" 2>&1
  check_entitlements "${SRC_APP}" || die 5 "产物签名缺少日历/提醒 entitlements"
  {
    echo "EXPECTED_SHA=${ACTUAL_SHA}"
    echo "VERSION=$(app_version "${SRC_APP}")"
    echo "BUILD=$(app_build "${SRC_APP}")"
    echo "BUNDLE_ID=$(app_bid "${SRC_APP}")"
    echo "TEST_MACHINE_ID=${TEST_ID}"
  } > "${EVID}/identity.env"

  # 安装：目标必须不存在（前面已保证），这里不做任何删除/覆盖
  ditto "${SRC_APP}" "${APP}" || die 5 "安装到 ${APP} 失败"
  codesign --verify --strict "${APP}" || die 5 "安装后签名校验失败"
  okc "已安装测试应用到 ${APP}（未覆盖任何已有安装）"

  pkill -f "DeskTodo.app/Contents/MacOS/DeskTodo" >/dev/null 2>&1 || true
  open -a "${APP}" || die 5 "启动失败"
  sleep 6
  pgrep -f "DeskTodo.app/Contents/MacOS/DeskTodo" >/dev/null 2>&1 || die 5 "启动后进程不存在"
  okc "测试应用已启动"

  cat > "${EVID}/02-next-steps.txt" <<'STEPS'
下一步（在隔离测试机里人工操作）：
1. 首次启动后，系统应弹「日历」与「提醒事项」授权窗口 → 选择允许。
2. 打开菜单 →「数据来源」，让应用真正读取一次日历/提醒事项。
3. 在测试系统里创建至少 1 个日历事件 + 1 个提醒事项（可用日历 App）。
4. 完成后再跑：
   ./tools/tcc-acceptance.sh collect --test-machine-id "${ID}" --evidence-dir <同一证据目录>
STEPS
  echo "PHASE_PREPARE_OK"
  echo "证据目录：${EVID}"
  exit 0
fi

# ═══════════════════════ 阶段 B：collect ═══════════════════════
if [ "${MODE}" = "collect" ]; then
  [ -d "${EVID}" ] || die 2 "证据目录不存在：${EVID}"
  [ -f "${EVID}/identity.env" ] || die 2 "缺少 identity.env（请先跑 prepare）"
  # shellcheck disable=SC1090
  . "${EVID}/identity.env"
  [ -e "${APP}" ] || die 4 "未检测到测试安装 ${APP}（请先跑 prepare）"
  [ "$(app_version "${APP}")" = "${VERSION}" ] || die 4 "已安装版本与候选不一致（$(app_version "${APP}") != ${VERSION}）"
  [ "$(app_build "${APP}")" = "${BUILD}" ] || die 4 "已安装构建号与候选不一致（$(app_build "${APP}") != ${BUILD}）"
  [ "$(app_bid "${APP}")" = "${BUNDLE_ID}" ] || die 4 "Bundle ID 与候选不一致"
  check_entitlements "${APP}" || die 5 "已安装应用签名缺少 entitlements"

  LOG="${DATA}/logs/desktodo.log"
  {
    echo "== 应用日志（授权/读取结果）=="
    [ -f "${LOG}" ] && tail -400 "${LOG}" | grep -E "ext cal=|ext rem=|requestAccess" || echo "（没有找到应用日志）"
    echo
    echo "== 数据目录（只列文件，不输出内容）=="
    ls -la "${DATA}" 2>&1 || true
  } > "${EVID}/03-eventkit-log.txt" 2>&1

  {
    echo "== tccd 日志（最近 20 分钟，DeskTodo/日历/提醒相关）=="
    log show --last 20m --predicate 'process == "tccd" AND (eventMessage CONTAINS[c] "deskTodo" OR eventMessage CONTAINS[c] "kTCCServiceCalendar" OR eventMessage CONTAINS[c] "kTCCServiceReminders")' 2>&1 | tail -300
  } > "${EVID}/04-tcc-log.txt" 2>&1

  # 判定
  FAILS=0
  claim_fail() { echo "  ✗ $*" | tee -a "${EVID}/90-verdict.txt" >/dev/null; FAILS=$((FAILS+1)); }
  claim_ok()   { echo "  ✓ $*" | tee -a "${EVID}/90-verdict.txt" >/dev/null; }
  : > "${EVID}/90-verdict.txt"

  CAL_OK="$(grep -oE 'ext cal=ok/[0-9]+/[0-9]+d?' "${EVID}/03-eventkit-log.txt" | tail -1 || true)"
  REM_OK="$(grep -oE 'ext rem=ok/[0-9]+/[0-9]+d?' "${EVID}/03-eventkit-log.txt" | tail -1 || true)"
  [ -n "${CAL_OK}" ] && claim_ok "应用日志出现 ${CAL_OK}" || claim_fail "应用日志没有 cal=ok（日历未真正授权/读取）"
  [ -n "${REM_OK}" ] && claim_ok "应用日志出现 ${REM_OK}" || claim_fail "应用日志没有 rem=ok（提醒事项未真正授权/读取）"
  CAL_N="$(printf '%s' "${CAL_OK}" | grep -oE '[0-9]+/' | head -1 | tr -d '/' || true)"
  REM_N="$(printf '%s' "${REM_OK}" | grep -oE '[0-9]+/' | head -1 | tr -d '/' || true)"
  [ -n "${CAL_N}" ] && [ "${CAL_N}" -ge "${REQUIRE_EVENTS}" ] 2>/dev/null && claim_ok "日历读到 ${CAL_N} 条（要求 ≥${REQUIRE_EVENTS}）" || claim_fail "日历读取条数不足（${CAL_N:-无}，要求 ≥${REQUIRE_EVENTS}）"
  [ -n "${REM_N}" ] && [ "${REM_N}" -ge "${REQUIRE_EVENTS}" ] 2>/dev/null && claim_ok "提醒事项读到 ${REM_N} 条（要求 ≥${REQUIRE_EVENTS}）" || claim_fail "提醒事项读取条数不足（${REM_N:-无}，要求 ≥${REQUIRE_EVENTS}）"

  if grep -qi "requires entitlement" "${EVID}/04-tcc-log.txt"; then
    claim_fail "tccd 日志出现 entitlement 缺失（P0-1 未修复）"
  else
    claim_ok "tccd 日志没有 entitlement 缺失"
  fi
  if grep -qi "denied" "${EVID}/04-tcc-log.txt"; then
    claim_fail "tccd 日志出现 denied"
  else
    claim_ok "tccd 日志没有 denied"
  fi

  # 重启/退出检查（只记录，不阻塞判定）
  {
    echo "== 进程状态 =="
    pgrep -fl "DeskTodo.app/Contents/MacOS/DeskTodo" || echo "（进程未运行）"
  } > "${EVID}/05-process.txt" 2>&1

  if [ "${FAILS}" -gt 0 ]; then
    echo "PHASE_COLLECT_FAIL (fails=${FAILS})"
    echo "证据目录：${EVID}"
    exit 5
  fi
  echo "PHASE_COLLECT_OK"
  echo "证据目录：${EVID}"
  exit 0
fi
