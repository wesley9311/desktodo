#!/bin/bash
# 建一张只给本机用的自签证书，放在独立钥匙串里（不碰你的 login 钥匙串内容）。
# 目的：让 app 的"指定要求"变成「bundle id + 证书」，而不是 cdhash。
#       ad-hoc 签名的 cdhash 每次重建都变 → 系统把新二进制当陌生程序 → 日历/提醒/磁盘权限清零。
# 撤销：security delete-keychain ~/Library/Keychains/desktodo-signing.keychain-db
set -euo pipefail

KC="$HOME/Library/Keychains/desktodo-signing.keychain-db"
PASSFILE="$HOME/.desktodo-signing-pass"
CN="DeskTodo Local Signing"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$CN"; then
  echo "证书已存在，无需重建：$KC"
  exit 0
fi

if [ -f "$PASSFILE" ]; then PASS="$(cat "$PASSFILE")"; else
  PASS="$(openssl rand -hex 18)"; (umask 077; printf '%s' "$PASS" > "$PASSFILE")
fi

echo "==> 建独立钥匙串"
rm -f "$KC"
security create-keychain -p "$PASS" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$PASS" "$KC"

echo "==> 生成证书（10 年，仅代码签名）"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$CN/O=DeskTodo Local/C=CN" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

echo "==> 导入为可签名身份"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$CN" -out "$TMP/id.p12" -passout "pass:$PASS" \
  -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1 \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -name "$CN" -out "$TMP/id.p12" -passout "pass:$PASS" \
       -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1
security import "$TMP/id.p12" -k "$KC" -P "$PASS" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null 2>&1

echo "==> 校验"
security find-identity -p codesigning "$KC"
echo "完成。私钥在独立钥匙串里，密码在 ${PASSFILE}（600）。"
