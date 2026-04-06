import { Router } from 'express';
import axios from 'axios';
import { requireAdmin } from './middleware';
import { config } from '../../config';

const router = Router();

// GET /admin/gorush/health  — proxy to Gorush /healthz
router.get('/gorush/health', requireAdmin, async (_req, res) => {
  try {
    const response = await axios.get(`${config.gorushUrl}/healthz`, { timeout: 5000 });
    return res.json({ ok: true, status: response.status, data: response.data });
  } catch (err: any) {
    return res.status(502).json({
      ok: false,
      code: 'gorush_unreachable',
      message: `Cannot reach Gorush at ${config.gorushUrl}: ${err.message}`,
    });
  }
});

// GET /admin/gorush/stats  — proxy to Gorush /sys/stats
router.get('/gorush/stats', requireAdmin, async (_req, res) => {
  try {
    const response = await axios.get(`${config.gorushUrl}/sys/stats`, { timeout: 5000 });
    return res.json(response.data);
  } catch (err: any) {
    return res.status(502).json({
      code: 'gorush_unreachable',
      message: `Cannot reach Gorush at ${config.gorushUrl}: ${err.message}`,
    });
  }
});

// POST /admin/gorush/test-push  — send a raw test push via Gorush
router.post('/gorush/test-push', requireAdmin, async (req, res) => {
  const { token, type, title, body, data } = req.body;
  if (!token || !type) {
    return res.status(400).json({ message: 'token and type are required' });
  }

  const platform = (type === 'fcm' || type === 'hms') ? 2 : 1;
  const notification: any = {
    tokens:   [token],
    platform,
    priority: 'high',
    title:    title  || 'Test Push',
    body:     body   || 'Hello from WebtRit Admin',
    ...(data ? { data } : {}),
    ...(type === 'apkvoip' ? { voip: true, content_available: true } : {}),
  };

  try {
    const response = await axios.post(`${config.gorushUrl}/api/push`, {
      notifications: [notification],
    }, { timeout: 10000 });
    return res.json({ ok: true, gorush: response.data });
  } catch (err: any) {
    return res.status(502).json({
      ok: false,
      message: `Gorush push failed: ${err.response?.data?.message || err.message}`,
    });
  }
});

export default router;
