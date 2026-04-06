import { Router } from 'express';
import { db } from '../db/connection';
import { requireAuth } from '../middleware/auth';

const router = Router();

router.get('/user/history', requireAuth, async (req, res) => {
  const { time_from, time_to, items_per_page } = req.query;
  const limit = parseInt(items_per_page as string) || 50;

  const [rows] = await db.query(
    `SELECT call_id, caller, callee, direction, status,
            connect_time, disconnect_time, duration, disconnect_reason, recording_id
     FROM call_records
     WHERE (caller_user_id = ? OR callee_user_id = ?)
       AND (? IS NULL OR connect_time >= ?)
       AND (? IS NULL OR connect_time <= ?)
     ORDER BY connect_time DESC
     LIMIT ?`,
    [req.userId, req.userId,
     time_from || null, time_from || null,
     time_to   || null, time_to   || null,
     limit]
  );

  return res.json({
    items: (rows as any[]).map(r => ({
      call_id:           r.call_id,
      caller:            r.caller,
      callee:            r.callee,
      direction:         r.direction,
      status:            r.status,
      connect_time:      r.connect_time ? new Date(r.connect_time).toISOString() : null,
      disconnect_time:   r.disconnect_time ? new Date(r.disconnect_time).toISOString() : null,
      duration:          r.duration || 0,
      disconnect_reason: r.disconnect_reason || 'normal',
      recording_id:      r.recording_id,
    })),
  });
});

export default router;
