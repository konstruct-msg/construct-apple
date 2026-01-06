import React from 'react';
import './MobileLayout.css';

interface MobileLayoutProps {
  children: React.ReactNode;
}

const MobileLayout: React.FC<MobileLayoutProps> = ({ children }) => {
  return (
    <div className="mobile-layout">
      {/* <h1>Mobile</h1> */}
      <main>{children}</main>
    </div>
  );
};

export default MobileLayout;
