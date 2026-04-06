import { Router } from 'express';
import { db } from '../db/connection';
import { requireAuth } from '../middleware/auth';

const router = Router();

// GET /api/v1/user
router.get('/user', requireAuth, async (req, res) => {
  const [rows] = await db.query(
    `SELECT id, email, first_name, last_name, alias_name, company_name,
            time_zone, status, phone_main, ext
     FROM users WHERE id = ?`,
    [req.userId]
  );
  const u = (rows as any[])[0];
  if (!u) return res.status(422).json({ code: 'refresh_token_invalid', message: 'User not found' });

  return res.json({
    status:       u.status || 'active',
    numbers: {
      main:       u.phone_main || null,
      ext:        u.ext || null,
      additional: [],
      sms:        u.phone_main ? [u.phone_main] : [],
    },
    email:        u.email,
    first_name:   u.first_name,
    last_name:    u.last_name,
    alias_name:   u.alias_name,
    company_name: u.company_name,
    time_zone:    u.time_zone || 'UTC',
  });
});

// DELETE /api/v1/user
router.delete('/user', requireAuth, async (req, res) => {
  await db.query(`DELETE FROM users WHERE id = ?`, [req.userId]);
  return res.status(204).send();
});

export default router;
