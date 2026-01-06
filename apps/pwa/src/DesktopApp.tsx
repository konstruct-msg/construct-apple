import React, { useState } from 'react';
import DesktopLayout from './components/layouts/DesktopLayout';
import ChatListScreen from './components/ChatListScreen';
import ContactsScreen from './components/ContactsScreen';
import SettingsScreen from './components/SettingsScreen';
import ChatScreen from './components/ChatScreen';
import NavigationBar from './components/NavigationBar';
import './DesktopApp.css';

type Screen = 'contacts' | 'chats' | 'settings';

interface DesktopAppProps {
  onLogout: () => void;
}

const DesktopApp: React.FC<DesktopAppProps> = ({ onLogout }) => {
  const [currentScreen, setCurrentScreen] = useState<Screen>('chats');
  const [selectedChatId, setSelectedChatId] = useState<string | null>(null);

  const navigateToChat = (chatId: string) => {
    setSelectedChatId(chatId);
  };

  const renderLeftPane = () => {
    let listComponent;
    switch (currentScreen) {
      case 'contacts':
        listComponent = <ContactsScreen />;
        break;
      case 'settings':
        listComponent = <SettingsScreen onLogout={onLogout} />;
        break;
      case 'chats':
      default:
        listComponent = <ChatListScreen onChatSelect={navigateToChat} />;
        break;
    }

    return (
      <>
        <div className="left-pane-header">
          <input type="text" placeholder="Search..." className="search-bar" />
        </div>
        <div className="left-pane-content">
          {listComponent}
        </div>
        <NavigationBar currentScreen={currentScreen} onNavigate={setCurrentScreen} layoutMode="desktop" />
      </>
    );
  };

  const renderRightPane = () => {
    if (!selectedChatId) {
      return (
        <div className="empty-chat-view">
          <h2>Select a chat to start messaging</h2>
        </div>
      );
    }

    // In desktop view, the back button is not needed in the chat screen itself.
    // Deselecting a chat can be handled differently (e.g., clicking a 'close' button or selecting another chat).
    // For now, we pass a no-op function for `onBack`.
    return <ChatScreen chatId={selectedChatId} onBack={() => setSelectedChatId(null)} showHeader={false} layoutMode="desktop" />;
  };


  return (
    <DesktopLayout
      leftPane={renderLeftPane()}
      rightPane={renderRightPane()}
    />
  );
};

export default DesktopApp;
