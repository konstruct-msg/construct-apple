//! Client API - High-level interface for cryptographic client
//!
//! Объединяет управление ключами + множественными сессиями в единый API.
//!
//! ## Архитектура
//!
//! ```text
//! Client
//!   ├── KeyManager         - долгосрочные ключи (identity, signed_prekey, signing)
//!   └── SessionManager     - множественные сессии с контактами
//!         └── Session      - X3DH + Double Ratchet
//! ```
//!
//! ## Типичный сценарий использования
//!
//! ### Регистрация
//! ```text
//! 1. client = Client::new()
//! 2. bundle = client.get_registration_bundle()
//! 3. Send bundle → Server
//! ```
//!
//! ### Инициация разговора (Alice)
//! ```text
//! 1. alice = Client::new()
//! 2. bob_bundle = alice.fetch_from_server("bob")
//! 3. alice.init_session("bob", bob_bundle)
//! 4. encrypted = alice.encrypt_message("bob", "Hello!")
//! 5. Send encrypted → Server → Bob
//! ```
//!
//! ### Получение сообщения (Bob)
//! ```text
//! 1. bob = Client::new()
//! 2. bob.init_receiving_session("alice", alice_identity, first_message)
//! 3. plaintext = bob.decrypt_message("alice", first_message)
//! ```
//!
//! ## Ответственность
//!
//! - Управление долгосрочными ключами
//! - Управление множественными сессиями
//! - Упрощённый API для приложения
//! - Rotation ключей
//!
//! ## Не отвечает за
//!
//! - Сетевой транспорт (это делает transport layer)
//! - Persistence ключей и сессий (это делает storage layer)
//! - UI/UX логика

use crate::crypto::handshake::{KeyAgreement, X3DHProtocol};
use crate::crypto::keys::KeyManager;
use crate::crypto::messaging::{double_ratchet::DoubleRatchetSession, SecureMessaging};
use crate::crypto::provider::CryptoProvider;
use crate::crypto::session_api::Session;
use std::collections::HashMap;
use std::marker::PhantomData;

/// High-level Client для работы с криптографией
///
/// Объединяет KeyManager (долгосрочные ключи) + SessionManager (множественные сессии).
///
/// ## Generics
///
/// - `P`: CryptoProvider - криптографический suite (Classic, Hybrid)
/// - `H`: KeyAgreement - handshake protocol (X3DH, PQ-X3DH)
/// - `M`: SecureMessaging - messaging protocol (Double Ratchet)
pub struct Client<P: CryptoProvider, H: KeyAgreement<P>, M: SecureMessaging<P>> {
    /// Управление долгосрочными ключами
    key_manager: KeyManager<P>,

    /// Активные сессии с контактами
    sessions: HashMap<String, Session<P, H, M>>,

    /// PhantomData для generic types
    _phantom: PhantomData<(P, H, M)>,
}

impl<P: CryptoProvider, H: KeyAgreement<P>, M: SecureMessaging<P>> Client<P, H, M>
where
    H::SharedSecret: AsRef<[u8]>,
{
    /// Создать нового клиента с новыми ключами
    ///
    /// Генерирует долгосрочные ключи:
    /// - Identity Key
    /// - Signed Prekey
    /// - Signing Key
    ///
    /// # Пример
    ///
    /// ```rust,ignore
    /// use construct_core::crypto::client_api::Client;
    /// use construct_core::crypto::handshake::x3dh::X3DHProtocol;
    /// use construct_core::crypto::messaging::double_ratchet::DoubleRatchetSession;
    /// use construct_core::crypto::suites::classic::ClassicSuiteProvider;
    ///
    /// type MyClient = Client<
    ///     ClassicSuiteProvider,
    ///     X3DHProtocol<ClassicSuiteProvider>,
    ///     DoubleRatchetSession<ClassicSuiteProvider>
    /// >;
    ///
    /// let client = MyClient::new()?;
    /// ```
    pub fn new() -> Result<Self, String> {
        let mut key_manager = KeyManager::<P>::new();
        key_manager
            .initialize()
            .map_err(|e| format!("Failed to initialize key manager: {:?}", e))?;

        Ok(Self {
            key_manager,
            sessions: HashMap::new(),
            _phantom: PhantomData,
        })
    }

    /// Создать Client с существующими ключами (для восстановления из storage)
    pub fn from_keys(
        identity_secret: Vec<u8>,
        signing_secret: Vec<u8>,
        prekey_secret: Vec<u8>,
        prekey_signature: Vec<u8>,
    ) -> Result<Self, String> {
        let mut key_manager = KeyManager::<P>::new();
        key_manager
            .initialize_from_keys(identity_secret, signing_secret, prekey_secret, prekey_signature)
            .map_err(|e| format!("Failed to initialize key manager from keys: {:?}", e))?;

        Ok(Self {
            key_manager,
            sessions: HashMap::new(),
            _phantom: PhantomData,
        })
    }

    /// Получить registration bundle для отправки на сервер
    ///
    /// Возвращает публичные ключи клиента для регистрации:
    /// - Identity Public Key
    /// - Signed Prekey Public Key
    /// - Signature над Signed Prekey
    /// - Verifying Key
    ///
    /// # Пример
    ///
    /// ```rust,ignore
    /// let bundle = client.get_registration_bundle()?;
    /// send_to_server(bundle);
    /// ```
    ///
    /// # ⚠️ ВАЖНО: Этот метод имеет архитектурную проблему
    ///
    /// TODO(ARCHITECTURE): Этот метод генерирует НОВЫЕ ключи вместо экспорта существующих!
    /// См. полное описание проблемы и решения: packages/core/ARCHITECTURE_TODOS.md
    ///
    /// ПРОБЛЕМА:
    /// - Вызывает статический метод H::generate_registration_bundle()
    /// - Генерирует совершенно новые ключи каждый раз
    /// - НЕ использует ключи из self.key_manager
    /// - Это означает, что bundle не соответствует ключам клиента!
    ///
    /// ПОЧЕМУ ТАК СДЕЛАНО:
    /// - KeyManager<P> не знает о generic типе H (handshake protocol)
    /// - KeyManager::export_registration_bundle() возвращает конкретный X3DHPublicKeyBundle
    /// - Но этот метод должен возвращать generic H::RegistrationBundle
    /// - Type mismatch делает невозможным использование KeyManager напрямую
    ///
    /// КАК ИСПОЛЬЗОВАТЬ СЕЙЧАС:
    /// - ⚠️ НЕ используйте этот метод для реального экспорта ключей!
    /// - Используйте напрямую: client.key_manager().export_registration_bundle()
    /// - Смотрите uniffi_bindings.rs:119 для примера
    ///
    /// КАК ИСПРАВИТЬ:
    /// 1. Сделать KeyManager<P, H: KeyAgreement<P>> - generic по handshake protocol
    /// 2. export_registration_bundle(&self) -> Result<H::RegistrationBundle>
    /// 3. Тогда этот метод сможет корректно вызывать key_manager.export_registration_bundle()
    ///
    /// Смотрите также: uniffi_bindings.rs:93-118 для полного описания проблемы и решений
    pub fn get_registration_bundle(&self) -> Result<H::RegistrationBundle, String> {
        H::generate_registration_bundle()
    }

    /// Инициировать сессию с контактом (Alice)
    ///
    /// Alice вызывает этот метод для начала разговора с Bob.
    ///
    /// # Процесс
    ///
    /// 1. Проверяет что сессии ещё нет
    /// 2. Получает свой identity public key
    /// 3. Создаёт Session::init_as_initiator()
    /// 4. Сохраняет сессию в sessions map
    ///
    /// # Параметры
    ///
    /// - `contact_id`: Идентификатор контакта (Bob)
    /// - `remote_bundle`: Bob's public key bundle (от сервера)
    /// - `remote_identity`: Bob's identity public key (от сервера)
    ///
    /// # Возвращает
    ///
    /// Session ID созданной сессии
    ///
    /// # Ошибки
    ///
    /// - "Session already exists" - сессия уже создана
    /// - Ошибки X3DH handshake
    /// - Ошибки Double Ratchet
    pub fn init_session(
        &mut self,
        contact_id: &str,
        remote_bundle: &H::PublicKeyBundle,
        remote_identity: &P::KemPublicKey,
    ) -> Result<String, String> {
        use tracing::info;

        // Check if session already exists
        if self.sessions.contains_key(contact_id) {
            return Err(format!(
                "Session already exists with contact: {}",
                contact_id
            ));
        }

        info!(
            target: "crypto::client",
            contact_id = %contact_id,
            "Initializing session as initiator"
        );

        // Get our identity private key
        let local_identity_priv = self
            .key_manager
            .identity_secret_key()
            .map_err(|e| format!("Failed to get identity key: {:?}", e))?;

        // Create session
        let session = Session::<P, H, M>::init_as_initiator(
            &local_identity_priv,
            remote_bundle,
            remote_identity,
            contact_id.to_string(),
        )?;

        let session_id = session.session_id().to_string();

        // Store session
        self.sessions.insert(contact_id.to_string(), session);

        info!(
            target: "crypto::client",
            contact_id = %contact_id,
            session_id = %session_id,
            "Session initialized successfully"
        );

        Ok(session_id)
    }

    /// Инициировать receiving сессию (Bob)
    ///
    /// Bob вызывает этот метод при получении первого сообщения от Alice.
    ///
    /// # Процесс
    ///
    /// 1. Проверяет что сессии ещё нет
    /// 2. Извлекает Alice's ephemeral key из сообщения
    /// 3. Создаёт Session::init_as_responder()
    /// 4. Сохраняет сессию
    ///
    /// # Параметры
    ///
    /// - `contact_id`: Идентификатор контакта (Alice)
    /// - `remote_identity`: Alice's identity public key (от сервера)
    /// - `first_message`: Первое зашифрованное сообщение от Alice
    ///
    /// # Возвращает
    ///
    /// Session ID созданной сессии
    pub fn init_receiving_session(
        &mut self,
        contact_id: &str,
        remote_identity: &P::KemPublicKey,
        first_message: &M::EncryptedMessage,
    ) -> Result<String, String> {
        use tracing::info;

        // Check if session already exists
        if self.sessions.contains_key(contact_id) {
            return Err(format!(
                "Session already exists with contact: {}",
                contact_id
            ));
        }

        info!(
            target: "crypto::client",
            contact_id = %contact_id,
            "Initializing session as responder"
        );

        // Extract remote ephemeral key from message
        // Note: This requires M::EncryptedMessage to provide access to dh_public_key
        // For DoubleRatchetSession, we know it has dh_public_key: [u8; 32]
        // But we can't access it generically. Let's add a parameter instead.

        Err("init_receiving_session requires remote_ephemeral parameter".to_string())
    }

    /// Инициировать receiving сессию с явным ephemeral key (Bob)
    ///
    /// Версия init_receiving_session где caller сам извлекает ephemeral key.
    ///
    /// # Параметры
    ///
    /// - `contact_id`: Идентификатор контакта (Alice)
    /// - `remote_identity`: Alice's identity public key
    /// - `remote_ephemeral`: Alice's ephemeral public key (из first_message.dh_public_key)
    /// - `first_message`: Первое зашифрованное сообщение
    ///
    /// # Возвращает
    ///
    /// Кортеж: (session_id, расшифрованный plaintext первого сообщения)
    pub fn init_receiving_session_with_ephemeral(
        &mut self,
        contact_id: &str,
        remote_identity: &P::KemPublicKey,
        remote_ephemeral: &P::KemPublicKey,
        first_message: &M::EncryptedMessage,
    ) -> Result<(String, Vec<u8>), String> {
        use tracing::info;

        // Check if session already exists
        if self.sessions.contains_key(contact_id) {
            return Err(format!(
                "Session already exists with contact: {}",
                contact_id
            ));
        }

        info!(
            target: "crypto::client",
            contact_id = %contact_id,
            "Initializing session as responder (with ephemeral)"
        );

        let local_identity = self
            .key_manager
            .identity_secret_key()
            .map_err(|e| format!("Failed to get identity key: {:?}", e))?;
        let local_signed_prekey = self
            .key_manager
            .current_signed_prekey()
            .map_err(|e| format!("Failed to get signed prekey: {:?}", e))?
            .key_pair
            .0
            .clone();

        // Create session and decrypt first message
        // ⚠️ ВАЖНО: init_as_responder теперь возвращает (session, plaintext)
        let (session, plaintext) = Session::<P, H, M>::init_as_responder(
            &local_identity,
            &local_signed_prekey,
            remote_identity,
            remote_ephemeral,
            first_message,
            contact_id.to_string(),
        )?;

        let session_id = session.session_id().to_string();

        // Store session
        self.sessions.insert(contact_id.to_string(), session);

        info!(
            target: "crypto::client",
            contact_id = %contact_id,
            session_id = %session_id,
            plaintext_len = %plaintext.len(),
            "Receiving session initialized and first message decrypted"
        );

        Ok((session_id, plaintext))
    }

    /// Зашифровать сообщение для контакта
    ///
    /// # Параметры
    ///
    /// - `contact_id`: Идентификатор получателя
    /// - `plaintext`: Данные для шифрования
    ///
    /// # Возвращает
    ///
    /// Зашифрованное сообщение для отправки
    ///
    /// # Ошибки
    ///
    /// - "No session with contact" - сессия не найдена
    /// - Ошибки шифрования
    pub fn encrypt_message(
        &mut self,
        contact_id: &str,
        plaintext: &[u8],
    ) -> Result<M::EncryptedMessage, String> {
        let session = self
            .sessions
            .get_mut(contact_id)
            .ok_or_else(|| format!("No session with contact: {}", contact_id))?;

        session.encrypt(plaintext)
    }

    /// Расшифровать сообщение от контакта
    ///
    /// # Параметры
    ///
    /// - `contact_id`: Идентификатор отправителя
    /// - `message`: Зашифрованное сообщение
    ///
    /// # Возвращает
    ///
    /// Расшифрованный plaintext
    ///
    /// # Ошибки
    ///
    /// - "No session with contact" - сессия не найдена
    /// - Ошибки расшифровки
    pub fn decrypt_message(
        &mut self,
        contact_id: &str,
        message: &M::EncryptedMessage,
    ) -> Result<Vec<u8>, String> {
        let session = self
            .sessions
            .get_mut(contact_id)
            .ok_or_else(|| format!("No session with contact: {}", contact_id))?;

        session.decrypt(message)
    }

    /// Проверить наличие сессии с контактом
    pub fn has_session(&self, contact_id: &str) -> bool {
        self.sessions.contains_key(contact_id)
    }

    /// Получить session ID для контакта
    pub fn get_session_id(&self, contact_id: &str) -> Option<String> {
        self.sessions
            .get(contact_id)
            .map(|s| s.session_id().to_string())
    }

    /// Удалить сессию с контактом
    pub fn remove_session(&mut self, contact_id: &str) -> bool {
        self.sessions.remove(contact_id).is_some()
    }

    /// Импортировать сессию из десериализованного состояния
    ///
    /// Используется для восстановления сессий из persistent storage (Keychain).
    ///
    /// # Параметры
    /// - `contact_id`: ID контакта
    /// - `messaging_session`: Восстановленная messaging session (Double Ratchet)
    ///
    /// # Возвращает
    /// Session ID восстановленной сессии
    pub fn import_session(&mut self, contact_id: &str, messaging_session: M) -> String {
        let session_id = messaging_session.session_id().to_string();

        let session = Session::from_messaging_session(
            contact_id.to_string(),
            messaging_session
        );

        self.sessions.insert(contact_id.to_string(), session);
        session_id
    }

    /// Получить количество активных сессий
    pub fn active_sessions_count(&self) -> usize {
        self.sessions.len()
    }

    /// Получить список контактов с активными сессиями
    pub fn active_contacts(&self) -> Vec<String> {
        self.sessions.keys().cloned().collect()
    }

    /// Rotate signed prekey
    ///
    /// Генерирует новый signed prekey и подпись.
    /// Старый prekey остаётся валидным до следующей rotation.
    pub fn rotate_prekey(&mut self) -> Result<(), String> {
        self.key_manager
            .rotate_signed_prekey()
            .map_err(|e| format!("Failed to rotate prekey: {:?}", e))
    }

    /// Cleanup старых skipped message keys во всех сессиях
    pub fn cleanup_all_skipped_keys(&mut self, max_age_seconds: i64) {
        for session in self.sessions.values_mut() {
            session.cleanup_old_skipped_keys(max_age_seconds);
        }
    }

    /// Получить изменяемую ссылку на KeyManager
    ///
    /// Для advanced использования
    pub fn key_manager_mut(&mut self) -> &mut KeyManager<P> {
        &mut self.key_manager
    }

    /// Получить неизменяемую ссылку на KeyManager
    ///
    /// Для advanced использования
    pub fn key_manager(&self) -> &KeyManager<P> {
        &self.key_manager
    }

    /// Получить изменяемую ссылку на сессию
    ///
    /// Для advanced использования
    pub fn get_session_mut(&mut self, contact_id: &str) -> Option<&mut Session<P, H, M>> {
        self.sessions.get_mut(contact_id)
    }

    /// Получить неизменяемую ссылку на сессию
    ///
    /// Для advanced использования
    pub fn get_session(&self, contact_id: &str) -> Option<&Session<P, H, M>> {
        self.sessions.get(contact_id)
    }
}

/// Convenience type alias для X3DH + Double Ratchet с Classic Suite
pub type ClassicClient<P> = Client<P, X3DHProtocol<P>, DoubleRatchetSession<P>>;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::handshake::x3dh::X3DHPublicKeyBundle;
    use crate::crypto::suites::classic::ClassicSuiteProvider;

    type TestClient = Client<
        ClassicSuiteProvider,
        X3DHProtocol<ClassicSuiteProvider>,
        DoubleRatchetSession<ClassicSuiteProvider>,
    >;

    #[test]
    fn test_client_creation() {
        let client = TestClient::new();
        assert!(client.is_ok());

        let client = client.unwrap();
        assert_eq!(client.active_sessions_count(), 0);
    }

    #[test]
    fn test_client_alice_bob_full_exchange() {
        // Alice and Bob create their clients
        let mut alice = TestClient::new().unwrap();
        let mut bob = TestClient::new().unwrap();

        // Bob's registration bundle
        let bob_identity_priv = bob.key_manager.identity_secret_key().unwrap();
        let bob_identity_pub =
            ClassicSuiteProvider::from_private_key_to_public_key(&bob_identity_priv).unwrap();

        let bob_prekey = bob.key_manager.current_signed_prekey().unwrap();
        let bob_bundle = X3DHPublicKeyBundle {
            identity_public: bob_identity_pub.clone(),
            signed_prekey_public: bob_prekey.key_pair.1.clone(),
            signature: bob_prekey.signature.clone(),
            verifying_key: bob.key_manager.verifying_key().unwrap().to_vec(),
            suite_id: 1,
        };

        // Alice initiates session with Bob
        let session_id = alice
            .init_session("bob", &bob_bundle, &bob_identity_pub)
            .unwrap();
        assert!(!session_id.is_empty());
        assert!(alice.has_session("bob"));
        assert_eq!(alice.active_sessions_count(), 1);

        // Alice sends first message
        let plaintext1 = b"Hello Bob!";
        let encrypted1 = alice.encrypt_message("bob", plaintext1).unwrap();

        // Bob extracts Alice's ephemeral key and initializes receiving session
        let alice_ephemeral_pub =
            ClassicSuiteProvider::kem_public_key_from_bytes(encrypted1.dh_public_key.to_vec());
        let alice_identity_priv = alice.key_manager.identity_secret_key().unwrap();
        let alice_identity_pub =
            ClassicSuiteProvider::from_private_key_to_public_key(&alice_identity_priv).unwrap();

        // NB: init_receiving_session_with_ephemeral теперь возвращает (session_id, plaintext)
        // Первое сообщение уже расшифровано!
        let (_session_id, decrypted1) = bob
            .init_receiving_session_with_ephemeral(
                "alice",
                &alice_identity_pub,
                &alice_ephemeral_pub,
                &encrypted1,
            )
            .unwrap();

        assert!(bob.has_session("alice"));

        // Verify first message was decrypted correctly
        assert_eq!(decrypted1, plaintext1);

        // Bob replies
        let plaintext2 = b"Hi Alice!";
        let encrypted2 = bob.encrypt_message("alice", plaintext2).unwrap();

        // Alice decrypts Bob's reply
        let decrypted2 = alice.decrypt_message("bob", &encrypted2).unwrap();
        assert_eq!(decrypted2, plaintext2);

        // Verify both have sessions
        assert_eq!(alice.active_contacts(), vec!["bob"]);
        assert_eq!(bob.active_contacts(), vec!["alice"]);
    }

    #[test]
    fn test_client_remove_session() {
        let mut alice = TestClient::new().unwrap();
        let bob = TestClient::new().unwrap();

        let bob_identity_priv = bob.key_manager.identity_secret_key().unwrap();
        let bob_identity_pub =
            ClassicSuiteProvider::from_private_key_to_public_key(&bob_identity_priv).unwrap();

        let bob_prekey = bob.key_manager.current_signed_prekey().unwrap();
        let bob_bundle = X3DHPublicKeyBundle {
            identity_public: bob_identity_pub.clone(),
            signed_prekey_public: bob_prekey.key_pair.1.clone(),
            signature: bob_prekey.signature.clone(),
            verifying_key: bob.key_manager.verifying_key().unwrap().to_vec(),
            suite_id: 1,
        };

        alice
            .init_session("bob", &bob_bundle, &bob_identity_pub)
            .unwrap();
        assert!(alice.has_session("bob"));

        // Remove session
        assert!(alice.remove_session("bob"));
        assert!(!alice.has_session("bob"));
        assert_eq!(alice.active_sessions_count(), 0);
    }
}
