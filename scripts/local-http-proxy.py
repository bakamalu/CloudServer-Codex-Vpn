#!/usr/bin/env python3
"""极简 HTTP CONNECT 代理（仅本机透传出网，无上游代理）。

用途：Windows 本机直连 OpenAI 可行，但本地没有代理端口。
远端 ECS 通过 `ssh -R 7897:127.0.0.1:7897` 借用本机出网能力。

监听 127.0.0.1:7897，支持 CONNECT 隧道（HTTPS 全部走这条）。
日志写到脚本同目录 proxy.log。
"""

import select
import socket
import sys
import threading
from datetime import datetime
from pathlib import Path

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 7897
BUF = 65536
IDLE_TIMEOUT = 300  # 空闲 5 分钟断开

LOG_PATH = Path(__file__).with_name("proxy.log")
_log_lock = threading.Lock()


def log(msg: str) -> None:
    line = f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}"
    with _log_lock:
        try:
            with LOG_PATH.open("a", encoding="utf-8") as f:
                f.write(line + "\n")
        except Exception:
            pass


def pipe(a: socket.socket, b: socket.socket) -> None:
    """双向转发直到任一侧关闭。"""
    socks = [a, b]
    try:
        while True:
            ready, _, _ = select.select(socks, [], [], IDLE_TIMEOUT)
            if not ready:
                break
            for s in ready:
                data = s.recv(BUF)
                if not data:
                    return
                (b if s is a else a).sendall(data)
    except Exception:
        pass
    finally:
        for s in socks:
            try:
                s.close()
            except Exception:
                pass


def handle(conn: socket.socket, addr) -> None:
    up = None
    try:
        conn.settimeout(30)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = conn.recv(4096)
            if not chunk:
                return
            buf += chunk
            if len(buf) > 131072:
                return

        head, _, rest = buf.partition(b"\r\n\r\n")
        first = head.split(b"\r\n", 1)[0]
        parts = first.split(b" ")
        if len(parts) < 2:
            return
        method, target = parts[0].upper(), parts[1]

        if method != b"CONNECT":
            conn.sendall(
                b"HTTP/1.1 501 Not Implemented\r\n"
                b"Content-Length: 0\r\n\r\n"
            )
            log(f"501 {first.decode('latin-1', 'replace')} from {addr[0]}")
            return

        host_b, _, port_b = target.partition(b":")
        host = host_b.decode()
        port = int(port_b or b"443")
        up = socket.create_connection((host, port), timeout=20)
        conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        if rest:
            up.sendall(rest)
        log(f"CONNECT {host}:{port} from {addr[0]}")
        conn.settimeout(None)
        up.settimeout(None)
        pipe(conn, up)
        up = None
    except Exception as e:
        log(f"ERR {type(e).__name__}: {e}")
        try:
            conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        except Exception:
            pass
    finally:
        for s in (conn, up):
            if s is not None:
                try:
                    s.close()
                except Exception:
                    pass


def main() -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((LISTEN_HOST, LISTEN_PORT))
    srv.listen(128)
    log(f"listening on {LISTEN_HOST}:{LISTEN_PORT}")
    print(f"proxy listening on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    while True:
        try:
            conn, addr = srv.accept()
        except KeyboardInterrupt:
            break
        threading.Thread(target=handle, args=(conn, addr), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main())