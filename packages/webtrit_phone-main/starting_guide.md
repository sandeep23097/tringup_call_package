# WebtRit Phone — Starting Guide

## Project Layout

```
webtrit_phone-main/
├── lib/                  Flutter app source
├── backend/              Node.js signaling + REST API
├── admin_frontend/       React admin panel
└── packages/             Flutter packages (signaling, callkeep)
```

---

## Backend

### Prerequisites
- Node.js 18+
- MySQL 8 running with database `webtrit`
- Janus WebRTC server (configured in `.env`)

### First-time setup

```bash
cd backend
npm install

# Apply DB migrations (run once, or when new migrations appear)
mysql -u webtrit -p webtrit < src/db/migrations/001_initial.sql
mysql -u webtrit -p webtrit < src/db/migrations/002_admin.sql
```

### Start (dev — auto-reloads on file change)

```bash
cd backend
npm run dev
```

### Start (production)

```bash
cd backend
npm run build      # compile TypeScript → dist/
npm start          # node dist/index.js
```

### Stop

```bash
# Dev: Ctrl+C in terminal, or:
pkill -f "ts-node-dev"

# Production:
pkill -f "node dist/index.js"
```

### Default port
`http://localhost:3000` — serves both REST API and WebSocket signaling on the same port.

---

## Configuration

All settings are controlled via environment variables. Create `backend/.env` to override defaults:

```env
# Server
PORT=3000

# Database (MySQL)
DB_HOST=localhost
DB_PORT=3306
DB_USER=webtrit
DB_PASSWORD=webtrit_password
DB_NAME=webtrit

# Auth
JWT_SECRET=dev_secret_change_in_production

# Janus WebRTC server
JANUS_URL=http://aws.edumation.in:8889/janus

# Push notifications (Gorush)
GORUSH_URL=http://localhost:8088

# Redis (optional — not required currently)
REDIS_URL=redis://localhost:6379

# App version reported to Flutter clients
APP_VERSION=1.0.0
```

> Runtime config (Janus URL, Gorush URL, App Version) can also be edited live from the admin panel → **Configuration** page. Changes are stored in the `app_config` DB table and take effect immediately.

---

## Admin Frontend

### Prerequisites
- Node.js 18+
- Backend running on port 3000

### Start (dev)

```bash
cd admin_frontend
npm install       # first time only
npm run dev
```

Opens at **http://localhost:5173**

**Default login:** `admin@example.com` / `admin123`

### Build for production

```bash
cd admin_frontend
npm run build     # output in admin_frontend/dist/
```

Serve the `dist/` folder with any static host (nginx, Apache, etc.).

### Point to a different backend URL

Edit `admin_frontend/.env`:

```env
VITE_API_URL=http://your-server-ip:3000
```

### Stop dev server

Ctrl+C in terminal, or `pkill -f vite`.

---

## Flutter App

### Run (Android)

```bash
flutter run --flavor deeplinksDisabledSmsReceiverDisabled
```

### Build APK

```bash
flutter build apk --flavor deeplinksDisabledSmsReceiverDisabled
```

### Backend URL
Set in the app at first launch — enter your server's LAN/public IP, e.g. `http://192.168.1.x:3000`.

---

## Quick Reference

| Service | Command | URL |
|---|---|---|
| Backend (dev) | `cd backend && npm run dev` | `http://localhost:3000` |
| Admin panel (dev) | `cd admin_frontend && npm run dev` | `http://localhost:5173` |
| Health check | `curl http://localhost:3000/health` | — |
| Admin login | — | `admin@example.com` / `admin123` |

---

## Admin Panel Pages

| Page | Purpose |
|---|---|
| Dashboard | Live stats, Janus status, recent calls |
| Users | Create / edit / delete app users |
| Call Logs | Full CDR with date & search filters |
| Active Calls | Live calls with force-hangup option |
| Janus Health | Janus server info, plugins, ICE config |
| Configuration | Edit Janus URL, Gorush URL, JWT secret |
| Push Tokens | View / delete tokens, send test push |

---

## Useful DB Queries

```sql
-- List all users
SELECT id, email, phone_main, status FROM users;

-- Recent call records
SELECT caller, callee, status, duration FROM call_records
ORDER BY created_at DESC LIMIT 20;

-- Check admin users
SELECT id, name, email FROM admin_users;

-- Reset admin password (admin123)
UPDATE admin_users SET password_hash =
  '$2a$10$TalNnBlDHJ6jrMTkGT5NFuVjusDwTHzGXGoyckglBLdZInIuIDo5q'
WHERE email = 'admin@example.com';
```
