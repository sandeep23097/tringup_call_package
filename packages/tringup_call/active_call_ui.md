# Active Call UI — Redesign Specification

**File to be rewritten:** `packages/tringup_call/lib/src/default_call_screen.dart`
**Review this document first — implementation happens only after approval.**

---

## 1. Design System

### 1.1 Color Palette

| Token | Value | Usage |
|---|---|---|
| `bgDeep` | `#071015` | Screen background (bottom) |
| `bgMid` | `#0D1F2D` | Screen background (top) |
| `bgSurface` | `#0F2132` | Cards, panels |
| `bgOverlay` | `rgba(0,0,0,0.45)` | Scrim over video |
| `controlBg` | `rgba(255,255,255,0.12)` | Idle control button fill |
| `controlActive` | `rgba(255,255,255,0.28)` | Active/toggled button fill |
| `green` | `#25D366` | Connected timer, answer button |
| `teal` | `#128C7E` | Accent, speaking border |
| `red` | `#E53935` | End-call button |
| `textPrimary` | `#FFFFFF` | Name, numbers |
| `textSecondary` | `rgba(255,255,255,0.65)` | Status, labels |
| `speakerGlow` | `#25D366 @ 60%` | Active-speaker border |

### 1.2 Typography

| Role | Size | Weight |
|---|---|---|
| Caller name | 26 sp | w600 |
| Phone number | 14 sp | w400 |
| Status / timer | 14 sp | w400 (green when connected) |
| Control label | 11 sp | w400 |
| Panel title | 16 sp | w600 |

### 1.3 Shape & Elevation

- All control buttons: `BorderRadius.circular(16)` (squircle feel, **not** circle)
- End-call & answer buttons: remain circular (`BorderRadius.circular(36)`)
- Video tiles (group): `BorderRadius.circular(12)`
- Self-PiP window: `BorderRadius.circular(14)`, `boxShadow: [0 4 16 rgba(0,0,0,0.5)]`
- Panels: `BorderRadius.vertical(top: Radius.circular(24))`

### 1.4 Animation Tokens

| Name | Duration | Curve |
|---|---|---|
| Button press scale | 80 ms | easeIn |
| Panel slide | 300 ms | easeOutCubic |
| Speaking pulse | 1200 ms | Curves.easeInOut (repeat) |
| Status fade | 200 ms | linear |
| Layout switch | 350 ms | easeInOutCubic |

---

## 2. Screen Layout (all call types)

```
┌─────────────────────────────────────┐
│  TOP HEADER                         │  ← fixed height ~80 dp (SafeArea)
├─────────────────────────────────────┤
│                                     │
│  CENTER CONTENT AREA                │  ← Expanded, fills remaining space
│  (dynamic — see §4)                 │
│                                     │
├─────────────────────────────────────┤
│  BOTTOM CONTROL BAR                 │  ← fixed height ~160 dp
└─────────────────────────────────────┘
```

The full screen is always a `Stack` (unchanged architecture). Panels slide up over the bottom bar.

---

## 3. Top Header

### 3.1 Layout

```
[ ↓ minimize ]   [ Name / Group Title ]   [ ⊕ Add | 👥 Members ]
                 [ status / timer       ]
                 [ 🔒 encrypted         ]   ← optional, subtle
```

- **Minimize button** (left): `Icons.keyboard_arrow_down_rounded`, size 30, `Colors.white70`
- **Center block** (centered, `Expanded`):
  - Call title: `info.callerLabel` (name or group name)
  - Below title: status label (`_statusLabel`) — color `green` when connected, else `textSecondary`
  - Below status: small lock icon + "End-to-end encrypted" text (12 sp, `textSecondary`, always shown)
- **Right action** (right):
  - If `info.isGroupCall` → `Icons.group` → opens `_GroupMembersPanel`
  - Else if `actions.addParticipant != null` → `Icons.person_add` → opens `_AddParticipantPanel`
  - Both: 40×40 circular button with `controlBg` background

### 3.2 Changes from current

| Current | New |
|---|---|
| Bare `IconButton` at top-left | Full header `Row` with title/status/right action |
| Name + status scattered in column | Name + status anchored to header |
| No encryption indicator | Lock icon + label added |
| Add/Members buttons in bottom row | Moved to header right slot |

---

## 4. Center Content Area

Dynamic — switches based on `isVideoCall`, `isGroupCall`, participant count.

### 4.1  Audio 1:1 Call

```
         ┌──────────────────┐
         │   Avatar (96dp)  │
         │  ┌────────────┐  │
         │  │  initials  │  │
         │  └────────────┘  │
         │  ◦ ◦ ◦ pulse    │  ← speaking animation when connected
         └──────────────────┘
              Display Name
              Phone Number
```

- Avatar: `CircleAvatar` radius 52, gradient fill (`teal` → `bgMid`) when no photo, else `CachedNetworkImage` / `FileImage`
- Speaking pulse: three concentric `AnimatedContainer` rings that scale 1.0→1.35 and fade out on repeat when call is connected. Implemented with `TweenAnimationBuilder` or `AnimationController`.
- Name below avatar: 26 sp, white, w600
- Number below name (if `displayName != null`): 14 sp, `textSecondary`

### 4.2  Audio Group Call (3+ participants)

Grid of avatar tiles, max 2 columns, scrollable:

```
  ┌──────────────┐  ┌──────────────┐
  │  Avatar      │  │  Avatar      │
  │  Name        │  │  Name        │
  │  🟢 speaking │  │              │
  └──────────────┘  └──────────────┘
  ┌──────────────────────────────────┐
  │  Avatar     Name    🔴 muted     │
  └──────────────────────────────────┘
```

Each tile (`_AudioParticipantTile`):
- Size: `(screenWidth / 2) - 20` wide, 130 dp tall
- `BorderRadius.circular(16)`
- Background: `bgSurface`
- Avatar (40 dp radius), centered top half
- Name centered below, 13 sp
- **Active speaker**: animated green border glow (`BoxDecoration` + `BoxShadow` color `speakerGlow`, toggle via LiveKit `isSpeaking`)
- **Muted indicator**: small `Icons.mic_off` badge bottom-right of avatar (red circle, 16 dp)

Implementation note: `_connectedParticipants` = `info.participants`. The self tile is not shown (user sees themselves in PiP if video) or omitted for audio.

### 4.3  Video 1:1 Call

No change to the core rendering — remote video fills background, local video is draggable PiP. Enhancements:

- PiP window: size increases from 100×140 to **108×152**, border radius 14, add `boxShadow`
- PiP border: 2 dp solid `Colors.white30`
- Scrim: unchanged (`Colors.black38` over remote video)
- When `!isCameraEnabled`: replace local video PiP with a small dark tile + `Icons.videocam_off` icon

### 4.4  Video Group Call (2+ remote participants)

**New widget**: `_VideoGroupGrid` (replaces the single remote video background).

Layout rules:

| Remote count | Layout |
|---|---|
| 1 | Remote fills full background (existing behaviour) |
| 2 | Two equal vertical halves |
| 3 | Top row: 2 tiles, bottom row: 1 tile (full width) |
| 4 | 2×2 grid |
| 5+ | 2-column grid, scrollable |

Each tile:
- `lk.VideoTrackRenderer` or `_AudioParticipantTile` fallback if video off
- Name overlay: semi-transparent bar at tile bottom, white text 12 sp
- Speaking glow: `AnimatedContainer` border color toggles `speakerGlow` ↔ transparent

Self video:
- Same draggable PiP as 1:1 video call
- Snap-to-edges on drag release (new: `_snapPip` method rounds to nearest corner)

---

## 5. Bottom Control Bar

**Replaces** the current two-row layout (Row 1: secondary controls, Row 2: hang-up/answer).

### 5.1  Connected Audio Call

```
┌──────────────────────────────────────────────────────┐
│  [Speaker]  [Mute]   [  END  ]   [Video]  [Hold]    │
└──────────────────────────────────────────────────────┘
```

Button specs:

| Button | Icon | Active state | Size |
|---|---|---|---|
| **Speaker** | `volume_up` / `bluetooth_audio` / `volume_down` | white bg, teal icon | 56×56 squircle |
| **Mute** | `mic` / `mic_off` | red bg when muted | 56×56 squircle |
| **End Call** | `call_end` | always red | 68 dp circle |
| **Video** | `videocam` / `videocam_off` | - | 56×56 squircle |
| **Hold** | `pause` / `play_arrow` | `controlActive` when held | 56×56 squircle |

- End Call button is always centered, slightly larger (68 dp), slightly elevated via shadow
- Speaker button: 3-state cycle: earpiece → speaker → bluetooth (if connected). Long press shows picker sheet (future scope, noted but not implemented now).
- All buttons have `ScaleTransition` press feedback (scale 0.92 on down, 1.0 on up)
- Labels below each button (11 sp, `textSecondary`): "Speaker", "Mute/Unmute", "", "Video", "Hold"

### 5.2  Connected Video Call

Same bar, but:
- **Video button** controls camera on/off (`info.isCameraEnabled`)
- **Flip camera** replaces Hold button (when camera enabled): `Icons.flip_camera_android`
- When camera disabled: Flip button is dimmed (`opacity: 0.4`, non-tappable)

### 5.3  Incoming Call (not yet answered)

```
┌─────────────────────────────────────────────────────┐
│        [ DECLINE ]          [ ANSWER ]              │
└─────────────────────────────────────────────────────┘
```

- Both 68 dp circles, spaced `MainAxisAlignment.spaceEvenly`
- Decline: red (`#E53935`), `Icons.call_end`
- Answer: green (`#25D366`), `Icons.call`
- **Swipe-up affordance** on Answer button: brief upward arrow animation (subtle, 1 repeat on mount)
- Label below: "Decline" / "Answer" in `textSecondary`

### 5.4  Changes from current

| Current | New |
|---|---|
| Secondary controls row only visible when `isConnected` | Full bar always visible; buttons disabled/hidden pre-connect |
| Add/Members in bottom row | Moved to header |
| Video + Flip in same row as Mute/Speaker | Same row, reordered |
| No Hold button visible | Hold added as 5th slot |
| No press-scale animation | `ScaleTransition` on all buttons |
| Circular buttons | Squircle for secondary, circle for primary only |

---

## 6. Sliding Panels (bottom sheets)

Both panels get visual refresh:

### 6.1  `_AddParticipantPanel` (unchanged logic, visual update)

- Background: `bgSurface` with `BackdropFilter(ImageFilter.blur(sigmaX:20, sigmaY:20))` on the backdrop
- Border: `border: Border(top: BorderSide(color: Colors.white12, width: 1))`
- Handle bar: width 40, height 4, `Colors.white24`, `br(2)`
- Participant rows: avatar (36 dp) + name + trailing chip ("Calling…" / "Ringing" / "Failed" / "Add")
- "Failed" chip: red, tappable → retry

### 6.2  `_GroupMembersPanel` (unchanged logic, visual update)

Same visual treatment. Sections:
1. **Connected** — green dot badge on avatar
2. **Ringing** — animated ring icon
3. **Calling** — subtle shimmer on name
4. **Failed** — red "×" badge, retry link

---

## 7. New Widgets to Create

| Widget | Purpose | Location |
|---|---|---|
| `_ControlBar` | Unified bottom control bar (§5) | bottom of `default_call_screen.dart` |
| `_SquircleButton` | Reusable squircle icon button with scale anim | same file |
| `_PrimaryButton` | Large circle call-action (end/answer) with scale anim | same file |
| `_SpeakingPulse` | Three animated rings around avatar | same file |
| `_AudioParticipantTile` | Audio group grid tile (§4.2) | same file |
| `_VideoGroupGrid` | Multi-participant video layout (§4.4) | same file |

Widgets to keep (no change to logic, visual refresh only):

- `_AddParticipantPanel` — keep logic, update colors/radius
- `_GroupMembersPanel` — keep logic, update colors/radius
- `_CallerAvatar` — keep, add speaking pulse integration
- `_PendingInvite` / `_InviteState` — unchanged

---

## 8. State & Logic Changes

### 8.1  PiP snap-to-corner

Currently: PiP follows drag but stays where released.
New: on `DragEndDetails`, animate PiP to the nearest of 4 corners (12 dp inset from screen edge) using `AnimationController` + `Tween<Offset>`.

```
// new field
AnimationController? _pipSnapController;
late Animation<Offset> _pipSnapAnim;

void _onPipDragEnd(DragEndDetails details, Size screen) {
  // compute nearest corner → animate _pipOffset to it
}
```

### 8.2  Active speaker tracking (group calls)

New field: `String? _activeSpeakerId`

In `_onRoomChanged` (existing LiveKit listener), read `lkRoom.activeSpeakers` and update:
```dart
void _onRoomChanged() {
  final speaker = _attachedRoom?.activeSpeakers.firstOrNull;
  if (mounted) setState(() => _activeSpeakerId = speaker?.identity);
}
```

Pass `_activeSpeakerId` down to `_AudioParticipantTile` and `_VideoGroupGrid` for glow rendering.

### 8.3  Speaking pulse (audio 1:1)

Start `AnimationController` (repeat) only when `info.isConnected`. Stop (and reset) otherwise. No extra timers needed.

---

## 9. Files Changed

| File | Change type |
|---|---|
| `lib/src/default_call_screen.dart` | **Full rewrite** of `_TringupDefaultCallScreenState.build()` and all private widgets |
| `lib/src/tringup_call_screen_api.dart` | No change |
| `lib/src/tringup_call_shell.dart` | No change |
| `lib/src/tringup_call_theme.dart` | No change (existing theme tokens still used) |

No new files required — all new widgets live in `default_call_screen.dart`.

---

## 10. Implementation Phases

| Phase | Scope | Risk |
|---|---|---|
| **P1** | Rewrite `_ControlBar` (§5) + `_SquircleButton` / `_PrimaryButton` | Low — pure visual |
| **P2** | Top header redesign (§3) — move Add/Members to header | Low |
| **P3** | Audio 1:1 center: speaking pulse + enhanced avatar (§4.1) | Low |
| **P4** | Audio group grid `_AudioParticipantTile` (§4.2) | Medium |
| **P5** | Video group grid `_VideoGroupGrid` (§4.4) + PiP snap | Medium |
| **P6** | Panel visual refresh (§6) | Low |

Each phase is independently testable. P1 + P2 + P3 deliver most of the visual improvement with minimal risk.

---

## 11. What Does NOT Change

- Stack slot architecture (5 fixed children — keeps PiP renderer alive)
- `Offstage` pattern for PiP and chrome (prevents video frame flash)
- `_pendingInvites` tracking and invite timer logic
- `_attachRoom` / `_onRoomChanged` LiveKit listener
- `_PendingInvite`, `_InviteState` data classes
- PiP enter/exit (`_isInPiP`) and `_pipSub` subscription
- All `TringupCallInfo` / `TringupCallActions` API — zero change to public API

---

## 12. Open Questions (resolve before implementation)

1. **Hold button**: Should Hold be visible in the bottom bar for all call types, or only 1:1 audio?
2. **Speaker 3-state cycle**: Long-press sheet for device picker — implement now or later?
3. **Video → switch-to-video**: For a started audio call, should the Video button in the bar initiate a video upgrade (future feature) or remain hidden?
4. **Encryption badge**: Always show, or only show when a specific flag is set by the host app?
5. **Group video grid scrolling**: Should the grid support scroll (5+ participants), or cap at 4 with a "+N more" tile?

---

*Once approved, implementation begins with Phase 1 (control bar) and progresses through each phase sequentially.*
