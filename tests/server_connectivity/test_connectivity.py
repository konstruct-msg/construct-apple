#!/usr/bin/env python3
"""
Construct Server — Layered Connectivity Test
=============================================
Tests each network layer independently so you can pinpoint exactly
where blocking occurs (DPI, TLS mismatch, gRPC, auth, ICE relay, etc.).

Run without VPN, then with VPN and compare results.

Usage:
    python3 test_connectivity.py                   # full test (gRPC + ICE relays)
    python3 test_connectivity.py --no-ice          # skip ICE relay checks
    python3 test_connectivity.py --host ams.konstruct.cc --port 443
    python3 test_connectivity.py --ice-only        # only test ICE relay reachability

ICE relay architecture:
    Primary : ice.ams.konstruct.cc:443  — TLS-wrapped obfs4 (DPI-resistant)
    Relay   : ice.msk.konstruct.cc:9443 — plain obfs4 TCP passthrough (Moscow → Amsterdam)
"""

import argparse
import socket
import ssl
import subprocess
import sys
import time
import http.client
import re
import struct
from dataclasses import dataclass, field
from typing import Optional

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
RESET = "\033[0m"
BOLD = "\033[1m"

# ─────────────────────────────────────────────────────────────────────────────
# ICE relay definitions (mirrors ICEConfig in Constants.swift)
# ─────────────────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class IceRelayInfo:
    name: str
    host: str
    port: int
    mode: str        # "tls_obfs4" or "plain_obfs4"
    description: str

ICE_RELAYS = [
    IceRelayInfo(
        name="Primary (Amsterdam)",
        host="ice.ams.konstruct.cc",
        port=443,
        mode="tls_obfs4",
        description="TLS-wrapped obfs4 — DPI sees normal HTTPS",
    ),
    IceRelayInfo(
        name="Relay (Moscow → Amsterdam)",
        host="ice.msk.konstruct.cc",
        port=9443,
        mode="plain_obfs4",
        description="Plain obfs4 TCP passthrough",
    ),
]

VPN_IFACE_RE = re.compile(
    r"^(utun\d+|tun\d+|tap\d+|ppp\d+|wg\d+|wg0|tailscale0|ipsec\d+|ppp|tun|tap|wg)$",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class NetPathInfo:
    default_iface: Optional[str]
    default_gateway: Optional[str]
    source_ip: Optional[str]
    vpn_likely: Optional[bool]   # True/False/None=unknown
    details: Optional[str]


def _run(cmd: list[str]) -> str | None:
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)
        return out.strip()
    except Exception:
        return None


def detect_network_path() -> NetPathInfo:
    """
    Best-effort VPN detection.
    - Primary signal: default route interface (darwin/linux).
    - Secondary signal: presence of common VPN tunnel interfaces.
    """
    platform = sys.platform

    # macOS / iOS simulator / etc.
    if platform == "darwin":
        out = _run(["route", "-n", "get", "default"])
        iface = gw = src = None
        if out:
            for line in out.splitlines():
                line = line.strip()
                if line.startswith("interface:"):
                    iface = line.split(":", 1)[1].strip() or None
                elif line.startswith("gateway:"):
                    gw = line.split(":", 1)[1].strip() or None
                elif line.startswith("source:"):
                    src = line.split(":", 1)[1].strip() or None

        vpn_likely = None
        if iface:
            vpn_likely = bool(VPN_IFACE_RE.match(iface))

        # If iface is unknown, look for any "utun/tun/wg/ppp" interface that is up.
        if vpn_likely is None:
            ifconfig = _run(["ifconfig"])
            if ifconfig:
                up_vpn = False
                current = None
                current_is_vpn = False
                for line in ifconfig.splitlines():
                    if line and not line.startswith("\t") and ":" in line:
                        current = line.split(":", 1)[0].strip()
                        current_is_vpn = bool(current and VPN_IFACE_RE.match(current))
                    if current_is_vpn and "status: active" in line:
                        up_vpn = True
                        break
                vpn_likely = True if up_vpn else False

        details = f"default_iface={iface or '?'} src={src or '?'} gw={gw or '?'}"
        return NetPathInfo(iface, gw, src, vpn_likely, details)

    # Linux
    if platform.startswith("linux"):
        out = _run(["ip", "route", "get", "1.1.1.1"])
        iface = gw = src = None
        if out:
            # Example: "1.1.1.1 via 192.168.1.1 dev wlan0 src 192.168.1.10 uid 1000"
            m_dev = re.search(r"\bdev\s+(\S+)", out)
            m_src = re.search(r"\bsrc\s+(\S+)", out)
            m_via = re.search(r"\bvia\s+(\S+)", out)
            iface = m_dev.group(1) if m_dev else None
            src = m_src.group(1) if m_src else None
            gw = m_via.group(1) if m_via else None

        vpn_likely = None
        if iface:
            vpn_likely = bool(VPN_IFACE_RE.match(iface))
        else:
            links = _run(["ip", "-o", "link", "show"])
            if links:
                vpn_likely = any(
                    VPN_IFACE_RE.match(line.split(":")[1].strip())
                    for line in links.splitlines()
                    if ":" in line
                )

        details = f"default_iface={iface or '?'} src={src or '?'} gw={gw or '?'}"
        return NetPathInfo(iface, gw, src, vpn_likely, details)

    raise SystemExit(f"Unsupported OS: {platform} (this script supports macOS and Linux only)")


def fmt_vpn_state(vpn_likely: Optional[bool]) -> str:
    if vpn_likely is None:
        return f"{YELLOW}UNKNOWN{RESET}"
    return f"{GREEN}ON{RESET}" if vpn_likely else f"{RED}OFF{RESET}"


def ok(msg):
    print(f"  {GREEN}✅ {msg}{RESET}")


def fail(msg):
    print(f"  {RED}❌ {msg}{RESET}")


def warn(msg):
    print(f"  {YELLOW}⚠️  {msg}{RESET}")


# ─────────────────────────────────────────────────────────────────────────────
# Layer 1: TCP
# ─────────────────────────────────────────────────────────────────────────────
def test_tcp(host: str, port: int, timeout: float = 10.0) -> bool:
    print(f"\n{BOLD}[1] TCP connection{RESET} → {host}:{port}")
    t0 = time.time()
    try:
        s = socket.create_connection((host, port), timeout=timeout)
        elapsed = time.time() - t0
        ok(f"Connected in {elapsed:.2f}s")
        s.close()
        return True
    except socket.timeout:
        fail(f"Timed out after {timeout}s  (possible firewall DROP)")
        return False
    except ConnectionRefusedError:
        fail("Connection refused  (port closed)")
        return False
    except Exception as e:
        fail(f"{e}")
        return False


# ─────────────────────────────────────────────────────────────────────────────
# Layer 2: TLS without h2 ALPN
# ─────────────────────────────────────────────────────────────────────────────
def test_tls_plain(host: str, port: int, timeout: float = 10.0) -> bool:
    print(f"\n{BOLD}[2] TLS handshake — NO h2 ALPN{RESET} (like HTTPS/1.1)")
    t0 = time.time()
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((host, port), timeout=timeout) as raw:
            raw.settimeout(timeout)
            with ctx.wrap_socket(raw, server_hostname=host) as s:
                elapsed = time.time() - t0
                ok(
                    f"Handshake OK in {elapsed:.2f}s — TLS={s.version()}  ALPN={s.selected_alpn_protocol()}"
                )
                return True
    except ssl.SSLError as e:
        fail(f"TLS error: {e}")
        return False
    except socket.timeout:
        fail(f"Timed out — server may be RST-ing the connection (DPI)")
        return False
    except Exception as e:
        fail(f"{e}")
        return False


# ─────────────────────────────────────────────────────────────────────────────
# Layer 3: TLS with h2 ALPN (exactly what gRPC sends)
# ─────────────────────────────────────────────────────────────────────────────
def test_tls_h2(host: str, port: int, timeout: float = 15.0) -> bool:
    print(f"\n{BOLD}[3] TLS handshake — WITH h2 ALPN{RESET} (exactly what gRPC sends)")
    t0 = time.time()
    try:
        ctx = ssl.create_default_context()
        ctx.set_alpn_protocols(["h2", "http/1.1"])
        with socket.create_connection((host, port), timeout=timeout) as raw:
            raw.settimeout(timeout)
            with ctx.wrap_socket(raw, server_hostname=host) as s:
                elapsed = time.time() - t0
                alpn = s.selected_alpn_protocol()
                ok(f"Handshake OK in {elapsed:.2f}s — TLS={s.version()}  ALPN={alpn}")
                if alpn != "h2":
                    warn("Server negotiated HTTP/1.1 instead of h2 — gRPC will fail")
                return True
    except ssl.SSLError as e:
        fail(f"TLS error: {e}")
        return False
    except socket.timeout:
        fail(
            f"Timed out after {timeout}s — DPI likely blocking h2 ALPN in TLS ClientHello"
        )
        return False
    except ConnectionResetError:
        elapsed = time.time() - t0
        fail(
            f"Connection reset after {elapsed:.2f}s — DPI injecting RST when it sees h2 ALPN"
        )
        return False
    except Exception as e:
        fail(f"{e}")
        return False


# ─────────────────────────────────────────────────────────────────────────────
# Layer 4: HTTP/1.1 GET (sanity check the web server)
# ─────────────────────────────────────────────────────────────────────────────
def test_http1(
    host: str, port: int, path: str = "/.well-known/construct-server", timeout: float = 10.0
) -> bool:
    print(f"\n{BOLD}[4] HTTPS/1.1 GET{RESET} {path}")
    t0 = time.time()
    try:
        conn = http.client.HTTPSConnection(host, port, timeout=timeout)
        conn.request("GET", path, headers={"Host": host})
        resp = conn.getresponse()
        elapsed = time.time() - t0
        body = resp.read(256).decode("utf-8", errors="replace")
        if resp.status == 200:
            ok(f"HTTP {resp.status} in {elapsed:.2f}s — body: {body[:80]}")
        else:
            warn(f"HTTP {resp.status} in {elapsed:.2f}s — {body[:80]}")
        conn.close()
        return True
    except Exception as e:
        fail(f"{e}")
        return False


# ─────────────────────────────────────────────────────────────────────────────
# Layer 5: gRPC channel ready (grpcio)
# ─────────────────────────────────────────────────────────────────────────────
def test_grpc_channel(host: str, port: int, timeout: float = 15.0) -> bool:
    print(f"\n{BOLD}[5] gRPC channel ready{RESET} (grpcio)")
    try:
        import grpc
    except ImportError:
        warn("grpcio not installed — run: pip3 install grpcio")
        return None

    t0 = time.time()
    try:
        channel = grpc.secure_channel(
            f"{host}:{port}",
            grpc.ssl_channel_credentials(),
            options=[
                ("grpc.enable_http_proxy", 0),
                ("grpc.keepalive_time_ms", 10000),
            ],
        )
        future = grpc.channel_ready_future(channel)
        future.result(timeout=timeout)
        elapsed = time.time() - t0
        ok(f"Channel READY in {elapsed:.2f}s")
        channel.close()
        return True
    except grpc.FutureTimeoutError:
        elapsed = time.time() - t0
        fail(
            f"Channel not ready after {timeout}s — HTTP/2 connection never established"
        )
        return False
    except Exception as e:
        fail(f"{e}")
        return False


# ─────────────────────────────────────────────────────────────────────────────
# Layer 6: gRPC call — GetPowChallenge (no auth required)
# ─────────────────────────────────────────────────────────────────────────────
def test_grpc_pow(host: str, port: int, timeout: float = 15.0) -> bool:
    print(
        f"\n{BOLD}[6] gRPC call{RESET} — AuthService.GetPowChallenge (no auth needed)"
    )
    try:
        import grpc
        import sys, os

        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "proto_gen"))
        from services import auth_service_pb2, auth_service_pb2_grpc
    except ImportError as e:
        warn(f"Missing dependency: {e}")
        return None

    t0 = time.time()
    try:
        channel = grpc.secure_channel(
            f"{host}:{port}",
            grpc.ssl_channel_credentials(),
        )
        stub = auth_service_pb2_grpc.AuthServiceStub(channel)
        response = stub.GetPowChallenge(
            auth_service_pb2.GetPowChallengeRequest(), timeout=timeout
        )
        elapsed = time.time() - t0
        ok(
            f"Response in {elapsed:.2f}s — challenge={response.challenge[:16] if hasattr(response, 'challenge') else '?'}... difficulty={getattr(response, 'difficulty', '?')}"
        )
        channel.close()
        return True
    except Exception as e:
        elapsed = time.time() - t0
        code = getattr(e, "code", lambda: None)()
        fail(
            f"RPC failed after {elapsed:.2f}s — {code}: {e.details() if hasattr(e, 'details') else e}"
        )
        return False


# ─────────────────────────────────────────────────────────────────────────────
# Layer 7: gRPC call — CheckUsernameAvailability (no auth required)
# ─────────────────────────────────────────────────────────────────────────────
def test_grpc_username(host: str, port: int, timeout: float = 15.0) -> bool:
    print(
        f"\n{BOLD}[7] gRPC call{RESET} — UserService.CheckUsernameAvailability (no auth needed)"
    )
    try:
        import grpc
        import sys, os

        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "proto_gen"))
        from services import user_service_pb2, user_service_pb2_grpc
    except ImportError as e:
        warn(f"Missing dependency: {e}")
        return None

    t0 = time.time()
    try:
        channel = grpc.secure_channel(f"{host}:{port}", grpc.ssl_channel_credentials())
        stub = user_service_pb2_grpc.UserServiceStub(channel)
        req = user_service_pb2.CheckUsernameAvailabilityRequest()
        req.username = "test_connectivity_probe"
        response = stub.CheckUsernameAvailability(req, timeout=timeout)
        elapsed = time.time() - t0
        ok(
            f"Response in {elapsed:.2f}s — available={response.available}  reason={getattr(response, 'reason', '?')}"
        )
        channel.close()
        return True
    except Exception as e:
        elapsed = time.time() - t0
        code = getattr(e, "code", lambda: None)()
        # unauthenticated / permission_denied is still a "server responded" success
        if code and str(code) in (
            "StatusCode.UNAUTHENTICATED",
            "StatusCode.PERMISSION_DENIED",
        ):
            ok(
                f"Server responded in {elapsed:.2f}s — {code} (endpoint reached, auth required)"
            )
            return True
        fail(
            f"RPC failed after {elapsed:.2f}s — {code}: {e.details() if hasattr(e, 'details') else e}"
        )
        return False


# ─────────────────────────────────────────────────────────────────────────────
# ICE Relay tests
# ─────────────────────────────────────────────────────────────────────────────

def test_ice_tcp(relay: IceRelayInfo, timeout: float = 10.0) -> bool:
    """TCP reachability — can we open a socket to the relay port?"""
    print(f"\n{BOLD}[ICE-TCP] {relay.name}{RESET}  {relay.host}:{relay.port}  ({relay.description})")
    t0 = time.time()
    try:
        s = socket.create_connection((relay.host, relay.port), timeout=timeout)
        elapsed = time.time() - t0
        ok(f"TCP connected in {elapsed:.2f}s")
        s.close()
        return True
    except socket.timeout:
        fail(f"Timed out after {timeout}s  — port may be firewalled (DROP)")
        return False
    except ConnectionRefusedError:
        fail("Connection refused  — port closed or relay not running")
        return False
    except Exception as e:
        fail(f"{e}")
        return False


def test_ice_tls(relay: IceRelayInfo, timeout: float = 10.0) -> bool:
    """
    TLS handshake check for TLS-mode relays (ice.ams.konstruct.cc:443).
    DPI-resistant relays wrap obfs4 inside TLS, so a TLS ClientHello with
    the right SNI should complete a normal handshake before obfs4 begins.
    """
    if relay.mode != "tls_obfs4":
        return None  # not applicable for plain obfs4 relays

    print(f"\n{BOLD}[ICE-TLS] {relay.name}{RESET}  TLS handshake (SNI={relay.host})")
    t0 = time.time()
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((relay.host, relay.port), timeout=timeout) as raw:
            raw.settimeout(timeout)
            with ctx.wrap_socket(raw, server_hostname=relay.host) as s:
                elapsed = time.time() - t0
                ok(f"TLS handshake OK in {elapsed:.2f}s — {s.version()}  ALPN={s.selected_alpn_protocol()}")
                return True
    except ssl.SSLCertVerificationError as e:
        elapsed = time.time() - t0
        # Self-signed or internal CA is normal for ICE relay endpoints
        warn(f"TLS cert verification failed in {elapsed:.2f}s (self-signed? normal for ICE): {e}")
        return True  # cert error ≠ port blocked; TLS handshake reached the server
    except ssl.SSLError as e:
        fail(f"TLS error: {e}")
        return False
    except socket.timeout:
        fail(f"Timed out — relay may be blocking TLS ClientHello")
        return False
    except Exception as e:
        fail(f"{e}")
        return False


def test_ice_obfs4_probe(relay: IceRelayInfo, timeout: float = 10.0) -> bool:
    """
    Lightweight obfs4 liveness probe.

    For tls_obfs4 relays (Amsterdam): connect, complete TLS handshake, then send
    random bytes inside the TLS tunnel. The obfs4 server will close the connection
    (invalid cert), but it will NOT return a TLS alert — connection close itself
    confirms the obfs4 layer is alive.

    For plain_obfs4 relays (Moscow): send random bytes on raw TCP. A live obfs4
    server responds with random-looking bytes. Silence (timeout) is inconclusive —
    some servers only respond after a valid handshake.
    """
    print(f"\n{BOLD}[ICE-obfs4] {relay.name}{RESET}  obfs4 liveness probe ({relay.host}:{relay.port})")
    t0 = time.time()
    import os

    try:
        if relay.mode == "tls_obfs4":
            # Amsterdam: TLS first, then send random bytes inside the tunnel
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE  # obfs4 relay has its own cert
            with socket.create_connection((relay.host, relay.port), timeout=timeout) as raw:
                raw.settimeout(timeout)
                with ctx.wrap_socket(raw, server_hostname=relay.host) as s:
                    s.sendall(os.urandom(64))
                    try:
                        response = s.recv(256)
                        elapsed = time.time() - t0
                        if response and response[0] != 0x15:
                            ok(f"Server responded in {elapsed:.2f}s with {len(response)} bytes inside TLS — obfs4 alive")
                            return True
                        elif not response:
                            # Server closed connection — obfs4 rejected our fake handshake
                            # This is the expected behaviour when cert is wrong
                            elapsed = time.time() - t0
                            ok(f"Server closed connection in {elapsed:.2f}s (expected: obfs4 rejected invalid cert) — relay alive")
                            return True
                        else:
                            elapsed = time.time() - t0
                            fail(f"Got TLS alert in {elapsed:.2f}s — unexpected")
                            return False
                    except (ssl.SSLError, ConnectionResetError, OSError):
                        elapsed = time.time() - t0
                        # SSL error / reset after our random bytes = obfs4 is alive and rejected us
                        ok(f"Connection closed/reset in {elapsed:.2f}s — obfs4 rejected invalid handshake (relay alive)")
                        return True
                    except socket.timeout:
                        warn(f"No response in {timeout}s inside TLS — inconclusive")
                        return None

        else:
            # Moscow: plain TCP, send random bytes
            s = socket.create_connection((relay.host, relay.port), timeout=timeout)
            s.settimeout(timeout)
            s.sendall(os.urandom(64))
            try:
                response = s.recv(256)
            except socket.timeout:
                warn(f"No response in {timeout}s — server may require valid obfs4 cert to respond (inconclusive)")
                s.close()
                return None

            elapsed = time.time() - t0
            s.close()

            if not response:
                warn(f"Server closed connection immediately — may require valid obfs4 cert")
                return None

            if response[0] == 0x15:
                fail(f"Got TLS Alert in {elapsed:.2f}s — relay may have TLS mode mismatch")
                return False
            if response[:4] in (b"HTTP", b"<HTM"):
                fail(f"Got HTTP response — unexpected protocol on obfs4 port")
                return False

            ok(f"Server responded in {elapsed:.2f}s with {len(response)} bytes — obfs4 alive")
            return True

    except socket.timeout:
        fail(f"TCP timed out — port firewalled or relay down")
        return False
    except ConnectionRefusedError:
        fail("Connection refused — relay not running")
        return False
    except Exception as e:
        fail(f"{e}")
        return False


def run_ice_tests(relays: list) -> dict:
    """Run all ICE relay tests and return results dict."""
    results = {}
    for relay in relays:
        section = f"ICE {relay.name}"
        print(f"\n{BOLD}{CYAN}{'─'*55}")
        print(f"  ICE Relay: {relay.name}")
        print(f"  {relay.host}:{relay.port}  [{relay.mode}]")
        print(f"  {relay.description}")
        print(f"{'─'*55}{RESET}")

        tcp_ok = test_ice_tcp(relay)
        results[f"{section} TCP"] = tcp_ok

        if not tcp_ok:
            results[f"{section} TLS"] = False
            results[f"{section} obfs4"] = False
            continue

        if relay.mode == "tls_obfs4":
            results[f"{section} TLS"] = test_ice_tls(relay)
        else:
            results[f"{section} TLS"] = None  # N/A

        results[f"{section} obfs4"] = test_ice_obfs4_probe(relay)

    return results


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Construct server connectivity test")
    parser.add_argument("--host", default="ams.konstruct.cc")
    parser.add_argument("--port", type=int, default=443)
    parser.add_argument("--web-host", default="konstruct.cc",
                        help="Public web host for .well-known checks (default: konstruct.cc)")
    parser.add_argument("--no-ice", action="store_true",
                        help="Skip ICE relay tests")
    parser.add_argument("--ice-only", action="store_true",
                        help="Only run ICE relay tests (skip gRPC stack)")
    args = parser.parse_args()

    host, port, web_host = args.host, args.port, args.web_host
    net = detect_network_path()

    print(f"\n{BOLD}{'='*55}")
    print(f"  Construct Server Connectivity Test")
    print(f"  gRPC target : {host}:{port}")
    print(f"  Web target  : {web_host}:443")
    print(f"  VPN         : {fmt_vpn_state(net.vpn_likely)}  ({net.details})")
    print(f"  ICE relays  : {'SKIPPED (--no-ice)' if args.no_ice else ', '.join(r.host for r in ICE_RELAYS)}")
    print(f"{'='*55}{RESET}")

    results = {}

    # ── gRPC stack ──────────────────────────────────────────────────────────
    if not args.ice_only:
        results["TCP connect"] = test_tcp(host, port)
        results["TLS (no ALPN)"] = test_tls_plain(host, port)
        results["TLS (h2 ALPN)"] = test_tls_h2(host, port)
        results["HTTPS GET /.well-known/construct-server"] = test_http1(web_host, 443)
        results["gRPC channel ready"] = test_grpc_channel(host, port)
        results["gRPC GetPowChallenge"] = test_grpc_pow(host, port)
        results["gRPC CheckUsername"] = test_grpc_username(host, port)

    # ── ICE relay tests ──────────────────────────────────────────────────────
    if not args.no_ice:
        ice_results = run_ice_tests(ICE_RELAYS)
        results.update(ice_results)

    # ── Summary ──────────────────────────────────────────────────────────────
    print(f"\n{BOLD}{'='*55}")
    print(f"  SUMMARY")
    print(f"{'='*55}{RESET}")

    for name, result in results.items():
        if result is None:
            print(f"  {YELLOW}⚠️  N/A {RESET}  {name}")
        elif result:
            print(f"  {GREEN}✅ OK  {RESET}  {name}")
        else:
            print(f"  {RED}❌ FAIL{RESET}  {name}")

    def _icon(value):
        if value is None:
            return "⚠️ "
        return "✅" if value else "❌"

    if not args.ice_only:
        grpc_values = [
            results.get("gRPC channel ready"),
            results.get("gRPC GetPowChallenge"),
            results.get("gRPC CheckUsername"),
        ]
        grpc_non_null = [v for v in grpc_values if v is not None]
        grpc_overall = any(grpc_non_null) if grpc_non_null else None

        print(f"\n{BOLD}Direct path:{RESET}")
        print(
            "  TCP {tcp}  TLS/no-ALPN {tls1}  TLS/h2 {tls2}  gRPC {grpc}".format(
                tcp=_icon(results.get("TCP connect")),
                tls1=_icon(results.get("TLS (no ALPN)")),
                tls2=_icon(results.get("TLS (h2 ALPN)")),
                grpc=_icon(grpc_overall),
            )
        )

    if not args.no_ice:
        print(f"\n{BOLD}ICE relays:{RESET}")
        for relay in ICE_RELAYS:
            section = f"ICE {relay.name}"
            tcp  = _icon(results.get(f"{section} TCP"))
            tls  = _icon(results.get(f"{section} TLS"))
            ob4  = _icon(results.get(f"{section} obfs4"))
            tls_label = f"TLS {tls}  " if relay.mode == "tls_obfs4" else ""
            print(f"  {relay.name:35s}  TCP {tcp}  {tls_label}obfs4 {ob4}")

    print()


if __name__ == "__main__":
    main()
