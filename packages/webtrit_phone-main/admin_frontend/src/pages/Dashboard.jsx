import React, { useEffect, useState } from 'react';
import client from '../api/client';
import StatCard from '../components/StatCard';
import DataTable from '../components/DataTable';

function formatDuration(seconds) {
  if (!seconds) return '0s';
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return m > 0 ? `${m}m ${s}s` : `${s}s`;
}

function Badge({ status }) {
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

export default function Dashboard() {
  const [stats, setStats] = useState(null);
  const [recentCalls, setRecentCalls] = useState([]);
  const [janusInfo, setJanusInfo] = useState(null);
  const [loading, setLoading] = useState(true);

  const fetchData = async () => {
    try {
      const [statsRes, callsRes, janusRes] = await Promise.allSettled([
        client.get('/admin/stats'),
        client.get('/admin/calls/history?page=1&limit=10'),
        client.get('/admin/janus/health'),
      ]);
      if (statsRes.status === 'fulfilled') setStats(statsRes.value.data);
      if (callsRes.status === 'fulfilled') setRecentCalls(callsRes.value.data.calls || []);
      if (janusRes.status === 'fulfilled') setJanusInfo(janusRes.value.data);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { fetchData(); }, []);

  const callRows = recentCalls.map(c => [
    <span className="font-mono text-xs">{c.call_id?.slice(0, 12)}…</span>,
    c.caller,
    c.callee,
    c.direction,
    <Badge status={c.status} />,
    c.connect_time ? new Date(c.connect_time).toLocaleString() : '—',
    formatDuration(c.duration),
  ]);

  return (
    <div>
      <div className="page-header">
        <div className="page-header-left">
          <h2>Dashboard</h2>
          <p>Overview of your WebtRit system</p>
        </div>
        <button className="btn btn-secondary btn-sm" onClick={() => { setLoading(true); fetchData(); }}>
          🔄 Refresh
        </button>
      </div>

      <div className="stats-grid">
        <StatCard
          icon="👥"
          title="Total Users"
          value={loading ? '…' : (stats?.totalUsers ?? 0)}
          color="blue"
        />
        <StatCard
          icon="🔴"
          title="Active Calls"
          value={loading ? '…' : (stats?.activeCalls ?? 0)}
          color="red"
        />
        <StatCard
          icon="📞"
          title="Calls Today"
          value={loading ? '…' : (stats?.totalCallsToday ?? 0)}
          color="green"
        />
        <StatCard
          icon="🔔"
          title="Push Tokens"
          value={loading ? '…' : (stats?.pushTokensCount ?? 0)}
          color="purple"
        />
      </div>

      <div className="dashboard-grid">
        <div className="card">
          <div className="card-header">
            <span className="card-title">Recent Call Logs</span>
            <a href="/calls" className="btn btn-ghost btn-sm">View All →</a>
          </div>
          <DataTable
            headers={['Call ID', 'Caller', 'Callee', 'Direction', 'Status', 'Time', 'Duration']}
            rows={callRows}
            loading={loading}
            emptyMessage="No calls yet"
          />
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>
          <div className="card">
            <div className="card-header">
              <span className="card-title">Janus Gateway</span>
              <span className={`status-dot ${janusInfo ? 'online' : 'offline'}`}>
                {janusInfo ? 'Online' : 'Offline'}
              </span>
            </div>
            <div className="card-body">
              {janusInfo ? (
                <div>
                  <div className="janus-status-row">
                    <span className="janus-status-label">Version</span>
                    <span className="janus-status-value">{janusInfo.version_string || janusInfo.version || '—'}</span>
                  </div>
                  <div className="janus-status-row">
                    <span className="janus-status-label">Server Name</span>
                    <span className="janus-status-value">{janusInfo.name || '—'}</span>
                  </div>
                  <div className="janus-status-row">
                    <span className="janus-status-label">Author</span>
                    <span className="janus-status-value">{janusInfo.author || '—'}</span>
                  </div>
                  <div className="janus-status-row">
                    <span className="janus-status-label">Plugins</span>
                    <span className="janus-status-value">
                      {janusInfo.plugins ? Object.keys(janusInfo.plugins).length : '—'}
                    </span>
                  </div>
                </div>
              ) : (
                <div className="empty-state" style={{ padding: '20px' }}>
                  <span>⚠️ Unable to reach Janus</span>
                </div>
              )}
            </div>
          </div>

          <div className="card">
            <div className="card-header">
              <span className="card-title">Call Statistics</span>
            </div>
            <div className="card-body">
              <div className="janus-status-row">
                <span className="janus-status-label">Answered</span>
                <span className="janus-status-value text-success">{stats?.answeredCalls ?? '—'}</span>
              </div>
              <div className="janus-status-row">
                <span className="janus-status-label">Rejected</span>
                <span className="janus-status-value text-danger">{stats?.rejectedCalls ?? '—'}</span>
              </div>
              <div className="janus-status-row">
                <span className="janus-status-label">This Week</span>
                <span className="janus-status-value">{stats?.totalCallsThisWeek ?? '—'}</span>
              </div>
              <div className="janus-status-row">
                <span className="janus-status-label">Avg Duration</span>
                <span className="janus-status-value">{formatDuration(stats?.avgDuration)}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
