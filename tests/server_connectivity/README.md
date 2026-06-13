# Server Connectivity Tests

Tests each network layer so you can pinpoint exactly where blocking occurs.

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

## Run

```bash
cd tests/server_connectivity
python3 test_connectivity.py                        # default: ams.konstruct.cc:443
python3 test_connectivity.py --host 152.42.130.140  # by IP (skip DNS)
```

## What each test checks

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

With VPN:
  all ✅
```

## Reproducing the iOS DPI issue

The DPI block only affects the iOS device's cellular connection, not this Mac.
To reproduce from Mac:
1. Create a WiFi hotspot from iPhone (cellular) 
2. Connect Mac to that hotspot
3. Run the test — you should see TLS/h2 fail

## Notes

- **HTTP 200 on /.well-known/construct-server** is the DPI sanity check (a 404 here trips false-positive DPI detection). The obfs4-era `/.well-known/ice-cert` endpoint is retired.
- `GetPowChallenge` returns `difficulty=8` — this is the PoW difficulty for registration
