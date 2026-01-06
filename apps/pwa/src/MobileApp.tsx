import React, { useState } from 'react';
import ChatListScreen from './components/ChatListScreen';
import ContactsScreen from './components/ContactsScreen';
import SettingsScreen from './components/SettingsScreen';
import ChatScreen from './components/ChatScreen';
import NavigationBar from './components/NavigationBar';
import './MobileApp.css';
import MobileLayout from './components/layouts/MobileLayout';

type Screen = 'contacts' | 'chats' | 'settings' | 'chat';

interface MobileAppProps {
  onLogout: () => void;
}

const MobileApp: React.FC<MobileAppProps> = ({ onLogout }) => {
  const [currentScreen, setCurrentScreen] = useState<Screen>('chats');
  const [selectedChatId, setSelectedChatId] = useState<string | null>(null);

  const navigateToChat = (chatId: string) => {
    setSelectedChatId(chatId);
    setCurrentScreen('chat');
  };

  const navigateBack = () => {
    setSelectedChatId(null);
    setCurrentScreen('chats');
  }

  const renderScreen = () => {
    switch (currentScreen) {
      case 'contacts':
        return <ContactsScreen />;
      case 'chats':
        return <ChatListScreen onChatSelect={navigateToChat} />;
      case 'settings':
        return <SettingsScreen onLogout={onLogout} />;
      case 'chat':
        return <ChatScreen chatId={selectedChatId!} onBack={navigateBack} />;
      default:
        return <ChatListScreen onChatSelect={navigateToChat} />;
    }
  };

  const Layout = MobileLayout;

  return (
    <Layout>
      <main className="main-content">
        {renderScreen()}
      </main>
      {currentScreen !== 'chat' && (
        <NavigationBar currentScreen={currentScreen} onNavigate={setCurrentScreen} />
      )}
    </Layout>
  );
}

export default MobileApp;
