# Profile Sharing Implementation TODO

## Текущий статус
✅ **Завершено:**
- Core Data модель User расширена полем `avatarData: Data?`
- ImageHelper создан для обработки изображений (1024x1024, макс 256 КБ)
- Сохранение аватара в AccountSettingsView через Core Data
- Отображение аватаров в ChatRowView
- SettingsViewModel использует Core Data вместо UserDefaults

## Что нужно реализовать

### 1. Протокол обмена профильной информацией

#### 1.1 Server-side (Rust)
**Файл:** `construct-server/src/db.rs`
- [ ] Добавить поле `avatar_data` (BYTEA) в таблицу `users` (опционально)
- [ ] Добавить поле `display_name` в таблицу `users` (если еще нет)
- [ ] Функция `update_user_profile(pool, user_id, display_name, avatar_data)` для обновления профиля

**Файл:** `packages/core/src/protocol/messages.rs`
- [ ] Создать новый message type `ProfileUpdate`:
  ```rust
  #[derive(Debug, Clone, Serialize, Deserialize)]
  pub struct ProfileUpdate {
      pub display_name: String,
      pub avatar_data: Option<Vec<u8>>, // Base64 encoded or binary
      pub timestamp: u64,
  }
  ```

**Файл:** `construct-server/src/handlers/...` (websocket handlers)
- [ ] Добавить обработчик для `ClientMessage::UpdateProfile`
- [ ] Relay profile updates только доверенным контактам (существующие чаты)

#### 1.2 Client-side (Swift)

**Файл:** `ProtocolTypes.swift`
- [ ] Добавить новый case в `ClientMessage`:
  ```swift
  case updateProfile(ProfileUpdateData)
  ```
- [ ] Создать структуру `ProfileUpdateData`:
  ```swift
  struct ProfileUpdateData: Codable {
      let displayName: String
      let avatarData: String? // Base64 encoded
      let timestamp: Date
  }
  ```
- [ ] Добавить case в `ServerMessage`:
  ```swift
  case profileUpdate(ProfileUpdateData)
  ```

**Файл:** `WebSocketManager.swift`
- [ ] Добавить метод `sendProfileUpdate(displayName:avatarData:)`
- [ ] Добавить обработку входящих `ServerMessage.profileUpdate`

**Файл:** `SettingsViewModel.swift`
- [ ] После сохранения avatar или displayName отправлять update через WebSocket:
  ```swift
  func saveAvatar(_ image: UIImage) {
      // ... existing code ...

      // Send update to server/contacts
      if let processedData = ImageHelper.prepareAvatarImage(image) {
          let base64Avatar = processedData.base64EncodedString()
          WebSocketManager.shared.sendProfileUpdate(
              displayName: displayName,
              avatarData: base64Avatar
          )
      }
  }
  ```

**Файл:** `ChatsViewModel.swift` или новый `ProfileUpdateHandler.swift`
- [ ] Обработка входящих profile updates:
  ```swift
  func handleProfileUpdate(_ data: ProfileUpdateData, from userId: String) {
      guard let context = viewContext else { return }

      let fetchRequest: NSFetchRequest<User> = User.fetchRequest()
      fetchRequest.predicate = NSPredicate(format: "id == %@", userId)

      if let user = try? context.fetch(fetchRequest).first {
          user.displayName = data.displayName

          if let base64Avatar = data.avatarData,
             let avatarData = Data(base64Encoded: base64Avatar) {
              user.avatarData = avatarData
          }

          try? context.save()
          print("✅ Profile updated for user: \(userId)")
      }
  }
  ```

### 2. UI/UX улучшения

**Опционально:**
- [ ] Показывать индикатор при отправке profile update
- [ ] Toast/уведомление когда контакт обновил свой профиль
- [ ] Кнопка "Поделиться профилем" для ручной отправки (или автоматически при изменении)

### 3. Privacy & Security соображения

**Важно:**
- ⚠️ Profile updates должны отправляться **только существующим контактам** (с кем есть Chat)
- ⚠️ Не отправлять глобально всем пользователям
- ⚠️ Валидация размера avatar на сервере (макс 256 КБ)
- ⚠️ Rate limiting для profile updates (например, не чаще 1 раза в минуту)

### 4. Migration план

**Для существующих пользователей:**
- [ ] Миграция Core Data: убедиться что `avatarData` опциональное (уже сделано ✅)
- [ ] Server migration: добавить колонки `avatar_data`, `display_name` если нужно
- [ ] Backward compatibility: старые клиенты должны игнорировать новые message types

### 5. Тестирование

- [ ] Тест: сохранение и загрузка аватара из Core Data
- [ ] Тест: отправка profile update через WebSocket
- [ ] Тест: получение и применение profile update от контакта
- [ ] Тест: avatar обрезается до 1024x1024 и сжимается до <256 КБ
- [ ] Тест: placeholder аватары генерируются корректно

## Технические детали

### Формат передачи
**Вариант 1 (рекомендуемый):** Base64 в JSON
```json
{
  "type": "profileUpdate",
  "data": {
    "displayName": "Alice",
    "avatarData": "iVBORw0KGgoAAAANS...", // Base64
    "timestamp": 1703980800000
  }
}
```

**Вариант 2:** Multipart (если WebSocket поддерживает)
- Отправлять binary data напрямую

### Хранение на сервере
**Опция A:** Не хранить аватары на сервере
- Relay только между активными клиентами
- Клиенты хранят локально в Core Data

**Опция B:** Хранить в database (BYTEA)
- Позволяет новым клиентам загрузить аватар при первом контакте
- Требует больше места на сервере

**Рекомендация:** Начать с Опции A (no server storage), позже добавить опциональное хранение

## Приоритеты

**MVP (Минимальная реализация):**
1. Протокол ProfileUpdate (client + server)
2. Отправка при изменении displayName/avatar
3. Получение и сохранение в Core Data

**Nice to have:**
1. Server-side хранение аватаров
2. UI уведомления о обновлениях
3. Batch updates (отправка нескольким контактам одновременно)

## Примерный timeline
- Protocol implementation: 2-3 часа
- Client-side integration: 1-2 часа
- Server-side relay logic: 1-2 часа
- Testing & refinement: 1 час

**Итого:** ~6-8 часов работы

---

## Связанные файлы для изменения

### Swift (iOS):
- `ConstructMessenger/Models/Protocol Models/ProtocolTypes.swift`
- `ConstructMessenger/Networking/WebSocketManager.swift`
- `ConstructMessenger/ViewModels/SettingsViewModel.swift`
- `ConstructMessenger/ViewModels/ChatsViewModel.swift`

### Rust (Server):
- `construct-server/src/db.rs`
- `packages/core/src/protocol/messages.rs`
- `construct-server/src/handlers/websocket.rs` (или аналогичный)

### Database:
- Migration script для добавления `avatar_data`, `display_name` если нужно
