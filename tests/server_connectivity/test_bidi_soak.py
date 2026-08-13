#!/usr/bin/env python3
"""
Construct — realistic data-plane soak (MessageStream-shaped)

Why this exists
---------------
`test_connectivity.py` proves short path: TCP / TLS / unary gRPC.
The iOS messenger fails when **long-lived bidi** (MessageStream) or the
shared channel dies under concurrent load — while short RPCs still look fine.

This script mirrors what the app actually does with VEIL off:

  A. Baseline short path (unary GetPowChallenge)
  B. H2 channel hold + periodic unary (control plane over long connection)
  C. MessageStream open latency (headers / first frame / auth error)
  D. MessageStream heartbeat soak (optional --token → real data plane)
  E. Storm mode: concurrent unaries + channel invalidation mid-stream
  F. QUIC/UDP host probe (quic.konstruct.cc — preferred iOS stream path)

Run on the **same network path as the phone** (iPhone hotspot → Mac, or
Linux on the censored Wi-Fi). Pair with:

  sudo csc diagnose --construct --pcap /tmp/construct-path.pcap

Usage
-----
  python3 test_bidi_soak.py
  python3 test_bidi_soak.py --duration 60 --storm
  python3 test_bidi_soak.py --host ams.konstruct.cc --quic-host quic.konstruct.cc
  ACCESS_TOKEN=… USER_ID=… DEVICE_ID=… python3 test_bidi_soak.py --duration 90
  python3 test_bidi_soak.py --json report.json
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import ssl
import struct
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any, Optional

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
DIM = "\033[2m"
RESET = "\033[0m"

# iOS NetworkTiming.GRPC mirrors (seconds)
IOS_H3_ACCEPT = 1.5
IOS_H2_ACCEPT = 2.0
IOS_H3_HARD = 5.0

MESSAGING_STREAM_METHOD = (
    "/shared.proto.services.v1.MessagingService/MessageStream"
)


# ── helpers ──────────────────────────────────────────────────────────────────


def ok(msg: str) -> None:
    print(f"  {GREEN}✅ {msg}{RESET}")


def fail(msg: str) -> None:
    print(f"  {RED}❌ {msg}{RESET}")


def warn(msg: str) -> None:
    print(f"  {YELLOW}⚠️  {msg}{RESET}")


def info(msg: str) -> None:
    print(f"  {CYAN}• {msg}{RESET}")


def section(title: str) -> None:
    print(f"\n{BOLD}{CYAN}{'─' * 60}{RESET}")
    print(f"{BOLD}{CYAN}{title}{RESET}")
    print(f"{CYAN}{'─' * 60}{RESET}")


@dataclass
class StepResult:
    name: str
    ok: bool
    detail: str
    elapsed_ms: float
    meta: dict[str, Any] = field(default_factory=dict)

    def verdict_icon(self) -> str:
        return f"{GREEN}OK{RESET}" if self.ok else f"{RED}FAIL{RESET}"


@dataclass
class SoakReport:
    started_at: str
    host: str
    quic_host: str
    duration_s: float
    steps: list[StepResult] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    def add(self, step: StepResult) -> StepResult:
        self.steps.append(step)
        icon = "✅" if step.ok else "❌"
        print(f"  {icon} [{step.elapsed_ms:.0f}ms] {step.name}: {step.detail}")
        return step

    def to_dict(self) -> dict:
        return {
            "started_at": self.started_at,
            "host": self.host,
            "quic_host": self.quic_host,
            "duration_s": self.duration_s,
            "steps": [asdict(s) for s in self.steps],
            "notes": self.notes,
        }


def resolve_host(hostname: str) -> list[str]:
    ips: list[str] = []
    try:
        for fam, _, _, _, sockaddr in socket.getaddrinfo(hostname, None):
            ip = sockaddr[0]
            if ip not in ips:
                ips.append(ip)
    except socket.gaierror as e:
        warn(f"DNS failed for {hostname}: {e}")
    return ips


def encode_varint(value: int) -> bytes:
    out = bytearray()
    v = value & 0xFFFFFFFFFFFFFFFF
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    return bytes(out)


def encode_key(field: int, wire_type: int) -> bytes:
    return encode_varint((field << 3) | wire_type)


def encode_string_field(field: int, value: str) -> bytes:
    raw = value.encode("utf-8")
    return encode_key(field, 2) + encode_varint(len(raw)) + raw


def encode_varint_field(field: int, value: int) -> bytes:
    return encode_key(field, 0) + encode_varint(value)


def encode_len_field(field: int, payload: bytes) -> bytes:
    return encode_key(field, 2) + encode_varint(len(payload)) + payload


def pb_heartbeat(ts_ms: int | None = None) -> bytes:
    """MessageStreamRequest { heartbeat: Heartbeat { timestamp } }"""
    if ts_ms is None:
        ts_ms = int(time.time() * 1000)
    inner = encode_varint_field(1, ts_ms)
    return encode_len_field(6, inner)  # oneof request.heartbeat = 6


def pb_subscribe(conversation_ids: list[str]) -> bytes:
    """MessageStreamRequest { subscribe: SubscribeRequest { conversation_ids } }"""
    inner = b"".join(encode_string_field(1, cid) for cid in conversation_ids)
    return encode_len_field(4, inner)  # oneof request.subscribe = 4


def grpc_frame(message: bytes, compress: bool = False) -> bytes:
    return struct.pack("!B I", 1 if compress else 0, len(message)) + message


# ── layer probes ─────────────────────────────────────────────────────────────


def probe_tcp(host: str, port: int, timeout: float = 8.0) -> StepResult:
    t0 = time.time()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            ms = (time.time() - t0) * 1000
            return StepResult("tcp", True, f"connected {host}:{port}", ms)
    except Exception as e:
        ms = (time.time() - t0) * 1000
        return StepResult("tcp", False, str(e), ms)


def probe_tls_h2(host: str, port: int, timeout: float = 12.0) -> StepResult:
    t0 = time.time()
    try:
        ctx = ssl.create_default_context()
        ctx.set_alpn_protocols(["h2", "http/1.1"])
        with socket.create_connection((host, port), timeout=timeout) as raw:
            raw.settimeout(timeout)
            with ctx.wrap_socket(raw, server_hostname=host) as s:
                ms = (time.time() - t0) * 1000
                alpn = s.selected_alpn_protocol()
                ok_alpn = alpn == "h2"
                return StepResult(
                    "tls_h2",
                    ok_alpn,
                    f"TLS={s.version()} ALPN={alpn}",
                    ms,
                    {"alpn": alpn, "tls": s.version()},
                )
    except Exception as e:
        ms = (time.time() - t0) * 1000
        return StepResult("tls_h2", False, str(e), ms)


def probe_udp_quic_host(host: str, port: int = 443, timeout: float = 2.0) -> StepResult:
    """
    Best-effort UDP liveness for quic.konstruct.cc.
    Sends a minimal datagram; any ICMP/response vs silent drop is informative.
    Not a full QUIC handshake (needs quinn/aioquic) — matches 'UDP path exists?'
    """
    t0 = time.time()
    try:
        ips = resolve_host(host)
        if not ips:
            return StepResult("udp_quic_host", False, "DNS failed", 0)
        ip = ips[0]
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(timeout)
        # QUIC long-header-ish junk — server may drop or reply with Initial
        payload = b"\xc0" + os.urandom(1200)
        sock.sendto(payload, (ip, port))
        try:
            data, addr = sock.recvfrom(2048)
            ms = (time.time() - t0) * 1000
            sock.close()
            return StepResult(
                "udp_quic_host",
                True,
                f"UDP reply {len(data)}B from {addr[0]} (path open)",
                ms,
                {"ip": ip, "bytes": len(data)},
            )
        except socket.timeout:
            ms = (time.time() - t0) * 1000
            sock.close()
            # Silence is common (drop or ignore) — mark inconclusive as soft-fail
            return StepResult(
                "udp_quic_host",
                False,
                f"no UDP reply in {timeout}s from {ip}:{port} "
                f"(drop/filter OR server ignores garbage — try real QUIC client)",
                ms,
                {"ip": ip, "inconclusive": True},
            )
    except Exception as e:
        ms = (time.time() - t0) * 1000
        return StepResult("udp_quic_host", False, str(e), ms)


def make_channel(host: str, port: int, keepalive_s: int = 10):
    import grpc

    return grpc.secure_channel(
        f"{host}:{port}",
        grpc.ssl_channel_credentials(),
        options=[
            ("grpc.enable_http_proxy", 0),
            ("grpc.keepalive_time_ms", keepalive_s * 1000),
            ("grpc.keepalive_timeout_ms", 5000),
            ("grpc.http2.max_pings_without_data", 0),
            ("grpc.keepalive_permit_without_calls", 1),
        ],
    )


def unary_pow(channel, timeout: float = 10.0) -> tuple[bool, str, float]:
    """Return (ok, detail, elapsed_ms)."""
    t0 = time.time()
    try:
        import grpc

        # Prefer generated stubs if present
        try:
            sys.path.insert(
                0, os.path.join(os.path.dirname(__file__), "proto_gen")
            )
            from services import auth_service_pb2, auth_service_pb2_grpc

            stub = auth_service_pb2_grpc.AuthServiceStub(channel)
            resp = stub.GetPowChallenge(
                auth_service_pb2.GetPowChallengeRequest(), timeout=timeout
            )
            ms = (time.time() - t0) * 1000
            diff = getattr(resp, "difficulty", "?")
            return True, f"GetPowChallenge difficulty={diff}", ms
        except ImportError:
            # Generic unary — still proves H2+gRPC framing
            method = "/shared.proto.services.v1.AuthService/GetPowChallenge"
            call = channel.unary_unary(
                method,
                request_serializer=lambda x: x,
                response_deserializer=lambda x: x,
            )
            try:
                call(b"", timeout=timeout)
                ms = (time.time() - t0) * 1000
                return True, "GetPowChallenge (raw) OK", ms
            except grpc.RpcError as e:
                ms = (time.time() - t0) * 1000
                # Server spoke = path OK even if parse fails
                if e.code() in (
                    grpc.StatusCode.INVALID_ARGUMENT,
                    grpc.StatusCode.INTERNAL,
                    grpc.StatusCode.UNKNOWN,
                ):
                    return True, f"server responded: {e.code().name}", ms
                if e.code() == grpc.StatusCode.UNAVAILABLE:
                    return False, f"UNAVAILABLE: {e.details()}", ms
                return True, f"gRPC {e.code().name}: {e.details()}", ms
    except Exception as e:
        ms = (time.time() - t0) * 1000
        return False, str(e), ms


def metadata_from_env() -> list[tuple[str, str]]:
    md: list[tuple[str, str]] = []
    token = os.environ.get("ACCESS_TOKEN") or os.environ.get("CONSTRUCT_ACCESS_TOKEN")
    user = os.environ.get("USER_ID") or os.environ.get("CONSTRUCT_USER_ID")
    device = os.environ.get("DEVICE_ID") or os.environ.get("CONSTRUCT_DEVICE_ID")
    if token:
        md.append(("authorization", f"Bearer {token}"))
    if user:
        md.append(("x-user-id", user))
    if device:
        md.append(("x-device-id", device))
    return md


def open_message_stream(
    channel,
    metadata: list[tuple[str, str]],
    accept_timeout: float,
    send_subscribe: bool = True,
    heartbeat_interval: float = 0.0,
    soak_s: float = 0.0,
) -> StepResult:
    """
    Open MessageStream (bidi). Without token, expect quick UNAUTHENTICATED
    (= path can open bidi). With token, soak heartbeats.
    """
    import grpc

    t0 = time.time()
    first_event_ms: Optional[float] = None
    events: list[str] = []
    heartbeats_sent = 0
    msgs_recv = 0

    def request_iter():
        nonlocal heartbeats_sent
        if send_subscribe:
            yield pb_subscribe(
                ["direct:soak-test-conversation-00000000-0000-0000-0000-000000000001"]
            )
            events.append("subscribe_sent")
        if soak_s <= 0 and heartbeat_interval <= 0:
            # single heartbeat then half-close client side eventually
            yield pb_heartbeat()
            heartbeats_sent += 1
            events.append("heartbeat_sent")
            return
        deadline = time.time() + max(soak_s, 0.1)
        # initial heartbeat immediately (iOS sends heartbeats after open)
        yield pb_heartbeat()
        heartbeats_sent += 1
        interval = heartbeat_interval if heartbeat_interval > 0 else 25.0
        while time.time() < deadline:
            time.sleep(min(interval, max(0.05, deadline - time.time())))
            if time.time() >= deadline:
                break
            yield pb_heartbeat()
            heartbeats_sent += 1

    call = channel.stream_stream(
        MESSAGING_STREAM_METHOD,
        request_serializer=lambda x: x,
        response_deserializer=lambda x: x,
    )

    try:
        responses = call(request_iter(), timeout=accept_timeout + max(soak_s, 0) + 5.0, metadata=metadata)
        # Wait for first response frame (headers+msg or trailers-only error)
        for _msg in responses:
            if first_event_ms is None:
                first_event_ms = (time.time() - t0) * 1000
            msgs_recv += 1
            events.append(f"msg#{msgs_recv}:{len(_msg)}B")
            if soak_s <= 0:
                break
            if time.time() - t0 >= soak_s:
                break
        ms = (time.time() - t0) * 1000
        # completed without RpcError
        within_h2 = (first_event_ms or ms) <= IOS_H2_ACCEPT * 1000
        return StepResult(
            "message_stream",
            True,
            f"stream open first_frame={first_event_ms or ms:.0f}ms "
            f"hb_sent={heartbeats_sent} recv={msgs_recv} "
            f"{'(within iOS H2 accept)' if within_h2 else '(SLOWER than iOS 2s accept)'}",
            ms,
            {
                "first_frame_ms": first_event_ms or ms,
                "heartbeats_sent": heartbeats_sent,
                "msgs_recv": msgs_recv,
                "within_ios_h2_accept": within_h2,
                "events": events,
                "authed": bool(metadata),
            },
        )
    except grpc.RpcError as e:
        ms = (time.time() - t0) * 1000
        code = e.code()
        details = e.details() or ""
        # Path success criteria:
        #  - UNAUTHENTICATED / PERMISSION_DENIED quickly → bidi path works, auth required
        #  - DEADLINE_EXCEEDED / UNAVAILABLE after long wait → path/stream blocked
        fast_auth = code in (
            grpc.StatusCode.UNAUTHENTICATED,
            grpc.StatusCode.PERMISSION_DENIED,
        ) and ms <= max(IOS_H2_ACCEPT, 5.0) * 1000
        path_ok = fast_auth or (
            code
            not in (
                grpc.StatusCode.DEADLINE_EXCEEDED,
                grpc.StatusCode.UNAVAILABLE,
            )
            and ms < accept_timeout * 1000
        )
        # DEADLINE with no response is the iOS "MessageStream open timed out" twin
        if code in (
            grpc.StatusCode.DEADLINE_EXCEEDED,
            grpc.StatusCode.UNAVAILABLE,
        ) and ms >= accept_timeout * 800:
            path_ok = False
        note = f"{code.name}: {details}" if details else code.name
        if fast_auth:
            note += " — bidi path OPEN (auth required; expected without token)"
        elif not path_ok:
            note += " — matches iOS MessageStream open timeout / stream death"
        return StepResult(
            "message_stream",
            path_ok,
            note,
            ms,
            {
                "grpc_code": code.name,
                "details": details,
                "first_frame_ms": first_event_ms,
                "heartbeats_sent": heartbeats_sent,
                "msgs_recv": msgs_recv,
                "within_ios_h2_accept": ms <= IOS_H2_ACCEPT * 1000,
                "events": events,
                "authed": bool(metadata),
            },
        )
    except Exception as e:
        ms = (time.time() - t0) * 1000
        return StepResult("message_stream", False, str(e), ms)


def channel_hold_unary(
    channel, duration_s: float, interval_s: float = 5.0
) -> StepResult:
    """Hold one H2 channel and fire unary RPCs periodically (control plane)."""
    t0 = time.time()
    samples: list[float] = []
    errors = 0
    last_err = ""
    while time.time() - t0 < duration_s:
        ok_u, detail, ms = unary_pow(channel, timeout=10.0)
        if ok_u:
            samples.append(ms)
        else:
            errors += 1
            last_err = detail
        sleep_left = interval_s - 0.01
        if sleep_left > 0 and time.time() - t0 < duration_s:
            time.sleep(min(sleep_left, max(0, duration_s - (time.time() - t0))))
    total_ms = (time.time() - t0) * 1000
    if not samples and errors:
        return StepResult(
            "channel_hold_unary",
            False,
            f"all unaries failed ({errors}): {last_err}",
            total_ms,
            {"errors": errors},
        )
    avg = sum(samples) / len(samples) if samples else 0
    p95 = sorted(samples)[int(0.95 * (len(samples) - 1))] if samples else 0
    return StepResult(
        "channel_hold_unary",
        errors == 0,
        f"n={len(samples)} avg={avg:.0f}ms p95={p95:.0f}ms errors={errors}",
        total_ms,
        {
            "samples_ms": samples,
            "errors": errors,
            "avg_ms": avg,
            "p95_ms": p95,
            "last_error": last_err,
        },
    )


def storm_test(host: str, port: int, workers: int = 8, rounds: int = 3) -> StepResult:
    """
    Reproduce app thrash: many concurrent unaries + channel close mid-flight.
    Expect some UNAVAILABLE/'Stream unexpectedly closed' — counts how many.
    """
    import grpc

    t0 = time.time()
    closed_like = 0
    ok_count = 0
    fail_count = 0
    details: list[str] = []

    for r in range(rounds):
        channel = make_channel(host, port)
        try:
            grpc.channel_ready_future(channel).result(timeout=10)
        except Exception as e:
            channel.close()
            return StepResult(
                "storm",
                False,
                f"channel not ready: {e}",
                (time.time() - t0) * 1000,
            )

        def one_call(i: int):
            return unary_pow(channel, timeout=8.0)

        with ThreadPoolExecutor(max_workers=workers) as pool:
            futs = [pool.submit(one_call, i) for i in range(workers)]
            # Mid-flight invalidate — same as forceReconnect / gen++
            time.sleep(0.05)
            channel.close()
            for f in as_completed(futs):
                ok_u, detail, _ms = f.result()
                if ok_u:
                    ok_count += 1
                else:
                    fail_count += 1
                    low = detail.lower()
                    if (
                        "unavailable" in low
                        or "closed" in low
                        or "cancel" in low
                        or "http2" in low
                    ):
                        closed_like += 1
                    details.append(detail)

    total_ms = (time.time() - t0) * 1000
    # Storm always produces some fails if we kill the channel — that's expected.
    # The diagnostic value is the ratio and message shapes.
    return StepResult(
        "storm",
        True,  # informational
        f"ok={ok_count} fail={fail_count} closed_like={closed_like} "
        f"(channel kill mid-RPC — app forceReconnect twin)",
        total_ms,
        {
            "ok": ok_count,
            "fail": fail_count,
            "closed_like": closed_like,
            "sample_errors": details[:8],
        },
    )


# ── main ─────────────────────────────────────────────────────────────────────


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Realistic Construct MessageStream-shaped soak test"
    )
    parser.add_argument("--host", default="ams.konstruct.cc")
    parser.add_argument("--port", type=int, default=443)
    parser.add_argument(
        "--quic-host",
        default="quic.konstruct.cc",
        help="UDP/QUIC host used by iOS engine-QUIC MessageStream",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=45.0,
        help="Seconds for channel-hold and (if authed) stream soak",
    )
    parser.add_argument(
        "--accept-timeout",
        type=float,
        default=IOS_H2_ACCEPT,
        help=f"Stream open budget (default {IOS_H2_ACCEPT}s = iOS H2 accept)",
    )
    parser.add_argument(
        "--storm",
        action="store_true",
        help="Run concurrent RPC + channel-kill thrash test",
    )
    parser.add_argument(
        "--skip-stream",
        action="store_true",
        help="Skip MessageStream (only channel hold + unary)",
    )
    parser.add_argument("--json", dest="json_out", default=None, help="Write JSON report")
    parser.add_argument(
        "--heartbeat-interval",
        type=float,
        default=10.0,
        help="Heartbeat interval during authed soak (iOS uses ~25s; 10s is denser)",
    )
    args = parser.parse_args()

    try:
        import grpc  # noqa: F401
    except ImportError:
        print(f"{RED}grpcio required: pip3 install grpcio{RESET}")
        return 2

    report = SoakReport(
        started_at=datetime.now(timezone.utc).isoformat(),
        host=args.host,
        quic_host=args.quic_host,
        duration_s=args.duration,
    )

    print(f"\n{BOLD}{'=' * 60}")
    print("  Construct bidi / data-plane soak")
    print(f"  gRPC  : {args.host}:{args.port}")
    print(f"  QUIC  : {args.quic_host}:443 (UDP probe)")
    print(f"  hold  : {args.duration}s   stream accept ≤ {args.accept_timeout}s")
    print(f"  time  : {report.started_at}")
    print(f"{'=' * 60}{RESET}")

    # DNS
    section("0. DNS")
    ams_ips = resolve_host(args.host)
    quic_ips = resolve_host(args.quic_host)
    if ams_ips:
        ok(f"{args.host} → {', '.join(ams_ips)}")
    else:
        fail(f"{args.host} unresolved")
    if quic_ips:
        ok(f"{args.quic_host} → {', '.join(quic_ips)}")
    else:
        warn(f"{args.quic_host} unresolved")
    report.notes.append(f"ams_ips={ams_ips}")
    report.notes.append(f"quic_ips={quic_ips}")

    # L4 / L5
    section("1. Short path baseline (what old tests already cover)")
    report.add(probe_tcp(args.host, args.port))
    report.add(probe_tls_h2(args.host, args.port))

    section("2. QUIC host UDP probe (iOS preferred MessageStream transport)")
    report.add(probe_udp_quic_host(args.quic_host, 443, timeout=IOS_H3_ACCEPT))

    section("3. Unary control plane")
    ch = make_channel(args.host, args.port)
    try:
        import grpc

        t0 = time.time()
        try:
            grpc.channel_ready_future(ch).result(timeout=15)
            report.add(
                StepResult(
                    "grpc_channel_ready",
                    True,
                    "READY",
                    (time.time() - t0) * 1000,
                )
            )
        except Exception as e:
            report.add(
                StepResult(
                    "grpc_channel_ready",
                    False,
                    str(e),
                    (time.time() - t0) * 1000,
                )
            )
            print(f"\n{RED}Cannot establish gRPC channel — aborting soak.{RESET}\n")
            if args.json_out:
                with open(args.json_out, "w") as f:
                    json.dump(report.to_dict(), f, indent=2)
            return 1

        ok_u, detail, ms = unary_pow(ch, timeout=12.0)
        report.add(StepResult("unary_pow", ok_u, detail, ms))

        section(
            f"4. Channel hold + periodic unary ({args.duration:.0f}s) "
            "— long-lived H2 control plane"
        )
        report.add(channel_hold_unary(ch, args.duration, interval_s=5.0))

        if not args.skip_stream:
            md = metadata_from_env()
            section("5. MessageStream open (bidi) — iOS data plane twin")
            if md:
                info("ACCESS_TOKEN present — will try authed stream + heartbeats")
            else:
                info(
                    "no ACCESS_TOKEN — expect quick UNAUTHENTICATED if bidi path is open"
                )
                info(
                    "set ACCESS_TOKEN / USER_ID / DEVICE_ID for full heartbeat soak"
                )

            # Open-only probe with iOS-like accept budget
            report.add(
                open_message_stream(
                    ch,
                    metadata=md,
                    accept_timeout=args.accept_timeout,
                    send_subscribe=True,
                    soak_s=0.0,
                )
            )

            if md:
                section(
                    f"6. MessageStream heartbeat soak ({args.duration:.0f}s, "
                    f"hb every {args.heartbeat_interval:.0f}s)"
                )
                # Fresh channel after previous stream
                ch.close()
                ch = make_channel(args.host, args.port)
                grpc.channel_ready_future(ch).result(timeout=15)
                report.add(
                    open_message_stream(
                        ch,
                        metadata=md,
                        accept_timeout=max(args.accept_timeout, 15.0),
                        send_subscribe=True,
                        heartbeat_interval=args.heartbeat_interval,
                        soak_s=args.duration,
                    )
                )
        else:
            report.notes.append("stream skipped")

        if args.storm:
            section("7. Storm — concurrent unary + channel kill (forceReconnect twin)")
            report.add(storm_test(args.host, args.port))

    finally:
        try:
            ch.close()
        except Exception:
            pass

    # Summary
    section("SUMMARY")
    fails = [s for s in report.steps if not s.ok and s.name != "storm"]
    # soft: udp probe is best-effort (server often ignores garbage Initial)
    hard_fails = [
        s
        for s in fails
        if s.name
        not in (
            "udp_quic_host",  # always soft without real QUIC stack
        )
    ]

    for s in report.steps:
        mark = f"{GREEN}OK  {RESET}" if s.ok else f"{RED}FAIL{RESET}"
        print(f"  {mark}  {s.name:22s}  {s.detail}")

    print()
    # Diagnosis blurb
    by = {s.name: s for s in report.steps}
    if by.get("unary_pow", StepResult("", False, "", 0)).ok and not by.get(
        "message_stream", StepResult("", True, "", 0)
    ).ok:
        warn(
            "DIAGNOSIS: short unary OK, MessageStream FAIL — "
            "same split as iOS with VEIL off (control ≠ data plane)."
        )
        report.notes.append("split: unary_ok stream_fail")
    if by.get("message_stream") and by["message_stream"].meta.get(
        "grpc_code"
    ) in ("UNAUTHENTICATED", "PERMISSION_DENIED"):
        ok(
            "DIAGNOSIS: bidi path reaches server (auth gate). "
            "Network is not fully blocking gRPC streams."
        )
        report.notes.append("bidi_path_open_auth_required")
    hold = by.get("channel_hold_unary")
    if hold and hold.ok:
        ok("DIAGNOSIS: long-lived H2 channel + unary held for full duration.")
    elif hold and not hold.ok:
        warn(
            "DIAGNOSIS: channel died under hold — middlebox or server closing idle/long H2."
        )
        report.notes.append("channel_hold_failed")
    if by.get("storm"):
        info(
            f"Storm closed_like={by['storm'].meta.get('closed_like')} — "
            "app forceReconnect produces the same 'Stream unexpectedly closed' flood."
        )

    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump(report.to_dict(), f, indent=2)
        info(f"JSON report → {args.json_out}")

    print()
    if hard_fails:
        print(f"{RED}{BOLD}Result: {len(hard_fails)} hard failure(s){RESET}\n")
        return 1
    print(f"{GREEN}{BOLD}Result: path OK for exercised layers{RESET}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
