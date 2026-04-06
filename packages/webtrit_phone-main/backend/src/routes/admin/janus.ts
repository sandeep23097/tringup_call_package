import { Router } from 'express';
import axios from 'axios';
import { requireAdmin } from './middleware';
import { config } from '../../config';

const router = Router();

// GET /admin/janus/health
router.get('/janus/health', requireAdmin, async (_req, res) => {
  try {
    // The Janus /info endpoint returns server info without authentication
    const janusInfoUrl = config.janusUrl + '/info';
    const response = await axios.get(janusInfoUrl, { timeout: 5000 });

    // Janus wraps the info in { janus: 'server_info', ... }
    const data = response.data;
    if (data.janus === 'server_info') {
      return res.json(data);
    }
    return res.json(data);
  } catch (err: any) {
    console.error('Admin GET /janus/health error:', err.message);
    return res.status(502).json({
      code:    'janus_unreachable',
      message: `Cannot reach Janus at ${config.janusUrl}: ${err.message}`,
    });
  }
});

export default router;
