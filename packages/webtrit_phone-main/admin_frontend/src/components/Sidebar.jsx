import React from 'react';
import { NavLink } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';

const NAV_ITEMS = [
  { icon: '📊', label: 'Dashboard', to: '/', exact: true },
  { icon: '👥', label: 'Users', to: '/users' },
  { icon: '📞', label: 'Call Logs', to: '/calls' },
  { icon: '🔴', label: 'Active Calls', to: '/active-calls' },
  { icon: '🔌', label: 'Janus Health', to: '/janus' },
  { icon: '📡', label: 'Gorush Health', to: '/gorush' },
  { icon: '⚙️', label: 'Configuration', to: '/config' },
  { icon: '🔔', label: 'Push Tokens', to: '/push-tokens' },
];

export default function Sidebar() {
  const { admin } = useAuth();

  return (
    <aside className="admin-sidebar">
      <div className="sidebar-logo">
        <h1>📱 WebtRit</h1>
        <p>Admin Panel</p>
      </div>

      <nav className="sidebar-nav">
        <div className="sidebar-section-title">Navigation</div>
        {NAV_ITEMS.map(item => (
          <NavLink
            key={item.to}
            to={item.to}
            end={item.exact}
            className={({ isActive }) => isActive ? 'active' : ''}
          >
            <span className="nav-icon">{item.icon}</span>
            {item.label}
          </NavLink>
        ))}
      </nav>

      <div className="sidebar-footer">
        {admin && (
          <>
            <div className="admin-name">{admin.name || admin.email}</div>
            <div className="admin-info">{admin.email}</div>
          </>
        )}
      </div>
    </aside>
  );
}
