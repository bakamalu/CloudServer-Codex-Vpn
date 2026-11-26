#!/usr/bin/env bash
# 远端自建 mihomo（Clash Meta）代理，供 gcmp 的 Codex CLI 使用
#
# 用法：
#   bash install-mihomo.sh                        仅安装内核 + 空配置
#   bash install-mihomo.sh "<Clash订阅URL>"        安装并写入订阅
#   bash install-mihomo.sh --sub-file /path/clash.yaml  用本地已下载的配置
#
# 端口统一 7897，与 /usr/local/bin/codex 包装脚本约定一致。

set -euo pipefail

PORT=7897
CTRL_PORT=9090
DIR=/etc/mihomo
BIN=/usr/local/bin/mihomo
SVC=/etc/systemd/system/mihomo.service
ARCH=amd64

log() { printf '\033[32m[mihomo]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行"

# ---------- 1. 安装内核 ----------
if [ -x "$BIN" ]; then
  log "内核已存在：$($BIN -v 2>/dev/null | head -1)"
else
  log "查询最新版本…"
  VER=$(curl -fsSL --max-time 20 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
        | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)
  [ -n "${VER:-}" ] || die "无法获取版本号（GitHub API 不可达）"
  log "版本 $VER"

  URL="https://github.com/MetaCubeX/mihomo/releases/download/${VER}/mihomo-linux-${ARCH}-${VER}.gz"
  TMP=$(mktemp -d)
  log "下载 $URL"
  if ! curl -fL --max-time 180 -o "$TMP/m.gz" "$URL"; then
    log "GitHub 直连失败，改用镜像 ghfast.top"
    curl -fL --max-time 180 -o "$TMP/m.gz" "https://ghfast.top/${URL}" \
      || die "下载失败，请手动下载 mihomo-linux-${ARCH}-${VER}.gz 并放到 $TMP"
  fi
  gzip -dc "$TMP/m.gz" > "$BIN"
  chmod +x "$BIN"
  rm -rf "$TMP"
  log "内核安装完成：$($BIN -v 2>/dev/null | head -1)"
fi

mkdir -p "$DIR"

# ---------- 2. 配置 ----------
write_base_config() {
  cat > "$DIR/config.yaml" <<'YAML'
mixed-port: 7897
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: warning
ipv6: false
external-controller: 127.0.0.1:9090
profile:
  store-selected: true
  store-fake-ip: true
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
  fallback:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
proxies: []
proxy-groups: []
rules:
  - GEOIP,CN,DIRECT
  - MATCH,DIRECT
YAML
  log "已写入基础配置（无节点，仅直连）"
}

case "${1:-}" in
  --sub-file)
    SRC="${2:-}"; [ -f "$SRC" ] || die "配置文件不存在：$SRC"
    cp "$SRC" "$DIR/config.yaml"
    log "已导入 $SRC -> $DIR/config.yaml"
    ;;
  "")
    [ -f "$DIR/config.yaml" ] || write_base_config
    log "复用已有配置 $DIR/config.yaml"
    ;;
  *)
    SUB="$1"
    log "下载 Clash 订阅…"
    curl -fL --max-time 60 -A 'clash-meta/1.19' -o "$DIR/config.yaml" "$SUB" \
      || die "订阅下载失败"
    # 去掉 BOM，并统一端口
    sed -i '1s/^\xEF\xBB\xBF//' "$DIR/config.yaml"
    if grep -qE '^mixed-port:' "$DIR/config.yaml"; then
      sed -i -E "s#^mixed-port:.*#mixed-port: ${PORT}#" "$DIR/config.yaml"
    elif grep -qE '^port:' "$DIR/config.yaml"; then
      log "订阅使用 port/socks-port 写法，改用 mixed-port"
      sed -i -E "/^(port|socks-port|redir-port|tproxy-port):/d" "$DIR/config.yaml"
      sed -i "1i mixed-port: ${PORT}" "$DIR/config.yaml"
    else
      sed -i "1i mixed-port: ${PORT}" "$DIR/config.yaml"
    fi
    grep -qE '^allow-lan:' "$DIR/config.yaml" && sed -i -E 's#^allow-lan:.*#allow-lan: false#' "$DIR/config.yaml"
    grep -qE '^external-controller:' "$DIR/config.yaml" && sed -i -E "s#^external-controller:.*#external-controller: 127.0.0.1:${CTRL_PORT}#" "$DIR/config.yaml"
    log "订阅已写入，mixed-port=${PORT}"
    ;;
esac

# ---------- 3. systemd ----------
cat > "$SVC" <<UNIT
[Unit]
Description=mihomo proxy (for gcmp Codex CLI)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN} -d ${DIR}
Restart=always
RestartSec=3
LimitNOFILE=65535
# 本机内存紧张（1.8G），限制代理进程占用
MemoryMax=180M
MemoryHigh=140M

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable mihomo >/dev/null 2>&1 || true
systemctl restart mihomo
sleep 2

# ---------- 4. 自检 ----------
log "服务状态：$(systemctl is-active mihomo)"
ss -ltn | grep -q "127.0.0.1:${PORT}" && log "端口 ${PORT} 已监听 ✓" || log "端口 ${PORT} 未监听 ✗（检查 journalctl -u mihomo -n 50）"

if grep -qE '^proxies: \[\]' "$DIR/config.yaml" 2>/dev/null; then
  cat <<'TIP'

────────────────────────────────────────────
内核已就绪，但还没有节点。做下面任一件事：

A. 有机场 Clash 订阅链接（推荐）
   bash /root/install-mihomo.sh "https://你的订阅?clash=1"

B. 只有单节点信息（server/port/uuid 等）
   手工编辑 /etc/mihomo/config.yaml 的 proxies: 段，
   然后 systemctl restart mihomo

C. 已有现成 clash/mihomo 配置文件
   bash /root/install-mihomo.sh --sub-file /path/to/clash.yaml

验证：curl -s -x http://127.0.0.1:7897 -o /dev/null -w '%{http_code}\n' https://chatgpt.com
────────────────────────────────────────────
TIP
fi