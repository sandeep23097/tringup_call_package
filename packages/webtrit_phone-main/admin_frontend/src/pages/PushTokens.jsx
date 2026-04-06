import React, { useEffect, useState, useCallback } from 'react';
import client from '../api/client';
import DataTable from '../components/DataTable';
import ConfirmModal from '../components/ConfirmModal';
import { useToast } from '../components/Toast';

const TYPE_COLORS = {
  fcm: { background: '#fff7ed', color: '#c2410c' },
  apns: { background: '#eff6ff', color: '#1d4ed8' },
  hms: { background: '#fdf2f8', color: '#9d174d' },
  apkvoip: { background: '#f0fdf4', color: '#15803d' },
};

function TypeBadge({ type }) {
  const style = TYPE_COLORS[type?.toLowerCase()] || { background: '#f3f4f6', color: '#6b7280' };
  return (
    <span className="badge" style={style}>{type || 'unknown'}</span>
  );
}

export default function PushTokens() {
  const toast = useToast();
  const [tokens, setTokens] = useState([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(true);
  const [deleteTarget, setDeleteTarget] = useState(null);
  const [deleting, setDeleting] = useState(false);

  const [testForm, setTestForm] = useState({ token_id: '', title: 'Test Push', body: 'Hello from WebtRit Admin' });
  const [testLoading, setTestLoading] = useState(false);

  const LIMIT = 20;

  const fetchTokens = useCallback(async () => {
    setLoading(true);
    try {
      const res = await client.get('/admin/push-tokens', {
        params: { page, limit: LIMIT },
      });
      setTokens(res.data.tokens || []);
      setTotal(res.data.total || 0);
    } catch {
      toast.error('Failed to load push tokens');
    } finally {
      setLoading(false);
    }
  }, [page]);

  useEffect(() => { fetchTokens(); }, [fetchTokens]);

  const handleDelete = async () => {
    if (!deleteTarget) return;
    setDeleting(true);
    try {
      await client.delete(`/admin/push-tokens/${deleteTarget.id}`);
      toast.success('Push token deleted');
      setDeleteTarget(null);
      fetchTokens();
    } catch {
      toast.error('Failed to delete token');
    } finally {
      setDeleting(false);
    }
  };

  const handleTestPush = async (e) => {
    e.preventDefault();
    if (!testForm.token_id) {
      toast.error('Please enter a Token ID');
      return;
    }
    setTestLoading(true);
    try {
      const res = await client.post('/admin/push-tokens/test', testForm);
      toast.success(res.data.message || 'Test push sent successfully');
    } catch (err) {
      toast.error(err.response?.data?.message || 'Failed to send test push');
    } finally {
      setTestLoading(false);
    }
  };

  const totalPages = Math.ceil(total / LIMIT);

  const rows = tokens.map(t => [
    <span className="font-mono text-xs text-muted">{t.user_id?.slice(0, 8)}…</span>,
    <span style={{ fontWeight: 500 }}>{t.user_name || '—'}</span>,
    t.user_email || '—',
    <TypeBadge type={t.type} />,
    <span className="token-value" title={t.value}>{t.value?.slice(0, 40)}…</span>,
    t.updated_at ? new Date(t.updated_at).toLocaleString() : '—',
    <button
      className="btn btn-danger btn-sm"
      onClick={() => setDeleteTarget({ id: t.id, value: t.value?.slice(0, 20) })}
    >
      🗑️ Delete
    </button>,
  ]);

  return (
    <div>
      <div className="page-header">
        <div className="page-header-left">
          <h2>Push Tokens</h2>
          <p>{total} registered tokens</p>
        </div>
        <button className="btn btn-secondary btn-sm" onClick={fetchTokens}>
          🔄 Refresh
        </button>
      </div>

      <div className="card mb-4">
        <DataTable
          headers={['User ID', 'Name', 'Email', 'Type', 'Token Value', 'Updated At', 'Action']}
          rows={rows}
          loading={loading}
          emptyMessage="No push tokens registered"
        />

        {totalPages > 1 && (
          <div className="pagination">
            <span className="pagination-info">
              Showing {((page - 1) * LIMIT) + 1}–{Math.min(page * LIMIT, total)} of {total}
            </span>
            <button
              className="pagination-btn"
              onClick={() => setPage(p => Math.max(1, p - 1))}
              disabled={page === 1}
            >
              ← Prev
            </button>
            {Array.from({ length: Math.min(5, totalPages) }, (_, i) => {
              const pn = totalPages <= 5 ? i + 1 : page <= 3 ? i + 1 : page - 2 + i;
              return (
                <button
                  key={pn}
                  className={`pagination-btn ${page === pn ? 'active' : ''}`}
                  onClick={() => setPage(pn)}
                >
                  {pn}
                </button>
              );
            })}
            <button
              className="pagination-btn"
              onClick={() => setPage(p => Math.min(totalPages, p + 1))}
              disabled={page === totalPages}
            >
              Next →
            </button>
          </div>
        )}
      </div>

      <div className="card">
        <div className="card-header">
          <span className="card-title">🔔 Send Test Push Notification</span>
        </div>
        <div className="card-body">
          <form onSubmit={handleTestPush}>
            <div className="form-row">
              <div className="form-group">
                <label className="form-label" htmlFor="token_id">
                  Token ID <span className="required">*</span>
                </label>
                <input
                  id="token_id"
                  type="text"
                  className="form-input"
                  placeholder="Push token ID (from table above)"
                  value={testForm.token_id}
                  onChange={e => setTestForm(f => ({ ...f, token_id: e.target.value }))}
                />
                <p className="form-hint">Enter the token ID (UUID) from the table above</p>
              </div>
              <div className="form-group">
                <label className="form-label" htmlFor="push_title">Title</label>
                <input
                  id="push_title"
                  type="text"
                  className="form-input"
                  value={testForm.title}
                  onChange={e => setTestForm(f => ({ ...f, title: e.target.value }))}
                />
              </div>
            </div>
            <div className="form-group">
              <label className="form-label" htmlFor="push_body">Message Body</label>
              <input
                id="push_body"
                type="text"
                className="form-input"
                value={testForm.body}
                onChange={e => setTestForm(f => ({ ...f, body: e.target.value }))}
              />
            </div>
            <div className="form-actions">
              <button type="submit" className="btn btn-primary" disabled={testLoading}>
                {testLoading ? <><span className="spinner spinner-sm" /> Sending…</> : '📤 Send Test Push'}
              </button>
            </div>
          </form>
        </div>
      </div>

      <ConfirmModal
        open={!!deleteTarget}
        title="Delete Push Token"
        message={
          <span>Are you sure you want to delete this push token? The device will no longer receive push notifications.</span>
        }
        confirmLabel="Delete Token"
        confirmVariant="danger"
        onConfirm={handleDelete}
        onCancel={() => setDeleteTarget(null)}
        loading={deleting}
      />
    </div>
  );
}
