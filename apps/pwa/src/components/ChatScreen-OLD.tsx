import React, { useState, useRef, useLayoutEffect } from 'react';
import './ChatScreen.css';

type ChatScreenProps = {
  chatId: string;
  onBack: () => void;
  showHeader?: boolean;
  layoutMode?: 'mobile' | 'desktop';
};

type Message = {
  id: number;
  text: string;
  sender: string;
  timestamp: string;
};

const ChatScreen: React.FC<ChatScreenProps> = ({ chatId, onBack, showHeader = true, layoutMode = 'mobile' }) => {
  const [inputValue, setInputValue] = useState('');
  const [messages] = useState<Message[]>([]);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const screenClassName = `chat-screen ${layoutMode === 'desktop' ? 'chat-screen-desktop' : ''}`;

  useLayoutEffect(() => {
    const textarea = textareaRef.current;
    if (textarea) {
      // Reset height to shrink when text is deleted
      textarea.style.height = 'auto';
      // Set height based on content
      textarea.style.height = `${textarea.scrollHeight}px`;
    }
  }, [inputValue]);

  const handleSendMessage = () => {
    if (inputValue.trim() === '') return;
    // TODO: Implement send message logic
    console.log('Send message:', inputValue);
    setInputValue('');
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSendMessage();
    }
  };

  return (
    <div className={screenClassName}>
      {showHeader && (
        <header className="chat-header">
          <button onClick={onBack} className="back-button">&lt;</button>
          <h1>Chat with {chatId}</h1>
        </header>
      )}
      <div className="message-list">
        {messages.map((msg, index) => {
          const isMe = msg.sender === 'Me';
          const nextMsg = messages[index + 1];
          const showTimestamp = !nextMsg || nextMsg.sender !== msg.sender;

          return (
            <div key={msg.id} className={`message-row ${isMe ? 'me' : 'other'}`}>
              <div className="message-content">
                <span className="message-text">{msg.text}</span>
                {showTimestamp && <span className="timestamp">{msg.timestamp}</span>}
              </div>
            </div>
          );
        })}
      </div>
      <div className="message-input-container">
        <textarea
          ref={textareaRef}
          placeholder="Сообщение..."
          className="message-input"
          value={inputValue}
          onChange={(e) => setInputValue(e.target.value)}
          onKeyDown={handleKeyDown}
          rows={1} // Start with a single row
        />
        <button className="send-button" onClick={handleSendMessage}>
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24" fill="currentColor">
            <path d="M2.01 21L23 12 2.01 3 2 10l15 2-15 2z"/>
          </svg>
        </button>
      </div>
    </div>
  );
};

export default ChatScreen;
