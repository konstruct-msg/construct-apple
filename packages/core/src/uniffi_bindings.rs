use crate::crypto::client_api::ClassicClient;
use crate::crypto::handshake::x3dh::X3DHPublicKeyBundle;
use crate::crypto::messaging::double_ratchet::EncryptedRatchetMessage;
use crate::crypto::provider::CryptoProvider;
use crate::crypto::suites::classic::ClassicSuiteProvider;
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};

// Wrapper for Client to make it work with UniFFI
// Note: We use UDL definition, not derive macro
// UniFFI wraps this in Arc automatically, so we only need Mutex here
pub struct ClassicCryptoCore {
    inner: Mutex<ClassicClient<ClassicSuiteProvider>>,
}

// Error type that matches UDL definition (flat errors)
// Note: We use UDL definition, not derive macro
#[derive(Debug, thiserror::Error)]
pub enum CryptoError {
    #[error("Initialization failed")]
    InitializationFailed,

    #[error("Session not found")]
    SessionNotFound,

    #[error("Session initialization failed")]
    SessionInitializationFailed,

    #[error("Encryption failed")]
    EncryptionFailed,

    #[error("Decryption failed")]
    DecryptionFailed,

    #[error("Invalid key data")]
    InvalidKeyData,

    #[error("Invalid ciphertext")]
    InvalidCiphertext,

    #[error("Serialization failed")]
    SerializationFailed,

    #[error("MessagePack deserialization failed - check format")]
    MessagePackDeserializationFailed,
}

// Registration bundle as JSON - matches UDL
// Note: We use UDL definition, not derive macro
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegistrationBundleJson {
    pub identity_public: String,
    pub signed_prekey_public: String,
    pub signature: String,
    pub verifying_key: String,
    pub suite_id: String,
}

// Encrypted message components for wire format (matches server ChatMessage)
// Note: We use UDL definition for UniFFI
#[derive(Debug, Clone)]
pub struct EncryptedMessageComponents {
    pub ephemeral_public_key: Vec<u8>,  // 32 bytes
    pub message_number: u32,
    pub content: String,  // Base64(nonce || ciphertext_with_tag)
}

// Session initialization result with decrypted first message
// Note: We use UDL definition for UniFFI
#[derive(Debug, Clone)]
pub struct SessionInitResult {
    pub session_id: String,
    pub decrypted_message: String,  // UTF-8 decoded plaintext
}

// Key bundle for session initialization
#[derive(Debug, Clone, Serialize, Deserialize)]
struct KeyBundle {
    identity_public: Vec<u8>,
    signed_prekey_public: Vec<u8>,
    signature: Vec<u8>,
    verifying_key: Vec<u8>,
    suite_id: u16,
}

// Private keys for persistence (exported via UDL)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrivateKeysJson {
    pub identity_secret: String,  // Base64
    pub signing_secret: String,   // Base64
    pub signed_prekey_secret: String,  // Base64
    pub prekey_signature: String, // Base64
    pub suite_id: String,
}

// UniFFI interface implementation (exported via UDL, not proc-macros)
impl ClassicCryptoCore {
    /// Export registration bundle as JSON string
    pub fn export_registration_bundle_json(&self) -> Result<String, CryptoError> {
        let client = self.inner.lock().unwrap();

        // TODO(ARCHITECTURE): Обходной путь для экспорта существующих ключей
        // См. подробное описание: packages/core/ARCHITECTURE_TODOS.md
        //
        // ПРОБЛЕМА:
        // - Client::get_registration_bundle() вызывает H::generate_registration_bundle()
        // - Это статический метод, который генерирует НОВЫЕ ключи каждый раз
        // - Нам нужны СУЩЕСТВУЮЩИЕ ключи из KeyManager
        // - KeyManager::export_registration_bundle() возвращает конкретный тип X3DHPublicKeyBundle
        // - Client::get_registration_bundle() возвращает generic H::RegistrationBundle
        //
        // ТЕКУЩЕЕ РЕШЕНИЕ (временное):
        // - Обходим Client::get_registration_bundle()
        // - Напрямую вызываем key_manager().export_registration_bundle()
        //
        // ПРАВИЛЬНОЕ РЕШЕНИЕ:
        // Вариант 1: Сделать KeyManager generic по протоколу handshake
        //   - KeyManager<P, H: KeyAgreement<P>>
        //   - export_registration_bundle() -> Result<H::RegistrationBundle>
        //
        // Вариант 2: Добавить метод в trait KeyAgreement
        //   - fn export_from_key_manager(km: &KeyManager<P>) -> Result<Self::RegistrationBundle>
        //
        // Вариант 3: Сделать Client::get_registration_bundle() не-generic
        //   - pub fn export_registration_bundle() -> Result<конкретный тип>
        //   - Но это нарушает generic design
        //
        // РЕКОМЕНДАЦИЯ: Вариант 1 - наиболее type-safe и правильный архитектурно
        let bundle = client.key_manager().export_registration_bundle()
            .map_err(|_| CryptoError::InitializationFailed)?;

        // Convert to base64 strings
        use base64::Engine;
        let json_bundle = RegistrationBundleJson {
            identity_public: base64::engine::general_purpose::STANDARD.encode(&bundle.identity_public),
            signed_prekey_public: base64::engine::general_purpose::STANDARD.encode(&bundle.signed_prekey_public),
            signature: base64::engine::general_purpose::STANDARD.encode(&bundle.signature),
            verifying_key: base64::engine::general_purpose::STANDARD.encode(&bundle.verifying_key),
            suite_id: bundle.suite_id.to_string(),
        };

        serde_json::to_string(&json_bundle)
            .map_err(|_| CryptoError::SerializationFailed)
    }

    /// Export private keys as JSON string for persistence
    /// SECURITY: Only call this method to store keys in secure storage (Keychain)
    pub fn export_private_keys_json(&self) -> Result<String, CryptoError> {
        let client = self.inner.lock().unwrap();

        // Get private keys from key manager
        let identity_secret = client.key_manager().identity_secret_key()
            .map_err(|_| CryptoError::InvalidKeyData)?;
        let signing_secret = client.key_manager().signing_secret_key()
            .map_err(|_| CryptoError::InvalidKeyData)?;
        let prekey = client.key_manager().current_signed_prekey()
            .map_err(|_| CryptoError::InvalidKeyData)?;

        // Convert to bytes - use AsRef<[u8]> trait bound
        let identity_bytes: Vec<u8> = <_ as AsRef<[u8]>>::as_ref(identity_secret).to_vec();
        let signing_bytes: Vec<u8> = <_ as AsRef<[u8]>>::as_ref(signing_secret).to_vec();
        let prekey_secret_bytes: Vec<u8> = <_ as AsRef<[u8]>>::as_ref(&prekey.key_pair.0).to_vec();

        // Encode to base64
        use base64::Engine;
        let private_keys_json = PrivateKeysJson {
            identity_secret: base64::engine::general_purpose::STANDARD.encode(&identity_bytes),
            signing_secret: base64::engine::general_purpose::STANDARD.encode(&signing_bytes),
            signed_prekey_secret: base64::engine::general_purpose::STANDARD.encode(&prekey_secret_bytes),
            prekey_signature: base64::engine::general_purpose::STANDARD.encode(&prekey.signature),
            suite_id: "1".to_string(),
        };

        serde_json::to_string(&private_keys_json)
            .map_err(|_| CryptoError::SerializationFailed)
    }

    /// Initialize a session with a contact
    pub fn init_session(
        &self,
        contact_id: String,
        recipient_bundle: Vec<u8>,
    ) -> Result<String, CryptoError> {
        let bundle_str = std::str::from_utf8(&recipient_bundle)
            .map_err(|_| CryptoError::InvalidKeyData)?;

        let key_bundle: KeyBundle = serde_json::from_str(bundle_str)
            .map_err(|_| CryptoError::InvalidKeyData)?;

        // Create X3DHPublicKeyBundle
        let public_bundle = X3DHPublicKeyBundle {
            identity_public: key_bundle.identity_public.clone(),
            signed_prekey_public: key_bundle.signed_prekey_public.clone(),
            signature: key_bundle.signature.clone(),
            verifying_key: key_bundle.verifying_key.clone(),
            suite_id: key_bundle.suite_id,
        };

        // Extract remote identity public key
        let remote_identity = ClassicSuiteProvider::kem_public_key_from_bytes(
            key_bundle.identity_public.clone()
        );

        tracing::debug!(
            "Alice init_session - remote_identity (Bob): {}",
            hex::encode(&key_bundle.identity_public)
        );

        let mut client = self.inner.lock().unwrap();

        // Log local keys for debugging (sender side)
        let local_bundle = client.key_manager().export_registration_bundle()
            .map_err(|_| CryptoError::InitializationFailed)?;
        eprintln!("🔑 Bob (sender) local keys during init_session:");
        eprintln!("   Local identity (hex): {}", hex::encode(&local_bundle.identity_public));
        eprintln!("   Remote identity (hex): {}", hex::encode(&key_bundle.identity_public));

        // Initialize the session (returns internal session_id which we ignore)
        client.init_session(&contact_id, &public_bundle, &remote_identity)
            .map_err(|_| CryptoError::SessionInitializationFailed)?;

        // Return contact_id as the session identifier for Swift
        // Sessions are looked up by contact_id, not by the internal random session_id
        Ok(contact_id)
    }

    /// Initialize a receiving session (for responder) with first message
    ///
    /// Returns SessionInitResult with session_id and decrypted first message
    pub fn init_receiving_session(
        &self,
        contact_id: String,
        recipient_bundle: Vec<u8>,
        first_message: Vec<u8>,
    ) -> Result<SessionInitResult, CryptoError> {
        tracing::debug!("init_receiving_session called for contact: {}", contact_id);

        // Parse recipient bundle JSON
        let bundle_str = std::str::from_utf8(&recipient_bundle)
            .map_err(|_| CryptoError::InvalidKeyData)?;

        let key_bundle: KeyBundle = serde_json::from_str(bundle_str)
            .map_err(|_| CryptoError::InvalidKeyData)?;

        tracing::debug!("Parsed key bundle, suite_id: {}", key_bundle.suite_id);

        // Parse first message JSON
        let message_str = std::str::from_utf8(&first_message)
            .map_err(|_| CryptoError::InvalidCiphertext)?;

        #[derive(Deserialize)]
        struct FirstMessage {
            ephemeral_public_key: Vec<u8>,
            message_number: u32,
            content: String,  // Base64
        }

        let first_msg: FirstMessage = serde_json::from_str(message_str)
            .map_err(|_| CryptoError::InvalidCiphertext)?;

        // Decode base64 content
        let sealed_box = base64::engine::general_purpose::STANDARD
            .decode(&first_msg.content)
            .map_err(|_| CryptoError::InvalidCiphertext)?;

        tracing::debug!("Parsing sealed_box - total length: {}", sealed_box.len());

        // Extract nonce (first 12 bytes) and ciphertext (rest)
        if sealed_box.len() < 12 {
            return Err(CryptoError::InvalidCiphertext);
        }
        let nonce = sealed_box[..12].to_vec();
        let ciphertext = sealed_box[12..].to_vec();

        tracing::debug!(
            "Extracted components - nonce length: {}, ciphertext length: {}",
            nonce.len(),
            ciphertext.len()
        );

        // Convert ephemeral_public_key to [u8; 32]
        let dh_public_key: [u8; 32] = first_msg.ephemeral_public_key.clone()
            .try_into()
            .map_err(|_| CryptoError::InvalidKeyData)?;

        // Create EncryptedRatchetMessage
        let encrypted_first_message = EncryptedRatchetMessage {
            dh_public_key,
            message_number: first_msg.message_number,
            ciphertext,
            nonce,
            previous_chain_length: 0,
            suite_id: key_bundle.suite_id,
        };

        // Extract keys for session initialization
        let remote_identity = ClassicSuiteProvider::kem_public_key_from_bytes(
            key_bundle.identity_public.clone()
        );

        let remote_ephemeral = ClassicSuiteProvider::kem_public_key_from_bytes(
            first_msg.ephemeral_public_key.clone()
        );

        tracing::debug!(
            "Bob receiving session - remote_identity: {}, remote_ephemeral: {}, dh_public_key: {}",
            hex::encode(&key_bundle.identity_public),
            hex::encode(&first_msg.ephemeral_public_key),
            hex::encode(&encrypted_first_message.dh_public_key)
        );

        let mut client = self.inner.lock().unwrap();

        // Log local keys for debugging
        let local_bundle = client.key_manager().export_registration_bundle()
            .map_err(|_| CryptoError::InitializationFailed)?;
        eprintln!("🔑 Alice (receiver) local keys:");
        eprintln!("   Local identity (hex): {}", hex::encode(&local_bundle.identity_public));
        eprintln!("   Local signed prekey (hex): {}", hex::encode(&local_bundle.signed_prekey_public));

        let (_internal_session_id, plaintext_bytes) = client.init_receiving_session_with_ephemeral(
            &contact_id,
            &remote_identity,
            &remote_ephemeral,
            &encrypted_first_message,
        )
        .map_err(|e| {
            // Use eprintln! to ensure error is visible even if tracing is not initialized
            eprintln!("❌ RUST ERROR: init_receiving_session_with_ephemeral failed: {}", e);
            eprintln!("   Contact ID: {}", contact_id);
            eprintln!("   Remote identity (hex): {}", hex::encode(&key_bundle.identity_public));
            eprintln!("   Remote ephemeral (hex): {}", hex::encode(&first_msg.ephemeral_public_key));
            eprintln!("   Message number: {}", first_msg.message_number);
            tracing::error!("init_receiving_session_with_ephemeral failed: {:?}", e);
            CryptoError::SessionInitializationFailed
        })?;

        // Convert plaintext bytes to UTF-8 string
        let decrypted_message = String::from_utf8(plaintext_bytes)
            .map_err(|_| CryptoError::DecryptionFailed)?;

        tracing::info!("Session initialized, plaintext length: {}", decrypted_message.len());

        // Return contact_id as session_id for Swift (sessions are looked up by contact_id)
        Ok(SessionInitResult {
            session_id: contact_id,
            decrypted_message,
        })
    }

    /// Encrypt a message for a session - returns wire format components
    pub fn encrypt_message(
        &self,
        session_id: String,
        plaintext: String,
    ) -> Result<EncryptedMessageComponents, CryptoError> {
        let mut client = self.inner.lock().unwrap();

        // Note: session_id from Swift is actually contact_id in our new API
        let contact_id = &session_id;

        let encrypted_message = client
            .encrypt_message(contact_id, plaintext.as_bytes())
            .map_err(|_| CryptoError::EncryptionFailed)?;

        tracing::debug!(
            "Alice encrypt_message - dh_public_key: {}, message_number: {}, nonce_len: {}, ciphertext_len: {}",
            hex::encode(&encrypted_message.dh_public_key),
            encrypted_message.message_number,
            encrypted_message.nonce.len(),
            encrypted_message.ciphertext.len()
        );

        // Create sealed box: nonce || ciphertext_with_tag
        let mut sealed_box = Vec::new();
        sealed_box.extend_from_slice(&encrypted_message.nonce);
        sealed_box.extend_from_slice(&encrypted_message.ciphertext);

        Ok(EncryptedMessageComponents {
            ephemeral_public_key: encrypted_message.dh_public_key.to_vec(),
            message_number: encrypted_message.message_number,
            content: base64::engine::general_purpose::STANDARD.encode(&sealed_box),
        })
    }

    /// Decrypt a message from a session - accepts wire format components
    pub fn decrypt_message(
        &self,
        session_id: String,
        ephemeral_public_key: Vec<u8>,
        message_number: u32,
        content: String,
    ) -> Result<String, CryptoError> {
        // Decode base64 sealed box
        let sealed_box = base64::engine::general_purpose::STANDARD
            .decode(&content)
            .map_err(|_| CryptoError::InvalidCiphertext)?;

        // Extract nonce (first 12 bytes) and ciphertext (rest)
        if sealed_box.len() < 12 {
            return Err(CryptoError::InvalidCiphertext);
        }
        let nonce = sealed_box[..12].to_vec();
        let ciphertext = sealed_box[12..].to_vec();

        // Convert ephemeral_public_key to [u8; 32]
        let dh_public_key: [u8; 32] = ephemeral_public_key
            .try_into()
            .map_err(|_| CryptoError::InvalidKeyData)?;

        // Reconstruct EncryptedRatchetMessage
        let encrypted_message = EncryptedRatchetMessage {
            dh_public_key,
            message_number,
            ciphertext,
            nonce,
            previous_chain_length: 0,  // Not used by decryption
            suite_id: crate::config::Config::global().classic_suite_id,
        };

        // Note: session_id from Swift is actually contact_id in our new API
        let contact_id = &session_id;

        let mut client = self.inner.lock().unwrap();
        let plaintext_bytes = client
            .decrypt_message(contact_id, &encrypted_message)
            .map_err(|_| CryptoError::DecryptionFailed)?;

        String::from_utf8(plaintext_bytes)
            .map_err(|_| CryptoError::DecryptionFailed)
    }

    /// Deletes a session for a contact, allowing a new one to be created.
    pub fn remove_session(&self, contact_id: String) -> bool {
        let mut client = self.inner.lock().unwrap();
        client.remove_session(&contact_id)
    }
}

/// Create a new CryptoCore instance (exported via UDL)
/// UniFFI automatically wraps this in Arc<>, so we return Arc<ClassicCryptoCore>
pub fn create_crypto_core() -> Result<Arc<ClassicCryptoCore>, CryptoError> {
    // Инициализировать конфигурацию при первом вызове
    let _ = crate::config::Config::init();

    let client = ClassicClient::<ClassicSuiteProvider>::new()
        .map_err(|_| CryptoError::InitializationFailed)?;

    Ok(Arc::new(ClassicCryptoCore {
        inner: Mutex::new(client),
    }))
}

/// Create a CryptoCore instance from existing private keys (exported via UDL)
/// Used to restore cryptographic state from secure storage (e.g., iOS Keychain)
pub fn create_crypto_core_from_keys_json(keys_json: String) -> Result<Arc<ClassicCryptoCore>, CryptoError> {
    // Инициализировать конфигурацию при первом вызове
    let _ = crate::config::Config::init();

    // Parse JSON
    let private_keys: PrivateKeysJson = serde_json::from_str(&keys_json)
        .map_err(|_| CryptoError::SerializationFailed)?;

    // Decode base64 to bytes
    use base64::Engine;
    let identity_secret = base64::engine::general_purpose::STANDARD.decode(&private_keys.identity_secret)
        .map_err(|_| CryptoError::InvalidKeyData)?;
    let signing_secret = base64::engine::general_purpose::STANDARD.decode(&private_keys.signing_secret)
        .map_err(|_| CryptoError::InvalidKeyData)?;
    let prekey_secret = base64::engine::general_purpose::STANDARD.decode(&private_keys.signed_prekey_secret)
        .map_err(|_| CryptoError::InvalidKeyData)?;
    let prekey_signature = base64::engine::general_purpose::STANDARD.decode(&private_keys.prekey_signature)
        .map_err(|_| CryptoError::InvalidKeyData)?;

    // Create client from keys
    let client = ClassicClient::<ClassicSuiteProvider>::from_keys(
        identity_secret,
        signing_secret,
        prekey_secret,
        prekey_signature,
    ).map_err(|_| CryptoError::InitializationFailed)?;

    eprintln!("✅ CryptoCore restored from saved keys");

    Ok(Arc::new(ClassicCryptoCore {
        inner: Mutex::new(client),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::handshake::x3dh::X3DHPublicKeyBundle;

    /// Helper to convert RegistrationBundleJson to KeyBundle format
    fn convert_bundle_for_init(bundle_json: &str) -> Vec<u8> {
        use base64::Engine;

        #[derive(serde::Deserialize)]
        struct RegBundle {
            identity_public: String,
            signed_prekey_public: String,
            signature: String,
            verifying_key: String,
            suite_id: String,
        }

        let bundle: RegBundle = serde_json::from_str(bundle_json).unwrap();

        // Convert base64 to bytes
        let identity_pub = base64::engine::general_purpose::STANDARD.decode(&bundle.identity_public).unwrap();
        let signed_prekey = base64::engine::general_purpose::STANDARD.decode(&bundle.signed_prekey_public).unwrap();
        let signature = base64::engine::general_purpose::STANDARD.decode(&bundle.signature).unwrap();
        let verifying_key = base64::engine::general_purpose::STANDARD.decode(&bundle.verifying_key).unwrap();
        let suite_id: u16 = bundle.suite_id.parse().unwrap();

        // Create KeyBundle and serialize it properly
        let key_bundle = KeyBundle {
            identity_public: identity_pub,
            signed_prekey_public: signed_prekey,
            signature,
            verifying_key,
            suite_id,
        };

        serde_json::to_vec(&key_bundle).unwrap()
    }

    /// Test that verifies session_id returned from init_session is the contact_id
    /// This ensures the bug where random UUID was returned is fixed
    #[test]
    fn test_init_session_returns_contact_id() {
        let alice = create_crypto_core().unwrap();
        let bob = create_crypto_core().unwrap();

        // Get Bob's registration bundle and convert it
        let bob_bundle_json = bob.export_registration_bundle_json().unwrap();
        let bob_bundle_bytes = convert_bundle_for_init(&bob_bundle_json);

        // Alice initializes session with Bob
        let contact_id = "bob_user_id_123".to_string();
        let session_id = alice.init_session(contact_id.clone(), bob_bundle_bytes).unwrap();

        // CRITICAL: session_id should equal contact_id
        assert_eq!(session_id, contact_id,
            "init_session must return contact_id as session_id for Swift compatibility");
    }

    /// Test full end-to-end encryption/decryption flow
    /// Verifies that sessions are created consistently and messages can be exchanged
    #[test]
    fn test_full_e2e_encryption_flow() {
        let alice = create_crypto_core().unwrap();
        let bob = create_crypto_core().unwrap();

        // Get registration bundles and convert them
        let alice_bundle_json = alice.export_registration_bundle_json().unwrap();
        let alice_bundle_bytes = convert_bundle_for_init(&alice_bundle_json);

        let bob_bundle_json = bob.export_registration_bundle_json().unwrap();
        let bob_bundle_bytes = convert_bundle_for_init(&bob_bundle_json);

        // Alice initializes session with Bob
        let alice_to_bob_session = alice.init_session(
            "bob_user_id".to_string(),
            bob_bundle_bytes
        ).unwrap();

        assert_eq!(alice_to_bob_session, "bob_user_id",
            "Alice's session_id for Bob should be bob's user_id");

        // Alice encrypts a message for Bob
        let plaintext = "Hello Bob!".to_string();
        let encrypted = alice.encrypt_message(
            alice_to_bob_session.clone(),
            plaintext.clone()
        ).unwrap();

        // Verify encrypted message has required components
        assert!(!encrypted.ephemeral_public_key.is_empty(), "Ephemeral key should not be empty");
        assert!(!encrypted.content.is_empty(), "Content should not be empty");
        assert_eq!(encrypted.message_number, 0, "First message should have message_number 0");

        // Bob initializes receiving session with Alice's first message
        let first_msg_json = serde_json::json!({
            "ephemeral_public_key": encrypted.ephemeral_public_key,
            "message_number": encrypted.message_number,
            "content": encrypted.content
        });
        let first_msg_bytes = serde_json::to_vec(&first_msg_json).unwrap();

        let bob_session_result = bob.init_receiving_session(
            "alice_user_id".to_string(),
            alice_bundle_bytes,
            first_msg_bytes
        ).unwrap();

        // CRITICAL: Bob's session_id should be alice_user_id
        assert_eq!(bob_session_result.session_id, "alice_user_id",
            "Bob's session_id for Alice should be alice's user_id");

        // First message should be decrypted automatically
        assert_eq!(bob_session_result.decrypted_message, plaintext,
            "First message should be decrypted correctly by init_receiving_session");

        // Bob encrypts a reply
        let reply_plaintext = "Hi Alice!".to_string();
        let reply_encrypted = bob.encrypt_message(
            bob_session_result.session_id.clone(),
            reply_plaintext.clone()
        ).unwrap();

        assert_eq!(reply_encrypted.message_number, 0,
            "Bob's first message should also have message_number 0");

        // Alice decrypts Bob's reply
        let decrypted_reply = alice.decrypt_message(
            alice_to_bob_session,
            reply_encrypted.ephemeral_public_key,
            reply_encrypted.message_number,
            reply_encrypted.content
        ).unwrap();

        assert_eq!(decrypted_reply, reply_plaintext,
            "Alice should decrypt Bob's reply correctly");
    }

    /// Test that encryption fails with proper error when session doesn't exist
    #[test]
    fn test_encrypt_without_session_fails() {
        let alice = create_crypto_core().unwrap();

        let result = alice.encrypt_message(
            "nonexistent_user".to_string(),
            "test message".to_string()
        );

        assert!(result.is_err(), "Encryption should fail when session doesn't exist");
        match result {
            Err(CryptoError::EncryptionFailed) => {}, // Expected
            _ => panic!("Should return EncryptionFailed error"),
        }
    }

    /// Test session attribute consistency
    /// Verifies that both participants have matching session attributes
    #[test]
    fn test_session_attribute_consistency() {
        let alice = create_crypto_core().unwrap();
        let bob = create_crypto_core().unwrap();

        let bob_bundle_json = bob.export_registration_bundle_json().unwrap();
        let alice_bundle_json = alice.export_registration_bundle_json().unwrap();

        // Convert bundles to KeyBundle format
        let bob_bundle_bytes = convert_bundle_for_init(&bob_bundle_json);
        let alice_bundle_bytes = convert_bundle_for_init(&alice_bundle_json);

        // Alice initializes session
        let alice_session_id = alice.init_session(
            "bob_contact".to_string(),
            bob_bundle_bytes
        ).unwrap();

        // Alice sends first message
        let msg1 = alice.encrypt_message(
            alice_session_id.clone(),
            "Test message".to_string()
        ).unwrap();

        // Bob initializes receiving session
        let first_msg_json = serde_json::json!({
            "ephemeral_public_key": msg1.ephemeral_public_key,
            "message_number": msg1.message_number,
            "content": msg1.content
        });

        let bob_session_result = bob.init_receiving_session(
            "alice_contact".to_string(),
            alice_bundle_bytes,
            serde_json::to_vec(&first_msg_json).unwrap()
        ).unwrap();

        // Verify session IDs are the contact IDs
        assert_eq!(alice_session_id, "bob_contact");
        assert_eq!(bob_session_result.session_id, "alice_contact");

        // Both should be able to continue communication
        let msg2 = bob.encrypt_message(
            bob_session_result.session_id.clone(),
            "Reply".to_string()
        ).unwrap();

        let decrypted = alice.decrypt_message(
            alice_session_id,
            msg2.ephemeral_public_key,
            msg2.message_number,
            msg2.content
        ).unwrap();

        assert_eq!(decrypted, "Reply");
    }

    /// Simple test using Client API directly (bypassing UniFFI)
    #[test]
    fn test_direct_client_api_e2e() {
        use crate::crypto::client_api::Client;
        use crate::crypto::handshake::x3dh::X3DHProtocol;
        use crate::crypto::messaging::double_ratchet::DoubleRatchetSession;
        use crate::crypto::suites::classic::ClassicSuiteProvider;

        type TestClient = Client<ClassicSuiteProvider, X3DHProtocol<ClassicSuiteProvider>, DoubleRatchetSession<ClassicSuiteProvider>>;

        // Create Alice and Bob
        let mut alice = TestClient::new().unwrap();
        let mut bob = TestClient::new().unwrap();

        eprintln!("\n[DIRECT TEST] Creating clients...");

        // Get bundles
        let alice_bundle = alice.key_manager().export_registration_bundle().unwrap();
        let bob_bundle = bob.key_manager().export_registration_bundle().unwrap();

        eprintln!("[DIRECT TEST] Alice identity: {}", hex::encode(&alice_bundle.identity_public));
        eprintln!("[DIRECT TEST] Bob identity: {}", hex::encode(&bob_bundle.identity_public));

        // Alice creates session with Bob
        let alice_identity_pub = ClassicSuiteProvider::kem_public_key_from_bytes(alice_bundle.identity_public.clone());
        let bob_identity_pub = ClassicSuiteProvider::kem_public_key_from_bytes(bob_bundle.identity_public.clone());

        alice.init_session("bob", &bob_bundle, &bob_identity_pub).unwrap();
        eprintln!("[DIRECT TEST] Alice created session with Bob");

        // Alice encrypts message
        let plaintext1 = b"Hello Bob!";
        let encrypted1 = alice.encrypt_message("bob", plaintext1).unwrap();
        eprintln!("[DIRECT TEST] Alice encrypted message, dh_key: {}", hex::encode(&encrypted1.dh_public_key));

        // Bob creates receiving session
        let alice_ephemeral_pub = ClassicSuiteProvider::kem_public_key_from_bytes(encrypted1.dh_public_key.to_vec());

        let (_session_id, decrypted1) = bob.init_receiving_session_with_ephemeral(
            "alice",
            &alice_identity_pub,
            &alice_ephemeral_pub,
            &encrypted1,
        ).unwrap();

        eprintln!("[DIRECT TEST] Bob received and decrypted!");
        assert_eq!(decrypted1, plaintext1);
        eprintln!("[DIRECT TEST] ✅ Direct Client API test PASSED!");
    }

    /// Test that mimics UniFFI flow but uses EncryptedMessageComponents
    #[test]
    fn test_uniffi_flow_with_components() {
        use crate::crypto::client_api::Client;
        use crate::crypto::handshake::x3dh::X3DHProtocol;
        use crate::crypto::messaging::double_ratchet::{DoubleRatchetSession, EncryptedRatchetMessage};
        use crate::crypto::suites::classic::ClassicSuiteProvider;

        type TestClient = Client<ClassicSuiteProvider, X3DHProtocol<ClassicSuiteProvider>, DoubleRatchetSession<ClassicSuiteProvider>>;

        // Create Alice and Bob
        let mut alice = TestClient::new().unwrap();
        let mut bob = TestClient::new().unwrap();

        eprintln!("\n[UNIFFI FLOW TEST] Creating clients...");

        // Get bundles
        let alice_bundle = alice.key_manager().export_registration_bundle().unwrap();
        let bob_bundle = bob.key_manager().export_registration_bundle().unwrap();

        let alice_identity_pub = ClassicSuiteProvider::kem_public_key_from_bytes(alice_bundle.identity_public.clone());
        let bob_identity_pub = ClassicSuiteProvider::kem_public_key_from_bytes(bob_bundle.identity_public.clone());

        // Alice creates session with Bob
        alice.init_session("bob", &bob_bundle, &bob_identity_pub).unwrap();

        // Alice encrypts message
        let plaintext1 = b"Hello Bob!";
        let encrypted1 = alice.encrypt_message("bob", plaintext1).unwrap();

        eprintln!("[UNIFFI FLOW TEST] Alice encrypted:");
        eprintln!("  dh_public_key: {}", hex::encode(&encrypted1.dh_public_key));
        eprintln!("  nonce len: {}", encrypted1.nonce.len());
        eprintln!("  ciphertext len: {}", encrypted1.ciphertext.len());
        eprintln!("  suite_id: {}", encrypted1.suite_id);

        // Mimic UniFFI: create sealed box
        let mut sealed_box = Vec::new();
        sealed_box.extend_from_slice(&encrypted1.nonce);
        sealed_box.extend_from_slice(&encrypted1.ciphertext);

        eprintln!("[UNIFFI FLOW TEST] Sealed box length: {}", sealed_box.len());

        // Mimic UniFFI: extract nonce and ciphertext
        let nonce_parsed = sealed_box[..12].to_vec();
        let ciphertext_parsed = sealed_box[12..].to_vec();

        eprintln!("[UNIFFI FLOW TEST] After parsing:");
        eprintln!("  nonce len: {}", nonce_parsed.len());
        eprintln!("  ciphertext len: {}", ciphertext_parsed.len());

        // Mimic UniFFI: reconstruct EncryptedRatchetMessage
        let reconstructed_message = EncryptedRatchetMessage {
            dh_public_key: encrypted1.dh_public_key,
            message_number: encrypted1.message_number,
            ciphertext: ciphertext_parsed,
            nonce: nonce_parsed,
            previous_chain_length: 0,
            suite_id: alice_bundle.suite_id,  // Use Alice's bundle suite_id
        };

        eprintln!("[UNIFFI FLOW TEST] Reconstructed message:");
        eprintln!("  dh_public_key: {}", hex::encode(&reconstructed_message.dh_public_key));
        eprintln!("  suite_id: {}", reconstructed_message.suite_id);

        // Bob creates receiving session with RECONSTRUCTED message
        let alice_ephemeral_pub = ClassicSuiteProvider::kem_public_key_from_bytes(reconstructed_message.dh_public_key.to_vec());

        let result = bob.init_receiving_session_with_ephemeral(
            "alice",
            &alice_identity_pub,
            &alice_ephemeral_pub,
            &reconstructed_message,
        );

        match &result {
            Ok(_) => eprintln!("[UNIFFI FLOW TEST] ✅ PASSED!"),
            Err(e) => eprintln!("[UNIFFI FLOW TEST] ❌ FAILED: {}", e),
        }

        let (_session_id, decrypted1) = result.unwrap();
        assert_eq!(decrypted1, plaintext1);
    }
}
