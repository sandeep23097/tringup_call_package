# TringupCall — Usage Guide

A drop-in Flutter package that adds full WebRTC audio/video calling (including optional group
calls via Janus AudioBridge) to any existing Flutter chat application.
Works with **any router** (GetX, go_router, Navigator 1/2) — no auto_route required.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Package Deployment Options](#2-package-deployment-options)
   - [A. Same Repository (monorepo / path dependency)](#a-same-repository-monorepo--path-dependency)
   - [B. Separate Git Repository (hosted on GitHub)](#b-separate-git-repository-hosted-on-github)
3. [Integration in a GetX Chat Project](#3-integration-in-a-getx-chat-project)
   - [Step 1 — Add the dependency](#step-1--add-the-dependency)
   - [Step 2 — Android setup](#step-2--android-setup)
   - [Step 3 — iOS setup](#step-3--ios-setup)
   - [Step 4 — Wrap your app root](#step-4--wrap-your-app-root)
   - [Step 5 — Register the controller with GetX](#step-5--register-the-controller-with-getx)
   - [Step 6 — Make a call from anywhere](#step-6--make-a-call-from-anywhere)
   - [Step 7 — Background / FCM calls (optional)](#step-7--background--fcm-calls-optional)
   - [Step 8 — Token lifecycle](#step-8--token-lifecycle)
4. [Backend Integration API](#4-backend-integration-api)
5. [Public API Reference](#5-public-api-reference)
   - [TringupCallConfig](#tringupCallconfig)
   - [TringupCallContact](#tringupCallcontact)
   - [TringupCallController](#tringupCallcontroller)
   - [TringupCallWidget](#tringupCallwidget)
   - [TringupCallBackgroundHandler](#tringupCallbackgroundhandler)
6. [Internal Widgets (read-only reference)](#6-internal-widgets-read-only-reference)
7. [Group Call Feature](#7-group-call-feature)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Your Chat App                                                  │
│                                                                 │
│  GetMaterialApp / MaterialApp                                   │
│   └─ TringupCallWidget  ◄── wraps your entire widget tree      │
│       ├─ Creates CallBloc (owns signaling, WebRTC, callkeep)    │
│       ├─ TringupCallShell  ◄── Overlay-based call UI           │
│       │   ├─ Full-screen CallActiveScaffold  (during call)     │
│       │   ├─ Draggable thumbnail             (minimised)       │
│       │   └─ Nothing                         (idle)            │
│       └─ your child widget (chat screens, routes, etc.)        │
└─────────────────────────────────────────────────────────────────┘
```

**Key design decisions:**
- The call UI is injected as a Flutter `Overlay` — it does **not** push a route, so it works with
  any navigation library.
- `TringupCallController` is a plain Dart object you can store in a GetX controller, Provider,
  or any DI system.
- The package holds its own `CallBloc` internally; you never need to touch flutter_bloc directly.

---

## 2. Package Deployment Options

### A. Same Repository (monorepo / path dependency)

This is the recommended approach while the package is under active development together with your
chat app.

**Folder layout:**

```
your_workspace/
  chat_app/          ← your existing GetX Flutter project
    pubspec.yaml
    lib/
    ...
  tringup_call/      ← this package
    pubspec.yaml
    lib/
    ...
  webtrit_phone-main/   ← call engine (must stay alongside)
    pubspec.yaml
    lib/
    ...
```

**`chat_app/pubspec.yaml`:**

```yaml
dependencies:
  flutter:
    sdk: flutter
  get: ^4.6.6          # your existing GetX dep
  # ... other deps ...

  tringup_call:
    path: ../tringup_call   # relative path to the package folder
```

Run:

```bash
cd chat_app
flutter pub get
```

> **Important:** `webtrit_phone-main` must exist at `../webtrit_phone-main` relative to
> `tringup_call/` (or adjust `tringup_call/pubspec.yaml` paths accordingly).

---

### B. Separate Git Repository (hosted on GitHub)

Once the package is stable, host it on GitHub so any project can consume it without a local copy.

#### Step 1 — Create a GitHub repository

```bash
cd tringup_call
git init
git add .
git commit -m "Initial release of tringup_call package"

# Create the repo on GitHub (via UI or gh CLI):
gh repo create your-org/tringup_call --public --source=. --push
```

#### Step 2 — Tag a version

```bash
git tag v1.0.0
git push origin v1.0.0
```

#### Step 3 — Consume from GitHub in your chat app

```yaml
# chat_app/pubspec.yaml
dependencies:
  tringup_call:
    git:
      url: https://github.com/your-org/tringup_call.git
      ref: v1.0.0          # tag, branch, or SHA
```

> **Note:** When hosting on GitHub, `webtrit_phone-main` must be committed into the **same
> repository** (or its own GitHub repo), and `tringup_call/pubspec.yaml` updated to use the
> corresponding git/path dependency. The simplest approach is to include `webtrit_phone-main` as
> a git submodule:
>
> ```bash
> git submodule add https://github.com/your-org/webtrit_phone.git webtrit_phone-main
> ```
>
> Then update `tringup_call/pubspec.yaml`:
>
> ```yaml
> webtrit_phone:
>   path: ./webtrit_phone-main   # submodule path
> ```

#### Step 4 — Update to a newer version

```yaml
# Bump ref to the new tag or commit SHA
ref: v1.1.0
```

Then run `flutter pub upgrade tringup_call`.

---

## 3. Integration in a GetX Chat Project

### Step 1 — Add the dependency

```yaml
# chat_app/pubspec.yaml
dependencies:
  tringup_call:
    path: ../tringup_call   # or git URL — see Section 2
```

```bash
flutter pub get
```

---

### Step 2 — Android setup

**`android/app/src/main/AndroidManifest.xml`** — add inside `<manifest>`:

```xml
<!-- Core permissions for calling -->
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>
<uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
<uses-permission android:name="android.permission.VIBRATE"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
```

**`android/app/build.gradle`** — ensure `minSdkVersion` is at least 26:

```groovy
android {
    defaultConfig {
        minSdkVersion 26
    }
}
```

---

### Step 3 — iOS setup

**`ios/Runner/Info.plist`** — add:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Microphone is needed for calls.</string>
<key>NSCameraUsageDescription</key>
<string>Camera is needed for video calls.</string>
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>voip</string>
    <string>fetch</string>
    <string>remote-notification</string>
</array>
```

---

### Step 4 — Wrap your app root

In `lib/main.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:tringup_call/tringup_call.dart';

import 'app/routes/app_pages.dart';
import 'app/bindings/initial_binding.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Optional: enable background call UI from FCM terminated-state.
  await TringupCallBackgroundHandler.initialize();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Retrieve credentials from your auth layer (GetX controller, shared prefs, etc.)
    final auth = Get.find<AuthController>();

    return TringupCallWidget(
      config: TringupCallConfig(
        serverUrl:   auth.callServerUrl,   // e.g. 'https://call.example.com'
        tenantId:    auth.tenantId,        // e.g. 'f1rIih5iS3yACprjOBbF-0'
        token:       auth.callToken,       // JWT from POST /integration/token
        userId:      auth.userId,
        phoneNumber: auth.phoneNumber,     // E.164, e.g. '+14155550100'
        firstName:   auth.firstName,       // optional, for display
        lastName:    auth.lastName,        // optional
        groupCallEnabled: true,            // set false to hide "Add participant"
        nameResolver: (TringupCallContact contact) async {
          // Return a display name for the remote party, or null to use number.
          return Get.find<ContactsController>().nameFor(contact.userId);
        },
      ),
      controller: Get.find<CallController>().tringupController,
      child: GetMaterialApp(
        initialBinding: InitialBinding(),
        getPages: AppPages.routes,
        // ... your existing GetMaterialApp config ...
      ),
    );
  }
}
```

---

### Step 5 — Register the controller with GetX

Create a GetX controller to own the `TringupCallController`:

```dart
// lib/app/controllers/call_controller.dart
import 'package:get/get.dart';
import 'package:tringup_call/tringup_call.dart';

class CallController extends GetxController {
  final tringupController = TringupCallController();

  /// Make an outgoing audio call.
  void callUser({required String phoneNumber, String? displayName}) {
    tringupController.makeCall(
      number:      phoneNumber,
      displayName: displayName,
    );
  }

  /// Make an outgoing video call.
  void videoCallUser({required String phoneNumber, String? displayName}) {
    tringupController.makeCall(
      number:      phoneNumber,
      displayName: displayName,
      video:       true,
    );
  }

  /// Call after token refresh to keep signaling alive.
  void refreshToken(String newToken) {
    tringupController.updateToken(newToken);
  }
}
```

Register in your initial binding:

```dart
// lib/app/bindings/initial_binding.dart
import 'package:get/get.dart';
import 'call_controller.dart';

class InitialBinding extends Bindings {
  @override
  void dependencies() {
    Get.put(CallController(), permanent: true);
    // ... other bindings ...
  }
}
```

---

### Step 6 — Make a call from anywhere

From any widget or GetX controller in your app:

```dart
// Audio call
Get.find<CallController>().callUser(
  phoneNumber: '+14155550100',
  displayName: 'Alice',
);

// Video call
Get.find<CallController>().videoCallUser(
  phoneNumber: '+14155550100',
  displayName: 'Alice',
);
```

The call screen slides in automatically as a full-screen overlay — no `Get.to()` or route push
needed.

---

### Step 7 — Background / FCM calls (optional)

To show the native incoming-call UI (CallKit on iOS, ConnectionService on Android) when the app
is in background or terminated, register the FCM background handler:

```dart
// lib/main.dart
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:tringup_call/tringup_call.dart';

// Must be a top-level function (not inside a class).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await TringupCallBackgroundHandler.initialize();
  // The handler hooks into callkeep automatically; no further code needed here.
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  await TringupCallBackgroundHandler.initialize();
  runApp(const MyApp());
}
```

---

### Step 8 — Token lifecycle

Call tokens expire (default 24 h). When your auth layer refreshes the JWT, tell the package:

```dart
// Inside your auth refresh logic:
final newCallToken = await fetchNewCallToken(userId: currentUser.id);
Get.find<CallController>().refreshToken(newCallToken);
```

For a full token refresh, you can also rebuild `TringupCallWidget` with a new `config` by
changing `config.token` in your state — `didUpdateWidget` will detect the change and
reconnect signaling automatically.

---

## 4. Backend Integration API

Your chat backend must call the call backend to issue a token for each user. All endpoints
require the `x-integration-key` header (set `INTEGRATION_API_KEY` env var on the call server).

### Issue a call token

```
POST /integration/token
x-integration-key: <your-integration-api-key>
Content-Type: application/json

{
  "userId":      "chat-user-uuid-or-id",
  "phoneNumber": "+14155550100",
  "firstName":   "Alice",        // optional
  "lastName":    "Smith"         // optional
}
```

Response:
```json
{
  "token":     "eyJhbGciOiJIUzI1NiIsInR...",
  "expiresIn": 86400
}
```

Pass `token` as `TringupCallConfig.token`. Refresh 5–10 minutes before `expiresIn` seconds elapse.

### Deactivate a user

```
DELETE /integration/users/:userId
x-integration-key: <key>
```

### Check online status

```
GET /integration/users/:userId/status
x-integration-key: <key>
```

Response: `{ "online": true }` — `true` if the user has an active WebSocket signaling connection.

---

## 5. Public API Reference

### TringupCallConfig

Configuration object passed to `TringupCallWidget`.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `serverUrl` | `String` | ✅ | Base URL of the call backend, e.g. `https://call.example.com` |
| `tenantId` | `String` | ✅ | Tenant identifier from your WebTrit deployment |
| `token` | `String` | ✅ | Call JWT obtained from `POST /integration/token` |
| `userId` | `String` | ✅ | Chat app user ID (must match the userId used to issue the token) |
| `phoneNumber` | `String` | ✅ | User's E.164 phone number used for call routing |
| `firstName` | `String?` | ❌ | User's first name (shown in call UI) |
| `lastName` | `String?` | ❌ | User's last name (shown in call UI) |
| `nameResolver` | `TringupNameResolver?` | ❌ | Async callback to resolve display names for remote participants |
| `photoResolver` | `TringupPhotoResolver?` | ❌ | Async callback to resolve profile photos for remote participants |
| `groupCallEnabled` | `bool` | ❌ | Enable group-call "Add participant" button. Default: `false` |

**Resolver typedefs:**

```dart
typedef TringupNameResolver  = Future<String?>        Function(TringupCallContact contact);
typedef TringupPhotoResolver = Future<ImageProvider?> Function(TringupCallContact contact);
```

---

### TringupCallContact

Read-only data class passed to resolver callbacks.

```dart
class TringupCallContact {
  final String userId;      // Chat app user ID
  final String phoneNumber; // E.164 number used for call routing
}
```

---

### TringupCallController

Imperative API to trigger calls and update credentials programmatically.

| Method / Property | Signature | Description |
|-------------------|-----------|-------------|
| `makeCall` | `void makeCall({required String number, String? displayName, bool video = false})` | Start an outgoing call to `number`. Must be attached to a `TringupCallWidget`. |
| `updateToken` | `void updateToken(String newToken)` | Refresh the call JWT and reconnect signaling. |
| `attach` | `void attach(BuildContext context)` | **Internal** — called automatically by `TringupCallWidget`. |
| `detach` | `void detach()` | **Internal** — called automatically on widget dispose. |
| `isAttached` | `bool` (getter) | `true` if the controller is connected to a live widget. |

**Usage with GetX:**

```dart
final ctrl = Get.find<CallController>();

// Check before calling
if (ctrl.tringupController.isAttached) {
  ctrl.callUser(phoneNumber: '+14155550101');
}
```

---

### TringupCallWidget

Root widget that bootstraps the entire call stack.

```dart
TringupCallWidget({
  required TringupCallConfig  config,
  required Widget             child,
  TringupCallController?      controller,
})
```

| Parameter | Description |
|-----------|-------------|
| `config` | All call credentials and feature flags. |
| `child` | Your existing app widget tree (typically `GetMaterialApp`). |
| `controller` | Optional controller for imperative `makeCall` API. |

**Behaviour:**
- Creates `CallBloc` with all required repositories on mount.
- Provides `CallBloc` to descendants via `BlocProvider` (useful for advanced access).
- Listens to call state changes and inserts/removes overlay entries automatically.
- When `config.token` changes across widget rebuilds, reconnects signaling transparently.

---

### TringupCallBackgroundHandler

Static utility for handling incoming calls when the app is in background or terminated.

| Method | Signature | Description |
|--------|-----------|-------------|
| `initialize` | `static Future<void> initialize({SecureStorage? secureStorage})` | Set up FCM background call handling. Call once from `main()` before `runApp`. |
| `dispose` | `static Future<void> dispose()` | Tear down the background handler (e.g. on logout). |

---

## 6. Internal Widgets (read-only reference)

These widgets are rendered automatically by `TringupCallShell` and `TringupCallWidget`. You do
**not** instantiate them directly, but they are useful to understand for theming and debugging.

| Widget | Rendered when | Description |
|--------|--------------|-------------|
| `CallActiveScaffold` | Active/accepted call | Full-screen call controls: mute, hold, DTMF keypad, video toggle, transfer, add-participant, hang up. |
| `CallInitScaffold` | Outgoing call ringing (pre-accept) | Spinner / "Calling…" screen while waiting for the remote party. |
| `CallActiveThumbnail` | Minimised (overlay mode) | Small draggable card showing caller name and duration. Tap to expand. |
| `CallInfo` | Inside `CallActiveScaffold` | Displays caller display name, number, and call duration timer. |
| `CallActions` | Inside `CallActiveScaffold` | Grid of action buttons (mute, hold, keypad, video, transfer, add participant, hang up). |

### Theming

The call UI respects your app's `ThemeData`. For fine-grained control, inject a
`CallScreenStyles` extension into your theme:

```dart
ThemeData(
  extensions: [
    CallScreenStyles(
      primary: CallScreenStyle(
        appBar: CallScreenAppBarStyle(
          backgroundColor: Colors.black87,
          foregroundColor: Colors.white,
          showBackButton: false,
        ),
        callInfo: CallInfoStyle(...),
        actions: CallActionsStyle(...),
      ),
    ),
  ],
)
```

---

## 7. Group Call Feature

Enable by passing `groupCallEnabled: true` in `TringupCallConfig`.

**What happens:**
1. During an active call, an **"Add participant"** button appears in the action grid.
2. Tapping it opens a dialog to enter a phone number or extension.
3. The call backend creates a Janus AudioBridge room and notifies all parties to upgrade their
   peer connections from direct WebRTC to AudioBridge-mixed audio.
4. Additional participants receive a conference invite and can accept or decline.

**Requirements:**
- Call backend must be running with `GROUP_CALL_ENABLED=true` and Janus server configured.
- Janus WebSocket URL must be set via `JANUS_URL` env var on the call server.

---

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `TringupCallController.makeCall` crashes with assertion | Controller not yet attached | Call `makeCall` inside a widget build scope, not in `GetxController.onInit` |
| Call screen never appears | `TringupCallWidget` not at root | Ensure it wraps the widget that contains `Overlay` (i.e., above `GetMaterialApp`) |
| "Add participant" button not visible | `groupCallEnabled: false` | Set `groupCallEnabled: true` in `TringupCallConfig` |
| Signaling disconnects after a while | Token expired | Implement token refresh and call `TringupCallController.updateToken` |
| No incoming call on terminated app | Background handler not registered | Call `TringupCallBackgroundHandler.initialize()` at the top of `main()` and register the FCM `onBackgroundMessage` handler |
| `flutter pub get` fails with version conflicts | `webtrit_phone` path not found | Verify that `webtrit_phone-main/` is at the path specified in `tringup_call/pubspec.yaml` |
| iOS CallKit not showing | Missing Info.plist entries | Add `voip` to `UIBackgroundModes` and microphone/camera usage descriptions |
