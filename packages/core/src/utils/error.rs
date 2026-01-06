// Типы ошибок

use thiserror::Error;

#[derive(Error, Debug)]
pub enum ConstructError {
    #[error("Cryptography error: {0}")]
    CryptoError(String),

    #[error("Storage error: {0}")]
    StorageError(String),

    #[error("Network error: {0}")]
    NetworkError(String),

    #[error("Serialization error: {0}")]
    SerializationError(String),

    #[error("Validation error: {0}")]
    ValidationError(String),

    #[error("Session error: {0}")]
    SessionError(String),

    #[error("Not found: {0}")]
    NotFound(String),

    #[error("Invalid input: {0}")]
    InvalidInput(String),

    #[error("Internal error: {0}")]
    InternalError(String),

    #[error("WASM serialization error: {0}")]
    SerdeWasmError(String),
}

#[cfg(target_arch = "wasm32")]
impl From<serde_wasm_bindgen::Error> for ConstructError {
    fn from(error: serde_wasm_bindgen::Error) -> Self {
        ConstructError::SerdeWasmError(error.to_string())
    }
}


pub type Result<T> = std::result::Result<T, ConstructError>;

// Alias для совместимости
pub type MessengerError = ConstructError;

// Для WASM-биндингов
#[cfg(target_arch = "wasm32")]
impl From<ConstructError> for wasm_bindgen::JsValue {
    fn from(error: ConstructError) -> Self {
        wasm_bindgen::JsValue::from_str(&error.to_string())
    }
}
