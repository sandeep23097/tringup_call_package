import React from 'react';
import { Outlet, useLocation } from 'react-router-dom';
import Sidebar from './Sidebar';
import Header from './Header';

const PAGE_TITLES = {
  '/': 'Dashboard',
  '/users': 'Users',
  '/users/new': 'Create User',
  '/calls': 'Call Logs',
  '/active-calls': 'Active Calls',
  '/janus': 'Janus Health',
  '/config': 'Configuration',
  '/push-tokens': 'Push Tokens',
};

export default function Layout() {
  const location = useLocation();

  const getTitle = () => {
    if (location.pathname.match(/^\/users\/.+\/edit$/)) return 'Edit User';
    return PAGE_TITLES[location.pathname] || 'Admin Panel';
  };

  return (
    <div className="admin-layout">
      <Sidebar />
      <div className="admin-main">
        <Header title={getTitle()} />
        <div className="admin-content">
          <Outlet />
        </div>
      </div>
    </div>
  );
}
