import { Router } from 'express';
import { db } from '../../db/connection';
import { requireAdmin } from './middleware';
import { getActiveCalls } from '../../admin/active-calls-service';
import { cleanupCall } from '../../signaling/handlers/call-state';

const router = Router();

// GET /admin/calls/history?page=1&limit=20&from=&to=&search=
router.get('/calls/history', requireAdmin, async (req, res) => {
  const page   = Math.max(1, parseInt(req.query.page as string) || 1);
  const limit  = Math.min(100, parseInt(req.query.limit as string) || 20);
  const search = (req.query.search as string || '').trim();
  const from   = req.query.from as string || '';
  const to     = req.query.to   as string || '';
  const offset = (page - 1) * limit;

  const conditions: string[] = [];
  const params: any[]        = [];

  if (search) {
    conditions.push('(cr.caller LIKE ? OR cr.callee LIKE ?)');
    params.push(`%${search}%`, `%${search}%`);
  }
  if (from) {
    conditions.push('DATE(cr.created_at) >= ?');
    params.push(from);
  }
  if (to) {
    conditions.push('DATE(cr.created_at) <= ?');
    params.push(to);
  }

  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';

  try {
    const [countRows] = await db.query(
      `SELECT COUNT(*) AS total FROM call_records cr ${where}`,
      params
    );
    const total = (countRows as any[])[0].total;

    const [rows] = await db.query(
      `SELECT cr.id, cr.call_id, cr.caller, cr.callee, cr.direction, cr.status,
              cr.connect_time, cr.disconnect_time, cr.duration, cr.disconnect_reason,
              cr.created_at,
              CONCAT(u1.first_name, ' ', u1.last_name) AS caller_name,
              CONCAT(u2.first_name, ' ', u2.last_name) AS callee_name
       FROM call_records cr
       LEFT JOIN users u1 ON cr.caller_user_id = u1.id
       LEFT JOIN users u2 ON cr.callee_user_id = u2.id
       ${where}
       ORDER BY cr.created_at DESC
       LIMIT ? OFFSET ?`,
      [...params, limit, offset]
    );

    return res.json({ calls: rows, total, page, limit });
  } catch (err) {
    console.error('Admin GET /calls/history error:', err);
    return res.status(500).json({ code: 'server_error', message: 'Failed to fetch call history' });
  }
});

// GET /admin/calls/active
router.get('/calls/active', requireAdmin, (_req, res) => {
  try {
    const calls = getActiveCalls();
    return res.json({ calls, total: calls.length });
  } catch (err) {
    console.error('Admin GET /calls/active error:', err);
    return res.status(500).json({ code: 'server_error', message: 'Failed to fetch active calls' });
  }
});

// POST /admin/calls/:callId/hangup
router.post('/calls/:callId/hangup', requireAdmin, (req, res) => {
  const { callId } = req.params;
  try {
    cleanupCall(callId);
    return res.json({ success: true, message: `Call ${callId} terminated` });
  } catch (err) {
    console.error('Admin POST /calls/:callId/hangup error:', err);
    return res.status(500).json({ code: 'server_error', message: 'Failed to hangup call' });
  }
});

export default router;
