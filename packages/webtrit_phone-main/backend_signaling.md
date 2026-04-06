# Backend Signaling & Push Notification Guide

## Overview

The backend handles two transport layers:
- **WebSocket** — real-time signaling for online users (WebtRit custom JSON protocol)
- **FCM / APNs push** — wake-up for offline / terminated-state users (via Gorush)

---

## Terminated-State Call Flow

When the callee's app is not running (terminated), the backend falls back to push:

```
Caller sends 'outgoing' via WebSocket
  └─ Backend checks cm.get(calleeId)  →  null (offline)
       └─ sendCallPush() → Gorush → FCM/APNs
            └─ Firebase wakes Dart isolate (background handler)
                 └─ _firebaseMessagingBackgroundHandler()
                      └─ PendingCallPush.fromFCM()  (if callId key present)
                           └─ reportNewIncomingCall()
                                └─ CallKeep → native system call UI
```

---

## FCM Data Payload — Exact Field Names

The Flutter app (`packages/webtrit_callkeep`) uses `CallDataConst` to read the push payload.
**All fields are strings.**  The discriminator is the presence of `callId`.

| Field | Type | Description |
|---|---|---|
| `callId` | string | Unique call UUID — **discriminator** (must be present) |
| `handleValue` | string | Caller phone number / extension |
| `displayName` | string | Caller display name |
| `hasVideo` | string | `"true"` or `"false"` |

> **Important:** Field names are **camelCase**.  Using `call_id` (snake_case) causes the push to be
> parsed as `UnknownPush` and the call screen never appears.

### Example Gorush request body

```json
{
  "notifications": [{
    "tokens":   ["<FCM_DEVICE_TOKEN>"],
    "platform": 2,
    "priority": "high",
    "data": {
      "callId":      "550e8400-e29b-41d4-a716-446655440000",
      "handleValue": "+15551234567",
      "displayName": "Alice Smith",
      "hasVideo":    "false"
    }
  }]
}
```

### APNs VoIP (iOS background / locked screen)

For `apkvoip` tokens, add `"voip": true, "content_available": true` to the notification object:

```json
{
  "tokens":            ["<APNS_VOIP_TOKEN>"],
  "platform":          1,
  "priority":          "high",
  "voip":              true,
  "content_available": true,
  "data": {
    "callId":      "...",
    "handleValue": "+15551234567",
    "displayName": "Alice Smith",
    "hasVideo":    "false"
  }
}
```

---

## Push Token Types

| `type` column | Platform code | Description |
|---|---|---|
| `fcm` | 2 | Android — Firebase Cloud Messaging |
| `hms` | 2 | Android — Huawei Mobile Services |
| `apns` | 1 | iOS — foreground/background push |
| `apkvoip` | 1 | iOS — VoIP push (PushKit), wakes terminated apps |

---

## Flutter Background Handler

**File:** `lib/push_notification/app_remote_push.dart` and
`lib/features/push_notifications/bloc/push_notifications_bloc.dart`

The entry point registered with Firebase is annotated with `@pragma('vm:entry-point')`
to prevent tree-shaking in release builds:

```dart
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // ... calls reportNewIncomingCall() via CallKeep
}
```

### Parsing logic

```dart
// Discriminator check (app_remote_push.dart)
if (data.containsKey(CallDataConst.callId)) {
  return PendingCallPush.fromFCM(data);   // ← correct path
}
// else → UnknownPush (call screen never appears)
```

```dart
// PendingCallPush.fromFCM field mapping
PendingCall(
  callId:      data[CallDataConst.callId],       // 'callId'
  number:      data[CallDataConst.handleValue],  // 'handleValue' → caller phone
  displayName: data[CallDataConst.displayName],  // 'displayName'
  hasVideo:    data[CallDataConst.hasVideo] == 'true',
)
```

---

## Backend sendCallPush — Current Implementation

**File:** `backend/src/signaling/handlers/call.ts` — `sendCallPush()`

```typescript
data: {
  callId:      callId,          // UUID from client
  handleValue: caller,          // caller phone / userId
  displayName: callerName,      // "First Last"
  hasVideo:    'false',         // string, not boolean
}
```

This matches the Flutter `CallDataConst` field names exactly.

---

## How to Test Terminated-State Calls

### Prerequisites
1. Gorush running and reachable at `GORUSH_URL` (default `http://localhost:8088`)
2. FCM credentials configured in Gorush (`gorush.yml`)
3. Push token registered in DB:
   ```sql
   SELECT * FROM push_tokens WHERE user_id = '<callee_id>';
   ```

### Test steps
1. **Kill the Flutter app** completely (swipe away from recents / force-stop).
2. From another device / the admin panel, initiate a call to the callee.
3. Backend finds callee offline → `sendCallPush()` fires.
4. FCM delivers the data-only message to the device.
5. Android/iOS wakes the Dart isolate → `_firebaseMessagingBackgroundHandler`.
6. Native system call UI appears (full-screen incoming call notification).
7. User answers → app resumes, WebSocket reconnects, call proceeds via Janus.

### Manual push test (curl)

```bash
curl -X POST http://localhost:8088/api/push \
  -H 'Content-Type: application/json' \
  -d '{
    "notifications": [{
      "tokens":   ["YOUR_FCM_TOKEN"],
      "platform": 2,
      "priority": "high",
      "data": {
        "callId":      "test-call-1234",
        "handleValue": "+15551234567",
        "displayName": "Test Caller",
        "hasVideo":    "false"
      }
    }]
  }'
```

### Admin panel push test

Admin panel → **Push Tokens** page → select token → **Send Test Push**.
The test push uses the correct field names automatically.

---

## Gorush Configuration Reference

Gorush reads a `gorush.yml`.  Minimum FCM config:

```yaml
core:
  port: "8088"
  max_notification: 100

android:
  enabled: true
  key_path: "/path/to/service-account.json"   # Firebase service account JSON
```

The `GORUSH_URL` env var in `backend/.env` must point to where Gorush is running.

---

## Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| Call screen never appears on terminated app | Push payload uses `call_id` not `callId` | Fixed — backend now sends `callId` |
| Push delivered but app ignores it | Missing `callId` key → parsed as `UnknownPush` | Ensure `callId` is in `data` map |
| No push sent at all | No push token in DB for callee | Register token by logging in on device first |
| Gorush returns 4xx | Wrong token format or expired token | Delete and re-register token |
| iOS call screen missing | Using `apns` token instead of `apkvoip` | App must register PushKit token → type `apkvoip` |
