import React, { useEffect, useState, useCallback } from 'react';
import client from '../api/client';
import { useToast } from '../components/Toast';

function InfoRow({ label, value, mono }) {
  return (
    <div className="info-row">
      <span className="info-label">{label}</span>
      <span className={`info-value ${mono ? 'font-mono' : ''}`}>{value ?? '—'}</span>
    </div>
  );
}

function StatusBadge({ ok }) {
  return ok
    ? <span className="badge" style={{ background: '#dcfce7', color: '#15803d' }}>● Online</span>
    : <span className="badge" style={{ background: '#fee2e2', color: '#dc2626' }}>● Offline</span>;
}

export default function GorushHealth() {
  const toast = useToast();

  const [health, setHealth]   = useState(null);
  const [stats, setStats]     = useState(null);
  const [loading, setLoading] = useState(true);
  const [gorushUrl, setGorushUrl] = useState('');

  // Test push form
  const [testForm, setTestForm] = useState({
    token: '',
    type:  'fcm',
    title: 'Test Push',
    body:  'Hello from WebtRit Admin',
    isCallPush: false,
    callId:      '',
    handleValue: '',
    displayName: '',
  });
  const [testLoading, setTestLoading] = useState(false);

  const fetchAll = useCallback(async () => {
    setLoading(true);
    try {
      const [healthRes, statsRes, cfgRes] = await Promise.allSettled([
        client.get('/admin/gorush/health'),
        client.get('/admin/gorush/stats'),
        client.get('/admin/config'),
      ]);
      setHealth(healthRes.status === 'fulfilled' ? healthRes.value.data : { ok: false, message: healthRes.reason?.response?.data?.message || 'Unreachable' });
      setStats(statsRes.status === 'fulfilled' ? statsRes.value.data : null);
      if (cfgRes.status === 'fulfilled') setGorushUrl(cfgRes.value.data.GORUSH_URL || '');
    } catch {
      toast.error('Failed to fetch Gorush status');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { fetchAll(); }, [fetchAll]);

  const handleTestPush = async (e) => {
    e.preventDefault();
    if (!testForm.token) { toast.error('Token is required'); return; }

    setTestLoading(true);
    try {
      const body = {
        token: testForm.token,
        type:  testForm.type,
        title: testForm.title,
        body:  testForm.body,
      };
      if (testForm.isCallPush) {
        body.data = {
          callId:      testForm.callId      || `test-${Date.now()}`,
          handleValue: testForm.handleValue || '+15550000000',
          displayName: testForm.displayName || 'Test Caller',
          hasVideo:    'false',
        };
      }
      const res = await client.post('/admin/gorush/test-push', body);
      toast.success(res.data.ok ? 'Push sent successfully' : 'Gorush responded with error — check below');
    } catch (err) {
      toast.error(err.response?.data?.message || 'Failed to send push');
    } finally {
      setTestLoading(false);
    }
  };

  const gorushOnline = health?.ok === true;

  return (
    <div>
      <div className="page-header">
        <div className="page-header-left">
          <h2>Gorush Health</h2>
          <p>Push notification server status and testing</p>
        </div>
        <button className="btn btn-secondary btn-sm" onClick={fetchAll} disabled={loading}>
          {loading ? <><span className="spinner spinner-sm" /> Loading…</> : '🔄 Refresh'}
        </button>
      </div>

      {/* Status card */}
      <div className="card mb-4">
        <div className="card-header">
          <span className="card-title">📡 Server Status</span>
          <StatusBadge ok={gorushOnline} />
        </div>
        <div className="card-body">
          <InfoRow label="Gorush URL"    value={gorushUrl || '(not set)'} mono />
          <InfoRow label="Reachable"     value={gorushOnline ? 'Yes' : 'No'} />
          {!gorushOnline && health?.message && (
            <div className="alert alert-danger mt-2" style={{ padding: '10px 14px', borderRadius: 6, background: '#fee2e2', color: '#991b1b', fontSize: 13 }}>
              {health.message}
            </div>
          )}
          {gorushOnline && (
            <InfoRow label="HTTP status" value={health?.status} />
          )}
        </div>
      </div>

      {/* System stats */}
      {stats && (
        <div className="card mb-4">
          <div className="card-header">
            <span className="card-title">📊 System Stats</span>
          </div>
          <div className="card-body">
            {stats.cpu_usage    !== undefined && <InfoRow label="CPU Usage"     value={`${stats.cpu_usage?.toFixed?.(1) ?? stats.cpu_usage}%`} />}
            {stats.memory_usage !== undefined && <InfoRow label="Memory Usage"  value={`${(stats.memory_usage / 1024 / 1024).toFixed(1)} MB`} />}
            {stats.total_count  !== undefined && <InfoRow label="Total Sent"    value={stats.total_count} />}
            {stats.ios?.push_success !== undefined && (
              <>
                <InfoRow label="iOS Success"  value={stats.ios.push_success} />
                <InfoRow label="iOS Error"    value={stats.ios.push_error} />
              </>
            )}
            {stats.android?.push_success !== undefined && (
              <>
                <InfoRow label="Android Success" value={stats.android.push_success} />
                <InfoRow label="Android Error"   value={stats.android.push_error} />
              </>
            )}
            {/* Fallback: render all keys generically */}
            {!stats.cpu_usage && !stats.ios && !stats.android && (
              <pre style={{ fontSize: 12, margin: 0, whiteSpace: 'pre-wrap', wordBreak: 'break-all' }}>
                {JSON.stringify(stats, null, 2)}
              </pre>
            )}
          </div>
        </div>
      )}

      {/* Test push form */}
      <div className="card mb-4">
        <div className="card-header">
          <span className="card-title">📤 Send Test Push</span>
        </div>
        <div className="card-body">
          <form onSubmit={handleTestPush}>
            <div className="form-row">
              <div className="form-group">
                <label className="form-label" htmlFor="g-token">Device Token <span className="required">*</span></label>
                <input
                  id="g-token"
                  type="text"
                  className="form-input font-mono"
                  placeholder="FCM or APNs token"
                  value={testForm.token}
                  onChange={e => setTestForm(f => ({ ...f, token: e.target.value }))}
                />
                <p className="form-hint">Copy from Push Tokens page</p>
              </div>
              <div className="form-group">
                <label className="form-label" htmlFor="g-type">Token Type <span className="required">*</span></label>
                <select
                  id="g-type"
                  className="form-input"
                  value={testForm.type}
                  onChange={e => setTestForm(f => ({ ...f, type: e.target.value }))}
                >
                  <option value="fcm">fcm — Android Firebase</option>
                  <option value="hms">hms — Android Huawei</option>
                  <option value="apns">apns — iOS standard</option>
                  <option value="apkvoip">apkvoip — iOS VoIP (PushKit)</option>
                </select>
              </div>
            </div>

            <div className="form-row">
              <div className="form-group">
                <label className="form-label" htmlFor="g-title">Title</label>
                <input
                  id="g-title"
                  type="text"
                  className="form-input"
                  value={testForm.title}
                  onChange={e => setTestForm(f => ({ ...f, title: e.target.value }))}
                />
              </div>
              <div className="form-group">
                <label className="form-label" htmlFor="g-body">Body</label>
                <input
                  id="g-body"
                  type="text"
                  className="form-input"
                  value={testForm.body}
                  onChange={e => setTestForm(f => ({ ...f, body: e.target.value }))}
                />
              </div>
            </div>

            {/* Call push toggle */}
            <div className="form-group">
              <label style={{ display: 'flex', alignItems: 'center', gap: 10, cursor: 'pointer' }}>
                <input
                  type="checkbox"
                  checked={testForm.isCallPush}
                  onChange={e => setTestForm(f => ({ ...f, isCallPush: e.target.checked }))}
                />
                <span className="form-label" style={{ margin: 0 }}>Send as incoming call push (terminated-state test)</span>
              </label>
              <p className="form-hint">Adds the FCM data payload that triggers the native call screen in the Flutter app</p>
            </div>

            {testForm.isCallPush && (
              <div style={{ background: '#f8fafc', border: '1px solid #e2e8f0', borderRadius: 8, padding: '16px', marginBottom: 16 }}>
                <p className="text-muted text-sm mb-3" style={{ marginBottom: 12 }}>
                  These fields populate the <code>data</code> map. <code>callId</code> is the discriminator — the app only shows the call screen when it's present.
                </p>
                <div className="form-row">
                  <div className="form-group">
                    <label className="form-label" htmlFor="g-callid">callId</label>
                    <input
                      id="g-callid"
                      type="text"
                      className="form-input font-mono"
                      placeholder="Auto-generated if empty"
                      value={testForm.callId}
                      onChange={e => setTestForm(f => ({ ...f, callId: e.target.value }))}
                    />
                  </div>
                  <div className="form-group">
                    <label className="form-label" htmlFor="g-handle">handleValue (caller phone)</label>
                    <input
                      id="g-handle"
                      type="text"
                      className="form-input"
                      placeholder="+15550000000"
                      value={testForm.handleValue}
                      onChange={e => setTestForm(f => ({ ...f, handleValue: e.target.value }))}
                    />
                  </div>
                </div>
                <div className="form-group">
                  <label className="form-label" htmlFor="g-display">displayName</label>
                  <input
                    id="g-display"
                    type="text"
                    className="form-input"
                    placeholder="Test Caller"
                    value={testForm.displayName}
                    onChange={e => setTestForm(f => ({ ...f, displayName: e.target.value }))}
                  />
                </div>
              </div>
            )}

            <div className="form-actions">
              <button type="submit" className="btn btn-primary" disabled={testLoading || !gorushOnline}>
                {testLoading
                  ? <><span className="spinner spinner-sm" /> Sending…</>
                  : '📤 Send Push'}
              </button>
              {!gorushOnline && (
                <span style={{ fontSize: 13, color: '#dc2626', marginLeft: 12 }}>
                  Gorush is offline — cannot send
                </span>
              )}
            </div>
          </form>
        </div>
      </div>

      {/* Setup instructions */}
      <div className="card">
        <div className="card-header">
          <span className="card-title">🛠️ Gorush Setup</span>
        </div>
        <div className="card-body">
          <p className="text-muted text-sm mb-3">
            Gorush is a standalone push notification gateway. Run it separately, then point this backend to it via
            the <strong>Gorush URL</strong> setting in the Configuration page.
          </p>

          <div style={{ marginBottom: 20 }}>
            <h4 style={{ marginBottom: 8, fontSize: 14 }}>1. Download Gorush</h4>
            <pre className="code-block">{`# Linux / macOS
curl -L https://github.com/appleboy/gorush/releases/latest/download/gorush-linux-amd64 -o gorush
chmod +x gorush

# Or via Docker
docker pull appleboy/gorush`}</pre>
          </div>

          <div style={{ marginBottom: 20 }}>
            <h4 style={{ marginBottom: 8, fontSize: 14 }}>2. Create gorush.yml</h4>
            <pre className="code-block">{`core:
  port: "8088"
  max_notification: 100

android:
  enabled: true
  key_path: "/path/to/firebase-service-account.json"

ios:
  enabled: true
  key_path: "/path/to/AuthKey_XXXXXXXX.p8"
  key_id: "XXXXXXXX"
  team_id: "YYYYYY"
  production: false`}</pre>
          </div>

          <div style={{ marginBottom: 20 }}>
            <h4 style={{ marginBottom: 8, fontSize: 14 }}>3. Run Gorush</h4>
            <pre className="code-block">{`./gorush -c gorush.yml

# Or Docker
docker run -p 8088:8088 -v $(pwd)/gorush.yml:/config/gorush.yml \\
  appleboy/gorush -c /config/gorush.yml`}</pre>
          </div>

          <div>
            <h4 style={{ marginBottom: 8, fontSize: 14 }}>4. Point backend to Gorush</h4>
            <p className="text-muted text-sm">
              Go to <strong>Configuration</strong> page and set <code>Gorush URL</code> to your Gorush server address,
              e.g. <code>http://your-server-ip:8088</code>.
              Or set it in <code>backend/.env</code>: <code>GORUSH_URL=http://localhost:8088</code>
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
