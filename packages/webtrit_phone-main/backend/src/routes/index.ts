import { Router } from 'express';
import systemRouter        from './system';
import sessionRouter       from './session';
import userRouter          from './user';
import contactsRouter      from './contacts';
import historyRouter       from './history';
import voicemailRouter     from './voicemail';
import notificationsRouter from './notifications';

const router = Router();

router.use('/', systemRouter);
router.use('/', sessionRouter);
router.use('/', userRouter);
router.use('/', contactsRouter);
router.use('/', historyRouter);
router.use('/', voicemailRouter);
router.use('/', notificationsRouter);

// Custom demo endpoints
router.post('/custom/private/call-to-actions', (_req, res) => {
  res.json({ actions: [] });
});

// Catch-all for unimplemented custom endpoints — app handles 404 gracefully
router.all('/custom/*', (_req, res) => res.status(404).json({ code: 'not_found', message: 'Not implemented' }));

export default router;

