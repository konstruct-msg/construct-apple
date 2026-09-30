#!/usr/bin/env bash
#
# history_stand.sh — стенд переноса истории: телефон ↔ Mac, одна сборка с -DHISTORY_STAND.
#
# Перенос истории выключен в продукте (DeviceLinkHistorySyncPolicy.isPostLinkEnabled = false)
# до прогона этого стенда (DEVICE_LINK_HISTORY_TRANSFER_PLAN §8). Стендовая сборка включает его
# флагом компилятора, которого нет ни в одной конфигурации проекта — в том числе в Beta, которая
# держит DEBUG и уходит в TestFlight. Документация: docs/HISTORY_STAND.md.
#
# Использование:
#   ./scripts/history_stand.sh mac          # собрать Desktop, перезапустить, лог → logs/history_stand/mac.log
#   ./scripts/history_stand.sh phone        # собрать iOS, поставить на PHONE, запустить
#   ./scripts/history_stand.sh join         # ссылка из QR Mac (Flow B) → буфер симулятора
#   ./scripts/history_stand.sh logs         # забрать лог телефона, показать строки истории обеих сторон
#   ./scripts/history_stand.sh snapshots    # snapshot_id, которые видели обе стороны
#   ./scripts/history_stand.sh stop         # остановить Desktop
#
# PHONE — UDID физического iPhone (xcrun devicectl list devices) или sim:<имя|UDID>.
# По умолчанию sim:Construct-A: связывание стирает аккаунт нового устройства, и умолчание не
# должно указывать на чей-то телефон.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$PWD"

PROJECT="ConstructMessenger.xcodeproj"
PHONE="${PHONE:-sim:Construct-A}"
PHONE_BUNDLE="maximeliseyev.constructmessenger"
MAC_SCHEME="Construct Desktop"
MAC_APP_NAME="Construct Desktop"
OUT="$REPO_ROOT/logs/history_stand"
DD="$OUT/DerivedData"
STAND_FLAGS=(OTHER_SWIFT_FLAGS='$(inherited) -DHISTORY_STAND')

# Строки, по которым читается прогон: link, доверие, фазы, отказ.
PATTERN='history_|DeviceLink|NearbyTransfer'

info()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$OUT"

is_sim() { [[ "$PHONE" == sim:* ]]; }

sim_udid() {
  local name="${PHONE#sim:}"
  if [[ "$name" =~ ^[0-9A-F-]{36}$ ]]; then echo "$name"; return; fi
  xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == name:
            print(d["udid"]); sys.exit(0)
sys.exit("нет симулятора " + name)
' "$name"
}

# Путь к .app — из самого xcodebuild, а не строкой из DerivedData.
built_app() {
  local scheme="$1"; shift
  xcodebuild -project "$PROJECT" -scheme "$scheme" -configuration Debug -derivedDataPath "$DD" \
    "$@" "${STAND_FLAGS[@]}" -showBuildSettings -json 2>/dev/null | python3 -c '
import json, sys
for entry in json.load(sys.stdin):
    s = entry.get("buildSettings", {})
    if s.get("FULL_PRODUCT_NAME", "").endswith(".app"):
        print(s["BUILT_PRODUCTS_DIR"] + "/" + s["FULL_PRODUCT_NAME"]); sys.exit(0)
sys.exit("не нашёл .app")
'
}

build() {
  local scheme="$1"; shift
  info "сборка $scheme (-DHISTORY_STAND)"
  xcodebuild -project "$PROJECT" -scheme "$scheme" -configuration Debug -derivedDataPath "$DD" \
    -allowProvisioningUpdates "$@" "${STAND_FLAGS[@]}" build -quiet \
    || die "сборка $scheme упала"
}

cmd_stop() {
  pkill -x "$MAC_APP_NAME" 2>/dev/null && ok "Desktop остановлен" || true
}

cmd_mac() {
  build "$MAC_SCHEME" -destination 'platform=macOS'
  local app; app="$(built_app "$MAC_SCHEME" -destination 'platform=macOS')"
  cmd_stop
  # Файловый лог Desktop лежит в контейнере песочницы, куда терминал не пускает TCC. Поэтому
  # stderr процесса идёт в файл: OS_ACTIVITY_DT_MODE дублирует туда os_log, без <private>.
  # Через open, а не бинарником напрямую: запущенный из шелла, он не открывает ни одного окна.
  [[ -f "$OUT/mac.log" ]] && mv "$OUT/mac.log" "$OUT/mac.prev.log"
  : >"$OUT/mac.log"
  open -n "$app" --env OS_ACTIVITY_DT_MODE=YES --stdout "$OUT/mac.log" --stderr "$OUT/mac.log"
  ok "Desktop запущен, лог: $OUT/mac.log"
}

cmd_phone() {
  if is_sim; then
    local udid; udid="$(sim_udid)"
    xcrun simctl boot "$udid" 2>/dev/null || true
    build ConstructMessenger -destination "id=$udid"
    local app; app="$(built_app ConstructMessenger -destination "id=$udid")"
    xcrun simctl install "$udid" "$app"
    xcrun simctl launch --terminate-running-process "$udid" "$PHONE_BUNDLE" >/dev/null
    ok "запущено на симуляторе $udid"
  else
    build ConstructMessenger -destination "id=$PHONE"
    local app; app="$(built_app ConstructMessenger -destination "id=$PHONE")"
    xcrun devicectl device install app --device "$PHONE" "$app" >/dev/null
    xcrun devicectl device process launch --terminate-existing --device "$PHONE" "$PHONE_BUNDLE" >/dev/null
    ok "запущено на $PHONE"
  fi
}

pull_phone_log() {
  if is_sim; then
    local container; container="$(xcrun simctl get_app_container "$(sim_udid)" "$PHONE_BUNDLE" data)"
    cp "$container/Documents/Logs/current.log" "$OUT/phone.log"
  else
    xcrun devicectl device copy from --device "$PHONE" --domain-type appDataContainer \
      --domain-identifier "$PHONE_BUNDLE" --source Documents/Logs/current.log \
      --destination "$OUT/phone.log" >/dev/null
  fi
}

# Flow B: Mac показывает QR, телефон сканирует. У симулятора нет камеры, поэтому ссылка берётся
# из DEBUG-строки лога Mac (Log.info: debug-уровень os_log в stderr не выходит) и кладётся в буфер: дальше «Link New Device» → «вставить».
cmd_join() {
  local url
  url="$(grep -oE 'konstruct://link-to-me\?[^ ]+' "$OUT/mac.log" | tail -1)"
  [[ -n "$url" ]] || die "в логе Mac нет ссылки на связывание — открыт ли экран QR?"
  if is_sim; then
    printf '%s' "$url" | xcrun simctl pbcopy "$(sim_udid)"
    ok "ссылка в буфере симулятора: ${url:0:60}…"
  else
    echo "$url"
  fi
}

cmd_logs() {
  pull_phone_log || warn "лог телефона не забран"
  local side
  for side in phone mac; do
    printf '\n\033[1m── %s ──\033[0m\n' "$side"
    grep -E "$PATTERN" "$OUT/$side.log" 2>/dev/null | tail -n "${TAIL:-60}" || true
  done
}

cmd_snapshots() {
  pull_phone_log || warn "лог телефона не забран"
  local tags side
  for side in phone mac; do
    grep -oE 'snapshot=[0-9a-f]{8}' "$OUT/$side.log" 2>/dev/null | sort -u >"$OUT/$side.snapshots" || true
  done
  tags="$(comm -12 "$OUT/phone.snapshots" "$OUT/mac.snapshots")"
  if [[ -z "$tags" ]]; then
    warn "нет snapshot_id, который видели бы обе стороны"
  else
    ok "обе стороны:"; echo "$tags"
  fi
}

case "${1:-}" in
  mac)        cmd_mac ;;
  phone)      cmd_phone ;;
  join)       cmd_join ;;
  logs)       cmd_logs ;;
  snapshots)  cmd_snapshots ;;
  stop)       cmd_stop ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
