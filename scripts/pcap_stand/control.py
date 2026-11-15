#!/usr/bin/env python3
"""Traffic the analyzer must flag — the positive control of todos 309 and 310.

A red t1/t2/t3 on the app means nothing unless the same analyzer, on the same kind of capture,
turns red where it should. This script makes that traffic while capture.sh records, and writes the
needles and the red lines it expects. Its values are random per run, not the stand accounts': the
control proves the analyzer, and the stand's identifiers never go to a third-party host.

The far end is example.com (IANA's reserved example host); what it receives is random bytes.

    control.py <out-dir>      # writes control-needles.json, control-expect.json
"""

import json
import os
import secrets
import socket
import ssl
import subprocess
import sys
import time
import uuid

HOST = "example.com"
CURL_H3 = "/opt/homebrew/opt/curl/bin/curl"


def needle_entry(name, raw):
    return {"name": name, "hex": raw.hex()}


def plain_http_split(ip, whole, split):
    """One cleartext HTTP flow: a needle sent whole, and another cut across two TCP segments."""
    s = socket.create_connection((ip, 80), timeout=5)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    half = len(split) // 2
    s.sendall(b"POST / HTTP/1.1\r\nHost: " + HOST.encode() + b"\r\nContent-Length: "
              + str(len(whole) + len(split) + 1).encode() + b"\r\nConnection: close\r\n\r\n"
              + whole + b" " + split[:half])
    time.sleep(0.4)
    s.sendall(split[half:])
    try:
        s.recv(4096)
    except OSError:
        pass
    s.close()


def tls_sni(ip, name):
    """A ClientHello carrying the needle as its server name; the handshake may well fail."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((ip, 443), timeout=5) as raw:
            with ctx.wrap_socket(raw, server_hostname=name):
                pass
    except (OSError, ssl.SSLError):
        pass


def tls_same_ticket(ip):
    """Three TLS 1.3 connections, the second and third resuming with the first one's ticket:
    the same PSK identity in two ClientHellos — what t3 exists to catch."""
    ctx = ssl.create_default_context()
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3

    def get(session=None):
        with socket.create_connection((ip, 443), timeout=5) as raw:
            with ctx.wrap_socket(raw, server_hostname=HOST, session=session) as s:
                s.sendall(b"GET / HTTP/1.1\r\nHost: " + HOST.encode() + b"\r\nConnection: close\r\n\r\n")
                while s.recv(65536):
                    pass
                return s.session

    first = get()
    if first is None or not first.has_ticket:
        sys.exit("control: the first connection got no ticket; t3 control cannot be made")
    # The app's ClientHello (post-quantum key share) spans two TCP segments; a field read only from
    # single-segment hellos would pass the control and miss the app. Pad the resumed hellos past
    # one segment with ALPN names; whether the server then completes does not matter — the
    # ClientHello, with its PSK identity, is already on the wire.
    ctx.set_alpn_protocols([f"x-pad-{i:02d}-" + "p" * 40 for i in range(40)] + ["http/1.1"])
    for _ in range(2):
        try:
            get(first)
        except (OSError, ssl.SSLError):
            pass


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    ip = socket.gethostbyname(HOST)

    whole = secrets.token_hex(16).encode()
    split = secrets.token_hex(16).encode()
    sni_tls = f"{uuid.uuid4()}.{HOST}"
    sni_quic = f"{uuid.uuid4()}.{HOST}"
    raw_id = secrets.token_bytes(16)   # never sent: a needle that must stay unfound

    needles = [
        needle_entry("control:whole", whole),
        needle_entry("control:split", split),
        needle_entry("control:sni-tls", sni_tls.split(".")[0].encode()),
        needle_entry("control:sni-quic", sni_quic.split(".")[0].encode()),
        needle_entry("control:never-sent", raw_id),
    ]
    json.dump({"udid": "control", "needles": needles}, open(f"{out}/control-needles.json", "w"))

    plain_http_split(ip, whole, split)
    tls_sni(ip, sni_tls)
    subprocess.run([CURL_H3, "--http3-only", "-sk", "--max-time", "5",
                    "--resolve", f"{sni_quic}:443:{ip}", f"https://{sni_quic}/"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    tls_same_ticket(ip)

    expect = {
        "t1": ["control:whole", "control:split", "control:sni-tls", "control:sni-quic"],
        "t1_absent": ["control:never-sent"],
        "t2_red_flows": 1,
        "t3": ["tls.handshake.extensions.psk.identity.identity"],
    }
    json.dump(expect, open(f"{out}/control-expect.json", "w"))
    print("control: traffic sent")


if __name__ == "__main__":
    main()
