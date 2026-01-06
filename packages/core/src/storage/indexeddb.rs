// IndexedDB хранилище для WASM

use crate::storage::models::*;
use crate::utils::error::{ConstructError, Result};

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen_futures::JsFuture;
#[cfg(target_arch = "wasm32")]
use web_sys::{IdbDatabase, IdbRequest, IdbTransactionMode};

pub struct IndexedDbStorage {
    #[cfg(target_arch = "wasm32")]
    db: Option<IdbDatabase>,
}

impl IndexedDbStorage {
    pub fn new() -> Self {
        Self {
            #[cfg(target_arch = "wasm32")]
            db: None,
        }
    }

    /// Инициализировать базу данных
    #[cfg(target_arch = "wasm32")]
    pub async fn init(&mut self) -> Result<()> {
        let window = web_sys::window()
            .ok_or_else(|| ConstructError::StorageError("No window object".to_string()))?;

        let idb = window
            .indexed_db()
            .map_err(|e| ConstructError::StorageError(format!("IndexedDB not available: {:?}", e)))?
            .ok_or_else(|| ConstructError::StorageError("IndexedDB not supported".to_string()))?;

        // Открыть или создать БД
        let open_request = idb
            .open_with_u32("construct_messenger", 1)
            .map_err(|e| ConstructError::StorageError(format!("Failed to open DB: {:?}", e)))?;
        
        let onupgradeneeded = Closure::wrap(Box::new(move |event: web_sys::IdbVersionChangeEvent| {
            let target = event.target().expect("Event should have target");
            let request: IdbRequest = target.dyn_into().expect("Target should be IdbRequest");
            let db: IdbDatabase = request.result().unwrap().dyn_into().unwrap();

            // Создать object stores (версия БД контролирует создание)
            // Если версия увеличена, создаем все stores заново
            let params = web_sys::IdbObjectStoreParameters::new();
            params.set_key_path(&JsValue::from_str("user_id"));
            let _ = db.create_object_store_with_optional_parameters("private_keys", &params);

            let params = web_sys::IdbObjectStoreParameters::new();
            params.set_key_path(&JsValue::from_str("session_id"));
            if let Ok(store) = db.create_object_store_with_optional_parameters("sessions", &params) {
                // Индекс по contact_id
                let _ = store.create_index_with_str("contact_id", "contact_id");
            }

            let params = web_sys::IdbObjectStoreParameters::new();
            params.set_key_path(&JsValue::from_str("id"));
            let _ = db.create_object_store_with_optional_parameters("contacts", &params);

            let params = web_sys::IdbObjectStoreParameters::new();
            params.set_key_path(&JsValue::from_str("id"));
            if let Ok(store) = db.create_object_store_with_optional_parameters("messages", &params) {
                // Индексы для поиска
                let _ = store.create_index_with_str("conversation_id", "conversation_id");
                let _ = store.create_index_with_str("timestamp", "timestamp");
            }

            let params = web_sys::IdbObjectStoreParameters::new();
            params.set_key_path(&JsValue::from_str("user_id"));
            let _ = db.create_object_store_with_optional_parameters("metadata", &params);
        }) as Box<dyn FnMut(_)>);

        open_request.set_onupgradeneeded(Some(onupgradeneeded.as_ref().unchecked_ref()));
        onupgradeneeded.forget();

        // Дождаться открытия БД
        let db_promise = idb_open_request_to_promise(&open_request);
        let db_value = JsFuture::from(db_promise).await
            .map_err(|e| ConstructError::StorageError(format!("Failed to open database: {:?}", e)))?;

        let db: IdbDatabase = db_value.dyn_into()
            .map_err(|_| ConstructError::StorageError("Invalid database object".to_string()))?;

        self.db = Some(db);
        Ok(())
    }

    /// Инициализировать базу данных (non-WASM заглушка)
    #[cfg(not(target_arch = "wasm32"))]
    pub async fn init(&mut self) -> Result<()> {
        Ok(())
    }

    // === Вспомогательные методы ===

    #[cfg(target_arch = "wasm32")]
    fn get_db(&self) -> Result<&IdbDatabase> {
        self.db.as_ref()
            .ok_or_else(|| ConstructError::StorageError("Database not initialized".to_string()))
    }

    #[cfg(target_arch = "wasm32")]
    async fn put_value(&self, store_name: &str, value: &JsValue) -> Result<()> {
        let db = self.get_db()?;

        let transaction = db
            .transaction_with_str_and_mode(store_name, IdbTransactionMode::Readwrite)
            .map_err(|e| ConstructError::StorageError(format!("Failed to create transaction: {:?}", e)))?;

        let store = transaction
            .object_store(store_name)
            .map_err(|e| ConstructError::StorageError(format!("Failed to get store: {:?}", e)))?;

        let request = store
            .put(value)
            .map_err(|e| ConstructError::StorageError(format!("Failed to put value: {:?}", e)))?;

        let promise = idb_request_to_promise(&request);
        JsFuture::from(promise).await
            .map_err(|e| ConstructError::StorageError(format!("Put operation failed: {:?}", e)))?;

        Ok(())
    }

    #[cfg(target_arch = "wasm32")]
    async fn get_value(&self, store_name: &str, key: &JsValue) -> Result<Option<JsValue>> {
        let db = self.get_db()?;

        let transaction = db
            .transaction_with_str(store_name)
            .map_err(|e| ConstructError::StorageError(format!("Failed to create transaction: {:?}", e)))?;

        let store = transaction
            .object_store(store_name)
            .map_err(|e| ConstructError::StorageError(format!("Failed to get store: {:?}", e)))?;

        let request = store
            .get(key)
            .map_err(|e| ConstructError::StorageError(format!("Failed to get value: {:?}", e)))?;

        let promise = idb_request_to_promise(&request);
        let result = JsFuture::from(promise).await
            .map_err(|e| ConstructError::StorageError(format!("Get operation failed: {:?}", e)))?;

        if result.is_null() || result.is_undefined() {
            Ok(None)
        } else {
            Ok(Some(result))
        }
    }

    #[cfg(target_arch = "wasm32")]
    async fn get_all_values(&self, store_name: &str) -> Result<Vec<JsValue>> {
        let db = self.get_db()?;

        let transaction = db
            .transaction_with_str(store_name)
            .map_err(|e| ConstructError::StorageError(format!("Failed to create transaction: {:?}", e)))?;

        let store = transaction
            .object_store(store_name)
            .map_err(|e| ConstructError::StorageError(format!("Failed to get store: {:?}", e)))?;

        let request = store
            .get_all()
            .map_err(|e| ConstructError::StorageError(format!("Failed to get all: {:?}", e)))?;

        let promise = idb_request_to_promise(&request);
        let result = JsFuture::from(promise).await
            .map_err(|e| ConstructError::StorageError(format!("GetAll operation failed: {:?}", e)))?;

        let array: js_sys::Array = result.dyn_into()
            .map_err(|_| ConstructError::StorageError("Invalid array result".to_string()))?;

        Ok(array.iter().collect())
    }

    #[cfg(target_arch = "wasm32")]
    async fn delete_value(&self, store_name: &str, key: &JsValue) -> Result<()> {
        let db = self.get_db()?;

        let transaction = db
            .transaction_with_str_and_mode(store_name, IdbTransactionMode::Readwrite)
            .map_err(|e| ConstructError::StorageError(format!("Failed to create transaction: {:?}", e)))?;

        let store = transaction
            .object_store(store_name)
            .map_err(|e| ConstructError::StorageError(format!("Failed to get store: {:?}", e)))?;

        let request = store
            .delete(key)
            .map_err(|e| ConstructError::StorageError(format!("Failed to delete: {:?}", e)))?;

        let promise = idb_request_to_promise(&request);
        JsFuture::from(promise).await
            .map_err(|e| ConstructError::StorageError(format!("Delete operation failed: {:?}", e)))?;

        Ok(())
    }

    // === Приватные ключи ===

    #[cfg(target_arch = "wasm32")]
    pub async fn save_private_keys(&self, keys: StoredPrivateKeys) -> Result<()> {
        let value = serde_wasm_bindgen::to_value(&keys)
            .map_err(|e| ConstructError::SerializationError(format!("Failed to serialize keys: {:?}", e)))?;

        self.put_value("private_keys", &value).await
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub async fn save_private_keys(&self, _keys: StoredPrivateKeys) -> Result<()> {
        Err(ConstructError::StorageError("IndexedDB only available in WASM".to_string()))
    }

    #[cfg(target_arch = "wasm32")]
    pub async fn load_private_keys(&self, user_id: &str) -> Result<Option<StoredPrivateKeys>> {
        let key = JsValue::from_str(user_id);
        let value = self.get_value("private_keys", &key).await?;

        match value {
            Some(v) => {
                let keys: StoredPrivateKeys = serde_wasm_bindgen::from_value(v)
                    .map_err(|e| ConstructError::SerializationError(format!("Failed to deserialize keys: {:?}", e)))?;
                Ok(Some(keys))
            }
            None => Ok(None)
        }
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub async fn load_private_keys(&self, _user_id: &str) -> Result<Option<StoredPrivateKeys>> {
        Ok(None)
    }

    // === Сессии ===

    #[cfg(target_arch = "wasm32")]
    pub async fn save_session(&self, session: StoredSession) -> Result<()> {
        let value = serde_wasm_bindgen::to_value(&session)
            .map_err(|e| ConstructError::SerializationError(format!("Failed to serialize session: {:?}", e)))?;

        self.put_value("sessions", &value).await
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub async fn save_session(&self, _session: StoredSession) -> Result<()> {
        Err(ConstructError::StorageError("IndexedDB only available in WASM".to_string()))
    }

    #[cfg(target_arch = "wasm32")]
    pub async fn load_session(&self, session_id: &str) -> Result<Option<StoredSession>> {
        let key = JsValue::from_str(session_id);
        let value = self.get_value("sessions", &key).await?;

        match value {
            Some(v) => {
                let session: StoredSession = serde_wasm_bindgen::from_value(v)
                    .map_err(|e| ConstructError::SerializationError(format!("Failed to deserialize session: {:?}", e)))?;
                Ok(Some(session))
            }
            None => Ok(None)
        }
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub async fn load_session(&self, _session_id: &str) -> Result<Option<StoredSession>> {
        Ok(None)
    }

    #[cfg(target_arch = "wasm32")]
    pub async fn load_all_sessions(&self) -> Result<Vec<StoredSession>> {
        let values = self.get_all_values("sessions").await?;

        let mut sessions = Vec::new();
        for value in values {
            let session: StoredSession = serde_wasm_bindgen::from_value(value)
                .map_err(|e| ConstructError::SerializationError(format!("Failed to deserialize session: {:?}", e)))?;
            sessions.push(session);
        }

        Ok(sessions)
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub async fn load_all_sessions(&self) -> Result<Vec<StoredSession>> {
        Ok(Vec::new())
    }

    #[cfg(target_arch = "wasm32")]
    pub async fn delete_session(&self, session_id: &str) -> Result<()> {
        let key = JsValue::from_str(session_id);
        self.delete_value("sessions", &key).await
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub async fn delete_session(&self, _session_id: &str) -> Result<()> {
        Ok(())
    }

    // === Контакты ===

    #[cfg(target_arch = "wasm32")]
    pub async fn save_contact(&self, contact: StoredContact) -> Result<()> {
        let value = serde_wasm_bindgen::to_value(&contact)
            .map_err(|e| ConstructError::SerializationError(format!("Failed to serialize contact: {:?}", e)))?;

        self.put_value("contacts", &value).await
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub async fn save_contact(&self, _contact: StoredContact) -> Result<()> {
        Err(ConstructError::StorageError("IndexedDB only available in WASM".to_string()))
    }

    #[cfg(target_arch = "wasm32")]
    pub async fn load_all_contacts(&self) -> Result<Vec<StoredContact>> {
        let values = self.get_all_values("contacts").await?;

        let mut contacts = Vec::new();
        for value in values {
            let contact: StoredContact = serde_wasm_bindgen::from_value(value)
                .map_err(|e| ConstructError::SerializationError(format!("Failed to deserialize contact: {:?}", e)))?;
            contacts.push(contact);
        }

        Ok(contacts)
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub async fn load_all_contacts(&self) -> Result<Vec<StoredContact>> {
        Ok(Vec::new())
    }

    // === Сообщения ===

    #[cfg(target_arch = "wasm32")]
    pub async fn save_message(&self, msg: StoredMessage) -> Result<()> {
        let value = serde_wasm_bindgen::to_value(&msg)
            .map_err(|e| ConstructError::SerializationError(format!("Failed to serialize message: {:?}", e)))?;

        self.put_value("messages", &value).await
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub async fn save_message(&self, _msg: StoredMessage) -> Result<()> {
        Err(ConstructError::StorageError("IndexedDB only available in WASM".to_string()))
    }

    #[cfg(target_arch = "wasm32")]
    pub async fn load_messages_for_conversation(
        &self,
        conversation_id: &str,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<StoredMessage>> {
        let db = self.get_db()?;

        let transaction = db
            .transaction_with_str("messages")
            .map_err(|e| ConstructError::StorageError(format!("Failed to create transaction: {:?}", e)))?;

        let store = transaction
            .object_store("messages")
            .map_err(|e| ConstructError::StorageError(format!("Failed to get store: {:?}", e)))?;

        // Получить индекс по conversation_id
        let index = store
            .index("conversation_id")
            .map_err(|e| ConstructError::StorageError(format!("Failed to get index: {:?}", e)))?;

        let key = JsValue::from_str(conversation_id);
        let request = index
            .get_all_with_key(&key)
            .map_err(|e| ConstructError::StorageError(format!("Failed to query index: {:?}", e)))?;

        let promise = idb_request_to_promise(&request);
        let result = JsFuture::from(promise).await
            .map_err(|e| ConstructError::StorageError(format!("Query operation failed: {:?}", e)))?;

        let array: js_sys::Array = result.dyn_into()
            .map_err(|_| ConstructError::StorageError("Invalid array result".to_string()))?;

        let mut messages: Vec<StoredMessage> = array.iter()
            .map(|v| serde_wasm_bindgen::from_value(v))
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(|e| ConstructError::SerializationError(format!("Failed to deserialize messages: {:?}", e)))?;

        // Сортировать по timestamp
        messages.sort_by_key(|m| m.timestamp);

        // Применить offset и limit
        let messages: Vec<StoredMessage> = messages
            .into_iter()
            .skip(offset)
            .take(limit)
            .collect();

        Ok(messages)
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub async fn load_messages_for_conversation(
        &self,
        _conversation_id: &str,
        _limit: usize,
        _offset: usize,
    ) -> Result<Vec<StoredMessage>> {
        Ok(Vec::new())
    }

    // === Метаданные ===

    #[cfg(target_arch = "wasm32")]
    pub async fn save_metadata(&self, metadata: StoredAppMetadata) -> Result<()> {
        let value = serde_wasm_bindgen::to_value(&metadata)
            .map_err(|e| ConstructError::SerializationError(format!("Failed to serialize metadata: {:?}", e)))?;

        self.put_value("metadata", &value).await
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub async fn save_metadata(&self, _metadata: StoredAppMetadata) -> Result<()> {
        Err(ConstructError::StorageError("IndexedDB only available in WASM".to_string()))
    }

    #[cfg(target_arch = "wasm32")]
    pub async fn load_metadata(&self, user_id: &str) -> Result<Option<StoredAppMetadata>> {
        let key = JsValue::from_str(user_id);
        let value = self.get_value("metadata", &key).await?;

        match value {
            Some(v) => {
                let metadata: StoredAppMetadata = serde_wasm_bindgen::from_value(v)
                    .map_err(|e| ConstructError::SerializationError(format!("Failed to deserialize metadata: {:?}", e)))?;
                Ok(Some(metadata))
            }
            None => Ok(None)
        }
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub async fn load_metadata(&self, _user_id: &str) -> Result<Option<StoredAppMetadata>> {
        Ok(None)
    }

    // === Утилиты ===

    #[cfg(target_arch = "wasm32")]
    pub async fn clear_all(&self) -> Result<()> {
        let db = self.get_db()?;
        let store_names = &["private_keys", "sessions", "contacts", "messages", "metadata"];

        for store_name in store_names {
            let transaction = db
                .transaction_with_str_and_mode(store_name, IdbTransactionMode::Readwrite)
                .map_err(|e| ConstructError::StorageError(format!("Failed to create transaction for clear: {:?}", e)))?;

            let store = transaction
                .object_store(store_name)
                .map_err(|e| ConstructError::StorageError(format!("Failed to get store for clear: {:?}", e)))?;

            let request = store
                .clear()
                .map_err(|e| ConstructError::StorageError(format!("Failed to clear {}: {:?}", store_name, e)))?;

            let promise = idb_request_to_promise(&request);
            JsFuture::from(promise).await
                .map_err(|e| ConstructError::StorageError(format!("Clear operation failed for {}: {:?}", store_name, e)))?;
        }

        Ok(())
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub async fn clear_all(&self) -> Result<()> {
        Ok(())
    }
}

impl Default for IndexedDbStorage {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(target_arch = "wasm32")]
fn idb_request_to_promise(request: &IdbRequest) -> js_sys::Promise {
    js_sys::Promise::new(&mut |resolve, reject| {
        let onsuccess = Closure::wrap(Box::new(move |event: web_sys::Event| {
            let target = event.target().expect("Event target is missing");
            let req = target.dyn_into::<web_sys::IdbRequest>().unwrap();
            let result = req.result().unwrap();
            resolve.call1(&JsValue::NULL, &result).unwrap();
        }) as Box<dyn FnMut(_)>);

        let onerror = Closure::wrap(Box::new(move |event: web_sys::Event| {
            // Stop the event from propagating.
            event.prevent_default();
            let target = event.target().expect("Event target is missing");
            let req = target.dyn_into::<web_sys::IdbRequest>().unwrap();
            if let Some(error) = req.error().unwrap() {
                 reject.call1(&JsValue::NULL, &error.into()).unwrap();
            } else {
                 reject.call1(&JsValue::NULL, &JsValue::from("Unknown IndexedDB Error")).unwrap();
            }
        }) as Box<dyn FnMut(_)>);

        request.set_onsuccess(Some(onsuccess.as_ref().unchecked_ref()));
        request.set_onerror(Some(onerror.as_ref().unchecked_ref()));

        onsuccess.forget();
        onerror.forget();
    })
}

#[cfg(target_arch = "wasm32")]
fn idb_open_request_to_promise(request: &web_sys::IdbOpenDbRequest) -> js_sys::Promise {
    idb_request_to_promise(request)
}

// Для совместимости с существующим кодом
pub type KeyStorage = IndexedDbStorage;
