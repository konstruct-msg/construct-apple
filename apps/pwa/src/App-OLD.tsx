import React from 'react';
import { useDeviceType } from './hooks/useDeviceType';
import MobileApp from './MobileApp';
import DesktopApp from './DesktopApp';

const App: React.FC = () => {
  const deviceType = useDeviceType();

  if (deviceType === 'desktop') {
    return <DesktopApp onLogout={() => console.log('logout')} />;
  }

  return <MobileApp onLogout={() => console.log('logout')} />;
};

export default App;
