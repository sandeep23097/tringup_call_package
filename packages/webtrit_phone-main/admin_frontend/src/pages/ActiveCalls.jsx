import React, { useEffect, useState, useRef } from 'react';
import client from '../api/client';
import DataTable from '../components/DataTable';
import ConfirmModal from '../components/ConfirmModal';
import { useToast } from '../components/Toast';

function timeAgo(isoString) {
  const start = new Date(isoString);
  const diff = Math.floor((Date.now() - start.getTime()) / 1000);
  if (diff < 60) return `${diff}s`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ${diff % 60}s`;
  return `${Math.floor(diff / 3600)}h ${Math.floor((diff % 3600) / 60)}m`;
}

export default function ActiveCalls() {
  const toast = useToast();
  const [calls, setCalls] = useState([]);
  const [loading, setLoading] = useState(true);
  const [hangupTarget, setHangupTarget] = useState(null);
  const [hanging, setHanging] = useState(false);
  const [tick, setTick] = useState(0);
  const intervalRef = useRef(null);

  const fetchActive = async (silent = false) => {
    if (!silent) setLoading(true);
    try {
      const res = await client.get('/admin/calls/active');
      setCalls(res.data.calls || []);
    } catch {
      if (!silent) toast.error('Failed to load active calls');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchActive();
    intervalRef.current = setInterval(() => {
      fetchActive(true);
      setTick(t => t + 1);
    }, 5000);
    return () => clearInterval(intervalRef.current);
  }, []);

  const handleHangup = async () => {
    if (!hangupTarget) return;
    setHanging(true);
    try {
      await client.post(`/admin/calls/${hangupTarget.callId}/hangup`);
      toast.success(`Call ${hangupTarget.callId} terminated`);
      setHangupTarget(null);
      fetchActive(true);
    } catch {
      toast.error('Failed to hang up call');
    } finally {
      setHanging(false);
    }
  };

  const rows = calls.map(c => [
    <span className="font-mono text-xs" title={c.callId}>{c.callId?.slice(0, 14)}…</span>,
    <span style={{ fontWeight: 500 }}>{c.callerNumber || c.callerUserId}</span>,
    c.calleeNumber || c.calleeUserId,
    <span className="badge badge-active badge-dot">{timeAgo(c.startedAt)}</span>,
    <button
      className="btn btn-danger btn-sm"
      onClick={() => setHangupTarget({ callId: c.callId })}
    >
      📵 Hangup
    </button>,
  ]);

  return (
    <div>
      <div className="page-header">
        <div className="page-header-left">
          <h2>Active Calls</h2>
          <p>Live view — auto-refreshes every 5 seconds</p>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
          <span className="live-indicator">
            <span className="live-dot" />
            LIVE
          </span>
          <span className="badge badge-active">{calls.length} active</span>
          <button className="btn btn-secondary btn-sm" onClick={() => fetchActive()}>
            🔄 Refresh
          </button>
        </div>
      </div>

      <div className="card">
        <DataTable
          headers={['Call ID', 'Caller', 'Callee', 'Duration', 'Action']}
          rows={rows}
          loading={loading}
          emptyMessage="No active calls right now"
        />
      </div>

      <ConfirmModal
        open={!!hangupTarget}
        title="Force Hangup"
        message={
          <span>
            Are you sure you want to force hangup call <strong>{hangupTarget?.callId?.slice(0, 14)}…</strong>?
            Both parties will be disconnected.
          </span>
        }
        confirmLabel="Hang Up"
        confirmVariant="danger"
        onConfirm={handleHangup}
        onCancel={() => setHangupTarget(null)}
        loading={hanging}
      />
    </div>
  );
}
