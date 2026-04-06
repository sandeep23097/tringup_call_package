import http from 'http';
import express from 'express';
import cors    from 'cors';
import { config }             from './config';
import apiRouter              from './routes';
import adminRouter            from './routes/admin';
import integrationRouter      from './routes/integration';
import { startSignalingServer } from './signaling/server';
import { testConnection }     from './db/connection';

const app = express();

// Allow requests from admin frontend (Vite dev server) and any configured origin
app.use(cors({
  origin: [
    'http://localhost:5173',
    'http://127.0.0.1:5173',
    ...(process.env.ADMIN_ORIGIN ? [process.env.ADMIN_ORIGIN] : []),
  ],
  credentials: true,
}));
app.use(express.json());

// Strip /tenant/{tenantId} prefix for REST routes only (not WebSocket — handled in signaling server)
app.use((req, _res, next) => {
  const match = req.url.match(/^\/tenant\/[^/]+(\/.*)?$/);
  if (match) req.url = match[1] || '/';
  next();
});

// Mount REST API
app.use('/api/v1', apiRouter);

// Mount Admin API (no tenant prefix stripping needed)
app.use('/admin', adminRouter);

// Mount Integration API (server-to-server, no tenant prefix)
app.use('/integration', integrationRouter);

// Health check
app.get('/health', (_req, res) => res.json({ status: 'ok', ts: new Date().toISOString() }));

// Create a single HTTP server shared by Express + WebSocket
const server = http.createServer(app);

// Start
testConnection().then(() => {
  startSignalingServer(server);
  server.listen(config.port, () => {
    console.log(`Server running on http://0.0.0.0:${config.port} (REST + WebSocket + Admin API)`);
  });
}).catch(err => {
  console.error('Failed to connect to MySQL:', err.message);
  process.exit(1);
});
