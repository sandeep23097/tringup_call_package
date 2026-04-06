import React, { useEffect, useState, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import client from '../api/client';
import DataTable from '../components/DataTable';
import ConfirmModal from '../components/ConfirmModal';
import { useToast } from '../components/Toast';

function StatusBadge({ status }) {
  return (
    <span className={`badge ${status === 'active' ? 'badge-active' : 'badge-inactive'}`}>
      <span className="badge-dot" />
      {status}
    </span>
  );
}

export default function Users() {
  const navigate = useNavigate();
  const toast = useToast();
  const [users, setUsers] = useState([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [search, setSearch] = useState('');
  const [searchInput, setSearchInput] = useState('');
  const [loading, setLoading] = useState(true);
  const [deleteTarget, setDeleteTarget] = useState(null);
  const [deleting, setDeleting] = useState(false);
  const LIMIT = 20;

  const fetchUsers = useCallback(async () => {
    setLoading(true);
    try {
      const res = await client.get('/admin/users', {
        params: { page, limit: LIMIT, search },
      });
      setUsers(res.data.users || []);
      setTotal(res.data.total || 0);
    } catch {
      toast.error('Failed to load users');
    } finally {
      setLoading(false);
    }
  }, [page, search]);

  useEffect(() => { fetchUsers(); }, [fetchUsers]);

  const handleSearch = (e) => {
    e.preventDefault();
    setSearch(searchInput);
    setPage(1);
  };

  const handleDelete = async () => {
    if (!deleteTarget) return;
    setDeleting(true);
    try {
      await client.delete(`/admin/users/${deleteTarget.id}`);
      toast.success(`User "${deleteTarget.name}" deleted`);
      setDeleteTarget(null);
      fetchUsers();
    } catch {
      toast.error('Failed to delete user');
    } finally {
      setDeleting(false);
    }
  };

  const totalPages = Math.ceil(total / LIMIT);

  const rows = users.map(u => [
    <span className="font-mono text-xs text-muted">{u.id.slice(0, 8)}…</span>,
    <span style={{ fontWeight: 500 }}>{[u.first_name, u.last_name].filter(Boolean).join(' ') || '—'}</span>,
    u.phone_main || '—',
    u.email || '—',
    u.ext || '—',
    <StatusBadge status={u.status} />,
    <div className="actions-cell">
      <button
        className="btn btn-secondary btn-sm"
        onClick={() => navigate(`/users/${u.id}/edit`)}
        title="Edit user"
      >
        ✏️ Edit
      </button>
      <button
        className="btn btn-danger btn-sm"
        onClick={() => setDeleteTarget({ id: u.id, name: [u.first_name, u.last_name].filter(Boolean).join(' ') || u.email || u.id })}
        title="Delete user"
      >
        🗑️ Delete
      </button>
    </div>,
  ]);

  return (
    <div>
      <div className="page-header">
        <div className="page-header-left">
          <h2>Users</h2>
          <p>{total} total users</p>
        </div>
        <button className="btn btn-primary" onClick={() => navigate('/users/new')}>
          + Add User
        </button>
      </div>

      <div className="card">
        <div className="card-header">
          <form className="toolbar" onSubmit={handleSearch} style={{ margin: 0, flex: 1 }}>
            <div className="search-input-wrapper">
              <span className="search-icon">🔍</span>
              <input
                type="text"
                placeholder="Search by name, email or phone…"
                value={searchInput}
                onChange={e => setSearchInput(e.target.value)}
              />
            </div>
            <button type="submit" className="btn btn-primary btn-sm">Search</button>
            {search && (
              <button type="button" className="btn btn-secondary btn-sm" onClick={() => { setSearch(''); setSearchInput(''); setPage(1); }}>
                Clear
              </button>
            )}
          </form>
        </div>

        <DataTable
          headers={['ID', 'Name', 'Phone', 'Email', 'Ext', 'Status', 'Actions']}
          rows={rows}
          loading={loading}
          emptyMessage="No users found"
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
              let pageNum;
              if (totalPages <= 5) pageNum = i + 1;
              else if (page <= 3) pageNum = i + 1;
              else if (page >= totalPages - 2) pageNum = totalPages - 4 + i;
              else pageNum = page - 2 + i;
              return (
                <button
                  key={pageNum}
                  className={`pagination-btn ${page === pageNum ? 'active' : ''}`}
                  onClick={() => setPage(pageNum)}
                >
                  {pageNum}
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

      <ConfirmModal
        open={!!deleteTarget}
        title="Delete User"
        message={
          <span>Are you sure you want to delete <strong>{deleteTarget?.name}</strong>? This action cannot be undone.</span>
        }
        confirmLabel="Delete"
        confirmVariant="danger"
        onConfirm={handleDelete}
        onCancel={() => setDeleteTarget(null)}
        loading={deleting}
      />
    </div>
  );
}
