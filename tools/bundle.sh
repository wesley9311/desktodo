#!/bin/bash
# 把 src/ 下的分片打成一个可运行的前端包，输出到 build/Resources/
# 目的：源码按职责拆开（可读、可单测），运行期仍然是一个 <script> 一个闭包
# （WKWebView 用 file:// 加载，ES module 会被 CORS 拦掉，所以不能真模块化）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src"
OUT="$ROOT/build/Resources"

mkdir -p "$OUT"

# ---- 1. 静态文件 ----
cp "$SRC/index.html" "$OUT/index.html"
cp "$SRC/styles.css" "$OUT/styles.css"

# ---- 2. JS：按文件名排序拼接，外层补回 IIFE 包裹 ----
{
  echo '(function () {'
  echo "  'use strict';"
  for f in "$SRC"/js/*.js; do
    cat "$f"
  done
  echo '})();'
} > "$OUT/app.js"

# ---- 3. 语法与包裹自检（拼错了就别往 app 里拷）----
node -e '
const fs = require("fs");
const code = fs.readFileSync(process.argv[1], "utf8");
if (!code.startsWith("(function () {")) throw new Error("缺少 IIFE 包裹");
new Function(code);
const must = ["function send(", "function persist(", "function renderReport(", "function muted(", "window.__load"];
const miss = must.filter(m => code.indexOf(m) < 0);
if (miss.length) throw new Error("缺少关键定义: " + miss.join(", "));
console.log("bundle ok · " + code.split("\n").length + " 行 · " + (code.length / 1024).toFixed(0) + "KB");
' "$OUT/app.js"
