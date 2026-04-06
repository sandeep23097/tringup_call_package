import { Router } from 'express';
import { db } from '../db/connection';
import { requireAuth } from '../middleware/auth';

const router = Router();

router.get('/user/notifications', requireAuth, async (req, res) => {
  const { created_before, limit } = req.query;
  const [rows] = await db.query(
    `SELECT id, title, content, type, seen, created_at, updated_at, read_at
     FROM notifications
     WHERE user_id = ?
       AND (? IS NULL OR created_at < ?)
     ORDER BY created_at DESC LIMIT ?`,
    [req.userId, created_before || null, created_before || null, parseInt(limit as string) || 20]
  );
  return res.json({ items: rows });
});

router.get('/user/notifications/updates', requireAuth, async (req, res) => {
  const { updated_after, limit } = req.query;
  const [rows] = await db.query(
    `SELECT id, title, content, type, seen, created_at, updated_at, read_at
     FROM notifications
     WHERE user_id = ? AND updated_at > ?
     ORDER BY updated_at DESC LIMIT ?`,
    [req.userId, updated_after || '1970-01-01', parseInt(limit as string) || 20]
  );
  return res.json({ items: rows });
});

router.patch('/user/notifications/:id', requireAuth, async (req, res) => {
  await db.query(
    `UPDATE notifications SET seen = ?, read_at = NOW(), updated_at = NOW()
     WHERE id = ? AND user_id = ?`,
    [req.body.seen ? 1 : 0, req.params.id, req.userId]
  );
  return res.status(204).send();
});

export default router;
