import React from 'react';
import './NavigationBar.css';

type Screen = 'contacts' | 'chats' | 'settings';

type NavigationBarProps = {
  currentScreen: Screen;
  onNavigate: (screen: Screen) => void;
  layoutMode?: 'mobile' | 'desktop';
};

const NavigationBar: React.FC<NavigationBarProps> = ({ currentScreen, onNavigate, layoutMode = 'mobile' }) => {
  const navClassName = `navigation-bar ${layoutMode === 'desktop' ? 'navigation-bar-desktop' : ''}`;
  
  return (
    <nav className={navClassName}>
      <button
        className={`nav-item ${currentScreen === 'contacts' ? 'active' : ''}`}
        onClick={() => onNavigate('contacts')}
      >
        <span className="nav-label mono">CONTACTS</span>
      </button>
      <button
        className={`nav-item ${currentScreen === 'chats' ? 'active' : ''}`}
        onClick={() => onNavigate('chats')}
      >
        <span className="nav-label mono">CHATS</span>
      </button>
      <button
        className={`nav-item ${currentScreen === 'settings' ? 'active' : ''}`}
        onClick={() => onNavigate('settings')}
      >
        <span className="nav-label mono">SETTINGS</span>
      </button>
    </nav>
  );
};

export default NavigationBar;
