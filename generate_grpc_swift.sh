#!/bin/bash
# Generate Swift gRPC client code from .proto files
# Requires: protoc, protoc-gen-swift, protoc-gen-grpc-swift-2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROTOS_DIR="${PROTOS_DIR:-$HOME/Code/construct-protos}"
OUTPUT_DIR="$SCRIPT_DIR/ConstructMessenger/Networking/gRPC/Generated"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
error()   { echo -e "${RED}✗${NC} $1"; exit 1; }

# Check dependencies
for cmd in protoc protoc-gen-swift protoc-gen-grpc-swift-2; do
    command -v "$cmd" &>/dev/null || error "$cmd not found. Install via: brew install swift-protobuf grpc-swift"
done

[ -d "$PROTOS_DIR" ] || error "Proto directory not found: $PROTOS_DIR"

# Clean and recreate output dir
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

info "Proto source: $PROTOS_DIR"
info "Output: $OUTPUT_DIR"

# Collect all .proto files
PROTO_FILES=$(find "$PROTOS_DIR" -name "*.proto" -not -path "*/google/*" | sort)
PROTO_COUNT=$(echo "$PROTO_FILES" | wc -l | tr -d ' ')
info "Found $PROTO_COUNT .proto files"

# Generate Swift message types (.pb.swift) and gRPC clients (.grpc.swift)
protoc \
    --proto_path="$PROTOS_DIR" \
    --swift_out="$OUTPUT_DIR" \
    --swift_opt=Visibility=Public \
    --grpc-swift-2_out="$OUTPUT_DIR" \
    --grpc-swift-2_opt=Visibility=Public,Client=true,Server=false \
    --plugin=protoc-gen-grpc-swift-2="$(which protoc-gen-grpc-swift-2)" \
    $PROTO_FILES

# Count generated files
PB_COUNT=$(find "$OUTPUT_DIR" -name "*.pb.swift" | wc -l | tr -d ' ')
GRPC_COUNT=$(find "$OUTPUT_DIR" -name "*.grpc.swift" | wc -l | tr -d ' ')

success "Generated $PB_COUNT .pb.swift files (message types)"
success "Generated $GRPC_COUNT .grpc.swift files (gRPC clients)"
echo ""

# List generated files
info "Generated files:"
find "$OUTPUT_DIR" -name "*.swift" | sort | while read f; do
    echo "  $(basename "$f")"
done

success "Done! Add Generated/ directory to Xcode project."
