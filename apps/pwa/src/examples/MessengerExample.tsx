import { useState } from 'react';
import { useMessenger } from '../hooks/useMessenger';

/**
 * Пример использования Rust WASM мессенджера в React
 */
export function MessengerExample() {
  const {
    initialized,
    loading,
    error,
    currentUser,
    contacts,
    connectionState,
    register,
    login,
    addContact,
    sendMessage,
    connect,
  } = useMessenger();

  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [userId, setUserId] = useState('');
  const [isRegistering, setIsRegistering] = useState(true);
  const [serverUrl, setServerUrl] = useState('ws://localhost:8080');

  // Регистрация/Вход
  const handleAuth = async () => {
    try {
      if (isRegistering) {
        const newUserId = await register(username, password);
        alert(`✅ Пользователь создан!\nID: ${newUserId}\n\nСохраните этот ID для входа!`);
      } else {
        await login(userId, password);
        alert('✅ Вход выполнен!');
      }
    } catch (err) {
      console.error('Auth error:', err);
    }
  };

  // Подключение к серверу
  const handleConnect = async () => {
    try {
      await connect(serverUrl);
      alert('✅ Подключено к серверу!');
    } catch (err) {
      console.error('Connection error:', err);
    }
  };

  // Добавить контакт
  const handleAddContact = async () => {
    const contactId = prompt('Введите UUID контакта:');
    const contactName = prompt('Введите имя контакта:');
    if (contactId && contactName) {
      try {
        await addContact(contactId, contactName);
        alert('✅ Контакт добавлен!');
      } catch (err) {
        console.error('Add contact error:', err);
      }
    }
  };

  // Отправить сообщение
  const handleSendMessage = async (contactId: string) => {
    const text = prompt('Введите сообщение:');
    if (text) {
      try {
        // TODO: В реальном приложении нужно получить sessionId из сессии с контактом
        const sessionId = contactId; // Упрощенно
        await sendMessage(contactId, sessionId, text);
        alert('✅ Сообщение отправлено!');
      } catch (err) {
        console.error('Send message error:', err);
      }
    }
  };

  if (!initialized) {
    return <div>⏳ Загрузка WASM модуля...</div>;
  }

  return (
    <div style={{ padding: '20px', maxWidth: '600px', margin: '0 auto' }}>
      <h1>🔐 Construct Messenger (Rust WASM)</h1>

      {error && (
        <div style={{ padding: '10px', background: '#fee', border: '1px solid #f00', marginBottom: '20px' }}>
          ❌ Ошибка: {error}
        </div>
      )}

      {/* Статус */}
      <div style={{ marginBottom: '20px', padding: '10px', background: '#f0f0f0' }}>
        <div><strong>Пользователь:</strong> {currentUser.username || 'Не авторизован'}</div>
        <div><strong>User ID:</strong> {currentUser.userId || '—'}</div>
        <div>
          <strong>Подключение:</strong>{' '}
          {connectionState === 'connected' ? '✅ Подключено' :
           connectionState === 'connecting' ? '⏳ Подключение...' :
           '❌ Отключено'}
        </div>
      </div>

      {/* Авторизация */}
      {!currentUser.userId && (
        <div style={{ marginBottom: '20px', padding: '20px', border: '1px solid #ccc' }}>
          <h2>{isRegistering ? '📝 Регистрация' : '🔑 Вход'}</h2>

          <div style={{ marginBottom: '10px' }}>
            <button onClick={() => setIsRegistering(!isRegistering)}>
              {isRegistering ? 'Уже есть аккаунт? Войти' : 'Нет аккаунта? Зарегистрироваться'}
            </button>
          </div>

          {!isRegistering && (
            <input
              type="text"
              placeholder="User ID"
              value={userId}
              onChange={(e) => setUserId(e.target.value)}
              style={{ display: 'block', width: '100%', marginBottom: '10px', padding: '8px' }}
            />
          )}

          <input
            type="text"
            placeholder="Username"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            style={{ display: 'block', width: '100%', marginBottom: '10px', padding: '8px' }}
          />

          <input
            type="password"
            placeholder="Password (min 8 символов, буквы + цифры)"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            style={{ display: 'block', width: '100%', marginBottom: '10px', padding: '8px' }}
          />

          <button
            onClick={handleAuth}
            disabled={loading || !username || !password || (!isRegistering && !userId)}
            style={{ padding: '10px 20px', fontSize: '16px' }}
          >
            {loading ? '⏳ Загрузка...' : isRegistering ? '📝 Зарегистрироваться' : '🔑 Войти'}
          </button>
        </div>
      )}

      {/* Подключение к серверу */}
      {currentUser.userId && connectionState === 'disconnected' && (
        <div style={{ marginBottom: '20px', padding: '20px', border: '1px solid #ccc' }}>
          <h2>🌐 Подключение к серверу</h2>
          <input
            type="text"
            placeholder="Server URL (ws://localhost:8080)"
            value={serverUrl}
            onChange={(e) => setServerUrl(e.target.value)}
            style={{ display: 'block', width: '100%', marginBottom: '10px', padding: '8px' }}
          />
          <button onClick={handleConnect} style={{ padding: '10px 20px', fontSize: '16px' }}>
            🔌 Подключиться
          </button>
        </div>
      )}

      {/* Контакты */}
      {currentUser.userId && (
        <div style={{ marginBottom: '20px', padding: '20px', border: '1px solid #ccc' }}>
          <h2>👥 Контакты ({contacts.length})</h2>

          <button onClick={handleAddContact} style={{ marginBottom: '10px', padding: '8px 16px' }}>
            ➕ Добавить контакт
          </button>

          <div>
            {contacts.length === 0 ? (
              <p>Нет контактов</p>
            ) : (
              contacts.map((contact) => (
                <div
                  key={contact.id}
                  style={{
                    padding: '10px',
                    border: '1px solid #ddd',
                    marginBottom: '5px',
                    display: 'flex',
                    justifyContent: 'space-between',
                    alignItems: 'center',
                  }}
                >
                  <div>
                    <strong>{contact.username}</strong>
                    <br />
                    <small style={{ color: '#666' }}>{contact.id}</small>
                  </div>
                  <button onClick={() => handleSendMessage(contact.id)}>✉️ Написать</button>
                </div>
              ))
            )}
          </div>
        </div>
      )}

      {/* Инфо */}
      <div style={{ marginTop: '40px', padding: '10px', background: '#f9f9f9', fontSize: '12px' }}>
        <h3>ℹ️ Как это работает:</h3>
        <ol>
          <li><strong>WASM модуль</strong> - Rust код компилируется в WebAssembly</li>
          <li><strong>Шифрование</strong> - Приватные ключи шифруются мастер-паролем (PBKDF2 + AES-256-GCM)</li>
          <li><strong>IndexedDB</strong> - Хранилище в браузере для ключей, сессий, сообщений</li>
          <li><strong>Double Ratchet</strong> - Протокол E2EE для сообщений (как в Signal)</li>
          <li><strong>WebSocket</strong> - Соединение с сервером для обмена сообщениями</li>
        </ol>
      </div>
    </div>
  );
}
