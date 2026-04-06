# WebtRit Admin Panel

A clean dark-sidebar admin UI for the WebtRit Phone backend, built with Vite + React.

## Features

- **Dashboard** — system stats (users, active calls, calls today, push tokens), Janus health status, recent call log
- **Users** — searchable paginated table, create/edit/delete users
- **Call Logs** — full CDR with date range and text filters
- **Active Calls** — live polling table (every 5s) with force hangup
- **Janus Health** — gateway info, plugins, transports, network settings
- **Configuration** — editable Janus/Gorush/version settings, read-only DB info
- **Push Tokens** — list by user, delete tokens, send test push notifications

## Prerequisites

- Node.js 18+
- WebtRit backend running on port 3000

## Setup

```bash
cd admin_frontend
npm install
```

Copy the environment file (already created):
```
admin_frontend/.env
  VITE_API_URL=http://localhost:3000
```

## Development

```bash
npm run dev
```

Opens at http://localhost:5173

## Production Build

```bash
npm run build
# Output in admin_frontend/dist/
```

Serve the `dist/` folder with any static file server (nginx, express static, etc.).

## Default Credentials

| Field    | Value               |
|----------|---------------------|
| Email    | admin@example.com   |
| Password | admin123            |

> Change these immediately in production by running `002_admin.sql` with an updated bcrypt hash,
> or set `ADMIN_EMAIL` and `ADMIN_PASSWORD` environment variables on the backend.

## Backend Admin API Routes

All routes are prefixed with `/admin`:

| Method | Path                          | Description                  |
|--------|-------------------------------|------------------------------|
| POST   | /admin/auth/login             | Authenticate admin           |
| GET    | /admin/stats                  | System statistics            |
| GET    | /admin/users                  | List users (paginated)       |
| POST   | /admin/users                  | Create user                  |
| GET    | /admin/users/:id              | Get user                     |
| PUT    | /admin/users/:id              | Update user                  |
| DELETE | /admin/users/:id              | Delete/deactivate user       |
| GET    | /admin/calls/history          | Call log (CDR)               |
| GET    | /admin/calls/active           | Active calls (live)          |
| POST   | /admin/calls/:callId/hangup   | Force hangup                 |
| GET    | /admin/janus/health           | Janus server info            |
| GET    | /admin/config                 | Get configuration            |
| PUT    | /admin/config                 | Update configuration         |
| GET    | /admin/push-tokens            | List push tokens             |
| DELETE | /admin/push-tokens/:id        | Delete push token            |
| POST   | /admin/push-tokens/test       | Send test push notification  |

## Database Migration

Run `backend/src/db/migrations/002_admin.sql` to add the `admin_users` and `app_config` tables.

```sql
-- Creates admin_users and app_config tables
-- Inserts default admin@example.com / admin123
SOURCE backend/src/db/migrations/002_admin.sql;
```
