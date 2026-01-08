#!/bin/bash

# Generate Swift bindings using UniFFI from the compiled library
# Supports multiple architectures and build configurations

set -e  # Exit on error
set -u  # Exit on undefined variable

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_PATH="$PROJECT_ROOT/packages/core"
OUTPUT_DIR="$PROJECT_ROOT/ConstructMessenger"
UDL_FILE="$CORE_PATH/src/construct_core.udl"

# Default values
BUILD_TYPE="release"
ARCHITECTURES=("aarch64-apple-ios-sim")  # Default to iOS simulator
CLEAN_BUILD=false
VERBOSE=false

# Helper functions
print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Generate Swift bindings for Construct Messenger using UniFFI

OPTIONS:
    -h, --help              Show this help message
    -d, --debug             Build in debug mode (default: release)
    -a, --arch ARCH         Target architecture (can be specified multiple times)
                            Options:
                              aarch64-apple-ios           - iOS ARM64
                              aarch64-apple-ios-sim       - iOS Simulator ARM64 (default)
                              x86_64-apple-ios            - iOS Simulator x86_64
                              aarch64-apple-darwin        - macOS ARM64
                              x86_64-apple-darwin         - macOS x86_64
    -A, --all-ios           Build for all iOS targets (device + simulators)
    -M, --all-macos         Build for all macOS targets
    -c, --clean             Clean build (remove old bindings first)
    -v, --verbose           Verbose output

EXAMPLES:
    $(basename "$0")                           # Build for iOS sim (ARM64)
    $(basename "$0") --debug                   # Build in debug mode
    $(basename "$0") -a aarch64-apple-ios      # Build for iOS device
    $(basename "$0") --all-ios                 # Build for all iOS targets
    $(basename "$0") -c -v                     # Clean build with verbose output

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -d|--debug)
            BUILD_TYPE="debug"
            shift
            ;;
        -a|--arch)
            if [ -z "${2:-}" ]; then
                print_error "Option $1 requires an argument"
                exit 1
            fi
            # Clear default if first custom arch is specified
            if [ ${#ARCHITECTURES[@]} -eq 1 ] && [ "${ARCHITECTURES[0]}" == "aarch64-apple-ios-sim" ]; then
                ARCHITECTURES=()
            fi
            ARCHITECTURES+=("$2")
            shift 2
            ;;
        -A|--all-ios)
            ARCHITECTURES=("aarch64-apple-ios" "aarch64-apple-ios-sim" "x86_64-apple-ios")
            shift
            ;;
        -M|--all-macos)
            ARCHITECTURES=("aarch64-apple-darwin" "x86_64-apple-darwin")
            shift
            ;;
        -c|--clean)
            CLEAN_BUILD=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Validate environment
check_dependencies() {
    print_header "Checking Dependencies"

    local missing_deps=()

    if ! command -v cargo &> /dev/null; then
        missing_deps+=("cargo (Rust)")
    fi

    if ! command -v uniffi-bindgen &> /dev/null; then
        print_warning "uniffi-bindgen not found in PATH, will use cargo run"
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_error "Missing required dependencies:"
        for dep in "${missing_deps[@]}"; do
            echo "  - $dep"
        done
        exit 1
    fi

    print_success "All required dependencies found"
}

# Clean old bindings
clean_bindings() {
    print_header "Cleaning Old Bindings"

    if [ -f "$OUTPUT_DIR/construct_coreFFI.h" ]; then
        rm -f "$OUTPUT_DIR/construct_coreFFI.h"
        print_success "Removed old header file"
    fi

    if [ -f "$OUTPUT_DIR/construct_core.swift" ]; then
        rm -f "$OUTPUT_DIR/construct_core.swift"
        print_success "Removed old Swift file"
    fi

    # Clean old compiled libraries
    local lib_count=$(find "$OUTPUT_DIR" -name "*.a" -o -name "*.dylib" 2>/dev/null | wc -l)
    if [ "$lib_count" -gt 0 ]; then
        find "$OUTPUT_DIR" -name "*.a" -o -name "*.dylib" -delete
        print_success "Removed $lib_count old library file(s)"
    fi
}

# Build Rust library for target
build_for_target() {
    local target=$1
    local build_flag=""

    if [ "$BUILD_TYPE" == "release" ]; then
        build_flag="--release"
    fi

    print_info "Building for $target ($BUILD_TYPE)..."

    cd "$CORE_PATH"

    if [ "$VERBOSE" = true ]; then
        cargo build --lib --target "$target" $build_flag
    else
        cargo build --lib --target "$target" $build_flag 2>&1 | grep -v "Compiling\|Finished" || true
    fi

    # Patch UniFFI generated files for Rust 1.82+ compatibility
    cd "$PROJECT_ROOT"
    if [ -f "./patch_uniffi_unsafe.sh" ]; then
        bash ./patch_uniffi_unsafe.sh > /dev/null 2>&1
    fi

    print_success "Built successfully for $target"
}

# Generate Swift bindings
generate_bindings() {
    print_header "Generating Swift Bindings"

    cd "$PROJECT_ROOT"

    # Check if UDL file exists
    if [ ! -f "$UDL_FILE" ]; then
        print_error "UDL file not found: $UDL_FILE"
        exit 1
    fi

    print_info "Using UDL file: $UDL_FILE"
    print_info "Output directory: $OUTPUT_DIR"

    # Try to use uniffi-bindgen from PATH first
    if command -v uniffi-bindgen &> /dev/null; then
        print_info "Using uniffi-bindgen from PATH"
        uniffi-bindgen generate "$UDL_FILE" \
            --language swift \
            --out-dir "$OUTPUT_DIR"
    else
        print_info "Using cargo run for uniffi-bindgen"
        cargo run --manifest-path "$CORE_PATH/Cargo.toml" \
            --features=uniffi/cli \
            --bin uniffi-bindgen -- \
            generate "$UDL_FILE" \
            --language swift \
            --out-dir "$OUTPUT_DIR" \
            ${VERBOSE:+--verbose}
    fi

    print_success "Swift bindings generated"
}

# Verify generated files
verify_output() {
    print_header "Verifying Generated Files"

    local swift_file="$OUTPUT_DIR/construct_core.swift"
    local header_file="$OUTPUT_DIR/construct_coreFFI.h"

    if [ ! -f "$swift_file" ]; then
        print_error "Swift file not generated: $swift_file"
        exit 1
    fi

    if [ ! -f "$header_file" ]; then
        print_error "Header file not generated: $header_file"
        exit 1
    fi

    local swift_lines=$(wc -l < "$swift_file")
    local header_lines=$(wc -l < "$header_file")

    print_success "construct_core.swift (${swift_lines} lines)"
    print_success "construct_coreFFI.h (${header_lines} lines)"

    # List all generated files
    echo ""
    print_info "Generated files in $OUTPUT_DIR:"
    ls -lh "$OUTPUT_DIR"/construct_core* 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
}

# Main execution
main() {
    print_header "Swift Bindings Generator for Construct Messenger"

    print_info "Build type: $BUILD_TYPE"
    print_info "Targets: ${ARCHITECTURES[*]}"

    # Check dependencies
    check_dependencies

    # Clean if requested
    if [ "$CLEAN_BUILD" = true ]; then
        clean_bindings
    fi

    # Build for each architecture
    print_header "Building Rust Library"
    for arch in "${ARCHITECTURES[@]}"; do
        build_for_target "$arch"
    done

    # Generate bindings
    generate_bindings

    # Verify output
    verify_output

    # Final message
    echo ""
    print_success "✨ All done! Swift bindings are ready to use."
    echo ""
}

# Run main function
main
