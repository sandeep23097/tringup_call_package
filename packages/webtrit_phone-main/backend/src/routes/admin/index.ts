import { Router } from 'express';
import authRouter   from './auth';
import usersRouter  from './users';
import statsRouter  from './stats';
import callsRouter  from './calls';
import janusRouter  from './janus';
import configRouter from './config';
import pushRouter   from './push';
import gorushRouter from './gorush';

const router = Router();

// Auth (no middleware — public)
router.use('/', authRouter);

// Protected routes
router.use('/', usersRouter);
router.use('/', statsRouter);
router.use('/', callsRouter);
router.use('/', janusRouter);
router.use('/', configRouter);
router.use('/', pushRouter);
router.use('/', gorushRouter);

export default router;
