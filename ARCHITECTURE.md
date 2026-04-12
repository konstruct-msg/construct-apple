# Construct Messenger — архитектура (черновик)

Цель этого файла — быстро объяснить, **какие слои есть в iOS-клиенте**, где проходит граница ответственности,
и где искать/добавлять диагностику для проблемы “крипто-сессия теряет синхронизацию”.

## Слои и ответственность

### UI
- `ConstructMessenger/Views/` — SwiftUI экраны. Не содержат бизнес-логики кроме отображения/маршрутизации событий.
- `ConstructMessenger/ViewModels/` — `@Observable` модели состояния и UX-логика. Оркестрируют сервисы, но не делают крипто напрямую.

### Сервисы (бизнес-логика)
- `ConstructMessenger/Services/Messaging/MessageRouter.swift` — **единая точка входа для входящих сообщений**: дедуп, ACK, контрольные сообщения (END_SESSION/SESSION_RESET_INIT), построение `CfeIncomingEvent`, роутинг Rust-actions → Core Data / receipts / session-init.
- `ConstructMessenger/Services/Session/SessionCoordinator.swift` — **жизненный цикл сессии на уровне приложения**: prewarm, tie-break, resend loops, watchdogs, healing-политики, KEY_SYNC, управление очередями “первого сообщения”.
- `ConstructMessenger/Services/Crypto/SessionInitializationService.swift` — **инициализация INITIATOR-сессии**: fetch bundle (retry/backoff), проверка SPK epoch, вызов `CryptoManager.initializeSession`.
- `ConstructMessenger/Services/Calls/CallManager.swift` — вызовы/сигналинг; крипто-сигналы шифруются через orchestrator.

### Крипто и ключи
- `ConstructMessenger/Security/CryptoManager.swift` — Swift-обёртка над Rust `construct-core` (UniFFI):
  - хранение `OrchestratorCore`,
  - импорт/экспорт сессий (Keychain),
  - encrypt/decrypt (старый API) и `handleOrchestratorEvent` (M5 orchestrator path),
  - persistence `construct.orchestrator_state` (ACK cache/heal queue/таймеры).
- `ConstructMessenger/Utilities/KeychainManager.swift` (и рядом) — физическое хранение: device keys, session blobs, orchestrator state.

### Данные
- `ConstructMessenger/Persistence/` + Core Data модели — сообщения/чаты/юзеры.

### Сеть
- `ConstructMessenger/Networking/gRPC/` + `*ServiceClient` — gRPC к Construct (bundle fetch, message send, stream).

## Потоки крипто-сессии (коротко)

### Входящее сообщение
1) Stream → `SessionCoordinator.routeIncomingMessage` → `MessageRouter.routeIncomingMessage`.
2) `MessageRouter` делает дедуп/ACK-guard, разбирает control сообщения, затем строит `CfeIncomingEvent.messageReceived`.
3) `CryptoManager.handleOrchestratorEvent` → Rust orchestrator → список `CfeAction`.
4) `MessageRouter.executeRustActions` применяет `CfeAction`: сохранить сессию/ACK, сохранить сообщение, отправить receipt, запланировать таймер, принять решение о heal/END_SESSION и т.д.

### Исходящее сообщение
1) UI/ViewModel вызывает `MessageRouter.encryptOutgoing` (или `CryptoManager.encryptMessage` для старого пути).
2) Rust orchestrator выдаёт `sendEncryptedMessage` + `saveSessionToSecureStore`.
3) Swift сохраняет сессию/состояние orchestrator в Keychain.

## Где смотреть/добавлять логирование при “рассинхроне”

Ключевые категории:
- `SessionInit` — bundle fetch/init, tie-break, heals, END_SESSION.
- `MessageRouter` — контрольные сообщения, дедуп, storage actions.
- `CryptoOrchestrator` — вход/выход `handleOrchestratorEvent` (тип события + флаги действий).
- `CryptoManager` — encrypt/decrypt (старый путь), восстановление сессии/кора.

Практический минимум для отладки:
- фиксировать `contactId`, `messageId`, `msgNum`, `contentType`, роль (INITIATOR/RESPONDER) и причину reset/heal.
- отдельно ловить события, когда orchestrator вызывается **не с main thread** (это почти всегда “скрытая” причина дрейфа).

## Частые причины “сессия без причин ломается” (гипотезы)
- Параллельные вызовы Rust orchestrator из разных `Task`/потоков (таймеры, background, UI) → состояние DR расходится.
- “Старый” END_SESSION, повторно доставленный сервером, рвёт актуальную сессию (для этого есть `isEndSessionStale`).
- Частичный Keychain state после reboot/lock → `orchestratorCore` nil → ложные END_SESSION (нужно аккуратное восстановление).

## Рекомендованный порядок дальнейшей разборки
1) Собрать 1–2 лога-архива из `Diagnostics` в момент рассинхрона.
2) По логам найти, кто инициировал reset/heal (`MessageRouter`/`SessionCoordinator`/Rust action).
3) Если это Rust `sendEndSession/sessionHealNeeded` — сопоставить с последовательностью `msgNum` и наличием `saveSessionToSecureStore`.
4) Дальше уже решать: баг протокола/серверной очереди или гонка/порядок вызовов на iOS.

