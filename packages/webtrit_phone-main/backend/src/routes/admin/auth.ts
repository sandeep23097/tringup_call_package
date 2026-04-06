import { Router } from 'express';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import { db } from '../../db/connection';
import { config } from '../../config';

const router = Router();

/**
 * POST /admin/auth/login
 * Authenticates an admin user.
 * Checks admin_users table first; falls back to ADMIN_EMAIL / ADMIN_PASSWORD env vars.
 */
router.post('/auth/login', async (req, res) => {
  const { email, password } = req.body;

  if (!email || !password) {
    return res.status(400).json({ code: 'bad_request', message: 'Email and password are required' });
  }

  try {
    // 1. Try DB-based admin users
    const [rows] = await db.query(
      'SELECT id, name, email, password_hash FROM admin_users WHERE email = ?',
      [email]
    );
    const admins = rows as any[];

    if (admins.length > 0) {
      const admin = admins[0];
      const valid = await bcrypt.compare(password, admin.password_hash);
      if (!valid) {
        return res.status(401).json({ code: 'invalid_credentials', message: 'Invalid email or password' });
      }
      const token = jwt.sign(
        { adminId: admin.id, email: admin.email, role: 'admin' },
        config.jwtSecret,
        { expiresIn: '24h' }
      );
      return res.json({
        token,
        admin: { id: admin.id, email: admin.email, name: admin.name },
      });
    }

    // 2. Fallback: env-var credentials
    const envEmail    = process.env.ADMIN_EMAIL    || 'admin@example.com';
    const envPassword = process.env.ADMIN_PASSWORD || 'admin123';
    if (email === envEmail && password === envPassword) {
      const token = jwt.sign(
        { adminId: 'env-admin', email: envEmail, role: 'admin' },
        config.jwtSecret,
        { expiresIn: '24h' }
      );
      return res.json({
        token,
        admin: { id: 'env-admin', email: envEmail, name: 'Administrator' },
      });
    }

    return res.status(401).json({ code: 'invalid_credentials', message: 'Invalid email or password' });
  } catch (err) {
    console.error('Admin login error:', err);
    return res.status(500).json({ code: 'server_error', message: 'Internal server error' });
  }
});

export default router;
