# Contact Link Format - Security & Best Practices

## Текущая реализация

**Формат:** `construct://add-contact?id=USER_ID&username=USERNAME`

**Пример:**
```
construct://add-contact?id=550e8400-e29b-41d4-a716-446655440000&username=alice
```

## Анализ существующих решений

### 1. Telegram
```
Custom scheme: tg://resolve?domain=username
Universal Link: https://t.me/username
```
✅ Использует оба подхода
✅ HTTPS версия работает везде

### 2. WhatsApp
```
Custom scheme: whatsapp://send?phone=1234567890
Universal Link: https://wa.me/1234567890
```
✅ HTTPS предпочтительнее
✅ Простой формат

### 3. Signal
```
Universal Link: https://signal.me/#p/+1234567890
```
✅ Только HTTPS (безопаснее)
✅ Hash-based routing

### 4. Discord
```
Custom scheme: discord://invite/CODE
Universal Link: https://discord.gg/CODE
```
✅ Короткие коды вместо ID

### 5. Matrix
```
Custom scheme: matrix:u/@user:server.com
Universal Link: https://matrix.to/#/@user:server.com
```
✅ Федеративный формат
✅ URL encoding для специальных символов

## Проблемы текущего формата

### 🔴 Критичные

1. **Отсутствие Universal Links**
   - Custom scheme `construct://` не работает без установленного приложения
   - Не работает в браузерах, email, соцсетях
   - Нет fallback для неустановленного приложения

2. **Безопасность**
   - ❌ Нет подписи/верификации → возможна подделка ссылок
   - ❌ Нет защиты от replay attacks
   - ❌ Любой может создать ссылку с произвольным user_id

3. **Нет версионирования**
   - Если формат изменится, старые ссылки сломаются
   - Нет способа определить версию протокола

### 🟡 Средние

4. **URL Encoding**
   - Username может содержать специальные символы
   - Нужно корректное кодирование параметров

5. **Длина ссылки**
   - UUID делает ссылку очень длинной
   - Неудобно для QR-кодов и ручного ввода

### 🟢 Косметические

6. **SEO и превью**
   - Custom scheme не поддерживает Open Graph
   - Нельзя показать превью в Telegram/WhatsApp при шеринге

## Рекомендуемое решение

### Option A: Dual Format (рекомендуется)

**Primary: Universal Links (HTTPS)**
```
https://construct.chat/add?id=USER_ID&username=USERNAME&v=1
```

**Fallback: Custom Scheme**
```
construct://add-contact?id=USER_ID&username=USERNAME&v=1
```

**Преимущества:**
- ✅ Работает везде (iOS, Android, Web)
- ✅ Если приложение не установлено → веб-страница с инструкциями
- ✅ HTTPS обеспечивает базовую безопасность
- ✅ Можно добавить server-side валидацию
- ✅ SEO-friendly, поддержка превью

**Реализация на iOS:**
1. Настроить Associated Domains в Xcode
2. Создать `.well-known/apple-app-site-association` на сервере
3. Обработка через `onOpenURL` и `onContinueUserActivity`

**Пример конфига:**
```json
{
  "applinks": {
    "apps": [],
    "details": [{
      "appID": "TEAM_ID.com.construct.messenger",
      "paths": ["/add", "/u/*"]
    }]
  }
}
```

### Option B: Short Codes (для будущего)

**Формат:**
```
https://construct.chat/c/ABC123
construct://c/ABC123
```

**Преимущества:**
- ✅ Короче для QR-кодов
- ✅ Легче делиться вручную
- ✅ Можно отслеживать использование
- ✅ Можно отзывать (revoke) коды

**Недостатки:**
- ❌ Требует server-side хранилище кодов
- ❌ Дополнительная сложность

## Безопасность: Signed Links

Для предотвращения подделки добавить подпись:

### Формат с подписью
```
https://construct.chat/add?id=USER_ID&username=USERNAME&ts=TIMESTAMP&sig=SIGNATURE
```

**Где:**
- `ts` - Unix timestamp создания ссылки
- `sig` - HMAC-SHA256(id + username + ts, server_secret)

**Алгоритм валидации:**
1. Проверить, что `ts` не старше 24 часов (опционально)
2. Вычислить ожидаемую подпись
3. Сравнить с `sig` в constant-time

**Пример генерации (Swift):**
```swift
import CryptoKit

func generateContactLink(userId: String, username: String) -> String {
    let timestamp = Int(Date().timeIntervalSince1970)
    let payload = "\(userId)|\(username)|\(timestamp)"

    let key = SymmetricKey(data: serverSecret)
    let signature = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
    let sigHex = signature.map { String(format: "%02x", $0) }.joined()

    return "https://construct.chat/add?id=\(userId)&username=\(username)&ts=\(timestamp)&sig=\(sigHex)"
}
```

**⚠️ Проблема:** Требует shared secret между клиентом и сервером
- Если секрет в клиенте → можно извлечь из APK/IPA
- Решение: генерировать подписанные ссылки на сервере

## Рекомендуемая реализация (MVP)

### Phase 1: Universal Links без подписи

**Client-side:**
```
https://construct.chat/add?id=USER_ID&username=USERNAME&v=1
construct://add-contact?id=USER_ID&username=USERNAME&v=1
```

**Генерация (Swift):**
```swift
func generateContactLink(userId: String, username: String) -> String {
    let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username

    // Primary: HTTPS
    let httpsLink = "https://construct.chat/add?id=\(userId)&username=\(encodedUsername)&v=1"

    // Fallback: Custom scheme (для старых клиентов)
    // let customLink = "construct://add-contact?id=\(userId)&username=\(encodedUsername)&v=1"

    return httpsLink
}
```

**Обработка (Swift):**
```swift
.onOpenURL { url in
    handleContactLink(url)
}
.onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
    if let url = activity.webpageURL {
        handleContactLink(url)
    }
}

func handleContactLink(_ url: URL) {
    // Support both schemes
    guard url.scheme == "construct" || url.scheme == "https" else { return }

    // Parse path
    let path = url.host ?? url.path
    guard path.contains("add-contact") || path.contains("add") else { return }

    // Extract parameters
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
          let queryItems = components.queryItems else { return }

    let params = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })

    guard let userId = params["id"],
          let username = params["username"] else { return }

    // Optional: Check version
    if let version = params["v"], version != "1" {
        print("⚠️ Unknown link version: \(version)")
    }

    // Add contact
    addContact(userId: userId, username: username)
}
```

### Phase 2: Server-side signed links (будущее)

**Flow:**
1. Client запрашивает у сервера подписанную ссылку
2. Server генерирует короткий код или подписанную ссылку
3. Server сохраняет mapping (optional для коротких кодов)
4. Client получает безопасную ссылку для шаринга

## Миграция

### Шаг 1: Добавить поддержку HTTPS
- Обработка `https://construct.chat/add?...`
- Backward compatibility с `construct://`

### Шаг 2: Настроить Universal Links
- Зарегистрировать домен
- Создать `.well-known/apple-app-site-association`
- Протестировать с testflight

### Шаг 3: Обновить UI
- Использовать HTTPS ссылки по умолчанию
- Оставить custom scheme для старых версий

### Шаг 4: Добавить подписи (опционально)
- Server-side endpoint для генерации
- Client-side валидация

## Альтернативные подходы

### 1. QR-code only (без ссылок)
- QR содержит зашифрованные данные
- Нельзя скопировать ссылку → выше безопасность
- Неудобно для дистанционного шаринга

### 2. Invitation codes
```
https://construct.chat/invite/ABC123
```
- Генерируются на сервере
- Одноразовые или с TTL
- Можно отслеживать и отзывать
- Требует server-side БД

### 3. Public key fingerprint
```
construct://verify?key=SHA256_FINGERPRINT
```
- Проверка через QR-код
- Нет персональной информации в ссылке
- Требует дополнительный шаг верификации

## Рекомендация для Construct Messenger

**Краткосрочно (MVP):**
1. Реализовать Universal Links: `https://construct.chat/add?id=...&username=...&v=1`
2. Сохранить backward compatibility с `construct://`
3. Добавить URL encoding для username
4. Добавить версионирование (`v=1`)

**Среднесрочно:**
1. Настроить Associated Domains для iOS
2. Создать landing page на `construct.chat/add` для неустановленных приложений
3. Добавить Open Graph meta для превью при шаринге

**Долгосрочно:**
1. Реализовать server-side генерацию подписанных ссылок
2. Добавить короткие коды (optional)
3. Отслеживание использования ссылок (analytics)

## Ресурсы

- [Apple Universal Links](https://developer.apple.com/ios/universal-links/)
- [Android App Links](https://developer.android.com/training/app-links)
- [URL Scheme Best Practices](https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app)
- [OWASP Mobile Security](https://owasp.org/www-project-mobile-security-testing-guide/)

## Проверочный лист

- [ ] URL encoding для всех параметров
- [ ] Версионирование протокола
- [ ] Universal Links настроены
- [ ] Custom scheme fallback работает
- [ ] Валидация параметров на клиенте
- [ ] Обработка некорректных ссылок
- [ ] Landing page для веб
- [ ] Тесты для парсинга ссылок
- [ ] Документация для пользователей
- [ ] Rate limiting для генерации (если server-side)
