#!/usr/bin/env python3
"""
construct DPI Probe
===================
Запускать через Pythonista 3, a-Shell или Pyto на iPhone.
Только стандартная библиотека — дополнительных пакетов не нужно.

Что проверяется (каждый слой отдельно):
  1. DNS          — время резолюции ams.konstruct.cc
  2. TCP          — время 3-way handshake (чистый сокет)
  3. TLS (real)   — TLS handshake с правильным SNI: ams.konstruct.cc
  4. TLS (fake)   — TLS handshake с fake SNI: www.bing.com → тест на SNI-DPI
  5. HTTP/2       — отправка HTTP/2 preface, ожидание SETTINGS от сервера
  6. gRPC ping    — минимальный gRPC Health Check (если H2 работает)

⚠️  ЗАПУСК НА iOS (a-Shell / Pyto):
  a-Shell использует собственный OpenSSL CA-bundle, в котором может не быть
  ISRG Root X1 (Let's Encrypt). Это вызывает CERTIFICATE_VERIFY_FAILED даже
  через VPN — это артефакт теста, а не DPI. Установи SKIP_TLS_VERIFY = True.
  Тест соединимости (DPI) от этого не страдает — важны timeouts, а не cert.

Интерпретация:
  TCP ok, TLS (real) иногда fail → SNI-based DPI (ТСПУ)
  TLS ok, HTTP/2 иногда fail    → HTTP/2 / gRPC content inspection
  Высокий jitter при T_h2       → DPI «задерживает» пакеты до классификации
  TLS (fake) ok, TLS (real) fail → точный DPI по SNI ams.konstruct.cc
"""

import socket
import ssl
import statistics
import struct
import sys
import time
from datetime import datetime

# ─────────────────────────────────────────────────────────
TARGET_HOST = "api.divany-kresla.uk"
TARGET_PORT = 443
TIMEOUT = 8.0  # секунды на один тест
RUNS = 10  # количество повторов каждого теста
FAKE_SNI = "www.bing.com"  # нейтральный домен для проверки SNI-блокировки

# ⚠️  iOS / a-Shell: установи True если видишь CERTIFICATE_VERIFY_FAILED через VPN.
# a-Shell использует устаревший CA-bundle без ISRG Root X1 (Let's Encrypt).
# Флаг отключает проверку сертификата — тест DPI по-прежнему корректен
# (мы смотрим на timeouts и success rate, а не на cert validity).
SKIP_TLS_VERIFY = False
# ─────────────────────────────────────────────────────────


# ── HTTP/2 helpers ────────────────────────────────────────

H2_CLIENT_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"


def _h2_frame(type_: int, flags: int, stream_id: int, payload: bytes = b"") -> bytes:
    length = len(payload)
    return (
        struct.pack(">I", length)[1:]
        + bytes([type_, flags])
        + struct.pack(">I", stream_id)
        + payload
    )


H2_SETTINGS = _h2_frame(0x04, 0x00, 0)  # empty SETTINGS (client)
H2_SETTINGS_ACK = _h2_frame(0x04, 0x01, 0)  # SETTINGS ACK


def _read_h2_frame(sock, timeout: float = TIMEOUT) -> tuple[int, int, bytes] | None:
    """Read exactly one HTTP/2 frame. Returns (type, flags, payload) or None on error."""
    sock.settimeout(timeout)
    try:
        header = b""
        while len(header) < 9:
            chunk = sock.recv(9 - len(header))
            if not chunk:
                return None
            header += chunk
        length = (header[0] << 16) | (header[1] << 8) | header[2]
        ftype = header[3]
        flags = header[4]
        payload = b""
        while len(payload) < length:
            chunk = sock.recv(length - len(payload))
            if not chunk:
                return None
            payload += chunk
        return ftype, flags, payload
    except Exception:
        return None


# ── gRPC health check helpers ────────────────────────────


def _grpc_frame(payload: bytes) -> bytes:
    """Wrap protobuf bytes in gRPC length-prefixed frame."""
    return struct.pack(">BI", 0, len(payload)) + payload


def _h2_headers_frame(
    stream_id: int, headers_block: bytes, end_headers: bool = True
) -> bytes:
    flags = 0x04 if end_headers else 0x00
    return _h2_frame(0x01, flags, stream_id, headers_block)


def _build_grpc_headers(path: str, authority: str) -> bytes:
    """Minimal HPACK-encoded headers for a gRPC POST request."""

    def _str(s: str) -> bytes:
        b = s.encode()
        return bytes([len(b)]) + b  # no Huffman encoding

    h = b""
    h += bytes([0x83])  # :method: POST  (static index 3)
    h += bytes([0x87])  # :scheme: https (static index 7)
    # :path — literal with incremental indexing, name index 4 (:path)
    h += bytes([0x44]) + _str(path)
    # :authority — literal with incremental indexing, name index 1
    h += bytes([0x41]) + _str(authority)
    # content-type: application/grpc — name index 31
    h += bytes([0x5F]) + _str("application/grpc")
    # te: trailers — new literal name
    h += bytes([0x40]) + _str("te") + _str("trailers")
    return h


_HEALTH_HEADERS_HPACK = _build_grpc_headers("/grpc.health.v1.Health/Check", TARGET_HOST)

# proto: HealthCheckRequest { service: "" } = empty oneof = 0 bytes
_HEALTH_REQUEST_PROTO = b""

WINDOW_UPDATE_FRAME = _h2_frame(0x08, 0x00, 0, struct.pack(">I", 65535))


# ── Individual tests ──────────────────────────────────────


def test_dns(host: str) -> tuple[float | None, str | None]:
    """Resolve hostname, return (ms, error)."""
    t0 = time.perf_counter()
    try:
        ip = socket.gethostbyname(host)
        ms = (time.perf_counter() - t0) * 1000
        return ms, ip
    except Exception as e:
        return None, str(e)


def test_tcp(ip: str, port: int) -> tuple[float | None, str | None]:
    """Pure TCP connect, return (ms, error)."""
    t0 = time.perf_counter()
    try:
        s = socket.create_connection((ip, port), timeout=TIMEOUT)
        ms = (time.perf_counter() - t0) * 1000
        s.close()
        return ms, None
    except Exception as e:
        return None, str(e)


def test_tls(
    ip: str, port: int, sni: str
) -> tuple[float | None, float | None, str | None]:
    """TCP + TLS handshake. Returns (t_tcp_ms, t_tls_ms, error)."""
    t0 = time.perf_counter()
    t_tcp = None
    try:
        sock = socket.create_connection((ip, port), timeout=TIMEOUT)
        t_tcp = (time.perf_counter() - t0) * 1000

        ctx = ssl.create_default_context()
        # Offer both h2 and http/1.1 — construct relays serve only http/1.1
        # on :443 (h2 ALPN is fingerprinted by ТСПУ DPI). Asking for h2 only
        # gets you a fatal `no_application_protocol` alert from a working
        # relay — that's not DPI, that's our ALPN being wrong.
        ctx.set_alpn_protocols(["h2", "http/1.1"])
        if sni != TARGET_HOST or SKIP_TLS_VERIFY:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE

        tls = ctx.wrap_socket(sock, server_hostname=sni)
        t_tls = (time.perf_counter() - t0) * 1000
        alpn = tls.selected_alpn_protocol()
        tls.close()
        return t_tcp, t_tls, (None if alpn in ("h2", "http/1.1") else f"ALPN={alpn}")
    except Exception as e:
        return t_tcp, None, str(e)


def test_h2(ip: str, port: int, sni: str = TARGET_HOST) -> dict:
    """Full HTTP/2 handshake. Returns timing dict + error."""
    result = {"t_tcp": None, "t_tls": None, "t_h2": None, "error": None}
    t0 = time.perf_counter()
    try:
        sock = socket.create_connection((ip, port), timeout=TIMEOUT)
        result["t_tcp"] = (time.perf_counter() - t0) * 1000

        ctx = ssl.create_default_context()
        ctx.set_alpn_protocols(["h2"])
        if SKIP_TLS_VERIFY:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        tls = ctx.wrap_socket(sock, server_hostname=sni)
        result["t_tls"] = (time.perf_counter() - t0) * 1000

        alpn = tls.selected_alpn_protocol()
        if alpn != "h2":
            result["error"] = f"ALPN not h2: {alpn}"
            tls.close()
            return result

        # Send HTTP/2 client preface + SETTINGS + WINDOW_UPDATE
        tls.sendall(H2_CLIENT_PREFACE + H2_SETTINGS + WINDOW_UPDATE_FRAME)

        # Read until we receive server SETTINGS (type=0x04, flags≠ACK)
        deadline = time.perf_counter() + TIMEOUT
        while time.perf_counter() < deadline:
            frame = _read_h2_frame(tls, timeout=deadline - time.perf_counter())
            if frame is None:
                result["error"] = "connection closed before SETTINGS"
                break
            ftype, flags, _ = frame
            if ftype == 0x04 and (flags & 0x01) == 0:
                result["t_h2"] = (time.perf_counter() - t0) * 1000
                tls.close()
                break
        else:
            if result["t_h2"] is None:
                result["error"] = "SETTINGS timeout"
    except Exception as e:
        result["error"] = str(e)
    return result


def test_grpc_health(ip: str, port: int) -> tuple[float | None, str | None]:
    """Full gRPC round-trip: Health/Check. Returns (total_ms, error)."""
    t0 = time.perf_counter()
    try:
        sock = socket.create_connection((ip, port), timeout=TIMEOUT)
        ctx = ssl.create_default_context()
        ctx.set_alpn_protocols(["h2"])
        if SKIP_TLS_VERIFY:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        tls = ctx.wrap_socket(sock, server_hostname=TARGET_HOST)

        # HTTP/2 handshake
        tls.sendall(H2_CLIENT_PREFACE + H2_SETTINGS + WINDOW_UPDATE_FRAME)

        # Wait for server SETTINGS
        deadline = time.perf_counter() + TIMEOUT
        got_settings = False
        while time.perf_counter() < deadline:
            frame = _read_h2_frame(tls, timeout=deadline - time.perf_counter())
            if frame is None:
                return None, "closed during handshake"
            ftype, flags, payload = frame
            if ftype == 0x04 and (flags & 0x01) == 0:
                got_settings = True
                # ACK server SETTINGS
                tls.sendall(H2_SETTINGS_ACK)
                break

        if not got_settings:
            return None, "no server SETTINGS"

        # Send HEADERS + DATA for Health/Check on stream 1
        grpc_payload = _grpc_frame(_HEALTH_REQUEST_PROTO)
        headers_frame = _h2_frame(0x01, 0x04, 1, _HEALTH_HEADERS_HPACK)
        data_frame = _h2_frame(0x00, 0x01, 1, grpc_payload)  # END_STREAM
        tls.sendall(headers_frame + data_frame)

        # Read until HEADERS or RST_STREAM on stream 1
        deadline = time.perf_counter() + TIMEOUT
        while time.perf_counter() < deadline:
            frame = _read_h2_frame(tls, timeout=deadline - time.perf_counter())
            if frame is None:
                return None, "closed before response"
            ftype, flags, _ = frame
            if ftype == 0x01:  # HEADERS
                ms = (time.perf_counter() - t0) * 1000
                tls.close()
                return ms, None
            if ftype == 0x03:  # RST_STREAM
                return None, "RST_STREAM received"
        return None, "response timeout"

    except Exception as e:
        return None, str(e)


# ── Formatting helpers ────────────────────────────────────


def _ok(ms: float) -> str:
    return f"✅ {ms:6.1f}ms"


def _fail(err: str) -> str:
    short = (err or "?")[:60]
    return f"❌ {short}"


def _stats(values: list[float], total: int) -> str:
    if not values:
        return f"  0/{total} succeeded"
    return (
        f"  {len(values)}/{total} ok  "
        f"avg={statistics.mean(values):.1f}ms  "
        f"min={min(values):.1f}ms  "
        f"max={max(values):.1f}ms"
        + (f"  stdev={statistics.stdev(values):.1f}ms" if len(values) > 1 else "")
    )


# ── Main ──────────────────────────────────────────────────


def run():
    print(f"\n{'═' * 62}")
    print(f"  Construct DPI Probe — {TARGET_HOST}:{TARGET_PORT}")
    print(f"  {RUNS} runs per test  ·  {datetime.now().strftime('%H:%M:%S')}")
    if SKIP_TLS_VERIFY:
        print(
            f"  ⚠️  SKIP_TLS_VERIFY=True — cert not validated (iOS CA bundle workaround)"
        )
    print(f"{'═' * 62}\n")

    # ── DNS ──────────────────────────────────────────────
    print("── 0. DNS ──────────────────────────────────────────────")
    dns_ms, ip_or_err = test_dns(TARGET_HOST)
    if dns_ms is not None:
        print(f"  {TARGET_HOST} → {ip_or_err}  ({dns_ms:.1f}ms)")
        target_ip = ip_or_err
    else:
        print(f"  DNS FAILED: {ip_or_err}")
        return
    print()

    # ── TCP ──────────────────────────────────────────────
    print("── 1. TCP connect ──────────────────────────────────────")
    tcp_times: list[float] = []
    for i in range(RUNS):
        ms, err = test_tcp(target_ip, TARGET_PORT)
        if ms is not None:
            tcp_times.append(ms)
            print(f"  #{i + 1:2d}  {_ok(ms)}")
        else:
            print(f"  #{i + 1:2d}  {_fail(err)}")
    print(_stats(tcp_times, RUNS))
    print()

    # ── TLS real SNI ──────────────────────────────────────
    print(f"── 2. TLS  SNI={TARGET_HOST} (правильный) ─────────────")
    tls_real: list[float] = []
    for i in range(RUNS):
        t_tcp, t_tls, err = test_tls(target_ip, TARGET_PORT, sni=TARGET_HOST)
        if t_tls is not None:
            tls_real.append(t_tls)
            print(f"  #{i + 1:2d}  {_ok(t_tls)}  (tcp={t_tcp:.1f}ms)")
        else:
            print(
                f"  #{i + 1:2d}  {_fail(err)}  tcp={'n/a' if t_tcp is None else f'{t_tcp:.1f}ms'}"
            )
    print(_stats(tls_real, RUNS))
    print()

    # ── TLS fake SNI ──────────────────────────────────────
    print(f"── 3. TLS  SNI={FAKE_SNI} (фейковый) ──────────")
    print(f"     Если этот тест быстрее/надёжнее чем тест 2 → DPI по SNI")
    tls_fake: list[float] = []
    for i in range(RUNS):
        t_tcp, t_tls, err = test_tls(target_ip, TARGET_PORT, sni=FAKE_SNI)
        if t_tls is not None:
            tls_fake.append(t_tls)
            print(f"  #{i + 1:2d}  {_ok(t_tls)}")
        else:
            print(f"  #{i + 1:2d}  {_fail(err)}")
    print(_stats(tls_fake, RUNS))
    print()

    # ── HTTP/2 ────────────────────────────────────────────
    print("── 4. HTTP/2 preface (gRPC channel open) ───────────────")
    h2_times: list[float] = []
    for i in range(RUNS):
        r = test_h2(target_ip, TARGET_PORT)
        if r["t_h2"] is not None:
            h2_times.append(r["t_h2"])
            print(
                f"  #{i + 1:2d}  {_ok(r['t_h2'])}  "
                f"(tcp={r['t_tcp']:.1f}ms  tls={r['t_tls']:.1f}ms)"
            )
        else:
            tcp_s = "n/a" if r["t_tcp"] is None else f"{r['t_tcp']:.1f}ms"
            tls_s = "n/a" if r["t_tls"] is None else f"{r['t_tls']:.1f}ms"
            print(f"  #{i + 1:2d}  {_fail(r['error'])}  tcp={tcp_s}  tls={tls_s}")
    print(_stats(h2_times, RUNS))
    print()

    # ── gRPC Health ───────────────────────────────────────
    print("── 5. gRPC Health/Check (полный round-trip) ────────────")
    grpc_times: list[float] = []
    for i in range(RUNS):
        ms, err = test_grpc_health(target_ip, TARGET_PORT)
        if ms is not None:
            grpc_times.append(ms)
            print(f"  #{i + 1:2d}  {_ok(ms)}")
        else:
            print(f"  #{i + 1:2d}  {_fail(err)}")
    print(_stats(grpc_times, RUNS))
    print()

    # ── Diagnosis ─────────────────────────────────────────
    print("── ДИАГНОЗ ─────────────────────────────────────────────")

    tcp_ok_rate = len(tcp_times) / RUNS
    tls_ok_rate = len(tls_real) / RUNS
    h2_ok_rate = len(h2_times) / RUNS
    grpc_ok_rate = len(grpc_times) / RUNS if grpc_times else 0.0

    no_dpi = True

    if tcp_ok_rate < 1.0:
        print(
            f"  ❌ TCP нестабилен ({tcp_ok_rate * 100:.0f}% ok) → блокировка на уровне IP/TCP"
        )
        no_dpi = False

    elif tls_ok_rate < 0.9:
        print(
            f"  ❌ TLS нестабилен ({tls_ok_rate * 100:.0f}% ok) → DPI по TLS SNI или ключевому обмену"
        )
        no_dpi = False
        if tls_fake and len(tls_fake) / RUNS > tls_ok_rate + 0.1:
            print(
                f"  ⚠️  TLS fake SNI работает лучше ({len(tls_fake) / RUNS * 100:.0f}%)"
            )
            print(f"     → DPI блокирует именно SNI «{TARGET_HOST}»")

    elif h2_ok_rate < 0.9:
        print(
            f"  ❌ HTTP/2 нестабилен ({h2_ok_rate * 100:.0f}% ok) → DPI на HTTP/2 / gRPC уровне"
        )
        no_dpi = False
        if tls_real:
            overhead = (
                statistics.mean(h2_times) - statistics.mean(tls_real) if h2_times else 0
            )
            print(f"     TLS→H2 overhead: {overhead:.1f}ms")

    elif grpc_ok_rate < 0.9:
        print(
            f"  ❌ gRPC нестабилен ({grpc_ok_rate * 100:.0f}% ok) → DPI на уровне gRPC/protobuf"
        )
        no_dpi = False

    if no_dpi and h2_times and tcp_times:
        avg_tcp = statistics.mean(tcp_times)
        avg_h2 = statistics.mean(h2_times)
        overhead = avg_h2 - avg_tcp
        print(f"  ✅ Все слои работают стабильно")
        print(f"     TCP avg:    {avg_tcp:.1f}ms")
        if tls_real:
            avg_tls = statistics.mean(tls_real)
            print(
                f"     TLS avg:    {avg_tls:.1f}ms  (+{avg_tls - avg_tcp:.1f}ms поверх TCP)"
            )
        print(f"     H2 avg:     {avg_h2:.1f}ms  (+{overhead:.1f}ms поверх TCP)")
        if grpc_times:
            print(f"     gRPC avg:   {statistics.mean(grpc_times):.1f}ms")
        if overhead > 500:
            h2_only = avg_h2 - avg_tls if tls_real else overhead
            if h2_only > 300:
                print(
                    f"  ⚠️  H2 SETTINGS overhead над TLS ({h2_only:.0f}ms) высокий (норма <200ms)"
                )
                print(f"     Возможно: сервер медленно обрабатывает HTTP/2 preface")
            else:
                print(f"  ✅ H2 SETTINGS overhead нормальный ({h2_only:.0f}ms)")
                print(f"     Высокий H2 vs TCP объясняется самим TLS (ожидаемо)")
        else:
            print(f"  ✅ Overhead в норме — DPI на этом пути не обнаружен")
            print(
                f"     Если приложение всё равно медленно → проблема в Swift-логике, не в сети"
            )

    # Raw expected RTT
    if h2_times and tls_real:
        # If TCP is suspiciously fast (<5ms), likely routing through a local proxy.
        # Estimate RTT from TLS→H2 delta (≈1 round-trip for SETTINGS exchange).
        avg_tcp = statistics.mean(tcp_times) if tcp_times else 0
        avg_tls = statistics.mean(tls_real)
        avg_h2 = statistics.mean(h2_times)
        h2_overhead = avg_h2 - avg_tls
        if avg_tcp < 5.0:
            rtt_est = h2_overhead
            print(f"\n  RTT оценка (из H2−TLS delta): ~{rtt_est:.0f}ms")
            print(
                f"  (TCP={avg_tcp:.1f}ms — вероятно локальный прокси/VPN, не отражает реальный RTT)"
            )
        else:
            rtt_est = avg_tcp
            print(f"\n  Оценка RTT: ~{rtt_est:.0f}ms")
        print(f"  Теоретический минимум gRPC (TLS 1.3):")
        print(f"    TCP + TLS 1.3 (1-RTT) + H2 = ~{rtt_est * 2:.0f}ms")
        print(f"    С 0-RTT TLS session resumption = ~{rtt_est:.0f}ms")

    print()


if __name__ == "__main__":
    run()
