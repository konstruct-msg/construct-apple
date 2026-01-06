// WASM bindings

use wasm_bindgen::prelude::*;
use crate::crypto::ClientCrypto;
use crate::api::{crypto, messaging, contacts};
use crate::protocol::validation;
use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

// Глобальное хранилище клиентов
thread_local! {
    static CLIENTS: RefCell<HashMap<String, ClientCrypto>> = RefCell::new(HashMap::new());
    static CRYPTO_MANAGERS: RefCell<HashMap<String, crypto::CryptoManager>> = RefCell::new(HashMap::new());
    static CONTACT_MANAGERS: RefCell<HashMap<String, contacts::ContactManager>> = RefCell::new(HashMap::new());
    static APP_STATES: RefCell<HashMap<String, Arc<Mutex<crate::state::app::AppState>>>> = RefCell::new(HashMap::new());
}

/// Создать нового криптографического клиента
#[wasm_bindgen]
pub fn create_crypto_client() -> Result<String, JsValue> {
    let client = crypto::create_client()
        .map_err(|e| JsValue::from_str(&e.to_string()))?;

    let client_id = uuid::Uuid::new_v4().to_string();

    CLIENTS.with(|clients| {
        clients.borrow_mut().insert(client_id.clone(), client);
    });

    Ok(client_id)
}

/// Получить публичные ключи клиента для регистрации (JSON)
#[wasm_bindgen]
pub fn get_registration_bundle(client_id: String) -> Result<String, JsValue> {
    CLIENTS.with(|clients| {
        let clients_ref = clients.borrow();
        let client = clients_ref.get(&client_id)
            .ok_or_else(|| JsValue::from_str("Client not found"))?;

        let bundle = crypto::get_registration_bundle(client)
            .map_err(|e| JsValue::from_str(&e.to_string()))?;

        crypto::serialize_key_bundle(&bundle)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    })
}

/// Инициализировать сессию с контактом (отправитель)
/// remote_bundle_json - JSON строка с ключами удаленной стороны
/// Возвращает session_id
#[wasm_bindgen]
pub fn init_session(
    client_id: String,
    contact_id: String,
    remote_bundle_json: String,
) -> Result<String, JsValue> {
    CLIENTS.with(|clients| {
        let mut clients_ref = clients.borrow_mut();
        let client = clients_ref.get_mut(&client_id)
            .ok_or_else(|| JsValue::from_str("Client not found"))?;

        let remote_bundle = crypto::deserialize_key_bundle(&remote_bundle_json)
            .map_err(|e| JsValue::from_str(&e.to_string()))?;

        messaging::init_session(client, &contact_id, &remote_bundle)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    })
}

/// Инициализировать сессию получателя при получении первого сообщения
/// first_message_json - JSON строка с первым зашифрованным сообщением от отправителя
/// Возвращает session_id
#[wasm_bindgen]
pub fn init_receiving_session(
    client_id: String,
    contact_id: String,
    remote_bundle_json: String,
    first_message_json: String,
) -> Result<String, JsValue> {
    CLIENTS.with(|clients| {
        let mut clients_ref = clients.borrow_mut();
        let client = clients_ref.get_mut(&client_id)
            .ok_or_else(|| JsValue::from_str("Client not found"))?;

        let remote_bundle = crypto::deserialize_key_bundle(&remote_bundle_json)
            .map_err(|e| JsValue::from_str(&e.to_string()))?;

        let first_message = messaging::deserialize_encrypted_message(&first_message_json)
            .map_err(|e| JsValue::from_str(&e.to_string()))?;

        messaging::init_receiving_session(client, &contact_id, &remote_bundle, &first_message)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    })
}

/// Зашифровать сообщение
/// Возвращает JSON с зашифрованным сообщением
#[wasm_bindgen]
pub fn encrypt_message(
    client_id: String,
    session_id: String,
    plaintext: String,
) -> Result<String, JsValue> {
    CLIENTS.with(|clients| {
        let mut clients_ref = clients.borrow_mut();
        let client = clients_ref.get_mut(&client_id)
            .ok_or_else(|| JsValue::from_str("Client not found"))?;

        let encrypted = messaging::encrypt_message(client, &session_id, &plaintext)
            .map_err(|e| JsValue::from_str(&e.to_string()))?;

        messaging::serialize_encrypted_message(&encrypted)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    })
}

/// Расшифровать сообщение
/// encrypted_json - JSON строка с зашифрованным сообщением
/// Возвращает расшифрованный текст
#[wasm_bindgen]
pub fn decrypt_message(
    client_id: String,
    session_id: String,
    encrypted_json: String,
) -> Result<String, JsValue> {
    CLIENTS.with(|clients| {
        let mut clients_ref = clients.borrow_mut();
        let client = clients_ref.get_mut(&client_id)
            .ok_or_else(|| JsValue::from_str("Client not found"))?;

        let encrypted = messaging::deserialize_encrypted_message(&encrypted_json)
            .map_err(|e| JsValue::from_str(&e.to_string()))?;

        messaging::decrypt_message(client, &session_id, encrypted)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    })
}

/// Удалить клиента из памяти
#[wasm_bindgen]
pub fn destroy_client(client_id: String) -> Result<(), JsValue> {
    CLIENTS.with(|clients| {
        clients.borrow_mut().remove(&client_id)
            .ok_or_else(|| JsValue::from_str("Client not found"))?;
        Ok(())
    })
}

// ===== CryptoManager WASM API =====

/// Создать новый CryptoManager
#[wasm_bindgen]
pub fn create_crypto_manager() -> Result<String, JsValue> {
    let manager = crypto::CryptoManager::new()
        .map_err(|e| JsValue::from_str(&e.to_string()))?;

    let manager_id = uuid::Uuid::new_v4().to_string();

    CRYPTO_MANAGERS.with(|managers| {
        managers.borrow_mut().insert(manager_id.clone(), manager);
    });

    Ok(manager_id)
}

/// Экспортировать registration bundle в JSON
#[wasm_bindgen]
pub fn crypto_manager_get_registration_bundle(manager_id: String) -> Result<String, JsValue> {
    CRYPTO_MANAGERS.with(|managers| {
        let managers_ref = managers.borrow();
        let manager = managers_ref.get(&manager_id)
            .ok_or_else(|| JsValue::from_str("Manager not found"))?;

        let bundle = manager.export_registration_bundle()
            .map_err(|e| JsValue::from_str(&e.to_string()))?;

        crypto::serialize_key_bundle(&bundle)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    })
}

/// Экспортировать registration bundle в base64 формате
#[wasm_bindgen]
pub fn crypto_manager_get_registration_bundle_b64(manager_id: String) -> Result<String, JsValue> {
    CRYPTO_MANAGERS.with(|managers| {
        let managers_ref = managers.borrow();
        let manager = managers_ref.get(&manager_id)
            .ok_or_else(|| JsValue::from_str("Manager not found"))?;

        let bundle = manager.export_registration_bundle_b64()
            .map_err(|e| JsValue::from_str(&e.to_string()))?;

        serde_json::to_string(&bundle)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    })
}

/// Ротация prekey
#[wasm_bindgen]
pub fn crypto_manager_rotate_prekey(manager_id: String) -> Result<(), JsValue> {
    CRYPTO_MANAGERS.with(|managers| {
        let mut managers_ref = managers.borrow_mut();
        let manager = managers_ref.get_mut(&manager_id)
            .ok_or_else(|| JsValue::from_str("Manager not found"))?;

        manager.rotate_prekey()
            .map_err(|e| JsValue::from_str(&e.to_string()))
    })
}

/// Проверить наличие сессии
#[wasm_bindgen]
pub fn crypto_manager_has_session(manager_id: String, contact_id: String) -> Result<bool, JsValue> {
    CRYPTO_MANAGERS.with(|managers| {
        let managers_ref = managers.borrow();
        let manager = managers_ref.get(&manager_id)
            .ok_or_else(|| JsValue::from_str("Manager not found"))?;

        Ok(manager.has_session(&contact_id))
    })
}

/// Удалить CryptoManager
#[wasm_bindgen]
pub fn destroy_crypto_manager(manager_id: String) -> Result<(), JsValue> {
    CRYPTO_MANAGERS.with(|managers| {
        managers.borrow_mut().remove(&manager_id)
            .ok_or_else(|| JsValue::from_str("Manager not found"))?;
        Ok(())
    })
}

// ===== ContactManager WASM API =====

/// Создать новый ContactManager
#[wasm_bindgen]
pub fn create_contact_manager() -> String {
    let manager = contacts::ContactManager::new();
    let manager_id = uuid::Uuid::new_v4().to_string();

    CONTACT_MANAGERS.with(|managers| {
        managers.borrow_mut().insert(manager_id.clone(), manager);
    });

    manager_id
}

/// Добавить контакт
#[wasm_bindgen]
pub fn contact_manager_add_contact(
    manager_id: String,
    contact_id: String,
    username: String,
) -> Result<(), JsValue> {
    CONTACT_MANAGERS.with(|managers| {
        let mut managers_ref = managers.borrow_mut();
        let manager = managers_ref.get_mut(&manager_id)
            .ok_or_else(|| JsValue::from_str("Manager not found"))?;

        let contact = contacts::create_contact(contact_id, username);
        manager.add_contact(contact)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    })
}

/// Получить контакт по ID (JSON)
#[wasm_bindgen]
pub fn contact_manager_get_contact(manager_id: String, contact_id: String) -> Result<String, JsValue> {
    CONTACT_MANAGERS.with(|managers| {
        let managers_ref = managers.borrow();
        let manager = managers_ref.get(&manager_id)
            .ok_or_else(|| JsValue::from_str("Manager not found"))?;

        let contact = manager.get_contact(&contact_id)
            .ok_or_else(|| JsValue::from_str("Contact not found"))?;

        serde_json::to_string(contact)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    })
}

/// Получить все контакты (JSON array)
#[wasm_bindgen]
pub fn contact_manager_get_all_contacts(manager_id: String) -> Result<String, JsValue> {
    CONTACT_MANAGERS.with(|managers| {
        let managers_ref = managers.borrow();
        let manager = managers_ref.get(&manager_id)
            .ok_or_else(|| JsValue::from_str("Manager not found"))?;

        let contacts = manager.get_all_contacts();
        serde_json::to_string(&contacts)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    })
}

/// Поиск контактов по username
#[wasm_bindgen]
pub fn contact_manager_search_contacts(manager_id: String, query: String) -> Result<String, JsValue> {
    CONTACT_MANAGERS.with(|managers| {
        let managers_ref = managers.borrow();
        let manager = managers_ref.get(&manager_id)
            .ok_or_else(|| JsValue::from_str("Manager not found"))?;

        let results = manager.search_contacts(&query);
        serde_json::to_string(&results)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    })
}

/// Удалить контакт
#[wasm_bindgen]
pub fn contact_manager_remove_contact(manager_id: String, contact_id: String) -> Result<(), JsValue> {
    CONTACT_MANAGERS.with(|managers| {
        let mut managers_ref = managers.borrow_mut();
        let manager = managers_ref.get_mut(&manager_id)
            .ok_or_else(|| JsValue::from_str("Manager not found"))?;

        manager.remove_contact(&contact_id);
        Ok(())
    })
}

/// Удалить ContactManager
#[wasm_bindgen]
pub fn destroy_contact_manager(manager_id: String) -> Result<(), JsValue> {
    CONTACT_MANAGERS.with(|managers| {
        managers.borrow_mut().remove(&manager_id)
            .ok_or_else(|| JsValue::from_str("Manager not found"))?;
        Ok(())
    })
}

// ===== Protocol & Utility Functions =====

/// Валидировать username
#[wasm_bindgen]
pub fn validate_username(username: String) -> Result<bool, JsValue> {
    match validation::validate_username(&username) {
        Ok(_) => Ok(true),
        Err(_) => Ok(false),
    }
}

/// Валидировать UUID
#[wasm_bindgen]
pub fn validate_uuid(uuid: String) -> Result<bool, JsValue> {
    match validation::validate_uuid(&uuid) {
        Ok(_) => Ok(true),
        Err(_) => Ok(false),
    }
}

/// Конвертировать байты в base64
#[wasm_bindgen]
pub fn bytes_to_base64(bytes: Vec<u8>) -> String {
    crypto::bytes_to_base64(&bytes)
}

/// Конвертировать base64 в байты
#[wasm_bindgen]
pub fn base64_to_bytes(base64_str: String) -> Result<Vec<u8>, JsValue> {
    crypto::base64_to_bytes(&base64_str)
        .map_err(|e| JsValue::from_str(&e.to_string()))
}

/// Генерировать случайные байты
#[wasm_bindgen]
pub fn generate_random_bytes(len: usize) -> Vec<u8> {
    crypto::generate_random_bytes(len)
}

/// Генерировать UUID v4
#[wasm_bindgen]
pub fn generate_uuid() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// Получить текущий timestamp в секундах
#[wasm_bindgen]
pub fn current_timestamp() -> i64 {
    crate::utils::time::current_timestamp()
}

// Note: pack/unpack protocol messages is now encapsulated inside AppState
// and doesn't require direct access from JavaScript

// ===== AppState WASM API =====

/// Создать новый AppState
#[wasm_bindgen]
pub async fn create_app_state(_db_name: String) -> Result<String, JsValue> {
    #[cfg(target_arch = "wasm32")]
    let state = crate::state::app::AppState::new().await
        .map_err(|e| JsValue::from_str(&e.to_string()))?;

    #[cfg(not(target_arch = "wasm32"))]
    let state = crate::state::app::AppState::new(&db_name)
        .map_err(|e| JsValue::from_str(&e.to_string()))?;

    let state_id = uuid::Uuid::new_v4().to_string();

    APP_STATES.with(|states| {
        states.borrow_mut().insert(state_id.clone(), Arc::new(Mutex::new(state)));
    });

    Ok(state_id)
}

/// Инициализировать нового пользователя (только создать ключи, не сохранять)
#[wasm_bindgen]
pub async fn app_state_initialize_user(
    state_id: String,
    username: String,
    password: String,
) -> Result<(), JsValue> {
    // Получаем Arc<Mutex<AppState>> из thread_local
    let state_arc = APP_STATES.with(|states| {
        states.borrow()
            .get(&state_id)
            .cloned()
            .ok_or_else(|| JsValue::from_str("AppState not found"))
    })?;

    // Выполняем async операцию вне thread_local блока
    #[cfg(target_arch = "wasm32")]
    {
        let mut state = state_arc.lock()
            .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

        state.initialize_user(username, password).await
            .map_err(|e| JsValue::from_str(&e.to_string()))
    }

    #[cfg(not(target_arch = "wasm32"))]
    {
        let mut state = state_arc.lock()
            .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

        state.initialize_user(username, password)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    }
}

/// Завершить регистрацию после получения UUID от сервера
#[wasm_bindgen]
pub async fn app_state_finalize_registration(
    state_id: String,
    server_user_id: String,
    session_token: String,
    password: String,
) -> Result<(), JsValue> {
    let state_arc = APP_STATES.with(|states| {
        states.borrow()
            .get(&state_id)
            .cloned()
            .ok_or_else(|| JsValue::from_str("AppState not found"))
    })?;

    #[cfg(target_arch = "wasm32")]
    {
        let mut state = state_arc.lock()
            .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

        state.finalize_registration(server_user_id, session_token, password).await
            .map_err(|e| JsValue::from_str(&e.to_string()))
    }

    #[cfg(not(target_arch = "wasm32"))]
    {
        let mut state = state_arc.lock()
            .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

        state.finalize_registration(server_user_id, session_token, password)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    }
}

/// Загрузить существующего пользователя
#[wasm_bindgen]
pub async fn app_state_load_user(
    state_id: String,
    user_id: String,
    password: String,
) -> Result<(), JsValue> {
    let state_arc = APP_STATES.with(|states| {
        states.borrow()
            .get(&state_id)
            .cloned()
            .ok_or_else(|| JsValue::from_str("AppState not found"))
    })?;

    #[cfg(target_arch = "wasm32")]
    {
        let mut state = state_arc.lock()
            .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

        state.load_user(user_id, password).await
            .map_err(|e| JsValue::from_str(&e.to_string()))
    }

    #[cfg(not(target_arch = "wasm32"))]
    {
        let mut state = state_arc.lock()
            .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

        state.load_user(user_id, password)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    }
}

/// Получить user_id текущего пользователя
#[wasm_bindgen]
pub fn app_state_get_user_id(state_id: String) -> Result<Option<String>, JsValue> {
    let state_arc = APP_STATES.with(|states| {
        states.borrow()
            .get(&state_id)
            .cloned()
            .ok_or_else(|| JsValue::from_str("AppState not found"))
    })?;

    let state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

    Ok(state.get_user_id().map(|s| s.to_string()))
}

/// Получить username текущего пользователя
#[wasm_bindgen]
pub fn app_state_get_username(state_id: String) -> Result<Option<String>, JsValue> {
    let state_arc = APP_STATES.with(|states| {
        states.borrow()
            .get(&state_id)
            .cloned()
            .ok_or_else(|| JsValue::from_str("AppState not found"))
    })?;

    let state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

    Ok(state.get_username().map(|s| s.to_string()))
}

/// Добавить контакт
#[wasm_bindgen]
pub async fn app_state_add_contact(
    state_id: String,
    contact_id: String,
    username: String,
) -> Result<(), JsValue> {
    let state_arc = APP_STATES.with(|states| {
        states.borrow()
            .get(&state_id)
            .cloned()
            .ok_or_else(|| JsValue::from_str("AppState not found"))
    })?;

    #[cfg(target_arch = "wasm32")]
    {
        let mut state = state_arc.lock()
            .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

        state.add_contact(contact_id, username).await
            .map_err(|e| JsValue::from_str(&e.to_string()))
    }

    #[cfg(not(target_arch = "wasm32"))]
    {
        let mut state = state_arc.lock()
            .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

        state.add_contact(contact_id, username)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    }
}

/// Получить список всех контактов (JSON)
#[wasm_bindgen]
pub fn app_state_get_contacts(state_id: String) -> Result<String, JsValue> {
    let state_arc = APP_STATES.with(|states| {
        states.borrow()
            .get(&state_id)
            .cloned()
            .ok_or_else(|| JsValue::from_str("AppState not found"))
    })?;

    let state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

    let contacts = state.get_contacts();
    serde_json::to_string(&contacts)
        .map_err(|e| JsValue::from_str(&e.to_string()))
}

/// Отправить сообщение
#[wasm_bindgen]
pub async fn app_state_send_message(
    state_id: String,
    to: String,
    session_id: String,
    text: String,
) -> Result<String, JsValue> {
    let state_arc = APP_STATES.with(|states| {
        states.borrow()
            .get(&state_id)
            .cloned()
            .ok_or_else(|| JsValue::from_str("AppState not found"))
    })?;

    #[cfg(target_arch = "wasm32")]
    {
        let mut state = state_arc.lock()
            .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

        state.send_message(&to, &session_id, &text).await
            .map_err(|e| JsValue::from_str(&e.to_string()))
    }

    #[cfg(not(target_arch = "wasm32"))]
    {
        let mut state = state_arc.lock()
            .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

        state.send_message(&to, &session_id, &text)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    }
}

/// Загрузить беседу с контактом (JSON)
#[wasm_bindgen]
pub async fn app_state_load_conversation(
    state_id: String,
    contact_id: String,
) -> Result<String, JsValue> {
    let state_arc = APP_STATES.with(|states| {
        states.borrow()
            .get(&state_id)
            .cloned()
            .ok_or_else(|| JsValue::from_str("AppState not found"))
    })?;

    #[cfg(target_arch = "wasm32")]
    {
        let mut state = state_arc.lock()
            .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

        let conversation = state.load_conversation(&contact_id).await
            .map_err(|e| JsValue::from_str(&e.to_string()))?;

        serde_json::to_string(&conversation)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    }

    #[cfg(not(target_arch = "wasm32"))]
    {
        let mut state = state_arc.lock()
            .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

        let conversation = state.load_conversation(&contact_id)
            .map_err(|e| JsValue::from_str(&e.to_string()))?;

        serde_json::to_string(&conversation)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    }
}

/// Подключиться к WebSocket серверу с полной интеграцией callbacks
#[wasm_bindgen]
pub async fn app_state_connect(
    state_id: String,
    server_url: String,
) -> Result<(), JsValue> {
    use crate::protocol::transport::WebSocketTransport;
    use crate::state::app::{AppState, ConnectionState};

    let state_arc = APP_STATES.with(|states| {
        states.borrow()
            .get(&state_id)
            .cloned()
            .ok_or_else(|| JsValue::from_str("AppState not found"))
    })?;

    #[cfg(target_arch = "wasm32")]
    {
        // 1. Проверить текущее состояние
        {
            let state = state_arc.lock()
                .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

            if state.connection_state() == ConnectionState::Connected {
                return Err(JsValue::from_str("Already connected"));
            }
        }

        // 2. Сохранить server_url для автоматического переподключения
        {
            let mut state = state_arc.lock()
                .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

            state.set_server_url(server_url.clone());
        }

        // 3. Создать и подключить WebSocket транспорт
        let mut transport = WebSocketTransport::new();
        transport.connect(&server_url)
            .map_err(|e| JsValue::from_str(&e.to_string()))?;

        // 4. Настроить callbacks с доступом к Arc<Mutex<AppState>>
        // ✅ Это ключевая часть! Теперь callbacks имеют доступ к AppState
        AppState::setup_transport_callbacks_with_arc(&mut transport, state_arc.clone())
            .map_err(|e| JsValue::from_str(&e.to_string()))?;

        // 5. Сохранить транспорт в AppState
        {
            let mut state = state_arc.lock()
                .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

            state.set_transport(transport);
        }

        Ok(())
    }

    #[cfg(not(target_arch = "wasm32"))]
    {
        let mut state = state_arc.lock()
            .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

        state.connect(&server_url)
            .map_err(|e| JsValue::from_str(&e.to_string()))
    }
}

/// Отключиться от WebSocket сервера
#[wasm_bindgen]
pub async fn app_state_disconnect(state_id: String) -> Result<(), JsValue> {
    let state_arc = APP_STATES.with(|states| {
        states.borrow()
            .get(&state_id)
            .cloned()
            .ok_or_else(|| JsValue::from_str("AppState not found"))
    })?;

    #[cfg(target_arch = "wasm32")]
    {
        let mut state = state_arc.lock()
            .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

        state.disconnect()
            .map_err(|e| JsValue::from_str(&e.to_string()))
    }

    #[cfg(not(target_arch = "wasm32"))]
    {
        let mut state = state_arc.lock()
            .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

        state.disconnect()
            .map_err(|e| JsValue::from_str(&e.to_string()))
    }
}

/// Получить состояние подключения
#[wasm_bindgen]
pub fn app_state_connection_state(state_id: String) -> Result<String, JsValue> {
    use crate::state::app::ConnectionState;

    let state_arc = APP_STATES.with(|states| {
        states.borrow()
            .get(&state_id)
            .cloned()
            .ok_or_else(|| JsValue::from_str("AppState not found"))
    })?;

    let state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

    let conn_state = state.connection_state();
    let state_str = match conn_state {
        ConnectionState::Connecting => "connecting",
        ConnectionState::Connected => "connected",
        ConnectionState::Disconnected => "disconnected",
        ConnectionState::Reconnecting => "reconnecting",
        ConnectionState::Error => "error",
    };

    Ok(state_str.to_string())
}

/// Включить/выключить автоматическое переподключение
#[wasm_bindgen]
pub fn app_state_set_auto_reconnect(state_id: String, enabled: bool) -> Result<(), JsValue> {
    let state_arc = APP_STATES.with(|states| {
        states.borrow()
            .get(&state_id)
            .cloned()
            .ok_or_else(|| JsValue::from_str("AppState not found"))
    })?;

    let mut state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

    state.reconnect_state_mut().set_enabled(enabled);

    Ok(())
}

/// Получить количество попыток переподключения
#[wasm_bindgen]
pub fn app_state_reconnect_attempts(state_id: String) -> Result<u32, JsValue> {
    let state_arc = APP_STATES.with(|states| {
        states.borrow()
            .get(&state_id)
            .cloned()
            .ok_or_else(|| JsValue::from_str("AppState not found"))
    })?;

    let state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

    Ok(state.reconnect_state().attempts())
}

/// Сбросить счётчик попыток переподключения
#[wasm_bindgen]
pub fn app_state_reset_reconnect(state_id: String) -> Result<(), JsValue> {
    let state_arc = APP_STATES.with(|states| {
        states.borrow()
            .get(&state_id)
            .cloned()
            .ok_or_else(|| JsValue::from_str("AppState not found"))
    })?;

    let mut state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

    state.reconnect_state_mut().reset();

    Ok(())
}

/// Зарегистрировать пользователя на сервере
/// Отправляет сообщение Register с username, password и registration bundle
#[wasm_bindgen]
pub fn app_state_register_on_server(state_id: String, password: String) -> Result<(), JsValue> {
    let state_arc = APP_STATES.with(|states| {
        states.borrow()
            .get(&state_id)
            .cloned()
            .ok_or_else(|| JsValue::from_str("AppState not found"))
    })?;

    let state = state_arc.lock()
        .map_err(|e| JsValue::from_str(&format!("Failed to lock state: {}", e)))?;

    state.register_on_server(password)
        .map_err(|e| JsValue::from_str(&e.to_string()))
}

/// Удалить AppState из памяти
#[wasm_bindgen]
pub fn destroy_app_state(state_id: String) -> Result<(), JsValue> {
    APP_STATES.with(|states| {
        states.borrow_mut().remove(&state_id)
            .ok_or_else(|| JsValue::from_str("AppState not found"))?;
        Ok(())
    })
}
