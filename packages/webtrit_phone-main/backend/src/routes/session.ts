import { Router } from 'express';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import { v4 as uuidv4 } from 'uuid';
import { db } from '../db/connection';
import { config } from '../config';
import { requireAuth } from '../middleware/auth';

const router = Router();

// POST /api/v1/session
router.post('/session', async (req, res) => {
  try {
    const { type, identifier, login, password } = req.body;
    if (!login || !password) {
      return res.status(422).json({ code: 'invalid_request', message: 'login and password are required' });
    }

    const [rows] = await db.query(
      `SELECT id, password_hash, tenant_id FROM users
       WHERE (email = ? OR sip_username = ?) AND status != 'blocked'`,
      [login, login]
    );
    const user = (rows as any[])[0];

    if (!user || !(await bcrypt.compare(password, user.password_hash))) {
      return res.status(422).json({ code: 'invalid_credentials', message: 'Invalid login or password' });
    }

    const token = jwt.sign({ userId: user.id }, config.jwtSecret, { expiresIn: '90d' });
    await db.query(
      `INSERT INTO sessions (id, user_id, token, app_type, bundle_id) VALUES (?, ?, ?, ?, ?)`,
      [uuidv4(), user.id, token, type || 'unknown', req.body.bundle_id || null]
    );

    return res.json({ token, user_id: user.id, tenant_id: user.tenant_id || identifier || '' });
  } catch (err) {
    console.error('Login error:', err);
    return res.status(500).json({ code: 'internal_error', message: 'Internal server error' });
  }
});

// POST /api/v1/session/otp-create
router.post('/session/otp-create', async (req, res) => {
  const { identifier, user_ref } = req.body;
  const [rows] = await db.query(
    `SELECT id FROM users WHERE email = ? OR phone_main = ?`, [user_ref, user_ref]
  );
  const user = (rows as any[])[0];
  if (!user) return res.status(422).json({ code: 'user_not_found', message: 'User not found' });

  const code = Math.floor(100000 + Math.random() * 900000).toString();
  const otpId = uuidv4();
  await db.query(
    `INSERT INTO otp_codes (id, user_id, code, expires_at) VALUES (?, ?, ?, DATE_ADD(NOW(), INTERVAL 10 MINUTE))`,
    [otpId, user.id, code]
  );
  console.log(`[OTP] ${user_ref} → ${code}`); // Remove in production
  return res.json({ otp_id: otpId, notification_type: 'sms', from_email: null, tenant_id: identifier || '' });
});

// POST /api/v1/session/otp-verify
router.post('/session/otp-verify', async (req, res) => {
  const { otp_id, code } = req.body;
  const [rows] = await db.query(
    `SELECT id, user_id, code, expires_at, used FROM otp_codes WHERE id = ?`, [otp_id]
  );
  const otp = (rows as any[])[0];

  if (!otp || otp.used || new Date(otp.expires_at) < new Date() || otp.code !== code) {
    return res.status(422).json({ code: 'invalid_otp', message: 'Invalid or expired OTP' });
  }

  await db.query(`UPDATE otp_codes SET used = 1 WHERE id = ?`, [otp.id]);
  const token = jwt.sign({ userId: otp.user_id }, config.jwtSecret, { expiresIn: '90d' });
  await db.query(
    `INSERT INTO sessions (id, user_id, token, app_type) VALUES (?, ?, ?, 'otp')`,
    [uuidv4(), otp.user_id, token]
  );
  const [uRows] = await db.query(`SELECT tenant_id FROM users WHERE id = ?`, [otp.user_id]);
  return res.json({ token, user_id: otp.user_id, tenant_id: (uRows as any[])[0]?.tenant_id || '' });
});

// POST /api/v1/session/auto-provision
router.post('/session/auto-provision', async (req, res) => {
  const { config_token, type } = req.body;
  const [rows] = await db.query(
    `SELECT user_id FROM provision_tokens WHERE token = ? AND used = 0 AND expires_at > NOW()`,
    [config_token]
  );
  const pt = (rows as any[])[0];
  if (!pt) return res.status(422).json({ code: 'invalid_token', message: 'Invalid or expired token' });

  await db.query(`UPDATE provision_tokens SET used = 1 WHERE token = ?`, [config_token]);
  const token = jwt.sign({ userId: pt.user_id }, config.jwtSecret, { expiresIn: '90d' });
  await db.query(
    `INSERT INTO sessions (id, user_id, token, app_type) VALUES (?, ?, ?, ?)`,
    [uuidv4(), pt.user_id, token, type || 'unknown']
  );
  return res.json({ token, user_id: pt.user_id, tenant_id: '' });
});

// DELETE /api/v1/session
router.delete('/session', requireAuth, async (req, res) => {
  const token = req.headers.authorization!.slice(7);
  await db.query(`DELETE FROM sessions WHERE token = ?`, [token]);
  return res.status(204).send();
});

export default router;
