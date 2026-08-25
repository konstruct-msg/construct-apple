#!/usr/bin/env bash
#
# two_sims.sh — стенд из iOS-симуляторов для E2E-проверок мессенджера.
#
# Зачем: сценарии вида «A отправил → B получил» нельзя проверить на одном
# устройстве. Каждый симулятор — независимый контейнер (свой Keychain, свой
# Core Data, свой аккаунт), то есть полноценный участник разговора.
#
# Ролей три: a, b, c. Двух хватает на разговор двух аккаунтов, и это умолчание
# (SIMS=ab) — отсюда имя скрипта. Третья нужна ровно одному сценарию:
# многоустройственному. `link a b` делает из A и B ОДИН аккаунт, после чего
# собеседника у него не остаётся, а SENDER_SYNC отправляется только вслед за
# успешно ушедшим сообщением — то есть без третьего участника этот код просто
# не выполняется. Поэтому `SIMS=abc` и C в роли собеседника.
#
# Симуляторы создаются отдельные, с фиксированными именами (Construct-A/-B/-C),
# чтобы не мешать обычному дев-симулятору и чтобы `reset` можно было делать
# без страха стереть рабочее состояние.
#
# Использование:
#   ./scripts/two_sims.sh up         # создать + загрузить активные симуляторы
#   ./scripts/two_sims.sh build      # собрать .app один раз
#   ./scripts/two_sims.sh install    # поставить свежий .app на активные
#   ./scripts/two_sims.sh launch     # запустить на активных
#   ./scripts/two_sims.sh run        # up + build + install + launch
#   ./scripts/two_sims.sh pair a c   # два аккаунта: ссылка из буфера A → openurl на C
#   ./scripts/two_sims.sh link a b   # один аккаунт на двух устройствах: токен A → буфер B
#   ./scripts/two_sims.sh status     # UDID, состояние, установлен ли app
#   ./scripts/two_sims.sh env        # export-строки для MCP/других скриптов
#   ./scripts/two_sims.sh shot       # скриншоты активных
#   ./scripts/two_sims.sh logs a     # стрим лога приложения (a|b|c)
#   ./scripts/two_sims.sh reset      # стереть активные (чистый онбординг)
#   ./scripts/two_sims.sh down       # выключить активные
#
# Многоустройственный прогон целиком:
#   SIMS=abc ./scripts/two_sims.sh run
#   SIMS=abc ./scripts/two_sims.sh pair a c   # у аккаунта появляется собеседник
#   SIMS=abc ./scripts/two_sims.sh link a b   # A и B становятся одним аккаунтом
#
# Переопределяется через окружение: SIMS, SCHEME, CONFIGURATION, BUNDLE_ID,
# SIM_A_NAME, SIM_B_NAME, SIM_C_NAME, DEVICE_TYPE_A, DEVICE_TYPE_B, DEVICE_TYPE_C.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$PWD"

PROJECT="${PROJECT:-ConstructMessenger.xcodeproj}"
SCHEME="${SCHEME:-ConstructMessenger}"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUNDLE_ID="${BUNDLE_ID:-maximeliseyev.constructmessenger}"

# Разные модели специально: на скриншотах сразу видно, кто A, кто B, кто C.
SIM_A_NAME="${SIM_A_NAME:-Construct-A}"
SIM_B_NAME="${SIM_B_NAME:-Construct-B}"
SIM_C_NAME="${SIM_C_NAME:-Construct-C}"
DEVICE_TYPE_A="${DEVICE_TYPE_A:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
DEVICE_TYPE_B="${DEVICE_TYPE_B:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}"
DEVICE_TYPE_C="${DEVICE_TYPE_C:-com.apple.CoreSimulator.SimDeviceType.iPhone-17e}"

# Роли, которыми управляет этот вызов. Третий симулятор не поднимается по
# умолчанию: он нужен одному сценарию, а стоит загрузки и памяти на всех
# остальных.
SIMS="${SIMS:-ab}"

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

# Force a Latin keyboard. UI automation types HID key codes, which the simulator maps
# through its *active* input source: with a Russian layout "alice" arrives as "фдшсу"
# and the failure looks like a broken app, not a broken locale.
normalize_keyboard() {
  local udid="$1"
  xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array en-US 2>/dev/null || true
  xcrun simctl spawn "$udid" defaults write -g AppleLocale -string en_US 2>/dev/null || true
  xcrun simctl spawn "$udid" defaults write -g AppleKeyboards -array "en_US@sw=QWERTY" 2>/dev/null || true
}

boot_sim() {
  local udid="$1" name="$2"
  if [[ "$(state_for "$udid")" != "Booted" ]]; then
    normalize_keyboard "$udid"
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

# Роли этого вызова, по одной букве в строке, в порядке a→b→c и без повторов.
active_roles() {
  local raw; raw="$(printf '%s' "$SIMS" | tr '[:upper:]' '[:lower:]' | tr -cd 'abc')"
  [[ -n "$raw" ]] || die "SIMS не называет ни одной роли (ожидается подмножество abc): '$SIMS'"
  local r
  for r in a b c; do
    if [[ "$raw" == *"$r"* ]]; then printf '%s\n' "$r"; fi
  done
  # Явный успех: под `set -o pipefail` ненулевой код этой функции стал бы кодом
  # любого конвейера с ней, и `active_roles | grep -qx a` отвечал бы «нет» при
  # совпавшем grep — просто потому, что последняя проверка в цикле была про `c`.
  return 0
}

# Без конвейера намеренно. `active_roles | grep -qx b` отвечает «нет» при
# совпавшем grep: -q завершает grep на найденной строке, продюсер получает
# SIGPIPE (141), и `pipefail` делает этот код ответом всего конвейера. Ошибалась
# при этом ровно средняя роль — на первой и последней продюсер успевал
# закончить, — то есть проверка выглядела работающей на двух буквах из трёх.
role_active() {
  local r
  for r in $(active_roles); do
    [[ "$r" == "$1" ]] && return 0
  done
  return 1
}

role_name() {
  case "$1" in
    a) printf '%s' "$SIM_A_NAME" ;;
    b) printf '%s' "$SIM_B_NAME" ;;
    c) printf '%s' "$SIM_C_NAME" ;;
    *) die "неизвестная роль: $1" ;;
  esac
}

role_udid() {
  case "$1" in
    a) printf '%s' "$UDID_A" ;;
    b) printf '%s' "$UDID_B" ;;
    c) printf '%s' "$UDID_C" ;;
    *) die "неизвестная роль: $1" ;;
  esac
}

UDID_A="" ; UDID_B="" ; UDID_C=""

resolve_sims() {
  local r
  for r in $(active_roles); do
    case "$r" in
      a) UDID_A="$(ensure_sim "$SIM_A_NAME" "$DEVICE_TYPE_A")" ;;
      b) UDID_B="$(ensure_sim "$SIM_B_NAME" "$DEVICE_TYPE_B")" ;;
      c) UDID_C="$(ensure_sim "$SIM_C_NAME" "$DEVICE_TYPE_C")" ;;
    esac
  done
}

# Проверяет букву роли и кладёт её в ROLE. Опечатка иначе прочиталась бы как
# пустой UDID, а пустой UDID для simctl — это «текущее загруженное устройство»,
# то есть команда ушла бы не туда и отчиталась успехом.
#
# Через глобальную, а не через stdout: `die` внутри `$( )` завершает только
# подоболочку, вызывающий продолжает с пустой строкой и падает вторым, менее
# внятным сообщением.
ROLE=""
require_role() {
  ROLE="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$ROLE" in
    a|b|c) ;;
    *) die "укажи симулятор буквой: a, b или c (получено: '${1:-}')" ;;
  esac
  role_active "$ROLE" \
    || die "роль $ROLE не поднята в этом прогоне (SIMS=$SIMS) — запусти с SIMS=abc"
}

# Единственная другая активная роль — умолчание для `pair`/`link`, когда ролей
# ровно две. При трёх ролях умолчания нет: угадывать, кого с кем связывать,
# значит связать не тех и узнать об этом через полчаса прогона.
other_role() {
  local self="$1" r out=""
  for r in $(active_roles); do
    [[ "$r" == "$self" ]] && continue
    [[ -z "$out" ]] || return 1
    out="$r"
  done
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

sim_by_letter() { require_role "${1:-}"; role_udid "$ROLE"; }

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
  local r
  for r in $(active_roles); do
    boot_sim "$(role_udid "$r")" "$(role_name "$r")"
  done
  open -a Simulator
  warn "окна симуляторов Simulator.app раскладывает сам — разведи их один раз руками"
}

cmd_install() {
  resolve_sims
  local app
  app="$(app_path)"
  [[ -d "$app" ]] || die "нет собранного .app ($app) — сначала ./scripts/two_sims.sh build"
  local r
  for r in $(active_roles); do
    local udid name
    udid="$(role_udid "$r")" ; name="$(role_name "$r")"
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
  local r
  for r in $(active_roles); do
    local udid name
    udid="$(role_udid "$r")" ; name="$(role_name "$r")"
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
  local r
  for r in $(active_roles); do
    local udid name installed="—"
    udid="$(role_udid "$r")" ; name="$(role_name "$r")"
    if xcrun simctl get_app_container "$udid" "$BUNDLE_ID" >/dev/null 2>&1; then
      installed="установлен"
    fi
    printf '%-14s %-38s %-10s %s\n' "$name" "$udid" "$(state_for "$udid")" "$installed"
  done
}

cmd_env() {
  resolve_sims
  echo
  local r
  for r in $(active_roles); do
    echo "export UDID_$(printf '%s' "$r" | tr '[:lower:]' '[:upper:]')=$(role_udid "$r")   # $(role_name "$r")"
  done
  echo "export BUNDLE_ID=$BUNDLE_ID"
}

# Pair the two sims without a camera.
#
# The simulator has no camera, so the QR pairing path is undrivable. Settings ▸
# ПРИГЛАСИТЬ ▸ СКОПИРОВАТЬ ССЫЛКУ puts the same invite on the pasteboard, and
# `simctl pbpaste`
# reads it back out. The copied form is the HTTPS share link, which needs an
# apple-app-site-association fetch to open the app — a simulator will just hand it
# to Safari. The custom scheme carries the identical payload and always resolves,
# so rewrite the prefix rather than trusting universal links here.
cmd_pair() {
  resolve_sims
  local from to link payload
  require_role "${1:-a}" ; from="$ROLE"
  if [[ -n "${2:-}" ]]; then
    require_role "$2" ; to="$ROLE"
  else
    to="$(other_role "$from")" \
      || die "ролей больше двух — назови приёмника явно: pair $from <a|b|c>"
  fi
  [[ "$from" != "$to" ]] || die "источник и приёмник — одна и та же роль ($from)"
  info "приглашение: $(role_name "$from") → $(role_name "$to")"
  from="$(role_udid "$from")" ; to="$(role_udid "$to")"

  link="$(xcrun simctl pbpaste "$from" 2>/dev/null | tr -d '\n')"
  payload="${link#*invite=}"
  if [[ "$link" != *"invite="* || -z "$payload" ]]; then
    warn "в буфере не приглашение, а: ${link:0:60}"
    die "открой на источнике Settings ▸ ПРИГЛАСИТЬ ▸ СКОПИРОВАТЬ ССЫЛКУ и повтори"
  fi

  info "передаю приглашение (payload ${#payload} симв.)"
  xcrun simctl openurl "$to" "konstruct://add?invite=$payload"
  ok "приглашение открыто на втором симуляторе"
}

# Связать оба симулятора в ОДИН аккаунт (в отличие от `pair`, который делает из них
# двух собеседников).
#
# Это единственный способ проверить SENDER_SYNC: копия своего сообщения уходит на
# другое устройство того же аккаунта, а два симулятора по умолчанию — два разных
# аккаунта, то есть совсем другой сценарий.
#
# Камеры у симулятора нет, а `konstruct://link?token=…` намеренно НЕ обрабатывается
# как глубокая ссылка: `DeepLinkHandler` отдаёт всё, кроме veil-config, разбору
# контактных ссылок. Это не упущение — токен связывания подключает устройство к
# аккаунту, и делать это по нажатию на присланную ссылку небезопасно. Сканер такой
# префикс принимает (`QRScannerView.handleScannedCode`), поэтому путь без камеры —
# положить токен в буфер приёмника и нажать «вставить» в сканере.
#
# Токен берётся из лога DEBUG-сборки: на экране он есть только внутри QR-картинки.
cmd_link() {
  resolve_sims
  local from to from_udid to_udid token

  require_role "${1:-a}" ; from="$ROLE"
  if [[ -n "${2:-}" ]]; then
    require_role "$2" ; to="$ROLE"
  else
    to="$(other_role "$from")" \
      || die "ролей больше двух — назови привязываемого явно: link $from <a|b|c>"
  fi
  [[ "$from" != "$to" ]] || die "источник и приёмник — одна и та же роль ($from)"

  # Связав два симулятора в один аккаунт, стенд остаётся без собеседника, а
  # SENDER_SYNC уходит только вслед за успешно отправленным сообщением
  # (ChatSendCoordinator зовёт его после sendChunks). То есть на стенде из двух
  # ролей многоустройственный код не выполняется ни разу, и прогон выглядит как
  # «копия не пришла», хотя её никто и не отправлял.
  if [[ "$(active_roles | wc -l | tr -d ' ')" -lt 3 ]]; then
    warn "активны только роли: $(active_roles | tr '\n' ' ')"
    warn "после link у аккаунта не останется собеседника, и SENDER_SYNC не с чего будет отправить"
    warn "для многоустройственного прогона: SIMS=abc ./scripts/two_sims.sh run && SIMS=abc $0 pair $from c"
  fi

  info "связывание: $(role_name "$from") показывает код → $(role_name "$to") вставляет"
  from_udid="$(role_udid "$from")" ; to_udid="$(role_udid "$to")"

  local container log
  container="$(xcrun simctl get_app_container "$from_udid" "$BUNDLE_ID" data 2>/dev/null || true)"
  [[ -n "$container" ]] || die "приложение не установлено на источнике — сначала ./scripts/two_sims.sh run"
  log="$container/Documents/Logs/current.log"
  [[ -f "$log" ]] || die "нет лога $log — запусти приложение на источнике"

  # Последний сгенерированный токен: экран можно открывать несколько раз, годится свежий.
  token="$(grep -o 'konstruct://link?token=[A-Za-z0-9._~+/=-]*' "$log" | tail -1 || true)"
  if [[ -z "$token" ]]; then
    warn "в логе источника нет токена связывания"
    die "открой на нём Настройки ▸ УСТРОЙСТВА ▸ показать QR и повтори"
  fi

  xcrun simctl pbcopy "$to_udid" <<< "$token"
  ok "токен (${#token} симв.) положен в буфер приёмника"
  info "на приёмнике: Настройки ▸ УСТРОЙСТВА ▸ привязать устройство ▸ вставить из буфера"
  info "идентификаторы: settings.devices → devices.linkNew → qrScanner.paste"
}

cmd_shot() {
  resolve_sims
  mkdir -p "$SHOT_DIR"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local r
  for r in $(active_roles); do
    local letter out
    letter="$(printf '%s' "$r" | tr '[:lower:]' '[:upper:]')"
    out="$SHOT_DIR/$stamp-$letter.png"
    xcrun simctl io "$(role_udid "$r")" screenshot "$out" >/dev/null 2>&1
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
  local r names=""
  for r in $(active_roles); do names="$names $(role_name "$r")"; done
  warn "стираю$names — аккаунты, ключи и переписка пропадут"
  for r in $(active_roles); do
    local udid; udid="$(role_udid "$r")"
    xcrun simctl shutdown "$udid" 2>/dev/null || true
    xcrun simctl erase "$udid"
  done
  ok "симуляторы чистые — следующий запуск начнётся с онбординга"
}

cmd_down() {
  resolve_sims
  local r
  for r in $(active_roles); do
    xcrun simctl shutdown "$(role_udid "$r")" 2>/dev/null || true
  done
  ok "симуляторы выключены"
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
  pair)    cmd_pair "${2:-a}" "${3:-}" ;;
  link)    cmd_link "${2:-a}" "${3:-}" ;;
  status)  cmd_status ;;
  env)     cmd_env ;;
  shot)    cmd_shot ;;
  logs)    cmd_logs "${2:-}" ;;
  reset)   cmd_reset ;;
  down)    cmd_down ;;
  ""|-h|--help|help) usage ;;
  *)       die "неизвестная команда: $1 (см. --help)" ;;
esac
