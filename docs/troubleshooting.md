# 踩坑记录

本文档记录部署过程中实际遇到的坑，按「症状 → 根因 → 修法」组织。

---

## 1. `dns resolve failed: context deadline exceeded`

**症状**：mihomo 日志报 `[TCP] dial ... error: dns resolve failed`，经代理的 `curl` 返回 `000`。

**根因**：服务器本地 UDP DNS 对境外域名返回**污染 IP**。例如 `chatgpt.com` 被解到 `199.59.148.97`（Facebook 段），拿这个 IP 去连 443 必然超时。

**修法**：不要用系统 DNS 或明文 UDP DNS，改用**国内 DoH**：

```yaml
dns:
  enable: true
  enhanced-mode: fake-ip
  default-nameserver: [223.5.5.5, 119.29.29.29]
  nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  proxy-server-nameserver: [223.5.5.5, 119.29.29.29]   # 解析节点域名
```

实测 `doh.pub` / `dns.alidns.com` 对 `chatgpt.com` 返回正确的 Cloudflare IP。

> 注意：**不要**把 `1.1.1.1` / `8.8.8.8` 的 DoH 写进去。在云服务器上它们本身不可达，会让每次解析都等超时，表现为「配了 DNS 反而更慢/更不通」。

---

## 2. 启动失败：`can't download MMDB: context deadline exceeded`

**症状**：mihomo 反复重启，日志 `Can't find MMDB, start download` → 超时 → `Parse config error: rules[0] [GEOIP,CN,DIRECT]`。

**根因**：规则里用了 `GEOIP` / `GEOSITE` 就会触发 geodata 自动下载，而下载源都在 GitHub —— 服务器直连超时。

**修法**：手动放置地理库文件。

```bash
# jsDelivr 的 release 分支可直接取（实测 7.3MB，有效）
curl -fsSL -o /etc/mihomo/country.mmdb \
  https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb
```

镜像可用性实测：

| 源 | 结果 |
| --- | --- |
| `github.com` 直连 | 超时 |
| `ghfast.top` | HTTP 403 |
| `testingcf.jsdelivr.net` | 可用 |
| `fastly.jsdelivr.net` | 可用 |

另外 `geosite.dat` 从 jsDelivr 下到的文件虽然体积正常（4.2MB），但 `mihomo` 报 `failed to decode geodata file: proto: cannot parse invalid wire-format data`，最终**放弃 GEOSITE 规则**，只保留 `GEOIP,CN,DIRECT`。

---

## 3. 健康检查全超时：`get delay: all proxies timeout`

**症状**：`/group/{name}/delay` 返回全部超时，`fallback` 组永远停在 `DIRECT`，`history` 为空。

**根因**：探测 URL 用了 `https://www.gstatic.com/generate_204`，但 `gstatic.com` 在国内被解析到 `211.95.34.130`（国内 CDN），探测会得出「直连可用」的**错误结论**；叠加 DNS 污染，连节点探测也一起失败。

**修法**：

1. 探测目标换成真正能反映出境能力的域名，例如 `https://chatgpt.com/`
2. 组配置加 `expected-status: "*"`，避免 301/403 被判定为失败

```yaml
proxy-groups:
  - name: 直连优先
    type: fallback
    url: https://chatgpt.com/
    interval: 300
    timeout: 5000
    lazy: false
    expected-status: "*"
    proxies: [DIRECT, 节点A, 节点B]
```

---

## 4. `fallback` 组不主动切节点

**症状**：`DIRECT` 明明连不通，组仍然选中 `DIRECT`。

**根因**：健康检查是定时任务，首次结果出现前组会默认选第一个成员；刚改完配置就立刻测试，会看到「没切换」的假象。

**修法**：改完配置至少等 20s 再看组的 `now` 字段，或用 `/group/{name}/delay` 手动触发一次探测。

---

## 5. `codex exec` 卡在 `Reading additional input from stdin...`

**症状**：非交互执行 codex 时挂住不动。

**根因**：通过 SSH 调用时 stdin 未关闭，codex 认为还有额外输入要读。

**修法**：

```bash
codex exec --skip-git-repo-check --sandbox read-only "你的提示词" < /dev/null
```

---

## 6. `bad interpreter: /bin/bash^M`

**症状**：`scp` 上传脚本后执行报 `bad interpreter: /bin/bash^M: No such file or directory`。

**根因**：Windows 上创建的文件是 CRLF 行尾。

**修法**：

```bash
sed -i 's/\r$//' /path/to/script.sh
```

或依赖仓库里的 `.gitattributes`（`*.sh text eol=lf`）。

---

## 7. 不要往 `~/.bashrc` 或远端 `settings.json` 写代理

**症状**：配了代理后 `gcmp` / `Copilot` 报 `Connection error`。

**根因**：VS Code 远程扩展宿主会继承这些变量，所有扩展的请求都被塞进代理；代理一旦波动（隧道断开、节点挂）全盘报错。

**修法**：代理只注入需要它的进程（本项目用 `codex` 包装脚本）。远端 `~/.vscode-server/data/Machine/settings.json` 里**刻意不写** `http.proxy`。

---

## 8. `ping` 永远不通是正常的

**根因**：`ping` 用 ICMP，而 HTTP CONNECT / SOCKS5 代理只转发 TCP/UDP，协议层面就转不了 ICMP。

**修法**：验证链路请用：

```bash
curl -s -x http://127.0.0.1:7897 -o /dev/null -w "%{http_code}\n" https://chatgpt.com
```

想 `ping` 通只能开 TUN 透明代理，代价是会接管整机路由、有踢掉 SSH 的风险，且对 Codex 使用毫无收益。

---

## 9. 设备码登录不要被中途杀掉

**症状**：`codex login --device-auth` 显示了验证码，但之后一直登录不上。

**根因**：用 `timeout` 包裹或 SSH 断开导致登录进程被终止，设备码随之失效。

**修法**：让它常驻后台，把输出写文件：

```bash
setsid nohup codex login --device-auth > /root/codex-login.log 2>&1 < /dev/null &
tail -f /root/codex-login.log
```

登录完成后 `codex login status` 应显示 `Logged in using ChatGPT`。

---

## 10. `/tmp` 会被清理

**症状**：脚本跑过一次后，订阅文件 `/tmp/sub.txt` 消失，重建配置报 `FileNotFoundError`。

**修法**：把订阅缓存放到 `/root/sub.yaml`，并把订阅 URL 存到 `/etc/mihomo/subscription.url`（权限 600）。