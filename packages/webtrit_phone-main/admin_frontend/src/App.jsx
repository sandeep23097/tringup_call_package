import React from 'react';
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { AuthProvider, useAuth } from './context/AuthContext';
import { ToastProvider } from './components/Toast';
import Layout from './components/Layout';
import Login from './pages/Login';
import Dashboard from './pages/Dashboard';
import Users from './pages/Users';
import UserForm from './pages/UserForm';
import CallLogs from './pages/CallLogs';
import ActiveCalls from './pages/ActiveCalls';
import JanusHealth from './pages/JanusHealth';
import GorushHealth from './pages/GorushHealth';
import Configuration from './pages/Configuration';
import PushTokens from './pages/PushTokens';
import './styles/global.css';

function ProtectedRoute({ children }) {
  const { admin, loading } = useAuth();
  if (loading) {
    return (
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100vh', background: '#f0f2f5' }}>
        <div className="spinner" />
      </div>
    );
  }
  if (!admin) return <Navigate to="/login" replace />;
  return children;
}

function AppRoutes() {
  const { admin } = useAuth();
  return (
    <Routes>
      <Route path="/login" element={admin ? <Navigate to="/" replace /> : <Login />} />
      <Route path="/" element={<ProtectedRoute><Layout /></ProtectedRoute>}>
        <Route index element={<Dashboard />} />
        <Route path="users" element={<Users />} />
        <Route path="users/new" element={<UserForm />} />
        <Route path="users/:id/edit" element={<UserForm />} />
        <Route path="calls" element={<CallLogs />} />
        <Route path="active-calls" element={<ActiveCalls />} />
        <Route path="janus" element={<JanusHealth />} />
        <Route path="gorush" element={<GorushHealth />} />
        <Route path="config" element={<Configuration />} />
        <Route path="push-tokens" element={<PushTokens />} />
      </Route>
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}

export default function App() {
  return (
    <AuthProvider>
      <ToastProvider>
        <BrowserRouter>
          <AppRoutes />
        </BrowserRouter>
      </ToastProvider>
    </AuthProvider>
  );
}
