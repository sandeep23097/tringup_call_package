import { Router } from 'express';
import axios from 'axios';
import { db } from '../../db/connection';
import { requireAdmin } from './middleware';
import { config } from '../../config';

const router = Router();

// GET /admin/push-tokens?page=1&limit=20
router.get('/push-tokens', requireAdmin, async (req, res) => {
  const page   = Math.max(1, parseInt(req.query.page as string) || 1);
  const limit  = Math.min(100, parseInt(req.query.limit as string) || 20);
  const offset = (page - 1) * limit;

  try {
    const [countRows] = await db.query('SELECT COUNT(*) AS total FROM push_tokens');
    const total = (countRows as any[])[0].total;

    const [rows] = await db.query(
      `SELECT pt.id, pt.user_id, pt.type, pt.value, pt.updated_at,
              u.email AS user_email,
              CONCAT(COALESCE(u.first_name,''), ' ', COALESCE(u.last_name,'')) AS user_name
       FROM push_tokens pt
       LEFT JOIN users u ON pt.user_id = u.id
       ORDER BY pt.updated_at DESC
       LIMIT ? OFFSET ?`,
      [limit, offset]
    );

    return res.json({ tokens: rows, total, page, limit });
  } catch (err) {
    console.error('Admin GET /push-tokens error:', err);
    return res.status(500).json({ code: 'server_error', message: 'Failed to fetch push tokens' });
  }
});

// DELETE /admin/push-tokens/:id
router.delete('/push-tokens/:id', requireAdmin, async (req, res) => {
  try {
    const [result] = await db.query('DELETE FROM push_tokens WHERE id = ?', [req.params.id]);
    if ((result as any).affectedRows === 0) {
      return res.status(404).json({ code: 'not_found', message: 'Push token not found' });
    }
    return res.status(204).send();
  } catch (err) {
    console.error('Admin DELETE /push-tokens/:id error:', err);
    return res.status(500).json({ code: 'server_error', message: 'Failed to delete push token' });
  }
});

// POST /admin/push-tokens/test
router.post('/push-tokens/test', requireAdmin, async (req, res) => {
  const { token_id, title = 'Test Push', body = 'Hello from WebtRit Admin' } = req.body;

  if (!token_id) {
    return res.status(400).json({ code: 'bad_request', message: 'token_id is required' });
  }

  try {
    // Look up the token details
    const [rows] = await db.query(
      'SELECT id, user_id, type, value FROM push_tokens WHERE id = ?',
      [token_id]
    );
    const tokens = rows as any[];
    if (tokens.length === 0) {
      return res.status(404).json({ code: 'not_found', message: 'Push token not found' });
    }
    const tokenRecord = tokens[0];

    // Build Gorush payload
    const platform = tokenRecord.type === 'apns' ? 1
      : tokenRecord.type === 'fcm'  ? 2
      : tokenRecord.type === 'hms'  ? 8
      : 2;

    const gorushPayload = {
      notifications: [
        {
          tokens:   [tokenRecord.value],
          platform,
          title,
          body,
          data: { type: 'admin_test', timestamp: new Date().toISOString() },
        },
      ],
    };

    const gorushRes = await axios.post(
      `${config.gorushUrl}/api/push`,
      gorushPayload,
      { timeout: 8000 }
    );

    return res.json({
      success: true,
      message: 'Test push sent successfully',
      gorush:  gorushRes.data,
    });
  } catch (err: any) {
    console.error('Admin POST /push-tokens/test error:', err.message);
    return res.status(502).json({
      code:    'push_failed',
      message: `Failed to send push: ${err.message}`,
    });
  }
});

export default router;
