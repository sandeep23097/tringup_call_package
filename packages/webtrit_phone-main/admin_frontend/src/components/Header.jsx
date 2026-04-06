import React from 'react';
import { useAuth } from '../context/AuthContext';

export default function Header({ title }) {
  const { admin, logout } = useAuth();

  const initials = admin
    ? (admin.name || admin.email || 'A').split(' ').map(s => s[0]).join('').toUpperCase().slice(0, 2)
    : 'A';

  return (
    <header className="admin-header">
      <div className="header-title">{title}</div>
      <div className="header-right">
        {admin && (
          <div className="admin-badge">
            <div className="avatar">{initials}</div>
            <span>{admin.name || admin.email}</span>
          </div>
        )}
        <button className="btn btn-secondary btn-sm" onClick={logout}>
          Sign Out
        </button>
      </div>
    </header>
  );
}
