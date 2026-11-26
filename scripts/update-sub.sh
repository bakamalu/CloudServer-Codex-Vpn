#!/usr/bin/env bash
# 更新机场订阅并重建 mihomo 配置（保留「直连优先」策略）
#
# 用法：bash update-sub.sh [订阅URL]
#   不带参数时复用 /etc/mihomo/subscription.url 里记录的链接
#
# 建议加 cron：0 4 * * * bash /root/update-sub.sh >/dev/null 2>&1

set -euo pipefail

URL_FILE=/etc/mihomo/subscription.url
SUB_YAML=/root/sub.yaml

if [ $# -ge 1 ]; then
  printf '%s' "$1" > "$URL_FILE"
  chmod 600 "$URL_FILE"
fi
[ -f "$URL_FILE" ] || { echo "未提供订阅链接，且 $URL_FILE 不存在" >&2; exit 1; }

URL=$(cat "$URL_FILE")
echo "[1/3] 下载订阅"
curl -fsSL --max-time 90 -A 'clash-verge/v2.0' -o "$SUB_YAML.new" "$URL"
# 简单校验：必须含 proxies:
grep -q '^proxies:' "$SUB_YAML.new" || { echo "订阅内容异常（无 proxies）" >&2; rm -f "$SUB_YAML.new"; exit 1; }
mv "$SUB_YAML.new" "$SUB_YAML"

echo "[2/3] 重建配置"
python3 /root/gen-config.py "$SUB_YAML" /etc/mihomo/config.yaml

echo "[3/3] 重载 mihomo"
mihomo -d /etc/mihomo -t >/dev/null && systemctl reload-or-restart mihomo
sleep 3
systemctl is-active mihomo
ss -ltn | grep -q '127.0.0.1:7897' && echo "代理已就绪" || echo "端口未监听，检查 journalctl -u mihomo"