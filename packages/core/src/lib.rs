// Construct Messenger Core
// Rust/WASM engine with end-to-end encryption

#![warn(clippy::all)]
#![allow(clippy::too_many_arguments)]

// UniFFI bindings for iOS/macOS
#[cfg(not(target_arch = "wasm32"))]
pub mod uniffi_bindings;

// Re-export UniFFI types at crate root so scaffolding can find them
#[cfg(not(target_arch = "wasm32"))]
pub use uniffi_bindings::{ClassicCryptoCore, CryptoError, EncryptedMessageComponents, RegistrationBundleJson, SessionInitResult, PrivateKeysJson, create_crypto_core, create_crypto_core_from_keys_json};

// Include UniFFI scaffolding generated from construct_core.udl
#[cfg(not(target_arch = "wasm32"))]
uniffi::include_scaffolding!("construct_core");

// Модули
pub mod api;
pub mod config;
pub mod crypto;
pub mod protocol;
pub mod storage;
pub mod state;
pub mod utils;
pub mod error;

// Re-exports для удобства
pub use api::MessengerAPI;

// WASM-specific bindings
#[cfg(target_arch = "wasm32")]
pub mod wasm;

