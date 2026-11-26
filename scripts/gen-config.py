#!/usr/bin/env python3
"""根据机场订阅重建 mihomo 配置：直连优先，失败自动切代理。

- proxy-groups.直连优先 : fallback，成员顺序 DIRECT -> 节点1 -> 节点2 ...
  健康检查 url 用境外 204，DIRECT 探不通时自动落到节点。
- proxy-groups.手动选择 : select，可在面板里手动指定。
- 规则：OpenAI 相关域名 -> 直连优先；国内 IP -> DIRECT；其余 -> 直连优先。

用法: python3 gen-config.py <订阅yaml> <目标config.yaml>
"""
import os
import sys

import yaml

SRC = sys.argv[1] if len(sys.argv) > 1 else "/tmp/sub.txt"
DST = sys.argv[2] if len(sys.argv) > 2 else "/etc/mihomo/config.yaml"

PROBE_URL = "https://chatgpt.com/"
AUTO = "直连优先"
MANUAL = "手动选择"

with open(SRC, encoding="utf-8") as f:
    sub = yaml.safe_load(f)

proxies = sub.get("proxies") or []
names = [p.get("name") for p in proxies if p.get("name")]
if not names:
    print("ERROR: 订阅里没有 proxies，检查订阅链接或 UA", file=sys.stderr)
    sys.exit(1)

print(f"节点数: {len(names)}")
print("节点: " + " | ".join(names[:12]) + (" ..." if len(names) > 12 else ""))

# fallback 里只放前 3 个节点，控制健康检查开销（这台机器内存/带宽都紧张）
auto_members = ["DIRECT"] + names[:3]

config = {
    "mixed-port": 7897,
    "allow-lan": False,
    "bind-address": "127.0.0.1",
    "mode": "rule",
    "log-level": "info",
    "ipv6": False,
    "unified-delay": True,
    "tcp-concurrent": True,
    "external-controller": "127.0.0.1:9090",
    "profile": {"store-selected": True, "store-fake-ip": True},
    "dns": {
        "enable": True,
        "ipv6": False,
        "enhanced-mode": "fake-ip",
        "fake-ip-range": "198.18.0.1/16",
        "fake-ip-filter": ["+.lan", "+.local", "*.msftconnecttest.com", "*.msftncsi.com"],
        "default-nameserver": ["223.5.5.5", "119.29.29.29"],
        # 必须用 DoH：阿里云本地 UDP DNS 对境外域名返回污染 IP，
        # 会导致节点连接/健康检查全部超时。不能用 1.1.1.1 / 8.8.8.8（被墙）。
        "nameserver": ["https://doh.pub/dns-query", "https://dns.alidns.com/dns-query"],
        "proxy-server-nameserver": ["223.5.5.5", "119.29.29.29"],
    },
    "proxies": proxies,
    "proxy-groups": [
        {
            "name": AUTO,
            "type": "fallback",
            "url": PROBE_URL,
            "interval": 300,
            "timeout": 5000,
            "lazy": False,
            "expected-status": "*",
            "proxies": auto_members,
        },
        {
            "name": MANUAL,
            "type": "select",
            "proxies": [AUTO] + names,
        },
    ],
    "rules": [
        # —— OpenAI / Codex 相关：先直连，不通再代理 ——
        "DOMAIN-SUFFIX,openai.com," + AUTO,
        "DOMAIN-SUFFIX,chatgpt.com," + AUTO,
        "DOMAIN-SUFFIX,chatgpt.livekit.cloud," + AUTO,
        "DOMAIN-SUFFIX,oaistatic.com," + AUTO,
        "DOMAIN-SUFFIX,oaiusercontent.com," + AUTO,
        "DOMAIN-SUFFIX,openai.org," + AUTO,
        # —— 其它境外常用：同样直连优先 ——
        "DOMAIN-SUFFIX,github.com," + AUTO,
        "DOMAIN-SUFFIX,githubusercontent.com," + AUTO,
        "DOMAIN-SUFFIX,anthropic.com," + AUTO,
        # —— 国内直连，不折腾 ——
        "GEOIP,CN,DIRECT",
        "MATCH," + AUTO,
    ],
}

with open(DST, "w", encoding="utf-8") as f:
    yaml.safe_dump(config, f, allow_unicode=True, sort_keys=False)

print(f"已写入 {DST}")
print(f"{AUTO} 成员顺序: {auto_members}")

# 清掉损坏的 GeoSite.dat，避免启动时再次触发下载
for bad in ("/etc/mihomo/GeoSite.dat", "/etc/mihomo/geosite.dat"):
    if os.path.exists(bad):
        os.remove(bad)
        print(f"已删除 {bad}")