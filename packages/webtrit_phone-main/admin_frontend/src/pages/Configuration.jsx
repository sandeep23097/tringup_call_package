import React, { useEffect, useState } from 'react';
import client from '../api/client';
import { useToast } from '../components/Toast';

const EDITABLE_KEYS = [
  { key: 'JANUS_URL', label: 'Janus URL', type: 'url', hint: 'WebRTC gateway endpoint' },
  { key: 'GORUSH_URL', label: 'Gorush URL', type: 'url', hint: 'Push notification server endpoint' },
  { key: 'APP_VERSION', label: 'App Version', type: 'text', hint: 'Minimum supported app version' },
];

const READONLY_KEYS = [
  { key: 'DB_HOST', label: 'Database Host' },
  { key: 'DB_PORT', label: 'Database Port' },
  { key: 'DB_NAME', label: 'Database Name' },
  { key: 'PORT', label: 'Server Port' },
];

export default function Configuration() {
  const toast = useToast();
  const [config, setConfig] = useState({});
  const [editValues, setEditValues] = useState({});
  const [showSecret, setShowSecret] = useState(false);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    const load = async () => {
      try {
        const res = await client.get('/admin/config');
        setConfig(res.data);
        const editable = {};
        EDITABLE_KEYS.forEach(({ key }) => {
          editable[key] = res.data[key] || '';
        });
        setEditValues(editable);
      } catch {
        toast.error('Failed to load configuration');
      } finally {
        setLoading(false);
      }
    };
    load();
  }, []);

  const handleChange = (key, value) => {
    setEditValues(prev => ({ ...prev, [key]: value }));
  };

  const handleSave = async (e) => {
    e.preventDefault();
    setSaving(true);
    try {
      await client.put('/admin/config', editValues);
      setConfig(prev => ({ ...prev, ...editValues }));
      toast.success('Configuration saved successfully');
    } catch {
      toast.error('Failed to save configuration');
    } finally {
      setSaving(false);
    }
  };

  if (loading) {
    return (
      <div className="loading-state">
        <div className="spinner" />
        <span>Loading configuration…</span>
      </div>
    );
  }

  return (
    <div className="config-page">
      <div className="page-header">
        <div className="page-header-left">
          <h2>Configuration</h2>
          <p>Manage system settings and integrations</p>
        </div>
      </div>

      <form onSubmit={handleSave}>
        <div className="card mb-4">
          <div className="card-header">
            <span className="card-title">⚙️ Editable Settings</span>
          </div>
          <div className="card-body">
            {EDITABLE_KEYS.map(({ key, label, type, hint }) => (
              <div className="form-group" key={key}>
                <label className="form-label" htmlFor={key}>{label}</label>
                <input
                  id={key}
                  type={type}
                  className="form-input"
                  value={editValues[key] || ''}
                  onChange={e => handleChange(key, e.target.value)}
                />
                {hint && <p className="form-hint">{hint}</p>}
              </div>
            ))}

            <div className="form-group">
              <label className="form-label" htmlFor="jwt">JWT Secret</label>
              <div className="config-masked">
                <input
                  id="jwt"
                  type={showSecret ? 'text' : 'password'}
                  className="form-input"
                  value={config.JWT_SECRET || ''}
                  readOnly
                  style={{ background: '#f9fafb', color: '#6b7280', cursor: 'default' }}
                />
                <button
                  type="button"
                  className="btn btn-secondary btn-sm"
                  onClick={() => setShowSecret(s => !s)}
                  style={{ flexShrink: 0 }}
                >
                  {showSecret ? '🙈 Hide' : '👁 Show'}
                </button>
              </div>
              <p className="form-hint">JWT secret is managed via environment variable. Shown read-only for reference.</p>
            </div>

            <div className="form-actions">
              <button type="submit" className="btn btn-primary" disabled={saving}>
                {saving ? <><span className="spinner spinner-sm" /> Saving…</> : '💾 Save Configuration'}
              </button>
            </div>
          </div>
        </div>
      </form>

      <div className="card">
        <div className="card-header">
          <span className="card-title">🗄️ Database Settings (Read-only)</span>
        </div>
        <div className="card-body">
          <p className="text-muted text-sm mb-3">
            Database settings are configured via environment variables and cannot be changed here.
          </p>
          {READONLY_KEYS.map(({ key, label }) => (
            <div className="form-group" key={key}>
              <label className="form-label">{label}</label>
              <input
                type="text"
                className="form-input"
                value={config[key] || '—'}
                readOnly
                style={{ background: '#f9fafb', color: '#6b7280', cursor: 'default' }}
              />
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
