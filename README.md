# bmd-download

> Blackmagic 官网大文件（DaVinci Resolve Studio 等 9GB+ 安装包）下载一体化工具
> 专治国内网络下载官网安装包报 **"This URL is invalid or has expired"**、下载无法完成的问题
> 自动换官方直链 + 断点续传 + CloudFront 优选 IP + 完整性校验

## 解决什么问题

在国内网络环境从 Blackmagic 官网下载 DaVinci Resolve 安装包，点击下载后经常直接跳到错误页：

> **This URL is invalid or has expired.**
> If you are not redirected automatically, please locate your download on the Blackmagic Design Support page.

不是慢——是**完全无法开始下载**，反复重试也一样。原因和对策：

| 现象 | 根因 | 本工具的做法 |
|---|---|---|
| 跳转报错 "URL invalid or has expired"，无法下载 | 官网下载用的是短时效的 CloudFront 签名直链（寿命仅约 2 小时 50 分）；国内网络下浏览器这套换链/跳转流程经常走不通，最终拿到的是一个已失效的地址 | 绕开浏览器流程，按官网同款接口现场换新鲜直链并立即开始下载，地址失效自动重换 |
| 偶尔开始下载了，几 GB 的包中途断掉就前功尽弃 | 浏览器对大文件的中断恢复不可靠 | 断点续传，断了从断点继续，9GB 一次下完 |
| 晚高峰速度可能掉到几十 KB/s | 默认 DNS 分到的 CloudFront 边缘节点拥堵 | 全网段优选 IP，下载中卡速自动换节点 |

实测效果（2026-09，国内宽带晚高峰）：报错完全下不了 → 优选节点 16-19 MB/s，9.63GB 的 DaVinci Resolve Studio 21.1 剩余部分 **5 分半下完**。

## 快速开始

依赖：`bash` + `curl` + `python3`（Git Bash / WSL / Linux / macOS 均可）

```bash
git clone https://github.com/exitsys/bmd-download.git
cd bmd-download

# 全自动下载最新版 DaVinci Resolve Studio Windows 安装包到当前目录
bash scripts/bmd.sh download studio windows

# 其他常用法
bash scripts/bmd.sh link studio windows     # 只拿直链(打印URL/大小/有效期), 可粘到 IDM/浏览器
bash scripts/bmd.sh link studio mac         # macOS 版
bash scripts/bmd.sh probe                   # CloudFront 全网段优选测速(约10-15分钟)
bash scripts/bmd.sh probe --quick           # 只重测已知可用节点(约3分钟)
bash scripts/bmd.sh help                    # 完整帮助
```

`download` 一条命令到底：查最新版本 → 换直链 → 优选节点（结果缓存 12 小时）→ 断点续传 → 链接过期自动换 → 速度不佳自动轮换节点 → 下载完成自动做 zip CRC 校验。中断后**重跑同一条命令即续传**。

## 工作原理

### 1. 官网换直链（复刻官方"Download Only"按钮）

官网点下载按钮时，浏览器实际执行的是：

```
POST /api/support/latest-version                    → 查最新版本号和 downloadId
GET  /products/davinciresolve/download              → 拿会话 cookie（WAF 要求）
POST /api/register/us/download/<downloadId>         → 返回 CloudFront 签名直链
```

本脚本用完全相同的请求流（含浏览器 UA 和会话 cookie，缺一样 WAF 直接 403）。这是官网自己暴露给每个浏览器的公开接口，不是破解。

### 2. CloudFront 优选

CloudFront 全球边缘节点共享同一批 IP 段，节点靠 TLS SNI 区分服务哪个域名——**任何边缘 IP 都能服务任何 CloudFront 站点**。脚本拉取 AWS 官方 IP 清单（排除只服务 ICP 备案站的中国网段），对每个网段实测 2MB Range 下载速度，取最快的节点用 `--resolve` 固定下载。

同一批优选结果对**所有** CloudFront 站点通用（如 AWS 官方静态资源）。注意与 Cloudflare 的优选 IP 池互不通用。

### 3. 稳定性设计

- **链接缓存复用**：官网换链接口限流约 3 次/小时/IP，未过期的链接存 `~/.bmd/` 直接复用
- **限流退避**：换链 403 自动指数退避重试，并提示等待窗口
- **代理自动探测**：只用于访问官网 API（国内直连官网 API 会被劫持 301），依次尝试 `BMD_PROXY` → 直连 → 常见本地代理端口（7890/7897/10808/10809/1080）→ 环境变量代理；**下载文件本身永远直连 CDN**
- **卡速自动换节点**：45 秒低于 100KB/s 判定卡速，自动轮换到下一个优选节点；连续 6 次断流自动重测优选

## 作为 AI Agent Skill 安装

本仓库同时是一个 [ZCode](https://zcode.ai) / Claude Code 风格的 skill，装好后直接对 AI 说"帮我下载最新版达芬奇 Studio"即可自动调用：

```bash
# 用户级(所有项目可用)
git clone https://github.com/exitsys/bmd-download.git ~/.agents/skills/bmd-download

# 或项目级(仅当前项目)
git clone https://github.com/exitsys/bmd-download.git .agents/skills/bmd-download
```

## 已知限制

- **免费版不支持**：官网免费版下载接口要求完整注册表单，本脚本只实现 Studio 版的免表单 Download Only 流程；免费版请去官网页面下载
- **限流**：换链接口约 3 次/小时/IP，脚本已做缓存和退避，重度使用请等待或换出口
- **优选结果随时段漂移**：缓存 12 小时自动过期重测；感觉变慢手动跑 `probe`
- **CloudFront 中国网段**（120.52.x / 180.163.x / 111.13.x 等）只服务有 ICP 备案的站点，官网没备案，脚本已自动排除

## FAQ

**Q: 下载报 403 / 换链接失败？**
限流了，等 1 小时，或换网络出口（手机热点等）。

**Q: probe 大量节点显示连不上（000）？**
正常。多数区域边缘节点从国内不可达，看排上名的即可。但若**全部** 000 且一分钟内就"测完"，不是网络问题——是候选列表/参数层错误（典型：Windows Git Bash 下 Python 文本输出 CRLF，IP 带 `\r` 拼进 `--resolve` 使 curl 秒败），检查 `~/.bmd/cand.txt` 行尾。

**Q: 校验失败怎么办？**
删除残留的 zip 重跑，断点续传不会自动修复坏块。

**Q: 想下其它 Blackmagic 产品？**
`latest-version` 接口按 product 查询，改 `get_link` 里的产品名（如 `davinci-resolve`）即可扩展。

## 声明

本工具仅复刻官网浏览器下载按钮的公开 API 请求，用于个人下载官方安装包。请遵守 [Blackmagic Design](https://www.blackmagicdesign.com/) 官网服务条款；Studio 版使用需要正版授权（加密狗 / 激活码 / Cloud 许可）。

## License

[MIT](LICENSE)
