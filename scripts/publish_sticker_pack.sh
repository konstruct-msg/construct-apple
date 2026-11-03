#!/usr/bin/env bash
# publish_sticker_pack.sh — publish a built sticker pack to the server in one command.
#
#   scripts/publish_sticker_pack.sh PACK_DIR [--name NAME] [--unlisted] [--yes]
#
# PACK_DIR is what scripts/build_sticker_pack.py wrote (pack.json + blobs/), with every emoji
# filled in. The script:
#   1. checks the pack locally — every emoji set, every blob present with the hash and size
#      pack.json names, the limits the server enforces — so a refusal happens before the upload;
#   2. shows what will be published and asks once: a pack is its manifest's hash, so title,
#      emoji and order cannot be changed after this (vault deployment/sticker-publish-runbook.md);
#   3. copies the pack to ~/stickers/NAME on the box;
#   4. runs sticker-publish in a one-off container of the deployed media image. The signing key
#      is read from the box's app.env inside the ssh session and never leaves the box;
#   5. checks the effect: the catalog lists the pack_id the tool printed and the manifest
#      resolves — not the tool's exit code.
#
# Re-running with the same pack is safe: blobs are idempotent by hash and the tool finishes a
# half-written publish. Needs ssh access to the box, and grpcurl (brew install grpcurl) plus a
# construct-protos checkout for step 5.
#
# Defaults can be overridden from the environment:
#   STICKER_SSH        maxeliseyev@152.42.130.140
#   STICKER_SERVER_DIR /opt/construct-server              (holds ops/docker-compose.prod.yml)
#   STICKER_ENV_FILE   /opt/construct/secrets/app.env     (BUNDLE_SIGNING_KEY, _PUBLIC_KEY)
#   STICKER_ENDPOINT   ams.konstruct.cc:443
#   STICKER_PROTOS     ~/Code/construct-protos

set -euo pipefail

SSH_TARGET="${STICKER_SSH:-maxeliseyev@152.42.130.140}"
SERVER_DIR="${STICKER_SERVER_DIR:-/opt/construct-server}"
ENV_FILE="${STICKER_ENV_FILE:-/opt/construct/secrets/app.env}"
ENDPOINT="${STICKER_ENDPOINT:-ams.konstruct.cc:443}"
PROTOS="${STICKER_PROTOS:-$HOME/Code/construct-protos}"

usage() { sed -n '3,4p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

PACK_DIR=""; NAME=""; UNLISTED=""; YES=""
while (( $# )); do
  case "$1" in
    --name) NAME="${2:?--name needs a value}"; shift 2 ;;
    --unlisted) UNLISTED="--unlisted"; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) [[ -z "$PACK_DIR" ]] || usage; PACK_DIR="$1"; shift ;;
  esac
done
[[ -n "$PACK_DIR" ]] || usage
PACK_DIR="${PACK_DIR%/}"
[[ -d "$PACK_DIR" ]] || { echo "✗ not a directory: $PACK_DIR" >&2; exit 1; }

# The directory name on the box: given, or the built folder's name without "stickerpack_NNNN_".
if [[ -z "$NAME" ]]; then
  NAME="$(basename "$PACK_DIR")"
  NAME="${NAME#stickerpack_[0-9][0-9][0-9][0-9]_}"
fi
[[ "$NAME" =~ ^[a-z0-9_-]+$ ]] || { echo "✗ --name must be [a-z0-9_-]+, got '$NAME'" >&2; exit 1; }

# 1. Local check. Same rules as sticker-publish (media-service/src/stickers.rs) and the client.
python3 -I - "$PACK_DIR" <<'PY'
import hashlib, json, sys
from pathlib import Path

MAX_BYTES, MAX_STICKERS, MAX_EMOJI_BYTES = 100 * 1024, 120, 32
root = Path(sys.argv[1])
errors = []
try:
    pack = json.loads((root / "pack.json").read_text(encoding="utf-8"))
except Exception as exc:  # noqa: BLE001
    sys.exit(f"✗ {root}/pack.json: {exc}")

stickers = pack.get("stickers") or []
if not pack.get("title"):
    errors.append("title is empty")
if not pack.get("publisher"):
    errors.append("publisher is empty")
if not 1 <= len(stickers) <= MAX_STICKERS:
    errors.append(f"{len(stickers)} stickers, expected 1..{MAX_STICKERS}")

total = 0
for i, s in enumerate(stickers):
    where = f"sticker {i} ({s.get('source', '?')})"
    emoji = s.get("emoji") or ""
    if not emoji:
        errors.append(f"{where}: emoji is empty — fill it in pack.json")
    elif len(emoji.encode("utf-8")) > MAX_EMOJI_BYTES:
        errors.append(f"{where}: emoji is over {MAX_EMOJI_BYTES} UTF-8 bytes")
    sha = s.get("sha256", "")
    blob = root / "blobs" / f"{sha}.webp"
    if not blob.is_file():
        errors.append(f"{where}: blobs/{sha}.webp is missing")
        continue
    data = blob.read_bytes()
    total += len(data)
    if hashlib.sha256(data).hexdigest() != sha:
        errors.append(f"{where}: blob hash does not match pack.json")
    if len(data) != s.get("byte_len"):
        errors.append(f"{where}: blob is {len(data)} B, pack.json says {s.get('byte_len')}")
    if len(data) > MAX_BYTES:
        errors.append(f"{where}: {len(data)} B is over {MAX_BYTES}")

if errors:
    print("✗ the pack is not ready:", *errors, sep="\n  ", file=sys.stderr)
    sys.exit(1)

print(f"  {pack['title']} — {pack['publisher']}, {len(stickers)} stickers, {total / 1024:.0f} KB")
print("  " + " ".join(s["emoji"] for s in stickers))
PY

# 2. One question: what is published cannot be edited.
echo "  → $SSH_TARGET:~/stickers/$NAME${UNLISTED:+ (unlisted)}"
if [[ -z "$YES" ]]; then
  read -r -p "  Title, emoji and order are final once published. Publish? [y/N] " answer
  [[ "$answer" == [yY]* ]] || { echo "  nothing published"; exit 1; }
fi

# 3. Upload. A fresh copy each time, so a rebuilt pack never mixes with an older upload.
echo "• uploading"
ssh "$SSH_TARGET" "rm -rf ~/stickers/$NAME && mkdir -p ~/stickers"
scp -q -r "$PACK_DIR" "$SSH_TARGET:~/stickers/$NAME"

# 4. Publish on the box. The key is read there and passed to this one process only; the media
# service itself never holds it.
echo "• publishing"
OUT="$(ssh "$SSH_TARGET" bash -s -- "$NAME" "$SERVER_DIR" "$ENV_FILE" "$UNLISTED" <<'REMOTE'
set -euo pipefail
name="$1"; server_dir="$2"; env_file="$3"; unlisted="${4:-}"
key="$(grep '^BUNDLE_SIGNING_KEY=' "$env_file" | cut -d= -f2-)"
pub="$(grep '^BUNDLE_SIGNING_PUBLIC_KEY=' "$env_file" | cut -d= -f2-)"
[[ -n "$key" ]] || { echo "✗ BUNDLE_SIGNING_KEY not found in $env_file" >&2; exit 1; }
cd "$server_dir"
docker compose -f ops/docker-compose.prod.yml run --rm -T \
  -v "$HOME/stickers/$name:/packs/$name:ro" \
  -e BUNDLE_SIGNING_KEY="$key" \
  -e BUNDLE_SIGNING_PUBLIC_KEY="$pub" \
  media sticker-publish "/packs/$name" $unlisted
REMOTE
)" || { echo "$OUT"; echo "✗ sticker-publish failed — re-running the same command is safe" >&2; exit 1; }
echo "$OUT"

PACK_ID="$(awk '$1 == "pack_id" { print $2; exit }' <<<"$OUT")"
[[ "$PACK_ID" =~ ^[0-9a-f]{64}$ ]] || { echo "✗ no pack_id in the tool's output" >&2; exit 1; }

# 5. The effect: the server serves the manifest and (unless unlisted) lists the pack.
if ! command -v grpcurl >/dev/null || [[ ! -f "$PROTOS/services/sticker_service.proto" ]]; then
  echo "! grpcurl or $PROTOS missing — check the catalog by hand (runbook §5)"
  exit 0
fi
echo "• checking $ENDPOINT"
ID_B64="$(python3 -I -c 'import base64,sys; print(base64.b64encode(bytes.fromhex(sys.argv[1])).decode())' "$PACK_ID")"
rpc() { grpcurl -max-time 20 -import-path "$PROTOS" -proto services/sticker_service.proto -d "$2" "$ENDPOINT" "shared.proto.services.v1.StickerService/$1"; }

rpc GetStickerPackManifest "{\"pack_id\":\"$ID_B64\"}" | grep -q '"signature"' \
  || { echo "✗ the manifest of $PACK_ID does not resolve" >&2; exit 1; }
echo "  ✓ manifest resolves"

if [[ -z "$UNLISTED" ]]; then
  rpc ListStickerPacks '{"page_size": 120}' | grep -qF "\"$ID_B64\"" \
    || { echo "✗ the catalog does not list $PACK_ID" >&2; exit 1; }
  echo "  ✓ listed in the catalog — clients show it under More packs / Add stickers"
fi
