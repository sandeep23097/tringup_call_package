# WebTrit Phone — Backend Implementation Guide

This document explains everything you need to build a backend that is 100% compatible with the `webtrit_phone` Flutter app. The app's closed-source backend communicates over two channels: a **REST HTTP API** and a **WebSocket signaling protocol**. Both are fully reverse-engineered from the app's source code in `packages/webtrit_api` and `packages/webtrit_signaling`.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Technology Stack Recommendations](#2-technology-stack-recommendations)
3. [REST API — Base Setup](#3-rest-api--base-setup)
4. [REST API — Authentication Endpoints](#4-rest-api--authentication-endpoints)
5. [REST API — User & Contacts Endpoints](#5-rest-api--user--contacts-endpoints)
6. [REST API — Call History & Voicemail](#6-rest-api--call-history--voicemail)
7. [REST API — Push Notifications](#7-rest-api--push-notifications)
8. [REST API — System Notifications](#8-rest-api--system-notifications)
9. [REST API — Custom Endpoints](#9-rest-api--custom-endpoints)
10. [WebSocket Signaling Protocol](#10-websocket-signaling-protocol)
11. [Call Flow — Step by Step](#11-call-flow--step-by-step)
12. [Push Notification Payloads](#12-push-notification-payloads)
13. [Database Schema](#13-database-schema)
14. [SIP/WebRTC Media Server Integration](#14-sipwebrtc-media-server-integration)
15. [Complete Setup Walkthrough](#15-complete-setup-walkthrough)
16. [Error Codes Reference](#16-error-codes-reference)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                   Flutter App (Client)                   │
│                                                         │
│   ┌───────────────┐         ┌─────────────────────┐     │
│   │  webtrit_api  │         │ webtrit_signaling   │     │
│   │  (HTTP REST)  │         │   (WebSocket)       │     │
│   └──────┬────────┘         └──────────┬──────────┘     │
└──────────┼──────────────────────────────┼───────────────┘
           │ HTTPS                        │ WSS
           ▼                              ▼
┌──────────────────┐          ┌─────────────────────┐
│  Your REST API   │          │  Your WebSocket     │
│  (e.g. /api/v1)  │          │  Signaling Server   │
└────────┬─────────┘          └──────────┬──────────┘
         │                               │
         ▼                               ▼
┌─────────────────────────────────────────────────────────┐
│                     Your Backend                         │
│                                                         │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────┐   │
│  │PostgreSQL│  │  Redis   │  │  Janus WebRTC GW   │   │
│  │(users,   │  │(sessions,│  │  (SIP ↔ WebRTC     │   │
│  │ history) │  │  tokens) │  │   bridging)         │   │
│  └──────────┘  └──────────┘  └────────────────────┘   │
│                                                         │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────┐   │
│  │  Firebase │  │   SIP    │  │   Gorush or FCM    │   │
│  │  Admin    │  │  Proxy   │  │   Push Gateway     │   │
│  │  SDK      │  │(Kamailio │  │                    │   │
│  └──────────┘  │ /OpenSIPS│  └────────────────────┘   │
│                └──────────┘                             │
└─────────────────────────────────────────────────────────┘
```

The app expects **two independent services** on the same base domain:
- `https://your-domain.com/api/v1/` — REST API
- `wss://your-domain.com/signaling/v1` — WebSocket signaling

---

## 2. Technology Stack Recommendations

You can use any language. Below are recommended stacks from easiest to most powerful:

### Option A — Node.js + Express (Easiest to start)
```
Node.js 20+
Express 4
PostgreSQL (via pg or Prisma)
Redis (via ioredis)
ws (WebSocket library)
firebase-admin (push notifications)
```

### Option B — Python + FastAPI (Best for rapid prototyping)
```
Python 3.11+
FastAPI
SQLAlchemy + asyncpg (PostgreSQL)
Redis (via aioredis)
websockets library
firebase-admin
```

### Option C — Elixir + Phoenix (Closest to original WebTrit)
```
Elixir 1.15+
Phoenix Framework
Phoenix Channels (WebSocket — matches the Elixir Phoenix socket protocol)
Ecto + PostgreSQL
Redis (via Redix)
```
> **Note**: The app's signaling client (`packages/webtrit_signaling`) uses `phoenix_socket` Dart package, meaning the original backend is built with **Elixir Phoenix**. Phoenix Channels over WebSocket is the native protocol. If you use Phoenix, signaling will work out-of-the-box.

### Option D — Go (Best performance)
```
Go 1.22+
Chi or Gin router
GORM + PostgreSQL
gorilla/websocket
firebase-admin-go
```

---

## 3. REST API — Base Setup

### Base URL
```
Single-tenant:    https://your-domain.com/api/v1
Multi-tenant:     https://your-domain.com/tenant/{tenantId}/api/v1
```

The app sends a `tenantId` as the `identifier` field in login requests. For a single-tenant setup, you can ignore the `/tenant/{id}` prefix entirely.

### Required Response Headers
Every response must include:
```
Content-Type: application/json; charset=utf-8
```

### Required Request Headers (sent by app)
```
Authorization: Bearer <token>     ← all authenticated endpoints
Content-Type: application/json; charset=utf-8
X-Request-Id: <uuid>              ← unique per request, log this for tracing
```

### Standard Error Response Format
```json
{
  "code": "error_code_string",
  "message": "Human readable message",
  "details": {
    "path": "field.name",
    "reason": "why it failed"
  }
}
```

### Special Error — Force Logout
When a token is invalid or expired, return:
```
HTTP 422 Unprocessable Entity
{
  "code": "refresh_token_invalid",
  "message": "Session expired"
}
```
The app will automatically log the user out when it receives this.

---

## 4. REST API — Authentication Endpoints

### GET `/api/v1/system-info`
**Auth**: None
**Purpose**: Called on app startup to check backend capabilities and version.

**Response** `200 OK`:
```json
{
  "core": { "version": "1.0.0" },
  "postgres": { "version": "15.0" },
  "adapter": {
    "name": "your-adapter",
    "version": "1.0.0",
    "supported": ["login", "otp"],
    "custom": {}
  },
  "janus": {
    "version": "1.1.0",
    "plugins": { "sip": { "version": "1.0.0" } },
    "transports": { "websocket": { "version": "1.0.0" } }
  },
  "gorush": { "version": "1.0.0" }
}
```
You can return mostly static/fake data here — the app just checks it exists.

---

### POST `/api/v1/session` — Login with Password
**Auth**: None

**Request body**:
```json
{
  "type": "android",
  "identifier": "your-tenant-id",
  "login": "user@example.com",
  "password": "secret123",
  "bundle_id": "com.webtrit.app"
}
```

`type` values the app sends: `smart`, `web`, `linux`, `macos`, `windows`, `android`, `android_hms`, `ios`

**Response** `200 OK` (success):
```json
{
  "token": "eyJhbGc...",
  "user_id": "user-uuid-here",
  "tenant_id": "your-tenant-id"
}
```

**Response** `200 OK` (OTP required — app will move to OTP verification screen):
```json
{
  "otp_id": "otp-uuid-here",
  "notification_type": "sms",
  "from_email": null,
  "tenant_id": "your-tenant-id"
}
```
`notification_type` values: `sms`, `email`, `push`

---

### POST `/api/v1/session/otp-create` — Request OTP Code
**Auth**: None

**Request body**:
```json
{
  "type": "android",
  "identifier": "your-tenant-id",
  "user_ref": "user@example.com",
  "bundle_id": "com.webtrit.app"
}
```

**Response** `200 OK`:
```json
{
  "otp_id": "otp-uuid-here",
  "notification_type": "sms",
  "from_email": null,
  "tenant_id": "your-tenant-id"
}
```
Your backend should generate a 6-digit OTP, store it linked to `otp_id`, and send it via SMS/email.

---

### POST `/api/v1/session/otp-verify` — Verify OTP Code
**Auth**: None

**Request body**:
```json
{
  "otp_id": "otp-uuid-here",
  "code": "123456"
}
```

**Response** `200 OK`:
```json
{
  "token": "eyJhbGc...",
  "user_id": "user-uuid-here",
  "tenant_id": "your-tenant-id"
}
```

---

### POST `/api/v1/session/auto-provision` — Token-Based Provisioning
**Auth**: None
**Purpose**: Used when users scan a QR code or click a provisioning link.

**Request body**:
```json
{
  "type": "android",
  "identifier": "device-id",
  "config_token": "provisioning-token-from-qr",
  "bundle_id": "com.webtrit.app"
}
```

**Response** `200 OK`: Same as login — returns `token`, `user_id`, `tenant_id`.

---

### DELETE `/api/v1/session` — Logout
**Auth**: Required

**Response**: `204 No Content`
Invalidate the token server-side and delete any stored push tokens for this session.

---

### POST `/api/v1/user` — Self-Register New User
**Auth**: None
**Purpose**: App shows a "Sign Up" button only if backend supports this.

**Request body**:
```json
{
  "type": "android",
  "identifier": "your-tenant-id",
  "login": "newuser@example.com",
  "password": "password123",
  "bundle_id": "com.webtrit.app"
}
```

**Response** `200 OK`: Same as login — returns session token.

---

### DELETE `/api/v1/user` — Delete Account
**Auth**: Required
**Response**: `204 No Content`

---

## 5. REST API — User & Contacts Endpoints

### GET `/api/v1/user` — Get Current User Info
**Auth**: Required

**Response** `200 OK`:
```json
{
  "status": "active",
  "numbers": {
    "main": "+15551234567",
    "ext": "101",
    "additional": [],
    "sms": ["+15551234567"]
  },
  "balance": {
    "balance_type": "prepaid",
    "amount": 10.50,
    "credit_limit": 100.0,
    "currency": "USD"
  },
  "email": "user@example.com",
  "first_name": "John",
  "last_name": "Doe",
  "alias_name": "JD",
  "company_name": "ACME Corp",
  "time_zone": "America/New_York"
}
```

`status` values: `active`, `limited`, `blocked`
`balance` is optional — omit it if you don't have billing.

---

### GET `/api/v1/user/contacts` — Get Directory / Contacts List
**Auth**: Required
**Purpose**: Shows the contacts/phonebook directory in the app.

**Response** `200 OK`:
```json
{
  "items": [
    {
      "user_id": "user-uuid",
      "sip_status": "registered",
      "numbers": {
        "main": "+15559876543",
        "ext": "102",
        "additional": [],
        "sms": []
      },
      "email": "jane@example.com",
      "first_name": "Jane",
      "last_name": "Smith",
      "alias_name": null,
      "company_name": "ACME Corp",
      "is_current_user": false,
      "is_registered_user": true
    }
  ]
}
```

`sip_status` values: `registered`, `notregistered`

---

### GET `/api/v1/user/contacts/{userId}` — Get Single Contact
**Auth**: Required
**Response**: Single contact object (same structure as above without the `items` wrapper).

---

### GET `/api/v1/app/status` — Get App Registration Status
**Auth**: Required
**Purpose**: Checks if this device is registered to receive calls.

**Response** `200 OK`:
```json
{
  "register": true
}
```

---

### PATCH `/api/v1/app/status` — Update Registration Status
**Auth**: Required
**Purpose**: App sets `register: true` on startup, `register: false` on logout.

**Request body**:
```json
{
  "register": true
}
```

**Response**: `204 No Content`

---

### POST `/api/v1/app/contacts` — Upload Local Phone Contacts
**Auth**: Required
**Purpose**: App sends device contact list so backend can match them to registered users.

**Request body**:
```json
[
  {
    "identifier": "+15551234567",
    "phones": ["15551234567", "5551234567"]
  }
]
```

**Response**: `204 No Content`

---

### GET `/api/v1/app/contacts/smart` — Get Suggested Contacts
**Auth**: Required
**Purpose**: Returns matched contacts based on previously uploaded device contacts.

**Response** `200 OK`:
```json
{
  "items": [
    {
      "user_id": "user-uuid",
      "numbers": { "main": "+15551234567", "ext": null, "additional": [], "sms": [] },
      "first_name": "John",
      "last_name": "Doe"
    }
  ]
}
```

---

## 6. REST API — Call History & Voicemail

### GET `/api/v1/user/history` — Call History (CDR)
**Auth**: Required
**Query params**: `time_from`, `time_to` (ISO8601), `items_per_page` (int)

**Response** `200 OK`:
```json
{
  "items": [
    {
      "call_id": "call-uuid",
      "caller": "+15551234567",
      "callee": "+15559876543",
      "direction": "out",
      "status": "answered",
      "connect_time": "2024-03-12T10:30:00Z",
      "disconnect_time": "2024-03-12T10:35:30Z",
      "duration": 330,
      "disconnect_reason": "normal",
      "recording_id": null
    }
  ]
}
```

`direction`: `in` or `out`
`status`: `answered`, `missed`, `rejected`

---

### GET `/api/v1/user/voicemails` — List Voicemails
**Auth**: Required

**Response** `200 OK`:
```json
{
  "items": [
    {
      "id": "voicemail-uuid",
      "date": "2024-03-12T10:30:00Z",
      "sender": "+15551234567",
      "receiver": "+15559876543",
      "duration": 45.5,
      "seen": false,
      "size": 123456,
      "type": "audio",
      "attachments": [
        {
          "filename": "voicemail.mp3",
          "size": 123456,
          "type": "audio",
          "subtype": "mpeg"
        }
      ]
    }
  ]
}
```

---

### GET `/api/v1/user/voicemails/{id}` — Get Single Voicemail
**Auth**: Required
**Response**: Single voicemail object.

---

### PATCH `/api/v1/user/voicemails/{id}` — Mark as Seen
**Auth**: Required

**Request body**:
```json
{ "seen": true }
```

**Response**: `204 No Content`

---

### DELETE `/api/v1/user/voicemails/{id}` — Delete Voicemail
**Auth**: Required
**Response**: `204 No Content`

---

### GET `/api/v1/user/voicemails/{id}/attachment` — Download Audio
**Auth**: Required
**Query params**: `file_format` (e.g. `mp3`, `wav`)
**Response**: Binary audio file with appropriate `Content-Type: audio/mpeg`

---

## 7. REST API — Push Notifications

### POST `/api/v1/app/push-tokens` — Register Push Token
**Auth**: Required
**Purpose**: Called every time the app starts or gets a new push token from FCM/APNS.

**Request body**:
```json
{
  "type": "fcm",
  "value": "fcm-token-string-from-firebase"
}
```

`type` values:
- `fcm` — Firebase Cloud Messaging (Android)
- `apns` — Apple Push Notifications (iOS, standard)
- `apkvoip` — Apple VoIP Push (iOS, for CallKit — highest priority)
- `hms` — Huawei Mobile Services (Huawei Android)

**Response**: `204 No Content`

**What your backend should do**:
1. Store the token linked to the user's session
2. When an incoming call arrives for this user, use the stored token to send a push notification
3. The push notification wakes up the app even when backgrounded

---

## 8. REST API — System Notifications

### GET `/api/v1/user/notifications` — List Notifications
**Auth**: Required
**Query params**: `created_before` (ISO8601), `limit` (int)

**Response** `200 OK`:
```json
{
  "items": [
    {
      "id": 1,
      "title": "Welcome!",
      "content": "Your account is ready.",
      "type": "announcement",
      "seen": false,
      "created_at": "2024-03-12T10:00:00Z",
      "updated_at": "2024-03-12T10:00:00Z",
      "read_at": null
    }
  ]
}
```

`type` values: `announcement`, `promotion`, `security`, `system`

---

### GET `/api/v1/user/notifications/updates` — Poll for New Notifications
**Auth**: Required
**Query params**: `updated_after` (ISO8601, required), `limit` (int)
**Response**: Same format as above but only items newer than `updated_after`.

---

### PATCH `/api/v1/user/notifications/{id}` — Mark as Seen
**Auth**: Required

**Request body**:
```json
{ "seen": true }
```

**Response**: `204 No Content`

---

## 9. REST API — Custom Endpoints

These are optional but the app will call them. Return `404` if not implemented — the app handles that gracefully.

### POST `/api/v1/custom/private/call-to-actions`
**Auth**: Required
**Purpose**: Returns suggested actions/numbers when a user is about to make a call.

**Request body**:
```json
{ "phone_number": "+15551234567" }
```

**Response** `200 OK` or `404 Not Found` (app ignores 404).

---

### POST `/api/v1/custom/private/self-config-portal-url`
**Auth**: Required
**Purpose**: Returns URL to open a self-service settings web page.

**Response** `200 OK`:
```json
{ "url": "https://portal.your-domain.com/settings" }
```

---

### POST `/api/v1/custom/private/external-page-access-token`
**Auth**: Required
**Purpose**: Returns a short-lived token for the external page.

**Response** `200 OK`:
```json
{ "token": "short-lived-token" }
```

---

## 10. WebSocket Signaling Protocol

The app uses the `phoenix_socket` Dart package, which means the **Elixir Phoenix Channels WebSocket protocol**. The signaling runs over Phoenix Channels.

### Connection URL
```
wss://your-domain.com/signaling/v1?token=<bearer_token>&force=true
```

- `token` — same bearer token from login
- `force=true` — disconnect any other session for this user

### WebSocket Subprotocol
```
webtrit-protocol
```

### If you use Phoenix (Elixir) — Easy Path

Phoenix handles the channel protocol automatically. Your channel just needs to handle the correct events. The Dart `phoenix_socket` client will connect to:
```
wss://your-domain.com/socket/websocket?token=<token>&force=<true|false>
```

### If you use Node.js/Python — Manual Protocol

You must implement the Phoenix Channels wire protocol manually. The messages use this JSON format:

```json
[join_ref, message_ref, topic, event, payload]
```

Example join message from client:
```json
[1, 1, "signaling", "phx_join", {}]
```

You can use these libraries to handle Phoenix protocol without Elixir:
- Node.js: `phoenix` npm package or implement manually
- Python: `pyphoenix` or `asyncphoenix`

---

### Step 1 — Client Connects & Joins Channel

After WebSocket connection, the app immediately joins the `signaling` topic/channel.

**Your server must send the State Handshake immediately after join**:
```json
{
  "handshake": "state",
  "keepalive_interval": 30000,
  "timestamp": 1710220800000,
  "registration": {
    "status": "registered"
  },
  "lines": [null, null, null, null],
  "user_active_calls": [],
  "presence_contacts_info": {},
  "guest_line": null
}
```

`registration.status` values: `registering`, `registered`, `registration_failed`, `unregistering`, `unregistered`

`lines` is an array of active call states per line slot. `null` means the line is free. The app supports multiple simultaneous call lines.

`keepalive_interval` — milliseconds between keepalive pings (30000 = 30 seconds recommended).

---

### Step 2 — Keepalive Heartbeat

The client sends this every `keepalive_interval` milliseconds:
```json
{
  "handshake": "keepalive",
  "transaction": "auto-generated-id"
}
```

**Your server must reply immediately**:
```json
{
  "handshake": "keepalive",
  "transaction": "same-transaction-id-from-request"
}
```

If the server doesn't respond to keepalive within a timeout, the client reconnects.

---

### Step 3 — Incoming Call (Server → Client)

When a call comes in for this user, send:
```json
{
  "event": "incoming_call",
  "line": 0,
  "call_id": "unique-call-id-24chars",
  "caller": "+15551234567",
  "callee": "+15559876543",
  "caller_display_name": "John Doe",
  "referred_by": null,
  "replace_call_id": null,
  "is_focus": false,
  "jsep": {
    "type": "offer",
    "sdp": "v=0\r\no=- 12345 ... (full SDP offer from Janus)"
  }
}
```

The `jsep.sdp` comes from your Janus WebRTC gateway (see Section 14).

---

### Step 4 — Client Accepts Call (Client → Server)

```json
{
  "request": "accept",
  "transaction": "client-txn-id",
  "line": 0,
  "call_id": "unique-call-id-24chars",
  "jsep": {
    "type": "answer",
    "sdp": "v=0\r\no=- ... (SDP answer from client)"
  }
}
```

**You must respond**:
```json
{
  "response": "ack",
  "transaction": "client-txn-id"
}
```

Then send the accepted event:
```json
{
  "event": "accepted",
  "line": 0,
  "call_id": "unique-call-id-24chars",
  "callee": "+15559876543"
}
```

---

### Step 5 — Outgoing Call (Client → Server)

```json
{
  "request": "outgoing_call",
  "transaction": "client-txn-id",
  "line": 0,
  "call_id": "unique-call-id-24chars",
  "number": "+15559876543",
  "from": null,
  "refer_id": null,
  "replaces": null,
  "jsep": {
    "type": "offer",
    "sdp": "v=0\r\no=- ... (SDP offer from client)"
  }
}
```

**Your server must respond** with `ack`, then send events as the call progresses:

```json
{ "response": "ack", "transaction": "client-txn-id" }
```

Then send progression events:
```json
{ "event": "calling",    "line": 0, "call_id": "unique-call-id-24chars" }
{ "event": "proceeding", "line": 0, "call_id": "unique-call-id-24chars", "code": 100 }
{ "event": "ringing",    "line": 0, "call_id": "unique-call-id-24chars" }
```

When the callee answers, send:
```json
{
  "event": "accepted",
  "line": 0,
  "call_id": "unique-call-id-24chars",
  "callee": "+15559876543",
  "is_focus": false,
  "jsep": {
    "type": "answer",
    "sdp": "v=0\r\no=- ... (SDP answer from Janus)"
  }
}
```

---

### Step 6 — ICE Candidate Exchange

**Client sends candidates to server**:
```json
{
  "request": "ice_trickle",
  "transaction": "txn-id",
  "line": 0,
  "candidate": {
    "candidate": "candidate:1 1 UDP 2130706431 192.168.1.1 54321 typ host",
    "sdpMLineIndex": 0,
    "sdpMid": "0"
  }
}
```

End of candidates:
```json
{
  "request": "ice_trickle",
  "transaction": "txn-id",
  "line": 0,
  "candidate": { "completed": true }
}
```

**Server sends candidates to client**:
```json
{
  "event": "ice_trickle",
  "line": 0,
  "candidate": {
    "candidate": "candidate:...",
    "sdpMLineIndex": 0,
    "sdpMid": "0"
  }
}
```

No more candidates from server:
```json
{
  "event": "ice_trickle",
  "line": 0,
  "candidate": null
}
```

---

### Step 7 — WebRTC Connected

After ICE negotiation succeeds, send:
```json
{ "event": "ice_webrtcup", "line": 0 }
{ "event": "ice_media", "line": 0, "type": "audio", "receiving": true }
```

---

### Step 8 — Hangup

**Client hangs up**:
```json
{
  "request": "hangup",
  "transaction": "txn-id",
  "line": 0,
  "call_id": "unique-call-id-24chars"
}
```

**Server confirms hangup** (or initiates it):
```json
{
  "event": "hangup",
  "line": 0,
  "call_id": "unique-call-id-24chars"
}
```

---

### Other Signaling Messages

#### Decline Incoming Call
```json
{
  "request": "decline",
  "transaction": "txn-id",
  "line": 0,
  "call_id": "unique-call-id-24chars"
}
```

#### Hold / Unhold
```json
{ "request": "hold",   "transaction": "txn-id", "line": 0, "call_id": "...", "direction": "sendonly" }
{ "request": "unhold", "transaction": "txn-id", "line": 0, "call_id": "..." }
```

Events from server:
```json
{ "event": "holding",   "line": 0, "call_id": "..." }
{ "event": "unholding", "line": 0, "call_id": "..." }
```

#### Transfer (Blind)
```json
{
  "request": "transfer",
  "transaction": "txn-id",
  "line": 0,
  "call_id": "...",
  "number": "+15551112222",
  "replace_call_id": null
}
```

#### Mid-call SDP Update
```json
{
  "request": "update",
  "transaction": "txn-id",
  "line": 0,
  "call_id": "...",
  "jsep": { "type": "offer", "sdp": "v=0\r\n..." }
}
```

Server responds:
```json
{ "event": "updated", "line": 0, "call_id": "..." }
```

#### Error Response
```json
{
  "response": "error",
  "transaction": "txn-id",
  "code": 486,
  "reason": "User Busy"
}
```

---

## 11. Call Flow — Step by Step

### Outgoing Call Full Sequence
```
App                    Your Backend               Remote Phone/SIP
 |                          |                           |
 |-- outgoing_call + SDP -->|                           |
 |<-- ack ------------------|                           |
 |                          |--- SIP INVITE ----------->|
 |<-- calling event --------|                           |
 |                          |<-- 100 Trying ------------|
 |<-- proceeding event -----|                           |
 |                          |<-- 183 Session Progress --|
 |<-- progress event + SDP -|                           |
 |-- ice_trickle ---------->|-- ICE to Janus ---------->|
 |                          |<-- 180 Ringing ------------|
 |<-- ringing event --------|                           |
 |                          |<-- 200 OK + SDP ----------|
 |<-- accepted + SDP -------|                           |
 |                          |--- SIP ACK -------------->|
 |<-- ice_webrtcup event ---|                           |
 |<-- ice_media event ------|                           |
 |   [CALL IN PROGRESS]     |   [CALL IN PROGRESS]     |
 |-- hangup request ------->|                           |
 |                          |--- SIP BYE -------------->|
 |<-- hangup event ---------|<-- 200 OK ----------------|
```

### Incoming Call Full Sequence
```
Remote Phone/SIP       Your Backend                   App
       |                    |                           |
       |--- SIP INVITE ----->|                           |
       |                    |--- push notification ----->| (FCM/APNS)
       |                    |                           | (app wakes up)
       |                    |-- incoming_call + SDP --->|
       |                    |<-- accept + SDP answer ---|
       |                    |--- ack ------------------>|
       |                    |--- accepted event -------->|
       |<-- 200 OK + SDP ---|                           |
       |--- SIP ACK -------->|                           |
       |                    |--- ice_webrtcup ---------->|
       |                    |--- ice_media ------------->|
       |   [CALL IN PROGRESS]                           |
       |                    |<-- hangup request --------|
       |<-- SIP BYE ---------|                           |
       |--- 200 OK ---------->|                          |
       |                    |--- hangup event ---------->|
```

---

## 12. Push Notification Payloads

When a call arrives and the app is in background, you must send a push notification to wake it up.

### Android FCM Payload
```json
{
  "to": "<fcm_token_stored_in_db>",
  "priority": "high",
  "data": {
    "type": "call",
    "call_id": "unique-call-id-24chars",
    "caller": "+15551234567",
    "caller_display_name": "John Doe",
    "callee": "+15559876543"
  }
}
```

### iOS APNS VoIP Payload (CallKit)
```json
{
  "aps": {},
  "type": "call",
  "call_id": "unique-call-id-24chars",
  "caller": "+15551234567",
  "caller_display_name": "John Doe",
  "callee": "+15559876543"
}
```
Send this to the `apkvoip` token via APNS VoIP push for best results on iOS.

### Using Gorush (Recommended)
The original WebTrit uses [Gorush](https://github.com/appleboy/gorush) as a push gateway. It handles both FCM and APNS and provides a simple REST API:

```
POST http://gorush:8088/api/push
{
  "notifications": [
    {
      "tokens": ["<device_token>"],
      "platform": 2,        // 1=iOS, 2=Android
      "priority": "high",
      "data": { ... }
    }
  ]
}
```

---

## 13. Database Schema

Here is a minimal PostgreSQL schema to get started:

```sql
-- Users / Accounts
CREATE TABLE users (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   VARCHAR(100) NOT NULL DEFAULT 'default',
  email       VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255),
  first_name  VARCHAR(100),
  last_name   VARCHAR(100),
  alias_name  VARCHAR(100),
  company_name VARCHAR(200),
  time_zone   VARCHAR(50) DEFAULT 'UTC',
  status      VARCHAR(20) DEFAULT 'active',  -- active, limited, blocked
  sip_username VARCHAR(100) UNIQUE,
  sip_password VARCHAR(100),
  ext         VARCHAR(20),
  phone_main  VARCHAR(30),
  created_at  TIMESTAMP DEFAULT NOW()
);

-- Sessions / Auth Tokens
CREATE TABLE sessions (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID REFERENCES users(id) ON DELETE CASCADE,
  token       VARCHAR(512) UNIQUE NOT NULL,
  app_type    VARCHAR(20) NOT NULL,           -- android, ios, web, etc
  bundle_id   VARCHAR(200),
  created_at  TIMESTAMP DEFAULT NOW(),
  last_seen   TIMESTAMP DEFAULT NOW()
);

-- Push Tokens
CREATE TABLE push_tokens (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id  UUID REFERENCES sessions(id) ON DELETE CASCADE,
  user_id     UUID REFERENCES users(id) ON DELETE CASCADE,
  type        VARCHAR(20) NOT NULL,            -- fcm, apns, apkvoip, hms
  value       TEXT NOT NULL,
  updated_at  TIMESTAMP DEFAULT NOW()
);

-- OTP Codes
CREATE TABLE otp_codes (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID REFERENCES users(id) ON DELETE CASCADE,
  code        VARCHAR(10) NOT NULL,
  expires_at  TIMESTAMP NOT NULL,
  used        BOOLEAN DEFAULT FALSE
);

-- Call History (CDR)
CREATE TABLE call_records (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  call_id         VARCHAR(100) UNIQUE NOT NULL,
  caller_user_id  UUID REFERENCES users(id),
  callee_user_id  UUID REFERENCES users(id),
  caller          VARCHAR(50) NOT NULL,
  callee          VARCHAR(50) NOT NULL,
  direction       VARCHAR(5) NOT NULL,   -- in, out (relative to each user)
  status          VARCHAR(20) NOT NULL,  -- answered, missed, rejected
  connect_time    TIMESTAMP,
  disconnect_time TIMESTAMP,
  duration        INT DEFAULT 0,
  disconnect_reason VARCHAR(50),
  recording_id    UUID
);

-- Voicemails
CREATE TABLE voicemails (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID REFERENCES users(id) ON DELETE CASCADE,
  sender     VARCHAR(50) NOT NULL,
  receiver   VARCHAR(50) NOT NULL,
  duration   DECIMAL(10,2),
  seen       BOOLEAN DEFAULT FALSE,
  file_path  TEXT,
  file_size  INT,
  created_at TIMESTAMP DEFAULT NOW()
);

-- System Notifications
CREATE TABLE notifications (
  id         SERIAL PRIMARY KEY,
  user_id    UUID REFERENCES users(id) ON DELETE CASCADE,
  title      VARCHAR(200) NOT NULL,
  content    TEXT NOT NULL,
  type       VARCHAR(30) NOT NULL,  -- announcement, promotion, security, system
  seen       BOOLEAN DEFAULT FALSE,
  read_at    TIMESTAMP,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- App Registration Status
CREATE TABLE app_status (
  user_id    UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  registered BOOLEAN DEFAULT FALSE,
  updated_at TIMESTAMP DEFAULT NOW()
);

-- Uploaded Contacts (for smart contact matching)
CREATE TABLE device_contacts (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID REFERENCES users(id) ON DELETE CASCADE,
  identifier   VARCHAR(200) NOT NULL,
  phones       TEXT[],
  uploaded_at  TIMESTAMP DEFAULT NOW()
);
```

---

## 14. SIP/WebRTC Media Server Integration

The hardest part. The app uses WebRTC — it generates SDP offers and expects SDP answers. Your backend must bridge WebRTC ↔ SIP. The recommended (and original WebTrit) approach is **Janus WebRTC Gateway** with its SIP plugin.

### Option A — Janus Gateway (Recommended)

[Janus Gateway](https://janus.conf.meetecho.com/) is open source. Its SIP plugin converts between WebRTC and SIP.

**How it works**:
1. App sends WebRTC SDP offer to your signaling server
2. Your signaling server forwards it to Janus via Janus REST/WebSocket API
3. Janus converts WebRTC → SIP INVITE and sends to the SIP proxy (Kamailio/FreeSWITCH)
4. SIP response comes back → Janus converts to WebRTC SDP answer
5. You forward the SDP answer back to the app over signaling

**Install Janus**:
```bash
# Ubuntu/Debian
apt-get install janus

# Or Docker
docker run -d --name janus \
  -p 8088:8088 -p 8089:8089 \
  -p 20000-20100:20000-20100/udp \
  canyan/janus-gateway
```

**Janus SIP Plugin API** (your signaling server talks to this):
```
POST http://janus:8088/janus
{
  "janus": "attach",
  "plugin": "janus.plugin.sip",
  "transaction": "txn-id"
}
```

### Option B — FreeSWITCH (Simpler for beginners)

[FreeSWITCH](https://freeswitch.org/) has built-in WebRTC support (`mod_verto`) and SIP.

**Simpler flow**:
1. Configure FreeSWITCH with `mod_verto` for WebRTC
2. FreeSWITCH handles the WebRTC ↔ SIP bridging internally
3. Your signaling server becomes a thin proxy

### Option C — Asterisk + WebRTC (Most documentation)

[Asterisk](https://www.asterisk.org/) with `res_pjsip` and WebRTC configuration.

### Simplest Setup for Testing (No SIP)

If you just want to test the app works without SIP trunk integration:

1. Set up two user accounts
2. When user A calls user B, forward the WebRTC SDP offer from A's signaling connection to B's
3. Forward B's answer back to A
4. Forward ICE candidates between them
5. This creates a **peer-to-peer WebRTC call** through your server as relay

This is like a basic WebRTC signaling server. No SIP needed — just forward SDPs between two signaling connections.

---

## 15. Complete Setup Walkthrough

This is the recommended path to get the app running step by step.

### Phase 1 — Basic Auth & Profile (Get App to Log In)

1. Implement `GET /api/v1/system-info` returning static JSON
2. Implement `POST /api/v1/session` — hardcode a test user, return a fixed token
3. Implement `GET /api/v1/user` — return hardcoded user data
4. Implement `GET /api/v1/user/contacts` — return empty list `{"items":[]}`
5. Implement `GET /api/v1/app/status` — return `{"register":false}`
6. Implement `PATCH /api/v1/app/status` — return `204`
7. Implement `POST /api/v1/app/push-tokens` — return `204`

**Test**: Open app → configure server URL → log in → should see dashboard.

### Phase 2 — Signaling Connection (Get App Online)

1. Set up a WebSocket server on `wss://your-domain.com/signaling/v1`
2. On connection, authenticate using the `token` query parameter
3. Send the `state` handshake with `registration.status: "registered"`
4. Handle keepalive requests and respond
5. Never disconnect — keep the WebSocket alive

**Test**: App should show as "online/registered" in the UI.

### Phase 3 — Contacts & Directory

1. Implement `GET /api/v1/user/contacts` with real users from your database
2. Implement `POST /api/v1/app/contacts` — store and match against your user list
3. Implement `GET /api/v1/app/contacts/smart` — return matched users

**Test**: App contacts tab shows your users.

### Phase 4 — Internal Calls (App-to-App)

1. When app A sends `outgoing_call` on signaling, find user B in your database
2. Look up user B's active WebSocket connection
3. Send `incoming_call` event to user B with the SDP offer from user A
4. When user B sends `accept` with SDP answer, forward it back to user A as `accepted` event
5. Forward ICE candidates between the two connections
6. Handle `hangup`/`decline` requests

**Test**: Two devices both logged in can call each other.

### Phase 5 — Push Notifications for Background Calls

1. Store FCM/APNS tokens from `POST /api/v1/app/push-tokens`
2. When an incoming call arrives for a user who is not connected via WebSocket (app is backgrounded):
   - Send an FCM push notification with call data
   - App wakes up, reconnects WebSocket
   - Then send `incoming_call` event over WebSocket
3. Set up [Gorush](https://github.com/appleboy/gorush) for sending pushes

### Phase 6 — SIP Trunk Integration (PSTN Calls)

1. Install and configure **Janus Gateway** with SIP plugin
2. Configure Janus to register with your SIP provider or PBX
3. Modify your signaling server to forward WebRTC offers to Janus
4. Configure a SIP proxy (Kamailio or FreeSWITCH) for routing
5. Store CDR records in your database for call history

### Phase 7 — Voicemail & History

1. Implement `GET /api/v1/user/history` from your CDR database
2. Set up voicemail recording via your SIP server (Asterisk/FreeSWITCH)
3. Implement the voicemail API endpoints

---

## 16. Error Codes Reference

### HTTP Status Codes

| Code | Meaning | App Behavior |
|------|---------|--------------|
| `200` | Success | Process response |
| `204` | No Content (success) | OK |
| `404` | Endpoint not found | Silently ignore (feature disabled) |
| `422` with `refresh_token_invalid` | Session expired | Force logout |
| `422` other | Validation error | Show error message |
| `501` | Not implemented | Silently ignore |

### Signaling Error Codes

| Code Range | Category |
|-----------|---------|
| 452–457 | Request format errors |
| 458–472 | Session/connection errors |
| 471 | WebRTC/ICE error |
| 480 | Call terminated (normal) |
| 481 | Call doesn't exist |
| 486 | User busy |
| 487 | Request terminated (declined) |
| 603 | Decline |

Return errors in signaling like this:
```json
{
  "response": "error",
  "transaction": "original-txn-id",
  "code": 486,
  "reason": "User Busy"
}
```

---

## Quick Reference — Minimum Viable Backend Checklist

For the app to fully launch and be usable for basic calls, you need:

**REST API (required)**:
- [ ] `GET  /api/v1/system-info`
- [ ] `POST /api/v1/session` (login)
- [ ] `DELETE /api/v1/session` (logout)
- [ ] `GET  /api/v1/user` (profile)
- [ ] `GET  /api/v1/user/contacts`
- [ ] `GET  /api/v1/app/status`
- [ ] `PATCH /api/v1/app/status`
- [ ] `POST /api/v1/app/push-tokens`

**REST API (nice to have)**:
- [ ] `POST /api/v1/session/otp-create`
- [ ] `POST /api/v1/session/otp-verify`
- [ ] `GET  /api/v1/user/history`
- [ ] `GET  /api/v1/user/voicemails`
- [ ] `GET  /api/v1/user/notifications`

**WebSocket Signaling (required)**:
- [ ] Connection + authentication by token
- [ ] Send `state` handshake on connect
- [ ] Handle `keepalive` requests
- [ ] Send `incoming_call` event
- [ ] Handle `accept` / `decline` requests
- [ ] Handle `outgoing_call` request
- [ ] Handle `hangup` request
- [ ] Forward ICE candidates (`ice_trickle`)
- [ ] Send `accepted`, `calling`, `ringing`, `hangup` events

**Infrastructure (required for real calls)**:
- [ ] Janus WebRTC Gateway
- [ ] SIP Proxy (Kamailio / OpenSIPS / FreeSWITCH)
- [ ] Firebase project (for FCM push notifications)
- [ ] PostgreSQL database
- [ ] HTTPS + WSS (TLS certificate — Let's Encrypt works)
