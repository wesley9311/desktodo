#!/bin/bash
# DeskTodo TCC 日志解析与阶段判定（纯函数，可在无 VM 的宿主上做夹具测试）。
#
# 真实日志格式（来自 src/AppDelegate+Sources.swift:200-201，单行）：
#   <Date()> ext cal=<st>/<N>/<D>d rem=<st>/<Open>open/<Late>late screen=...
# 其中 <Date()> 形如 "2026-11-13 12:00:01 +0800"（本地时区，可能任意偏移）。
# 注意：提醒**没有** "ext rem=" 前缀，而是同一行的 "rem=ok/Nopen/Mlate"。
#
# 约定：
#   - 所有函数不写真实数据，只读传入文件；
#   - 判定函数把 ✓/✗ 写入传入的 verdict 文件，并累加全局 TCC_FAILS；
#   - 返回 0 表示该阶段通过（TCC_FAILS=0），1 表示失败。
# 依赖：BSD date（macOS），awk/sed/grep。
# shellcheck shell=bash

TCC_FAILS=0

tcc_claim_ok()   { printf '  ✓ %s\n' "$1" >> "$2"; }
tcc_claim_fail() { printf '  ✗ %s\n' "$1" >> "$2"; TCC_FAILS=$((TCC_FAILS + 1)); }
tcc_claim_note() { printf '    %s\n' "$1" >> "$2"; }

# "YYYY-MM-DD HH:MM:SS ±HHMM" → epoch
tcc_epoch_of_ts() {
  # BSD date
  date -j -f "%Y-%m-%d %H:%M:%S %z" "$1" +%s 2>/dev/null
}

# 从一行日志里取时间戳（前三个字段），解析失败返回空
tcc_line_ts() {
  printf '%s' "$1" | sed -nE 's/^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}).*/\1/p'
}

# 过滤：只保留 epoch >= start_epoch 的日志行（自动处理任意时区偏移）
tcc_filter_since() {
  local file="$1" start="$2" line ts epoch
  [ -f "${file}" ] || return 1
  while IFS= read -r line || [ -n "${line}" ]; do
    ts="$(tcc_line_ts "${line}")"
    [ -n "${ts}" ] || continue
    epoch="$(tcc_epoch_of_ts "${ts}")" || continue
    [ -n "${epoch}" ] || continue
    [ "${epoch}" -ge "${start}" ] && printf '%s\n' "${line}"
  done < "${file}"
  return 0
}

# 解析日历字段：输出 "status|N|D"
tcc_parse_cal() {
  printf '%s' "$1" | sed -nE 's/.*ext cal=([^ \/]+)\/([0-9]+)\/([0-9]+)d.*/\1|\2|\3/p'
}

# 解析提醒字段：输出 "status|Open|Late"（同一行，无 ext 前缀）
tcc_parse_rem() {
  printf '%s' "$1" | sed -nE 's/.* rem=([^ \/]+)\/([0-9]+)open\/([0-9]+)late.*/\1|\2|\3/p'
}

# 取文件中最后一条可解析的 cal / rem
tcc_latest_cal() {
  local f="$1" line p out=""
  [ -f "${f}" ] || { printf ''; return 0; }
  while IFS= read -r line || [ -n "${line}" ]; do
    p="$(tcc_parse_cal "${line}")"
    [ -n "${p}" ] && out="${p}"
  done < "${f}"
  printf '%s' "${out}"
}
tcc_latest_rem() {
  local f="$1" line p out=""
  [ -f "${f}" ] || { printf ''; return 0; }
  while IFS= read -r line || [ -n "${line}" ]; do
    p="$(tcc_parse_rem "${line}")"
    [ -n "${p}" ] && out="${p}"
  done < "${f}"
  printf '%s' "${out}"
}

# ── collect 判定 ─────────────────────────────────────────────
# 参数：filtered(本次启动后) tccd_log verdict require_events shots_present(0/1)
tcc_judge_collect() {
  local log="$1" tccf="$2" verdict="$3" req="$4" shots="${5:-0}"
  local cal rem cs cn cd rs rn rl
  : > "${verdict}"

  if [ ! -s "${log}" ]; then
    tcc_claim_fail "本次启动后没有可用日志：不能把「没记录」当成已允许/已读取" "${verdict}"
    return 1
  fi
  grep -qE 'requestAccess\(cal\) ok=true' "${log}" && tcc_claim_ok "授权回调 requestAccess(cal) ok=true（实际返回）" "${verdict}" || tcc_claim_fail "缺少 requestAccess(cal) ok=true（实际授权返回）" "${verdict}"
  grep -qE 'requestAccess\(rem\) ok=true' "${log}" && tcc_claim_ok "授权回调 requestAccess(rem) ok=true（实际返回）" "${verdict}" || tcc_claim_fail "缺少 requestAccess(rem) ok=true（实际授权返回）" "${verdict}"

  cal="$(tcc_latest_cal "${log}")"
  cs="${cal%%|*}"; cn="$(printf '%s' "${cal}" | cut -d'|' -f2)"; cd="$(printf '%s' "${cal}" | cut -d'|' -f3)"
  if [ -n "${cal}" ] && [ "${cs}" = "ok" ]; then
    if [ -n "${cn}" ] && [ "${cn}" -ge "${req}" ] 2>/dev/null; then
      tcc_claim_ok "日历读取：cal=ok/${cn}/${cd}d（≥${req}）" "${verdict}"
    else
      tcc_claim_fail "日历读取条数不足：cal=${cal}（要求 ≥${req}）" "${verdict}"
    fi
  else
    tcc_claim_fail "日历未读取成功：cal=${cal:-无记录}" "${verdict}"
  fi

  rem="$(tcc_latest_rem "${log}")"
  rs="${rem%%|*}"; rn="$(printf '%s' "${rem}" | cut -d'|' -f2)"; rl="$(printf '%s' "${rem}" | cut -d'|' -f3)"
  if [ -n "${rem}" ] && [ "${rs}" = "ok" ]; then
    if [ -n "${rn}" ] && [ "${rn}" -ge "${req}" ] 2>/dev/null; then
      tcc_claim_ok "提醒读取：rem=ok/${rn}open/${rl}late（≥${req}）" "${verdict}"
    else
      tcc_claim_fail "提醒读取条数不足：rem=${rem}（要求 ≥${req}）" "${verdict}"
    fi
  else
    tcc_claim_fail "提醒未读取成功：rem=${rem:-无记录}" "${verdict}"
  fi

  # 弹窗证据：tccd 可能被系统隐私过滤；不能因字符串缺失就假阳/假阴。
  local prompt=0 fallback=0 tcc_has=0
  [ -s "${tccf}" ] && tcc_has=1
  grep -qiE 'Prompting policy' "${tccf}" 2>/dev/null && prompt=1
  [ "${shots}" = "1" ] && fallback=1
  if [ "${prompt}" = "1" ]; then
    tcc_claim_ok "tccd 记录到授权弹窗（Prompting policy）" "${verdict}"
  elif [ "${fallback}" = "1" ] && [ "$(grep -cE 'requestAccess\((cal|rem)\) ok=true' "${log}")" -ge 2 ]; then
    tcc_claim_ok "tccd 未给出弹窗字符串，但存在人工截图 + 两次真实授权回调（独立证据）" "${verdict}"
  else
    tcc_claim_fail "弹窗证据不足：既无 Prompting policy，也无截图+回调双证据" "${verdict}"
  fi
  if [ "${tcc_has}" = "1" ]; then
    grep -qiE 'requires entitlement' "${tccf}" && tcc_claim_fail "tccd 出现 entitlement 缺失（P0-1 未修复）" "${verdict}" || tcc_claim_ok "tccd 无 entitlement 缺失" "${verdict}"
    if grep -iE 'kTCCService(Calendar|Reminders)' "${tccf}" | grep -qi 'denied'; then
      tcc_claim_fail "tccd 对日历/提醒出现 denied" "${verdict}"
    else
      tcc_claim_ok "tccd 对日历/提醒无 denied" "${verdict}"
    fi
  else
    tcc_claim_note "tccd 日志为空/被过滤：entitlement 与 denied 只能依赖授权回调+截图" "${verdict}"
  fi

  [ "${TCC_FAILS}" -eq 0 ] && return 0 || return 1
}

# ── restart 判定 ────────────────────────────────────────────
# 参数：filtered(重启后) tccd_log(重启后) verdict require_events
tcc_judge_restart() {
  local log="$1" tccf="$2" verdict="$3" req="$4"
  local cal rem cs cn cd rs rn rl
  : > "${verdict}"
  if [ ! -s "${log}" ]; then
    tcc_claim_fail "重启后没有可用日志：无法证明授权保持" "${verdict}"
    return 1
  fi

  cal="$(tcc_latest_cal "${log}")"
  cs="${cal%%|*}"; cn="$(printf '%s' "${cal}" | cut -d'|' -f2)"; cd="$(printf '%s' "${cal}" | cut -d'|' -f3)"
  [ -n "${cal}" ] && [ "${cs}" = "ok" ] && [ -n "${cn}" ] && [ "${cn}" -ge "${req}" ] 2>/dev/null \
    && tcc_claim_ok "重启后日历授权与读取保持：cal=ok/${cn}/${cd}d" "${verdict}" \
    || tcc_claim_fail "重启后日历未保持：cal=${cal:-无记录}" "${verdict}"

  rem="$(tcc_latest_rem "${log}")"
  rs="${rem%%|*}"; rn="$(printf '%s' "${rem}" | cut -d'|' -f2)"; rl="$(printf '%s' "${rem}" | cut -d'|' -f3)"
  [ -n "${rem}" ] && [ "${rs}" = "ok" ] && [ -n "${rn}" ] && [ "${rn}" -ge "${req}" ] 2>/dev/null \
    && tcc_claim_ok "重启后提醒授权与读取保持：rem=ok/${rn}open/${rl}late" "${verdict}" \
    || tcc_claim_fail "重启后提醒未保持：rem=${rem:-无记录}" "${verdict}"

  if [ -s "${tccf}" ] && grep -qiE 'Prompting policy' "${tccf}" 2>/dev/null; then
    tcc_claim_fail "重启后再次出现授权弹窗（应保持已授权）" "${verdict}"
  elif [ -s "${tccf}" ]; then
    tcc_claim_ok "重启后 tccd 无新的授权弹窗" "${verdict}"
  else
    tcc_claim_note "重启后 tccd 日志为空/被过滤：弹窗未复现无法从日志确认，但 cal/rem 读取已分别验证" "${verdict}"
  fi
  [ "${TCC_FAILS}" -eq 0 ] && return 0 || return 1
}

# ── denial 判定 ─────────────────────────────────────────────
# 参数：filtered(拒绝后) alive(0/1) verdict
tcc_judge_denial() {
  local log="$1" alive="$2" verdict="$3"
  : > "${verdict}"
  if [ ! -s "${log}" ]; then
    tcc_claim_fail "拒绝后没有可用日志：不能把「没有拒绝记录」当成系统已允许" "${verdict}"
    return 1
  fi
  grep -qE 'requestAccess\(cal\) ok=false' "${log}" && tcc_claim_ok "日历拒绝返回 requestAccess(cal) ok=false" "${verdict}" || tcc_claim_fail "缺少日历拒绝返回 ok=false" "${verdict}"
  grep -qE 'requestAccess\(rem\) ok=false' "${log}" && tcc_claim_ok "提醒拒绝返回 requestAccess(rem) ok=false" "${verdict}" || tcc_claim_fail "缺少提醒拒绝返回 ok=false" "${verdict}"

  if grep -qE 'ext cal=ok/[0-9]+/' "${log}"; then
    tcc_claim_fail "拒绝后仍出现 cal=ok 读取（错误宣称连接成功）" "${verdict}"
  else
    tcc_claim_ok "拒绝后没有 cal=ok 读取" "${verdict}"
  fi
  if grep -qE 'rem=ok/[0-9]+open/' "${log}"; then
    tcc_claim_fail "拒绝后仍出现 rem=ok 读取（错误宣称连接成功）" "${verdict}"
  else
    tcc_claim_ok "拒绝后没有 rem=ok 读取" "${verdict}"
  fi
  [ "${alive}" = "1" ] && tcc_claim_ok "拒绝后应用仍在运行（未崩溃）" "${verdict}" || tcc_claim_fail "拒绝后应用不在运行（疑似崩溃）" "${verdict}"
  [ "${TCC_FAILS}" -eq 0 ] && return 0 || return 1
}

# ── identity.env 严格读取（bash 3.2 兼容，无 eval/source）────
# 参数：identity 文件、期望测试机标识
# 输出：设置全局 ID_SHA/ID_VERSION/ID_BUILD/ID_BID/ID_CDHASH/ID_START_* 并返回 0
tcc_read_identity() {
  local f="$1" machine="$2" line k v
  ID_SHA=""; ID_VERSION=""; ID_BUILD=""; ID_BID=""; ID_CDHASH=""
  ID_START_ISO=""; ID_START_UTC_KEY=""; ID_START_LOCAL=""; ID_START_EPOCH=""; ID_MACHINE=""
  [ -f "${f}" ] || { echo "identity.env 不存在" >&2; return 1; }
  local required="EXPECTED_SHA VERSION BUILD BUNDLE_ID CDHASH TEST_START_ISO TEST_START_UTC_KEY TEST_START_LOCAL TEST_START_EPOCH TEST_MACHINE_ID"
  local key
  for key in ${required}; do
    grep -q "^${key}=" "${f}" || { echo "identity.env 缺少字段：${key}" >&2; return 1; }
    if [ "$(grep -c "^${key}=" "${f}")" -gt 1 ]; then
      echo "identity.env 重复键：${key}" >&2; return 1
    fi
  done
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in ''|'#'*) continue ;; esac
    case "${line}" in *=*) ;; *) echo "identity.env 行格式非法" >&2; return 1 ;; esac
    k="${line%%=*}"; v="${line#*=}"
    [ -n "${v}" ] || { echo "identity.env 字段为空：${k}" >&2; return 1; }
    case "${k}" in
      EXPECTED_SHA)   printf '%s' "${v}" | grep -Eq '^[0-9a-f]{64}$' || { echo "EXPECTED_SHA 非法" >&2; return 1; }; ID_SHA="${v}" ;;
      VERSION)        printf '%s' "${v}" | grep -Eq '^[0-9A-Za-z.-]+$' || { echo "VERSION 非法" >&2; return 1; }; ID_VERSION="${v}" ;;
      BUILD)          printf '%s' "${v}" | grep -Eq '^[0-9]{10}$' || { echo "BUILD 非法" >&2; return 1; }; ID_BUILD="${v}" ;;
      BUNDLE_ID)      printf '%s' "${v}" | grep -Eq '^[A-Za-z0-9.-]+$' || { echo "BUNDLE_ID 非法" >&2; return 1; }; ID_BID="${v}" ;;
      CDHASH)         printf '%s' "${v}" | grep -Eq '^[0-9a-f]{40,64}$' || { echo "CDHASH 非法" >&2; return 1; }; ID_CDHASH="${v}" ;;
      TEST_START_ISO) ID_START_ISO="${v}" ;;
      TEST_START_UTC_KEY)   printf '%s' "${v}" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' || { echo "UTC 起始时间非法" >&2; return 1; }; ID_START_UTC_KEY="${v}" ;;
      TEST_START_LOCAL)     printf '%s' "${v}" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' || { echo "本地起始时间非法" >&2; return 1; }; ID_START_LOCAL="${v}" ;;
      TEST_START_EPOCH)     printf '%s' "${v}" | grep -Eq '^[0-9]+$' || { echo "起始 epoch 非法" >&2; return 1; }; ID_START_EPOCH="${v}" ;;
      TEST_MACHINE_ID)      ID_MACHINE="${v}" ;;
      *) echo "identity.env 未知字段：${k}" >&2; return 1 ;;
    esac
  done < "${f}"
  [ -n "${ID_SHA}${ID_VERSION}${ID_BUILD}${ID_BID}${ID_CDHASH}${ID_START_ISO}${ID_START_UTC_KEY}${ID_START_LOCAL}${ID_START_EPOCH}" ] || { echo "identity.env 字段不完整" >&2; return 1; }
  [ "${ID_MACHINE}" = "${machine}" ] || { echo "identity.env 测试机标识不匹配" >&2; return 1; }
  return 0
}
