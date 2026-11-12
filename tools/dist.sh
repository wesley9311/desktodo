#!/bin/bash
# 本机打包入口已统一到 tools/package.sh（universal dmg，不含任何安装脚本）。
# 保留这个文件名只为了不打断旧习惯：它现在只做转发。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "dist.sh 已退役：改用 tools/package.sh（universal dmg）。" >&2
exec "$ROOT/tools/package.sh" "$@"
