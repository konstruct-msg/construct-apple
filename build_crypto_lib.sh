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
DO_CLEAN=false

for arg in "$@"; do
  case "$arg" in
    --ios)   BUILD_CAT=false ;;
    --cat)   BUILD_IOS=false ;;
    --clean) DO_CLEAN=true ;;
    --debug) BUILD_DIR="debug"; CARGO_FLAGS="" ;;
    -h|--help)
      echo "Использование: $0 [--ios] [--cat] [--clean] [--debug]"
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

$BUILD_IOS && build_target "aarch64-apple-ios"
$BUILD_CAT && build_target "aarch64-apple-ios-macabi"

# ── Мёрдж + копирование ───────────────────────────────────────────────────────
hdr "Мёрдж ICE и копирование"

$BUILD_IOS && merge_ice "aarch64-apple-ios"        "$PROJECT_ROOT/libconstruct_core.a"
$BUILD_CAT && merge_ice "aarch64-apple-ios-macabi"  "$PROJECT_ROOT/libconstruct_core_catalyst.a"

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

# ── Готово ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Готово! Следующие шаги в Xcode:${NC}"
echo "  1. ⌘⇧K  — Product → Clean Build Folder"
echo "  2. ⌘R   — Build & Run (iPhone через USB или Mac Catalyst)"
echo "  3. Settings → Diagnostics → Reset local data  (очистить Keychain)"
echo ""
