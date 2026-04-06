import React from 'react';

export default function StatCard({ icon, title, value, trend, trendDir, color = 'blue' }) {
  return (
    <div className="stat-card">
      <div className={`stat-icon ${color}`}>
        <span>{icon}</span>
      </div>
      <div className="stat-info">
        <div className="stat-value">{value ?? '—'}</div>
        <div className="stat-label">{title}</div>
        {trend !== undefined && (
          <div className={`stat-trend ${trendDir || ''}`}>{trend}</div>
        )}
      </div>
    </div>
  );
}
