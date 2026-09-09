#!/bin/bash
# bmd.sh — Blackmagic 官网(DaVinci Resolve Studio 等)大文件下载一体化工具
# 能力: 自动换最新签名直链(约2h50m寿命) + 断点续传 + CloudFront 全网段优选 + zip CRC 校验
# 依赖: bash + curl + python3；平台: Git Bash(Windows) / Linux / macOS
# 用法: bash bmd.sh link|download|probe ...  (详见 README.md 或 bmd.sh help)
set -u

VERSION="1.0.0"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
CACHE="$HOME/.bmd"; mkdir -p "$CACHE"
PY=""   # 探测可用的python(跳过Windows商店stub, 它无输出)
for _c in python python3; do
  _p=$(command -v "$_c" 2>/dev/null) || continue
  case "$_p" in *WindowsApps*) continue ;; esac
  if echo '{}' | "$_p" -c "import sys,json" >/dev/null 2>&1; then PY="$_p"; break; fi
done
API="https://www.blackmagicdesign.com"
DLHOST="sw.blackmagicdesign.com"

log() { echo "[$(date '+%F %T')] $*" >&2; }   # 永远走stderr, 不污染被捕获的stdout
fsize() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo 0; }  # GNU/BSD(macOS)兼容
load_edges() { # $1=目标数组名; 从 ips.txt 读前5个IP (不用mapfile, 兼容macOS bash3)
  local _arr=$1 _l; eval "$_arr=()"
  while IFS= read -r _l; do [ -n "$_l" ] && eval "$_arr+=(\"\$_l\")"; done \
    < <(awk '!/^#/{print $1}' "$CACHE/ips.txt" 2>/dev/null | head -5)
}

usage() {
  cat <<'EOF'
bmd.sh — Blackmagic 官网大文件下载一体化工具 v1.0.0

用法:
  bmd.sh link <studio|free> <windows|winarm|mac|linux>
      查最新版本并换取直链, 打印 URL/大小/有效期 (可粘到 IDM/FDM/浏览器)
  bmd.sh download <studio|free> <windows|winarm|mac|linux> [保存目录] [--no-probe|--probe]
      全自动下载: 换链 → 优选节点 → 断点续传 → 自动换链/换节点 → zip CRC 校验
      --no-probe  跳过优选测速, 用默认 DNS
      --probe     强制重新优选(忽略缓存; 海外直连型网络默认跳过优选, 用它强制)
  bmd.sh probe [--quick]
      CloudFront 优选测速, 两段并行(粗筛1MB×并发8 → 前16精测8MB×并发4)
      全量约1-3分钟, --quick 只重测已知节点约半分钟
      结果存 ~/.bmd/ips.txt, 12小时内自动复用

环境变量:
  BMD_PROXY=socks5h://127.0.0.1:10808   手动指定访问官网API用的代理(仅API, 下载永远直连)
  BMD_LIMIT=2097152                     测试模式: 只下载前N字节

缓存目录 ~/.bmd/: 直链(自动按有效期复用) / 优选IP排名 / 代理探测结果
EOF
}

# ---------- 代理探测与路由(只用于官网API; 下载文件永远直连) ----------
# 路由 token: direct=https直连 | direct-http=http明文直连 | 其他=经该代理URL的https
# curl 的 NO_PROXY 环境变量优先级高于显式 -x/--proxy: NO_PROXY=* 会把代理测试静默变直连;
# 反之 https_proxy/ALL_PROXY 会让"必须直连"的请求静默走代理。所以每处 curl 都用
# --noproxy 显式钉死: 带代理的请求用空列表(不排除任何主机), 直连的请求用 '*'(排除全部)。
# BMD 自家边缘(openresty, TLS对端持 DigiCert 签发的 *.blackmagicdesign.com 真证书)对大陆
# 来源IP全站强制301降级https→http, 但80端口服务完好——无任何代理时回落 direct-http 换链。
want_test() { # $1=路由token; 判定标准: latest-version 返回JSON
  local base="https://www.blackmagicdesign.com" np='*' px=()
  case "${1:-}" in
    ""|direct) ;;
    direct-http) base="http://www.blackmagicdesign.com" ;;
    *) np=''; px=(-x "$1") ;;
  esac
  curl ${px[@]+"${px[@]}"} --noproxy "$np" -s --connect-timeout 8 -m 15 -A "$UA" \
    -H 'Content-Type: application/json' -X POST "$base/api/support/latest-version" \
    -d '{"product":"davinci-resolve-studio","platform":"windows"}' 2>/dev/null \
    | grep -q '"downloadId"'
}
find_proxy() { # → stdout: 路由token(direct|direct-http|代理URL); 全部候选失败输出空串
  local cached=""
  [ -s "$CACHE/proxy" ] && cached=$(cat "$CACHE/proxy")
  if [ -n "$cached" ] && want_test "$cached"; then echo "$cached"; return; fi
  local p
  for p in "${BMD_PROXY:-}" direct direct-http \
           "socks5h://127.0.0.1:7890" "socks5h://127.0.0.1:7897" \
           "socks5h://127.0.0.1:10808" "socks5h://127.0.0.1:10809" "socks5h://127.0.0.1:1080" \
           "${ALL_PROXY:-}" "${https_proxy:-}"; do
    [ -n "$p" ] || continue
    if want_test "$p"; then echo "$p" > "$CACHE/proxy"; echo "$p"; return; fi
  done
  echo ""; return
}
set_route() { # $1=find_proxy输出的token → 设置 route_base/route_np/route_px; 空token返回1
  route_base="https://www.blackmagicdesign.com"; route_np='*'; route_px=()
  case "${1:-}" in
    direct) ;;
    direct-http)
      route_base="http://www.blackmagicdesign.com"
      if [ ! -f "$CACHE/http_warned" ]; then : > "$CACHE/http_warned"  # apicall常在$()子shell中执行, 变量防重不跨子shell, 用标志文件
        log "⚠️ 无可用代理, 官网API回落 http 明文直连(BMD边缘对大陆IP强制301降级, 80端口服务完好)"
        log "   明文通道理论上可被篡改, 已强制校验直链域名; 换到的http签名直链无法升级https(改写即404), 下载完成后zip CRC校验兜底; 建议配置 BMD_PROXY"
      fi ;;
    "") return 1 ;;
    *) route_np=''; route_px=(-x "$1") ;;
  esac
  return 0
}

apicall() { # apicall <method> <path> [data]   (自动带路由/浏览器UA/会话cookie, 缺一样WAF就403)
  local p; p=$(find_proxy)
  set_route "$p" || { echo "PROXY_FAIL"; return; }
  curl ${route_px[@]+"${route_px[@]}"} --noproxy "$route_np" -s --connect-timeout 15 -m 40 -A "$UA" -b "$CACHE/ck" \
    -H 'Content-Type: application/json;charset=UTF-8' \
    -H 'Accept: application/json, text/plain, */*' \
    -H "Origin: $route_base" -H "Referer: $route_base/products/davinciresolve/download" \
    -H 'X-Requested-With: XMLHttpRequest' -X "$1" "$route_base$2" ${3:+-d "$3"}
}

sess() { # 官网WAF要求: POST register 前先访问页面拿会话cookie
  local p; p=$(find_proxy)
  set_route "$p" || return 1
  [ "$p" = "direct-http" ] && rm -f "$CACHE/ck"  # 旧jar中Secure标记的cookie不会随http发送, 重建
  curl ${route_px[@]+"${route_px[@]}"} --noproxy "$route_np" -s -c "$CACHE/ck" --connect-timeout 15 -A "$UA" \
    "$route_base/products/davinciresolve/download" -o /dev/null
}

# ---------- 换直链(带缓存+限流退避) ----------
get_link() { # get_link <studio|free> <platform>  → stdout: URL
  local key=$1 plat=$2 prod
  case "$key" in
    studio) prod="davinci-resolve-studio" ;;
    free)   prod="davinci-resolve" ;;
    *) return 1 ;;
  esac
  local ver; ver=$(apicall POST /api/support/latest-version "{\"product\":\"$prod\",\"platform\":\"$plat\"}")
  if [ -z "$ver" ] || [ "$ver" = "PROXY_FAIL" ]; then log "官网API不可达(代理探测失败), 可设 BMD_PROXY=socks5h://ip:端口 重试"; return 1; fi
  local did; did=$(echo "$ver" | "$PY" -c "import sys,json;d=(json.load(sys.stdin).get('$plat') or {});print(d.get('downloadId',''))" 2>/dev/null)
  if [ -z "$did" ]; then log "查最新版本失败: $(echo "$ver" | head -c 80)"; return 1; fi
  local vinfo; vinfo=$(echo "$ver" | "$PY" -c "import sys,json;d=(json.load(sys.stdin).get('$plat') or {});print('%s.%s b%s'%(d.get('major','?'),d.get('minor','?'),d.get('build','?')))" 2>/dev/null)
  log "最新版本: $key $vinfo ($plat)"
  local f="$CACHE/url_$did" u exp now
  if [ -s "$f" ]; then  # 未过期(>10分钟)的链接直接复用, 省限流额度
    u=$(cat "$f"); exp=$(echo "$u" | sed 's/.*Expires=//' | tr -dc '0-9'); now=$(date +%s)
    if [ -n "$exp" ] && [ "$exp" -gt $((now+600)) ]; then echo "$u"; return; fi
  fi
  local i
  for i in 1 2 3; do
    sess
    u=$(apicall POST "/api/register/us/download/$did" '{"country":"US","origin":"www.blackmagicdesign.com"}')
    if echo "$u" | grep -q '^https\?://'; then
      # http路由下register回显http签名直链: CloudFront签名按协议生成, 改写成https会404(实测), 只能原样使用
      case "$u" in  # http明文路由下换链响应可能被篡改, 强制校验直链域名
        https://*.blackmagicdesign.com/*|http://*.blackmagicdesign.com/*) ;;
        *) log "换链返回的直链域名异常, 拒绝使用: $(echo "$u" | head -c 60)"; return 1 ;;
      esac
      echo "$u" > "$f"; echo "$u"; return; fi
    if echo "$u" | grep -q 'Must register'; then
      log "免费版需要完整注册表单, 本脚本只支持 Studio 免表单流程; 免费版请去官网页面下载"; return 1
    fi
    log "换链接失败(第${i}次): $(echo "$u" | head -c 60)  (持续403=限流, 每小时约3次/IP)"
    sleep $((i*20))
  done
  return 1
}

# ---------- CloudFront 优选 ----------
edges_fresh() { # ~/.bmd/ips.txt 存在、有可用节点且 <12h → 真
  [ -s "$CACHE/ips.txt" ] || return 1
  [ "$(grep -c -v '^#' "$CACHE/ips.txt")" -ge 1 ] || return 1  # 优选全灭只剩表头不算有效缓存, 否则会跳过重测12h
  local ts; ts=$(awk 'NR==1{print $2}' "$CACHE/ips.txt" 2>/dev/null)
  [ -n "$ts" ] && [ $(( $(date +%s) - ts )) -lt 43200 ]
}

probe_one() { # $1=IP $2=样本字节 $3=最长秒 $4=结果文件 → 追加 "ip code speed" 行(并发调用)
  local r
  r=$(curl -s --noproxy '*' --resolve "$DLHOST:443:$1" -r $POFF-$((POFF+$2-1)) -o /dev/null \
      -w '%{http_code} %{speed_download}' --max-time "$3" -A "$UA" "$PURL" 2>/dev/null)
  echo "$1 $r" >> "$4"
}

probe() { # probe [--quick]  → ~/.bmd/ips.txt (两段并行: 粗筛1MB×并发8 → 前16精测8MB×并发4)
  local quick=false; [ "${1:-}" = "--quick" ] && quick=true
  local url; url=$(get_link studio windows) || return 1
  curl -s --noproxy '*' --connect-timeout 10 "https://d7uri8nf7uskq.cloudfront.net/tools/list-cloudfront-ips" -o "$CACHE/cfips.json" \
    || { log "拉取 CloudFront IP 列表失败"; return 1; }
  "$PY" -c "
import json, sys, ipaddress
d = json.load(open(sys.argv[1], encoding='utf-8'))
ranges = d['CLOUDFRONT_GLOBAL_IP_LIST'] + d['CLOUDFRONT_REGIONAL_EDGE_IP_LIST']
CN = ('120.52','180.163','111.13','223.','119.147','120.253','116.129','36.103','120.232','118.193')
seen, ips = set(), []
for r in ranges:
    first = str(ipaddress.ip_network(r).network_address)
    if first.startswith(CN): continue  # CF中国节点只服务ICP备案站, 官网没备案会403
    p16 = first.rsplit('.', 2)[0]
    if p16 not in seen:
        seen.add(p16); ips.append(first)
print('\n'.join(ips))" "$CACHE/cfips.json" | tr -d '\r' > "$CACHE/cand.txt"  # Windows python文本输出是CRLF, \r带入--resolve会让curl秒败
  if $quick && [ -s "$CACHE/ips.txt" ]; then  # quick: 只重测上次的可用节点
    awk '!/^#/{print $1}' "$CACHE/ips.txt" > "$CACHE/cand.txt"
  fi
  local len off; len=$(curl -sI --noproxy '*' --connect-timeout 15 -A "$UA" "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')
  off=$(( ${len:-9600000000} / 2 ))   # 文件中部冷数据, 对所有节点公平
  PURL="$url"; POFF=$off   # 供 probe_one(后台子进程)使用
  local total ip pids=()
  total=$(wc -l < "$CACHE/cand.txt")

  # ---- 第1段: 并行粗筛, 目标是"通且不龟速"(206 且 ≥256KB/s), 排名仅作精测入场券 ----
  log "粗筛 $total 个节点: 每节点1MB样本/最长5秒, 并发8..."
  : > "$CACHE/ips.raw"
  while read -r ip; do
    ip=${ip%$'\r'}; [ -n "$ip" ] || continue   # 双保险: 兜底剥掉可能残留的CR
    probe_one "$ip" 1048576 5 "$CACHE/ips.raw" &
    pids+=($!)
    [ ${#pids[@]} -lt 8 ] || { wait "${pids[@]}"; pids=(); }
  done < "$CACHE/cand.txt"
  [ ${#pids[@]} -gt 0 ] && wait "${pids[@]}"
  local survivors; survivors=$(awk '$2==206 && $3>=262144 {print $1, $3}' "$CACHE/ips.raw" | sort -k2 -rn | head -16 | awk '{print $1}')
  log "粗筛完成: 存活 $(echo "$survivors" | grep -c .) 个"

  # ---- 第2段: 并行精测前16, 大样本定排名; 全军覆没则退回粗筛结果 ----
  local src="$CACHE/ips.raw"
  if [ -n "$survivors" ]; then
    log "精测存活前16: 每节点8MB样本/最长8秒, 并发4..."
    : > "$CACHE/ips2.raw"
    pids=()
    for ip in $survivors; do
      probe_one "$ip" 8388608 8 "$CACHE/ips2.raw" &
      pids+=($!)
      [ ${#pids[@]} -lt 4 ] || { wait "${pids[@]}"; pids=(); }
    done
    [ ${#pids[@]} -gt 0 ] && wait "${pids[@]}"
    awk '$2==206 && $3>0' "$CACHE/ips2.raw" | grep -q . && src="$CACHE/ips2.raw"
  fi
  awk -v ts="$(date +%s)" -v d="$(date '+%F %T')" \
      'BEGIN{print "# "ts" "d} $2==206 && $3>0 {print $1, $3}' "$src" | sort -k2 -rn > "$CACHE/ips.txt"
  log "优选完成, 可用节点 $(($(wc -l < "$CACHE/ips.txt")-1)) 个, Top5:"
  sed -n '2,6p' "$CACHE/ips.txt" | awk '{printf "  %-16s %6.2f MB/s\n", $1, $2/1048576}'
}

# ---------- 下载 ----------
cmd_download() { # download <studio|free> <platform> [outdir] [--no-probe|--probe]
  local key=$1 plat=$2 outdir="." noprobe=false forceprobe=false a
  shift 2
  for a in "$@"; do case "$a" in --no-probe) noprobe=true ;; --probe) forceprobe=true ;; *) outdir="$a" ;; esac; done
  # Git Bash 下 "D:/中文目录" 风格路径: MSYS stat 可能拿不到大小, 续传判断失效会从0重写文件
  # (实测踩坑)。统一转成 /d/... MSYS 风格, stat 与 原生curl(经MSYS参数转换) 都能正确处理。
  case "$outdir" in [A-Za-z]:[/\\]*) command -v cygpath >/dev/null 2>&1 && outdir=$(cygpath -u "$outdir") ;; esac
  mkdir -p "$outdir" || return 1
  local url; url=$(get_link "$key" "$plat") || return 1
  local fname; fname=$(basename "${url%%\?*}")
  local expected; expected=$(curl -sI --noproxy '*' --connect-timeout 15 -A "$UA" "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')
  [ -n "${BMD_LIMIT:-}" ] && expected=$BMD_LIMIT   # 测试模式: 只下前N字节
  [ -n "$expected" ] || { log "HEAD 获取大小失败"; return 1; }
  log "文件: $fname  大小: $expected 字节  保存到: $outdir"

  if ! $noprobe; then
    local route; route=$(cat "$CACHE/proxy" 2>/dev/null)   # get_link 刚刷新过的 API 路由
    if $forceprobe; then
      probe || log "测速失败, 回退默认DNS"
    elif [ "$route" = "direct" ]; then
      log "API 可 https 直达(海外型网络), 跳过前置优选; 默认DNS不佳时会在卡速后自动触发测速"
    elif edges_fresh; then
      log "用近期优选缓存, 最快节点: $(awk 'NR==2{print $1" ("int($2/1048576*100)/100" MB/s)"}' "$CACHE/ips.txt")"
    else
      log "无近期(<12h)优选结果, 先两段并行测速(约1-3分钟)..."
      probe || log "测速失败, 回退默认DNS"
    fi
  fi
  local edges=(); load_edges edges
  local ei=0 tries=0 stall=0
  while :; do
    local size; size=$(fsize "$outdir/$fname")
    if [ "$size" -ge "$expected" ]; then
      log "下载完成: $size 字节"
      if [ -z "${BMD_LIMIT:-}" ] && [[ "$fname" == *.zip ]]; then
        local zpath="$outdir/$fname"
        command -v cygpath >/dev/null 2>&1 && zpath=$(cygpath -w "$zpath")  # env变量不做MSYS自动转换,需手动转Windows路径
        log "zip CRC 校验中(9-10GB约需1-3分钟)..."
        local crc; crc=$(BMD_ZIP="$zpath" "$PY" -c "
import os, zipfile
p = os.environ['BMD_ZIP']
bad = zipfile.ZipFile(p).testzip()
print('CRC_OK' if bad is None else 'CRC_BAD:'+bad)")
        log "CRC: $crc"
        if [ "$crc" = CRC_OK ]; then
          log "✅ 校验通过, 文件完好: $outdir/$fname"
        else
          log "❌ CRC校验失败! 删除残文件重跑"; return 1
        fi
      fi
      return 0
    fi
    tries=$((tries+1)); [ $tries -gt 2000 ] && { log "重试次数用尽, 重跑本命令可续传"; return 1; }
    local res=() range=(-C -)
    [ -n "${BMD_LIMIT:-}" ] && range=(-r 0-$((BMD_LIMIT-1)))   # 测试模式: 只要前N字节
    [ ${#edges[@]} -gt 0 ] && res=(--resolve "$DLHOST:443:${edges[$ei]}")
    log "try=$tries 已下 $((size/1024/1024))MB/$((expected/1024/1024))MB ($(awk "BEGIN{printf \"%.1f%%\", $size*100/$expected}")) 节点=${edges[$ei]:-默认DNS}"
    local http; http=$(curl -sfL --noproxy '*' "${range[@]}" -o "$outdir/$fname" --connect-timeout 15 \
        --speed-time 45 --speed-limit 102400 -A "$UA" ${res[@]+"${res[@]}"} \
        -w '%{http_code}' "$url" 2>/dev/null)
    local rc=$?
    local nsz; nsz=$(fsize "$outdir/$fname")
    [ "$nsz" -ge "$expected" ] && continue
    if [ $rc -eq 22 ] && [ "$http" = "403" ]; then
      log "链接过期, 自动换新..."; url=$(get_link "$key" "$plat") || return 1; sleep 2; continue
    fi
    if [ $rc -eq 28 ] || [ $rc -eq 7 ]; then  # 卡速/连不上 → 轮换优选节点
      stall=$((stall+1))
      if [ ${#edges[@]} -gt 1 ]; then
        ei=$(( (ei+1) % ${#edges[@]} )); log "速度不佳, 切换节点 → ${edges[$ei]} (第${stall}次)"
      fi
      local rth=6; [ ${#edges[@]} -eq 0 ] && rth=2   # 手里没有优选节点时更早触发重测
      if [ $stall -ge $rth ]; then
        log "连续${stall}次断流, 重测优选..."
        probe && load_edges edges
        ei=0; stall=0
      fi
    else
      log "断开 rc=$rc http=$http 本轮+$((nsz-size))B, 2秒后续传"
    fi
    sleep 2
  done
}

cmd_link() { # link <studio|free> <platform>
  local url; url=$(get_link "$1" "$2") || return 1
  local exp; exp=$(echo "$url" | sed 's/.*Expires=//' | tr -dc '0-9')
  local len; len=$(curl -sI --noproxy '*' --connect-timeout 15 -A "$UA" "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')
  echo "文件: $(basename "${url%%\?*}")"
  echo "大小: ${len:-?} 字节"
  echo "有效期至: $("$PY" -c "import time;print(time.strftime('%F %T', time.localtime($exp)))") (剩 $(( (exp-$(date +%s))/60 )) 分钟)"
  echo
  echo "$url"
  echo
  echo "提示: 链接寿命约2小时50分, 过期重新跑本命令即可; 可粘到浏览器/IDM立即下载"
}

case "${1:-}" in
  link)     shift; cmd_link "${1:-studio}" "${2:-windows}" ;;
  download) shift; cmd_download "${1:-studio}" "${2:-windows}" "${3:-.}" ;;
  probe)    shift; probe "${1:-}" ;;
  help|-h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac
