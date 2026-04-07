# TringupCall Package — Developer Context

> **Purpose of this document:** Complete technical context for making changes, fixing bugs, or
> extending the `tringup_call` package directly from the host chat repository without needing to
> re-read all source files first.

---

## 1. Repository Layout

```
your_workspace/
  chat_app/                         ← host chat app (GetX / go_router / etc.)
  tringup_call/                     ← THIS package
  webtrit_phone-main/               ← call engine (must NOT be moved)
    lib/
      features/call/                ← BLoC, views, widgets, models
      repositories/                 ← repo abstractions + impls
      models/                       ← shared data models
      packages/
        webtrit_signaling/          ← WebSocket signaling events
        webtrit_api/                ← REST API client
        ssl_certificates/           ← TrustedCertificates class
    backend/                        ← Node.js signaling server
      src/
        config.ts                   ← env var configuration
        index.ts                    ← Express app entry point
        signaling/
          server.ts                 ← WebSocket message routing
          handlers/
            call.ts                 ← 1:1 call signaling
            call-state.ts           ← in-memory active call map
            conference.ts           ← group call signaling
            conference-state.ts     ← in-memory conference map
        janus/
          client.ts                 ← raw Janus WebSocket client
          audiobridge.ts            ← AudioBridge plugin helpers
        routes/
          integration/index.ts      ← server-to-server REST API
```

---

## 2. Package File Map

```
tringup_call/
  pubspec.yaml
  lib/
    tringup_call.dart               ← barrel: exports all public types
    src/
      tringup_call_config.dart      ← TringupCallConfig + resolver typedefs
      tringup_call_contact.dart     ← TringupCallContact (data class)
      tringup_call_controller.dart  ← TringupCallController (imperative API)
      tringup_call_widget.dart      ← TringupCallWidget (root widget)
      tringup_call_shell.dart       ← TringupCallShell (Overlay-based call UI)
      tringup_call_background_handler.dart ← FCM background handler
      stubs/
        stub_session_repository.dart
        stub_call_logs_repository.dart
        stub_presence_info_repository.dart
        stub_presence_settings_repository.dart
```

---

## 3. Dependency Graph

```
tringup_call
  ├── flutter_bloc ^9.0.0              (BlocProvider, BlocListener)
  ├── webtrit_phone (path: ../webtrit_phone-main)
  │     ├── features/call/call.dart    (CallBloc, CallState, CallControlEvent,
  │     │                               CallScreenEvent, CallConfig, ActiveCall, ...)
  │     ├── repositories/repositories.dart
  │     │     ├── CallLogsRepository
  │     │     ├── CallPullRepositoryMemoryImpl
  │     │     ├── LinesStateRepositoryInMemoryImpl
  │     │     ├── PresenceInfoRepository
  │     │     ├── PresenceSettingsRepository
  │     │     ├── SessionRepository
  │     │     └── UserRepository
  │     ├── features/call/view/call_active_scaffold.dart  (not re-exported)
  │     ├── features/call/view/call_active_thumbnail.dart (not re-exported)
  │     └── features/call/view/call_init_scaffold.dart    (not re-exported)
  ├── webtrit_api (path: ../webtrit_phone-main/packages/webtrit_api)
  │     └── WebtritApiClient
  ├── webtrit_callkeep (git: release/0.4.1)
  │     └── Callkeep, CallkeepConnections, BackgroundPushNotificationService
  └── ssl_certificates (path: ../webtrit_phone-main/packages/ssl_certificates)
        └── TrustedCertificates, TrustedCertificates.empty, SecureStorageImpl
```

> **Critical paths:** `CallActiveScaffold`, `CallActiveThumbnail`, and `CallInitScaffold` are
> NOT exported from `webtrit_phone/features/call/call.dart`. They must be imported by full file
> path. `CallScreen` is exported but must NOT be used in this package — it uses
> `AutoRouteAwareStateMixin` which throws when no auto_route router is present in the widget tree.

---

## 4. Object Lifecycle

```
main()
  └─ TringupCallBackgroundHandler.initialize()       [optional, for FCM]

runApp()
  └─ TringupCallWidget.initState()
       ├─ Callkeep.setUp(...)
       ├─ CallkeepConnections()
       └─ _buildCallBloc(config)
            ├─ WebtritApiClient(serverUrl, tenantId)
            ├─ Creates all repos (real + stubs)
            └─ CallBloc(..., groupCallEnabled, ...)
                 └─ .add(CallStarted())           ← connects WebSocket signaling

  └─ BlocProvider<CallBloc>.value(callBloc)
       └─ Builder
            ├─ controller?.attach(context)        ← wires TringupCallController
            └─ TringupCallShell(child: yourApp)
                 └─ MultiBlocListener
                      ├─ _callDisplayListener     ← watches CallState.display
                      └─ _lockscreenListener      ← Android lock-screen control
```

**On `CallState.display` change:**

| `CallDisplay` value | Action taken by `TringupCallShell` |
|---------------------|------------------------------------|
| `screen` | Insert `OverlayEntry` with full-screen `_TringupCallScreenPage` |
| `overlay` | Remove call screen; insert draggable `_ThumbnailOverlay` |
| `none` / `noneScreen` | Remove both overlays |

**On `TringupCallWidget.dispose()`:**
1. `controller?.detach()` — clears `_context` on the controller
2. `_callBloc.close()` — closes WebSocket, disposes all streams
3. `_callkeep.tearDown()` — releases native telephony bindings

---

## 5. Key Classes in Detail

### 5.1 `TringupCallConfig` (`tringup_call_config.dart`)

All fields are **read-only** after construction. When `token` changes in a rebuild,
`_TringupCallWidgetState.didUpdateWidget` sends `CallStarted()` to reconnect signaling.

```
serverUrl       → CallBloc.coreUrl + WebtritApiClient base URL
tenantId        → CallBloc.tenantId + WebtritApiClient tenant
token           → CallBloc.token + UserRepository token
userId          → informational (passed to integration token endpoint by chat backend)
phoneNumber     → informational (passed to integration token endpoint by chat backend)
firstName/lastName → informational
nameResolver    → wrapped by _TringupContactNameResolver → ContactNameResolver
photoResolver   → not wired yet (placeholder for future avatar support)
groupCallEnabled → CallBloc.groupCallEnabled → shows "Add participant" button
```

### 5.2 `TringupCallController` (`tringup_call_controller.dart`)

Stores a `BuildContext` reference set by `TringupCallWidget` during `build()`. Reading
`context.read<CallBloc>()` sends events imperatively.

```dart
makeCall(number, displayName, video)
  → callBloc.add(CallControlEvent.started(number, displayName, video))

updateToken(newToken)
  → callBloc.add(CallStarted())    // reconnects with new token from config
```

> **Gotcha:** `_context` is `null` until `TringupCallWidget` builds at least once. Never call
> `makeCall` in `GetxController.onInit()`. Use it inside a UI callback or after
> `WidgetsBinding.instance.addPostFrameCallback`.

### 5.3 `TringupCallShell` (`tringup_call_shell.dart`)

The shell does **not** push routes. It uses `Overlay.of(context).insert(entry)` directly.

**Full-screen overlay (`_callScreenEntry`):**
- Wraps `_TringupCallScreenPage` in `BlocProvider<CallBloc>.value` + `PresenceViewParams`
- `_TringupCallScreenPage.initState` fires `CallScreenEvent.didPush()` in a post-frame callback
- `_TringupCallScreenPage.dispose` fires `CallScreenEvent.didPop()`
- Build tree: `PopScope → AnnotatedRegion → Material → BlocConsumer`
  - `listener`: handles `activeCall.failure` → shows `AcknowledgeDialog`
  - `builder`: `state.isActive` → `CallActiveScaffold`, else → `CallInitScaffold`

**Thumbnail overlay (`_ThumbnailOverlay`):**
- Draggable with sticky-to-edge snap behaviour
- Shows `CallActiveThumbnail(activeCall: state.activeCalls.current)`
- Tapping triggers `callBloc.add(CallScreenEvent.didPush())`

### 5.4 Stub Repositories (`stubs/`)

| Stub | Base type | Why needed | What it returns |
|------|-----------|------------|-----------------|
| `StubCallLogsRepository` | `extends CallLogsRepository` | Concrete class backed by drift/SQLite — we override all 3 methods so `AppDatabase` is never touched. Constructor: `super(appDatabase: null as dynamic)` | Empty stream / no-ops |
| `StubSessionRepository` | `implements SessionRepository` | Abstract interface — package is always "signed in" via JWT | `isSignedIn = true`, empty stream, no-op save/logout |
| `StubPresenceInfoRepository` | `implements PresenceInfoRepository` | `sipPresenceEnabled = false` so presence is never queried | Empty lists / no-ops |
| `StubPresenceSettingsRepository` | `implements PresenceSettingsRepository` | Same as above | `PresenceSettings.blank(device: 'tringup_call')` |

> **Adding a new stub method:** If `webtrit_phone` adds a new abstract method to one of these
> interfaces, `flutter analyze` will report a "missing concrete implementation" error. Add a
> no-op or sensible default to the appropriate stub file.

### 5.5 Private helpers in `tringup_call_widget.dart`

| Class | Purpose |
|-------|---------|
| `_TringupContactNameResolver` | Bridges `TringupCallConfig.nameResolver` (takes `TringupCallContact`) to `ContactNameResolver` (takes `String? number`). `userId` is set to `''` because only the phone number is available at call time. |
| `_SilentCallErrorReporter` | Implements `CallErrorReporter.handle(error, stack, context)` as a no-op. Prevents unhandled errors from crashing the host app. Replace with a real reporter if needed. |

---

## 6. CallBloc Internal State (read-only reference)

The `CallBloc` lives in `webtrit_phone-main/lib/features/call/bloc/call_bloc.dart`.
The package does not modify it — it only instantiates and sends events to it.

### `CallState` fields used by the shell

| Field | Type | Description |
|-------|------|-------------|
| `display` | `CallDisplay` | `screen`, `overlay`, `noneScreen`, `none` — drives overlay visibility |
| `isActive` | `bool` | `true` when `activeCalls.isNotEmpty` |
| `activeCalls` | `List<ActiveCall>` | Live calls; `.current` = un-held call; `.nonCurrent` = held calls |
| `status` | `CallStatus` | `ready`, `inProgress`, `connectError`, etc. — used to disable actions |
| `audioDevice` | `CallAudioDevice?` | Active audio device |
| `availableAudioDevices` | `List<CallAudioDevice>` | All available devices |
| `minimized` | `bool?` | `true` = show thumbnail; drives `display` computation |

### `ActiveCall` fields used by the UI

| Field | Type | Description |
|-------|------|-------------|
| `callId` | `String` | Unique call identifier |
| `handle` | `CallkeepHandle` | `.value` = phone number string |
| `displayName` | `String?` | Resolved display name |
| `direction` | `CallDirection` | `incoming` / `outgoing` |
| `isIncoming` | `bool` | Shorthand for `direction == incoming` |
| `wasAccepted` | `bool` | `acceptedTime != null` |
| `wasHungUp` | `bool` | `hungUpTime != null` |
| `held` | `bool` | Whether the call is on hold |
| `muted` | `bool` | Whether mic is muted |
| `cameraEnabled` | `bool` | Whether outgoing video track is enabled |
| `remoteVideo` | `bool` | Remote stream has video tracks |
| `localVideo` | `bool` | Local stream has video tracks |
| `frontCamera` | `bool?` | `null` = switching, `true` = front, `false` = rear |
| `transfer` | `Transfer?` | Current transfer state object |
| `processingStatus` | `CallProcessingStatus` | Loading/error state for async operations |
| `failure` | `...?` | Non-null when call encountered an error |

### Group-call state (`_conferenceState` — private to `CallBloc`)

```
Map<callId, _ConferenceCallState>
  _ConferenceCallState:
    roomId              : int            — Janus AudioBridge room number
    pendingPeerConnection : RTCPeerConnection?
    participants        : List<ConferenceParticipant>
      ConferenceParticipant:
        userId          : String
        displayName     : String
```

---

## 7. Event Flow — Outgoing Call

```
TringupCallController.makeCall(number)
  → CallBloc.add(CallControlEvent.started(number, ...))
    → _onCallControlEvent → _onCallControlEventStarted
      → callkeep.startCall(...)
        → [native CallKit / ConnectionService]
          → CallBloc._onCallPerformEvent
            → creates RTCPeerConnection
            → sends SDP offer to signaling server
              → server sends 'call_accept' / 'call_reject'
                → CallBloc updates state
                  → CallState.display = CallDisplay.screen
                    → TringupCallShell inserts full-screen OverlayEntry
```

## 8. Event Flow — Incoming Call

```
FCM push (or WebSocket 'incoming_call' event)
  → CallBloc._onCallSignalingEvent → handles IncomingCallEvent
    → callkeep.reportIncomingCall(...)
      → [native incoming-call UI]
        → user taps Accept
          → CallBloc.add(CallControlEvent.answered(callId))
            → creates RTCPeerConnection
            → sends SDP answer
              → CallState.display = CallDisplay.screen
                → TringupCallShell inserts OverlayEntry
```

## 9. Event Flow — Group Call (Add Participant)

```
User taps "Add participant" in CallActiveScaffold
  → _showAddParticipantDialog → user enters number → OK
    → CallBloc.add(CallControlEvent.addParticipant(callId, number))
      → _onCallControlEventAddParticipant
        → signaling.send({ type: 'add_to_call', call_id, number })

[Server]
  → handleAddToCall:
      1. Creates Janus AudioBridge room if new
      2. Sends 'conference_upgrade' to BOTH existing call parties
      3. Looks up invitee in DB
      4. Sends 'conference_invite' to invitee

[Client — existing parties receive 'conference_upgrade']
  → CallBloc.add(_CallSignalingEventConferenceUpgrade(callId, roomId))
    → _onConferenceUpgrade:
        1. Stores _ConferenceCallState(roomId)
        2. Closes old 1:1 RTCPeerConnection
        3. Creates new RTCPeerConnection for AudioBridge
        4. Creates SDP offer (audio only)
        5. signaling.send({ type: 'conference_join', call_id, room_id, jsep })

[Server receives 'conference_join']
  → joinParticipant:
      1. Creates Janus handle, joins AudioBridge room
      2. Gets SDP answer from Janus
      3. Sends 'conference_join_answer' to this client
      4. Broadcasts 'conference_participant_joined' to others

[Client receives 'conference_join_answer']
  → CallBloc.add(_CallSignalingEventConferenceJoinAnswer(callId, roomId, jsep))
    → _onConferenceJoinAnswer:
        1. Sets remote description on pending RTCPeerConnection
        2. Call is now through AudioBridge

[Invitee receives 'conference_invite']
  → CallBloc.add(_CallSignalingEventConferenceInvite(callId, roomId, ...))
    → _onConferenceInvite:
        1. Creates RTCPeerConnection for AudioBridge
        2. Creates SDP offer
        3. signaling.send({ type: 'conference_accept', call_id, room_id, jsep })
        → same joinParticipant path on server
```

---

## 10. Adding a New Feature — Checklist

### A. New call control button (e.g., "Raise Hand")

1. **`webtrit_phone-main/lib/features/call/bloc/call_event.dart`**
   Add a new factory in `CallControlEvent`:
   ```dart
   const factory CallControlEvent.raiseHand(String callId) = _CallControlEventRaiseHand;
   // + private class _CallControlEventRaiseHand
   ```

2. **`webtrit_phone-main/lib/features/call/bloc/call_bloc.dart`**
   Add handler in `_onCallControlEvent` switch and implement `_onCallControlEventRaiseHand`.

3. **`webtrit_phone-main/lib/features/call/widgets/call_actions.dart`**
   Add `onRaiseHandPressed` callback param.
   Add button to the widget tree.
   **Keep button count a multiple of 3** — `TextButtonsTable` enforces `children.length % 3 == 0`.
   Pad with `const SizedBox()` if necessary.

4. **`webtrit_phone-main/lib/features/call/view/call_active_scaffold.dart`**
   Wire `onRaiseHandPressed` to fire the new event.

5. **Backend `backend/src/signaling/server.ts`**
   Add `case 'raise_hand':` in the switch block.

### B. New signaling event from server

1. **`webtrit_phone-main/packages/webtrit_signaling/lib/src/events/call/`**
   Create `raise_hand_event.dart`:
   ```dart
   class RaiseHandEvent extends CallEvent {
     static const String typeValue = 'raise_hand';
     // fields...
     @override String get type => typeValue;
   }
   ```

2. **`webtrit_phone-main/packages/webtrit_signaling/lib/src/events/call/call_events.dart`**
   Add `export 'raise_hand_event.dart';`

3. **`webtrit_phone-main/packages/webtrit_signaling/lib/src/events/call_event.dart`**
   Register in `_callEventFromJsonDecoders`:
   ```dart
   RaiseHandEvent.typeValue: RaiseHandEvent.fromJson,
   ```

4. **`webtrit_phone-main/lib/features/call/bloc/call_event.dart`**
   Add `_CallSignalingEventRaiseHand` private class.

5. **`webtrit_phone-main/lib/features/call/bloc/call_bloc.dart`**
   In `_onSignalingEvent`, map `RaiseHandEvent` → `add(_CallSignalingEventRaiseHand(...))`.
   Register `on<_CallSignalingEventRaiseHand>(_onRaiseHand, ...)`.

### C. New config option in the package

1. Add field to `tringup_call/lib/src/tringup_call_config.dart`
2. Read it in `tringup_call/lib/src/tringup_call_widget.dart` inside `_buildCallBloc()`
3. Export via `tringup_call/lib/tringup_call.dart` (it's already exported via `tringup_call_config.dart`)

---

## 11. Known Constraints & Pitfalls

| Issue | Root cause | Fix / rule |
|-------|-----------|------------|
| `CallScreen` cannot be used in the package | Uses `AutoRouteAwareStateMixin` which calls `context.router` — throws with no auto_route | Always use `CallActiveScaffold` + `CallInitScaffold` directly in `_TringupCallScreenPage` |
| `TextButtonsTable` assertion error | `children.length % 3 != 0` — table enforces 3-column grid | When adding/removing buttons in `CallActions`, pad to a multiple of 3 with `const SizedBox()` |
| `TextEditingController` disposed too early | Disposing in `showDialog.then(...)` while dismiss animation still holds listener | Use `StatefulWidget` with controller in `State.dispose()` — done in `_AddParticipantDialog` |
| `TrustedCertificates([])` compile error | Factory constructor takes named param, not positional; not const | Use `TrustedCertificates.empty` (const static) |
| `SecureStorage()` cannot be instantiated | Abstract class — only `SecureStorageImpl` is concrete | Use `await SecureStorageImpl.init()` |
| `CallActiveScaffold` / `CallActiveThumbnail` not in barrel | Not exported from `call.dart` | Import by full file path: `package:webtrit_phone/features/call/view/call_active_scaffold.dart` |
| `groupCallEnabled` button invisible | `CallBloc.groupCallEnabled` is `false` by default | Pass `groupCallEnabled: true` in both `TringupCallConfig` AND verify it flows to `CallBloc` constructor in `_buildCallBloc` |
| Controller `makeCall` assertion failure | `_context` is null — controller not yet attached | Only call after at least one build of `TringupCallWidget` has completed |

---

## 12. Backend Environment Variables

| Variable | Default | Effect |
|----------|---------|--------|
| `JWT_SECRET` | `dev_secret_change_in_production` | Signs/verifies call JWTs |
| `DB_HOST` | `localhost` | MySQL host |
| `DB_PORT` | `3306` | MySQL port |
| `DB_USER` | `root` | MySQL user |
| `DB_PASSWORD` | `` | MySQL password |
| `DB_NAME` | `webtrit` | Database name |
| `JANUS_URL` | `http://aws.edumation.in:8889/janus` | Janus WebSocket gateway URL |
| `GROUP_CALL_ENABLED` | `false` | Enable `add_to_call` / conference signaling |
| `INTEGRATION_API_KEY` | `change-me-in-production` | Shared secret for `/integration/*` routes |

Set via `.env` file or shell export. Backend is in `webtrit_phone-main/backend/`.

---

## 13. Backend Integration API — Quick Reference

All endpoints require header: `x-integration-key: <INTEGRATION_API_KEY>`

### `POST /integration/token`
Upserts user in DB, issues 24 h JWT.
```json
// Request body
{ "userId": "chat-uuid", "phoneNumber": "+14155550100", "firstName": "Alice", "lastName": "Smith" }

// Response
{ "token": "eyJ...", "expiresIn": 86400 }
```

### `DELETE /integration/users/:userId`
Sets `status = 'inactive'` for the user.
```json
// Response
{ "ok": true }
```

### `GET /integration/users/:userId/status`
Checks live WebSocket connection via `ConnectionManager`.
```json
// Response
{ "online": true }
```

---

## 14. Signal Protocol Messages (WebSocket)

All messages follow `{ type: string, line: int, call_id: string, ...fields }`.

### Client → Server

| `type` | Key fields | When sent |
|--------|-----------|-----------|
| `add_to_call` | `call_id`, `number` | User taps "Add participant" |
| `conference_join` | `call_id`, `room_id`, `jsep` (SDP offer) | Existing party upgrading to AudioBridge |
| `conference_accept` | `call_id`, `room_id`, `jsep` (SDP offer) | Invitee accepting conference invite |
| `conference_decline` | `call_id` | Invitee declining |

### Server → Client

| `type` | Key fields | When sent |
|--------|-----------|-----------|
| `conference_upgrade` | `call_id`, `room_id` | Both existing parties told to switch to AudioBridge |
| `conference_invite` | `call_id`, `room_id`, `inviter`, `inviter_display_name` | Sent to the newly invited user |
| `conference_join_answer` | `call_id`, `room_id`, `jsep` (SDP answer) | Janus SDP answer for the joining client |
| `conference_participant_joined` | `call_id`, `room_id`, `user_id`, `display_name` | Broadcast when anyone joins |
| `conference_participant_left` | `call_id`, `room_id`, `user_id` | Broadcast when anyone leaves |

---

## 15. Running `flutter analyze` After Changes

Always run from the package root after any change:

```bash
cd tringup_call
flutter analyze
```

Expected output: `No issues found!`

If `webtrit_phone` changes break a stub interface:
- **"Missing concrete implementation"** → add the missing method to the relevant stub in `stubs/`
- **"Getter not found"** or **"Method not found"** on `CallBloc` → update the event call in
  `tringup_call_widget.dart` to match the new constructor signature

---

## 16. File Quick-Find Cheatsheet

| What you want to change | File |
|------------------------|------|
| Add a config option | `tringup_call/lib/src/tringup_call_config.dart` |
| Wire a new config into CallBloc | `tringup_call/lib/src/tringup_call_widget.dart` → `_buildCallBloc()` |
| Change how the call screen looks | `webtrit_phone-main/lib/features/call/view/call_active_scaffold.dart` |
| Add/remove a call action button | `webtrit_phone-main/lib/features/call/widgets/call_actions.dart` |
| Change the call thumbnail | `webtrit_phone-main/lib/features/call/view/call_active_thumbnail.dart` |
| Change the "Calling…" screen | `webtrit_phone-main/lib/features/call/view/call_init_scaffold.dart` |
| Add a BLoC event | `webtrit_phone-main/lib/features/call/bloc/call_event.dart` |
| Handle a BLoC event | `webtrit_phone-main/lib/features/call/bloc/call_bloc.dart` |
| Add a signaling event from server | `webtrit_phone-main/packages/webtrit_signaling/lib/src/events/call/` |
| Change how overlay appears/hides | `tringup_call/lib/src/tringup_call_shell.dart` → `_TringupCallShellState` |
| Change thumbnail drag behaviour | `tringup_call/lib/src/tringup_call_shell.dart` → `_DraggableThumbnailState` |
| Fix background call handling | `tringup_call/lib/src/tringup_call_background_handler.dart` |
| Add a group-call server handler | `webtrit_phone-main/backend/src/signaling/handlers/conference.ts` |
| Add a backend REST endpoint | `webtrit_phone-main/backend/src/routes/integration/index.ts` |
| Change backend config / env vars | `webtrit_phone-main/backend/src/config.ts` |
