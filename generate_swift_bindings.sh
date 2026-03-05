#!/bin/bash

# Generate Swift bindings using UniFFI from the compiled library
# Supports multiple architectures and build configurations

set -e          # Exit on error
set -u          # Exit on undefined variable
set -o pipefail # Catch errors in pipelines (e.g. cargo ... | grep ...)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/ConstructMessenger"

# Default values
BUILD_TYPE="release"
ARCHITECTURES=("aarch64-apple-ios-sim")  # Default to iOS simulator
CLEAN_BUILD=false
FORCE_REBUILD=false  # cargo clean + clear DerivedData
VERBOSE=false
CREATE_XCFRAMEWORK=false

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

# Find construct-core path
find_construct_core() {
    # Try to find construct-core: first check ~/Code/construct-core, then sibling directory, then local path
    local home_core="$HOME/Code/construct-core"
    if [ -d "$home_core" ]; then
        # Primary location: ~/Code/construct-core
        echo "$home_core"
    elif [ -d "$PROJECT_ROOT/../construct-core" ]; then
        # Sibling directory (common during development)
        echo "$PROJECT_ROOT/../construct-core"
    elif [ -d "$PROJECT_ROOT/packages/core" ]; then
        # Local path (fallback for old setup)
        echo "$PROJECT_ROOT/packages/core"
    else
        # Try to clone from git if not found
        print_warning "construct-core not found locally. Cloning from git..."
        local temp_path="$PROJECT_ROOT/.construct-core-temp"
        if [ ! -d "$temp_path" ]; then
            git clone --depth 1 https://github.com/maximeliseyev/construct-core.git "$temp_path" || {
                print_error "Failed to clone construct-core. Please ensure you have access to the repository."
                print_error "Alternatively, you can:"
                print_error "  1. Clone construct-core manually to ../construct-core"
                print_error "  2. Or use git submodule: git submodule add https://github.com/maximeliseyev/construct-core.git packages/core"
                exit 1
            }
        fi
        echo "$temp_path"
    fi
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
                              aarch64-apple-ios           - iOS ARM64 (device)
                              aarch64-apple-ios-sim       - iOS Simulator ARM64 (default)
                              x86_64-apple-ios            - iOS Simulator x86_64
                              aarch64-apple-ios-macabi    - Mac Catalyst ARM64
                              x86_64-apple-ios-macabi     - Mac Catalyst x86_64
                              aarch64-apple-darwin        - macOS ARM64 (native)
                              x86_64-apple-darwin         - macOS x86_64 (native)
    -A, --all-ios           Build for all iOS targets (device + simulators)
    -C, --catalyst          Build for Mac Catalyst (aarch64-apple-ios-macabi)
    -X, --xcframework       Build all targets + package into XCFramework
                            Produces: construct_core.xcframework
    -M, --all-macos         Build for all macOS targets (native)
    -c, --clean             Clean build (remove old bindings first)
    -f, --force             Force full rebuild (cargo clean + DerivedData)
                            Use this to fix "UniFFI API checksum mismatch" errors
    -v, --verbose           Verbose output

EXAMPLES:
    $(basename "$0")                           # Build for iOS sim (ARM64)
    $(basename "$0") --debug                   # Build in debug mode
    $(basename "$0") -a aarch64-apple-ios      # Build for iOS device
    $(basename "$0") --all-ios                 # Build for all iOS targets
    $(basename "$0") --catalyst                # Build for Mac Catalyst
    $(basename "$0") --xcframework             # Full XCFramework (iOS + Catalyst + Sim)
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
        -C|--catalyst)
            # Clear default if first custom arch is specified
            if [ ${#ARCHITECTURES[@]} -eq 1 ] && [ "${ARCHITECTURES[0]}" == "aarch64-apple-ios-sim" ]; then
                ARCHITECTURES=()
            fi
            ARCHITECTURES+=("aarch64-apple-ios-macabi")
            shift
            ;;
        -X|--xcframework)
            # Full XCFramework: device + simulator fat + catalyst
            ARCHITECTURES=("aarch64-apple-ios" "aarch64-apple-ios-sim" "x86_64-apple-ios" "aarch64-apple-ios-macabi")
            CREATE_XCFRAMEWORK=true
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
        -f|--force)
            FORCE_REBUILD=true
            CLEAN_BUILD=true  # --force implies --clean
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

    # Also remove library from project root
    if [ -f "$PROJECT_ROOT/libconstruct_core.a" ]; then
        rm -f "$PROJECT_ROOT/libconstruct_core.a"
        print_success "Removed library from project root"
    fi
}

# Force full rebuild (cargo clean + DerivedData)
force_rebuild() {
    print_header "Force Rebuild (fixing checksum mismatch)"

    # 1. cargo clean in construct-core
    print_info "Running cargo clean in $CORE_PATH..."
    cd "$CORE_PATH"
    cargo clean
    print_success "Rust build cache cleared"

    # 2. Clear Xcode DerivedData for this project
    local derived_data=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "ConstructMessenger-*" 2>/dev/null || true)
    if [ -n "$derived_data" ]; then
        rm -rf "$derived_data"
        print_success "Cleared Xcode DerivedData"
    else
        print_info "No DerivedData found (already clean)"
    fi

    cd "$PROJECT_ROOT"
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

    # Ensure the rustup target is installed
    if ! rustup target list --installed | grep -q "^${target}$"; then
        print_info "Installing rustup target: $target"
        rustup target add "$target"
    fi

    # Build the library — use PIPESTATUS to detect failures when filtering output
    if [ "$VERBOSE" = true ]; then
        cargo build --lib --target "$target" --features ios $build_flag
    else
        cargo build --lib --target "$target" --features ios $build_flag 2>&1 \
            | grep -v "^\s*Compiling\|^\s*Finished\|^\s*Fresh"
        # pipefail catches cargo exit code through the pipe
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

    # Ensure output directory exists
    mkdir -p "$OUTPUT_DIR"
    if [ ! -d "$OUTPUT_DIR" ]; then
        print_error "Failed to create output directory: $OUTPUT_DIR"
        exit 1
    fi

    # Try to use uniffi-bindgen-cli (Rust version) first, then fallback to uniffi-bindgen
    local bindgen_cmd=""
    if command -v uniffi-bindgen-cli &> /dev/null; then
        bindgen_cmd="uniffi-bindgen-cli"
        print_info "Using uniffi-bindgen-cli (Rust CLI) from PATH"
        $bindgen_cmd --version 2>/dev/null || true
    elif command -v uniffi-bindgen &> /dev/null; then
        bindgen_cmd="uniffi-bindgen"
        print_info "Using uniffi-bindgen from PATH"
        $bindgen_cmd --version 2>/dev/null || true
    else
        print_error "uniffi-bindgen-cli or uniffi-bindgen not found in PATH"
        print_error "Please install it with: cargo install uniffi-bindgen-cli"
        exit 1
    fi
    
    # Verify that library was built before generating bindings
    # UniFFI needs the compiled library to extract metadata
    local lib_built=false
    for arch in "${ARCHITECTURES[@]}"; do
        local build_dir="release"
        if [ "$BUILD_TYPE" == "debug" ]; then
            build_dir="debug"
        fi
        # Check PROJECT_ROOT/target first, then CORE_PATH/target
        local lib_path="$PROJECT_ROOT/target/$arch/$build_dir/libconstruct_core.a"
        [ -f "$lib_path" ] || lib_path="$CORE_PATH/target/$arch/$build_dir/libconstruct_core.a"
        if [ -f "$lib_path" ]; then
            lib_built=true
            break
        fi
    done
    
    if [ "$lib_built" = false ]; then
        print_error "Library not found! Please build the library first."
        exit 1
    fi
    
    # Need to run from CORE_PATH directory for cargo metadata to work
    cd "$CORE_PATH"
    
    # Generate bindings using LIBRARY MODE (not UDL mode)
    local lib_path=""
    for arch in "${ARCHITECTURES[@]}"; do
        local build_dir="release"
        if [ "$BUILD_TYPE" == "debug" ]; then
            build_dir="debug"
        fi
        local candidate="$PROJECT_ROOT/target/$arch/$build_dir/libconstruct_core.a"
        [ -f "$candidate" ] || candidate="$CORE_PATH/target/$arch/$build_dir/libconstruct_core.a"
        if [ -f "$candidate" ]; then
            lib_path="$candidate"
            break
        fi
    done

    print_info "Generating bindings with $bindgen_cmd in LIBRARY MODE..."
    print_info "Using library: $lib_path"
    $bindgen_cmd generate --library "$lib_path" \
        --language swift \
        --out-dir "$OUTPUT_DIR" || {
        print_error "Failed to generate bindings with $bindgen_cmd"
        print_error "Make sure:"
        print_error "  1. The library is built (cargo build completed successfully)"
        print_error "  2. uniffi-bindgen version matches uniffi version in Cargo.toml (0.30)"
        print_error "  3. Library path exists: $lib_path"
        exit 1
    }
    
    cd "$PROJECT_ROOT"

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

# Cleanup temporary directory
cleanup_temp() {
    if [ -d "$PROJECT_ROOT/.construct-core-temp" ] && [ "$CORE_PATH" == "$PROJECT_ROOT/.construct-core-temp" ]; then
        print_info "Cleaning up temporary construct-core clone..."
        rm -rf "$PROJECT_ROOT/.construct-core-temp"
    fi
}

# Main execution
main() {
    print_header "Swift Bindings Generator for Construct Messenger"

    # Find construct-core path (after functions are defined)
    CORE_PATH=$(find_construct_core)
    UDL_FILE="$CORE_PATH/src/construct_core.udl"

    print_info "Build type: $BUILD_TYPE"
    print_info "Targets: ${ARCHITECTURES[*]}"
    print_info "Construct-core path: $CORE_PATH"
    if [ "$FORCE_REBUILD" = true ]; then
        print_warning "Force rebuild enabled (will run cargo clean)"
    fi

    # Check dependencies
    check_dependencies

    # Force rebuild if requested (fixes checksum mismatch)
    if [ "$FORCE_REBUILD" = true ]; then
        force_rebuild
    fi

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

    # Copy library to project root if it exists
    copy_library_to_project_root

    # Create XCFramework if requested
    if [ "$CREATE_XCFRAMEWORK" = true ]; then
        create_xcframework
    fi

    # Cleanup temporary directory if we cloned it
    if [ "$CORE_PATH" == "$PROJECT_ROOT/.construct-core-temp" ]; then
        print_info "Cleaning up temporary construct-core clone..."
        rm -rf "$PROJECT_ROOT/.construct-core-temp"
    fi
    if [ "$CORE_PATH" == "$PROJECT_ROOT/.construct-core-temp" ]; then
        cleanup_temp
    fi

    # Final message
    echo ""
    print_success "✨ All done! Swift bindings are ready to use."
    echo ""
}

# Copy library to project root
copy_library_to_project_root() {
    print_header "Copying Library to Project Root"

    local build_dir="release"
    if [ "$BUILD_TYPE" == "debug" ]; then
        build_dir="debug"
    fi

    # Rust outputs to PROJECT_ROOT/target/ (via CARGO_TARGET_DIR or cargo config).
    # Fall back to CORE_PATH/target/ for setups without target-dir redirect.
    _lib_path() {
        local arch=$1
        local candidate="$PROJECT_ROOT/target/$arch/$build_dir/libconstruct_core.a"
        if [ -f "$candidate" ]; then
            echo "$candidate"
        else
            echo "$CORE_PATH/target/$arch/$build_dir/libconstruct_core.a"
        fi
    }

    # iOS device library
    local ios_lib
    ios_lib=$(_lib_path "aarch64-apple-ios")
    if [ -f "$ios_lib" ]; then
        cp "$ios_lib" "$PROJECT_ROOT/libconstruct_core.a"
        print_success "Copied iOS device library → libconstruct_core.a"
    fi

    # Mac Catalyst library — always named libconstruct_core_catalyst.a at project root
    local macabi_lib
    macabi_lib=$(_lib_path "aarch64-apple-ios-macabi")
    if [ -f "$macabi_lib" ]; then
        cp "$macabi_lib" "$PROJECT_ROOT/libconstruct_core_catalyst.a"
        print_success "Copied Mac Catalyst library → libconstruct_core_catalyst.a"
    fi

    # Fallback: if no device lib, copy the first non-macabi arch built
    if [ ! -f "$PROJECT_ROOT/libconstruct_core.a" ]; then
        local latest_lib=""
        local latest_time=0
        for arch in "${ARCHITECTURES[@]}"; do
            # macabi belongs in libconstruct_core_catalyst.a, never in libconstruct_core.a
            [[ "$arch" == *macabi* ]] && continue
            local lib_path
            lib_path=$(_lib_path "$arch")
            if [ -f "$lib_path" ]; then
                local lib_time
                lib_time=$(stat -f "%m" "$lib_path" 2>/dev/null || echo "0")
                if [ "$lib_time" -gt "$latest_time" ]; then
                    latest_time=$lib_time
                    latest_lib="$lib_path"
                fi
            fi
        done
        if [ -n "$latest_lib" ]; then
            cp "$latest_lib" "$PROJECT_ROOT/libconstruct_core.a"
            print_success "Copied fallback library → libconstruct_core.a (from $latest_lib)"
        else
            print_info "No iOS library built — skipping libconstruct_core.a"
        fi
    fi
}

# Create XCFramework bundling iOS device, simulator fat binary, and Mac Catalyst
create_xcframework() {
    print_header "Creating XCFramework"

    local build_dir="release"
    if [ "$BUILD_TYPE" == "debug" ]; then
        build_dir="debug"
    fi

    local xcfw_out="$PROJECT_ROOT/construct_core.xcframework"

    # Helper: resolve lib path — PROJECT_ROOT/target first, then CORE_PATH/target
    _xcfw_lib() {
        local arch=$1
        local p="$PROJECT_ROOT/target/$arch/$build_dir/libconstruct_core.a"
        [ -f "$p" ] || p="$CORE_PATH/target/$arch/$build_dir/libconstruct_core.a"
        echo "$p"
    }

    # Collect available slices
    local ios_lib;    ios_lib=$(_xcfw_lib "aarch64-apple-ios")
    local sim_arm64;  sim_arm64=$(_xcfw_lib "aarch64-apple-ios-sim")
    local sim_x86;    sim_x86=$(_xcfw_lib "x86_64-apple-ios")
    local macabi_lib; macabi_lib=$(_xcfw_lib "aarch64-apple-ios-macabi")
    local headers_dir="$PROJECT_ROOT/ConstructMessenger"

    # Build xcodebuild -create-xcframework args
    local xc_args=()

    # iOS device slice
    if [ -f "$ios_lib" ]; then
        xc_args+=(-library "$ios_lib" -headers "$headers_dir")
        print_info "Including iOS device slice"
    fi

    # iOS Simulator fat binary (arm64 + x86_64 merged with lipo)
    if [ -f "$sim_arm64" ] || [ -f "$sim_x86" ]; then
        local sim_fat="$PROJECT_ROOT/target/sim_fat/libconstruct_core.a"
        mkdir -p "$(dirname "$sim_fat")"
        local lipo_inputs=()
        [ -f "$sim_arm64" ] && lipo_inputs+=("$sim_arm64")
        [ -f "$sim_x86" ]   && lipo_inputs+=("$sim_x86")
        lipo "${lipo_inputs[@]}" -create -output "$sim_fat"
        xc_args+=(-library "$sim_fat" -headers "$headers_dir")
        print_info "Including iOS Simulator slice (fat: ${lipo_inputs[*]})"
    fi

    # Mac Catalyst slice
    if [ -f "$macabi_lib" ]; then
        xc_args+=(-library "$macabi_lib" -headers "$headers_dir")
        print_info "Including Mac Catalyst slice"
    fi

    if [ ${#xc_args[@]} -eq 0 ]; then
        print_warning "No library slices found — skipping XCFramework creation"
        return
    fi

    # Remove old xcframework
    rm -rf "$xcfw_out"

    xcodebuild -create-xcframework "${xc_args[@]}" -output "$xcfw_out"
    print_success "XCFramework created: $xcfw_out"
    print_info "Add construct_core.xcframework to your Xcode project to replace libconstruct_core.a"
}

# Run main function
main
