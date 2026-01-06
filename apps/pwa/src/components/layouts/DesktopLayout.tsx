import React from 'react';
import './DesktopLayout.css';

interface DesktopLayoutProps {
  leftPane: React.ReactNode;
  rightPane: React.ReactNode;
}

const DesktopLayout: React.FC<DesktopLayoutProps> = ({ leftPane, rightPane }) => {
  return (
    <div className="desktop-layout">
      <div className="left-pane">
        {leftPane}
      </div>
      <div className="right-pane">
        {rightPane}
      </div>
    </div>
  );
};

export default DesktopLayout;
