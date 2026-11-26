#!/usr/bin/env bash
# 一键检查 Codex 代理链路是否正常
# 用法: bash verify.sh [代理端口，默认 7897]

set -uo pipefail

PORT="${1:-7897}"
PASS=0
FAIL=0

ok()   { printf '  \033[32m[OK]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m[!!]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33m[--]\033[0m %s\n' "$*"; }

echo "== 1. mihomo 服务"
if systemctl is-active --quiet mihomo 2>/dev/null; then
  ok "mihomo 运行中"
else
  bad "mihomo 未运行（journalctl -u mihomo -n 50）"
fi
if systemctl is-enabled --quiet mihomo 2>/dev/null; then
  ok "已设置开机自启"
else
  warn "未设置开机自启（systemctl enable mihomo）"
fi

echo "== 2. 代理端口"
if ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:${PORT}[[:space:]]"; then
  ok "127.0.0.1:${PORT} 已监听"
else
  bad "127.0.0.1:${PORT} 未监听"
fi

echo "== 3. 出网能力"
CODE=$(curl -s -x "http://127.0.0.1:${PORT}" -o /dev/null -w '%{http_code}' -m 30 https://chatgpt.com 2>/dev/null)
if [ "$CODE" = "200" ]; then
  ok "经代理访问 chatgpt.com -> 200"
else
  bad "经代理访问 chatgpt.com -> ${CODE:-timeout}"
fi

CODE=$(curl -s -x "http://127.0.0.1:${PORT}" -o /dev/null -w '%{http_code}' -m 30 https://api.openai.com/v1/models 2>/dev/null)
if [ "$CODE" = "401" ] || [ "$CODE" = "200" ]; then
  ok "经代理访问 api.openai.com -> ${CODE}（401 = 通了但未带凭据）"
else
  bad "经代理访问 api.openai.com -> ${CODE:-timeout}"
fi

echo "== 4. 直连优先策略"
NOW=$(curl -s -m 10 "http://127.0.0.1:9090/proxies/%E7%9B%B4%E8%BF%9E%E4%BC%98%E5%85%88" 2>/dev/null | grep -oE '"now":"[^"]*"' | cut -d'"' -f4)
if [ -n "$NOW" ]; then
  ok "当前出口: ${NOW}"
else
  warn "读不到 fallback 组状态（外部控制器未开或组名不同）"
fi

echo "== 5. codex"
if command -v codex >/dev/null 2>&1; then
  ok "codex 在 PATH 中: $(command -v codex)"
else
  bad "PATH 中找不到 codex"
fi
if [ -f "$HOME/.codex/auth.json" ]; then
  ok "~/.codex/auth.json 存在"
else
  bad "未登录（codex login --device-auth）"
fi
if codex login status 2>/dev/null | grep -qi "logged in"; then
  ok "登录状态正常"
else
  warn "登录状态异常，见 codex login status"
fi

echo
echo "通过 ${PASS} 项，失败 ${FAIL} 项"
[ "$FAIL" -eq 0 ] || exit 1