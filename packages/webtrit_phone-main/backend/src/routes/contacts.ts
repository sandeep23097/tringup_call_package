import { Router } from 'express';
import { db } from '../db/connection';
import { requireAuth } from '../middleware/auth';

const router = Router();

// GET /api/v1/user/contacts
router.get('/user/contacts', requireAuth, async (req, res) => {
  const [rows] = await db.query(
    `SELECT u.id, u.email, u.first_name, u.last_name, u.alias_name,
            u.company_name, u.phone_main, u.ext,
            CASE WHEN u.id = ? THEN 1 ELSE 0 END AS is_current_user,
            1 AS is_registered_user,
            CASE WHEN s.id IS NOT NULL THEN 'registered' ELSE 'notregistered' END AS sip_status
     FROM users u
     LEFT JOIN sessions s ON s.user_id = u.id
       AND s.created_at > DATE_SUB(NOW(), INTERVAL 24 HOUR)
     WHERE u.status = 'active'
     ORDER BY u.last_name, u.first_name`,
    [req.userId]
  );

  return res.json({
    items: (rows as any[]).map(u => ({
      user_id:            u.id,
      sip_status:         u.sip_status,
      numbers: {
        main:             u.phone_main || null,
        ext:              u.ext || null,
        additional:       [],
        sms:              [],
      },
      email:              u.email,
      first_name:         u.first_name,
      last_name:          u.last_name,
      alias_name:         u.alias_name,
      company_name:       u.company_name,
      is_current_user:    !!u.is_current_user,
      is_registered_user: !!u.is_registered_user,
    })),
  });
});

// GET /api/v1/user/contacts/:userId
router.get('/user/contacts/:userId', requireAuth, async (req, res) => {
  const [rows] = await db.query(
    `SELECT id, email, first_name, last_name, alias_name, company_name, phone_main, ext
     FROM users WHERE id = ? AND status = 'active'`,
    [req.params.userId]
  );
  const u = (rows as any[])[0];
  if (!u) return res.status(404).json({ code: 'not_found', message: 'Contact not found' });

  return res.json({
    user_id:            u.id,
    sip_status:         'notregistered',
    numbers: { main: u.phone_main, ext: u.ext, additional: [], sms: [] },
    email:              u.email,
    first_name:         u.first_name,
    last_name:          u.last_name,
    alias_name:         u.alias_name,
    company_name:       u.company_name,
    is_current_user:    u.id === req.userId,
    is_registered_user: true,
  });
});

// GET /api/v1/app/status
router.get('/app/status', requireAuth, async (req, res) => {
  const [rows] = await db.query(`SELECT registered FROM app_status WHERE user_id = ?`, [req.userId]);
  return res.json({ register: !!(rows as any[])[0]?.registered });
});

// PATCH /api/v1/app/status
router.patch('/app/status', requireAuth, async (req, res) => {
  const { register } = req.body;
  await db.query(
    `INSERT INTO app_status (user_id, registered) VALUES (?, ?)
     ON DUPLICATE KEY UPDATE registered = VALUES(registered), updated_at = NOW()`,
    [req.userId, register ? 1 : 0]
  );
  return res.status(204).send();
});

// POST /api/v1/app/push-tokens
router.post('/app/push-tokens', requireAuth, async (req, res) => {
  const { type, value } = req.body;
  const [sRows] = await db.query(
    `SELECT id FROM sessions WHERE user_id = ? ORDER BY created_at DESC LIMIT 1`,
    [req.userId]
  );
  const sessionId = (sRows as any[])[0]?.id || null;

  await db.query(
    `INSERT INTO push_tokens (id, user_id, session_id, type, value) VALUES (UUID(), ?, ?, ?, ?)
     ON DUPLICATE KEY UPDATE value = VALUES(value), session_id = VALUES(session_id), updated_at = NOW()`,
    [req.userId, sessionId, type, value]
  );
  return res.status(204).send();
});

// POST /api/v1/app/contacts
router.post('/app/contacts', requireAuth, async (_req, res) => res.status(204).send());

// GET /api/v1/app/contacts/smart
router.get('/app/contacts/smart', requireAuth, async (_req, res) => res.json({ items: [] }));

export default router;
