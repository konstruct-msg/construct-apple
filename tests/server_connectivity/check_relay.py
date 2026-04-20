#!/usr/bin/env python3
"""
construct-relay post-deploy health check
=========================================
Verifies every observable relay property from the client's perspective.
Run immediately after deploying a new relay or after any relay config change.

Usage:
    python3 check_relay.py                        # test all hardcoded relays
    python3 check_relay.py --relay 158.160.140.67:443   # test specific relay
    python3 check_relay.py --ssh root@158.160.140.67    # also verify obfs4 cert via SSH
    python3 check_relay.py --relay 158.160.140.67:443 --ssh root@158.160.140.67

Checks:
    [1] TCP reachability              — basic: is the port open?
    [2] TLS handshake                 — does TLS succeed with the correct SNI?
    [3] SPKI pin match                — does the cert match the hardcoded SHA-256?
    [4] ALPN negotiated = http/1.1    — CRITICAL: h2 ALPN would be detected by ТСПУ DPI
    [5] WebTunnel 101 Upgrade         — does GET /path return 101 Switching Protocols?
    [6] obfs4 cert freshness (SSH)    — does /data/relay.obfs4 cert match Constants.swift?
    [7] gRPC upstream (AMS)           — is ams.konstruct.cc reachable from here?

Exit code:
    0  all critical checks passed
    1  one or more critical checks failed (check summary at end)

No external dependencies required.  Uses only Python stdlib.
Optional: `ssh` binary for check [6].
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import os
import socket
import ssl
import struct
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Optional

# ─────────────────────────────────────────────────────────────────────────────
# Terminal colours
# ─────────────────────────────────────────────────────────────────────────────
GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
CYAN   = "\033[96m"
BOLD   = "\033[1m"
DIM    = "\033[2m"
RESET  = "\033[0m"

# ─────────────────────────────────────────────────────────────────────────────
# Relay config — mirrors ICEConfig in ConstructMessenger/Utilities/Constants.swift
# Update these whenever Constants.swift changes.
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class RelayConfig:
    name: str
    addr: str          # "ip:port"
    sni: str           # fake SNI sent in ClientHello (REALITY-style DPI evasion)
    spki_sha256: str   # lowercase hex SHA-256 of DER SubjectPublicKeyInfo
    bridge_cert: str   # obfs4 bridge cert (base64, from relay.obfs4)
    wt_path: str       # WebTunnel WebSocket resource path


RELAYS: list[RelayConfig] = [
    RelayConfig(
        name        = "MSK (Yandex Cloud, 158.160.140.67)",
        addr        = "158.160.140.67:443",
        sni         = "storage.yandexcloud.net",
        spki_sha256 = "ce2bbfcac1fffab1f4f41ee540aee2dea92c523f7768264aeb87184bf8bfa723",
        bridge_cert = "IZKOsDNS5gld2g1PH4Uo4Yna/ltepGKpzDQTbSJll9OqzMin6yZaNx4gFbiLTvuGbABpcA",
        wt_path     = "/construct-ice",
    ),
    # Relay 2: SPb — uncomment and fill after deployment
    # RelayConfig(
    #     name        = "SPB (194.87.235.91)",
    #     addr        = "194.87.235.91:443",
    #     sni         = "",          # TODO: fill
    #     spki_sha256 = "",          # TODO: fill
    #     bridge_cert = "",          # TODO: fill
    #     wt_path     = "/construct-ice",
    # ),
]

GRPC_UPSTREAM = "ams.konstruct.cc"
GRPC_PORT     = 443


# ─────────────────────────────────────────────────────────────────────────────
# Result tracking
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class CheckResult:
    name: str
    passed: Optional[bool]   # True=pass, False=fail, None=skipped/n/a
    critical: bool = True
    detail: str = ""


_results: list[CheckResult] = []


def _record(name: str, passed: Optional[bool], critical: bool = True, detail: str = "") -> Optional[bool]:
    _results.append(CheckResult(name, passed, critical, detail))
    return passed


# ─────────────────────────────────────────────────────────────────────────────
# Printing helpers
# ─────────────────────────────────────────────────────────────────────────────

def _ok(msg: str):    print(f"    {GREEN}✅ {msg}{RESET}")
def _fail(msg: str):  print(f"    {RED}❌ {msg}{RESET}")
def _warn(msg: str):  print(f"    {YELLOW}⚠️  {msg}{RESET}")
def _info(msg: str):  print(f"    {DIM}ℹ  {msg}{RESET}")
def _head(msg: str):  print(f"\n{BOLD}{CYAN}{msg}{RESET}")
def _sub(msg: str):   print(f"  {BOLD}{msg}{RESET}")


# ─────────────────────────────────────────────────────────────────────────────
# Minimal pure-Python DER parser for SPKI extraction
# No external dependencies — works even without 'cryptography' package.
# ─────────────────────────────────────────────────────────────────────────────

def _der_read_tlv(data: bytes, offset: int) -> tuple[int, bytes, int]:
    """Parse one DER TLV at `offset`. Returns (tag, value, next_offset)."""
    tag = data[offset]
    offset += 1
    fb = data[offset]
    if fb & 0x80:
        n = fb & 0x7f
        length = int.from_bytes(data[offset + 1 : offset + 1 + n], "big")
        offset += 1 + n
    else:
        length = fb
        offset += 1
    return tag, data[offset : offset + length], offset + length


def _der_iter_sequence(seq_body: bytes):
    """Yield (tag, value) for every TLV element in a DER SEQUENCE body."""
    offset = 0
    while offset < len(seq_body):
        tag, value, offset = _der_read_tlv(seq_body, offset)
        yield tag, value


def _encode_tlv(tag: int, value: bytes) -> bytes:
    """Re-encode a tag + value as a DER TLV byte string."""
    length = len(value)
    if length < 0x80:
        lbytes = bytes([length])
    elif length < 0x100:
        lbytes = bytes([0x81, length])
    elif length < 0x10000:
        lbytes = bytes([0x82, length >> 8, length & 0xFF])
    else:
        raise ValueError(f"DER value too long: {length}")
    return bytes([tag]) + lbytes + value


def extract_spki_der(cert_der: bytes) -> bytes:
    """
    Extract the SubjectPublicKeyInfo SEQUENCE from a DER-encoded X.509 cert.

    X.509 structure:
      Certificate SEQUENCE {
        TBSCertificate SEQUENCE {
          [0] version (optional, present in v2/v3)
          serialNumber INTEGER
          signature    SEQUENCE
          issuer       SEQUENCE/SET
          validity     SEQUENCE
          subject      SEQUENCE/SET
          subjectPublicKeyInfo SEQUENCE  ← this
          ...
        }
        ...
      }
    """
    _, outer_val, _ = _der_read_tlv(cert_der, 0)
    tbs_tag, tbs_val, _ = _der_read_tlv(outer_val, 0)
    if tbs_tag != 0x30:
        raise ValueError(f"TBSCertificate is not SEQUENCE: {tbs_tag:#04x}")

    fields = list(_der_iter_sequence(tbs_val))
    # Skip optional [0] EXPLICIT version field (tag 0xa0)
    base = 1 if fields[0][0] == 0xA0 else 0
    # After base: serial(0), sig(1), issuer(2), validity(3), subject(4), spki(5)
    spki_tag, spki_val = fields[base + 5]
    if spki_tag != 0x30:
        raise ValueError(f"SPKI field is not SEQUENCE: {spki_tag:#04x}")
    return _encode_tlv(spki_tag, spki_val)


def spki_sha256_from_der_cert(cert_der: bytes) -> str:
    """Return lowercase hex SHA-256 of the SubjectPublicKeyInfo in a DER cert."""
    spki = extract_spki_der(cert_der)
    return hashlib.sha256(spki).hexdigest()


# ─────────────────────────────────────────────────────────────────────────────
# Check functions
# ─────────────────────────────────────────────────────────────────────────────

def check_tcp(relay: RelayConfig, timeout: float = 10.0) -> bool:
    """[1] TCP: can we open a socket to relay_ip:port?"""
    _sub("[1] TCP reachability")
    host, port_str = relay.addr.rsplit(":", 1)
    port = int(port_str)
    t0 = time.monotonic()
    try:
        s = socket.create_connection((host, port), timeout=timeout)
        elapsed = time.monotonic() - t0
        s.close()
        _ok(f"Connected in {elapsed * 1000:.0f} ms")
        return _record(f"{relay.name} [1] TCP", True)
    except socket.timeout:
        _fail(f"Timed out after {timeout:.0f}s — port may be firewalled (DROP)")
        return _record(f"{relay.name} [1] TCP", False, detail="timeout")
    except ConnectionRefusedError:
        _fail("Connection refused — relay is not listening on this port")
        return _record(f"{relay.name} [1] TCP", False, detail="refused")
    except Exception as e:
        _fail(str(e))
        return _record(f"{relay.name} [1] TCP", False, detail=str(e))


def _tls_ctx_no_verify(alpn: list[str] | None = None) -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    if alpn:
        ctx.set_alpn_protocols(alpn)
    return ctx


def check_tls_and_spki(relay: RelayConfig, timeout: float = 10.0) -> tuple[bool, bool, Optional[str]]:
    """
    [2] + [3]: TLS handshake with correct SNI, extract cert SPKI, compare SHA-256.
    Returns (tls_ok, spki_ok, negotiated_alpn).
    """
    _sub("[2] TLS handshake + [3] SPKI pin")
    host, port_str = relay.addr.rsplit(":", 1)
    port = int(port_str)

    # Use http/1.1-only ALPN — mirrors what the patched construct-ice client sends.
    ctx = _tls_ctx_no_verify(alpn=["http/1.1"])
    t0 = time.monotonic()
    try:
        raw = socket.create_connection((host, port), timeout=timeout)
        raw.settimeout(timeout)
        tls = ctx.wrap_socket(raw, server_hostname=relay.sni)
        elapsed = time.monotonic() - t0

        negotiated_alpn = tls.selected_alpn_protocol()
        cert_der = tls.getpeercert(binary_form=True)
        tls.close()

        _ok(f"TLS handshake OK in {elapsed * 1000:.0f} ms — {tls.version() if hasattr(tls, 'version') else 'TLS'}")

        # SPKI pin
        try:
            got_spki = spki_sha256_from_der_cert(cert_der)
        except Exception as e:
            _warn(f"SPKI extraction failed: {e} — skipping pin check")
            return _record(f"{relay.name} [2] TLS", True), _record(f"{relay.name} [3] SPKI", None, detail="extraction_failed"), negotiated_alpn

        if got_spki == relay.spki_sha256:
            _ok(f"SPKI pin matched: {got_spki[:16]}…{got_spki[-8:]}")
            spki_ok = _record(f"{relay.name} [3] SPKI", True, detail=got_spki)
        else:
            _fail(
                f"SPKI MISMATCH!\n"
                f"      Expected: {relay.spki_sha256}\n"
                f"      Got:      {got_spki}\n"
                f"      → Update mskRelayPinnedSPKI in Constants.swift"
            )
            spki_ok = _record(f"{relay.name} [3] SPKI", False, detail=f"expected={relay.spki_sha256} got={got_spki}")

        return _record(f"{relay.name} [2] TLS", True), spki_ok, negotiated_alpn

    except ssl.SSLError as e:
        elapsed = time.monotonic() - t0
        _fail(f"TLS error after {elapsed * 1000:.0f} ms: {e}")
        return _record(f"{relay.name} [2] TLS", False, detail=str(e)), _record(f"{relay.name} [3] SPKI", None), None
    except socket.timeout:
        _fail("Timed out during TLS handshake")
        return _record(f"{relay.name} [2] TLS", False, detail="timeout"), _record(f"{relay.name} [3] SPKI", None), None
    except Exception as e:
        _fail(str(e))
        return _record(f"{relay.name} [2] TLS", False, detail=str(e)), _record(f"{relay.name} [3] SPKI", None), None


def check_alpn(relay: RelayConfig, negotiated: Optional[str]) -> bool:
    """
    [4] ALPN must be http/1.1.

    Why this matters:
    - WebSocket (WebTunnel) only works over HTTP/1.1.  Advertising h2 in
      ClientHello then sending an HTTP/1.1 Upgrade request is inconsistent.
    - ТСПУ DPI detects this fingerprint mismatch and intercepts the stream.
    - After our fix: relay advertises only ["http/1.1"] and client requests
      only ["http/1.1"] — both sides agree unambiguously.
    """
    _sub("[4] ALPN negotiated = http/1.1")
    if negotiated is None:
        _warn(
            "No ALPN negotiated (None)\n"
            "      This can happen if relay is running an old build (no alpn_protocols set).\n"
            "      Redeploy the relay with the latest construct-relay image."
        )
        return _record(f"{relay.name} [4] ALPN", False, detail="None — relay needs redeploy")
    elif negotiated == "http/1.1":
        _ok(f"ALPN = {negotiated!r}  ✓ (correct for WebSocket)")
        return _record(f"{relay.name} [4] ALPN", True, detail=negotiated)
    elif negotiated == "h2":
        _fail(
            f"ALPN = {negotiated!r}  ← WRONG!\n"
            "      Server negotiated HTTP/2 instead of HTTP/1.1.\n"
            "      This breaks WebTunnel and is detectable by ТСПУ DPI.\n"
            "      Cause: relay was built without the tls.rs ALPN fix.\n"
            "      Fix: redeploy relay with construct-relay e8ba67b or later."
        )
        return _record(f"{relay.name} [4] ALPN", False, detail=f"h2 — wrong, relay needs redeploy")
    else:
        _warn(f"Unexpected ALPN: {negotiated!r}")
        return _record(f"{relay.name} [4] ALPN", False, detail=negotiated)


def check_webtunnel(relay: RelayConfig, timeout: float = 15.0) -> bool:
    """
    [5] WebTunnel: send a real WebSocket upgrade request, expect HTTP 101.

    This is the most important end-to-end test: it proves the relay
    correctly parses the upgrade and routes traffic to the upstream gRPC.
    If this fails but TCP+TLS pass, the relay is running but WebTunnel
    is misconfigured or upstream gRPC is unreachable.
    """
    _sub("[5] WebTunnel HTTP 101 Upgrade")
    host, port_str = relay.addr.rsplit(":", 1)
    port = int(port_str)

    # Sec-WebSocket-Key: any valid base64-encoded 16-byte value
    ws_key = base64.b64encode(os.urandom(16)).decode()
    request = (
        f"GET {relay.wt_path} HTTP/1.1\r\n"
        f"Host: {relay.sni}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {ws_key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n"
    ).encode()

    ctx = _tls_ctx_no_verify(alpn=["http/1.1"])
    t0 = time.monotonic()
    try:
        raw = socket.create_connection((host, port), timeout=timeout)
        raw.settimeout(timeout)
        tls = ctx.wrap_socket(raw, server_hostname=relay.sni)
        tls.sendall(request)

        # Read until we have the full response line
        response = b""
        while b"\r\n" not in response and (time.monotonic() - t0) < timeout:
            chunk = tls.recv(1024)
            if not chunk:
                break
            response += chunk

        elapsed = time.monotonic() - t0
        tls.close()

        first_line = response.split(b"\r\n")[0].decode("ascii", errors="replace")

        if "101" in first_line:
            _ok(f"HTTP 101 Switching Protocols in {elapsed * 1000:.0f} ms  ✓")
            return _record(f"{relay.name} [5] WebTunnel", True, detail="101")
        elif "200" in first_line:
            _warn(
                f"Got HTTP 200 instead of 101: {first_line}\n"
                "      Relay may not support WebSocket upgrade on this path.\n"
                "      Check relay routing and wt_path config."
            )
            return _record(f"{relay.name} [5] WebTunnel", False, detail=f"200: {first_line}")
        elif "400" in first_line or "404" in first_line:
            _fail(
                f"{first_line}\n"
                f"      Path {relay.wt_path!r} not found on relay.\n"
                "      Check wt_path in relay config and in iOS ICEConfig.hardcodedRelayWTPaths."
            )
            return _record(f"{relay.name} [5] WebTunnel", False, detail=first_line)
        else:
            _fail(f"Unexpected response: {first_line!r}")
            return _record(f"{relay.name} [5] WebTunnel", False, detail=first_line)

    except socket.timeout:
        elapsed = time.monotonic() - t0
        _fail(
            f"Timed out after {elapsed * 1000:.0f} ms waiting for HTTP response.\n"
            "      Possible causes:\n"
            "        a) Relay running old build without PROXY_WEBTUNNEL stop() fix\n"
            "           (relay reads upgrade, tries to proxy upstream, hangs)\n"
            "        b) Upstream gRPC (ams.konstruct.cc) is unreachable from relay\n"
            "        c) DPI is intercepting the stream before it reaches the relay"
        )
        return _record(f"{relay.name} [5] WebTunnel", False, detail="timeout")
    except Exception as e:
        _fail(str(e))
        return _record(f"{relay.name} [5] WebTunnel", False, detail=str(e))


def check_obfs4_cert_via_ssh(relay: RelayConfig, ssh_target: str, timeout: float = 15.0) -> bool:
    """
    [6] obfs4 cert freshness: SSH to relay host, read /data/relay.obfs4,
    extract cert= value and compare to the hardcoded bridge_cert in Constants.swift.

    Why this matters:
    - If the relay container was recreated (e.g. after a host reboot), the
      Docker named volume persists /data/relay.obfs4 — cert should be stable.
    - If the volume was deleted and recreated, the cert changes.  iOS clients
      hardcode the old cert and will get "HMAC verification failed" on every
      obfs4 connection attempt (obfs4 fallback completely broken).

    Requires: ssh access to the relay host.  Run with --ssh user@host.
    """
    _sub("[6] obfs4 cert freshness (via SSH)")

    cmd = [
        "ssh", "-o", "StrictHostKeyChecking=accept-new",
        "-o", f"ConnectTimeout={int(timeout)}",
        ssh_target,
        "docker exec $(docker ps --filter name=relay --format '{{.Names}}' | head -1) "
        "cat /data/relay.obfs4 2>/dev/null || "
        "docker exec relay cat /data/relay.obfs4 2>/dev/null",
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 5)
        output = result.stdout.strip()

        if result.returncode != 0 or not output:
            _warn(
                f"SSH command returned no output (rc={result.returncode}).\n"
                f"      stderr: {result.stderr.strip()[:200]}\n"
                "      Try running manually:\n"
                "        ssh {ssh_target} \"docker exec relay cat /data/relay.obfs4\""
            )
            return _record(f"{relay.name} [6] obfs4 cert", None, critical=False, detail="ssh_failed")

        # Parse cert= from the bridge descriptor line
        # Format: Bridge obfs4 <ip>:<port> <fp> cert=<base64> iat-mode=0
        cert_match = None
        for line in output.splitlines():
            for part in line.split():
                if part.startswith("cert="):
                    cert_match = part[5:]
                    break
            if cert_match:
                break

        if not cert_match:
            _warn(
                f"Could not parse cert= from relay.obfs4 output:\n"
                f"      {output[:200]}"
            )
            return _record(f"{relay.name} [6] obfs4 cert", None, critical=False, detail="parse_failed")

        # Normalize: strip trailing padding differences for comparison
        def norm(b64: str) -> str:
            return b64.rstrip("=").rstrip()

        live_cert  = norm(cert_match)
        ios_cert   = norm(relay.bridge_cert)

        if live_cert == ios_cert:
            _ok(f"obfs4 cert matches Constants.swift: {live_cert[:20]}…")
            return _record(f"{relay.name} [6] obfs4 cert", True, critical=False, detail=live_cert)
        else:
            _fail(
                f"obfs4 cert MISMATCH — iOS clients will get 'HMAC verification failed'!\n"
                f"      Relay live cert:    {live_cert[:40]}…\n"
                f"      Constants.swift:    {ios_cert[:40]}…\n"
                f"      Fix: update mskRelayBridgeCert in Constants.swift to:\n"
                f"        \"{cert_match}\""
            )
            return _record(
                f"{relay.name} [6] obfs4 cert", False, critical=False,
                detail=f"live={live_cert} ios={ios_cert}"
            )

    except subprocess.TimeoutExpired:
        _warn(f"SSH timed out after {timeout:.0f}s")
        return _record(f"{relay.name} [6] obfs4 cert", None, critical=False, detail="ssh_timeout")
    except FileNotFoundError:
        _warn("ssh binary not found — install OpenSSH or run manually (see check [6] instructions)")
        return _record(f"{relay.name} [6] obfs4 cert", None, critical=False, detail="no_ssh")
    except Exception as e:
        _warn(str(e))
        return _record(f"{relay.name} [6] obfs4 cert", None, critical=False, detail=str(e))


def check_grpc_upstream(timeout: float = 10.0) -> bool:
    """
    [7] gRPC upstream: verify ams.konstruct.cc:443 is reachable with h2 ALPN.

    This check is done from the machine running this script, NOT through
    the relay.  Its purpose:
      a) Confirm AMS is up (rules out upstream outage as cause of relay failures)
      b) Verify h2 ALPN works on the direct path (so relay→AMS path should work too)

    If this fails from Russia but passes from other networks:
      → DPI is blocking h2 ALPN on the direct path (expected, that's why ICE exists)
      The relay routes around this — the relay's path to AMS goes via Amsterdam.
    """
    _sub(f"[7] gRPC upstream reachability: {GRPC_UPSTREAM}:{GRPC_PORT}")
    ctx = ssl.create_default_context()
    ctx.set_alpn_protocols(["h2", "http/1.1"])
    t0 = time.monotonic()
    try:
        raw = socket.create_connection((GRPC_UPSTREAM, GRPC_PORT), timeout=timeout)
        raw.settimeout(timeout)
        tls = ctx.wrap_socket(raw, server_hostname=GRPC_UPSTREAM)
        elapsed = time.monotonic() - t0
        alpn = tls.selected_alpn_protocol()
        tls.close()
        if alpn == "h2":
            _ok(f"AMS reachable in {elapsed * 1000:.0f} ms, ALPN=h2  ✓")
            return _record("[7] gRPC AMS upstream", True, critical=False)
        else:
            _warn(f"AMS reachable but ALPN={alpn!r} (expected h2)")
            return _record("[7] gRPC AMS upstream", True, critical=False, detail=f"alpn={alpn}")
    except socket.timeout:
        _warn(
            f"AMS timed out — DPI likely blocking h2 ALPN on direct path.\n"
            "      This is EXPECTED from inside Russia — that's why ICE relay exists.\n"
            "      The relay routes traffic via Amsterdam where DPI doesn't apply."
        )
        return _record("[7] gRPC AMS upstream", None, critical=False, detail="timeout_expected_in_ru")
    except Exception as e:
        _warn(f"AMS check failed: {e}")
        return _record("[7] gRPC AMS upstream", None, critical=False, detail=str(e))


# ─────────────────────────────────────────────────────────────────────────────
# Runner
# ─────────────────────────────────────────────────────────────────────────────

def run_relay_checks(relay: RelayConfig, ssh_target: Optional[str]) -> None:
    _head(f"━━━  {relay.name}  ({relay.addr})  ━━━")
    _info(f"SNI: {relay.sni}   WT path: {relay.wt_path}")

    # [1] TCP
    tcp_ok = check_tcp(relay)
    if not tcp_ok:
        _warn("TCP failed — skipping TLS/WebTunnel checks (no connectivity)")
        for n in ("[2] TLS", "[3] SPKI", "[4] ALPN", "[5] WebTunnel"):
            _record(f"{relay.name} {n}", False, detail="skipped: tcp failed")
        if ssh_target:
            check_obfs4_cert_via_ssh(relay, ssh_target)
        return

    # [2]+[3] TLS + SPKI, also collect negotiated ALPN for [4]
    tls_ok, spki_ok, negotiated_alpn = check_tls_and_spki(relay)

    # [4] ALPN check
    check_alpn(relay, negotiated_alpn)

    # [5] WebTunnel
    check_webtunnel(relay)

    # [6] obfs4 cert (requires SSH)
    if ssh_target:
        check_obfs4_cert_via_ssh(relay, ssh_target)
    else:
        _sub("[6] obfs4 cert freshness")
        _info(
            "Skipped — run with --ssh user@relay-host to verify.\n"
            f"         Manual check:\n"
            f"           ssh user@{relay.addr.split(':')[0]} \\\n"
            f"             \"docker exec relay cat /data/relay.obfs4\"\n"
            f"         Expected cert prefix: {relay.bridge_cert[:20]}…"
        )
        _record(f"{relay.name} [6] obfs4 cert", None, critical=False, detail="skipped: no --ssh")


# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

def print_summary() -> int:
    """Print result table. Returns exit code (0=all critical passed, 1=any critical failed)."""
    _head("━━━  SUMMARY  ━━━")

    critical_fail = 0
    non_critical_fail = 0

    for r in _results:
        if r.passed is True:
            icon = f"{GREEN}✅ PASS{RESET}"
        elif r.passed is False:
            icon = f"{RED}❌ FAIL{RESET}"
            if r.critical:
                critical_fail += 1
            else:
                non_critical_fail += 1
        else:
            icon = f"{YELLOW}⚠️  N/A {RESET}"

        crit_tag = "" if r.critical else f"{DIM} [warn]{RESET}"
        detail   = f"  {DIM}← {r.detail}{RESET}" if r.detail else ""
        print(f"  {icon}  {r.name}{crit_tag}{detail}")

    total    = len([r for r in _results if r.passed is not None])
    passed   = len([r for r in _results if r.passed is True])
    print(f"\n  {BOLD}{passed}/{total} checks passed{RESET}")

    if critical_fail == 0:
        if non_critical_fail == 0:
            print(f"  {GREEN}{BOLD}All checks passed — relay is healthy ✓{RESET}")
        else:
            print(f"  {YELLOW}{BOLD}{non_critical_fail} non-critical warning(s) — review above{RESET}")
        print()
        return 0
    else:
        print(f"  {RED}{BOLD}{critical_fail} critical check(s) FAILED — relay will not work for Russian users{RESET}")
        print()
        print(f"{BOLD}Next steps:{RESET}")
        for r in _results:
            if r.passed is False and r.critical:
                print(f"  • {r.name}: {r.detail or 'see output above'}")
        print()
        return 1


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="construct-relay post-deploy health check",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--relay",
        metavar="IP:PORT",
        help="Test only this relay address (e.g. 158.160.140.67:443). "
             "Default: all relays in RELAYS list.",
    )
    parser.add_argument(
        "--ssh",
        metavar="USER@HOST",
        help="SSH target for obfs4 cert freshness check (check [6]). "
             "Example: root@158.160.140.67",
    )
    args = parser.parse_args()

    relays_to_check = RELAYS
    if args.relay:
        matches = [r for r in RELAYS if r.addr == args.relay]
        if not matches:
            # Create a minimal config for unknown relay addresses
            print(f"{YELLOW}⚠️  Relay {args.relay} not in hardcoded RELAYS list — running with empty expected values{RESET}")
            matches = [RelayConfig(
                name        = args.relay,
                addr        = args.relay,
                sni         = "",
                spki_sha256 = "",
                bridge_cert = "",
                wt_path     = "/construct-ice",
            )]
        relays_to_check = matches

    print(f"\n{BOLD}{'═' * 60}")
    print("  construct-relay Post-Deploy Health Check")
    print(f"  Checking {len(relays_to_check)} relay(s)")
    if args.ssh:
        print(f"  SSH target: {args.ssh}  (for obfs4 cert check)")
    print(f"{'═' * 60}{RESET}")

    for relay in relays_to_check:
        run_relay_checks(relay, args.ssh)

    # [7] gRPC upstream (once, not per-relay)
    _head("━━━  gRPC Upstream  ━━━")
    check_grpc_upstream()

    return print_summary()


if __name__ == "__main__":
    sys.exit(main())
