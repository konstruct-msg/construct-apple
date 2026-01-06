// Wrapper для Rust WASM модуля
import init, * as wasm from '../wasm/construct_core';

export interface Contact {
  id: string;
  username: string;
}

export interface Message {
  id: string;
  from: string;
  to: string;
  content: string;
  timestamp: number;
  status: 'pending' | 'sent' | 'delivered' | 'read' | 'failed';
}

export interface Conversation {
  contact_id: string;
  messages: Message[];
  unread_count: number;
}

/**
 * Сервис для работы с Rust WASM мессенджером
 */
export class MessengerService {
  private stateId: string | null = null;
  private initialized = false;

  /**
   * Инициализировать WASM модуль
   */
  async initialize(dbName: string = 'construct-messenger'): Promise<void> {
    if (this.initialized) return;

    // Загрузить WASM модуль
    await init();

    // Создать AppState
    this.stateId = await wasm.create_app_state(dbName);
    this.initialized = true;

    console.log('✅ Messenger WASM initialized, state ID:', this.stateId);
  }

  private ensureInitialized(): string {
    if (!this.stateId) {
      throw new Error('Messenger not initialized. Call initialize() first.');
    }
    return this.stateId;
  }

  /**
   * Создать нового пользователя (только ключи в памяти, НЕ сохранять в IndexedDB)
   * UUID будет получен от сервера после RegisterSuccess
   * @param username - Имя пользователя
   * @param password - Мастер-пароль для шифрования ключей (min 8 символов, буквы + цифры)
   */
  async registerUser(username: string, password: string): Promise<void> {
    const stateId = this.ensureInitialized();
    await wasm.app_state_initialize_user(stateId, username, password);
  }

  /**
   * Завершить регистрацию после получения UUID от сервера
   * Сохраняет данные в IndexedDB с server UUID
   * @param serverUserId - UUID полученный от сервера
   * @param sessionToken - Session token от сервера
   * @param password - Мастер-пароль для шифрования ключей
   */
  async finalizeRegistration(serverUserId: string, sessionToken: string, password: string): Promise<void> {
    const stateId = this.ensureInitialized();
    await wasm.app_state_finalize_registration(stateId, serverUserId, sessionToken, password);
  }

  /**
   * Загрузить существующего пользователя
   * @param userId - ID пользователя
   * @param password - Мастер-пароль для расшифровки ключей
   */
  async loginUser(userId: string, password: string): Promise<void> {
    const stateId = this.ensureInitialized();
    await wasm.app_state_load_user(stateId, userId, password);
  }

  /**
   * Получить текущего пользователя
   */
  getCurrentUser(): { userId: string | undefined; username: string | undefined } {
    const stateId = this.ensureInitialized();
    return {
      userId: wasm.app_state_get_user_id(stateId),
      username: wasm.app_state_get_username(stateId),
    };
  }

  /**
   * Добавить контакт
   * @param contactId - UUID контакта
   * @param username - Имя контакта
   */
  async addContact(contactId: string, username: string): Promise<void> {
    const stateId = this.ensureInitialized();
    await wasm.app_state_add_contact(stateId, contactId, username);
  }

  /**
   * Получить список контактов
   */
  getContacts(): Contact[] {
    const stateId = this.ensureInitialized();
    const json = wasm.app_state_get_contacts(stateId);
    return JSON.parse(json);
  }

  /**
   * Отправить сообщение
   * @param toContactId - UUID получателя
   * @param sessionId - ID сессии Double Ratchet
   * @param text - Текст сообщения
   * @returns Message ID
   */
  async sendMessage(toContactId: string, sessionId: string, text: string): Promise<string> {
    const stateId = this.ensureInitialized();
    return await wasm.app_state_send_message(stateId, toContactId, sessionId, text);
  }

  /**
   * Загрузить беседу с контактом
   * @param contactId - UUID контакта
   */
  async loadConversation(contactId: string): Promise<Conversation> {
    const stateId = this.ensureInitialized();
    const json = await wasm.app_state_load_conversation(stateId, contactId);
    return JSON.parse(json);
  }

  /**
   * Подключиться к WebSocket серверу
   * @param serverUrl - URL сервера (ws://localhost:8080 или wss://example.com)
   */
  async connect(serverUrl: string): Promise<void> {
    const stateId = this.ensureInitialized();
    await wasm.app_state_connect(stateId, serverUrl);
  }

  /**
   * Дождаться подключения к серверу
   * @param timeoutMs - Таймаут в миллисекундах (по умолчанию 10 секунд)
   * @returns Promise который resolve когда состояние станет 'connected'
   * @throws Error если таймаут или ошибка подключения
   */
  async waitForConnection(timeoutMs: number = 10000): Promise<void> {
    this.ensureInitialized();
    const startTime = Date.now();

    return new Promise((resolve, reject) => {
      const checkConnection = () => {
        const state = this.getConnectionState();

        if (state === 'connected') {
          resolve();
          return;
        }

        if (state === 'error') {
          reject(new Error('Connection failed'));
          return;
        }

        if (Date.now() - startTime > timeoutMs) {
          reject(new Error(`Connection timeout after ${timeoutMs}ms`));
          return;
        }

        // Проверять каждые 100ms
        setTimeout(checkConnection, 100);
      };

      checkConnection();
    });
  }

  /**
   * Отключиться от сервера
   */
  async disconnect(): Promise<void> {
    const stateId = this.ensureInitialized();
    await wasm.app_state_disconnect(stateId);
  }

  /**
   * Получить состояние подключения
   */
  getConnectionState(): 'disconnected' | 'connecting' | 'connected' | 'reconnecting' | 'error' {
    const stateId = this.ensureInitialized();
    const state = wasm.app_state_connection_state(stateId);
    return state as any;
  }

  /**
   * Включить/выключить автоматическое переподключение
   * @param enabled - true для включения, false для выключения
   */
  setAutoReconnect(enabled: boolean): void {
    const stateId = this.ensureInitialized();
    wasm.app_state_set_auto_reconnect(stateId, enabled);
  }

  /**
   * Получить количество попыток переподключения
   * @returns Количество попыток
   */
  getReconnectAttempts(): number {
    const stateId = this.ensureInitialized();
    return wasm.app_state_reconnect_attempts(stateId);
  }

  /**
   * Сбросить счётчик попыток переподключения
   */
  resetReconnect(): void {
    const stateId = this.ensureInitialized();
    wasm.app_state_reset_reconnect(stateId);
  }

  /**
   * Зарегистрировать пользователя на сервере
   * Отправляет сообщение Register с username, password и registration bundle
   */
  registerOnServer(password: string): void {
    const stateId = this.ensureInitialized();
    wasm.app_state_register_on_server(stateId, password);
  }

  /**
   * Установить callback для события RegisterSuccess
   * Вызывается когда сервер подтверждает регистрацию
   */
  onRegisterSuccess(callback: (userId: string, sessionToken: string) => void): void {
    (window as any).__onRegisterSuccess = callback;
  }

  /**
   * Установить callback для события Error
   * Вызывается при ошибке от сервера
   */
  onServerError(callback: (code: string, message: string) => void): void {
    (window as any).__onServerError = callback;
  }

  /**
   * Уничтожить сервис
   */
  destroy(): void {
    if (this.stateId) {
      wasm.destroy_app_state(this.stateId);
      this.stateId = null;
      this.initialized = false;
    }
  }
}

// Singleton instance
export const messenger = new MessengerService();
