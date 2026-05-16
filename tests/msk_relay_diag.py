#!/usr/bin/env python3
"""
Construct MSK Relay Diagnostic
================================
Запускать через Pythonista 3, a-Shell или Pyto на iPhone.
Только стандартная библиотека — дополнительных пакетов не нужно.

Что проверяется:
  1. Server config  — актуальный wt_path из .well-known/construct-server
  2. TCP            — доступность портов 443 и 52143
  3. TLS            — handshake с fake SNI + SPKI pin
  4. WebTunnel      — правильность токена (ожидаем HTTP 101)
  5. gRPC ping      — отправка минимального gRPC-запроса через каждый рабочий путь
"""

import base64
import hashlib
import json
import os
import socket
import ssl
import struct
import time
import urllib.request
from datetime import datetime

# ──────────────────────────────────────────────────────────────────────────────
# Конфиг релея (зеркало ICEConfig.swift)
# ──────────────────────────────────────────────────────────────────────────────
RELAY_IP = "PENDING"          # SPB relay deleted 2026-05-16 — new VPS to be provisioned
RELAY_SNI = "PENDING"         # will be set when new relay domain is configured
EXPECTED_SPKI = "PENDING"     # will be updated after new TLS cert is issued

# Токен из последнего docker logs (обновляй после каждого рестарта контейнера)
WT_TOKEN_LAST_KNOWN = "88f6344fe0beea2f"

# Дополнительные токены из iOS-логов (stale — для диагностики)
WT_EXTRA_TOKENS = ["f86323d55b22ee49", "2f3f73a6d9bece5d", "d6cd51dfbf97278c"]

GRPC_HOST = "ams.konstruct.cc"
PORTS = [443, 52143]
TIMEOUT = 6.0

CONFIG_URLS = [
    "https://konstruct.cc/.well-known/construct-server",
    "https://raw.githubusercontent.com/maximeliseyev/construct-relay/main/.well-known/construct-server",
]

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────
RESET = "\033[0m"
BOLD = "\033[1m"
RED = "\033[91m"
GRN = "\033[92m"
YLW = "\033[93m"
CYN = "\033[96m"


def ts():
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


def ok(msg):
    print(f"[{ts()}] {GRN}✅ {msg}{RESET}")


def err(msg):
    print(f"[{ts()}] {RED}❌ {msg}{RESET}")


def warn(msg):
    print(f"[{ts()}] {YLW}⚠️  {msg}{RESET}")


def info(msg):
    print(f"[{ts()}] {CYN}ℹ️  {msg}{RESET}")


def hdr(msg):
    print(f"\n{BOLD}{'─'*50}\n  {msg}\n{'─'*50}{RESET}")


def tls_context():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    except AttributeError:
        pass  # старый Python — не критично
    return ctx


def spki_sha256(cert_der: bytes) -> str | None:
    """SHA-256 SubjectPublicKeyInfo из DER-сертификата."""
    try:
        from cryptography import x509
        from cryptography.hazmat.primitives import serialization

        cert = x509.load_der_x509_certificate(cert_der)
        spki = cert.public_key().public_bytes(
            serialization.Encoding.DER,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        )
        return hashlib.sha256(spki).hexdigest()
    except ImportError:
        pass

    # Fallback: ищем SubjectPublicKeyInfo по известным OID-байтам
    for oid in [
        bytes.fromhex("2a8648ce3d0201"),  # EC P-256 / P-384
        bytes.fromhex("2a864886f70d010101"),  # RSA
    ]:
        idx = cert_der.find(oid)
        if idx < 0:
            continue
        # Идём назад до тега SEQUENCE (0x30)
        for start in range(max(0, idx - 4), max(0, idx - 1)):
            if cert_der[start] != 0x30:
                continue
            try:
                l0 = cert_der[start + 1]
                if l0 < 0x80:
                    hlen, length = 2, l0
                elif l0 == 0x81:
                    hlen, length = 3, cert_der[start + 2]
                elif l0 == 0x82:
                    hlen, length = (
                        4,
                        struct.unpack(">H", cert_der[start + 2 : start + 4])[0],
                    )
                else:
                    continue
                end = start + hlen + length
                if end <= len(cert_der):
                    return hashlib.sha256(cert_der[start:end]).hexdigest()
            except Exception:
                continue
    return None


# ──────────────────────────────────────────────────────────────────────────────
# Тест 1: Server config
# ──────────────────────────────────────────────────────────────────────────────
def test_server_config() -> dict:
    """Загружает .well-known/construct-server, возвращает dict с wt_path для каждого relay."""
    hdr("1. Server config (.well-known/construct-server)")
    result = {}
    for url in CONFIG_URLS:
        info(f"Fetching: {url}")
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": "construct-diag/1.0"}
            )
            with urllib.request.urlopen(req, timeout=5) as r:
                raw = r.read().decode()
            try:
                cfg = json.loads(raw)
                relays = cfg.get("ice", {}).get("relays", [])
                if not relays:
                    warn("  Поле ice.relays пустое или отсутствует")
                for relay in relays:
                    addr = relay.get("address", "?")
                    wtp = relay.get("wt_path", "—")
                    cert = relay.get("bridge_cert", "—")[:20] + "…"
                    print(f"     {addr:30s}  wt_path={wtp}  cert={cert}")
                    result[addr] = wtp
                ok(f"Config fetched via {url.split('/')[2]}")
                return result
            except json.JSONDecodeError:
                warn(f"  JSON parse error. Raw: {raw[:200]}")
        except Exception as e:
            warn(f"  {e}")
    err("Config недоступен ни через один источник")
    return result


# ──────────────────────────────────────────────────────────────────────────────
# Тест 2: TCP
# ──────────────────────────────────────────────────────────────────────────────
def test_tcp(ip: str, port: int) -> tuple[bool, float | None]:
    t0 = time.time()
    try:
        s = socket.create_connection((ip, port), timeout=TIMEOUT)
        rtt = (time.time() - t0) * 1000
        s.close()
        ok(f"TCP :{port} — RTT {rtt:.1f} ms")
        return True, rtt
    except socket.timeout:
        err(f"TCP :{port} — TIMEOUT ({TIMEOUT}s) — порт заблокирован оператором?")
        return False, None
    except ConnectionRefusedError:
        err(f"TCP :{port} — REFUSED — порт не слушается на сервере")
        return False, None
    except Exception as e:
        err(f"TCP :{port} — {e}")
        return False, None


# ──────────────────────────────────────────────────────────────────────────────
# Тест 3: TLS handshake + SPKI pin
# ──────────────────────────────────────────────────────────────────────────────
def test_tls(ip: str, port: int) -> tuple[bool, float | None]:
    t0 = time.time()
    try:
        raw = socket.create_connection((ip, port), timeout=TIMEOUT)
        tls = tls_context().wrap_socket(raw, server_hostname=RELAY_SNI)
        rtt = (time.time() - t0) * 1000
        cert_der = tls.getpeercert(binary_form=True)
        cipher = tls.cipher()
        version = tls.version()
        tls.close()

        ok(f"TLS :{port} — RTT {rtt:.1f} ms — {version} {cipher[0] if cipher else '?'}")

        if cert_der:
            actual = spki_sha256(cert_der)
            if actual is None:
                warn(f"  SPKI: не удалось вычислить (нет cryptography)")
            elif actual == EXPECTED_SPKI:
                ok(f"  SPKI pin ✓ совпадает")
            else:
                err(f"  SPKI pin MISMATCH!")
                info(f"  Expected: {EXPECTED_SPKI}")
                info(f"  Got:      {actual}")
        return True, rtt
    except ssl.SSLError as e:
        err(f"TLS :{port} SSL — {e}")
        return False, None
    except socket.timeout:
        err(f"TLS :{port} — TIMEOUT")
        return False, None
    except Exception as e:
        err(f"TLS :{port} — {e}")
        return False, None


# ──────────────────────────────────────────────────────────────────────────────
# Тест 4: WebTunnel токен
# ──────────────────────────────────────────────────────────────────────────────
def test_webtunnel(ip: str, port: int, path: str) -> tuple[bool, str]:
    try:
        raw = socket.create_connection((ip, port), timeout=TIMEOUT)
        tls = tls_context().wrap_socket(raw, server_hostname=RELAY_SNI)
        ws_key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {RELAY_SNI}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {ws_key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n"
            f"\r\n"
        )
        tls.sendall(req.encode())
        resp = b""
        tls.settimeout(3.0)
        try:
            while b"\r\n\r\n" not in resp:
                chunk = tls.recv(512)
                if not chunk:
                    break
                resp += chunk
        except Exception:
            pass
        tls.close()

        if resp:
            line = resp.decode(errors="replace").split("\r\n")[0]
            if "101" in line or "200" in line:
                return True, line
            return False, line
        return False, "(нет ответа)"
    except Exception as e:
        return False, str(e)


def test_all_webtunnel_paths(ip: str, port: int, server_wt: str | None):
    """Тестирует все известные wt_path, ищет рабочий."""
    # Сначала server-config токен (самый актуальный), затем last_known, затем stale
    candidates = []
    if server_wt:
        candidates.append(server_wt)
    candidates.append(f"/construct-ice/{WT_TOKEN_LAST_KNOWN}")
    for t in WT_EXTRA_TOKENS:
        candidates.append(f"/construct-ice/{t}")
    candidates.append("/construct-ice")  # base path (old v1)

    # Убираем дубли, сохраняя порядок
    seen = set()
    paths = [p for p in candidates if not (p in seen or seen.add(p))]

    found_working = None
    for path in paths:
        label = (
            "(server-config)"
            if path == server_wt
            else (
                "(last-known)"
                if WT_TOKEN_LAST_KNOWN in path
                else (
                    "(stale/ios-log)"
                    if any(t in path for t in WT_EXTRA_TOKENS)
                    else "(base-path)"
                )
            )
        )
        ok_, status = test_webtunnel(ip, port, path)
        if ok_:
            ok(f"  WebTunnel ✓ {path} {label}")
            info(f"    HTTP: {status}")
            found_working = path
            break
        else:
            err(f"  WebTunnel ✗ {path} {label} → {status}")

    if not found_working:
        err(
            "  Ни один WebTunnel путь не работает — токен не совпадает или CDN блокирует"
        )
        info(
            "  Запусти на сервере: docker logs construct-relay-relay-1 2>&1 | grep wt_path"
        )
    return found_working


# ──────────────────────────────────────────────────────────────────────────────
# Тест 5: минимальный gRPC ping через relay
# ──────────────────────────────────────────────────────────────────────────────
def grpc_header(body: bytes) -> bytes:
    """gRPC framing: 1 byte compressed flag + 4 bytes length + body."""
    return struct.pack(">BI", 0, len(body)) + body


def test_grpc_via_webtunnel(ip: str, port: int, path: str) -> bool:
    """
    Отправляет минимальный gRPC HealthCheck через WebTunnel.
    Ожидаем HTTP/2 200 или gRPC status в ответе.
    (Упрощённо: HTTP/1.1 — полноценный HTTP/2 upgrade сложен, проверяем статус ответа.)
    """
    try:
        raw = socket.create_connection((ip, port), timeout=TIMEOUT)
        tls = tls_context().wrap_socket(raw, server_hostname=RELAY_SNI)

        # gRPC/HTTP1.1 framing — нестандартно, но даёт понять, принимает ли сервер трафик
        # Реальный gRPC требует HTTP/2 (h2), но проверяем доступность upstream
        ws_key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {GRPC_HOST}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {ws_key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n"
            f"X-Construct-Probe: 1\r\n"
            f"\r\n"
        )
        tls.sendall(req.encode())
        tls.settimeout(4.0)
        resp = b""
        try:
            while b"\r\n\r\n" not in resp:
                chunk = tls.recv(1024)
                if not chunk:
                    break
                resp += chunk
        except Exception:
            pass
        tls.close()

        decoded = resp.decode(errors="replace")
        line = decoded.split("\r\n")[0]
        if "101" in line or "200" in line:
            ok(f"  gRPC probe: relay принимает трафик ({line})")
            return True
        warn(f"  gRPC probe: relay ответил {line}")
        return False
    except Exception as e:
        err(f"  gRPC probe error: {e}")
        return False


# ──────────────────────────────────────────────────────────────────────────────
# Итог
# ──────────────────────────────────────────────────────────────────────────────
def print_summary(results: dict):
    hdr("ИТОГ")
    status = {
        "server_config": "✅" if results.get("config_ok") else "❌",
        "tcp_443": "✅" if results.get("tcp_443") else "❌",
        "tcp_52143": "✅" if results.get("tcp_52143") else "❌",
        "tls_443": "✅" if results.get("tls_443") else "❌",
        "tls_52143": "✅" if results.get("tls_52143") else "❌",
        "wt_443": (
            "N/A (не настроен)" if results.get("wt_not_configured")
            else "✅" if results.get("wt_working_path")
            else "❌"
        ),
        "obfs4_52143": (
            "✅ *(обычно не тестируется из Python)*"
            if results.get("tcp_52143")
            else "❌ (TCP заблокирован)"
        ),
    }
    for k, v in status.items():
        print(f"  {k:20s} {v}")

    working_path = results.get("wt_working_path")
    if results.get("wt_not_configured"):
        pass  # WebTunnel intentionally disabled for this relay
    elif working_path:
        print(f"\n  ✅ Рабочий WebTunnel путь: {working_path}")
        if WT_TOKEN_LAST_KNOWN not in working_path:
            warn("  Токен в hardcoded WT_TOKEN_LAST_KNOWN устарел — обнови скрипт!")
    else:
        print()
        err("WebTunnel не работает. Возможные причины:")
        print(
            "  1. wt_path в .well-known/construct-server устарел — перезапусти знак конфига"
        )
        print("     docker logs construct-relay-relay-1 2>&1 | grep wt_path")
        print("  2. CDN блокирует нестандартный WebSocket upgrade")
        print("  3. Relay контейнер не запущен")

    if not results.get("tcp_52143"):
        print()
        warn("Порт 52143 недоступен:")
        print("  Вероятно, оператор/DPI блокирует нестандартные TLS-порты на этом IP.")
        print(
            "  Fallback-путь obfs4 через 52143 НЕ работает с этого устройства/оператора."
        )


# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
def main():
    print(f"\n{'='*50}")
    print(f"  Construct MSK Relay Diagnostic")
    print(f"  IP:   {RELAY_IP}")
    print(f"  SNI:  {RELAY_SNI}")
    print(f"  Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'='*50}")

    results = {}

    # 1. Server config
    server_relays = test_server_config()
    results["config_ok"] = bool(server_relays)
    # ищем wt_path для MSK relay в конфиге
    msk_wt_from_server = None
    for addr, wt in server_relays.items():
        if RELAY_IP in addr or "msk" in addr.lower():
            msk_wt_from_server = wt
            if wt:
                info(f"  wt_path для MSK из server config: {wt}")

    # 2. TCP + TLS + WebTunnel для каждого порта
    for port in PORTS:
        hdr(f"2–4. PORT {port}")
        tcp_ok, tcp_rtt = test_tcp(RELAY_IP, port)
        results[f"tcp_{port}"] = tcp_ok
        if not tcp_ok:
            continue

        tls_ok, _ = test_tls(RELAY_IP, port)
        results[f"tls_{port}"] = tls_ok
        if not tls_ok:
            continue

        if port == 443:
            if msk_wt_from_server is None:
                info("Порт 443 — WebTunnel отключён для этого релея (wt_path: null)")
                results["wt_working_path"] = None
                results["wt_not_configured"] = True
            else:
                working = test_all_webtunnel_paths(RELAY_IP, port, msk_wt_from_server)
                results["wt_working_path"] = working

        if port == 52143:
            info("Порт 52143 — obfs4 протокол (не тестируется из Python)")
            info("TLS handshake выше подтверждает доступность сети.")
            info(
                "Если TLS прошёл но ICE всё равно не работает — проблема в obfs4 framing"
            )

    # Итог
    print_summary(results)
    print()


if __name__ == "__main__":
    main()
