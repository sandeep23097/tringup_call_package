import React from 'react';

export default function DataTable({ headers, rows, loading, emptyMessage = 'No data found' }) {
  if (loading) {
    return (
      <div className="loading-state">
        <div className="spinner" />
        <span>Loading...</span>
      </div>
    );
  }

  if (!rows || rows.length === 0) {
    return (
      <div className="empty-state">
        <div className="empty-icon">📭</div>
        <h3>{emptyMessage}</h3>
        <p>No records to display.</p>
      </div>
    );
  }

  return (
    <div className="table-wrapper">
      <table className="data-table">
        <thead>
          <tr>
            {headers.map((h, i) => (
              <th key={i}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, i) => (
            <tr key={i}>
              {row.map((cell, j) => (
                <td key={j}>{cell}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
