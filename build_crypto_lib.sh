#!/bin/bash
# build_crypto_lib.sh
# Собирает Rust-библиотеку construct-core для iOS и Mac Catalyst,
# мёрджит ICE-символы и копирует .a файлы в корень проекта.
#
# ИСПОЛЬЗОВАНИЕ:
#   ./build_crypto_lib.sh          # iOS + Catalyst (по умолчанию)
#   ./build_crypto_lib.sh --ios    # только iOS device
#   ./build_crypto_lib.sh --cat    # только Mac Catalyst
#   ./build_crypto_lib.sh --clean  # cargo clean перед сборкой

set -e
set -o pipefail

# ── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✅${NC} $1"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
info() { echo -e "${BLUE}▸${NC} $1"; }
warn() { echo -e "${YELLOW}⚠️${NC}  $1"; }
hdr()  { echo -e "\n${BOLD}━━━  $1  ━━━${NC}"; }

# ── Пути ─────────────────────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_PATH="$HOME/Code/construct-core"

[ -d "$CORE_PATH" ] || \
  CORE_PATH="$PROJECT_ROOT/../construct-core"
[ -d "$CORE_PATH" ] || \
  fail "construct-core не найден. Ожидается ~/Code/construct-core или ../construct-core"

FEATURES="ios,post-quantum"
BUILD_DIR="release"
CARGO_FLAGS="--release"

# ── Аргументы ────────────────────────────────────────────────────────────────
BUILD_IOS=true
BUILD_CAT=true
BUILD_MAC=false
BUILD_SIM=false
DO_CLEAN=false

for arg in "$@"; do
  case "$arg" in
    --ios)   BUILD_CAT=false; BUILD_MAC=false; BUILD_SIM=false ;;
    --cat)   BUILD_IOS=false; BUILD_MAC=false; BUILD_SIM=false ;;
    --mac)   BUILD_IOS=false; BUILD_CAT=false; BUILD_MAC=true; BUILD_SIM=false ;;
    --sim)   BUILD_IOS=false; BUILD_CAT=false; BUILD_MAC=false; BUILD_SIM=true ;;
    --clean) DO_CLEAN=true ;;
    --debug) BUILD_DIR="debug"; CARGO_FLAGS="" ;;
    -h|--help)
      echo "Использование: $0 [--ios] [--cat] [--mac] [--sim] [--clean] [--debug]"
      echo "  --mac  Нативный macOS (aarch64-apple-darwin) → libconstruct_core_mac.a"
      echo "  --sim  iOS Симулятор (aarch64-apple-ios-sim) → target/aarch64-apple-ios-sim/libconstruct_core.a"
      exit 0 ;;
    *) warn "Неизвестный аргумент: $arg" ;;
  esac
done

# ── Проверка зависимостей ─────────────────────────────────────────────────────
hdr "Проверка зависимостей"
command -v cargo   &>/dev/null || fail "cargo не установлен (https://rustup.rs)"
command -v libtool &>/dev/null || fail "libtool не найден (должен быть в Xcode Command Line Tools)"
ok "cargo $(cargo --version | cut -d' ' -f2), libtool найден"

# ── cargo clean (опционально) ─────────────────────────────────────────────────
if $DO_CLEAN; then
  hdr "Cargo clean"
  cd "$CORE_PATH"
  cargo clean
  ok "Кеш очищен"
fi

# ── Функция: сборка одного таргета ───────────────────────────────────────────
build_target() {
  local arch="$1"
  info "Сборка для $arch ($BUILD_DIR)…"
  cd "$CORE_PATH"
  # touch x3dh.rs чтобы гарантировать пересборку при повторном запуске
  touch src/crypto/handshake/x3dh.rs
  cargo build --lib --target "$arch" --features "$FEATURES" $CARGO_FLAGS 2>&1 \
    | grep -E "^error|^warning\[|Compiling|Finished" || true
  ok "Собрано: $arch"
}

# ── Функция: мёрдж ICE-символов ──────────────────────────────────────────────
merge_ice() {
  local arch="$1"
  local dest="$2"
  local core_lib="$CORE_PATH/target/$arch/$BUILD_DIR/libconstruct_core.a"

  [ -f "$core_lib" ] || fail "libconstruct_core.a не найден: $core_lib"

  # Ищем libconstruct_ice*.a в deps/
  local ice_lib
  ice_lib=$(find "$CORE_PATH/target/$arch/$BUILD_DIR/deps" \
            -name "libconstruct_ice*.a" 2>/dev/null | head -1)

  if [ -n "$ice_lib" ] && [ -f "$ice_lib" ]; then
    libtool -static -o "$dest" "$core_lib" "$ice_lib"
    info "Смёрджено с ICE: $(basename "$ice_lib")"
  else
    cp "$core_lib" "$dest"
    warn "ICE-библиотека не найдена для $arch — ICE-прокси символы отсутствуют"
  fi

  local size
  size=$(du -sh "$dest" | cut -f1)
  ok "$(basename "$dest")  →  $size"
}

# ── Сборка ────────────────────────────────────────────────────────────────────
hdr "Сборка библиотек"

if $BUILD_MAC; then
  # macOS native uses "mac" feature instead of "ios"
  FEATURES="mac,post-quantum"
fi

$BUILD_IOS && build_target "aarch64-apple-ios"
$BUILD_CAT && build_target "aarch64-apple-ios-macabi"
$BUILD_MAC && build_target "aarch64-apple-darwin"
$BUILD_SIM && build_target "aarch64-apple-ios-sim"

# ── Мёрдж + копирование ───────────────────────────────────────────────────────
hdr "Мёрдж ICE и копирование"

$BUILD_IOS && merge_ice "aarch64-apple-ios"        "$PROJECT_ROOT/libconstruct_core.a"
$BUILD_CAT && merge_ice "aarch64-apple-ios-macabi"  "$PROJECT_ROOT/libconstruct_core_catalyst.a"
$BUILD_MAC && merge_ice "aarch64-apple-darwin"      "$PROJECT_ROOT/libconstruct_core_mac.a"
$BUILD_SIM && merge_ice "aarch64-apple-ios-sim"     "$PROJECT_ROOT/libconstruct_core_sim.a"

# ── Верификация пролога ───────────────────────────────────────────────────────
hdr "Верификация"
check_prologue() {
  local file="$1"
  local label="$2"
  # grep -a: читать бинарник как текст; -q: тихий режим
  if grep -qa "KonstruktX3DH-v1" "$file" 2>/dev/null; then
    ok "$label: пролог KonstruktX3DH-v1 ✓"
  else
    fail "$label: строка KonstruktX3DH-v1 НЕ НАЙДЕНА в бинарнике!"
  fi
}

$BUILD_IOS && check_prologue "$PROJECT_ROOT/libconstruct_core.a"          "iOS"
$BUILD_CAT && check_prologue "$PROJECT_ROOT/libconstruct_core_catalyst.a" "Catalyst"
$BUILD_MAC && check_prologue "$PROJECT_ROOT/libconstruct_core_mac.a"      "macOS"
$BUILD_SIM && check_prologue "$PROJECT_ROOT/libconstruct_core_sim.a"      "Simulator"

# ── Обновление ConstructCore.xcframework ─────────────────────────────────────
XCFW="$PROJECT_ROOT/ConstructCore.xcframework"
if [ -d "$XCFW" ]; then
  hdr "Обновление xcframework"
  $BUILD_IOS && cp "$PROJECT_ROOT/libconstruct_core.a"          "$XCFW/ios-arm64/libconstruct_core.a"          && ok "ios-arm64 → xcframework"
  $BUILD_CAT && cp "$PROJECT_ROOT/libconstruct_core_catalyst.a" "$XCFW/ios-arm64-maccatalyst/libconstruct_core_catalyst.a" && ok "ios-arm64-maccatalyst → xcframework"
  $BUILD_MAC && cp "$PROJECT_ROOT/libconstruct_core_mac.a"      "$XCFW/macos-arm64/libconstruct_core_mac.a"    && ok "macos-arm64 → xcframework"
  if $BUILD_SIM; then
    XCFW_SIM="$XCFW/ios-arm64-simulator/libconstruct_core.a"
    ICE_SIM=$(find "$CORE_PATH/target/aarch64-apple-ios-sim/release/deps" -name "libconstruct_ice-*.a" 2>/dev/null | head -1)
    RUST_SIM="$CORE_PATH/target/aarch64-apple-ios-sim/release/libconstruct_core.a"
    if [ -n "$ICE_SIM" ] && [ -f "$RUST_SIM" ]; then
      libtool -static -o "$XCFW_SIM" "$RUST_SIM" "$ICE_SIM" && ok "ios-arm64-simulator → xcframework (ICE merged)"
    else
      cp "$PROJECT_ROOT/libconstruct_core_sim.a" "$XCFW_SIM" && ok "ios-arm64-simulator → xcframework"
    fi
  fi
fi

# ── Готово ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Готово! Следующие шаги в Xcode:${NC}"
echo "  1. ⌘⇧K  — Product → Clean Build Folder"
echo "  2. ⌘R   — Build & Run (iPhone через USB или Mac Catalyst)"
echo "  3. Settings → Diagnostics → Reset local data  (очистить Keychain)"
echo ""
