import React, { createContext, useContext, useState, useEffect } from 'react';
import client from '../api/client';

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [admin, setAdmin] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const token = localStorage.getItem('admin_token');
    const stored = localStorage.getItem('admin_user');
    if (token && stored) {
      try {
        setAdmin(JSON.parse(stored));
      } catch {
        localStorage.removeItem('admin_token');
        localStorage.removeItem('admin_user');
      }
    }
    setLoading(false);
  }, []);

  const login = async (email, password) => {
    const res = await client.post('/admin/auth/login', { email, password });
    const { token, admin: adminData } = res.data;
    localStorage.setItem('admin_token', token);
    localStorage.setItem('admin_user', JSON.stringify(adminData));
    setAdmin(adminData);
    return adminData;
  };

  const logout = () => {
    localStorage.removeItem('admin_token');
    localStorage.removeItem('admin_user');
    setAdmin(null);
    window.location.href = '/login';
  };

  return (
    <AuthContext.Provider value={{ admin, login, logout, loading }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used within AuthProvider');
  return ctx;
}
