import React, { useEffect, useState } from 'react';
import client from '../api/client';
import { useToast } from '../components/Toast';

function InfoRow({ label, value }) {
  return (
    <div className="janus-status-row">
      <span className="janus-status-label">{label}</span>
      <span className="janus-status-value">{value || '—'}</span>
    </div>
  );
}

export default function JanusHealth() {
  const toast = useToast();
  const [info, setInfo] = useState(null);
  const [loading, setLoading] = useState(true);
  const [lastRefresh, setLastRefresh] = useState(null);

  const fetchHealth = async () => {
    setLoading(true);
    try {
      const res = await client.get('/admin/janus/health');
      setInfo(res.data);
      setLastRefresh(new Date());
    } catch {
      setInfo(null);
      toast.error('Failed to reach Janus server');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { fetchHealth(); }, []);

  const plugins = info?.plugins ? Object.entries(info.plugins) : [];
  const transports = info?.transports ? Object.entries(info.transports) : [];

  return (
    <div>
      <div className="page-header">
        <div className="page-header-left">
          <h2>Janus Health</h2>
          <p>
            {lastRefresh
              ? `Last refreshed: ${lastRefresh.toLocaleTimeString()}`
              : 'WebRTC Gateway status'}
          </p>
        </div>
        <button className="btn btn-primary" onClick={fetchHealth} disabled={loading}>
          {loading ? <><span className="spinner spinner-sm" /> Refreshing…</> : '🔄 Refresh'}
        </button>
      </div>

      {loading ? (
        <div className="loading-state">
          <div className="spinner" />
          <span>Querying Janus server…</span>
        </div>
      ) : !info ? (
        <div className="card">
          <div className="card-body">
            <div className="empty-state">
              <div className="empty-icon">🔌</div>
              <h3>Janus Unreachable</h3>
              <p>Could not connect to the Janus WebRTC gateway. Check your JANUS_URL configuration.</p>
              <button className="btn btn-primary mt-3" onClick={fetchHealth}>
                Try Again
              </button>
            </div>
          </div>
        </div>
      ) : (
        <div className="janus-grid">
          <div>
            <div className="card mb-4">
              <div className="card-header">
                <span className="card-title">Server Info</span>
                <span className="status-dot online">Online</span>
              </div>
              <div className="card-body">
                <InfoRow label="Name" value={info.name} />
                <InfoRow label="Version" value={info.version_string || info.version} />
                <InfoRow label="Author" value={info.author} />
                <InfoRow label="Commit Hash" value={info.commit_hash?.slice(0, 12)} />
                <InfoRow label="Compile Time" value={info.compile_time} />
                <InfoRow label="Log Level" value={info.log_level} />
              </div>
            </div>

            <div className="card">
              <div className="card-header">
                <span className="card-title">Network</span>
              </div>
              <div className="card-body">
                <InfoRow label="Local IP" value={info.local_ip} />
                <InfoRow label="Public IP" value={info.public_ip} />
                <InfoRow label="IPv6" value={info.ipv6 ? 'Enabled' : 'Disabled'} />
                <InfoRow label="ICE Lite" value={info.ice_lite ? 'Yes' : 'No'} />
                <InfoRow label="ICE TCP" value={info.ice_tcp ? 'Enabled' : 'Disabled'} />
                <InfoRow
                  label="ICE Servers"
                  value={
                    info.ice_servers?.length
                      ? info.ice_servers.join(', ')
                      : 'None configured'
                  }
                />
              </div>
            </div>
          </div>

          <div>
            <div className="card mb-4">
              <div className="card-header">
                <span className="card-title">Plugins ({plugins.length})</span>
              </div>
              <div className="card-body">
                {plugins.length === 0 ? (
                  <p className="text-muted text-sm">No plugins loaded</p>
                ) : (
                  <div className="plugin-list">
                    {plugins.map(([key, plugin]) => (
                      <div key={key} className="plugin-item">
                        <span className="plugin-icon">🔌</span>
                        <div>
                          <div style={{ fontWeight: 500, fontSize: '0.82rem' }}>
                            {plugin.name || key}
                          </div>
                          <div className="text-muted text-xs">{plugin.version_string || plugin.version || ''}</div>
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </div>

            <div className="card">
              <div className="card-header">
                <span className="card-title">Transports ({transports.length})</span>
              </div>
              <div className="card-body">
                {transports.length === 0 ? (
                  <p className="text-muted text-sm">No transports loaded</p>
                ) : (
                  <div className="plugin-list">
                    {transports.map(([key, transport]) => (
                      <div key={key} className="plugin-item">
                        <span className="plugin-icon">🚌</span>
                        <div>
                          <div style={{ fontWeight: 500, fontSize: '0.82rem' }}>
                            {transport.name || key}
                          </div>
                          <div className="text-muted text-xs">{transport.version_string || transport.version || ''}</div>
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
