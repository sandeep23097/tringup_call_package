# Group Call Bug Fix Specification

**Review this document and approve before implementation begins.**

---

## Background — The Core Problem (affects Issues 1, 2, 5)

`conferenceParticipants` stores phone numbers as `userId` (set at call-invite time).
The LiveKit room uses server-assigned identities (`lkRoom.remoteParticipants.keys`).
These two ID formats are **different**, so cross-matching fails silently throughout the panel.

All panel bucket logic (`connected`, `waitingToJoin`, `isSelf`) uses
`lkConnectedIds.contains(p.userId)` — a set of server IDs against phone-number keys —
which never matches. This is the root cause of members appearing in the wrong bucket or appearing twice.

---

## Issue 1 — Receiver sees 4 members instead of 3

### Symptoms
On receiver (B) side, the members panel shows 4 rows when there are only 3 people:
`You · A (Ringing) · B (Ringing, wrong — this is self!) · C (Ringing)`.

### Root Cause
`selfUserId` = `lkRoom.localParticipant.identity` (server ID).
`allInvited` has B stored with phone number as `userId` (from `call_invite`).
`isSelf(phone_number)` = `phone_number == server_id` = **false** → B is not excluded → B shows in `waitingToJoin` AS WELL AS in the "You" entry.

Same mismatch prevents A from appearing in `connected`: A's phone number ≠ `lkConnectedIds` server ID.

### Fix

#### Step 1 — Add `localUserNumber` to `TringupCallInfo`
```dart
// tringup_call_screen_api.dart
class TringupCallInfo {
  const TringupCallInfo({
    ...
    this.localUserNumber,   // NEW: the current user's own phone number
  });

  /// The current user's own registered phone number.
  /// Used in the panel to identify "self" when the LiveKit identity
  /// differs from the stored phone-number userId in conferenceParticipants.
  final String? localUserNumber;
}
```

#### Step 2 — Populate it in `tringup_call_shell.dart`
Get the local user's number from registration or the `event.from` field in the
initiating event. It is accessible as `state.callServiceState.registration?.account?.number`
(or equivalent field — confirm the exact path in the registration model).

```dart
final info = TringupCallInfo(
  ...
  localUserNumber: state.callServiceState.registration?.account?.number,
);
```

#### Step 3 — Update `isSelf` in `_GroupMembersPanel`
```dart
// Pass localUserNumber through to the panel
selfUserId: lkRoom?.localParticipant?.identity,
selfPhoneNumber: info.localUserNumber,   // NEW arg
```

```dart
// In _GroupMembersPanel
final isSelf = (String id) =>
    id == selfUserId ||
    (selfPhoneNumber != null && id == selfPhoneNumber);
```

With `isSelf` now matching both server ID and phone number, B's phone-number entry
in `allInvited` is correctly excluded, so B no longer appears twice.

#### Step 4 — Fix `selfParticipant` lookup
```dart
TringupParticipant? selfParticipant;
if (selfUserId != null || selfPhoneNumber != null) {
  final found = allInvited.where((p) => isSelf(p.userId));
  selfParticipant = found.isNotEmpty
      ? found.first
      : TringupParticipant(
          userId: selfUserId ?? selfPhoneNumber!,
          displayName: 'You',
        );
}
```

---

## Issue 2 — C always stays in "Ringing" (timeout never fires)

### Symptoms
In a 3-person call (A caller, B + C receivers):
- B answers → B is Connected
- C is ringing
- After 45+ seconds C never moves to "No answer" / "Timed out"

### Root Cause
The 45-second `_pendingInvites` timer only applies to **Add-button** invites.
Server-invited participants (`waitingToJoin`) have no timeout.
Furthermore, the broad `call_ended` guard introduced in the previous session ignores
`no_answer` / `missed` events — so even the server's timeout signal is swallowed.

### Fix

#### Step A — Re-narrow the `call_ended` group-call guard (in `call_bloc.dart`)
Instead of ignoring **all** `call_ended` while the room is active, only ignore the
pre-join-reject reasons. For `no_answer` / `missed`, mark the specific timing-out
participant instead of ignoring entirely (see Step B).
For `normal_clearing` (active hang-up), check room emptiness (see Issue 3).

```dart
// Revised guard in _onCallEnded
if (isGroupCall && _livekitRooms.containsKey(event.callId)) {
  if (event.reason == 'declined') {
    // Single invitee explicitly declined — call continues.
    _logger.info('[Room] group call: participant declined, call continues '
        'callId=${event.callId}');
    return;
  }
  if (event.reason == 'no_answer' || event.reason == 'missed') {
    // Invite timed out for one invitee — mark them as timed out but keep call.
    // (See Step B below for the marking logic.)
    _logger.info('[Room] group call: participant timed out, call continues '
        'callId=${event.callId}');
    // TODO Step B: mark participant as timed out
    return;
  }
  // For 'normal_clearing' and other reasons: check room emptiness (Issue 3).
}
```

#### Step B — Track timed-out server-invited participants in UI
Add a `Map<String, DateTime> _invitedAt` to the screen state. When a participant
first appears in `waitingToJoin`, record `DateTime.now()`. In the panel, split
`waitingToJoin` into two groups:

```dart
// In _GroupMembersPanel.build() (or passed in as a param from the screen):
final now = DateTime.now();
const timeout = Duration(seconds: 45);

final stillRinging = waitingToJoin
    .where((p) => invitedAt[p.userId] == null ||
                  now.difference(invitedAt[p.userId]!) < timeout)
    .toList();

final timedOut = waitingToJoin
    .where((p) => invitedAt[p.userId] != null &&
                  now.difference(invitedAt[p.userId]!) >= timeout)
    .toList();
```

The `invitedAt` map is populated in the screen's `build()` (or `_onRoomChanged`) whenever a
participant appears in `waitingToJoin` for the first time:
```dart
for (final p in waitingToJoin) {
  _invitedAt.putIfAbsent(p.userId, () => DateTime.now());
}
```

Show `timedOut` participants with a "No answer" chip (same visual as `failed` from
`_pendingInvites`).

**Pass** `invitedAt` to `_GroupMembersPanel` as a required param.

---

## Issue 3 — 2-person group call does not end when one user hangs up

### Symptoms
Group call between A and B. When B hangs up:
- Server sends `call_ended` to A
- Broad guard ignores it (room still in `_livekitRooms`)
- `participant_left` may or may not arrive from server
- A is stuck alone, call never ends

### Root Cause
The broad `call_ended` guard (`isGroupCall && lkRoom active → return`) is too aggressive.
It ignores the "last person left" case.

### Fix — In `_onCallEnded` in `call_bloc.dart`

After handling `declined` / `no_answer` / `missed` (which always ignore),
for **`normal_clearing`** and other active-hang-up reasons:

```dart
// For active hang-up reasons, check if the room is now empty
if (isGroupCall && _livekitRooms.containsKey(event.callId)) {
  final lkRemoteCount =
      _livekitRooms[event.callId]?.room?.remoteParticipants.length ?? 0;

  if (lkRemoteCount > 0) {
    // Other participants still in room — ignore this call_ended.
    _logger.info('[Room] group call: participant left but others remain '
        '(${lkRemoteCount}), call continues callId=${event.callId}');
    return;
  }

  // Room is empty — fall through to full teardown below.
  _logger.info('[Room] group call: last participant left via call_ended, '
      'tearing down callId=${event.callId}');
}
```

This handles the race correctly in the common case:
- LiveKit room update (B leaves LK room) arrives **before** `call_ended` signaling
  → `lkRemoteCount = 0` → teardown ✓
- If `call_ended` arrives before LiveKit → `lkRemoteCount = 1` → ignored
  → `participant_left` server event will trigger `_onParticipantLeft` auto-end as fallback ✓

**Also**: Revert the `_onParticipantLeft` auto-end back to checking
`updatedParticipants.isEmpty` instead of `lkRoom.remoteParticipants.length == 0`,
because for a 2-person group call A + B:

- `conferenceParticipants` (after my caller-init fix) = [B]
- B joins → dedup → still [B]
- B leaves → `participant_left` → [empty] → auto-end ✓

The `lkRoom.remoteParticipants.length` check is unreliable because the LiveKit
disconnect may have already fired and `_livekitRooms[callId]?.room` might be null
or already disconnected by the time `_onParticipantLeft` is processed.

```dart
// Revert auto-end to use updatedParticipants:
if (updatedParticipants.isEmpty) {
  final lkRoom = _livekitRooms.remove(event.callId);
  if (lkRoom != null) await lkRoom.disconnect();
  // ... full teardown
}
```

---

## Issue 4 — C's incoming call shows Connected UI when B answers

### Symptoms
3-person call: A (caller), B, C (both receivers, both ringing).
B answers → B is Connected.
C's call screen **immediately flips to Connected** even though C has not answered.

### Root Cause
In `_onParticipantJoined`, the BLoC updates `conferenceParticipants` for **all** active calls
with matching `callId`. It also unconditionally sets:
```dart
acceptedTime: call.acceptedTime ?? clock.now(),
```
When B joins, this fires on C's device too. C's `call.acceptedTime` is `null` (C hasn't
answered), so `null ?? clock.now()` = `clock.now()` — marking C's call as accepted/connected.

`isConnected` in `TringupCallInfo` is derived from `activeCall.wasAccepted` which checks
`acceptedTime != null`, so C's UI transitions to Connected.

### Fix — `call_bloc.dart` → `_onParticipantJoined`

Only set `acceptedTime` if the call is outgoing (caller) OR if the call was **already**
accepted by this device. Never set it just because a remote participant joined.

```dart
// Before (wrong — sets acceptedTime for all devices):
acceptedTime: call.acceptedTime ?? clock.now(),

// After (correct):
// - Outgoing/caller: set acceptedTime when first participant joins (call "connected")
// - Incoming already answered: acceptedTime already set, keep it (no-op)
// - Incoming NOT yet answered: acceptedTime stays null (call still ringing)
acceptedTime: call.direction == CallDirection.outgoing
    ? (call.acceptedTime ?? clock.now())
    : call.acceptedTime,   // preserve existing value (null = still ringing)
```

---

## Issue 5 — "Left call" section shows userId instead of display name

### Symptoms
When a participant leaves, the "Left call" panel section shows a raw user ID
(e.g., `usr_abc123` or a UUID) instead of their contact name.

### Root Cause
`_leftParticipants` is built in `_onRoomChanged` from `_knownRemoteNames`, which
stores `lkP.name` (LiveKit display name set by server). If the server sets `name` to a
phone number or UUID instead of the contact display name, the raw value is shown.

### Fix — `_onRoomChanged` in `default_call_screen.dart`

When a departure is detected, look up the participant in `widget.info.participants`
(which contains **contact-resolved display names** from the BLoC) before falling back
to the LiveKit name. At the time `_onRoomChanged` fires, the BLoC has not yet processed
`participant_left`, so `widget.info.participants` still contains the departed participant.

```dart
// In _onRoomChanged departure detection:
for (final id in _prevRemoteIds) {
  if (!currentIds.contains(id) && !_leftParticipants.containsKey(id)) {
    // Prefer contact-resolved name from conferenceParticipants (still present here)
    final known = widget.info.participants.where((p) => p.userId == id);
    final resolvedName = known.isNotEmpty
        ? (known.first.displayName ?? known.first.userId)
        : (_knownRemoteNames[id] ?? id);   // fallback to LiveKit name → identity

    _leftParticipants[id] = TringupParticipant(
      userId: id,
      displayName: resolvedName,
    );
  }
}
```

> **Note**: `widget.info.participants` accesses the `TringupCallInfo` passed from the
> shell into `TringupDefaultCallScreen`, which is accessible as `widget.info` inside
> `_TringupDefaultCallScreenState`.

---

## Issue 6 — Call CDR (history) not delivered to host app on call end

### Symptoms
When a call ends (any type — 1:1 or group), the host app (chat app) has no way to
immediately receive the call record to display it as a message in the chat.

### Proposed Design

#### Step 1 — Define `TringupCallCDR` data class
Add to `tringup_call_screen_api.dart` (or a new `tringup_call_cdr.dart`):

```dart
@immutable
class TringupCallCDR {
  const TringupCallCDR({
    required this.callId,
    required this.number,
    this.displayName,
    this.groupName,
    this.participants = const [],
    required this.createdAt,
    this.connectedAt,
    required this.endedAt,
    required this.isIncoming,
    required this.isVideo,
    required this.endReason,
  });

  /// Primary remote phone number (first participant for group calls).
  final String callId;
  final String number;
  final String? displayName;

  /// Non-null for group calls.
  final String? groupName;

  /// All participants for group calls; empty for 1:1 calls.
  final List<TringupParticipant> participants;

  final DateTime createdAt;

  /// Null when the call was never answered.
  final DateTime? connectedAt;

  final DateTime endedAt;
  final bool isIncoming;
  final bool isVideo;

  /// Server-provided end reason: 'normal_clearing', 'declined', 'no_answer',
  /// 'missed', or 'unknown'.
  final String endReason;

  /// Null when the call was never answered.
  Duration? get duration =>
      connectedAt != null ? endedAt.difference(connectedAt!) : null;

  bool get wasAnswered => connectedAt != null;
}
```

#### Step 2 — Add `onCallEnded` callback to `TringupCallShell`
```dart
class TringupCallShell extends StatelessWidget {
  const TringupCallShell({
    ...
    this.onCallEnded,   // NEW
  });

  /// Called immediately when any call ends (both 1:1 and group).
  /// Use this to display the call record in chat or save it to history.
  final void Function(TringupCallCDR cdr)? onCallEnded;
```

#### Step 3 — Fire the callback from the shell

In `TringupCallShell`'s `BlocListener<CallBloc, CallState>`, detect when an active
call disappears from state. The previous call object (from `previous.activeCalls`)
provides all the data needed to construct the CDR.

```dart
BlocListener<CallBloc, CallState>(
  listenWhen: (prev, curr) =>
      prev.activeCalls.length != curr.activeCalls.length,
  listener: (context, state) {
    if (widget.onCallEnded == null) return;

    // Find calls present in prev but missing in curr (ended calls)
    final prevIds = prev.activeCalls.map((c) => c.callId).toSet();
    final currIds = curr.activeCalls.map((c) => c.callId).toSet();
    final endedIds = prevIds.difference(currIds);

    for (final callId in endedIds) {
      final ended = prev.activeCalls.firstWhere((c) => c.callId == callId);
      final cdr = TringupCallCDR(
        callId:      ended.callId,
        number:      ended.handle.value,
        displayName: ended.displayName,
        groupName:   ended.groupName,
        participants: ended.conferenceParticipants
            .map((cp) => TringupParticipant(
                  userId:      cp.userId,
                  displayName: cp.displayName,
                ))
            .toList(),
        createdAt:   ended.createdTime,
        connectedAt: ended.acceptedTime,
        endedAt:     ended.hungUpTime ?? DateTime.now(),
        isIncoming:  ended.isIncoming,
        isVideo:     ended.video,
        endReason:   _resolveEndReason(ended),
      );
      widget.onCallEnded!(cdr);
    }
  },
),
```

`_resolveEndReason` is a private helper that maps `ActiveCall` state to a string:
```dart
String _resolveEndReason(ActiveCall call) {
  if (call.wasAccepted) return 'normal_clearing';
  if (call.wasHungUp && !call.isIncoming) return 'cancelled';
  // For incoming calls never answered (missed/declined):
  return call.isIncoming ? 'missed' : 'no_answer';
}
```

> **Note**: A more accurate `endReason` can be stored directly on `ActiveCall` (as a
> new field updated in `_onCallEnded`) if the server-provided reason string is
> important for the CDR. This can be done as a follow-up without changing the API.

---

## Summary Table

| # | Issue | File(s) Changed | Risk |
|---|---|---|---|
| 1 | Self shown as Ringing (phone≠server ID) | `tringup_call_screen_api.dart`, `tringup_call_shell.dart`, `default_call_screen.dart` | Low |
| 2 | C always Ringing (no timeout) | `call_bloc.dart`, `default_call_screen.dart` | Medium |
| 3 | 2-person group call doesn't end | `call_bloc.dart` | Medium |
| 4 | C's UI goes Connected when B answers | `call_bloc.dart` | Low |
| 5 | Left member shows userId not name | `default_call_screen.dart` | Low |
| 6 | No CDR callback to host app | `tringup_call_screen_api.dart`, `tringup_call_shell.dart` | Low |

---

*Approve this document to begin implementation. Issues can be implemented independently.*
