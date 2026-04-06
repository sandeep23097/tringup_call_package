# WebtRit Phone Backend

Node.js + TypeScript backend for the WebtRit Flutter phone app. Implements the WebtRit REST API and Phoenix Channels WebSocket signaling for app-to-app calls over WebRTC.

---

## Stack

- **Runtime**: Node.js 20
- **Language**: TypeScript 5
- **HTTP**: Express 4
- **WebSocket**: `ws` library with Phoenix Channels wire protocol
- **Database**: MySQL 8 (`mysql2`)
- **Cache / session bus**: Redis 7
- **Auth**: JWT (jsonwebtoken) + bcryptjs

---

## 1. Setup

### Option A — Local (npm)

**Requirements**: Node.js 20+, MySQL 8, Redis 7 running locally.

```bash
cd backend

# 1. Copy and edit the environment file
cp .env.example .env
# Edit .env: set DB_HOST, DB_PASSWORD, DB_ROOT_PASSWORD, JWT_SECRET, etc.

# 2. Create the database and run migrations
mysql -u root -p -e "CREATE DATABASE IF NOT EXISTS webtrit CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -p -e "CREATE USER IF NOT EXISTS 'webtrit'@'%' IDENTIFIED BY 'webtrit_password';"
mysql -u root -p -e "GRANT ALL PRIVILEGES ON webtrit.* TO 'webtrit'@'%'; FLUSH PRIVILEGES;"
mysql -u webtrit -p webtrit < src/db/migrations/001_initial.sql

# 3. Install dependencies
npm install

# 4. Start in development mode (auto-restarts on file change)
npm run dev
```

The server starts two listeners:
- REST API on `http://0.0.0.0:3000`
- WebSocket signaling on `ws://0.0.0.0:3001`

### Option B — Docker Compose

```bash
cd backend
cp .env.example .env
# Edit .env — at minimum set DB_PASSWORD, DB_ROOT_PASSWORD, and JWT_SECRET

docker compose up --build
```

Docker Compose starts MySQL 8, Redis 7, and the API container. The SQL migration in `src/db/migrations/001_initial.sql` is auto-applied by MySQL on first start.

---

## 2. Default Test Users

The migration seeds two users you can log in with immediately.

| Name        | Email               | Extension | Phone        | Password   |
|-------------|---------------------|-----------|--------------|------------|
| Alice Smith | alice@example.com   | 101       | +15551111111 | test1234   |
| Bob Jones   | bob@example.com     | 102       | +15552222222 | test1234   |

You can dial between these two accounts using their email, extension, or phone number as the dial target.

---

## 3. Adding More Users

Generate a bcrypt hash for the password (cost factor 10, matching what the seed uses):

```bash
node -e "const b=require('bcryptjs'); b.hash('yourpassword', 10).then(h => console.log(h));"
```

Then insert the user into MySQL:

```sql
INSERT INTO users (id, email, password_hash, first_name, last_name, phone_main, ext, sip_username, status)
VALUES (UUID(), 'carol@example.com', '<paste hash here>', 'Carol', 'White', '+15553333333', '103', 'carol', 'active');
```

Fields:
- `phone_main` — E.164 format, used as the dial target (e.g. `+15553333333`)
- `ext` — short extension number (e.g. `103`), also a valid dial target
- `sip_username` — alphanumeric name, also a valid dial target and login username
- `email` — used for login and OTP flows
- `status` — `active` or `blocked`

---

## 4. App-to-App Call Flow

All media negotiation (WebRTC SDP/ICE) is relayed through the server in-process. No Janus or SIP is involved.

```
Alice (caller)                   Server                   Bob (callee)
     |                              |                           |
     |-- WS connect + phx_join ---->|                           |
     |                              |<---- WS connect + phx_join|
     |                              |                           |
     |-- outgoing_call (SDP offer)->|                           |
     |<- calling -------------------|                           |
     |                              |--- incoming_call (offer)->|
     |<- ringing -------------------|<-- ice_trickle -----------|
     |<- ice_trickle (relayed) -----|                           |
     |                              |                           |
     |-- ice_trickle (relayed) ---->|--- ice_trickle (relayed)->|
     |                              |                           |
     |                              |<-- accept (SDP answer) ---|
     |<- accepted (answer) ---------|                           |
     |                              |                           |
     |         [ call in progress — ICE relayed both ways ]     |
     |                              |                           |
     |-- hangup -------------------->|--- hangup -------------->|
     |                              |  (CDR updated in MySQL)   |
```

**Offline callee**: If Bob is not connected to the WebSocket when Alice calls, the server sends a push notification via Gorush (FCM/APNs). When Bob's app wakes and connects, Alice's client must retry or the call is shown as missed.

**Call record**: Written to `call_records` table on `accept`, updated with duration on `hangup` or `decline`.

---

## 5. Connecting the Flutter App

In the WebtRit Flutter app login screen, enter the server URL in the "Server" or "Core URL" field.

**Without tenant**:
```
https://your-server.example.com
```

**With tenant** (multi-tenant mode):
```
https://your-server.example.com/tenant/my-tenant-id
```

The app will automatically:
- Call `GET /api/v1/system-info` to discover capabilities
- Call `POST /api/v1/session` with email + password to log in
- Open `wss://your-server.example.com/signaling/v1?token=<jwt>&force=true` for signaling

If you are running locally without HTTPS, use your machine's LAN IP and configure the Flutter app to allow plain HTTP (edit `network_security_config.xml` on Android or use `--disable-fbs-verification` flag if available).

---

## API Reference Summary

| Method   | Path                             | Auth | Description                     |
|----------|----------------------------------|------|---------------------------------|
| GET      | /api/v1/system-info              | No   | Server capabilities             |
| POST     | /api/v1/session                  | No   | Login (email/password)          |
| POST     | /api/v1/session/otp-create       | No   | Request OTP                     |
| POST     | /api/v1/session/otp-verify       | No   | Verify OTP                      |
| POST     | /api/v1/session/auto-provision   | No   | Provision token login           |
| DELETE   | /api/v1/session                  | Yes  | Logout                          |
| GET      | /api/v1/user                     | Yes  | Current user profile            |
| DELETE   | /api/v1/user                     | Yes  | Delete account                  |
| GET      | /api/v1/user/contacts            | Yes  | Directory / contact list        |
| GET      | /api/v1/user/contacts/:id        | Yes  | Single contact                  |
| GET      | /api/v1/user/history             | Yes  | Call history (CDR)              |
| GET      | /api/v1/user/voicemails          | Yes  | Voicemail list (stub)           |
| GET      | /api/v1/user/notifications       | Yes  | Notifications                   |
| GET      | /api/v1/app/status               | Yes  | Registration status             |
| PATCH    | /api/v1/app/status               | Yes  | Update registration status      |
| POST     | /api/v1/app/push-tokens          | Yes  | Register push token             |
| GET      | /health                          | No   | Health check                    |

**WebSocket**: `ws://host:3001/signaling/v1?token=<jwt>&force=<bool>`

---

## Environment Variables

| Variable         | Default                | Description                        |
|------------------|------------------------|------------------------------------|
| PORT             | 3000                   | REST API port                      |
| WS_PORT          | 3001                   | WebSocket signaling port           |
| DB_HOST          | localhost              | MySQL host                         |
| DB_PORT          | 3306                   | MySQL port                         |
| DB_USER          | webtrit                | MySQL username                     |
| DB_PASSWORD      | webtrit_password       | MySQL password                     |
| DB_NAME          | webtrit                | MySQL database name                |
| DB_ROOT_PASSWORD | root_password          | MySQL root password (Docker only)  |
| REDIS_URL        | redis://localhost:6379 | Redis connection URL               |
| JWT_SECRET       | dev_secret_...         | JWT signing secret (change this!)  |
| APP_VERSION      | 1.0.0                  | Reported in /system-info           |
| GORUSH_URL       | http://localhost:8088  | Gorush push notification server    |

**Important**: Always set a strong random `JWT_SECRET` in production. You can generate one with:

```bash
node -e "console.log(require('crypto').randomBytes(64).toString('hex'))"
```
