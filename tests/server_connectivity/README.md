# Server Connectivity Tests

Tests each network layer so you can pinpoint exactly where blocking occurs.

There are **two** suites:

| Script | What it proves |
|--------|----------------|
| `test_connectivity.py` | Short path: TCP / TLS / unary gRPC |
| `test_bidi_soak.py` | **Messenger data plane**: long H2 hold, MessageStream open, heartbeat soak, reconnect storm |
| `run_device_path.sh` | One-shot wrapper (+ optional `csc diagnose` / pcap hints) |

Short-path green **does not** mean the app works. iOS with VEIL off fails on
long-lived `MessageStream` while unary RPCs still succeed — use the soak.

## Setup

```bash
pip3 install grpcio grpcio-tools

# Compile protos (only needed once, or after proto changes)
cd /Users/maximeliseyev/Code/construct-protos
python3 -m grpc_tools.protoc -I. \
  --python_out=../construct-messenger/tests/server_connectivity/proto_gen \
  --grpc_python_out=../construct-messenger/tests/server_connectivity/proto_gen \
  services/auth_service.proto services/user_service.proto \
  core/crypto.proto core/identity.proto core/pagination.proto core/envelope.proto
```

`test_bidi_soak.py` works **without** generated messaging stubs (raw protobuf wire
for MessageStream heartbeat/subscribe). Auth stubs still improve unary detail.

## Run — short path

```bash
cd tests/server_connectivity
python3 test_connectivity.py                        # default: ams.konstruct.cc:443
python3 test_connectivity.py --host 152.42.130.140  # by IP (skip DNS)
```

## Run — realistic bidi / data-plane soak (preferred for RU path)

**Important:** run on the **same path as the phone** (iPhone Personal Hotspot → Mac).

```bash
cd tests/server_connectivity

# Unauthenticated: proves whether bidi opens (expect quick UNAUTHENTICATED if path OK)
python3 test_bidi_soak.py --duration 60 --storm --json /tmp/bidi.json

# Authed: full MessageStream + heartbeats (export tokens from a debug build / keychain dump)
ACCESS_TOKEN=… USER_ID=… DEVICE_ID=… \
  python3 test_bidi_soak.py --duration 90 --json /tmp/bidi-auth.json

# One-shot + optional csc
./run_device_path.sh --hold 60 --with-csc --capture
```

### What bidi soak checks

| Step | Mirrors iOS | Failure means |
|------|-------------|-----------------|
| TCP / TLS h2 | channel create | L4/L5 block |
| UDP → `quic.konstruct.cc` | engine-QUIC MessageStream host | UDP filtered (inconclusive if silent) |
| Unary GetPowChallenge | short RPC / control plane | gRPC unary dead |
| Channel hold + periodic unary | long-lived H2 control | middlebox kills long H2 |
| MessageStream open (≤2s) | `streamOpenAcceptTimeout` H2 | bidi blocked / open timeout |
| Heartbeat soak (authed) | data plane alive | stream dies under load/idle |
| Storm | forceReconnect thrash | self-inflicted `Stream unexpectedly closed` |

### Reading results

```
unary OK + message_stream FAIL  →  control≠data split (classic VEIL-off RU symptom)
message_stream UNAUTHENTICATED fast  →  bidi path open; need token for full soak
channel_hold FAIL  →  long H2 closed mid-session
storm closed_like=N  →  app invalidate mid-RPC looks the same
```

## Packet capture (`csc`)

```bash
cd ~/Code/construct-security-cli
cargo build --release

# Terminal A — capture ams + quic :443
sudo ./target/release/csc capture --construct -i en0 --duration 90 \
  --analyze --save-pcap ~/Desktop/construct-path.pcap

# Terminal B — layered diagnose with long H2 PING hold
./target/release/csc diagnose --construct --hold 60 --pcap-hint --json /tmp/diag.json

# Terminal C — Python MessageStream soak (same time window)
cd ~/Code/construct-messenger/tests/server_connectivity
python3 test_bidi_soak.py --duration 60 --storm
```

## What each short-path test checks

| Test | Layer | Detects |
|------|-------|---------|
| 1. TCP connect | L4 | Firewall DROP/REJECT on port 443 |
| 2. TLS no ALPN | L5 | TLS blocked regardless of ALPN |
| 3. TLS h2 ALPN | L5 | **DPI blocking gRPC** (h2 ALPN in ClientHello) |
| 4. HTTPS/1.1 GET | L7 | Web server / `.well-known` endpoint |
| 5. gRPC channel | L7 | HTTP/2 upgrade, gRPC framing |
| 6. GetPowChallenge | App | Unauthenticated gRPC RPC call |
| 7. CheckUsername | App | Another unauthenticated RPC |

## Expected results

```
Without VPN (DPI environment):
  TCP ✅  TLS/no-ALPN ✅  TLS/h2 ❌  gRPC ❌
  — or —
  short gRPC ✅  MessageStream open timeout ❌   ← most common "app broken, ping works"

With VPN / clean path:
  all ✅ including bidi soak
```

## Reproducing the iOS path issue

1. Create a WiFi hotspot from iPhone (same Wi-Fi/cellular as the failing app)
2. Connect Mac to that hotspot
3. Run `./run_device_path.sh --hold 60 --with-csc`
4. Compare with home/VPN network

## Notes

- **HTTP 200 on /.well-known/construct-server** is the DPI sanity check (a 404 here trips false-positive DPI detection). The obfs4-era `/.well-known/ice-cert` endpoint is retired.
- `GetPowChallenge` returns `difficulty=8` — this is the PoW difficulty for registration
- VEIL off leaves the client on direct only — if data plane flaps, the app looks "dead" even when ams is "reachable"
