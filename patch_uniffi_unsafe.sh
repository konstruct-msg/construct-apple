#!/bin/bash

# Patch UniFFI generated code for Rust 1.82+ compatibility
# Replaces #[no_mangle] with #[unsafe(no_mangle)]

set -e

CORE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/packages/core"

echo "🔧 Patching UniFFI generated files for Rust 1.82+ compatibility..."

# Find all construct_core.uniffi.rs files in target directory
find "$CORE_PATH/target" -name "construct_core.uniffi.rs" 2>/dev/null | while read -r file; do
    if [ -f "$file" ]; then
        # Check if already patched
        if grep -q "#\[unsafe(no_mangle)\]" "$file"; then
            echo "✓ Already patched: $file"
        else
            # Patch the file
            sed -i '' 's/#\[no_mangle\]/#[unsafe(no_mangle)]/g' "$file"
            echo "✓ Patched: $file"
        fi
    fi
done

# Also patch in root target if exists
find "./target" -name "construct_core.uniffi.rs" 2>/dev/null | while read -r file; do
    if [ -f "$file" ]; then
        # Check if already patched
        if grep -q "#\[unsafe(no_mangle)\]" "$file"; then
            echo "✓ Already patched: $file"
        else
            # Patch the file
            sed -i '' 's/#\[no_mangle\]/#[unsafe(no_mangle)]/g' "$file"
            echo "✓ Patched: $file"
        fi
    fi
done

echo "✨ All UniFFI files patched successfully!"
