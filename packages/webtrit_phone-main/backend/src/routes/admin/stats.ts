import { Router } from 'express';
import { db } from '../../db/connection';
import { requireAdmin } from './middleware';
import { getActiveCalls } from '../../admin/active-calls-service';

const router = Router();

// GET /admin/stats
router.get('/stats', requireAdmin, async (_req, res) => {
  try {
    const now   = new Date();
    const today = now.toISOString().slice(0, 10);  // YYYY-MM-DD
    const weekAgo = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);

    const [
      [usersRows],
      [todayRows],
      [weekRows],
      [answeredRows],
      [rejectedRows],
      [avgRows],
      [pushRows],
    ] = await Promise.all([
      db.query('SELECT COUNT(*) AS cnt FROM users WHERE status = ?', ['active']),
      db.query('SELECT COUNT(*) AS cnt FROM call_records WHERE DATE(created_at) = ?', [today]),
      db.query('SELECT COUNT(*) AS cnt FROM call_records WHERE DATE(created_at) >= ?', [weekAgo]),
      db.query('SELECT COUNT(*) AS cnt FROM call_records WHERE status = ?', ['answered']),
      db.query('SELECT COUNT(*) AS cnt FROM call_records WHERE status IN (?, ?)', ['rejected', 'failed']),
      db.query('SELECT AVG(duration) AS avg FROM call_records WHERE status = ? AND duration > 0', ['answered']),
      db.query('SELECT COUNT(*) AS cnt FROM push_tokens', []),
    ]);

    const activeCalls = getActiveCalls();

    return res.json({
      totalUsers:         (usersRows as any[])[0].cnt,
      activeCalls:        activeCalls.length,
      totalCallsToday:    (todayRows as any[])[0].cnt,
      totalCallsThisWeek: (weekRows as any[])[0].cnt,
      answeredCalls:      (answeredRows as any[])[0].cnt,
      rejectedCalls:      (rejectedRows as any[])[0].cnt,
      avgDuration:        Math.round((avgRows as any[])[0].avg || 0),
      pushTokensCount:    (pushRows as any[])[0].cnt,
    });
  } catch (err) {
    console.error('Admin GET /stats error:', err);
    return res.status(500).json({ code: 'server_error', message: 'Failed to fetch stats' });
  }
});

export default router;
