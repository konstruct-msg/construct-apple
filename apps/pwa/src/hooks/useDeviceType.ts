import { useState, useLayoutEffect } from 'react';

const mobileBreakpoint = 768;

export type DeviceType = 'mobile' | 'desktop';

export const useDeviceType = (): DeviceType => {
  const [deviceType, setDeviceType] = useState<DeviceType>(
    window.innerWidth < mobileBreakpoint ? 'mobile' : 'desktop'
  );

  useLayoutEffect(() => {
    const handleResize = () => {
      if (window.innerWidth < mobileBreakpoint) {
        setDeviceType('mobile');
      } else {
        setDeviceType('desktop');
      }
    };

    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, []);

  return deviceType;
};
