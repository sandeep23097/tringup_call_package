import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { v4 as uuidv4 } from 'uuid';
import { db } from '../../db/connection';
import { requireAdmin } from './middleware';

const router = Router();

// GET /admin/users?page=1&limit=20&search=
router.get('/users', requireAdmin, async (req, res) => {
  const page   = Math.max(1, parseInt(req.query.page as string) || 1);
  const limit  = Math.min(100, parseInt(req.query.limit as string) || 20);
  const search = (req.query.search as string || '').trim();
  const offset = (page - 1) * limit;

  try {
    let whereClause = '';
    const params: any[] = [];

    if (search) {
      whereClause = `WHERE (first_name LIKE ? OR last_name LIKE ? OR email LIKE ? OR phone_main LIKE ? OR ext LIKE ?)`;
      const like = `%${search}%`;
      params.push(like, like, like, like, like);
    }

    const [countRows] = await db.query(
      `SELECT COUNT(*) AS total FROM users ${whereClause}`,
      params
    );
    const total = (countRows as any[])[0].total;

    const [rows] = await db.query(
      `SELECT id, email, first_name, last_name, phone_main, ext, sip_username, status, created_at
       FROM users ${whereClause}
       ORDER BY created_at DESC
       LIMIT ? OFFSET ?`,
      [...params, limit, offset]
    );

    return res.json({ users: rows, total, page, limit });
  } catch (err) {
    console.error('Admin GET /users error:', err);
    return res.status(500).json({ code: 'server_error', message: 'Failed to fetch users' });
  }
});

// POST /admin/users
router.post('/users', requireAdmin, async (req, res) => {
  const { first_name, last_name, email, phone_main, ext, sip_username, password, status = 'active' } = req.body;

  if (!email || !password) {
    return res.status(400).json({ code: 'bad_request', message: 'Email and password are required' });
  }

  try {
    const id           = uuidv4();
    const password_hash = await bcrypt.hash(password, 10);

    await db.query(
      `INSERT INTO users (id, email, password_hash, first_name, last_name, phone_main, ext, sip_username, status)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [id, email, password_hash, first_name || null, last_name || null, phone_main || null, ext || null, sip_username || null, status]
    );

    const [rows] = await db.query('SELECT * FROM users WHERE id = ?', [id]);
    return res.status(201).json((rows as any[])[0]);
  } catch (err: any) {
    if (err.code === 'ER_DUP_ENTRY') {
      return res.status(409).json({ code: 'conflict', message: 'Email, phone, ext, or SIP username already in use' });
    }
    console.error('Admin POST /users error:', err);
    return res.status(500).json({ code: 'server_error', message: 'Failed to create user' });
  }
});

// GET /admin/users/:id
router.get('/users/:id', requireAdmin, async (req, res) => {
  try {
    const [rows] = await db.query(
      `SELECT id, email, first_name, last_name, phone_main, ext, sip_username, status, created_at
       FROM users WHERE id = ?`,
      [req.params.id]
    );
    const user = (rows as any[])[0];
    if (!user) return res.status(404).json({ code: 'not_found', message: 'User not found' });
    return res.json(user);
  } catch (err) {
    console.error('Admin GET /users/:id error:', err);
    return res.status(500).json({ code: 'server_error', message: 'Failed to fetch user' });
  }
});

// PUT /admin/users/:id
router.put('/users/:id', requireAdmin, async (req, res) => {
  const { first_name, last_name, email, phone_main, ext, sip_username, password, status } = req.body;

  try {
    const fields: string[] = [];
    const values: any[]    = [];

    if (first_name  !== undefined) { fields.push('first_name = ?');  values.push(first_name); }
    if (last_name   !== undefined) { fields.push('last_name = ?');   values.push(last_name); }
    if (email       !== undefined) { fields.push('email = ?');       values.push(email); }
    if (phone_main  !== undefined) { fields.push('phone_main = ?');  values.push(phone_main || null); }
    if (ext         !== undefined) { fields.push('ext = ?');         values.push(ext || null); }
    if (sip_username !== undefined) { fields.push('sip_username = ?'); values.push(sip_username || null); }
    if (status      !== undefined) { fields.push('status = ?');      values.push(status); }

    if (password && password.trim()) {
      const hash = await bcrypt.hash(password, 10);
      fields.push('password_hash = ?');
      values.push(hash);
    }

    if (fields.length === 0) {
      return res.status(400).json({ code: 'bad_request', message: 'No fields to update' });
    }

    values.push(req.params.id);
    const [result] = await db.query(
      `UPDATE users SET ${fields.join(', ')} WHERE id = ?`,
      values
    );

    if ((result as any).affectedRows === 0) {
      return res.status(404).json({ code: 'not_found', message: 'User not found' });
    }

    const [rows] = await db.query(
      'SELECT id, email, first_name, last_name, phone_main, ext, sip_username, status FROM users WHERE id = ?',
      [req.params.id]
    );
    return res.json((rows as any[])[0]);
  } catch (err: any) {
    if (err.code === 'ER_DUP_ENTRY') {
      return res.status(409).json({ code: 'conflict', message: 'Email, phone, ext, or SIP username already in use' });
    }
    console.error('Admin PUT /users/:id error:', err);
    return res.status(500).json({ code: 'server_error', message: 'Failed to update user' });
  }
});

// DELETE /admin/users/:id
router.delete('/users/:id', requireAdmin, async (req, res) => {
  const hard = req.query.hard === 'true';
  try {
    if (hard) {
      await db.query('DELETE FROM users WHERE id = ?', [req.params.id]);
    } else {
      const [result] = await db.query(
        `UPDATE users SET status = 'inactive' WHERE id = ?`,
        [req.params.id]
      );
      if ((result as any).affectedRows === 0) {
        return res.status(404).json({ code: 'not_found', message: 'User not found' });
      }
    }
    return res.status(204).send();
  } catch (err) {
    console.error('Admin DELETE /users/:id error:', err);
    return res.status(500).json({ code: 'server_error', message: 'Failed to delete user' });
  }
});

export default router;
