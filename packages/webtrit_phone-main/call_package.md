# Call Package Integration Guide

> How to embed the WebtRit call system into a separate chat application while
> keeping both projects modular and independently deployable.

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        USER DEVICE                              │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    CHAT APP (Flutter)                    │   │
│  │                                                          │   │
│  │  ┌──────────────────┐    ┌───────────────────────────┐   │   │
│  │  │  Chat UI / Auth  │    │  WebtritCallWidget        │   │   │
│  │  │  (chat app code) │    │  (embedded call package)  │   │   │
│  │  └────────┬─────────┘    └───────────┬───────────────┘   │   │
│  │           │ chat JWT                 │ call JWT           │   │
│  └───────────┼──────────────────────────┼───────────────────┘   │
│              │                          │ WebSocket signaling    │
└──────────────┼──────────────────────────┼───────────────────────┘
               │ HTTPS                    │ HTTPS / WSS
    ┌──────────▼──────────┐    ┌──────────▼──────────────┐
    │   CHAT BACKEND      │    │   CALL BACKEND          │
    │   (your server)     │    │   (webtrit_phone-main   │
    │                     │───▶│    /backend)            │
    │  Issues chat JWTs   │API │                         │
    │  Calls /integration │key │  Issues call JWTs       │
    │  to get call JWTs   │    │  Manages users/calls    │
    └─────────────────────┘    └─────────────────────────┘
```

### Key Design Decisions

| Concern | Decision |
|---------|----------|
| Auth | Chat app owns identity; call backend issues its own short-lived JWT via a server-to-server integration API |
| Flutter | Minimum changes to call project; a thin `WebtritCallPackage` entry point wraps the existing `CallBloc` tree |
| Permissions | Chat app requests all permissions once; call package reuses them |
| Push tokens | Chat app owns FCM registration; call package receives the token via a callback |
| Navigation | Call screen overlays the chat app using the existing `CallShell` overlay pattern |
| Contacts | Chat app provides a `ContactNameResolver` callback; call package does not import chat contacts independently |

---

## 2. Backend Integration API (Call Backend)

Add a new integration router that the **chat backend** calls
**server-to-server** using a shared secret (`INTEGRATION_API_KEY`).

### 2.1 New environment variable

```env
# .env (call backend)
INTEGRATION_API_KEY=super-secret-key-shared-with-chat-backend
```

### 2.2 New file: `backend/src/routes/integration/index.ts`

```typescript
import { Router } from 'express';
import jwt      from 'jsonwebtoken';
import { db }   from '../../db/connection';
import { config } from '../../config';

const router = Router();

// Middleware: verify shared API key (server-to-server only)
router.use((req, res, next) => {
  const key = req.headers['x-integration-key'];
  if (!key || key !== config.integrationApiKey) {
    return res.status(401).json({ error: 'Invalid integration key' });
  }
  next();
});

/**
 * POST /integration/token
 * Chat backend calls this to get a call JWT for a user.
 *
 * Request body:
 *   { userId: string, externalId?: string, phoneNumber: string,
 *     firstName?: string, lastName?: string }
 *
 * Response:
 *   { token: string, expiresIn: number }
 */
router.post('/token', async (req, res) => {
  const { userId, phoneNumber, firstName, lastName, externalId } = req.body;
  if (!userId || !phoneNumber) {
    return res.status(400).json({ error: 'userId and phoneNumber are required' });
  }

  // Upsert user into call backend's users table
  await db.query(
    `INSERT INTO users (id, phone_main, first_name, last_name, status)
     VALUES (?, ?, ?, ?, 'active')
     ON DUPLICATE KEY UPDATE
       phone_main = VALUES(phone_main),
       first_name = VALUES(first_name),
       last_name  = VALUES(last_name),
       status     = 'active'`,
    [userId, phoneNumber, firstName ?? '', lastName ?? ''],
  );

  const token = jwt.sign({ userId }, config.jwtSecret, { expiresIn: '24h' });
  return res.json({ token, expiresIn: 86400 });
});

/**
 * DELETE /integration/users/:userId
 * Deactivate a user (e.g. when they log out of the chat app).
 */
router.delete('/users/:userId', async (req, res) => {
  await db.query(`UPDATE users SET status = 'inactive' WHERE id = ?`, [req.params.userId]);
  return res.json({ ok: true });
});

/**
 * GET /integration/users/:userId/status
 * Returns whether the user is currently connected to signaling.
 */
router.get('/users/:userId/status', async (req, res) => {
  const { cm } = await import('../../signaling/connection-manager');
  const conn = cm.get(req.params.userId);
  return res.json({ online: !!conn });
});

export default router;
```

### 2.3 Mount in `backend/src/index.ts`

```typescript
import integrationRouter from './routes/integration';
// ...
app.use('/integration', integrationRouter);
```

### 2.4 Add to `backend/src/config.ts`

```typescript
export const config = {
  // ... existing fields ...
  integrationApiKey: process.env.INTEGRATION_API_KEY || 'change-me',
};
```

### 2.5 Integration API summary

| Method | Path | Who calls it | Purpose |
|--------|------|-------------|---------|
| `POST` | `/integration/token` | Chat backend | Get call JWT for a user |
| `DELETE` | `/integration/users/:id` | Chat backend | Deactivate user on logout |
| `GET` | `/integration/users/:id/status` | Chat backend | Check if user is online in signaling |

> **Security**: These routes are never exposed to the Flutter client directly.
> Only your chat backend can call them (it holds `INTEGRATION_API_KEY`).

---

## 3. Chat Backend Flow

When a chat user logs in:

```
1. Chat user authenticates with chat backend (any method)
2. Chat backend calls:
   POST https://call-backend/integration/token
   Headers: X-Integration-Key: <secret>
   Body: { userId, phoneNumber, firstName, lastName }
3. Call backend returns { token, expiresIn }
4. Chat backend includes callToken in the login response to the Flutter app
```

Example chat backend pseudocode (Node/Express):

```javascript
app.post('/auth/login', async (req, res) => {
  const user = await authenticateUser(req.body);

  // Get a call JWT for this user
  const callResp = await axios.post(`${CALL_BACKEND_URL}/integration/token`, {
    userId:      user.id,
    phoneNumber: user.phoneNumber,
    firstName:   user.firstName,
    lastName:    user.lastName,
  }, {
    headers: { 'X-Integration-Key': process.env.INTEGRATION_API_KEY },
  });

  res.json({
    chatToken:   user.chatJwt,
    callToken:   callResp.data.token,    // ← passed to Flutter call package
    callTenantId: CALL_TENANT_ID,
    callServerUrl: CALL_BACKEND_URL,
  });
});
```

---

## 4. Flutter Call Package – Changes

### 4.1 What NOT to change

- `CallBloc` and all its handlers
- All repositories and their implementations
- The signaling protocol
- `CallShell`, `CallScreen`, `CallActiveThumbnail`
- `CallPullBadge`, `PullableCallsDialog`
- Permissions handling (stays in the call app)
- Push notification background isolate logic

### 4.2 New files to add (do not modify existing files)

#### `lib/call_package/webtrit_call_package.dart`

This is the **single public entry point** the chat app imports.

```dart
library webtrit_call_package;

export 'src/call_package_widget.dart';
export 'src/call_package_controller.dart';
```

#### `lib/call_package/src/call_package_config.dart`

```dart
class CallPackageConfig {
  const CallPackageConfig({
    required this.serverUrl,
    required this.tenantId,
    required this.token,
    required this.userId,
    required this.phoneNumber,
    this.firstName,
    this.lastName,
  });

  final String serverUrl;   // e.g. "https://call.example.com"
  final String tenantId;    // e.g. "f1rIih5iS3yACprjOBbF-0"
  final String token;       // call JWT from /integration/token
  final String userId;      // must match the userId used to issue the token
  final String phoneNumber;
  final String? firstName;
  final String? lastName;
}
```

#### `lib/call_package/src/call_package_controller.dart`

Exposes an imperative API so the chat app can trigger calls programmatically.

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:webtrit_phone/features/call/call.dart';

class CallPackageController {
  BuildContext? _context;

  /// Called internally by CallPackageWidget when it mounts.
  void attach(BuildContext context) => _context = context;

  /// Call this from the chat app to initiate an outgoing call.
  void makeCall({
    required String number,
    String? displayName,
    bool video = false,
  }) {
    assert(_context != null, 'CallPackageController must be attached before calling makeCall');
    _context!.read<CallBloc>().add(
      CallControlEvent.started(
        number: number,
        video: video,
        displayName: displayName,
      ),
    );
  }

  void detach() => _context = null;
}
```

#### `lib/call_package/src/call_package_widget.dart`

The widget the chat app puts near the root of its widget tree.
It wires up all the BLoC dependencies without touching the existing `main_shell.dart`.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';

import 'package:webtrit_phone/app/router/main_shell.dart' show buildCallBloc;
import 'package:webtrit_phone/features/call/view/call_shell.dart';
import 'package:webtrit_phone/repositories/repositories.dart';

import 'call_package_config.dart';
import 'call_package_controller.dart';

/// Place this widget near the root of your chat app, above any widget that
/// needs to trigger or display calls.
///
/// ```dart
/// CallPackageWidget(
///   config: CallPackageConfig(...),
///   controller: _callController,
///   child: MyChatApp(),
/// )
/// ```
class CallPackageWidget extends StatefulWidget {
  const CallPackageWidget({
    required this.config,
    required this.controller,
    required this.child,
    /// Optional: provide a function to resolve a display name from a phone
    /// number using the chat app's own contact list.
    this.contactNameResolver,
    super.key,
  });

  final CallPackageConfig config;
  final CallPackageController controller;
  final Widget child;
  final String? Function(String number)? contactNameResolver;

  @override
  State<CallPackageWidget> createState() => _CallPackageWidgetState();
}

class _CallPackageWidgetState extends State<CallPackageWidget> {
  late final CallBloc _callBloc;

  @override
  void initState() {
    super.initState();
    _callBloc = _buildCallBloc();
    _callBloc.add(const CallStarted());
  }

  @override
  void dispose() {
    _callBloc.close();
    widget.controller.detach();
    super.dispose();
  }

  CallBloc _buildCallBloc() {
    // Reads all required repositories from context (must be provided above
    // this widget by your app's existing provider tree).
    return CallBloc(
      coreUrl:                    widget.config.serverUrl,
      tenantId:                   widget.config.tenantId,
      token:                      widget.config.token,
      trustedCertificates:        context.read<TrustedCertificates>(),
      callLogsRepository:         context.read<CallLogsRepository>(),
      callPullRepository:         context.read<CallPullRepository>(),
      linesStateRepository:       context.read<LinesStateRepository>(),
      presenceInfoRepository:     context.read<PresenceInfoRepository>(),
      presenceSettingsRepository: context.read<PresenceSettingsRepository>(),
      sessionRepository:          context.read<SessionRepository>(),
      userRepository:             context.read<UserRepository>(),
      callkeep:                   context.read<Callkeep>(),
      callkeepConnections:        context.read<CallkeepConnections>(),
      userMediaBuilder:           DefaultUserMediaBuilder(),
      contactNameResolver: widget.contactNameResolver != null
          ? _ChatAppContactNameResolver(widget.contactNameResolver!)
          : context.read<ContactNameResolver>(),
      callErrorReporter:          context.read<CallErrorReporter>(),
      sipPresenceEnabled:         false,
      submitNotification:         (n) => context.read<NotificationsBloc>().add(NotificationSubmitted(n)),
      onDiagnosticReportRequested: (_, __) {},
    );
  }

  @override
  Widget build(BuildContext context) {
    widget.controller.attach(context);

    return BlocProvider<CallBloc>.value(
      value: _callBloc,
      child: CallShell(child: widget.child),  // CallShell adds the overlay/screen logic
    );
  }
}

/// Adapter so the chat app's contact lookup works with CallBloc's interface.
class _ChatAppContactNameResolver implements ContactNameResolver {
  _ChatAppContactNameResolver(this._resolve);
  final String? Function(String number) _resolve;

  @override
  Future<String?> resolveWithNumber(String number) async => _resolve(number);
}
```

### 4.3 Export in `pubspec.yaml` (call project used as a path dependency)

No change needed. The chat app adds it as a path or git dependency:

```yaml
# chat_app/pubspec.yaml
dependencies:
  webtrit_phone:
    path: ../webtrit_phone-main   # or git: url / hosted
```

---

## 5. Chat App – Flutter Integration

### 5.1 One-time setup in `main.dart`

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // Call package needs callkeep initialized (same as webtrit bootstrap)
  await WebtritCallkeep.instance.setup(callkeepConfig);

  runApp(const MyChatApp());
}
```

### 5.2 Place `CallPackageWidget` near the root

```dart
class MyChatApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ChatAuthBloc, ChatAuthState>(
      builder: (context, authState) {
        if (!authState.isLoggedIn) return const LoginScreen();

        return CallPackageWidget(
          config: CallPackageConfig(
            serverUrl:   authState.callServerUrl,
            tenantId:    authState.callTenantId,
            token:       authState.callToken,     // from /integration/token
            userId:      authState.userId,
            phoneNumber: authState.phoneNumber,
          ),
          controller: context.read<CallPackageController>(),

          // Optional: plug in the chat app's own contact list
          contactNameResolver: (number) =>
              context.read<ChatContactsRepository>().findName(number),

          child: const ChatNavigationShell(),
        );
      },
    );
  }
}
```

### 5.3 Trigger a call from anywhere in the chat app

```dart
// e.g. from a chat conversation screen
IconButton(
  icon: const Icon(Icons.call),
  onPressed: () {
    context.read<CallPackageController>().makeCall(
      number:      contact.phoneNumber,
      displayName: contact.fullName,
    );
  },
)
```

### 5.4 Pass FCM token to the call backend

The call backend needs the push token to send call notifications.
Register it after FCM initializes, using the existing
`POST /api/v1/user/notifications/tokens` route (already implemented in the call backend):

```dart
FirebaseMessaging.instance.onTokenRefresh.listen((fcmToken) async {
  final callToken = context.read<ChatAuthBloc>().state.callToken;
  await http.post(
    Uri.parse('$callServerUrl/tenant/$tenantId/api/v1/user/notifications/tokens'),
    headers: {
      'Authorization': 'Bearer $callToken',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({ 'type': 'fcm', 'value': fcmToken }),
  );
});
```

### 5.5 Forward background push notifications to the call package

The chat app's `FirebaseMessaging.onBackgroundMessage` handler must detect
call payloads and delegate them:

```dart
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Detect call push (WebtRit call payloads always contain callId)
  if (message.data.containsKey('callId')) {
    // Delegate to the call package's existing background handler
    await webtritCallBackgroundHandler(message);
    return;
  }

  // Otherwise handle as a normal chat notification
  await handleChatPushNotification(message);
}
```

> `webtritCallBackgroundHandler` is the existing
> `_firebaseMessagingBackgroundHandler` in `lib/bootstrap.dart`.
> Export it from `lib/call_package/webtrit_call_package.dart`.

---

## 6. Permissions Handling

The call package needs: **microphone**, **camera**, **contacts**, **notifications**, **phone** (on Android).

**Rule: request permissions once, in the chat app.**

```dart
// In your chat app's startup sequence
final permissions = await [
  Permission.microphone,
  Permission.camera,
  Permission.contacts,
  Permission.notification,
  if (Platform.isAndroid) Permission.phone,
].request();
```

The call package's `AppPermissions` class reads the *current permission status*
rather than re-requesting. Since both apps share the same process and OS
permission state, no duplication occurs.

---

## 7. Navigation Integration

The call screen appears as a full-screen overlay via `CallShell` (already
implemented). `CallShell` uses Flutter's `Overlay` API — it does not push a
new route, so it works on top of any navigation system (go_router,
auto_route, Navigator 2.0).

When the user accepts a call from the background notification,
`CallShell` lifts the call screen above the chat UI automatically.
When the call ends, it pops back to wherever the user was.

No routing configuration changes are required in the chat app.

---

## 8. Token Refresh Strategy

Call JWTs expire in 24 hours. The chat app should refresh them proactively:

```dart
// In ChatAuthBloc or a token refresh service
Timer.periodic(const Duration(hours: 20), (_) async {
  final newCallToken = await chatApiClient.refreshCallToken();
  // Re-initialize the call package with the new token
  context.read<CallPackageController>().updateToken(newCallToken);
});
```

Add `updateToken(String token)` to `CallPackageController`:

```dart
void updateToken(String token) {
  _context?.read<CallBloc>().add(CallTokenRefreshed(token: token));
}
```

Add a `CallTokenRefreshed` event handler in `CallBloc` that updates the
internal `_signalingClient` credentials and reconnects.

---

## 9. Data Isolation

The call project uses its own SQLite database (`app_database` package) and
its own `SecureStorage` keys. As long as the two apps use different storage
key namespaces there is no conflict.

| Data | Call backend storage key prefix | Chat app prefix |
|------|--------------------------------|-----------------|
| Secure storage | `webtrit_*` | `chat_*` |
| SharedPreferences | `webtrit_*` | `chat_*` |
| SQLite DB | `webtrit_phone.db` | `chat_app.db` |

If you embed the call package into the chat app (same process), make sure
the call package's `SecureStorage` and `SharedPreferences` instances are
initialized with prefixed keys to avoid collision.

---

## 10. Deployment Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Infrastructure                        │
│                                                          │
│  chat-backend  ──── X-Integration-Key ────▶  call-backend│
│  :4000                                       :3000        │
│                                                           │
│  chat-db (PostgreSQL/MongoDB)    call-db (MySQL)          │
│                                                           │
│  Firebase project (shared) ──▶ Both backends can         │
│  (one FCM sender ID)            send pushes via Gorush    │
└─────────────────────────────────────────────────────────┘
```

Both backends can share one Firebase project so push notifications
(both chat and call) arrive via the same FCM sender ID. The Flutter app
distinguishes them by payload: call payloads contain `callId`.

---

## 11. Step-by-Step Integration Checklist

### Call Backend
- [ ] Add `INTEGRATION_API_KEY` to `.env`
- [ ] Add `integrationApiKey` to `config.ts`
- [ ] Create `backend/src/routes/integration/index.ts`
- [ ] Mount integration router in `index.ts`
- [ ] Restart backend, verify `POST /integration/token` works with curl

### Chat Backend
- [ ] Store `INTEGRATION_API_KEY` and `CALL_BACKEND_URL` in env
- [ ] On user login, call `POST /integration/token` and include `callToken` in login response
- [ ] On user logout, call `DELETE /integration/users/:userId`

### Flutter Call Project
- [ ] Create `lib/call_package/` directory with the 3 new files above
- [ ] Export `webtritCallBackgroundHandler` from the package barrel
- [ ] No changes to any existing files

### Flutter Chat App
- [ ] Add `webtrit_phone` as a dependency (path or git)
- [ ] Add `CallPackageWidget` near the root (below auth provider)
- [ ] Create and provide `CallPackageController`
- [ ] Forward FCM token to call backend on token refresh
- [ ] Forward call payloads in background FCM handler
- [ ] Request all permissions (mic, camera, contacts, notifications, phone) at app startup
- [ ] Add call button to chat conversation screen using `controller.makeCall()`

---

## 13. Q&A — Clarifications on Common Doubts

---

### Q1 — Firebase / FCM: Single project or two separate ones?

**Short answer: One shared Firebase project. Two separate setups are not possible for the same Flutter app.**

#### Why two separate setups don't work

A Flutter app is a single Android/iOS process. The OS assigns **one FCM registration token** per app installation, not one per Firebase project. If you tried to initialise two Firebase apps in one Flutter app, they would share the same FCM token but route notifications through different `google-services.json` configs — this creates subtle conflicts (duplicate notification delivery, background handler confusion) and is not supported by the Firebase SDK.

#### The correct model: one Firebase project, two backends send through it

```
┌──────────────────────────────────────────────────┐
│             Single Firebase Project               │
│      (one google-services.json in the app)        │
│                                                    │
│  Chat backend  ──▶  FCM API  ──▶  Flutter app     │
│  Call backend  ──▶  FCM API  ──▶  Flutter app     │
│   (via Gorush)                                    │
└──────────────────────────────────────────────────┘
```

Both backends send to FCM using the **same Firebase service-account JSON**
(or its key). They can both have a copy of the same service-account file —
there is no exclusivity.

The Flutter app distinguishes notification type by payload content:

| Payload field | Source | Handler |
|---------------|--------|---------|
| `callId` present | Call backend | `webtritCallBackgroundHandler()` |
| `callId` absent | Chat backend | `handleChatPushNotification()` |

#### Setup steps

1. Create **one** Firebase project (or reuse the existing `corncall-e7067` project).
2. Place `google-services.json` in the Flutter app once.
3. Give the **same** Firebase service-account JSON file to both Gorush (call backend) and your chat backend's FCM sender.
4. In the background handler, route on payload content (see Section 5.5).

---

### Q2 — GetX compatibility: does the call package work with a GetX chat app?

**Short answer: Yes, with one small consideration around the root widget.**

#### Why it is compatible

The call package only uses:
- `flutter_bloc` / `BlocProvider` — scoped **inside** `CallPackageWidget`, invisible to GetX code outside it
- `provider` — same scoping; GetX controllers are unaware of it
- Flutter's `Overlay` API for the call screen — works regardless of state management framework

GetX does not replace Flutter's widget tree or rendering pipeline. A GetX app is still a standard Flutter app; `GetMaterialApp` is just a thin wrapper around `MaterialApp`. BLoC providers placed anywhere in that tree are fully valid.

#### The one consideration: root widget ordering

GetX requires `GetMaterialApp` (or `GetCupertinoApp`) at the root.
`CallPackageWidget` must be **inside** `GetMaterialApp` but **above** any
GetX page that wants to trigger a call:

```dart
// ✅ Correct order
GetMaterialApp(
  home: CallPackageWidget(       // ← call package inside GetMaterialApp
    config: ...,
    controller: _callController,
    child: ChatHomeController(), // ← GetX pages go here
  ),
)
```

```dart
// ❌ Wrong — CallPackageWidget wrapping GetMaterialApp breaks GetX
CallPackageWidget(
  child: GetMaterialApp(...),    // GetX navigator won't find Overlay
)
```

#### Triggering a call from a GetX controller

`CallPackageController` is a plain Dart object — register it as a GetX service:

```dart
// In your binding
Get.put(CallPackageController(), permanent: true);

// In any GetX controller or widget
Get.find<CallPackageController>().makeCall(
  number: contact.phoneNumber,
  displayName: contact.name,
);
```

#### Navigation: GetX navigator + CallShell overlay

`CallShell` inserts its call screen using `Overlay.of(context)`, which is
provided by `GetMaterialApp` (identical to `MaterialApp`). There is no
conflict with GetX named routes, `Get.to()`, or `Get.off()` — the call
overlay sits above all of them in the widget Z-order.

---

### Q3 — `nameResolver` and `profilePhotoResolver` optional parameters

These two callbacks let the call package display the chat app's contact
names and avatars in the call UI without the call package knowing anything
about the chat app's data layer.

#### Type signatures

```dart
/// Returns the display name for a phone number, or null if unknown.
typedef NameResolver = Future<String?> Function(String phoneNumber);

/// Returns an ImageProvider (network image, memory image, etc.)
/// for a phone number's avatar, or null to show the default avatar.
typedef ProfilePhotoResolver = Future<ImageProvider?> Function(String phoneNumber);
```

#### Add to `CallPackageConfig`

```dart
class CallPackageConfig {
  const CallPackageConfig({
    required this.serverUrl,
    required this.tenantId,
    required this.token,
    required this.userId,
    required this.phoneNumber,
    this.firstName,
    this.lastName,
    // ── optional resolvers ──────────────────────────────────────
    this.nameResolver,
    this.profilePhotoResolver,
  });

  final String serverUrl;
  final String tenantId;
  final String token;
  final String userId;
  final String phoneNumber;
  final String? firstName;
  final String? lastName;

  /// Optional: resolve a contact's display name from their phone number.
  /// Called by the call UI when it needs to show a caller/callee name.
  /// Falls back to the raw phone number if null or resolver returns null.
  final NameResolver? nameResolver;

  /// Optional: resolve a contact's profile photo from their phone number.
  /// Called by the call UI when it needs to show an avatar.
  /// Falls back to a default avatar initial-letter widget if null or resolver returns null.
  final ProfilePhotoResolver? profilePhotoResolver;
}
```

#### How the call package uses them

The resolvers are injected through an adapter that implements the call
package's existing `ContactNameResolver` interface, and a new
`ContactPhotoResolver` interface added to the call package:

```dart
// In call_package_widget.dart — pass to CallBloc
contactNameResolver: _NameResolverAdapter(widget.config.nameResolver),

// Provide photo resolver via InheritedWidget so call UI widgets can access it
_PhotoResolverScope(
  resolver: widget.config.profilePhotoResolver,
  child: BlocProvider<CallBloc>.value(
    value: _callBloc,
    child: CallShell(child: widget.child),
  ),
)
```

Any call UI widget that shows an avatar reads from `_PhotoResolverScope`:

```dart
// Inside a call UI widget (e.g. CallActiveThumbnail, CallScreen)
final photo = await _PhotoResolverScope.of(context)?.call(phoneNumber);
if (photo != null) {
  return CircleAvatar(backgroundImage: photo);
} else {
  return InitialLetterAvatar(name: displayName);
}
```

#### Example usage in the chat app

```dart
CallPackageWidget(
  config: CallPackageConfig(
    serverUrl:   '...',
    tenantId:    '...',
    token:       '...',
    userId:      currentUser.id,
    phoneNumber: currentUser.phone,

    // Resolve name from chat app's local contacts DB
    nameResolver: (phone) async {
      final contact = await chatDb.findContactByPhone(phone);
      return contact?.fullName;
    },

    // Resolve photo — chat app serves avatars from its own CDN
    profilePhotoResolver: (phone) async {
      final contact = await chatDb.findContactByPhone(phone);
      if (contact?.avatarUrl == null) return null;
      return NetworkImage(contact!.avatarUrl!);
    },
  ),
  controller: _callController,
  child: const ChatNavigationShell(),
)
```

Both parameters are optional. If omitted:
- Names fall back to the raw phone number string.
- Avatars fall back to a generated initial-letter avatar.

---

### Q4 — Token refresh with a refresh-token pattern (login once)

Your chat app authenticates once and uses a **refresh token** on subsequent
launches. The call JWT must follow the same lifecycle.

#### The problem

The call JWT issued at login expires after 24 hours. On the next app open
the user is already authenticated via refresh token — you must also get a
fresh call JWT without making the user log in again.

#### Solution: refresh the call JWT alongside the chat token

Whenever your chat app uses its refresh token to get a new chat access
token, make one additional server-to-server call from your **chat backend**
to get a new call JWT, then send it back to the Flutter app as part of the
refresh response.

```
App open (user already logged in)
  │
  ▼
Chat app detects stored refresh token
  │
  ▼
POST chat-backend/auth/refresh  { refreshToken }
  │
  ├─▶ Chat backend validates refresh token
  │
  ├─▶ Chat backend calls  POST call-backend/integration/token
  │       { userId, phoneNumber, firstName, lastName }
  │
  └─▶ Returns to Flutter:
        { chatAccessToken, chatRefreshToken, callToken, expiresIn }
```

#### Chat backend: refresh endpoint

```javascript
app.post('/auth/refresh', async (req, res) => {
  const user = await validateRefreshToken(req.body.refreshToken);

  // Always get a fresh call JWT alongside the chat token refresh
  const callResp = await axios.post(`${CALL_BACKEND_URL}/integration/token`, {
    userId:      user.id,
    phoneNumber: user.phoneNumber,
    firstName:   user.firstName,
    lastName:    user.lastName,
  }, {
    headers: { 'X-Integration-Key': process.env.INTEGRATION_API_KEY },
  });

  res.json({
    chatAccessToken:  generateAccessToken(user),
    chatRefreshToken: rotateRefreshToken(user),   // rotate for security
    callToken:        callResp.data.token,         // ← fresh call JWT
    callExpiresIn:    callResp.data.expiresIn,
  });
});
```

#### Flutter chat app: update call token after refresh

```dart
// In your token-refresh service / GetX controller
Future<void> refreshTokens() async {
  final resp = await chatApi.refresh(storedRefreshToken);

  // Update chat auth state
  Get.find<AuthController>().updateTokens(
    accessToken:  resp.chatAccessToken,
    refreshToken: resp.chatRefreshToken,
  );

  // Hand the new call JWT to the call package — no restart needed
  Get.find<CallPackageController>().updateToken(resp.callToken);
}
```

`updateToken()` on the controller triggers a signaling reconnect with the
new JWT, transparently to the user.

#### Proactive refresh timing

Call JWTs are issued with a 24-hour expiry. Refresh them whenever:

| Trigger | Action |
|---------|--------|
| App foregrounds after >20 h background | Call `refreshTokens()` |
| Chat access token expires (your own TTL) | Call `refreshTokens()` — includes call JWT |
| `CallBloc` emits an auth error event | Call `refreshTokens()` immediately |

This way the call JWT is always refreshed as a side-effect of your existing
chat token refresh logic — no separate timer or call-specific refresh
mechanism is needed.

---

## 12. What Each Project Owns

| Concern | Chat App | Call Package |
|---------|----------|--------------|
| User identity & auth | ✅ | Receives JWT from chat |
| Chat messages | ✅ | — |
| Contact list | ✅ (provides resolver) | Uses resolver callback |
| Permissions request | ✅ (requests once) | Reads OS state |
| FCM registration | ✅ | Receives token via API call |
| Call signaling | — | ✅ |
| WebRTC media | — | ✅ |
| Call UI / screen | — | ✅ (overlay) |
| Call history (CDR) | — | ✅ |
| Push token storage | — | ✅ (call backend DB) |
| Janus media server | — | ✅ |

---

## 14. Q5 — Using `userId` Instead of Phone Number in Resolvers (Group Call Ready)

**Short answer: Yes, and it is the better design — especially for group calls.**

---

### Why phone number alone is insufficient

The `nameResolver` and `profilePhotoResolver` in Q3 were defined to receive a
`phoneNumber` string. This works for 1-to-1 calls today, but has three problems
that will block group calls later:

| Problem | Impact |
|---------|--------|
| Phone numbers are not unique in your chat system | Two users could share a number (shared lines, virtual numbers) |
| Group call participants are identified by userId in your chat DB, not by phone | You would have to reverse-look up userId → phoneNumber → name, adding an unnecessary round-trip |
| Resolving avatars by phone number forces the chat app to maintain a phone → user mapping that it may not have | Extra complexity for no gain |

---

### The recommended model: `CallContact`

Replace the two separate phone-number-based resolver types with a single
`CallContact` value object that carries **both** identifiers. The resolvers
receive `CallContact` and can use whichever field they prefer — typically
`userId` for their own data, `phoneNumber` as a fallback label.

#### `CallContact` model (new file in call package)

```dart
// lib/call_package/src/call_contact.dart

/// Identifies a participant in a call.
/// Both fields are provided so resolvers can choose the best key.
class CallContact {
  const CallContact({
    required this.userId,      // chat app's user UUID — primary key
    required this.phoneNumber, // E.164 phone number — fallback / display
  });

  /// The chat app's own user identifier (UUID or any opaque string).
  /// Use this as the primary key when querying the chat app's database.
  final String userId;

  /// The E.164 phone number used for routing the call.
  /// Use as a display label when userId lookup returns nothing.
  final String phoneNumber;

  @override
  String toString() => 'CallContact(userId: $userId, phone: $phoneNumber)';
}
```

#### Updated resolver typedefs

```dart
// lib/call_package/src/call_package_config.dart

/// Resolve a display name for a call participant.
/// Receives both userId and phoneNumber — use userId as the primary key.
/// Return null to fall back to the raw phone number string.
typedef NameResolver =
    Future<String?> Function(CallContact contact);

/// Resolve a profile photo for a call participant.
/// Receives both userId and phoneNumber — use userId as the primary key.
/// Return null to show the default initial-letter avatar.
typedef ProfilePhotoResolver =
    Future<ImageProvider?> Function(CallContact contact);
```

#### Updated `CallPackageConfig`

```dart
class CallPackageConfig {
  const CallPackageConfig({
    required this.serverUrl,
    required this.tenantId,
    required this.token,
    required this.userId,
    required this.phoneNumber,
    this.firstName,
    this.lastName,
    this.nameResolver,           // now receives CallContact
    this.profilePhotoResolver,   // now receives CallContact
  });

  // ... same fields as before ...
  final NameResolver? nameResolver;
  final ProfilePhotoResolver? profilePhotoResolver;
}
```

---

### What the call package must expose to make userId available

Currently the signaling events (`incoming_call`, `accepted`) only carry
phone numbers (`caller`, `callee`). The call package needs to also carry the
`userId` of each participant so it can build `CallContact` objects.

#### Backend change — include `userId` in signaling events

In `backend/src/janus/videocall.ts`, add `caller_user_id` and
`callee_user_id` to the `incoming_call` event:

```typescript
// videocall.ts — incomingcall handler
sendEvent(calleeConn.ws, 'incoming_call', {
  line:                0,
  call_id:             callId,
  caller:              info.callerNumber  || info.callerUserId,
  caller_user_id:      info.callerUserId,   // ← add this
  callee:              info.calleeNumber  || info.calleeUserId,
  callee_user_id:      info.calleeUserId,   // ← add this
  caller_display_name: info.callerName    || info.callerNumber,
  referred_by:         null,
  replace_call_id:     null,
  is_focus:            false,
  jsep:                jsep ?? null,
});
```

Also in `server.ts` (state handshake lines entry):

```typescript
lines[0] = {
  call_id:   info.callId,
  call_logs: [[
    Date.now(),
    {
      event:               'incoming_call',
      caller:              info.callerNumber,
      caller_user_id:      info.callerUserId,   // ← add
      callee:              info.calleeNumber,
      callee_user_id:      info.calleeUserId,   // ← add
      caller_display_name: info.callerName || info.callerNumber,
      referred_by:         null,
      replace_call_id:     null,
      is_focus:            false,
      jsep:                info.callerJsep ?? null,
    },
  ]],
};
```

#### Flutter call package — build `CallContact` from the event

When the call package parses an `incoming_call` event it now has both fields
and can construct a `CallContact` to pass to the resolvers:

```dart
// Inside the call bloc / signaling event handler
final contact = CallContact(
  userId:      event.callerUserId ?? event.callerPhoneNumber,
  phoneNumber: event.callerPhoneNumber,
);

final name  = await config.nameResolver?.call(contact) ?? contact.phoneNumber;
final photo = await config.profilePhotoResolver?.call(contact);
```

---

### Chat app resolver implementation using userId

```dart
CallPackageWidget(
  config: CallPackageConfig(
    // ... auth fields ...

    nameResolver: (CallContact contact) async {
      // Primary: look up by chat userId (fast, accurate)
      final user = await chatDb.findUserById(contact.userId);
      if (user != null) return user.fullName;

      // Fallback: search by phone number
      final byPhone = await chatDb.findUserByPhone(contact.phoneNumber);
      return byPhone?.fullName;
    },

    profilePhotoResolver: (CallContact contact) async {
      final user = await chatDb.findUserById(contact.userId);
      if (user?.avatarUrl == null) return null;
      return NetworkImage(user!.avatarUrl!);
    },
  ),
  controller: _callController,
  child: const ChatNavigationShell(),
)
```

---

### Group call extensibility

When you extend to group calls, each participant is a `CallContact`. The call
package will hold a list of active participants and resolve names/photos for
all of them using the same callbacks — no API change needed on the chat app
side.

```
Group call participants (future):

  [ CallContact(userId: 'u1', phone: '+1555...'),
    CallContact(userId: 'u2', phone: '+1444...'),
    CallContact(userId: 'u3', phone: '+1333...') ]

  ↓ nameResolver called once per participant
  ↓ profilePhotoResolver called once per participant

  Displayed in group call UI grid / participant strip
```

Because userId is the primary key, the chat app can resolve names and photos
from its own user table with a single `SELECT ... WHERE id IN (u1, u2, u3)`
query — far more efficient than three separate phone-number lookups.

---

### Summary of changes required

| Layer | Change | When |
|-------|--------|------|
| **Call backend** | Add `caller_user_id` / `callee_user_id` to `incoming_call` signaling event | Now |
| **Call backend** | Add same fields to state handshake `lines` entry | Now |
| **Call package Flutter** | Add `CallContact` model | Now |
| **Call package Flutter** | Change resolver typedefs to accept `CallContact` | Now |
| **Call package Flutter** | Build `CallContact` from parsed signaling event | Now |
| **Chat app** | Update resolver lambdas to use `contact.userId` | Now |
| **Group call** | Resolvers already accept `CallContact` — no further API change | Future |
