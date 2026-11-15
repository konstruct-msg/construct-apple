#!/usr/bin/env python3
"""Read a stand capture and fail on what a network observer could use (todos 309, 310).

    analyze.py t1 <capture.pcap> --needles needles.json
    analyze.py t2 <capture.pcap> --host HOST [--host …] [--domain SUFFIX]
    analyze.py t3 <capture.pcap> --host HOST [--host …] [--domain SUFFIX]

The capture is the host's default interface (capture.sh). Simulators share the host's network
stack, so the app's packets are there, among the rest of the Mac's traffic. (pktap would name each
packet's process, but macOS lets only root create the pktap interface.)

t1 reads every flow: an identifier of the stand found anywhere is red, whoever sent it. t2 and t3
judge the flows to the service: addresses `--host` resolves to now, every address a DNS answer in
the capture gave for a name under `--domain`, and every address a ClientHello (TLS or QUIC) named
a host under `--domain` to — the last one holds when the host's resolver and the simulator's
disagree (a proxy's fake-IP answers did on 2026-11-15). Hosts come from the build being tested
(stand.sh reads them from its Info.plist), never from this file. Loopback flows are left out:
nothing on the network sees them.

t1 — no identifier in the clear. Every TCP direction is reassembled by sequence number; every UDP
     datagram is read as is, and the QUIC Initial CRYPTO data tshark decrypts (any observer can:
     the keys come from the DCID) is read too. Any needle found is a red line.
t2 — no flow without a handshake. A TCP flow's first client bytes must be a TLS handshake record,
     a UDP flow's first datagram a QUIC long header. Anything else is a red line.
t3 — no handshake field repeats across connections. TLS legacy session id, PSK identity,
     ClientHello random and key share; QUIC DCID/SCID of long headers and the Initial token. A
     value seen in two different connections is a red line.

Exit code: 0 green, 1 red, 2 the capture holds no flow to the service (a run that saw nothing
proves nothing).
"""

import argparse
import collections
import ipaddress
import json
import socket
import subprocess
import sys

FIELDS = [
    "frame.number",
    "ip.src", "ipv6.src", "ip.dst", "ipv6.dst",
    "tcp.stream", "tcp.srcport", "tcp.dstport", "tcp.seq_raw", "tcp.flags.syn", "tcp.flags.ack",
    "tcp.payload",
    "udp.stream", "udp.srcport", "udp.dstport", "udp.payload",
    "tls.handshake.type",
    "tls.handshake.session_id",
    "tls.handshake.random",
    "tls.handshake.extensions.psk.identity.identity",
    "tls.handshake.extensions_key_share_key_exchange",
    "tls.handshake.extensions_server_name",
    "quic.header_form", "quic.long.packet_type", "quic.dcid", "quic.scid", "quic.token",
    "dns.qry.name", "dns.a", "dns.aaaa",
]


def tshark_rows(path):
    cmd = ["tshark", "-r", path, "-n", "-T", "fields", "-E", "separator=\t", "-E", "occurrence=a",
           "-E", "aggregator=|"]
    for f in FIELDS:
        cmd += ["-e", f]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"analyze: tshark failed: {out.stderr.strip()}")
    for line in out.stdout.splitlines():
        cols = line.split("\t")
        cols += [""] * (len(FIELDS) - len(cols))
        yield dict(zip(FIELDS, cols))


def decrypted_quic(path):
    """{udp stream: [bytes]} — what tshark decrypted or reassembled from QUIC packets: the Initial
    packets (keys derived from the DCID, so any observer has them) and the CRYPTO stream and TLS
    handshake rebuilt from them. `-T fields` gives no bytes for these, so read the `-x` dump."""
    base = ["tshark", "-r", path, "-n", "-Y", "quic"]
    streams = subprocess.run(base + ["-T", "fields", "-e", "udp.stream"],
                             capture_output=True, text=True, check=True).stdout.split("\n")
    dump = subprocess.run(base + ["-x"], capture_output=True, text=True, check=True).stdout
    out = collections.defaultdict(list)
    frame, source, buf = -1, None, bytearray()

    def flush():
        if source and source != "Packet" and buf and 0 <= frame < len(streams):
            out[streams[frame]].append(bytes(buf))

    for line in dump.split("\n"):
        if line.endswith("bytes):"):
            flush()
            source, buf = line.split(" (")[0], bytearray()
            if source == "Packet":
                frame += 1
        elif len(line) > 6 and line[4:6] == "  " and all(c in "0123456789abcdef" for c in line[:4]):
            buf += bytes.fromhex(line[6:6 + 48].strip())
    flush()
    return out


def is_loopback(addr):
    try:
        return ipaddress.ip_address(addr).is_loopback
    except ValueError:
        return False


def hexes(field):
    return [bytes.fromhex(v.replace(":", "")) for v in field.split("|") if v]


class Flow:
    def __init__(self, key, proto):
        self.key, self.proto = key, proto
        self.server = None
        self.client = None          # (addr, port) that sent the first packet / the SYN
        self.segments = collections.defaultdict(list)   # direction → [(seq, bytes)]
        self.datagrams = []          # [(direction, bytes)] for UDP
        self.quic_crypto = []        # decrypted Initial CRYPTO bytes
        self.loopback = False
        self.first_payload = None    # first client → server payload
        self.handshake = collections.defaultdict(set)   # field → values


def load(path, domains=()):
    flows, service_ips = {}, set()
    for r in tshark_rows(path):
        if r["dns.a"] or r["dns.aaaa"]:
            names = [n.lower().rstrip(".") for n in r["dns.qry.name"].split("|") if n]
            if any(n == d or n.endswith("." + d) for n in names for d in domains):
                service_ips.update(v for v in (r["dns.a"] + "|" + r["dns.aaaa"]).split("|") if v)
        src = r["ip.src"] or r["ipv6.src"]
        dst = r["ip.dst"] or r["ipv6.dst"]
        if r["tcp.stream"]:
            key, proto = ("tcp", r["tcp.stream"]), "tcp"
            sport, dport = r["tcp.srcport"], r["tcp.dstport"]
        elif r["udp.stream"]:
            key, proto = ("udp", r["udp.stream"]), "udp"
            sport, dport = r["udp.srcport"], r["udp.dstport"]
        else:
            continue
        fl = flows.get(key) or flows.setdefault(key, Flow(key, proto))
        fl.loopback = fl.loopback or is_loopback(src) or is_loopback(dst)
        if fl.client is None:
            syn_only = r["tcp.flags.syn"] in ("1", "True") and r["tcp.flags.ack"] in ("0", "False")
            if proto == "udp" or syn_only or r["tcp.payload"]:
                fl.client = (src, sport)
                fl.server = dst
        direction = "c2s" if fl.client == (src, sport) else "s2c"

        payload = hexes(r["tcp.payload"] or r["udp.payload"])
        payload = payload[0] if payload else b""
        if payload:
            if proto == "tcp":
                fl.segments[direction].append((int(r["tcp.seq_raw"] or 0), payload))
            else:
                fl.datagrams.append((direction, payload))
            if direction == "c2s" and fl.first_payload is None:
                fl.first_payload = payload

        hs_types = r["tls.handshake.type"].split("|")
        if "1" in hs_types:   # ClientHello
            for f in ("tls.handshake.session_id", "tls.handshake.random",
                      "tls.handshake.extensions.psk.identity.identity",
                      "tls.handshake.extensions_key_share_key_exchange"):
                for v in r[f].split("|"):
                    if v:
                        fl.handshake[f].add(v.replace(":", ""))
            for v in r["tls.handshake.extensions_server_name"].split("|"):
                if v:
                    fl.handshake["sni"].add(v)
        if r["quic.header_form"].split("|")[0] in ("1", "True"):
            for f in ("quic.dcid", "quic.scid", "quic.token"):
                for v in r[f].split("|"):
                    if v:
                        fl.handshake[f].add(v.replace(":", ""))
    for stream, chunks in decrypted_quic(path).items():
        if ("udp", stream) in flows:
            flows[("udp", stream)].quic_crypto += chunks
    for fl in flows.values():
        for n in fl.handshake.get("sni", ()):
            n = n.lower()
            if any(n == d or n.endswith("." + d) for d in domains):
                service_ips.add(fl.server)
    return flows, service_ips


def reassemble(segments):
    """Concatenate one TCP direction in sequence order, dropping retransmitted bytes. A hole is
    kept as a separator so a needle is never stitched together across missing data."""
    out, expected = bytearray(), None
    for seq, data in sorted(segments, key=lambda s: s[0]):
        if expected is None:
            expected = seq
        if seq + len(data) <= expected:
            continue
        if seq > expected:
            out += b"\0<gap>\0"
            expected = seq
        out += data[expected - seq:]
        expected = seq + len(data)
    return bytes(out)


def resolve(hosts):
    ips = set()
    for h in hosts:
        try:
            ips.update(ai[4][0] for ai in socket.getaddrinfo(h, 443, proto=socket.IPPROTO_TCP))
        except socket.gaierror as e:
            sys.exit(f"analyze: cannot resolve {h}: {e}")
    return ips


def service_flows(flows, ips):
    picked = [f for f in flows.values() if f.server in ips and not f.loopback]
    if not picked:
        print(f"analyze: no flow to the service addresses {sorted(ips)} in the capture")
        sys.exit(2)
    return picked


def network_flows(flows):
    picked = [f for f in flows.values() if not f.loopback]
    if not picked:
        print("analyze: the capture holds no network flow")
        sys.exit(2)
    return picked


def describe(fl):
    sni = ",".join(sorted(fl.handshake.get("sni", []))) or "-"
    return f"{fl.proto} stream {fl.key[1]} → {fl.server} sni={sni}"


def t1(flows, args):
    needles = [(n["name"], bytes.fromhex(n["hex"])) for n in json.load(open(args.needles))["needles"]]
    red = 0
    for fl in network_flows(flows):
        blobs = [("tcp " + d, reassemble(s)) for d, s in fl.segments.items()]
        blobs += [("udp " + d, p) for d, p in fl.datagrams]
        blobs += [("quic-decrypted", c) for c in fl.quic_crypto]
        for where, data in blobs:
            for name, needle in needles:
                at = data.find(needle)
                if at >= 0:
                    red += 1
                    print(f"RED t1: {name} ({len(needle)} B) in {describe(fl)} {where} @{at}")
    print(f"t1: {len(needles)} needles, {red} found")
    return red


def addresses(flows, args):
    """The service addresses the run judged, for pf_block.sh."""
    ips = sorted({f.server for f in service_flows(flows, args.service_ips)})
    print(" ".join(ips))
    return 0


def t2(flows, args):
    red, judged = 0, 0
    for fl in service_flows(flows, args.service_ips):
        first = fl.first_payload
        if first is None:
            continue
        judged += 1
        if fl.proto == "tcp":
            ok = len(first) >= 3 and first[0] == 0x16 and first[1] == 0x03
            what = "TLS handshake record"
        else:
            ok = len(first) >= 5 and first[0] & 0xC0 == 0xC0 and first[1:5] != b"\0\0\0\0"
            what = "QUIC long header"
        if not ok:
            red += 1
            print(f"RED t2: {describe(fl)} starts with {first[:8].hex()} — not a {what}")
    print(f"t2: {judged} flows judged, {red} without a handshake")
    return red


def t3(flows, args):
    seen = collections.defaultdict(set)   # (field, value) → flows
    for fl in service_flows(flows, args.service_ips):
        for field, values in fl.handshake.items():
            if field == "sni":   # the same for every client; a fingerprint, not an identifier
                continue
            for v in values:
                if v.strip("0"):
                    seen[(field, v)].add(fl.key)
    red = 0
    for (field, value), keys in sorted(seen.items()):
        if len(keys) > 1:
            red += 1
            print(f"RED t3: {field}={value[:32]}… in {len(keys)} connections: "
                  f"{', '.join(k[0] + ' ' + k[1] for k in sorted(keys))}")
    print(f"t3: {len(seen)} handshake values, {red} repeated across connections")
    return red


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("test", choices=["t1", "t2", "t3", "addresses"])
    ap.add_argument("capture")
    ap.add_argument("--needles")
    ap.add_argument("--host", action="append", default=[], help="a service host, resolved now")
    ap.add_argument("--domain", action="append", default=[],
                    help="a service domain: DNS answers in the capture for names under it count")
    args = ap.parse_args()
    if args.test == "t1" and not args.needles:
        ap.error("t1 needs --needles")
    if args.test != "t1" and not (args.host or args.domain):
        ap.error(f"{args.test} needs --host or --domain")
    flows, dns_ips = load(args.capture, [d.lower() for d in args.domain])
    args.service_ips = resolve(args.host) | dns_ips
    red = {"t1": t1, "t2": t2, "t3": t3, "addresses": addresses}[args.test](flows, args)
    sys.exit(1 if red else 0)


if __name__ == "__main__":
    main()
