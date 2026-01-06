import React, { useState, useEffect } from 'react';
import { messenger } from '../services/messenger';
import { SERVER_URL } from '../config/constants';
import { validateServerUrl } from '../utils/url';
import './SettingsScreen.css';

interface SettingsScreenProps {
  onLogout: () => void;
}

const SettingsScreen: React.FC<SettingsScreenProps> = ({ onLogout }) => {
  const [serverUrl, setServerUrl] = useState('');

  useEffect(() => {
    // Загрузить сохраненный адрес сервера или использовать дефолтный
    const savedUrl = localStorage.getItem('construct_server_url') || SERVER_URL;
    setServerUrl(savedUrl);
  }, []);

  const handleChangeServer = async () => {
    const newUrl = prompt(
      'Enter server URL (supports domain, IPv4, IPv6):\n\n' +
      'Examples:\n' +
      '  wss://example.com\n' +
      '  wss://192.168.1.1:443\n' +
      '  wss://[2a09:8280:1::b9:e736:0]:443',
      serverUrl
    );

    if (newUrl && newUrl !== serverUrl) {
      // Валидировать URL
      const validation = validateServerUrl(newUrl);
      if (!validation.valid) {
        alert('Invalid server URL: ' + validation.error);
        return;
      }

      try {
        // Отключиться от старого сервера
        await messenger.disconnect();

        // Подключиться к новому серверу (используем нормализованный URL)
        const normalizedUrl = validation.normalized!;
        await messenger.connect(normalizedUrl);

        // Сохранить новый адрес
        localStorage.setItem('construct_server_url', normalizedUrl);
        setServerUrl(normalizedUrl);

        console.log('Server changed to:', normalizedUrl);
      } catch (err) {
        console.error('Failed to change server:', err);
        alert('Failed to connect to new server: ' + (err instanceof Error ? err.message : 'Unknown error'));
      }
    }
  };

  const handleLogout = () => {
    if (confirm('Are you sure you want to logout?')) {
      onLogout();
    }
  };

  return (
    <div className="settings-screen">
      <div className="settings-header">
        <h1 className="mono">SETTINGS</h1>
      </div>

      <div className="settings-list">
        <div className="settings-item" onClick={handleChangeServer}>
          <div className="settings-item-label mono">SERVER</div>
          <div className="settings-item-value">{serverUrl}</div>
        </div>

        <div className="settings-item logout-item" onClick={handleLogout}>
          <div className="settings-item-label mono">LOGOUT</div>
        </div>
      </div>
    </div>
  );
};

export default SettingsScreen;
