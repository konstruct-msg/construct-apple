#!/bin/bash
# build_transport_lib.sh
# Builds construct-transport UniFFI bindings + ConstructTransport.xcframework
# for iOS and/or macOS Desktop.
#
# Thin wrapper around construct-transport/build_ios.sh — keeps transport build
# commands discoverable from the messenger repo (mirrors build_crypto_lib.sh).
#
# USAGE:
#   ./build_transport_lib.sh              # iOS device + Simulator (default)
#   ./build_transport_lib.sh --mac        # macOS native arm64 (Desktop)
#   ./build_transport_lib.sh --all        # iOS + Simulator + macOS
#   ./build_transport_lib.sh --bindings   # regenerate Swift bindings only
#   ./build_transport_lib.sh --clean      # cargo clean before build
#   ./build_transport_lib.sh --debug      # debug profile
#
# OUTPUT (written into this repo):
#   ConstructTransport.xcframework/
#   ConstructMessenger/construct_transport.swift
#   ConstructMessenger/construct_transportFFI.h

set -e
set -o pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅${NC} $1"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
info() { echo -e "${BLUE}▸${NC} $1"; }
warn() { echo -e "${YELLOW}⚠️${NC}  $1"; }
hdr()  { echo -e "\n${BOLD}━━━  $1  ━━━${NC}"; }

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSPORT_PATH="$HOME/Code/construct-transport"

[ -d "$TRANSPORT_PATH" ] || TRANSPORT_PATH="$PROJECT_ROOT/../construct-transport"
[ -d "$TRANSPORT_PATH" ] || \
  fail "construct-transport не найден. Ожидается ~/Code/construct-transport или ../construct-transport"

BUILD_SCRIPT="$TRANSPORT_PATH/build_ios.sh"
[ -f "$BUILD_SCRIPT" ] || fail "build_ios.sh не найден в $TRANSPORT_PATH"

# Map messenger-style flags → construct-transport/build_ios.sh flags.
FORWARD=()
ANY_TARGET=false

for arg in "$@"; do
  case "$arg" in
    --ios|--sim|--mac|--bindings|--clean|--debug)
      FORWARD+=("$arg")
      case "$arg" in --ios|--sim|--mac) ANY_TARGET=true ;; esac
      ;;
    --all)
      FORWARD+=(--ios --sim --mac)
      ANY_TARGET=true
      ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      warn "Неизвестный аргумент: $arg"
      ;;
  esac
done

hdr "construct-transport"
info "Repo: $TRANSPORT_PATH"
info "Messenger: $PROJECT_ROOT"

exec bash "$BUILD_SCRIPT" "${FORWARD[@]}"