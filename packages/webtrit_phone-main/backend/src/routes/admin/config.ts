import { Router } from 'express';
import { db } from '../../db/connection';
import { requireAdmin } from './middleware';
import { config } from '../../config';

const router = Router();

// Keys that are editable via the app_config table
const EDITABLE_KEYS = ['JANUS_URL', 'GORUSH_URL', 'APP_VERSION'];

// GET /admin/config
router.get('/config', requireAdmin, async (_req, res) => {
  try {
    // Load overrides from app_config table
    const [rows] = await db.query('SELECT key_name, value FROM app_config');
    const overrides: Record<string, string> = {};
    (rows as any[]).forEach(r => { overrides[r.key_name] = r.value; });

    return res.json({
      // Editable (from DB override or env fallback)
      JANUS_URL:   overrides['JANUS_URL']   || config.janusUrl,
      GORUSH_URL:  overrides['GORUSH_URL']  || config.gorushUrl,
      APP_VERSION: overrides['APP_VERSION'] || config.appVersion,
      // Masked secret
      JWT_SECRET:  '••••••••' + (config.jwtSecret.slice(-4) || ''),
      // Read-only env/config values
      PORT:    process.env.PORT    || String(config.port),
      DB_HOST: process.env.DB_HOST || config.db.host,
      DB_PORT: process.env.DB_PORT || String(config.db.port),
      DB_NAME: process.env.DB_NAME || config.db.name,
    });
  } catch (err) {
    console.error('Admin GET /config error:', err);
    return res.status(500).json({ code: 'server_error', message: 'Failed to fetch config' });
  }
});

// PUT /admin/config
router.put('/config', requireAdmin, async (req, res) => {
  const updates: Record<string, string> = {};

  // Only allow editing of EDITABLE_KEYS
  EDITABLE_KEYS.forEach(key => {
    if (req.body[key] !== undefined) {
      updates[key] = String(req.body[key]);
    }
  });

  if (Object.keys(updates).length === 0) {
    return res.status(400).json({ code: 'bad_request', message: 'No editable config keys provided' });
  }

  try {
    // Upsert each key into app_config
    await Promise.all(
      Object.entries(updates).map(([key, value]) =>
        db.query(
          `INSERT INTO app_config (key_name, value) VALUES (?, ?)
           ON DUPLICATE KEY UPDATE value = VALUES(value)`,
          [key, value]
        )
      )
    );

    // Apply changes to the runtime config object
    if (updates['JANUS_URL'])   (config as any).janusUrl  = updates['JANUS_URL'];
    if (updates['GORUSH_URL'])  (config as any).gorushUrl = updates['GORUSH_URL'];
    if (updates['APP_VERSION']) (config as any).appVersion = updates['APP_VERSION'];

    return res.json({ success: true, updated: updates });
  } catch (err) {
    console.error('Admin PUT /config error:', err);
    return res.status(500).json({ code: 'server_error', message: 'Failed to save config' });
  }
});

export default router;
