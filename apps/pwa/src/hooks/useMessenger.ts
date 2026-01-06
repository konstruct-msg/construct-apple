import { useState, useEffect, useCallback } from 'react';
import { messenger, Contact, Conversation } from '../services/messenger';

/**
 * React Hook для работы с мессенджером
 */
export function useMessenger() {
  const [initialized, setInitialized] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [currentUser, setCurrentUser] = useState<{ userId?: string; username?: string }>({});
  const [contacts, setContacts] = useState<Contact[]>([]);
  const [connectionState, setConnectionState] = useState<'disconnected' | 'connecting' | 'connected'>('disconnected');

  // Инициализация при монтировании
  useEffect(() => {
    const init = async () => {
      try {
        await messenger.initialize();
        setInitialized(true);
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Failed to initialize messenger');
      }
    };
    init();

    return () => {
      // Cleanup при размонтировании
      messenger.destroy();
    };
  }, []);

  // Регистрация нового пользователя
  const register = useCallback(async (username: string, password: string) => {
    setLoading(true);
    setError(null);
    try {
      const userId = await messenger.registerUser(username, password);
      const user = messenger.getCurrentUser();
      setCurrentUser(user);
      return userId;
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : 'Registration failed';
      setError(errorMsg);
      throw new Error(errorMsg);
    } finally {
      setLoading(false);
    }
  }, []);

  // Вход существующего пользователя
  const login = useCallback(async (userId: string, password: string) => {
    setLoading(true);
    setError(null);
    try {
      await messenger.loginUser(userId, password);
      const user = messenger.getCurrentUser();
      setCurrentUser(user);

      // Загрузить контакты
      const contactsList = messenger.getContacts();
      setContacts(contactsList);
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : 'Login failed';
      setError(errorMsg);
      throw new Error(errorMsg);
    } finally {
      setLoading(false);
    }
  }, []);

  // Добавить контакт
  const addContact = useCallback(async (contactId: string, username: string) => {
    setLoading(true);
    setError(null);
    try {
      await messenger.addContact(contactId, username);
      const contactsList = messenger.getContacts();
      setContacts(contactsList);
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : 'Failed to add contact';
      setError(errorMsg);
      throw new Error(errorMsg);
    } finally {
      setLoading(false);
    }
  }, []);

  // Отправить сообщение
  const sendMessage = useCallback(async (toContactId: string, sessionId: string, text: string) => {
    setLoading(true);
    setError(null);
    try {
      const messageId = await messenger.sendMessage(toContactId, sessionId, text);
      return messageId;
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : 'Failed to send message';
      setError(errorMsg);
      throw new Error(errorMsg);
    } finally {
      setLoading(false);
    }
  }, []);

  // Загрузить беседу
  const loadConversation = useCallback(async (contactId: string): Promise<Conversation> => {
    setLoading(true);
    setError(null);
    try {
      const conversation = await messenger.loadConversation(contactId);
      return conversation;
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : 'Failed to load conversation';
      setError(errorMsg);
      throw new Error(errorMsg);
    } finally {
      setLoading(false);
    }
  }, []);

  // Подключиться к серверу
  const connect = useCallback(async (serverUrl: string) => {
    setConnectionState('connecting');
    setError(null);
    try {
      await messenger.connect(serverUrl);
      setConnectionState('connected');
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : 'Connection failed';
      setError(errorMsg);
      setConnectionState('disconnected');
      throw new Error(errorMsg);
    }
  }, []);

  // Отключиться от сервера
  const disconnect = useCallback(async () => {
    try {
      await messenger.disconnect();
      setConnectionState('disconnected');
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : 'Disconnect failed';
      setError(errorMsg);
    }
  }, []);

  return {
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
    loadConversation,
    connect,
    disconnect,
  };
}
