import React, { useEffect, useState } from 'react';
import { messenger, Contact } from '../services/messenger';
import './ChatListScreen.css';

type ChatListScreenProps = {
  onChatSelect: (chatId: string) => void;
};

type ChatListItem = {
  id: string;
  name: string;
  lastMessage: string;
  timestamp: string;
  unread: number;
};

const ChatListScreen: React.FC<ChatListScreenProps> = ({ onChatSelect }) => {
  const [chats, setChats] = useState<ChatListItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    loadChats();

    // Polling для обновления списка (пока нет WebSocket callbacks)
    const interval = setInterval(loadChats, 3000);
    return () => clearInterval(interval);
  }, []);

  const loadChats = async () => {
    try {
      setLoading(true);
      setError(null);

      // ✅ РЕАЛЬНАЯ ЗАГРУЗКА из WASM!
      const contacts: Contact[] = messenger.getContacts();

      // Преобразовать контакты в список чатов
      const chatList: ChatListItem[] = await Promise.all(
        contacts.map(async (contact) => {
          try {
            const conversation = await messenger.loadConversation(contact.id);
            const lastMsg = conversation.messages[conversation.messages.length - 1];

            return {
              id: contact.id,
              name: contact.username,
              lastMessage: lastMsg ? lastMsg.content : 'No messages',
              timestamp: lastMsg ? formatTimestamp(lastMsg.timestamp) : '',
              unread: conversation.unread_count,
            };
          } catch (err) {
            console.error(`Failed to load conversation for ${contact.username}:`, err);
            return {
              id: contact.id,
              name: contact.username,
              lastMessage: 'Error loading messages',
              timestamp: '',
              unread: 0,
            };
          }
        })
      );

      setChats(chatList);
    } catch (err) {
      console.error('Failed to load chats:', err);
      setError(err instanceof Error ? err.message : 'Failed to load chats');
    } finally {
      setLoading(false);
    }
  };

  const formatTimestamp = (timestamp: number): string => {
    const date = new Date(timestamp * 1000);
    const now = new Date();
    const diff = now.getTime() - date.getTime();

    if (diff < 60000) return 'now';
    if (diff < 3600000) return `${Math.floor(diff / 60000)}m`;
    if (diff < 86400000) return date.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
    if (diff < 172800000) return 'yesterday';
    return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  };

  const handleAddContact = async () => {
    const contactId = prompt('Enter contact UUID:');
    const username = prompt('Enter contact username:');

    if (contactId && username) {
      try {
        await messenger.addContact(contactId, username);
        alert('✅ Contact added!');
        await loadChats();
      } catch (err) {
        console.error('Failed to add contact:', err);
        alert(`❌ Failed to add contact: ${err}`);
      }
    }
  };

  return (
    <div className="chat-list-screen">
      <div className="chat-list-header">
        <h1 className="mono">CHATS</h1>
        <button
          onClick={handleAddContact}
          style={{
            padding: '5px 10px',
            background: '#007aff',
            color: 'white',
            border: 'none',
            borderRadius: '4px',
            cursor: 'pointer',
          }}
        >
          ➕ Add Contact
        </button>
      </div>

      {error && (
        <div style={{
          padding: '10px',
          background: '#fee',
          border: '1px solid #f00',
          margin: '10px',
        }}>
          ❌ Error: {error}
        </div>
      )}

      {loading && chats.length === 0 && (
        <div style={{ textAlign: 'center', padding: '20px' }}>
          ⏳ Loading chats...
        </div>
      )}

      <div className="chat-list">
        {chats.length === 0 && !loading ? (
          <div className="empty-state">
            <p className="mono">NO CHATS</p>
            <p style={{ fontSize: '14px', color: '#999', marginTop: '10px' }}>
              Click "Add Contact" to start chatting
            </p>
          </div>
        ) : (
          chats.map(chat => (
            <div
              key={chat.id}
              className="chat-list-item"
              onClick={() => onChatSelect(chat.id)}
            >
              <div className="chat-content">
                <div className="chat-header-row">
                  <span className="chat-name mono">{chat.name}</span>
                  <span className="chat-timestamp mono">{chat.timestamp}</span>
                </div>
                <div className="chat-preview-row">
                  <span className="last-message">
                    {/* TODO: Расшифровать последнее сообщение */}
                    {chat.lastMessage.length > 50
                      ? chat.lastMessage.substring(0, 50) + '...'
                      : chat.lastMessage}
                  </span>
                  {chat.unread > 0 && (
                    <span className="unread-badge mono">{chat.unread}</span>
                  )}
                </div>
              </div>
            </div>
          ))
        )}
      </div>
    </div>
  );
};

export default ChatListScreen;
