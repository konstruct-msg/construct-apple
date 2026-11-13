"""TCP proxy on :LISTEN that logs each connection's ClientHello and forwards to :UPSTREAM.

One line per connection: the extension types in order, whether pre_shared_key (41) is present,
the legacy session id length and the PSK identities' hex. Used to see whether Network.framework
resumes a TLS session to the same host, and what resumption_enabled=false does to the hello.
"""
import socket, sys, threading

LISTEN, UPSTREAM = int(sys.argv[1]), int(sys.argv[2])


def parse_hello(rec: bytes) -> str:
    if len(rec) < 5 or rec[0] != 0x16:
        return "not a handshake record"
    body = rec[5:]
    if body[0] != 0x01:
        return "not a ClientHello"
    p = 4 + 2 + 32  # handshake header, legacy_version, random
    sid_len = body[p]; p += 1 + sid_len
    cs_len = int.from_bytes(body[p:p + 2], "big"); p += 2 + cs_len
    comp_len = body[p]; p += 1 + comp_len
    ext_total = int.from_bytes(body[p:p + 2], "big"); p += 2
    end = p + ext_total
    exts, psk_ids = [], []
    while p + 4 <= end:
        t = int.from_bytes(body[p:p + 2], "big"); n = int.from_bytes(body[p + 2:p + 4], "big")
        data = body[p + 4:p + 4 + n]
        # GREASE values (0x?a?a) vary per hello; fold them into one name.
        exts.append("GREASE" if (t & 0x0F0F) == 0x0A0A else str(t))
        if t == 41:
            ids_len = int.from_bytes(data[0:2], "big"); q = 2
            while q < 2 + ids_len:
                il = int.from_bytes(data[q:q + 2], "big")
                psk_ids.append(data[q + 2:q + 2 + il][:16].hex())
                q += 2 + il + 4
        p += 4 + n
    return f"sid_len={sid_len} psk={'41' in exts} exts={','.join(exts)} psk_ids={psk_ids}"


def pump(a, b):
    try:
        while (d := a.recv(65536)):
            b.sendall(d)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try: s.shutdown(socket.SHUT_RDWR)
            except OSError: pass


def handle(c, n):
    first = b""
    while len(first) < 5 or len(first) < 5 + int.from_bytes(first[3:5], "big"):
        d = c.recv(65536)
        if not d:
            return
        first += d
    print(f"conn{n}: {parse_hello(first)}", flush=True)
    u = socket.create_connection(("127.0.0.1", UPSTREAM))
    u.sendall(first)
    threading.Thread(target=pump, args=(u, c), daemon=True).start()
    pump(c, u)


srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", LISTEN)); srv.listen()
n = 0
while True:
    c, _ = srv.accept(); n += 1
    threading.Thread(target=handle, args=(c, n), daemon=True).start()
