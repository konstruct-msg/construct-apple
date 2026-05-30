#!/bin/bash
# build_crypto_lib.sh
# Собирает Rust-библиотеку construct-core для iOS и Mac Catalyst,
# мёрджит VEIL-символы и копирует .a файлы в корень проекта.
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
# Build-target flags accumulate (multiple may be combined in one invocation).
# When no build-target flag is passed, the default is iOS device only.
BUILD_IOS=false
BUILD_MAC=false
BUILD_SIM=false
BUILD_DIST=false
DO_CLEAN=false
ANY_TARGET_FLAG=false

for arg in "$@"; do
  case "$arg" in
    --ios)   BUILD_IOS=true;  ANY_TARGET_FLAG=true ;;
    --mac)   BUILD_MAC=true;  ANY_TARGET_FLAG=true ;;
    --sim)   BUILD_SIM=true;  ANY_TARGET_FLAG=true ;;
    --dist)  BUILD_DIST=true; BUILD_MAC=true; ANY_TARGET_FLAG=true ;;  # dist implies mac (adds x86_64)
    --all)   BUILD_IOS=true;  BUILD_MAC=true; BUILD_SIM=true; ANY_TARGET_FLAG=true ;;
    --clean) DO_CLEAN=true ;;
    --debug) BUILD_DIR="debug"; CARGO_FLAGS="" ;;
    -h|--help)
      echo "Использование: $0 [--ios] [--mac] [--sim] [--all] [--dist] [--clean] [--debug]"
      echo "  (без флагов)  iOS device (по умолчанию)"
      echo "  --ios         iOS device (aarch64-apple-ios)"
      echo "  --sim         iOS Симулятор (aarch64-apple-ios-sim + x86_64 fat)"
      echo "  --mac         Нативный macOS arm64 → libconstruct_core_mac.a"
      echo "  --all         Все три таргета (--ios --sim --mac) одним запуском"
      echo "  --dist        Universal macOS fat binary (arm64 + x86_64) для DMG/дистрибуции"
      echo ""
      echo "Флаги таргетов комбинируются: $0 --ios --sim соберёт iOS + Симулятор."
      exit 0 ;;
    *) warn "Неизвестный аргумент: $arg" ;;
  esac
done

# Default to iOS-only when no target flag was passed.
if ! $ANY_TARGET_FLAG; then
  BUILD_IOS=true
fi

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
  touch src/crypto/handshake/x3dh.rs
  local deploy_env=""
  case "$arch" in
    aarch64-apple-ios)          deploy_env="IPHONEOS_DEPLOYMENT_TARGET=18.0" ;;
    aarch64-apple-ios-sim|x86_64-apple-ios) deploy_env="IPHONEOS_DEPLOYMENT_TARGET=18.0" ;;
    aarch64-apple-darwin)       deploy_env="MACOSX_DEPLOYMENT_TARGET=15.0" ;;
  esac
  env $deploy_env cargo build --lib --target "$arch" --features "$FEATURES" $CARGO_FLAGS 2>&1 \
    | grep -E "^error|^warning\[|Compiling|Finished" || true
  ok "Собрано: $arch"
}

# ── Функция: мёрдж VEIL-символов ─────────────────────────────────────────────
merge_veil() {
  local arch="$1"
  local dest="$2"
  local core_lib="$CORE_PATH/target/$arch/$BUILD_DIR/libconstruct_core.a"

  [ -f "$core_lib" ] || fail "libconstruct_core.a не найден: $core_lib"

  # Ищем libconstruct_veil*.a в deps/ — берём самый новый (последний build)
  local veil_lib
  veil_lib=$(find "$CORE_PATH/target/$arch/$BUILD_DIR/deps" \
            -name "libconstruct_veil*.a" 2>/dev/null | xargs ls -t 2>/dev/null | head -1)

  if [ -n "$veil_lib" ] && [ -f "$veil_lib" ]; then
    libtool -static -o "$dest" "$core_lib" "$veil_lib"
    info "Смёрджено с VEIL: $(basename "$veil_lib")"
  else
    cp "$core_lib" "$dest"
    warn "VEIL-библиотека не найдена для $arch — VEIL-прокси символы отсутствуют"
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
$BUILD_MAC && build_target "aarch64-apple-darwin"
if $BUILD_DIST; then
  # Intel Mac (Rosetta / distribution universal binary)
  if ! rustup target list --installed 2>/dev/null | grep -q "x86_64-apple-darwin"; then
    info "Добавление цели x86_64-apple-darwin…"
    rustup target add x86_64-apple-darwin
  fi
  build_target "x86_64-apple-darwin"
fi
if $BUILD_SIM; then
  build_target "aarch64-apple-ios-sim"
  # x86_64 simulator needed for generic/platform=iOS Simulator builds on Intel and CI
  if ! rustup target list --installed 2>/dev/null | grep -q "x86_64-apple-ios"; then
    info "Добавление цели x86_64-apple-ios…"
    rustup target add x86_64-apple-ios
  fi
  build_target "x86_64-apple-ios"
fi

# ── Мёрдж + копирование ───────────────────────────────────────────────────────
hdr "Мёрдж VEIL и копирование"

$BUILD_IOS && merge_veil "aarch64-apple-ios"        "$PROJECT_ROOT/libconstruct_core.a"
if $BUILD_DIST; then
  # Universal fat binary: arm64 + x86_64 (for DMG / distribution)
  TMPDIR_DIST="/tmp/construct_mac_dist"
  mkdir -p "$TMPDIR_DIST"
  merge_veil "aarch64-apple-darwin"  "$TMPDIR_DIST/libconstruct_core_arm64.a"
  merge_veil "x86_64-apple-darwin"   "$TMPDIR_DIST/libconstruct_core_x86_64.a"
  lipo -create "$TMPDIR_DIST/libconstruct_core_arm64.a" "$TMPDIR_DIST/libconstruct_core_x86_64.a" \
       -output "$PROJECT_ROOT/libconstruct_core_mac.a"
  ok "Universal macOS fat binary (arm64 + x86_64) → libconstruct_core_mac.a"
elif $BUILD_MAC; then
  merge_veil "aarch64-apple-darwin"  "$PROJECT_ROOT/libconstruct_core_mac.a"
fi
if $BUILD_SIM; then
  # Fat simulator binary: arm64 (Apple Silicon sim) + x86_64 (Intel sim)
  TMPDIR_SIM="/tmp/construct_sim"
  mkdir -p "$TMPDIR_SIM"
  merge_veil "aarch64-apple-ios-sim" "$TMPDIR_SIM/libconstruct_core_arm64.a"
  merge_veil "x86_64-apple-ios"      "$TMPDIR_SIM/libconstruct_core_x86_64.a"
  lipo -create "$TMPDIR_SIM/libconstruct_core_arm64.a" "$TMPDIR_SIM/libconstruct_core_x86_64.a" \
       -output "$PROJECT_ROOT/libconstruct_core_sim.a"
  ok "Universal simulator fat binary (arm64 + x86_64) → libconstruct_core_sim.a"
fi

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
( $BUILD_MAC || $BUILD_DIST ) && check_prologue "$PROJECT_ROOT/libconstruct_core_mac.a" "macOS"
if $BUILD_SIM; then
  check_prologue "$PROJECT_ROOT/libconstruct_core_sim.a" "Simulator (arm64)"
  ok "Simulator fat binary: $(lipo -info $PROJECT_ROOT/libconstruct_core_sim.a 2>/dev/null | sed 's/.*are: //')"
fi

# ── Обновление ConstructCore.xcframework ─────────────────────────────────────
# Slice paths are read from Info.plist's LibraryIdentifier + LibraryPath. Hard-coded
# here because the xcframework layout is stable; if you change it, also update
# Info.plist + delete/recreate the slice folder. The cp calls deliberately run
# without `&&` so set -e + pipefail surface any failure instead of silently dropping.
XCFW="$PROJECT_ROOT/ConstructCore.xcframework"
if [ -d "$XCFW" ]; then
  hdr "Обновление xcframework"
  if $BUILD_IOS; then
    cp "$PROJECT_ROOT/libconstruct_core.a"     "$XCFW/ios-arm64/libconstruct_core.a"
    ok "ios-arm64 → xcframework"
  fi
  if $BUILD_MAC || $BUILD_DIST; then
    cp "$PROJECT_ROOT/libconstruct_core_mac.a" "$XCFW/macos-arm64/libconstruct_core_mac.a"
    ok "macos-arm64 → xcframework"
  fi
  if $BUILD_SIM; then
    cp "$PROJECT_ROOT/libconstruct_core_sim.a" "$XCFW/ios-arm64_x86_64-simulator/libconstruct_core_sim.a"
    ok "ios-arm64_x86_64-simulator → xcframework (arm64 + x86_64 fat)"
  fi
fi

# ── Готово ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Готово! Следующие шаги в Xcode:${NC}"
echo "  1. ⌘⇧K  — Product → Clean Build Folder"
echo "  2. ⌘R   — Build & Run (iPhone через USB или Mac Catalyst)"
echo "  3. Settings → Diagnostics → Reset local data  (очистить Keychain)"
echo ""
