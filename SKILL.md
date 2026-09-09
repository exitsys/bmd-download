---
name: bmd-download
description: 下载 Blackmagic 官网大文件（DaVinci Resolve / DaVinci Resolve Studio 等），解决国内网络下载官网安装包报 "This URL is invalid or has expired"、完全无法下载的问题，以及大文件下载中断、晚高峰速度极慢的问题。只要用户提到达芬奇、DaVinci Resolve、Blackmagic 下载安装包、官网下载链接失效过期报错、下载九个G大文件、CloudFront 优选 IP / 边缘节点测速，就用本 skill。核心能力：官网 API 自动换最新签名直链（Studio 版 Download Only 同款流程）、直连 CloudFront 断点续传、链接失效自动重换、全网段优选 IP 自动测速与自动切换。
---

# BMD Download — Blackmagic 官网大文件下载

把"官网换直链 → 优选 CloudFront 节点 → 断点续传 → 校验"整条链路固化成一个脚本（相对本 skill 目录）：

```bash
bash scripts/bmd.sh <子命令>
```

## 什么时候用

- 用户要下载 DaVinci Resolve / Studio 安装包（任何版本，脚本自动查最新）
- 用户报官网下载跳转报错 **"This URL is invalid or has expired"**、完全无法下载 —— 官网直链是短时效签名 URL，浏览器换链流程在国内网络经常走不通；本 skill 现场换新鲜直链直连下载
- 用户报大文件下载中途断了要重头再来 —— 断点续传，重跑同命令接着下
- 用户要"优选 IP / 测速 CloudFront 节点"

## 子命令速查

```bash
# 拿最新版直链（打印 URL、有效期、文件大小；结果缓存在 ~/.bmd/）
bash scripts/bmd.sh link studio windows       # studio|free × windows|winarm|mac|linux
bash scripts/bmd.sh link free windows

# 全自动下载（推荐）: 换链 → 优选节点(缓存12h) → 断点续传 → 校验大小+zip CRC
bash scripts/bmd.sh download studio windows            # 下载到当前目录
bash scripts/bmd.sh download studio windows --no-probe # 跳过优选, 用默认DNS
bash scripts/bmd.sh download studio mac /保存目录       # 第3参数=保存目录

# 优选 IP 测速（存 ~/.bmd/ips.txt）
bash scripts/bmd.sh probe              # 全量 116 网段, 约10-15分钟
bash scripts/bmd.sh probe --quick      # 只重测已知节点, 约3分钟
```

典型全程：`download` 一条命令到底，断了自动续、堵了自动换节点、链接过期自动换新链接，完成后自动 zip CRC 校验。中断后重跑同一条命令即续传。

## 必须知道的行为细节（脚本已内置，解释给用户时用）

| 现象/坑 | 原因与处理 |
|---|---|
| 直链"过期" | CloudFront 签名 URL 寿命约 2h50m，重新生成即可，不限次数 |
| 换链接接口 403 | 每个 IP 每小时限约 3 次；脚本缓存未过期链接、自动退避重试 |
| API 必须带浏览器 UA + 先访问页面拿 cookie | WAF 规则，缺一个就 403/400，脚本已内置 |
| 官网 API 要代理、下载不要代理 | 国内直连官网 API 会被 openresty 301 劫持；下载文件必须直连 CloudFront（走代理必慢必断）。脚本自动探测代理（env `BMD_PROXY` 可指定，如 `socks5h://127.0.0.1:10808`） |
| 默认 DNS 节点晚高峰可能堵到 <50KB/s | 优选后同文件可达 16-19 MB/s；结果存 `~/.bmd/ips.txt`，超 12 小时自动重测 |
| CF 中国网段(120.52.x/180.163.x/111.13.x) | 只服务有 ICP 备案的站，BMD 没备案，连了 403，脚本已排除 |
| 172.64.x.x 等 Cloudflare IP | 服务不了 CloudFront 的域名（证书不匹配），别拿来优选 BMD |
| 免费版 vs Studio | Studio 走免表单的 Download Only 接口；免费版接口要求完整注册表单，本 skill 只支持 Studio 免表单流程，免费版让用户去官网页面下 |

## 输出与产物

- `link` 输出：版本号、文件名、字节数、直链（一行）、有效期截止时间
- `download` 完成判定：字节数与 HEAD Content-Length 完全相等 + python zipfile CRC 全过；两个都过才算成功
- 优选缓存：`~/.bmd/ips.txt`（IP、速度B/s、测速时间，按速度降序）
- 链接缓存：`~/.bmd/url_<downloadId>.txt`（剩余有效期 >10 分钟就复用，省限流额度）

## 环境要求

Git Bash (Windows) 或 Linux/macOS；curl、python/python3。代理自动探测顺序：`BMD_PROXY` env → 直连测试 → 127.0.0.1 常见端口 (7890/7897/10808/10809/1080) → `ALL_PROXY`/`https_proxy` env。海外服务器直连即可，脚本探测会自动跳过代理。脚本所有 curl 均用 `--noproxy` 显式钉死代理行为，`NO_PROXY=*` 或全局 `https_proxy` 等环境变量不会造成干扰。

## 失败排查

- `link` 报 403 且重试无效：限流了，等 1 小时，或换网络出口
- `probe` 大量 000：正常，多数区域边缘节点从国内不可达，看排上名的即可
- `probe` **全部** 000 且一分钟内"测完"：不是网络问题，是参数层错误（典型：候选列表 `~/.bmd/cand.txt` 行尾带 `\r`，IP 拼进 `--resolve` 后 curl 秒败）——限时循环以不可能的速度完成，说明请求根本没发出去
- `download` 反复断：看日志 rc 码，rc=28 超时会自动换下一个优选节点；链接过期(403)自动换链
- 校验失败：删掉残文件重跑，断点续传文件不会自动修复坏块
