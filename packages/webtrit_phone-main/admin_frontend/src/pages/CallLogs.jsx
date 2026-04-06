import React, { useEffect, useState, useCallback } from 'react';
import client from '../api/client';
import DataTable from '../components/DataTable';
import { useToast } from '../components/Toast';

function StatusBadge({ status }) {
  const map = {
    answered: 'badge-answered',
    rejected: 'badge-rejected',
    missed: 'badge-missed',
    failed: 'badge-failed',
    busy: 'badge-busy',
  };
  return (
    <span className={`badge ${map[status?.toLowerCase()] || 'badge-default'}`}>
      {status || 'unknown'}
    </span>
  );
}

function DirectionBadge({ direction }) {
  const style = direction === 'inbound'
    ? { background: '#eff6ff', color: '#1d4ed8' }
    : { background: '#f0fdf4', color: '#15803d' };
  return (
    <span className="badge" style={style}>
      {direction === 'inbound' ? '⬇ In' : '⬆ Out'}
    </span>
  );
}

function formatDuration(seconds) {
  if (!seconds) return '—';
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return m > 0 ? `${m}m ${s}s` : `${s}s`;
}

export default function CallLogs() {
  const toast = useToast();
  const [calls, setCalls] = useState([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [search, setSearch] = useState('');
  const [searchInput, setSearchInput] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [loading, setLoading] = useState(true);
  const LIMIT = 20;

  const fetchCalls = useCallback(async () => {
    setLoading(true);
    try {
      const res = await client.get('/admin/calls/history', {
        params: { page, limit: LIMIT, search, from, to },
      });
      setCalls(res.data.calls || []);
      setTotal(res.data.total || 0);
    } catch {
      toast.error('Failed to load call logs');
    } finally {
      setLoading(false);
    }
  }, [page, search, from, to]);

  useEffect(() => { fetchCalls(); }, [fetchCalls]);

  const handleSearch = (e) => {
    e.preventDefault();
    setSearch(searchInput);
    setPage(1);
  };

  const handleClear = () => {
    setSearch('');
    setSearchInput('');
    setFrom('');
    setTo('');
    setPage(1);
  };

  const totalPages = Math.ceil(total / LIMIT);

  const rows = calls.map(c => [
    <span className="font-mono text-xs text-muted" title={c.call_id}>{c.call_id?.slice(0, 14)}…</span>,
    <span style={{ fontWeight: 500 }}>{c.caller}</span>,
    c.callee,
    <DirectionBadge direction={c.direction} />,
    <StatusBadge status={c.status} />,
    c.connect_time ? new Date(c.connect_time).toLocaleString() : '—',
    formatDuration(c.duration),
    c.disconnect_reason || '—',
  ]);

  return (
    <div>
      <div className="page-header">
        <div className="page-header-left">
          <h2>Call Logs</h2>
          <p>{total} total records</p>
        </div>
      </div>

      <div className="card">
        <div className="card-header">
          <form style={{ display: 'flex', gap: '10px', flexWrap: 'wrap', flex: 1, margin: 0 }} onSubmit={handleSearch}>
            <div className="search-input-wrapper" style={{ flex: '1', minWidth: '180px' }}>
              <span className="search-icon">🔍</span>
              <input
                type="text"
                placeholder="Search caller, callee…"
                value={searchInput}
                onChange={e => setSearchInput(e.target.value)}
              />
            </div>
            <input
              type="date"
              className="date-input"
              value={from}
              onChange={e => { setFrom(e.target.value); setPage(1); }}
              title="From date"
            />
            <input
              type="date"
              className="date-input"
              value={to}
              onChange={e => { setTo(e.target.value); setPage(1); }}
              title="To date"
            />
            <button type="submit" className="btn btn-primary btn-sm">Search</button>
            {(search || from || to) && (
              <button type="button" className="btn btn-secondary btn-sm" onClick={handleClear}>
                Clear
              </button>
            )}
          </form>
        </div>

        <DataTable
          headers={['Call ID', 'Caller', 'Callee', 'Direction', 'Status', 'Connect Time', 'Duration', 'Disconnect Reason']}
          rows={rows}
          loading={loading}
          emptyMessage="No call records found"
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
            {Array.from({ length: Math.min(7, totalPages) }, (_, i) => {
              let pn;
              if (totalPages <= 7) pn = i + 1;
              else if (page <= 4) pn = i + 1;
              else if (page >= totalPages - 3) pn = totalPages - 6 + i;
              else pn = page - 3 + i;
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
    </div>
  );
}
