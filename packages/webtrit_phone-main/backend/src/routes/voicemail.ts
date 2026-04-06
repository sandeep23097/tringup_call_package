import { Router } from 'express';
import { requireAuth } from '../middleware/auth';

const router = Router();

router.get('/user/voicemails',            requireAuth, (_req, res) => res.json({ items: [] }));
router.get('/user/voicemails/:id',        requireAuth, (_req, res) => res.status(404).json({ code: 'not_found', message: 'Not found' }));
router.patch('/user/voicemails/:id',      requireAuth, (_req, res) => res.status(204).send());
router.delete('/user/voicemails/:id',     requireAuth, (_req, res) => res.status(204).send());
router.get('/user/voicemails/:id/attachment', requireAuth, (_req, res) => res.status(404).json({ code: 'not_found', message: 'Not found' }));

export default router;
