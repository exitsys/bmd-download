#!/bin/bash
# bmd-server-dl.sh — 海外服务器一键下载最新版 DaVinci Resolve Studio (Windows)
#
# 用法:
#   bash bmd-server-dl.sh              # 下载到当前目录; 中断了重跑同命令即断点续传
# 可选环境变量:
#   BMD_PROXY=socks5h://127.0.0.1:10808  国内机器访问官网API用(仅API; 下载本身永远直连CDN)
#   LIMIT=2097152                        测试用: 只下前N字节
# 依赖: bash + curl + python3
set -u

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
API="https://www.blackmagicdesign.com"
CK=$(mktemp) || exit 1
PX=(); [ -n "${BMD_PROXY:-}" ] && PX=(-x "$BMD_PROXY" --noproxy '')
PY=""   # 探测可用的python(跳过Windows商店stub, 它无输出)
for _c in python3 python; do
  _p=$(command -v "$_c" 2>/dev/null) || continue
  case "$_p" in *WindowsApps*) continue ;; esac
  if echo '{}' | "$_p" -c "import sys,json" >/dev/null 2>&1; then PY="$_p"; break; fi
done

gen_url() { # $1=downloadId → stdout: 签名直链
  curl -s ${PX[@]+"${PX[@]}"} -c "$CK" -A "$UA" "$API/products/davinciresolve/download" -o /dev/null
  local u
  u=$(curl -s ${PX[@]+"${PX[@]}"} -b "$CK" -A "$UA" -X POST "$API/api/register/us/download/$1" \
      -H 'Content-Type: application/json;charset=UTF-8' \
      -H 'Accept: application/json, text/plain, */*' \
      -H "Origin: $API" -H "Referer: $API/products/davinciresolve/download" \
      -H 'X-Requested-With: XMLHttpRequest' \
      -d '{"country":"US","origin":"www.blackmagicdesign.com"}')
  case "$u" in
    https://*.blackmagicdesign.com/*|http://*.blackmagicdesign.com/*) echo "$u"; return 0 ;;
  esac
  echo "换链失败: $(echo "$u" | head -c 80)" >&2; return 1
}

fsize() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo 0; }

# 1) 查最新 Windows 版
VER=$(curl -s ${PX[@]+"${PX[@]}"} -A "$UA" -X POST "$API/api/support/latest-version" \
      -H 'Content-Type: application/json' \
      -d '{"product":"davinci-resolve-studio","platform":"windows"}')
DID=$(echo "$VER" | "$PY" -c 'import sys,json;d=(json.load(sys.stdin).get("windows") or {});print(d.get("downloadId",""))' 2>/dev/null)
[ -n "$DID" ] || { echo "查询最新版本失败: $(echo "$VER" | head -c 100)"; exit 1; }
echo "$VER" | "$PY" -c 'import sys,json;d=(json.load(sys.stdin).get("windows") or {});print("最新版: DaVinci Resolve Studio %s.%s b%s (Windows)"%(d.get("major"),d.get("minor"),d.get("build")))'

URL=$(gen_url "$DID") || exit 1
FNAME=$(basename "${URL%%\?*}")
echo "文件: $FNAME"

# 2) 断点续传下载(重跑续传), 链接过期自动重换
n=0
while :; do
  EXPECTED=$(curl -sI --noproxy '*' -A "$UA" "$URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')
  [ -n "${LIMIT:-}" ] && EXPECTED=$LIMIT
  sz=$(fsize "$FNAME")
  if [ -n "$EXPECTED" ] && [ "$sz" -ge "$EXPECTED" ]; then break; fi
  n=$((n+1)); [ $n -gt 100 ] && { echo "重试次数用尽, 重跑本脚本可续传"; exit 1; }
  RANGE=(-C -); [ -n "${LIMIT:-}" ] && RANGE=(-r 0-$((LIMIT-1)))
  curl -fL --noproxy '*' "${RANGE[@]}" -A "$UA" -o "$FNAME" \
       --speed-time 60 --speed-limit 51200 "$URL"
  rc=$?
  if [ $rc -eq 22 ]; then echo "链接过期, 自动换新..."; URL=$(gen_url "$DID") || exit 1; fi
  sleep 2
done

# 3) 校验: 大小 + zip CRC
sz=$(fsize "$FNAME")
[ -z "${LIMIT:-}" ] || exit 0   # 测试模式跳过校验
[ "$sz" = "$EXPECTED" ] || { echo "❌ 大小不符: $sz / $EXPECTED"; exit 1; }
echo "大小校验通过: $sz 字节; zip CRC 校验中..."
if BMD_ZIP="$FNAME" "$PY" -c 'import os,zipfile
print("CRC_OK" if zipfile.ZipFile(os.environ["BMD_ZIP"]).testzip() is None else "CRC_BAD")' | grep -q CRC_OK; then
  echo "✅ 完成: $FNAME"
else
  echo "❌ CRC 校验失败, 删除后重跑"; exit 1
fi
