# WebTrit Phone — Backend Implementation Plan

> **Status**: PENDING APPROVAL
> **Goal**: Build a fully compatible backend for `webtrit_phone` with zero client-side code changes.
> **Approach**: Node.js + TypeScript REST API + Phoenix-compatible WebSocket signaling, MySQL 8, Janus for WebRTC, FreeSWITCH for SIP.

---

## Table of Contents

1. [Recommendation Summary](#1-recommendation-summary)
2. [Why Zero Client Changes Are Possible](#2-why-zero-client-changes-are-possible)
3. [Chosen Technology Stack & Rationale](#3-chosen-technology-stack--rationale)
4. [System Architecture](#4-system-architecture)
5. [Project Structure](#5-project-structure)
6. [Phase 0 — Infrastructure Setup](#phase-0--infrastructure-setup-day-1)
7. [Phase 1 — REST API Core (Auth + Profile)](#phase-1--rest-api-core-auth--profile-days-23)
8. [Phase 2 — WebSocket Signaling Server](#phase-2--websocket-signaling-server-days-45)
9. [Phase 3 — App-to-App Internal Calls](#phase-3--app-to-app-internal-calls-days-67)
10. [Phase 4 — Push Notifications](#phase-4--push-notifications-day-8)
11. [Phase 5 — SIP Trunk & PSTN Calls](#phase-5--sip-trunk--pstn-calls-days-912)
12. [Phase 6 — Secondary Features](#phase-6--secondary-features-days-1314)
13. [Database Schema (Full)](#13-database-schema-full)
14. [Nginx Configuration](#14-nginx-configuration)
15. [Environment Variables Reference](#15-environment-variables-reference)
16. [Testing Checklist per Phase](#16-testing-checklist-per-phase)
17. [Deployment Guide](#17-deployment-guide)
18. [Client App Configuration](#18-client-app-configuration)

---

## 1. Recommendation Summary

| Decision | Choice | Reason |
|----------|--------|--------|
| **Language** | Node.js 20 + TypeScript | Widely known, fast to build, huge ecosystem |
| **REST Framework** | Express 4 | Simple, stable, well-documented |
| **WebSocket Protocol** | Raw WS + Phoenix Channels wire format | App uses `phoenix_socket` Dart package — must speak Phoenix protocol |
| **Database** | MySQL 8.0 | Widely hosted, familiar to most developers, full relational support |
| **Session Cache** | Redis 7 | Fast token lookup, WebSocket connection tracking |
| **WebRTC Bridge** | Janus Gateway | Open source, same as original WebTrit, active community |
| **SIP Server** | FreeSWITCH | Easier than Kamailio for beginners, built-in WebRTC support |
| **Push Gateway** | Gorush | Same as original WebTrit, handles FCM + APNS in one service |
| **Reverse Proxy** | Nginx | TLS termination, routes HTTP and WSS to correct services |
| **Containerization** | Docker Compose | Entire stack in one `docker-compose.yml`, easy to replicate |

**Total estimated implementation time**: 14 working days for a full-featured backend.
**Minimum to get calls working (app-to-app)**: 7 working days.

---

## 2. Why Zero Client Changes Are Possible

The app reads the server URL from one of these sources (in priority order):
1. Build-time dart-define: `--dart-define=WEBTRIT_APP_CORE_URL=https://your-server.com`
2. User types URL on the login screen
3. Default demo URL: `http://localhost:4000`

The app then constructs all URLs automatically:
```
REST API:    https://your-server.com/tenant/{tenantId}/api/v1/{endpoint}
WebSocket:  wss://your-server.com/tenant/{tenantId}/signaling/v1?token={token}&force=false
```

If the user's tenant ID is an **empty string** (single-tenant setup), the URLs become:
```
REST API:    https://your-server.com/api/v1/{endpoint}
WebSocket:  wss://your-server.com/signaling/v1?token={token}&force=false
```

**Our implementation will support both patterns** (with and without `/tenant/{id}`), so any user can log in with or without a tenant ID.

**The only client-side change needed** (optional, for production builds only):
```bash
# When building the app for your users:
flutter build apk \
  --flavor deeplinksDisabledSmsReceiverDisabled \
  --dart-define=WEBTRIT_APP_CORE_URL=https://your-server.com
```
This pre-fills the server URL so users don't have to type it. Without this, users type the URL themselves on the login screen — which is perfectly fine for testing.

---

## 3. Chosen Technology Stack & Rationale

### Why Node.js over Elixir Phoenix?

The original WebTrit backend is almost certainly **Elixir Phoenix** (the app depends on `phoenix_socket` Dart package). However, we chose Node.js because:
- Most developers know JavaScript/TypeScript — easier to hire and maintain
- Faster initial development
- The Phoenix Channels wire protocol is simple enough to implement manually in Node.js

### Phoenix Channels Wire Protocol (Critical)

The `phoenix_socket` Dart package expects this **exact WebSocket message format**:
```
[join_ref, message_ref, topic, event, payload]
```

Examples:
```json
// Client joins channel
[1, 1, "signaling:lobby", "phx_join", {}]

// Server reply (ok)
[1, 1, "signaling:lobby", "phx_reply", {"status": "ok", "response": {}}]

// Server pushes event to client
[null, null, "signaling:lobby", "incoming_call", { ...call_data... }]

// Client heartbeat
[null, 5, "phoenix", "heartbeat", {}]

// Server heartbeat reply
[null, 5, "phoenix", "phx_reply", {"status": "ok", "response": {}}]
```

We will implement a small Phoenix protocol adapter in ~100 lines of TypeScript. This is the most critical piece.

---

## 4. System Architecture

```
Internet
   │
   ▼
┌──────────────────────────────────────────────────────┐
│  Nginx (port 443)                                     │
│  ├── /api/         → Node.js Express   (port 3000)   │
│  ├── /signaling/   → Node.js WS Server (port 3001)   │
│  └── /janus/       → Janus REST API   (port 8088)    │
└──────────────────────────────────────────────────────┘
         │                │               │
         ▼                ▼               ▼
   ┌──────────┐    ┌──────────┐    ┌──────────────┐
   │ Express  │    │ WS (sig- │    │    Janus     │
   │ REST API │    │ naling)  │    │  WebRTC GW   │
   └────┬─────┘    └────┬─────┘    └──────┬───────┘
        │               │                 │
        └───────┬────────┘         ┌──────┘
                │                  │ SIP
                ▼                  ▼
        ┌──────────────┐    ┌──────────────┐
        │   MySQL 8    │    │  FreeSWITCH  │
        │  + Redis     │    │  SIP Server  │
        └──────────────┘    └──────────────┘
                                   │
                            ┌──────┘
                            ▼
                     ┌─────────────┐
                     │   Gorush    │
                     │  (FCM/APNS) │
                     └─────────────┘
```

All services run on a single VPS via Docker Compose. Minimum server spec: **2 vCPU, 4 GB RAM, 40 GB SSD**.

---

## 5. Project Structure

```
webtrit-backend/
├── docker-compose.yml
├── .env                          ← environment variables (never commit)
├── .env.example
├── nginx/
│   ├── nginx.conf
│   └── ssl/                      ← Let's Encrypt certs (auto-managed)
├── src/
│   ├── index.ts                  ← entry point (starts both HTTP + WS)
│   ├── config.ts                 ← reads from .env
│   ├── db/
│   │   ├── connection.ts         ← MySQL pool setup
│   │   ├── redis.ts              ← Redis client setup
│   │   └── migrations/           ← SQL migration files
│   │       ├── 001_initial.sql
│   │       └── 002_calls.sql
│   ├── middleware/
│   │   ├── auth.ts               ← Bearer token validation
│   │   ├── tenant.ts             ← Extract tenantId from URL
│   │   └── request-id.ts         ← X-Request-Id handling
│   ├── routes/
│   │   ├── index.ts              ← mounts all routes
│   │   ├── system.ts             ← GET /api/v1/system-info
│   │   ├── session.ts            ← POST/DELETE /api/v1/session
│   │   ├── user.ts               ← GET/DELETE /api/v1/user
│   │   ├── contacts.ts           ← GET /api/v1/user/contacts
│   │   ├── app-status.ts         ← GET/PATCH /api/v1/app/status
│   │   ├── push-tokens.ts        ← POST /api/v1/app/push-tokens
│   │   ├── history.ts            ← GET /api/v1/user/history
│   │   ├── voicemail.ts          ← GET /api/v1/user/voicemails
│   │   └── notifications.ts      ← GET /api/v1/user/notifications
│   ├── signaling/
│   │   ├── server.ts             ← WebSocket server entry
│   │   ├── phoenix.ts            ← Phoenix Channels protocol adapter
│   │   ├── connection-manager.ts ← Track connected users
│   │   └── handlers/
│   │       ├── call.ts           ← Handle call request/events
│   │       ├── ice.ts            ← ICE candidate relay
│   │       └── presence.ts       ← Presence updates
│   ├── services/
│   │   ├── auth.service.ts       ← Token generation, validation
│   │   ├── call.service.ts       ← Call routing logic
│   │   ├── push.service.ts       ← Send FCM/APNS via Gorush
│   │   ├── janus.service.ts      ← Janus Gateway REST client
│   │   └── otp.service.ts        ← OTP generation + delivery
│   └── types/
│       ├── api.types.ts          ← Request/response type definitions
│       └── signaling.types.ts    ← Signaling message type definitions
├── package.json
├── tsconfig.json
└── Dockerfile
```

---

## Phase 0 — Infrastructure Setup (Day 1)

### docker-compose.yml

```yaml
version: '3.9'
services:

  mysql:
    image: mysql:8.0
    restart: always
    environment:
      MYSQL_DATABASE: webtrit
      MYSQL_USER: webtrit
      MYSQL_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
    command: --default-authentication-plugin=caching_sha2_password
             --character-set-server=utf8mb4
             --collation-server=utf8mb4_unicode_ci
    volumes:
      - mysql_data:/var/lib/mysql
      - ./src/db/migrations:/docker-entrypoint-initdb.d   # runs *.sql on first start
    ports:
      - "127.0.0.1:3306:3306"

  redis:
    image: redis:7-alpine
    restart: always
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis_data:/data
    ports:
      - "127.0.0.1:6379:6379"

  api:
    build: .
    restart: always
    environment:
      NODE_ENV: production
      PORT: 3000
      WS_PORT: 3001
      DB_HOST: mysql
      DB_PORT: 3306
      DB_USER: webtrit
      DB_PASSWORD: ${DB_PASSWORD}
      DB_NAME: webtrit
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379
      JWT_SECRET: ${JWT_SECRET}
      GORUSH_URL: http://gorush:8088
    ports:
      - "127.0.0.1:3000:3000"
      - "127.0.0.1:3001:3001"
    depends_on:
      - mysql
      - redis

  janus:
    image: canyan/janus-gateway:latest
    restart: always
    ports:
      - "127.0.0.1:8088:8088"
      - "20000-20200:20000-20200/udp"   # RTP media ports
    volumes:
      - ./janus/janus.jcfg:/usr/local/etc/janus/janus.jcfg
      - ./janus/janus.plugin.sip.jcfg:/usr/local/etc/janus/janus.plugin.sip.jcfg

  freeswitch:
    image: signalwire/freeswitch:latest
    restart: always
    network_mode: host     # SIP needs host networking for proper port handling
    volumes:
      - ./freeswitch/conf:/etc/freeswitch
      - freeswitch_sounds:/usr/share/freeswitch/sounds

  gorush:
    image: appleboy/gorush:latest
    restart: always
    volumes:
      - ./gorush/config.yml:/config.yml
    ports:
      - "127.0.0.1:8088:8088"  # Gorush API
    command: -c /config.yml

  nginx:
    image: nginx:alpine
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf
      - ./nginx/ssl:/etc/nginx/ssl
    depends_on:
      - api

volumes:
  mysql_data:
  redis_data:
  freeswitch_sounds:
```

### .env.example
```bash
# Database (MySQL)
DB_PASSWORD=change_this_strong_password
DB_ROOT_PASSWORD=change_this_root_password

# Redis
REDIS_PASSWORD=change_this_redis_password

# JWT — generate with: node -e "console.log(require('crypto').randomBytes(64).toString('hex'))"
JWT_SECRET=generate_a_64_byte_random_hex_string

# Firebase (for FCM push on Android)
FIREBASE_PROJECT_ID=your-firebase-project-id
FIREBASE_PRIVATE_KEY_ID=your-key-id
FIREBASE_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
FIREBASE_CLIENT_EMAIL=firebase-adminsdk-xxx@your-project.iam.gserviceaccount.com

# APNS (for iOS push)
APNS_KEY_ID=your-apns-key-id
APNS_TEAM_ID=your-apple-team-id
APNS_BUNDLE_ID=com.webtrit.app

# Janus
JANUS_URL=http://janus:8088/janus
JANUS_ADMIN_SECRET=janus_admin_secret

# FreeSWITCH
FREESWITCH_ESL_HOST=freeswitch
FREESWITCH_ESL_PORT=8021
FREESWITCH_ESL_PASSWORD=ClueCon

# App
SERVER_DOMAIN=your-server.com
APP_VERSION=1.0.0
```

### Dockerfile
```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY dist/ ./dist/
EXPOSE 3000 3001
CMD ["node", "dist/index.js"]
```

### tsconfig.json
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "commonjs",
    "lib": ["ES2022"],
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true
  }
}
```

### package.json (key dependencies)
```json
{
  "dependencies": {
    "express": "^4.18.0",
    "ws": "^8.16.0",
    "mysql2": "^3.6.0",
    "ioredis": "^5.3.0",
    "jsonwebtoken": "^9.0.0",
    "bcryptjs": "^2.4.3",
    "uuid": "^9.0.0",
    "axios": "^1.6.0",
    "joi": "^17.11.0",
    "node-cron": "^3.0.0"
  },
  "devDependencies": {
    "typescript": "^5.3.0",
    "@types/express": "^4.17.0",
    "@types/ws": "^8.5.0",
    "@types/jsonwebtoken": "^9.0.0",
    "@types/bcryptjs": "^2.4.0",
    "@types/uuid": "^9.0.0",
    "ts-node-dev": "^2.0.0"
  }
}
```

---

## Phase 1 — REST API Core (Auth + Profile) (Days 2–3)

This phase gets the **app to successfully log in and show the main screen**.

### src/config.ts
```typescript
export const config = {
  port: parseInt(process.env.PORT || '3000'),
  wsPort: parseInt(process.env.WS_PORT || '3001'),
  jwtSecret: process.env.JWT_SECRET!,
  db: {
    host:     process.env.DB_HOST     || 'mysql',
    port:     parseInt(process.env.DB_PORT || '3306'),
    user:     process.env.DB_USER     || 'webtrit',
    password: process.env.DB_PASSWORD!,
    name:     process.env.DB_NAME     || 'webtrit',
  },
  redisUrl: process.env.REDIS_URL!,
  gorushUrl: process.env.GORUSH_URL || 'http://localhost:8088',
  appVersion: process.env.APP_VERSION || '1.0.0',
};
```

### src/db/connection.ts
```typescript
import mysql from 'mysql2/promise';
import { config } from '../config';

// mysql2 createPool returns a pool where every .query() call
// returns a Promise<[RowDataPacket[], FieldPacket[]]> tuple.
// Usage pattern:  const [rows] = await db.query('SELECT ...', [params]);
export const db = mysql.createPool({
  host:              config.db.host,
  port:              config.db.port,
  user:              config.db.user,
  password:          config.db.password,
  database:          config.db.name,
  waitForConnections: true,
  connectionLimit:   10,
  timezone:          '+00:00',          // always store dates in UTC
  decimalNumbers:    true,
});
```

### src/middleware/tenant.ts
```typescript
import { Request, Response, NextFunction } from 'express';

// Handles both:
//   /tenant/{tenantId}/api/v1/...
//   /api/v1/...
export function extractTenant(req: Request, res: Response, next: NextFunction) {
  const match = req.path.match(/^\/tenant\/([^/]+)\//);
  req.tenantId = match ? match[1] : '';
  next();
}

// Declare on Express Request type
declare global {
  namespace Express {
    interface Request {
      tenantId: string;
      userId: string;
    }
  }
}
```

### src/middleware/auth.ts
```typescript
import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import { config } from '../config';

export function requireAuth(req: Request, res: Response, next: NextFunction) {
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith('Bearer ')) {
    return res.status(401).json({ code: 'unauthorized', message: 'Missing token' });
  }

  const token = authHeader.slice(7);
  try {
    const payload = jwt.verify(token, config.jwtSecret) as { userId: string };
    req.userId = payload.userId;
    next();
  } catch {
    // This specific code triggers automatic logout in the Flutter app
    return res.status(422).json({
      code: 'refresh_token_invalid',
      message: 'Session expired or invalid',
    });
  }
}
```

### src/routes/system.ts
```typescript
import { Router } from 'express';
import { config } from '../config';

const router = Router();

// GET /api/v1/system-info  (no auth required)
router.get('/system-info', (req, res) => {
  res.json({
    core: { version: config.appVersion },
    postgres: { version: '8.0' },   // field name is fixed by app contract; value is informational only
    adapter: {
      name: 'webtrit-custom',
      version: config.appVersion,
      supported: ['login', 'otp', 'history', 'voicemail'],
      custom: {},
    },
    janus: {
      version: '1.1.0',
      plugins: { sip: { version: '1.0.0' } },
      transports: { websocket: { version: '1.0.0' } },
    },
    gorush: { version: '1.14.0' },
  });
});

export default router;
```

### src/routes/session.ts
```typescript
import { Router } from 'express';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import { v4 as uuidv4 } from 'uuid';
import { db } from '../db/connection';
import { config } from '../config';
import { requireAuth } from '../middleware/auth';

const router = Router();

// POST /api/v1/session  (Login with password)
router.post('/session', async (req, res) => {
  try {
    const { type, identifier, login, password } = req.body;
    if (!login || !password) {
      return res.status(422).json({ code: 'invalid_request', message: 'login and password required' });
    }

    // Look up user by email or username
    const [userRows] = await db.query(
      `SELECT id, password_hash, first_name, last_name, email, tenant_id
       FROM users WHERE (email = ? OR sip_username = ?) AND status != 'blocked'`,
      [login, login]
    );

    const user = (userRows as any[])[0];
    if (!user || !(await bcrypt.compare(password, user.password_hash))) {
      return res.status(422).json({ code: 'invalid_credentials', message: 'Invalid login or password' });
    }

    // Generate JWT token
    const token = jwt.sign({ userId: user.id }, config.jwtSecret, { expiresIn: '90d' });

    // Store session
    await db.query(
      `INSERT INTO sessions (id, user_id, token, app_type, bundle_id)
       VALUES (?, ?, ?, ?, ?)`,
      [uuidv4(), user.id, token, type || 'unknown', req.body.bundle_id || null]
    );

    return res.json({
      token,
      user_id: user.id,
      tenant_id: user.tenant_id || identifier || '',
    });
  } catch (err) {
    console.error('Session create error:', err);
    return res.status(500).json({ code: 'internal_error', message: 'Internal server error' });
  }
});

// POST /api/v1/session/otp-create  (Request OTP)
router.post('/session/otp-create', async (req, res) => {
  const { identifier, user_ref } = req.body;
  const [userRows] = await db.query(
    `SELECT id FROM users WHERE email = ? OR phone_main = ?`, [user_ref, user_ref]
  );
  const user = (userRows as any[])[0];
  if (!user) {
    return res.status(422).json({ code: 'user_not_found', message: 'User not found' });
  }

  const code = Math.floor(100000 + Math.random() * 900000).toString();
  const otpId = uuidv4();
  await db.query(
    `INSERT INTO otp_codes (id, user_id, code, expires_at)
     VALUES (?, ?, ?, DATE_ADD(NOW(), INTERVAL 10 MINUTE))`,
    [otpId, user.id, code]
  );

  // TODO: Send OTP via SMS/email
  // await smsService.send(user_ref, `Your code: ${code}`);
  console.log(`OTP for ${user_ref}: ${code}`); // Remove in production

  return res.json({
    otp_id: otpId,
    notification_type: 'sms',
    from_email: null,
    tenant_id: identifier || '',
  });
});

// POST /api/v1/session/otp-verify  (Verify OTP)
router.post('/session/otp-verify', async (req, res) => {
  const { otp_id, code } = req.body;
  const [otpRows] = await db.query(
    `SELECT id, user_id, code, expires_at, used FROM otp_codes WHERE id = ?`,
    [otp_id]
  );
  const otp = (otpRows as any[])[0];

  if (!otp || otp.used || new Date(otp.expires_at) < new Date() || otp.code !== code) {
    return res.status(422).json({ code: 'invalid_otp', message: 'Invalid or expired OTP' });
  }

  await db.query(`UPDATE otp_codes SET used = 1 WHERE id = ?`, [otp.id]);

  const token = jwt.sign({ userId: otp.user_id }, config.jwtSecret, { expiresIn: '90d' });
  await db.query(
    `INSERT INTO sessions (id, user_id, token, app_type) VALUES (?, ?, ?, 'otp')`,
    [uuidv4(), otp.user_id, token]
  );

  const [tenantRows] = await db.query(`SELECT tenant_id FROM users WHERE id = ?`, [otp.user_id]);

  return res.json({
    token,
    user_id: otp.user_id,
    tenant_id: (tenantRows as any[])[0]?.tenant_id || '',
  });
});

// POST /api/v1/session/auto-provision
router.post('/session/auto-provision', async (req, res) => {
  const { config_token, type } = req.body;
  const [ptRows] = await db.query(
    `SELECT user_id FROM provision_tokens WHERE token = ? AND used = 0 AND expires_at > NOW()`,
    [config_token]
  );
  if (!(ptRows as any[])[0]) {
    return res.status(422).json({ code: 'invalid_token', message: 'Invalid or expired provisioning token' });
  }

  const userId = (ptRows as any[])[0].user_id;
  await db.query(`UPDATE provision_tokens SET used = 1 WHERE token = ?`, [config_token]);

  const token = jwt.sign({ userId }, config.jwtSecret, { expiresIn: '90d' });
  await db.query(
    `INSERT INTO sessions (id, user_id, token, app_type) VALUES (?, ?, ?, ?)`,
    [uuidv4(), userId, token, type || 'unknown']
  );

  return res.json({ token, user_id: userId, tenant_id: '' });
});

// DELETE /api/v1/session  (Logout)
router.delete('/session', requireAuth, async (req, res) => {
  const authHeader = req.headers.authorization!;
  const token = authHeader.slice(7);
  // ON DELETE CASCADE on push_tokens.session_id handles push_tokens cleanup automatically
  await db.query(`DELETE FROM sessions WHERE token = ?`, [token]);
  return res.status(204).send();
});

export default router;
```

### src/routes/user.ts
```typescript
import { Router } from 'express';
import { db } from '../db/connection';
import { requireAuth } from '../middleware/auth';

const router = Router();

// GET /api/v1/user
router.get('/user', requireAuth, async (req, res) => {
  const [rows] = await db.query(
    `SELECT id, email, first_name, last_name, alias_name, company_name,
            time_zone, status, phone_main, ext, sip_username
     FROM users WHERE id = ?`,
    [req.userId]
  );
  const user = (rows as any[])[0];
  if (!user) return res.status(422).json({ code: 'refresh_token_invalid', message: 'User not found' });

  return res.json({
    status: user.status || 'active',
    numbers: {
      main: user.phone_main || null,
      ext: user.ext || null,
      additional: [],
      sms: user.phone_main ? [user.phone_main] : [],
    },
    email: user.email,
    first_name: user.first_name,
    last_name: user.last_name,
    alias_name: user.alias_name,
    company_name: user.company_name,
    time_zone: user.time_zone || 'UTC',
  });
});

// DELETE /api/v1/user
router.delete('/user', requireAuth, async (req, res) => {
  await db.query(`DELETE FROM users WHERE id = ?`, [req.userId]);
  return res.status(204).send();
});

export default router;
```

### src/routes/contacts.ts
```typescript
import { Router } from 'express';
import { db } from '../db/connection';
import { requireAuth } from '../middleware/auth';

const router = Router();

// GET /api/v1/user/contacts
router.get('/user/contacts', requireAuth, async (req, res) => {
  // Return all registered users except current user as contacts
  const [rows] = await db.query(
    `SELECT u.id, u.email, u.first_name, u.last_name, u.alias_name,
            u.company_name, u.phone_main, u.ext,
            CASE WHEN u.id = ? THEN 1 ELSE 0 END as is_current_user,
            1 as is_registered_user,
            CASE WHEN s.id IS NOT NULL THEN 'registered' ELSE 'notregistered' END as sip_status
     FROM users u
     LEFT JOIN sessions s ON s.user_id = u.id
       AND s.created_at > DATE_SUB(NOW(), INTERVAL 24 HOUR)
     WHERE u.status = 'active'
     ORDER BY u.last_name, u.first_name`,
    [req.userId]
  );

  return res.json({
    items: (rows as any[]).map(u => ({
      user_id: u.id,
      sip_status: u.sip_status,
      numbers: {
        main: u.phone_main || null,
        ext: u.ext || null,
        additional: [],
        sms: [],
      },
      email: u.email,
      first_name: u.first_name,
      last_name: u.last_name,
      alias_name: u.alias_name,
      company_name: u.company_name,
      is_current_user: u.is_current_user,
      is_registered_user: u.is_registered_user,
    })),
  });
});

// GET /api/v1/user/contacts/:userId
router.get('/user/contacts/:userId', requireAuth, async (req, res) => {
  const [rows] = await db.query(
    `SELECT id, email, first_name, last_name, alias_name, company_name, phone_main, ext
     FROM users WHERE id = ? AND status = 'active'`,
    [req.params.userId]
  );
  const u = (rows as any[])[0];
  if (!u) return res.status(404).json({ code: 'not_found', message: 'Contact not found' });

  return res.json({
    user_id: u.id,
    sip_status: 'notregistered',
    numbers: { main: u.phone_main, ext: u.ext, additional: [], sms: [] },
    email: u.email,
    first_name: u.first_name,
    last_name: u.last_name,
    alias_name: u.alias_name,
    company_name: u.company_name,
    is_current_user: u.id === req.userId,
    is_registered_user: true,
  });
});

// GET /api/v1/app/status
router.get('/app/status', requireAuth, async (req, res) => {
  const [rows] = await db.query(
    `SELECT registered FROM app_status WHERE user_id = ?`, [req.userId]
  );
  return res.json({ register: !!(rows as any[])[0]?.registered });
});

// PATCH /api/v1/app/status
router.patch('/app/status', requireAuth, async (req, res) => {
  const { register } = req.body;
  await db.query(
    `INSERT INTO app_status (user_id, registered) VALUES (?, ?)
     ON DUPLICATE KEY UPDATE registered = VALUES(registered), updated_at = NOW()`,
    [req.userId, register ? 1 : 0]
  );
  return res.status(204).send();
});

// POST /api/v1/app/push-tokens
router.post('/app/push-tokens', requireAuth, async (req, res) => {
  const { type, value } = req.body;
  const [sRows] = await db.query(
    `SELECT id FROM sessions WHERE user_id = ? ORDER BY created_at DESC LIMIT 1`,
    [req.userId]
  );
  const sessionId = (sRows as any[])[0]?.id || null;

  await db.query(
    `INSERT INTO push_tokens (user_id, session_id, type, value)
     VALUES (?, ?, ?, ?)
     ON DUPLICATE KEY UPDATE value = VALUES(value), session_id = VALUES(session_id), updated_at = NOW()`,
    [req.userId, sessionId, type, value]
  );
  return res.status(204).send();
});

// POST /api/v1/app/contacts  (upload device contacts)
router.post('/app/contacts', requireAuth, async (req, res) => {
  // Accept and store but response is just 204
  return res.status(204).send();
});

// GET /api/v1/app/contacts/smart
router.get('/app/contacts/smart', requireAuth, async (req, res) => {
  return res.json({ items: [] }); // Implement matching logic later
});

export default router;
```

### src/routes/index.ts
```typescript
import { Router } from 'express';
import systemRouter from './system';
import sessionRouter from './session';
import userRouter from './user';
import contactsRouter from './contacts';
import historyRouter from './history';
import voicemailRouter from './voicemail';
import notificationsRouter from './notifications';

const router = Router();

// Mount with regex to handle both /api/v1/... and /tenant/:id/api/v1/...
// Express handles this by stripping the tenant prefix in middleware
router.use('/', systemRouter);
router.use('/', sessionRouter);
router.use('/', userRouter);
router.use('/', contactsRouter);
router.use('/', historyRouter);
router.use('/', voicemailRouter);
router.use('/', notificationsRouter);

// Custom endpoints — return 404 (app handles gracefully)
router.post('/custom/private/*', (req, res) => {
  res.status(404).json({ code: 'not_found', message: 'Not implemented' });
});

export default router;
```

### src/index.ts
```typescript
import express from 'express';
import { config } from './config';
import apiRouter from './routes';
import { startSignalingServer } from './signaling/server';

const app = express();
app.use(express.json());

// Strip /tenant/{id} prefix before routing
app.use((req, res, next) => {
  const match = req.url.match(/^\/tenant\/[^/]+(\/.*)$/);
  if (match) req.url = match[1];
  next();
});

// Mount all API routes under /api/v1
app.use('/api/v1', apiRouter);

app.listen(config.port, () => {
  console.log(`REST API running on port ${config.port}`);
});

// Start WebSocket signaling on separate port
startSignalingServer(config.wsPort);
```

---

## Phase 2 — WebSocket Signaling Server (Days 4–5)

The **most critical piece** — implements the Phoenix Channels protocol.

### src/signaling/phoenix.ts
```typescript
// Phoenix Channels wire protocol
// Message format: [join_ref, message_ref, topic, event, payload]

export type PhoenixMessage = [
  string | null,   // join_ref
  string | null,   // message_ref
  string,          // topic
  string,          // event
  Record<string, unknown> // payload
];

export function parseMessage(raw: string): PhoenixMessage | null {
  try {
    const msg = JSON.parse(raw);
    if (Array.isArray(msg) && msg.length === 5) return msg as PhoenixMessage;
    return null;
  } catch {
    return null;
  }
}

export function encodeReply(
  joinRef: string | null,
  messageRef: string | null,
  topic: string,
  status: 'ok' | 'error',
  response: Record<string, unknown> = {}
): string {
  return JSON.stringify([joinRef, messageRef, topic, 'phx_reply', { status, response }]);
}

export function encodePush(topic: string, event: string, payload: Record<string, unknown>): string {
  return JSON.stringify([null, null, topic, event, payload]);
}
```

### src/signaling/connection-manager.ts
```typescript
import WebSocket from 'ws';

interface UserConnection {
  ws: WebSocket;
  userId: string;
  tenantId: string;
  topic: string;
  joinRef: string;
}

// In-memory map: userId → connection
// In production: move this to Redis for multi-instance support
const connections = new Map<string, UserConnection>();

export const connectionManager = {
  add(userId: string, conn: UserConnection) {
    connections.set(userId, conn);
  },
  remove(userId: string) {
    connections.delete(userId);
  },
  get(userId: string): UserConnection | undefined {
    return connections.get(userId);
  },
  isConnected(userId: string): boolean {
    const conn = connections.get(userId);
    return !!conn && conn.ws.readyState === WebSocket.OPEN;
  },
  send(userId: string, message: string): boolean {
    const conn = connections.get(userId);
    if (conn && conn.ws.readyState === WebSocket.OPEN) {
      conn.ws.send(message);
      return true;
    }
    return false;
  },
};
```

### src/signaling/server.ts
```typescript
import WebSocket, { WebSocketServer } from 'ws';
import { IncomingMessage } from 'http';
import jwt from 'jsonwebtoken';
import { config } from '../config';
import { parseMessage, encodeReply, encodePush } from './phoenix';
import { connectionManager } from './connection-manager';
import { handleCallRequest } from './handlers/call';
import { handleIceRequest } from './handlers/ice';

export function startSignalingServer(port: number) {
  const wss = new WebSocketServer({
    port,
    handleProtocols: () => 'webtrit-protocol', // Required subprotocol
  });

  wss.on('connection', (ws: WebSocket, req: IncomingMessage) => {
    const url = new URL(req.url!, `http://localhost`);
    const token = url.searchParams.get('token');
    const force = url.searchParams.get('force') === 'true';

    // Strip /tenant/{id} prefix from path
    const path = url.pathname.replace(/^\/tenant\/[^/]+/, '');
    if (!path.startsWith('/signaling/v1')) {
      ws.close(4001, 'Invalid path');
      return;
    }

    // Authenticate token
    let userId: string;
    try {
      const payload = jwt.verify(token!, config.jwtSecret) as { userId: string };
      userId = payload.userId;
    } catch {
      ws.close(4401, 'Unauthorized');
      return;
    }

    // Force-disconnect existing connection for this user
    if (force) {
      const existing = connectionManager.get(userId);
      if (existing) {
        existing.ws.close(4000, 'Replaced by new connection');
        connectionManager.remove(userId);
      }
    }

    let topic = '';
    let joinRef: string | null = null;

    ws.on('message', (data: Buffer) => {
      const msg = parseMessage(data.toString());
      if (!msg) return;

      const [msgJoinRef, msgRef, msgTopic, event, payload] = msg;

      // Handle Phoenix heartbeat (comes on "phoenix" topic)
      if (msgTopic === 'phoenix' && event === 'heartbeat') {
        ws.send(encodeReply(msgJoinRef, msgRef, 'phoenix', 'ok', {}));
        return;
      }

      // Handle channel join
      if (event === 'phx_join') {
        topic = msgTopic;
        joinRef = msgJoinRef;

        connectionManager.add(userId, { ws, userId, tenantId: '', topic, joinRef: joinRef || '' });

        // Reply OK to join
        ws.send(encodeReply(msgJoinRef, msgRef, topic, 'ok', {}));

        // Send state handshake — this tells the app it is "registered"
        ws.send(encodePush(topic, 'state', {
          handshake: 'state',
          keepalive_interval: 30000,
          timestamp: Date.now(),
          registration: { status: 'registered' },
          lines: [null, null, null, null],
          user_active_calls: [],
          presence_contacts_info: {},
          guest_line: null,
        }));
        return;
      }

      // Handle channel leave
      if (event === 'phx_leave') {
        ws.send(encodeReply(msgJoinRef, msgRef, topic, 'ok', {}));
        connectionManager.remove(userId);
        return;
      }

      // Route signaling requests
      const request = payload.request as string;
      switch (request) {
        case 'outgoing_call':
          handleCallRequest('outgoing', userId, topic, msg);
          break;
        case 'accept':
          handleCallRequest('accept', userId, topic, msg);
          break;
        case 'decline':
          handleCallRequest('decline', userId, topic, msg);
          break;
        case 'hangup':
          handleCallRequest('hangup', userId, topic, msg);
          break;
        case 'hold':
          handleCallRequest('hold', userId, topic, msg);
          break;
        case 'unhold':
          handleCallRequest('unhold', userId, topic, msg);
          break;
        case 'ice_trickle':
          handleIceRequest(userId, topic, msg);
          break;
        default:
          // Send ack for unknown requests
          if (msgRef) {
            connectionManager.send(userId,
              encodeReply(msgJoinRef, msgRef, topic, 'ok', {})
            );
          }
      }
    });

    ws.on('close', () => {
      connectionManager.remove(userId);
      console.log(`User ${userId} disconnected`);
    });

    ws.on('error', (err) => {
      console.error(`WS error for ${userId}:`, err);
    });

    console.log(`User ${userId} connected via signaling`);
  });

  console.log(`Signaling WebSocket server running on port ${port}`);
}
```

---

## Phase 3 — App-to-App Internal Calls (Days 6–7)

This makes two app users call each other directly — **no SIP or Janus needed yet**.

### src/signaling/handlers/call.ts
```typescript
import { v4 as uuidv4 } from 'uuid';
import { PhoenixMessage, encodeReply, encodePush } from '../phoenix';
import { connectionManager } from '../connection-manager';
import { db } from '../../db/connection';

// Track active calls: callId → {callerUserId, calleeUserId, line}
const activeCalls = new Map<string, { callerUserId: string; calleeUserId: string; line: number }>();

export async function handleCallRequest(
  type: string,
  userId: string,
  topic: string,
  msg: PhoenixMessage
) {
  const [joinRef, msgRef, , , payload] = msg;

  // Send ack immediately
  connectionManager.send(userId, encodeReply(joinRef, msgRef, topic, 'ok', {}));

  switch (type) {
    case 'outgoing': {
      const { call_id, number, line, jsep } = payload as any;

      // Find callee by phone number or extension
      const [calleeRows] = await db.query(
        `SELECT id FROM users WHERE phone_main = ? OR ext = ? OR sip_username = ?`,
        [number, number, number]
      );

      if (!(calleeRows as any[])[0]) {
        connectionManager.send(userId, encodePush(topic, 'signaling', {
          event: 'hangup', line, call_id,
        }));
        return;
      }

      const calleeUserId = (calleeRows as any[])[0].id;
      activeCalls.set(call_id, { callerUserId: userId, calleeUserId, line });

      // Send calling event to caller
      connectionManager.send(userId, encodePush(topic, 'signaling', {
        event: 'calling', line, call_id,
      }));

      // Look up caller info
      const [callerRows] = await db.query(
        `SELECT phone_main, first_name, last_name FROM users WHERE id = ?`, [userId]
      );
      const caller = (callerRows as any[])[0];

      // Check if callee is connected
      if (connectionManager.isConnected(calleeUserId)) {
        const calleeConn = connectionManager.get(calleeUserId)!;

        // Send incoming_call to callee
        calleeConn.ws.send(encodePush(calleeConn.topic, 'signaling', {
          event: 'incoming_call',
          line: 0,
          call_id,
          caller: caller?.phone_main || userId,
          callee: number,
          caller_display_name: `${caller?.first_name || ''} ${caller?.last_name || ''}`.trim(),
          referred_by: null,
          replace_call_id: null,
          is_focus: false,
          jsep,
        }));

        // Send ringing back to caller
        connectionManager.send(userId, encodePush(topic, 'signaling', {
          event: 'ringing', line, call_id,
        }));
      } else {
        // Callee is offline — send push notification
        await sendCallPush(calleeUserId, call_id, caller?.phone_main || userId, number);

        connectionManager.send(userId, encodePush(topic, 'signaling', {
          event: 'proceeding', line, call_id, code: 180,
        }));
      }
      break;
    }

    case 'accept': {
      const { call_id, line, jsep } = payload as any;
      const callInfo = activeCalls.get(call_id);
      if (!callInfo) return;

      const callerUserId = callInfo.callerUserId;

      // Forward SDP answer to caller as 'accepted'
      connectionManager.send(callerUserId, encodePush(
        connectionManager.get(callerUserId)!.topic,
        'signaling',
        {
          event: 'accepted',
          line: callInfo.line,
          call_id,
          callee: null,
          is_focus: false,
          jsep,
        }
      ));

      // Confirm accepted to callee
      connectionManager.send(userId, encodePush(topic, 'signaling', {
        event: 'accepted', line, call_id,
      }));
      break;
    }

    case 'decline': {
      const { call_id, line } = payload as any;
      const callInfo = activeCalls.get(call_id);
      if (callInfo) {
        // Notify caller that callee declined
        const otherUserId = callInfo.callerUserId === userId
          ? callInfo.calleeUserId
          : callInfo.callerUserId;

        connectionManager.send(otherUserId, encodePush(
          connectionManager.get(otherUserId)?.topic || '',
          'signaling',
          { event: 'hangup', line: callInfo.line, call_id }
        ));
        activeCalls.delete(call_id);
      }
      break;
    }

    case 'hangup': {
      const { call_id, line } = payload as any;
      const callInfo = activeCalls.get(call_id);
      if (callInfo) {
        const otherUserId = callInfo.callerUserId === userId
          ? callInfo.calleeUserId
          : callInfo.callerUserId;

        connectionManager.send(otherUserId, encodePush(
          connectionManager.get(otherUserId)?.topic || '',
          'signaling',
          { event: 'hangup', line: callInfo.line, call_id }
        ));
        activeCalls.delete(call_id);
      }
      break;
    }

    case 'hold': {
      const { call_id, line, direction } = payload as any;
      const callInfo = activeCalls.get(call_id);
      if (callInfo) {
        connectionManager.send(userId, encodePush(topic, 'signaling', {
          event: 'holding', line, call_id,
        }));
        // Notify other party
        const otherUserId = callInfo.callerUserId === userId ? callInfo.calleeUserId : callInfo.callerUserId;
        connectionManager.send(otherUserId, encodePush(
          connectionManager.get(otherUserId)?.topic || '', 'signaling',
          { event: 'holding', line: callInfo.line, call_id }
        ));
      }
      break;
    }
  }
}

async function sendCallPush(calleeUserId: string, callId: string, caller: string, callee: string) {
  const [tokenRows] = await db.query(
    `SELECT type, value FROM push_tokens WHERE user_id = ? ORDER BY updated_at DESC`,
    [calleeUserId]
  );
  if (!(tokenRows as any[])[0]) return;

  const { type, value } = (tokenRows as any[])[0];
  const { pushService } = await import('../../services/push.service');
  await pushService.sendCallNotification(type, value, callId, caller, callee);
}
```

### src/signaling/handlers/ice.ts
```typescript
import { PhoenixMessage, encodeReply, encodePush } from '../phoenix';
import { connectionManager } from '../connection-manager';

// Track which calls are between which users (share state with call.ts)
// In production use Redis for this
const callPairs = new Map<string, string>(); // callId → otherUserId

export function setCallPair(callId: string, userId1: string, userId2: string) {
  callPairs.set(`${callId}:${userId1}`, userId2);
  callPairs.set(`${callId}:${userId2}`, userId1);
}

export function handleIceRequest(userId: string, topic: string, msg: PhoenixMessage) {
  const [joinRef, msgRef, , , payload] = msg;
  const { call_id, line, candidate } = payload as any;

  // Ack the request
  connectionManager.send(userId, encodeReply(joinRef, msgRef, topic, 'ok', {}));

  // Forward to other party in the call
  const otherUserId = callPairs.get(`${call_id}:${userId}`);
  if (otherUserId) {
    const conn = connectionManager.get(otherUserId);
    if (conn) {
      conn.ws.send(encodePush(conn.topic, 'signaling', {
        event: 'ice_trickle',
        line,
        candidate: candidate.completed ? null : candidate,
      }));
    }
  }
}
```

---

## Phase 4 — Push Notifications (Day 8)

### src/services/push.service.ts
```typescript
import axios from 'axios';
import { config } from '../config';

export const pushService = {
  async sendCallNotification(
    tokenType: string,
    tokenValue: string,
    callId: string,
    caller: string,
    callee: string
  ) {
    const platform = tokenType === 'fcm' || tokenType === 'hms' ? 2 : 1; // 2=Android, 1=iOS

    const notificationPayload = {
      notifications: [{
        tokens: [tokenValue],
        platform,
        priority: 'high',
        data: {
          type: 'call',
          call_id: callId,
          caller,
          callee,
          caller_display_name: caller,
        },
        // iOS VoIP push fields
        ...(tokenType === 'apkvoip' ? {
          voip: true,
          content_available: true,
        } : {}),
      }],
    };

    try {
      await axios.post(`${config.gorushUrl}/api/push`, notificationPayload);
    } catch (err) {
      console.error('Push notification failed:', err);
    }
  },
};
```

### gorush/config.yml
```yaml
core:
  port: "8088"
  max_notification: 100
  sync: false
  mode: "release"
  log_level: "error"

api:
  push_uri: "/api/push"
  stat_go_uri: "/api/stat/go"
  stat_app_uri: "/api/stat/app"
  config_uri: "/api/config"
  sys_stat_uri: "/sys/stats"
  metric_uri: "/metrics"

android:
  enabled: true
  apikey: ""                   # Not used for FCM v1
  project_number: ""
  max_retry: 2
  key_path: "/firebase-service-account.json"  # Mount this file

ios:
  enabled: true
  key_path: "/apns-auth-key.p8"             # Mount this file
  key_id: "${APNS_KEY_ID}"
  team_id: "${APNS_TEAM_ID}"
  production: true
  topic: "com.webtrit.app"
  max_retry: 2
  voip: true
```

---

## Phase 5 — SIP Trunk & PSTN Calls (Days 9–12)

This phase adds the ability to call real phone numbers via SIP.

### Step 1 — Janus Gateway Configuration

Create `janus/janus.plugin.sip.jcfg`:
```
# Janus SIP plugin config
general: {
  local_ip = "0.0.0.0"
  user_agent = "Janus WebRTC Server SIP Plugin"
  register_ttl = 3600
}
```

Create `janus/janus.jcfg`:
```
general: {
  log_to_stdout = true
  log_level = 4
  admin_secret = "janusoverlord"
  token_auth = false
}

certificates: {
  cert_pem = "/etc/ssl/cert.pem"
  cert_key = "/etc/ssl/key.pem"
}

nat: {
  full_trickle = true
  ignore_mdns = true
}

plugins: {
  disable = "libjanus_videoroom.so,libjanus_echotest.so"
}

transports: {
  disable = "libjanus_rabbitmq.so"
}
```

### Step 2 — FreeSWITCH Configuration

FreeSWITCH acts as your SIP proxy. When Janus makes SIP calls, FreeSWITCH routes them to your SIP trunk provider.

Key config file `freeswitch/conf/sip_profiles/external.xml`:
```xml
<configuration name="sofia.conf" description="Sofia SIP">
  <profiles>
    <profile name="external">
      <settings>
        <param name="sip-port" value="5080"/>
        <param name="rtp-ip" value="auto"/>
        <param name="ext-rtp-ip" value="auto-nat"/>
        <param name="rtp-timeout-sec" value="300"/>
        <param name="rtp-hold-timeout-sec" value="1800"/>
      </settings>
      <gateways>
        <!-- Your SIP trunk provider -->
        <gateway name="sip-trunk">
          <param name="username" value="${SIP_TRUNK_USER}"/>
          <param name="password" value="${SIP_TRUNK_PASS}"/>
          <param name="proxy" value="${SIP_TRUNK_HOST}"/>
          <param name="register" value="true"/>
        </gateway>
      </gateways>
    </profile>
  </profiles>
</configuration>
```

### Step 3 — Janus Service Integration

When the app makes an outgoing call to a PSTN number, your signaling server:
1. Creates a Janus session
2. Attaches the SIP plugin
3. Registers the user with FreeSWITCH via Janus
4. Forwards the SDP offer to Janus
5. Janus converts WebRTC → SIP and sends INVITE to FreeSWITCH → PSTN

### src/services/janus.service.ts
```typescript
import axios from 'axios';
import { v4 as uuidv4 } from 'uuid';
import { config } from '../config';

const janusUrl = config.janusUrl || 'http://localhost:8088/janus';

export const janusService = {
  async createSession(): Promise<string> {
    const res = await axios.post(janusUrl, {
      janus: 'create',
      transaction: uuidv4(),
    });
    return res.data.data.id;
  },

  async attachSipPlugin(sessionId: string): Promise<string> {
    const res = await axios.post(`${janusUrl}/${sessionId}`, {
      janus: 'attach',
      plugin: 'janus.plugin.sip',
      transaction: uuidv4(),
    });
    return res.data.data.id;
  },

  async registerSipUser(sessionId: string, handleId: string, sipUser: string, sipPass: string, sipProxy: string) {
    await axios.post(`${janusUrl}/${sessionId}/${handleId}`, {
      janus: 'message',
      transaction: uuidv4(),
      body: {
        request: 'register',
        username: `sip:${sipUser}@${sipProxy}`,
        secret: sipPass,
        proxy: `sip:${sipProxy}`,
      },
    });
  },

  async makeCall(
    sessionId: string,
    handleId: string,
    callee: string,
    sipProxy: string,
    sdpOffer: string
  ): Promise<string> {
    const res = await axios.post(`${janusUrl}/${sessionId}/${handleId}`, {
      janus: 'message',
      transaction: uuidv4(),
      body: {
        request: 'call',
        uri: `sip:${callee}@${sipProxy}`,
        autoaccept_reinvites: false,
      },
      jsep: { type: 'offer', sdp: sdpOffer },
    });
    return res.data;
  },

  async acceptCall(sessionId: string, handleId: string, sdpAnswer: string) {
    await axios.post(`${janusUrl}/${sessionId}/${handleId}`, {
      janus: 'message',
      transaction: uuidv4(),
      body: { request: 'accept' },
      jsep: { type: 'answer', sdp: sdpAnswer },
    });
  },

  async hangup(sessionId: string, handleId: string) {
    await axios.post(`${janusUrl}/${sessionId}/${handleId}`, {
      janus: 'message',
      transaction: uuidv4(),
      body: { request: 'hangup' },
    });
  },
};
```

---

## Phase 6 — Secondary Features (Days 13–14)

### src/routes/history.ts
```typescript
import { Router } from 'express';
import { db } from '../db/connection';
import { requireAuth } from '../middleware/auth';

const router = Router();

router.get('/user/history', requireAuth, async (req, res) => {
  const { time_from, time_to, items_per_page } = req.query;
  const limit = parseInt(items_per_page as string) || 50;

  const [rows] = await db.query(
    `SELECT call_id, caller, callee, direction, status,
            connect_time, disconnect_time, duration, disconnect_reason, recording_id
     FROM call_records
     WHERE (caller_user_id = ? OR callee_user_id = ?)
       AND (? IS NULL OR connect_time >= ?)
       AND (? IS NULL OR connect_time <= ?)
     ORDER BY connect_time DESC
     LIMIT ?`,
    [req.userId, req.userId,
     time_from || null, time_from || null,
     time_to   || null, time_to   || null,
     limit]
  );

  return res.json({
    items: (rows as any[]).map(r => ({
      call_id: r.call_id,
      caller: r.caller,
      callee: r.callee,
      direction: r.direction,
      status: r.status,
      connect_time: r.connect_time?.toISOString(),
      disconnect_time: r.disconnect_time?.toISOString(),
      duration: r.duration || 0,
      disconnect_reason: r.disconnect_reason || 'normal',
      recording_id: r.recording_id,
    })),
  });
});

export default router;
```

### src/routes/notifications.ts
```typescript
import { Router } from 'express';
import { db } from '../db/connection';
import { requireAuth } from '../middleware/auth';

const router = Router();

router.get('/user/notifications', requireAuth, async (req, res) => {
  const { created_before, limit } = req.query;
  const [rows] = await db.query(
    `SELECT id, title, content, type, seen, created_at, updated_at, read_at
     FROM notifications
     WHERE user_id = ?
       AND (? IS NULL OR created_at < ?)
     ORDER BY created_at DESC LIMIT ?`,
    [req.userId,
     created_before || null, created_before || null,
     parseInt(limit as string) || 20]
  );
  return res.json({ items: rows });
});

router.get('/user/notifications/updates', requireAuth, async (req, res) => {
  const { updated_after, limit } = req.query;
  const [rows] = await db.query(
    `SELECT id, title, content, type, seen, created_at, updated_at, read_at
     FROM notifications
     WHERE user_id = ? AND updated_at > ?
     ORDER BY updated_at DESC LIMIT ?`,
    [req.userId, updated_after, parseInt(limit as string) || 20]
  );
  return res.json({ items: rows });
});

router.patch('/user/notifications/:id', requireAuth, async (req, res) => {
  await db.query(
    `UPDATE notifications SET seen = ?, read_at = NOW(), updated_at = NOW()
     WHERE id = ? AND user_id = ?`,
    [req.body.seen ? 1 : 0, req.params.id, req.userId]
  );
  return res.status(204).send();
});

export default router;
```

---

## 13. Database Schema (Full)

Save as `src/db/migrations/001_initial.sql`:
```sql
-- MySQL 8.0 compatible schema
-- This file is auto-run by MySQL Docker image on first container start

SET NAMES utf8mb4;
SET time_zone = '+00:00';

CREATE TABLE users (
  id            CHAR(36)     NOT NULL DEFAULT (UUID()),
  tenant_id     VARCHAR(100) NOT NULL DEFAULT '',
  email         VARCHAR(255) NULL,
  password_hash VARCHAR(255) NULL,
  first_name    VARCHAR(100) NULL,
  last_name     VARCHAR(100) NULL,
  alias_name    VARCHAR(100) NULL,
  company_name  VARCHAR(200) NULL,
  time_zone     VARCHAR(50)  NOT NULL DEFAULT 'UTC',
  status        VARCHAR(20)  NOT NULL DEFAULT 'active',
  phone_main    VARCHAR(30)  NULL,
  ext           VARCHAR(20)  NULL,
  sip_username  VARCHAR(100) NULL,
  sip_password  VARCHAR(100) NULL,
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_users_email       (email),
  UNIQUE KEY uq_users_phone_main  (phone_main),
  UNIQUE KEY uq_users_ext         (ext),
  UNIQUE KEY uq_users_sip_username(sip_username)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE sessions (
  id          CHAR(36)     NOT NULL DEFAULT (UUID()),
  user_id     CHAR(36)     NOT NULL,
  token       TEXT         NOT NULL,
  app_type    VARCHAR(20)  NOT NULL DEFAULT 'unknown',
  bundle_id   VARCHAR(200) NULL,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_sessions_token (token(255)),   -- TEXT needs prefix length for unique index
  KEY idx_sessions_user_id (user_id),
  CONSTRAINT fk_sessions_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE push_tokens (
  id          CHAR(36)    NOT NULL DEFAULT (UUID()),
  user_id     CHAR(36)    NOT NULL,
  session_id  CHAR(36)    NULL,
  type        VARCHAR(20) NOT NULL,
  value       TEXT        NOT NULL,
  updated_at  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_push_tokens_user_type (user_id, type),
  CONSTRAINT fk_push_tokens_user    FOREIGN KEY (user_id)    REFERENCES users(id)    ON DELETE CASCADE,
  CONSTRAINT fk_push_tokens_session FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE otp_codes (
  id          CHAR(36)    NOT NULL DEFAULT (UUID()),
  user_id     CHAR(36)    NOT NULL,
  code        VARCHAR(10) NOT NULL,
  expires_at  DATETIME    NOT NULL,
  used        TINYINT(1)  NOT NULL DEFAULT 0,
  created_at  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  CONSTRAINT fk_otp_codes_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE provision_tokens (
  id          CHAR(36)     NOT NULL DEFAULT (UUID()),
  user_id     CHAR(36)     NOT NULL,
  token       VARCHAR(255) NOT NULL,
  used        TINYINT(1)   NOT NULL DEFAULT 0,
  expires_at  DATETIME     NOT NULL,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_provision_tokens_token (token),
  CONSTRAINT fk_provision_tokens_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE app_status (
  user_id     CHAR(36)   NOT NULL,
  registered  TINYINT(1) NOT NULL DEFAULT 0,
  updated_at  DATETIME   NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id),
  CONSTRAINT fk_app_status_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE call_records (
  id                CHAR(36)    NOT NULL DEFAULT (UUID()),
  call_id           VARCHAR(100) NOT NULL,
  caller_user_id    CHAR(36)    NULL,
  callee_user_id    CHAR(36)    NULL,
  caller            VARCHAR(50) NOT NULL,
  callee            VARCHAR(50) NOT NULL,
  direction         VARCHAR(5)  NOT NULL,   -- 'in' or 'out'
  status            VARCHAR(20) NOT NULL,   -- 'answered', 'missed', 'rejected'
  connect_time      DATETIME    NULL,
  disconnect_time   DATETIME    NULL,
  duration          INT         NOT NULL DEFAULT 0,
  disconnect_reason VARCHAR(50) NULL,
  recording_id      CHAR(36)    NULL,
  created_at        DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_call_records_call_id (call_id),
  KEY idx_call_records_caller (caller_user_id),
  KEY idx_call_records_callee (callee_user_id),
  CONSTRAINT fk_call_records_caller FOREIGN KEY (caller_user_id) REFERENCES users(id) ON DELETE SET NULL,
  CONSTRAINT fk_call_records_callee FOREIGN KEY (callee_user_id) REFERENCES users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE voicemails (
  id          CHAR(36)      NOT NULL DEFAULT (UUID()),
  user_id     CHAR(36)      NOT NULL,
  sender      VARCHAR(50)   NOT NULL,
  receiver    VARCHAR(50)   NOT NULL,
  duration    DECIMAL(10,2) NULL,
  seen        TINYINT(1)    NOT NULL DEFAULT 0,
  file_path   TEXT          NULL,
  file_size   INT           NULL,
  created_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_voicemails_user (user_id),
  CONSTRAINT fk_voicemails_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE notifications (
  id          INT          NOT NULL AUTO_INCREMENT,
  user_id     CHAR(36)     NOT NULL,
  title       VARCHAR(200) NOT NULL,
  content     TEXT         NOT NULL,
  type        VARCHAR(30)  NOT NULL DEFAULT 'announcement',
  seen        TINYINT(1)   NOT NULL DEFAULT 0,
  read_at     DATETIME     NULL,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_notifications_user (user_id),
  CONSTRAINT fk_notifications_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Default test user  (password: test1234  — change before production!)
INSERT INTO users (id, email, password_hash, first_name, last_name, phone_main, ext, sip_username, status)
VALUES (
  UUID(),
  'test@example.com',
  '$2b$10$rICE65bqxPdB7KMwHa4b0.7fhHe3yF9SmEtDjv7z5I44j8B6ZG/pK',
  'Test', 'User', '+15551234567', '100', 'test', 'active'
);
```

---

## 14. Nginx Configuration

`nginx/nginx.conf`:
```nginx
events { worker_connections 1024; }

http {
  upstream api        { server 127.0.0.1:3000; }
  upstream signaling  { server 127.0.0.1:3001; }

  # HTTP → HTTPS redirect
  server {
    listen 80;
    server_name your-server.com;
    return 301 https://$host$request_uri;
  }

  server {
    listen 443 ssl http2;
    server_name your-server.com;

    ssl_certificate     /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    # REST API — matches /api/v1/... and /tenant/{id}/api/v1/...
    location ~ ^(/tenant/[^/]+)?/api/ {
      proxy_pass         http://api;
      proxy_http_version 1.1;
      proxy_set_header   Host $host;
      proxy_set_header   X-Real-IP $remote_addr;
      proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_read_timeout 30s;
    }

    # WebSocket Signaling — matches /signaling/v1 and /tenant/{id}/signaling/v1
    location ~ ^(/tenant/[^/]+)?/signaling/ {
      proxy_pass         http://signaling;
      proxy_http_version 1.1;
      proxy_set_header   Upgrade $http_upgrade;
      proxy_set_header   Connection "upgrade";
      proxy_set_header   Host $host;
      proxy_read_timeout 3600s;     # 1 hour — keep WS connections alive
      proxy_send_timeout 3600s;
    }
  }
}
```

---

## 15. Environment Variables Reference

| Variable | Required | Description |
|----------|----------|-------------|
| `DB_PASSWORD` | Yes | MySQL `webtrit` user password |
| `DB_ROOT_PASSWORD` | Yes | MySQL root password (needed for Docker init) |
| `DB_HOST` | Yes | MySQL hostname (default: `mysql`) |
| `DB_PORT` | No | MySQL port (default: `3306`) |
| `DB_USER` | No | MySQL username (default: `webtrit`) |
| `DB_NAME` | No | MySQL database name (default: `webtrit`) |
| `REDIS_PASSWORD` | Yes | Redis password |
| `JWT_SECRET` | Yes | 64-byte random hex string for JWT signing |
| `FIREBASE_PROJECT_ID` | For Android push | Firebase project ID |
| `FIREBASE_PRIVATE_KEY` | For Android push | Firebase service account private key |
| `FIREBASE_CLIENT_EMAIL` | For Android push | Firebase service account email |
| `APNS_KEY_ID` | For iOS push | Apple Push Notification key ID |
| `APNS_TEAM_ID` | For iOS push | Apple Developer Team ID |
| `SIP_TRUNK_HOST` | For PSTN calls | Your SIP provider hostname |
| `SIP_TRUNK_USER` | For PSTN calls | SIP trunk username |
| `SIP_TRUNK_PASS` | For PSTN calls | SIP trunk password |
| `JANUS_URL` | For SIP/WebRTC | Janus REST API URL |
| `SERVER_DOMAIN` | Yes | Your server's domain name |

---

## 16. Testing Checklist per Phase

### Phase 0 — Infrastructure
- [ ] `docker-compose up` runs without errors
- [ ] MySQL accessible: `mysql -h 127.0.0.1 -P 3306 -u webtrit -p webtrit -e "SHOW TABLES;"`
- [ ] Redis accessible: `redis-cli ping` returns `PONG`
- [ ] Migrations ran (tables exist in DB — check `users`, `sessions`, `push_tokens`)

### Phase 1 — REST API
- [ ] `curl https://your-server.com/api/v1/system-info` returns JSON
- [ ] Login with test user returns a JWT token
- [ ] `GET /api/v1/user` with token returns user profile
- [ ] `GET /api/v1/user/contacts` returns contacts list
- [ ] App can be opened, server URL entered, user logged in
- [ ] App main screen displays (contacts/calls tabs visible)

### Phase 2 — Signaling
- [ ] WebSocket connects to `wss://your-server.com/signaling/v1?token=...`
- [ ] State handshake received by app (user shows as "online")
- [ ] Keepalive messages handled without disconnect
- [ ] App does NOT reconnect repeatedly (stable connection)

### Phase 3 — App-to-App Calls
- [ ] User A can call User B (both using the app)
- [ ] User B receives incoming call screen
- [ ] User B can accept — both hear each other
- [ ] User B can decline — caller sees rejected
- [ ] Either user can hang up
- [ ] Call disconnects cleanly

### Phase 4 — Push Notifications
- [ ] Push token saved in database after app login
- [ ] Call push received when app is backgrounded
- [ ] App wakes up and shows incoming call screen
- [ ] Gorush health check: `curl http://localhost:8088/metrics`

### Phase 5 — SIP/PSTN
- [ ] FreeSWITCH registered with SIP trunk provider
- [ ] Janus starts and SIP plugin loads
- [ ] Outgoing call to real phone number connects
- [ ] Incoming call from real phone rings in the app

---

## 17. Deployment Guide

### Initial Server Setup
```bash
# Ubuntu 22.04 LTS server
apt update && apt upgrade -y
apt install -y docker.io docker-compose-plugin git certbot nginx

# Get SSL certificate
certbot certonly --standalone -d your-server.com
# Certs go to /etc/letsencrypt/live/your-server.com/

# Clone your backend repo
git clone https://github.com/your-org/webtrit-backend.git /opt/webtrit
cd /opt/webtrit

# Copy certs to nginx ssl dir
cp /etc/letsencrypt/live/your-server.com/fullchain.pem nginx/ssl/
cp /etc/letsencrypt/live/your-server.com/privkey.pem nginx/ssl/

# Set up environment
cp .env.example .env
nano .env   # Fill in all values

# Build and start
docker compose build
docker compose up -d

# Watch logs
docker compose logs -f api
```

### Adding Users (Admin Script)
Since there's no admin UI yet, add users directly in MySQL.
**Important**: bcrypt hashing must be done outside MySQL (MySQL has no bcrypt function).

**Step 1** — generate a bcrypt hash for the password on the server:
```bash
node -e "const b=require('bcryptjs'); b.hash('alice_password',10).then(h=>console.log(h))"
```

**Step 2** — insert the user with the hash:
```sql
-- Connect: mysql -h 127.0.0.1 -u webtrit -p webtrit
INSERT INTO users (id, email, password_hash, first_name, last_name, phone_main, ext, sip_username, sip_password, status)
VALUES (
  UUID(),
  'alice@example.com',
  '$2b$10$<paste_hash_from_step1_here>',
  'Alice', 'Smith', '+15551112222', '101', 'alice', 'alice_sip_pass',
  'active'
);
```

Or via a simple admin API endpoint you add yourself — not included in scope to minimize attack surface.

### SSL Certificate Auto-Renewal
```bash
# Add to crontab
0 3 * * * certbot renew --quiet && cp /etc/letsencrypt/live/your-server.com/*.pem /opt/webtrit/nginx/ssl/ && docker compose -f /opt/webtrit/docker-compose.yml exec nginx nginx -s reload
```

---

## 18. Client App Configuration

### Zero Changes — User Enters Server URL
When user opens the app for the first time → login screen → URL field → they type `https://your-server.com`.
Tenant ID field: leave **blank** (single-tenant setup uses no tenant prefix).

### One-Line Change — Pre-fill Server URL (Recommended for Production)
Build the app with the server URL baked in (so users don't need to type it):
```bash
flutter build apk \
  --flavor deeplinksDisabledSmsReceiverDisabled \
  --dart-define=WEBTRIT_APP_CORE_URL=https://your-server.com \
  --dart-define=WEBTRIT_APP_NAME=YourAppName
```

This is the **only client change recommended** — and it's optional. Everything else (API endpoints, signaling protocol, auth headers) is implemented server-side with zero client modifications.

---

## Appendix — Key Design Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| JWT vs. opaque tokens | JWT | No database lookup on every request — token is self-validating. Easy to expire. |
| Single port vs. split | Split (3000 REST, 3001 WS) | Nginx routes by URL path, but separating ports simplifies server code |
| In-memory call tracking vs. Redis | In-memory first, Redis later | Simpler to start; Redis needed only when running multiple server instances |
| App-to-app first, SIP later | App-to-app | Lets you test 80% of app functionality without SIP setup complexity |
| FreeSWITCH vs. Kamailio | FreeSWITCH | Better documentation for beginners; handles RTP natively |
| bcrypt for passwords | bcrypt (app-level) | MySQL has no built-in bcrypt; hashing done in Node.js with `bcryptjs` before inserting |


Access

- URL: http://localhost:5173
- Login: admin@example.com / admin123
