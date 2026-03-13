#!/usr/bin/env python3
"""
Construct Server — Layered Connectivity Test
=============================================
Tests each network layer independently so you can pinpoint exactly
where blocking occurs (DPI, TLS mismatch, gRPC, auth, etc.).

Run without VPN, then with VPN and compare results.

Usage:
    python3 test_connectivity.py
    python3 test_connectivity.py --host ams.konstruct.cc --port 443
"""

import argparse
import socket
import ssl
import subprocess
import sys
import time
import http.client

GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
RESET  = "\033[0m"
BOLD   = "\033[1m"


def ok(msg):  print(f"  {GREEN}✅ {msg}{RESET}")
def fail(msg): print(f"  {RED}❌ {msg}{RESET}")
def warn(msg): print(f"  {YELLOW}⚠️  {msg}{RESET}")


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
                ok(f"Handshake OK in {elapsed:.2f}s — TLS={s.version()}  ALPN={s.selected_alpn_protocol()}")
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
        fail(f"Timed out after {timeout}s — DPI likely blocking h2 ALPN in TLS ClientHello")
        return False
    except ConnectionResetError:
        elapsed = time.time() - t0
        fail(f"Connection reset after {elapsed:.2f}s — DPI injecting RST when it sees h2 ALPN")
        return False
    except Exception as e:
        fail(f"{e}")
        return False


# ─────────────────────────────────────────────────────────────────────────────
# Layer 4: HTTP/1.1 GET (sanity check the web server)
# ─────────────────────────────────────────────────────────────────────────────
def test_http1(host: str, port: int, path: str = "/.well-known/ice-cert", timeout: float = 10.0) -> bool:
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
            ]
        )
        future = grpc.channel_ready_future(channel)
        future.result(timeout=timeout)
        elapsed = time.time() - t0
        ok(f"Channel READY in {elapsed:.2f}s")
        channel.close()
        return True
    except grpc.FutureTimeoutError:
        elapsed = time.time() - t0
        fail(f"Channel not ready after {timeout}s — HTTP/2 connection never established")
        return False
    except Exception as e:
        fail(f"{e}")
        return False


# ─────────────────────────────────────────────────────────────────────────────
# Layer 6: gRPC call — GetPowChallenge (no auth required)
# ─────────────────────────────────────────────────────────────────────────────
def test_grpc_pow(host: str, port: int, timeout: float = 15.0) -> bool:
    print(f"\n{BOLD}[6] gRPC call{RESET} — AuthService.GetPowChallenge (no auth needed)")
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
            auth_service_pb2.GetPowChallengeRequest(),
            timeout=timeout
        )
        elapsed = time.time() - t0
        ok(f"Response in {elapsed:.2f}s — challenge={response.challenge[:16] if hasattr(response, 'challenge') else '?'}... difficulty={getattr(response, 'difficulty', '?')}")
        channel.close()
        return True
    except Exception as e:
        elapsed = time.time() - t0
        code = getattr(e, 'code', lambda: None)()
        fail(f"RPC failed after {elapsed:.2f}s — {code}: {e.details() if hasattr(e, 'details') else e}")
        return False


# ─────────────────────────────────────────────────────────────────────────────
# Layer 7: gRPC call — CheckUsernameAvailability (no auth required)
# ─────────────────────────────────────────────────────────────────────────────
def test_grpc_username(host: str, port: int, timeout: float = 15.0) -> bool:
    print(f"\n{BOLD}[7] gRPC call{RESET} — UserService.CheckUsernameAvailability (no auth needed)")
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
        ok(f"Response in {elapsed:.2f}s — available={response.available}  reason={getattr(response, 'reason', '?')}")
        channel.close()
        return True
    except Exception as e:
        elapsed = time.time() - t0
        code = getattr(e, 'code', lambda: None)()
        # unauthenticated / permission_denied is still a "server responded" success
        if code and str(code) in ("StatusCode.UNAUTHENTICATED", "StatusCode.PERMISSION_DENIED"):
            ok(f"Server responded in {elapsed:.2f}s — {code} (endpoint reached, auth required)")
            return True
        fail(f"RPC failed after {elapsed:.2f}s — {code}: {e.details() if hasattr(e, 'details') else e}")
        return False


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Construct server connectivity test")
    parser.add_argument("--host", default="ams.konstruct.cc")
    parser.add_argument("--port", type=int, default=443)
    args = parser.parse_args()

    host, port = args.host, args.port

    print(f"\n{BOLD}{'='*55}")
    print(f"  Construct Server Connectivity Test")
    print(f"  Target: {host}:{port}")
    print(f"{'='*55}{RESET}")

    results = {}
    results["TCP connect"]         = test_tcp(host, port)
    results["TLS (no ALPN)"]       = test_tls_plain(host, port)
    results["TLS (h2 ALPN)"]       = test_tls_h2(host, port)
    results["HTTPS/1.1 GET"]       = test_http1(host, port)
    results["gRPC channel ready"]  = test_grpc_channel(host, port)
    results["gRPC GetPowChallenge"]= test_grpc_pow(host, port)
    results["gRPC CheckUsername"]  = test_grpc_username(host, port)

    print(f"\n{BOLD}{'='*55}")
    print(f"  SUMMARY")
    print(f"{'='*55}{RESET}")
    for name, result in results.items():
        if result is None:
            print(f"  {YELLOW}⚠️  SKIP{RESET}  {name}")
        elif result:
            print(f"  {GREEN}✅ OK  {RESET}  {name}")
        else:
            print(f"  {RED}❌ FAIL{RESET}  {name}")

    print(f"\n{BOLD}Expected results:{RESET}")
    print(f"  Without VPN (DPI active):  TCP ✅  TLS/no-ALPN ✅  TLS/h2 ❌  gRPC ❌")
    print(f"  With VPN:                  all ✅")
    print()


if __name__ == "__main__":
    main()
