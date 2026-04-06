import { Router } from 'express';
import jwt from 'jsonwebtoken';
import { db } from '../../db/connection';
import { config } from '../../config';

const router = Router();

// Server-to-server auth: verify shared integration key
router.use((req, res, next) => {
  const key = req.headers['x-integration-key'];
  if (!key || key !== config.integrationApiKey) {
    return res.status(401).json({ error: 'Invalid integration key' });
  }
  next();
});

/**
 * POST /integration/token
 * Chat backend calls this to get a call JWT for a user.
 * Body: { userId, phoneNumber, firstName?, lastName? }
 */
router.post('/token', async (req, res) => {
  const { userId, phoneNumber, firstName, lastName } = req.body;
  if (!userId || !phoneNumber) {
    return res.status(400).json({ error: 'userId and phoneNumber are required' });
  }

  await db.query(
    `INSERT INTO users (id, phone_main, first_name, last_name, status)
     VALUES (?, ?, ?, ?, 'active')
     ON DUPLICATE KEY UPDATE
       phone_main = VALUES(phone_main),
       first_name = VALUES(first_name),
       last_name  = VALUES(last_name),
       status     = 'active'`,
    [userId, phoneNumber, firstName ?? '', lastName ?? ''],
  );

  const token = jwt.sign({ userId }, config.jwtSecret, { expiresIn: '24h' });
  return res.json({ token, expiresIn: 86400 });
});

/**
 * DELETE /integration/users/:userId
 * Deactivate a user on logout.
 */
router.delete('/users/:userId', async (req, res) => {
  await db.query(`UPDATE users SET status = 'inactive' WHERE id = ?`, [req.params.userId]);
  return res.json({ ok: true });
});

/**
 * GET /integration/users/:userId/status
 * Check if user is currently connected to signaling.
 */
router.get('/users/:userId/status', async (_req, res) => {
  const { cm } = await import('../../signaling/connection-manager');
  const conn = cm.get(_req.params.userId);
  return res.json({ online: !!conn });
});

export default router;
