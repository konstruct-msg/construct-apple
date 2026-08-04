#!/usr/bin/env bash
#
# two_sims.sh — стенд из двух iOS-симуляторов для E2E-проверок мессенджера.
#
# Зачем: сценарии вида «A отправил → B получил» нельзя проверить на одном
# устройстве. Два симулятора — это два независимых контейнера (свой Keychain,
# свой Core Data, свой аккаунт), то есть два полноценных участника разговора.
#
# Симуляторы создаются отдельные, с фиксированными именами (Construct-A/-B),
# чтобы не мешать обычному дев-симулятору и чтобы `reset` можно было делать
# без страха стереть рабочее состояние.
#
# Использование:
#   ./scripts/two_sims.sh up        # создать + загрузить оба симулятора
#   ./scripts/two_sims.sh build     # собрать .app один раз
#   ./scripts/two_sims.sh install   # поставить свежий .app на оба
#   ./scripts/two_sims.sh launch    # запустить на обоих
#   ./scripts/two_sims.sh run       # up + build + install + launch
#   ./scripts/two_sims.sh pair a    # связать: ссылка из буфера A → openurl на B
#   ./scripts/two_sims.sh status    # UDID, состояние, установлен ли app
#   ./scripts/two_sims.sh env       # export-строки для MCP/других скриптов
#   ./scripts/two_sims.sh shot      # скриншоты обоих
#   ./scripts/two_sims.sh logs a    # стрим лога приложения (a|b)
#   ./scripts/two_sims.sh reset     # стереть оба (чистый онбординг)
#   ./scripts/two_sims.sh down      # выключить оба
#
# Переопределяется через окружение: SCHEME, CONFIGURATION, BUNDLE_ID,
# SIM_A_NAME, SIM_B_NAME, DEVICE_TYPE_A, DEVICE_TYPE_B.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$PWD"

PROJECT="${PROJECT:-ConstructMessenger.xcodeproj}"
SCHEME="${SCHEME:-ConstructMessenger}"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUNDLE_ID="${BUNDLE_ID:-maximeliseyev.constructmessenger}"

# Разные модели специально: на скриншотах сразу видно, кто A, а кто B.
SIM_A_NAME="${SIM_A_NAME:-Construct-A}"
SIM_B_NAME="${SIM_B_NAME:-Construct-B}"
DEVICE_TYPE_A="${DEVICE_TYPE_A:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
DEVICE_TYPE_B="${DEVICE_TYPE_B:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}"

SHOT_DIR="${SHOT_DIR:-$REPO_ROOT/logs/two_sims}"

# ── вывод ────────────────────────────────────────────────────────────────────

info()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ── симуляторы ───────────────────────────────────────────────────────────────

# Самый свежий доступный iOS-рантайм. Не хардкодим версию: раннтаймы уезжают
# с каждым Xcode, а прибитая гвоздями 18.6 из AGENTS.md уже не существует.
latest_ios_runtime() {
  xcrun simctl list runtimes --json | python3 -c '
import json, sys
rts = [r for r in json.load(sys.stdin)["runtimes"]
       if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]
if not rts:
    sys.exit("нет доступных iOS-рантаймов — поставь их в Xcode ▸ Settings ▸ Components")
rts.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rts[-1]["identifier"])
'
}

udid_for() {
  local name="$1"
  xcrun simctl list devices --json | python3 -c '
import json, sys
name = sys.argv[1]
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == name and d.get("isAvailable"):
            print(d["udid"])
            sys.exit(0)
' "$name"
}

state_for() {
  local udid="$1"
  xcrun simctl list devices --json | python3 -c '
import json, sys
udid = sys.argv[1]
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["udid"] == udid:
            print(d["state"])
            sys.exit(0)
print("Unknown")
' "$udid"
}

ensure_sim() {
  local name="$1" device_type="$2" udid
  udid="$(udid_for "$name" || true)"
  if [[ -z "$udid" ]]; then
    info "создаю симулятор $name" >&2
    udid="$(xcrun simctl create "$name" "$device_type" "$(latest_ios_runtime)")"
  fi
  printf '%s' "$udid"
}

boot_sim() {
  local udid="$1" name="$2"
  if [[ "$(state_for "$udid")" != "Booted" ]]; then
    info "загружаю $name"
    xcrun simctl boot "$udid"
  fi
  xcrun simctl bootstatus "$udid" -b >/dev/null
  # Детерминированный статус-бар: иначе каждый скриншот отличается временем
  # и уровнем заряда, и визуальное сравнение шумит на пустом месте.
  xcrun simctl status_bar "$udid" override \
    --time "09:41" --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3 \
    2>/dev/null || true
  ok "$name готов ($udid)"
}

resolve_sims() {
  UDID_A="$(ensure_sim "$SIM_A_NAME" "$DEVICE_TYPE_A")"
  UDID_B="$(ensure_sim "$SIM_B_NAME" "$DEVICE_TYPE_B")"
}

sim_by_letter() {
  case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    a) printf '%s' "$UDID_A" ;;
    b) printf '%s' "$UDID_B" ;;
    *) die "укажи симулятор: a или b" ;;
  esac
}

# ── сборка ───────────────────────────────────────────────────────────────────

check_frameworks() {
  local missing=()
  [[ -d "$REPO_ROOT/ConstructCore.xcframework" ]]      || missing+=("ConstructCore.xcframework (./build_crypto_lib.sh --all)")
  [[ -d "$REPO_ROOT/ConstructTransport.xcframework" ]] || missing+=("ConstructTransport.xcframework (./build_transport_lib.sh)")
  if (( ${#missing[@]} )); then
    printf '%s\n' "${missing[@]}" >&2
    die "нет собранных Rust-фреймворков — Xcode не соберёт приложение"
  fi
}

# Путь к .app берём из самого xcodebuild, а не собираем строкой из
# DerivedData: схема содержит и app-таргет, и тесты, и путь зависит от
# конфигурации — угаданный путь молча разъедется при первом же изменении.
app_path() {
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -showBuildSettings -json 2>/dev/null | python3 -c '
import json, sys
for entry in json.load(sys.stdin):
    s = entry.get("buildSettings", {})
    product = s.get("FULL_PRODUCT_NAME", "")
    if product.endswith(".app"):
        print(s["BUILT_PRODUCTS_DIR"] + "/" + product)
        sys.exit(0)
sys.exit("не нашёл .app в build settings схемы")
'
}

cmd_build() {
  check_frameworks
  info "собираю $SCHEME ($CONFIGURATION) для симулятора"
  # Общая DerivedData Xcode осознанно: инкрементальная сборка переиспользует
  # артефакты Xcode и уже разрешённые SPM-пакеты вместо повторной резолюции.
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    build
  ok "собрано: $(app_path)"
}

# ── команды ──────────────────────────────────────────────────────────────────

cmd_up() {
  resolve_sims
  boot_sim "$UDID_A" "$SIM_A_NAME"
  boot_sim "$UDID_B" "$SIM_B_NAME"
  open -a Simulator
  warn "окна симуляторов Simulator.app раскладывает сам — разведи их один раз руками"
}

cmd_install() {
  resolve_sims
  local app
  app="$(app_path)"
  [[ -d "$app" ]] || die "нет собранного .app ($app) — сначала ./scripts/two_sims.sh build"
  for pair in "$UDID_A:$SIM_A_NAME" "$UDID_B:$SIM_B_NAME"; do
    local udid="${pair%%:*}" name="${pair##*:}"
    [[ "$(state_for "$udid")" == "Booted" ]] || die "$name не загружен — сначала ./scripts/two_sims.sh up"
    xcrun simctl install "$udid" "$app"
    # Микрофон/камера — чтобы звонковые сценарии не упирались в системный алерт,
    # который UI-автоматике придётся отдельно проходить на каждом прогоне.
    xcrun simctl privacy "$udid" grant microphone "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl privacy "$udid" grant camera "$BUNDLE_ID" 2>/dev/null || true
    ok "$name: установлен"
  done
}

cmd_launch() {
  resolve_sims
  for pair in "$UDID_A:$SIM_A_NAME" "$UDID_B:$SIM_B_NAME"; do
    local udid="${pair%%:*}" name="${pair##*:}"
    xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
    ok "$name: запущен"
  done
}

cmd_run() {
  cmd_up
  cmd_build
  cmd_install
  cmd_launch
  cmd_env
}

cmd_status() {
  resolve_sims
  printf '%-14s %-38s %-10s %s\n' "SIM" "UDID" "STATE" "APP"
  for pair in "$UDID_A:$SIM_A_NAME" "$UDID_B:$SIM_B_NAME"; do
    local udid="${pair%%:*}" name="${pair##*:}" installed="—"
    if xcrun simctl get_app_container "$udid" "$BUNDLE_ID" >/dev/null 2>&1; then
      installed="установлен"
    fi
    printf '%-14s %-38s %-10s %s\n' "$name" "$udid" "$(state_for "$udid")" "$installed"
  done
}

cmd_env() {
  resolve_sims
  echo
  echo "export UDID_A=$UDID_A   # $SIM_A_NAME"
  echo "export UDID_B=$UDID_B   # $SIM_B_NAME"
  echo "export BUNDLE_ID=$BUNDLE_ID"
}

# Pair the two sims without a camera.
#
# The simulator has no camera, so the QR pairing path is undrivable. Settings ▸
# COPY CONTACT LINK puts the same invite on the pasteboard, and `simctl pbpaste`
# reads it back out. The copied form is the HTTPS share link, which needs an
# apple-app-site-association fetch to open the app — a simulator will just hand it
# to Safari. The custom scheme carries the identical payload and always resolves,
# so rewrite the prefix rather than trusting universal links here.
cmd_pair() {
  resolve_sims
  local from="${1:-a}" to link payload
  case "$(echo "$from" | tr '[:upper:]' '[:lower:]')" in
    a) from="$UDID_A"; to="$UDID_B" ;;
    b) from="$UDID_B"; to="$UDID_A" ;;
    *) die "укажи источник ссылки: a или b" ;;
  esac

  link="$(xcrun simctl pbpaste "$from" 2>/dev/null | tr -d '\n')"
  payload="${link#*invite=}"
  if [[ "$link" != *"invite="* || -z "$payload" ]]; then
    warn "в буфере не приглашение, а: ${link:0:60}"
    die "открой на источнике Settings ▸ COPY CONTACT LINK и повтори"
  fi

  info "передаю приглашение (payload ${#payload} симв.)"
  xcrun simctl openurl "$to" "konstruct://add?invite=$payload"
  ok "приглашение открыто на втором симуляторе"
}

cmd_shot() {
  resolve_sims
  mkdir -p "$SHOT_DIR"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  for pair in "$UDID_A:A" "$UDID_B:B"; do
    local udid="${pair%%:*}" letter="${pair##*:}"
    local out="$SHOT_DIR/$stamp-$letter.png"
    xcrun simctl io "$udid" screenshot "$out" >/dev/null 2>&1
    ok "$out"
  done
}

cmd_logs() {
  resolve_sims
  local udid; udid="$(sim_by_letter "${1:-}")"
  info "лог приложения (Ctrl-C чтобы выйти)"
  xcrun simctl spawn "$udid" log stream \
    --style compact \
    --predicate "processImagePath CONTAINS[c] 'Construct Messenger'"
}

cmd_reset() {
  resolve_sims
  warn "стираю $SIM_A_NAME и $SIM_B_NAME — аккаунты, ключи и переписка пропадут"
  for udid in "$UDID_A" "$UDID_B"; do
    xcrun simctl shutdown "$udid" 2>/dev/null || true
    xcrun simctl erase "$udid"
  done
  ok "оба симулятора чистые — следующий запуск начнётся с онбординга"
}

cmd_down() {
  resolve_sims
  for udid in "$UDID_A" "$UDID_B"; do
    xcrun simctl shutdown "$udid" 2>/dev/null || true
  done
  ok "оба симулятора выключены"
}

usage() {
  awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
  up)      cmd_up ;;
  build)   cmd_build ;;
  install) cmd_install ;;
  launch)  cmd_launch ;;
  run)     cmd_run ;;
  pair)    cmd_pair "${2:-a}" ;;
  status)  cmd_status ;;
  env)     cmd_env ;;
  shot)    cmd_shot ;;
  logs)    cmd_logs "${2:-}" ;;
  reset)   cmd_reset ;;
  down)    cmd_down ;;
  ""|-h|--help|help) usage ;;
  *)       die "неизвестная команда: $1 (см. --help)" ;;
esac
