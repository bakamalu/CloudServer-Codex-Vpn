#!/bin/bash
# /usr/local/bin/codex
# 包装 codex.real：仅当 SSH 反向隧道（127.0.0.1:7897）可用时，
# 给 codex 进程注入代理环境变量。VS Code 扩展宿主本身不受影响。
#
# 隧道由本机维持：ssh -N -R 7897:127.0.0.1:7897 remote-server
# 关闭代理：CODEX_NO_PROXY=1 前缀运行

PROXY_PORT="${CODEX_PROXY_PORT:-7897}"
REAL="/usr/local/bin/codex.real"

port_up() {
  ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:${PROXY_PORT}[[:space:]]"
}

if [ -z "$CODEX_NO_PROXY" ]; then
  # 开机后 mihomo 首次配置可能需要 20s，VS Code 可能先于此调用 codex。
  # 最多等 15s（30 × 0.5s），避免"没起来就当没代理"。
  if ! port_up; then
    for _ in $(seq 1 30); do
      sleep 0.5
      port_up && break
    done
  fi

  if port_up; then
    _p="http://127.0.0.1:${PROXY_PORT}"
    export HTTP_PROXY="$_p" http_proxy="$_p"
    export HTTPS_PROXY="$_p" https_proxy="$_p"
    export ALL_PROXY="$_p" all_proxy="$_p"
    export NO_PROXY="127.0.0.1,localhost,::1,0.0.0.0" no_proxy="127.0.0.1,localhost,::1,0.0.0.0"
  fi
fi

exec "$REAL" "$@"