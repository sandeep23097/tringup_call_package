import { Router } from 'express';
import { config } from '../config';

const router = Router();

router.get('/system-info', (_req, res) => {
  res.json({
    core:    { version: config.appVersion },
    postgres: { version: '8.0' },
    adapter: {
      name:      'webtrit-custom',
      version:   config.appVersion,
      supported: ['passwordSignin', 'otpSignin', 'history', 'voicemail'],
      custom:    {},
    },
    janus: {
      version:    '1.1.0',
      plugins:    { sip: { version: '1.0.0' } },
      transports: { websocket: { version: '1.0.0' } },
    },
    gorush: { version: '1.14.0' },
  });
});

export default router;
