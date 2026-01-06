import React from 'react';
import './ChatListScreen.css';

type ChatListScreenProps = {
  onChatSelect: (chatId: string) => void;
};

const chats = [
  { id: '1', name: 'alice', lastMessage: 'hey', timestamp: '10:42', unread: 2 },
  { id: '2', name: 'bob', lastMessage: 'double ratchet works!', timestamp: '09:15', unread: 0 },
  { id: '3', name: 'charlie', lastMessage: 'test message', timestamp: 'yesterday', unread: 0 },
];

const ChatListScreen: React.FC<ChatListScreenProps> = ({ onChatSelect }) => {
  return (
    <div className="chat-list-screen">
      <div className="chat-list-header">
        <h1 className="mono">CHATS</h1>
      </div>

      <div className="chat-list">
        {chats.length === 0 ? (
          <div className="empty-state">
            <p className="mono">NO CHATS</p>
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
                  <span className="last-message">{chat.lastMessage}</span>
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
