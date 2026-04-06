import React from 'react';

export default function ConfirmModal({
  open,
  title = 'Confirm Action',
  message,
  confirmLabel = 'Confirm',
  confirmVariant = 'danger',
  onConfirm,
  onCancel,
  loading = false,
}) {
  if (!open) return null;

  return (
    <div className="modal-overlay" onClick={onCancel}>
      <div className="modal" onClick={e => e.stopPropagation()}>
        <div className="modal-header">
          <span className="modal-title">{title}</span>
          <button className="modal-close" onClick={onCancel}>✕</button>
        </div>
        <div className="modal-body">
          <div className="modal-icon">
            {confirmVariant === 'danger' ? '⚠️' : '❓'}
          </div>
          <p className="modal-message">{message}</p>
        </div>
        <div className="modal-footer">
          <button className="btn btn-secondary" onClick={onCancel} disabled={loading}>
            Cancel
          </button>
          <button
            className={`btn btn-${confirmVariant}`}
            onClick={onConfirm}
            disabled={loading}
          >
            {loading ? <><span className="spinner spinner-sm" /> Processing...</> : confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
