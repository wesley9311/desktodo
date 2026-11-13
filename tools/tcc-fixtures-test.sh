#!/bin/bash
# TCC 日志解析与阶段判定夹具测试（不需要 VM，不接触真实数据）。
# 目的：用真实日志格式的固定样本验证 collect/restart/denial/identity 的 PASS/FAIL 判定，
#       防止验收脚本假阳性（把缺失当通过）或假阴性（把正确格式判失败）。
#
# 真实格式来自 src/AppDelegate+Sources.swift:200-201：
#   <Date()> ext cal=<st>/<N>/<D>d rem=<st>/<Open>open/<Late>late ...
# 用法：./tools/tcc-fixtures-test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/tcc-log-parse.sh"

TMP="$(mktemp -d /tmp/dt-tcc-fixtures.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0; FAILED_NAMES=""

expect() { # name want_rc rc
  local name="$1" want="$2" rc="${3:-}"
  if [ "${rc}" = "${want}" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "${name}"
  else FAIL=$((FAIL+1)); FAILED_NAMES="${FAILED_NAMES}\n    - ${name} (rc=${rc} want=${want})"; printf '  \033[31m✗\033[0m %s (rc=%s want=%s)\n' "${name}" "${rc}" "${want}"; fi
}

# 采集判定前必须先按"本次启动时间"过滤（judge 只接受已过滤日志）
run_collect() { # raw tcc req shots [start_epoch]
  local raw="$1" tccf="$2" req="$3" shots="$4" start="${5:-${START_EPOCH}}"
  tcc_filter_since "${raw}" "${start}" > "${TMP}/filtered.tmp" 2>/dev/null || : > "${TMP}/filtered.tmp"
  ( TCC_FAILS=0; tcc_judge_collect "${TMP}/filtered.tmp" "${tccf}" "${TMP}/v" "${req}" "${shots}" )
}
run_restart() { ( TCC_FAILS=0; tcc_judge_restart "$1" "$2" "$3" "$4" ); }
run_denial()  { ( TCC_FAILS=0; tcc_judge_denial  "$1" "$2" "$3" ); }

START_EPOCH="$(tcc_epoch_of_ts '2026-11-13 04:00:00 +0000')"
[ -n "${START_EPOCH}" ] || { echo "无法解析起始时间（BSD date 不可用）" >&2; exit 2; }

# 基础真实格式行（本地时区 +0800）
CB_CAL='2026-11-13 12:00:00 +0800 requestAccess(cal) ok=true status=fullAccess'
CB_REM='2026-11-13 12:00:00 +0800 requestAccess(rem) ok=true status=fullAccess'
DATA_OK='2026-11-13 12:00:01 +0800 ext cal=ok/2/2d rem=ok/1open/0late screen=ok/0s(rc=0) holi=0 off=休0/班0'

# ── 解析器单元 ──
printf '%s\n' "${DATA_OK}" > "${TMP}/line.txt"
expect "parse_cal 真实格式" 0 "$([ "$(tcc_parse_cal "${DATA_OK}")" = 'ok|2|2' ] && echo 0 || echo 1)"
expect "parse_rem 真实格式 rem=ok/Nopen/Mlate" 0 "$([ "$(tcc_parse_rem "${DATA_OK}")" = 'ok|1|0' ] && echo 0 || echo 1)"
expect "parse_rem 不匹配错误格式 ext rem=ok/N/M" 0 "$([ -z "$(tcc_parse_rem '2026-11-13 12:00:01 +0800 ext rem=ok/1/0')" ] && echo 0 || echo 1)"

# ── 时间过滤：跨时区/边界 ──
cat > "${TMP}/filter.txt" <<EOF
2026-11-13 03:59:59 +0000 old-0000
2026-11-13 11:59:59 +0800 old-0800
2026-11-13 12:00:00 +0800 eq-0800
2026-11-13 04:00:01 +0000 new-0000
EOF
tcc_filter_since "${TMP}/filter.txt" "${START_EPOCH}" > "${TMP}/filter.out"
N="$(wc -l < "${TMP}/filter.out" | tr -d ' ')"
expect "时间过滤：跨时区边界（应为 2 行）" 0 "$([ "${N}" = "2" ] && echo 0 || echo 1)"
if grep -q "eq-0800" "${TMP}/filter.out" && grep -q "new-0000" "${TMP}/filter.out" && ! grep -q "old-" "${TMP}/filter.out"; then RC=0; else RC=1; fi
expect "时间过滤：相等边界包含、旧记录排除" 0 "${RC}"

# ── collect ──
printf '%s\n%s\n%s\n' "${CB_CAL}" "${CB_REM}" "${DATA_OK}" > "${TMP}/collect-ok.log"
printf 'prompt evidence: Prompting policy for hardened runtime; kTCCServiceCalendar\n' > "${TMP}/tcc-prompt.txt"
expect "collect 正向真实格式" 0 "$(run_collect "${TMP}/collect-ok.log" "${TMP}/tcc-prompt.txt" 1 1 >/dev/null; echo $?)"

printf '%s\n%s\n2026-11-13 12:00:01 +0800 ext cal=ok/2/2d\n' "${CB_CAL}" "${CB_REM}" > "${TMP}/collect-norem.log"
expect "collect 缺 rem 字段应失败" 1 "$(run_collect "${TMP}/collect-norem.log" "${TMP}/tcc-prompt.txt" 1 1 >/dev/null; echo $?)"

printf '2026-11-13 11:59:59 +0800 %s\n' "${DATA_OK}" > "${TMP}/collect-old.log"
expect "collect 旧日志（启动前）应失败" 1 "$(run_collect "${TMP}/collect-old.log" "${TMP}/tcc-prompt.txt" 1 1 >/dev/null; echo $?)"

printf '%s\n%s\n2026-11-13 12:00:00 +0800 ext cal=ok/2/2d rem=ok/1open/0late\n' "${CB_CAL}" "${CB_REM}" > "${TMP}/collect-eq.log"
expect "collect 起始时刻边界应通过" 0 "$(run_collect "${TMP}/collect-eq.log" "${TMP}/tcc-prompt.txt" 1 1 >/dev/null; echo $?)"

: > "${TMP}/tcc-empty.txt"
expect "collect tccd 被过滤：无截图应失败" 1 "$(run_collect "${TMP}/collect-ok.log" "${TMP}/tcc-empty.txt" 1 0 >/dev/null; echo $?)"
expect "collect tccd 被过滤：截图+回调应通过" 0 "$(run_collect "${TMP}/collect-ok.log" "${TMP}/tcc-empty.txt" 1 1 >/dev/null; echo $?)"

printf '%s\n%s\n2026-11-13 12:00:01 +0800 ext cal=ok/2/2 rem=ok/1open/0late\n' "${CB_CAL}" "${CB_REM}" > "${TMP}/collect-badfmt.log"
expect "collect 格式变化（缺 d）应失败" 1 "$(run_collect "${TMP}/collect-badfmt.log" "${TMP}/tcc-prompt.txt" 1 1 >/dev/null; echo $?)"

printf 'requires entitlement com.apple.security.personal-information.calendars\nPrompting policy\n' > "${TMP}/tcc-missing-ent.txt"
expect "collect entitlement 缺失应失败" 1 "$(run_collect "${TMP}/collect-ok.log" "${TMP}/tcc-missing-ent.txt" 1 1 >/dev/null; echo $?)"

expect "collect 日志文件不存在应失败" 1 "$(run_collect "${TMP}/nope.log" "${TMP}/tcc-prompt.txt" 1 1 >/dev/null; echo $?)"

# ── restart ──
printf '%s\n%s\n' '2026-11-13 12:10:00 +0800 ext cal=ok/2/2d rem=ok/1open/0late' '2026-11-13 12:10:01 +0800 ext cal=ok/2/2d rem=ok/1open/0late' > "${TMP}/restart-ok.log"
printf 'tccd noise: kTCCServiceCalendar access granted\n' > "${TMP}/tcc-none.txt"
expect "restart 正向（cal+rem 分别保持）" 0 "$(run_restart "${TMP}/restart-ok.log" "${TMP}/tcc-none.txt" "${TMP}/v" 1 >/dev/null; echo $?)"
printf '2026-11-13 12:10:00 +0800 ext cal=ok/2/2d\n' > "${TMP}/restart-norem.log"
expect "restart 缺 rem 应失败" 1 "$(run_restart "${TMP}/restart-norem.log" "${TMP}/tcc-none.txt" "${TMP}/v" 1 >/dev/null; echo $?)"
printf 'prompt evidence: Prompting policy\n' > "${TMP}/tcc-prompt2.txt"
expect "restart 出现新弹窗应失败" 1 "$(run_restart "${TMP}/restart-ok.log" "${TMP}/tcc-prompt2.txt" "${TMP}/v" 1 >/dev/null; echo $?)"
: > "${TMP}/restart-empty.log"
expect "restart 无日志应失败" 1 "$(run_restart "${TMP}/restart-empty.log" "${TMP}/tcc-prompt.txt" "${TMP}/v" 1 >/dev/null; echo $?)"

# ── denial ──
printf '%s\n%s\n' '2026-11-13 12:20:00 +0800 requestAccess(cal) ok=false status=denied' '2026-11-13 12:20:00 +0800 requestAccess(rem) ok=false status=denied' > "${TMP}/deny-ok.log"
expect "denial 正向（cal+rem 分别拒绝）" 0 "$(run_denial "${TMP}/deny-ok.log" 1 "${TMP}/v" >/dev/null; echo $?)"
printf '2026-11-13 12:20:00 +0800 requestAccess(cal) ok=false status=denied\n' > "${TMP}/deny-cal.log"
expect "denial 缺 rem 拒绝应失败" 1 "$(run_denial "${TMP}/deny-cal.log" 1 "${TMP}/v" >/dev/null; echo $?)"
{ cat "${TMP}/deny-ok.log"; echo "2026-11-13 12:20:01 +0800 ext cal=ok/1/1d rem=ok/0open/0late"; } > "${TMP}/deny-ok2.log"
expect "denial 后出现 ok 读取应失败" 1 "$(run_denial "${TMP}/deny-ok2.log" 1 "${TMP}/v" >/dev/null; echo $?)"
expect "denial 应用已退出应失败" 1 "$(run_denial "${TMP}/deny-ok.log" 0 "${TMP}/v" >/dev/null; echo $?)"
: > "${TMP}/deny-empty.log"
expect "denial 无日志不能当作已允许（应失败）" 1 "$(run_denial "${TMP}/deny-empty.log" 1 "${TMP}/v" >/dev/null; echo $?)"

# ── identity.env ──
valid_identity() {
  cat > "${TMP}/identity.env" <<EOF
EXPECTED_SHA=$(printf 'a%.0s' $(seq 1 64))
VERSION=0.1.1
BUILD=2026111201
BUNDLE_ID=local.desktodo.app
CDHASH=$(printf 'b%.0s' $(seq 1 40))
TEST_START_ISO=2026-11-13T04:00:00Z
TEST_START_UTC_KEY=2026-11-13 04:00:00
TEST_START_LOCAL=2026-11-13 12:00:00
TEST_START_EPOCH=${START_EPOCH}
TEST_MACHINE_ID=vm-1
EOF
}
run_identity() { ( tcc_read_identity "$1" "${2:-vm-1}" >/dev/null 2>&1 ); }
valid_identity
expect "identity 合法" 0 "$(run_identity "${TMP}/identity.env"; echo $?)"
grep -v '^BUILD=' "${TMP}/identity.env" > "${TMP}/id-missing.env"
expect "identity 缺字段应失败" 1 "$(run_identity "${TMP}/id-missing.env"; echo $?)"
sed 's/^VERSION=.*/VERSION=/' "${TMP}/identity.env" > "${TMP}/id-empty.env"
expect "identity 空值应失败" 1 "$(run_identity "${TMP}/id-empty.env"; echo $?)"
{ cat "${TMP}/identity.env"; echo "BUILD=2026111202"; } > "${TMP}/id-dup.env"
expect "identity 重复键应失败" 1 "$(run_identity "${TMP}/id-dup.env"; echo $?)"
{ cat "${TMP}/identity.env"; echo "EXTRA=x"; } > "${TMP}/id-unknown.env"
expect "identity 未知字段应失败" 1 "$(run_identity "${TMP}/id-unknown.env"; echo $?)"
sed 's/^CDHASH=.*/CDHASH=xyz/' "${TMP}/identity.env" > "${TMP}/id-badhash.env"
expect "identity CDHash 非法应失败" 1 "$(run_identity "${TMP}/id-badhash.env"; echo $?)"
expect "identity 测试机不匹配应失败" 1 "$(run_identity "${TMP}/identity.env" other-vm; echo $?)"


# ── 人工截图内容核验（不是只查文件存在）──
SERIAL="$(tcc_machine_serial)"; MID="vm-1"
mk_noise_png() { # file w h seed
  python3 - "$1" "$2" "$3" "$4" <<'PYPNG'
import sys, zlib, struct, random
path, w, h, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
random.seed(seed)
raw = b"".join(b"\x00" + bytes(random.getrandbits(8) for _ in range(w*3)) for _ in range(h))
def chunk(t, d):
    c = t + d
    return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
open(path, "wb").write(png)
PYPNG
}
HASPY=0; command -v python3 >/dev/null 2>&1 && HASPY=1
mk_manifest() { # dir caltitle remtitle calat remat [cal_dlg] [rem_dlg] [hash_override] [machine] [buttons]
  local dir="$1" ct="$2" rt="$3" ca="$4" ra="$5" cd="${6:-calendar}" rd="${7:-reminder}" ho="${8:-}" mach="${9:-$MID}" btns="${10:-不允许 / 允许}"
  local ch rh
  ch="$(shasum -a 256 "$dir/shot-calendar-prompt.png" | awk '{print $1}')"
  rh="$(shasum -a 256 "$dir/shot-reminder-prompt.png" | awk '{print $1}')"
  [ -n "$ho" ] && ch="$ho"
  { printf 'file\tdialog\ttitle\tbuttons\tcaptured_at\tcaptured_by\tmachine\timage_sha256\n'
    printf 'shot-calendar-prompt.png\t%s\t%s\t%s\t%s\tTester\t%s\t%s\n' "$cd" "$ct" "$btns" "$ca" "$mach" "$ch"
    printf 'shot-reminder-prompt.png\t%s\t%s\t%s\t%s\tTester\t%s\t%s\n' "$rd" "$rt" "$btns" "$ra" "$mach" "$rh"
  } > "$dir/shots-manifest.tsv"
}
run_shots() { ( TCC_FAILS=0; tcc_verify_shots "$1" "$START_EPOCH" "$TMP/shots-verdict.tmp" "$MID" ); }
run_structure() { ( TCC_FAILS=0; tcc_manifest_structure "$1" "$TMP/st-verdict.tmp" ); }

if [ "$HASPY" = "1" ]; then
  OKDIR="$TMP/shots-ok"; mkdir -p "$OKDIR"
  mk_noise_png "$OKDIR/shot-calendar-prompt.png" 800 600 1
  mk_noise_png "$OKDIR/shot-reminder-prompt.png" 800 600 2
  CALT='2026-11-13 12:05:00 +0800'; REMT='2026-11-13 12:06:00 +0800'
  mk_manifest "$OKDIR" '“浮窗待办”想要访问你的日历' '“浮窗待办”想要访问你的提醒事项' "$CALT" "$REMT"
  expect "shots 正向（日历/提醒分别截图+manifest）" 0 "$(run_shots "$OKDIR" >/dev/null 2>&1; echo $?)"

  D="$TMP/shots-norem"; cp -R "$OKDIR" "$D"; rm -f "$D/shot-reminder-prompt.png"
  expect "shots 缺少提醒弹窗截图应失败" 1 "$(run_shots "$D" >/dev/null 2>&1; echo $?)"

  D="$TMP/shots-dup"; cp -R "$OKDIR" "$D"; cp "$D/shot-calendar-prompt.png" "$D/shot-reminder-prompt.png"; mk_manifest "$D" '“浮窗待办”想要访问你的日历' '“浮窗待办”想要访问你的提醒事项' "$CALT" "$REMT"
  expect "shots 两图相同应失败" 1 "$(run_shots "$D" >/dev/null 2>&1; echo $?)"

  D="$TMP/shots-badtitle"; cp -R "$OKDIR" "$D"; mk_manifest "$D" '某个弹窗' '“浮窗待办”想要访问你的提醒事项' "$CALT" "$REMT"
  expect "shots 日历标题未命中关键词应失败" 1 "$(run_shots "$D" >/dev/null 2>&1; echo $?)"

  D="$TMP/shots-baddlg"; cp -R "$OKDIR" "$D"; mk_manifest "$D" '“浮窗待办”想要访问你的日历' '“浮窗待办”想要访问你的提醒事项' "$CALT" "$REMT" reminder reminder
  expect "shots dialog 字段错配应失败" 1 "$(run_shots "$D" >/dev/null 2>&1; echo $?)"

  D="$TMP/shots-oldtime"; cp -R "$OKDIR" "$D"; mk_manifest "$D" '“浮窗待办”想要访问你的日历' '“浮窗待办”想要访问你的提醒事项' '2026-11-13 03:00:00 +0800' "$REMT"
  expect "shots 拍摄时间早于测试开始应失败" 1 "$(run_shots "$D" >/dev/null 2>&1; echo $?)"

  D="$TMP/shots-badhash"; cp -R "$OKDIR" "$D"; mk_manifest "$D" '“浮窗待办”想要访问你的日历' '“浮窗待办”想要访问你的提醒事项' "$CALT" "$REMT" calendar reminder "$(printf '0%.0s' $(seq 1 64))"
  expect "shots 图片哈希与 manifest 不一致应失败" 1 "$(run_shots "$D" >/dev/null 2>&1; echo $?)"

  D="$TMP/shots-noheader"; cp -R "$OKDIR" "$D"; tail -n +2 "$D/shots-manifest.tsv" > "$D/shots-manifest.tsv.tmp"; mv "$D/shots-manifest.tsv.tmp" "$D/shots-manifest.tsv"
  expect "shots manifest 缺表头应失败" 1 "$(run_shots "$D" >/dev/null 2>&1; echo $?)"

  D="$TMP/shots-blank"; mkdir -p "$D"
  printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' | base64 -D > "$D/shot-calendar-prompt.png" 2>/dev/null || true
  cp "$D/shot-calendar-prompt.png" "$D/shot-reminder-prompt.png"
  mk_manifest "$D" '“浮窗待办”想要访问你的日历' '“浮窗待办”想要访问你的提醒事项' "$CALT" "$REMT"
  expect "shots 空白占位图应失败" 1 "$(run_shots "$D" >/dev/null 2>&1; echo $?)"

  expect "模板 tsv 本身可被严格解析（8 列/无空字段/各一条）" 0 "$(run_structure "${ROOT}/tools/tcc-shots-manifest.example.tsv" >/dev/null 2>&1; echo $?)"

  D="$TMP/shots-9col"; cp -R "$OKDIR" "$D"; printf '不允许\t允许' > "$D/btns.tmp"
  awk -F'\t' -v OFS='\t' 'NR==1{print;next}{$4=$4"\t"$4; print}' "$OKDIR/shots-manifest.tsv" > "$D/shots-manifest.tsv"
  expect "manifest 列数多一列应失败" 1 "$(run_structure "$D/shots-manifest.tsv" >/dev/null 2>&1; echo $?)"

  D="$TMP/shots-empty"; cp -R "$OKDIR" "$D"
  awk -F'\t' -v OFS='\t' 'NR==1{print;next}{$3=""; print}' "$OKDIR/shots-manifest.tsv" > "$D/shots-manifest.tsv"
  expect "manifest 空字段应失败" 1 "$(run_structure "$D/shots-manifest.tsv" >/dev/null 2>&1; echo $?)"

  D="$TMP/shots-dupfile"; mkdir -p "$D"; { head -1 "$OKDIR/shots-manifest.tsv"; sed -n '2p' "$OKDIR/shots-manifest.tsv"; sed -n '2p' "$OKDIR/shots-manifest.tsv"; } > "$D/shots-manifest.tsv"
  expect "manifest 重复 file 记录应失败" 1 "$(run_structure "$D/shots-manifest.tsv" >/dev/null 2>&1; echo $?)"

  D="$TMP/shots-dupdialog"; mkdir -p "$D"; { head -1 "$OKDIR/shots-manifest.tsv"; sed -n '2p' "$OKDIR/shots-manifest.tsv"; sed -n '3p' "$OKDIR/shots-manifest.tsv" | awk -F'\t' -v OFS='\t' '{$1="shot-other.png"; $2="calendar"; print}'; } > "$D/shots-manifest.tsv"
  expect "manifest 重复 dialog 记录应失败" 1 "$(run_structure "$D/shots-manifest.tsv" >/dev/null 2>&1; echo $?)"

  D="$TMP/shots-denyonly"; cp -R "$OKDIR" "$D"; mk_manifest "$D" '“浮窗待办”想要访问你的日历' '“浮窗待办”想要访问你的提醒事项' "$CALT" "$REMT" calendar reminder "" "$MID" '不允许'
  expect "shots 按钮只有「不允许」应失败" 1 "$(run_shots "$D" >/dev/null 2>&1; echo $?)"

  D="$TMP/shots-denyonly-en"; cp -R "$OKDIR" "$D"; mk_manifest "$D" 'Calendar access request' 'Reminders access request' "$CALT" "$REMT" calendar reminder "" "$MID" "Don't Allow"
  expect "shots 按钮只有 Don't Allow 应失败" 1 "$(run_shots "$D" >/dev/null 2>&1; echo $?)"

  D="$TMP/shots-badmachine"; cp -R "$OKDIR" "$D"; mk_manifest "$D" '“浮窗待办”想要访问你的日历' '“浮窗待办”想要访问你的提醒事项' "$CALT" "$REMT" calendar reminder "" "other-machine" '不允许 / 允许'
  expect "shots 机器标识不可验证/不匹配应失败" 1 "$(run_shots "$D" >/dev/null 2>&1; echo $?)"
else
  echo "  · 跳过截图夹具（无 python3 生成测试 PNG）"
fi


echo
echo "夹具结果：PASS=${PASS} FAIL=${FAIL}"
[ "${FAIL}" -eq 0 ] || printf '失败项：%b\n' "${FAILED_NAMES}"
[ "${FAIL}" -eq 0 ]
