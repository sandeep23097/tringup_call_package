# TringupCall Package — Native PiP Implementation Guide

> **Scope**: Industry-level Picture-in-Picture for active **video calls** on Android (API 26+) and iOS (15.4+).
> **Approach**: Native Android `enterPictureInPictureMode()` + iOS `AVPictureInPictureController` with `activeVideoCallSourceView` API.
> **Architecture**: New MethodChannel `com.tringup/pip` bridging the tringup_call Dart layer to platform-native PiP APIs in the host app.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [How PiP Works on Each Platform](#2-how-pip-works-on-each-platform)
3. [Files to Create or Modify](#3-files-to-create-or-modify)
4. [Phase 1 — Dart Layer (tringup_call package)](#4-phase-1--dart-layer-tringup_call-package)
5. [Phase 2 — Android Native (host app)](#5-phase-2--android-native-host-app)
6. [Phase 3 — iOS Native (host app)](#6-phase-3--ios-native-host-app)
7. [Full Data-Flow Diagram](#7-full-data-flow-diagram)
8. [Testing Checklist](#8-testing-checklist)
9. [Known Limitations & Edge Cases](#9-known-limitations--edge-cases)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    tringup_call Package (Dart)                  │
│                                                                 │
│  TringupCallShell                                               │
│    │  BlocListener on CallState                                 │
│    │  → when video call active + display=overlay/screen         │
│    ▼                                                            │
│  TringupPiPManager            (NEW: lib/src/pip/)               │
│    │  _channel = MethodChannel("com.tringup/pip")               │
│    │  _events  = EventChannel("com.tringup/pip/events")         │
│    │                                                            │
│    ├─ setup(streamId, aspectRatioX, aspectRatioY)               │
│    ├─ enterPiP()                                                │
│    ├─ exitPiP()                                                 │
│    └─ Stream<bool> pipModeStream  → rebuild UI                  │
│                                                                 │
│  DefaultCallScreen                                              │
│    └─ if (isInPiP) → show remote video only, no controls        │
└───────────────────────────────┬─────────────────────────────────┘
                                │  MethodChannel / EventChannel
                ┌───────────────┴───────────────┐
                │                               │
    ┌───────────▼────────────┐   ┌──────────────▼──────────────┐
    │  Android (Kotlin)      │   │  iOS (Swift)                │
    │  MainActivity.kt       │   │  TringupPiPHandler.swift    │
    │                        │   │                             │
    │  onUserLeaveHint()     │   │  AVPictureInPicture         │
    │  → enterPipMode()      │   │  Controller                 │
    │                        │   │  ContentSource:             │
    │  PictureInPicture      │   │  activeVideoCallSourceView  │
    │  Params.Builder()      │   │                             │
    │  .setAspectRatio(9:16) │   │  RTCMTLVideoView            │
    │  .setAutoEnter(true)   │   │  in PiP content VC          │
    └────────────────────────┘   └─────────────────────────────┘
```

**Key design decisions:**

| Decision | Rationale |
|---|---|
| Separate `TringupPiPManager` class | Clean separation; shell stays focused on display logic |
| EventChannel for mode changes | Push-based; no polling; works even when Flutter is partially suspended |
| `autoEnterEnabled = true` (Android) | OS enters PiP automatically on Home press — no user action needed |
| `activeVideoCallSourceView` (iOS 15.4+) | Designed for video calling; supports custom view content; no AVPlayer needed |
| Remote stream ID sent to native | Lets iOS create its own `RTCMTLVideoView` bound to the same track |
| Guard with `Platform.isAndroid / isIOS` | Single Dart class, platform fork only at the channel boundary |

---

## 2. How PiP Works on Each Platform

### Android

Android's PiP resizes the **whole Activity** into a small floating window. Flutter keeps running and rendering inside this window. The WebRTC `TextureView` continues receiving video frames — no extra work needed to keep video alive.

Critical points:
- `onUserLeaveHint()` fires when the user presses Home during an active call → we call `enterPictureInPictureMode()` there.
- `onPictureInPictureModeChanged()` fires when entering/exiting → we send an event to Flutter to rebuild the UI (hide controls in PiP, show them when restored).
- `PictureInPictureParams.Builder().setAutoEnterEnabled(true)` (Android 12+) auto-enters PiP even on back gesture — no `onUserLeaveHint` needed on newer devices.
- The Flutter call screen **continues rendering** in PiP; we just hide the control buttons and show only the video.

### iOS

iOS PiP is **not** a resized app window. It is a system-managed floating layer driven by `AVPictureInPictureController`. The app is backgrounded and Flutter rendering pauses. You must provide native video content to the PiP controller.

The iOS 15.4+ API for video calls:
```swift
let contentSource = AVPictureInPictureController.ContentSource(
    activeVideoCallSourceView: sourceUIView,
    contentViewController: pipVideoCallViewController
)
let pipController = AVPictureInPictureController(contentSource: contentSource)
```

- `sourceUIView`: any `UIView` on screen — used to animate the PiP window in/out. We use the Flutter view controller's root view.
- `contentViewController`: an `AVPictureInPictureVideoCallViewController` subclass whose `.view` is what appears in the PiP window. We add an `RTCMTLVideoView` to it, bound to the remote video track.

To get the video track natively, we leverage the fact that `flutter_webrtc` registers a singleton plugin (`FlutterWebRTCPlugin`) accessible from any iOS Swift code. The Dart side sends the remote `MediaStream` ID; the native code fetches the track and binds it to the PiP view.

---

## 3. Files to Create or Modify

### New files

| File | Location |
|---|---|
| `tringup_pip_manager.dart` | `packages/tringup_call/lib/src/pip/tringup_pip_manager.dart` |
| `TringupPiPHandler.swift` | `ios/Runner/TringupPiPHandler.swift` |

### Modified files

| File | Changes |
|---|---|
| `tringup_call_shell.dart` | Add `TringupPiPManager` lifecycle; connect to `CallBloc` video state |
| `default_call_screen.dart` | Add PiP mode listener; rebuild with video-only layout when in PiP |
| `tringup_call.dart` | Export `TringupPiPManager` |
| `MainActivity.kt` | Add PiP channel handler + `onUserLeaveHint` + `onPictureInPictureModeChanged` |
| `AndroidManifest.xml` | Add `android:supportsPictureInPicture="true"` |
| `AppDelegate.swift` | Register `TringupPiPHandler` |
| `ios/Runner/Info.plist` | Add `UIBackgroundModes` → `voip`, `audio` (if not already present) |

---

## 4. Phase 1 — Dart Layer (tringup_call package)

### 4.1 New file: `lib/src/pip/tringup_pip_manager.dart`

```dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _tag = '[TringupPiPManager]';

/// Manages native Picture-in-Picture lifecycle for active video calls.
///
/// Usage (handled internally by [TringupCallShell]):
///   1. Call [setup] when a video call becomes active, passing the remote
///      MediaStream ID and desired aspect ratio.
///   2. Call [enterPiP] when the call is minimised (or let auto-enter handle it).
///   3. Call [exitPiP] to restore the full call screen.
///   4. Listen to [pipModeStream] to know when the OS has entered/exited PiP
///      (so the UI can hide controls while in PiP).
///   5. Call [dispose] when the call ends.
class TringupPiPManager {
  static const _channel = MethodChannel('com.tringup/pip');
  static const _events  = EventChannel('com.tringup/pip/events');

  StreamSubscription<dynamic>? _eventSub;
  final _pipModeController = StreamController<bool>.broadcast();

  bool _isInPiP   = false;
  bool _supported = false;

  /// Whether the device supports native PiP.
  bool get isSupported => _supported;

  /// Whether PiP is currently active.
  bool get isInPiP => _isInPiP;

  /// Emits `true` when entering PiP, `false` when leaving.
  Stream<bool> get pipModeStream => _pipModeController.stream;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Check device PiP support. Call once during initialisation.
  Future<void> checkSupport() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      _supported = await _channel.invokeMethod<bool>('isSupported') ?? false;
      debugPrint('$_tag isSupported=$_supported');
    } catch (e) {
      debugPrint('$_tag checkSupport error: $e');
    }
  }

  /// Configure PiP with the remote stream ID and aspect ratio.
  ///
  /// [remoteStreamId] — the `MediaStream.id` of the remote video track.
  ///   On iOS, this is used to locate the `RTCVideoTrack` inside the native
  ///   `FlutterWebRTCPlugin` registry and bind it to the PiP content view.
  ///
  /// [aspectRatioX], [aspectRatioY] — rational aspect ratio of the video
  ///   (e.g. 9 and 16 for portrait video calls).
  Future<void> setup({
    required String remoteStreamId,
    int aspectRatioX = 9,
    int aspectRatioY = 16,
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('setup', {
        'remoteStreamId': remoteStreamId,
        'aspectRatioX':   aspectRatioX,
        'aspectRatioY':   aspectRatioY,
      });
      _startListening();
      debugPrint('$_tag setup done — stream=$remoteStreamId '
          'ratio=$aspectRatioX:$aspectRatioY');
    } catch (e) {
      debugPrint('$_tag setup error: $e');
    }
  }

  /// Programmatically enter PiP mode.
  ///
  /// On Android this calls `enterPictureInPictureMode()`; the OS also calls
  /// this automatically via `onUserLeaveHint` when [setup] used autoEnter.
  /// On iOS this calls `[pipController startPictureInPicture]`.
  Future<void> enterPiP() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('enterPiP');
      debugPrint('$_tag enterPiP requested');
    } catch (e) {
      debugPrint('$_tag enterPiP error: $e');
    }
  }

  /// Exit PiP and restore the full app.
  Future<void> exitPiP() async {
    if (!_supported || !_isInPiP) return;
    try {
      await _channel.invokeMethod('exitPiP');
      debugPrint('$_tag exitPiP requested');
    } catch (e) {
      debugPrint('$_tag exitPiP error: $e');
    }
  }

  /// Release all resources. Call when the call ends.
  Future<void> dispose() async {
    await _eventSub?.cancel();
    _eventSub = null;
    _isInPiP = false;
    if (!_pipModeController.isClosed) await _pipModeController.close();
    if (!_supported) return;
    try {
      await _channel.invokeMethod('dispose');
    } catch (e) {
      debugPrint('$_tag dispose error: $e');
    }
  }

  // ── Private ───────────────────────────────────────────────────────────────

  void _startListening() {
    _eventSub ??= _events.receiveBroadcastStream().listen(
      (dynamic event) {
        final isInPiP = event as bool;
        _isInPiP = isInPiP;
        debugPrint('$_tag pipModeChanged → isInPiP=$isInPiP');
        if (!_pipModeController.isClosed) _pipModeController.add(isInPiP);
      },
      onError: (dynamic e) => debugPrint('$_tag event error: $e'),
    );
  }
}
```

---

### 4.2 Modified: `lib/src/tringup_call_shell.dart`

Add the following changes. The diff shows only the relevant sections; everything else remains unchanged.

**Add import at the top:**
```dart
import 'pip/tringup_pip_manager.dart';
```

**Modify `_TringupCallShellState`** — add `_pip` field and video-call tracking:

```dart
class _TringupCallShellState extends State<TringupCallShell>
    with WidgetsBindingObserver {   // ← ADD WidgetsBindingObserver mixin

  OverlayEntry? _callScreenEntry;
  _ThumbnailOverlay? _thumbnail;

  // ── PiP ──────────────────────────────────────────────────────────────────
  final _pip = TringupPiPManager();
  bool _videoCallActive = false;
  String? _remoteStreamId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);   // ← ADD
    _pip.checkSupport();                          // ← ADD
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // ← ADD
    _pip.dispose();                               // ← ADD
    _removeCallScreen();
    _removeThumbnail();
    super.dispose();
  }

  // Called by OS when user presses Home during a video call.
  // Android-only; on iOS the user triggers PiP via the expand button in the
  // call screen or it enters automatically via autoEnterEnabled.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive && _videoCallActive) {
      // On Android: native side already enters PiP via onUserLeaveHint.
      // On iOS: explicitly request PiP here for reliability.
      if (Platform.isIOS) _pip.enterPiP();
    }
    if (state == AppLifecycleState.resumed && _pip.isInPiP) {
      _pip.exitPiP();
    }
  }
```

**Add a new BlocListener inside `build()` for video-call tracking:**

Inside the `MultiBlocListener.listeners` list, add after `_lockscreenListener()`:

```dart
        _videoPiPListener(),  // ← ADD
```

**Add the new listener method:**

```dart
  /// Tracks video-call state and sets up / tears down PiP accordingly.
  BlocListener<CallBloc, CallState> _videoPiPListener() {
    return BlocListener<CallBloc, CallState>(
      listenWhen: (prev, curr) {
        // Re-evaluate when active calls change or remote streams change.
        final prevCall = prev.activeCalls.isEmpty ? null : prev.activeCalls.current;
        final currCall = curr.activeCalls.isEmpty ? null : curr.activeCalls.current;
        return prevCall?.video       != currCall?.video
            || prevCall?.callId      != currCall?.callId
            || prevCall?.remoteStream?.id != currCall?.remoteStream?.id
            || (prev.activeCalls.length != curr.activeCalls.length);
      },
      listener: (context, state) async {
        if (state.activeCalls.isEmpty) {
          // Call ended — tear down PiP.
          _videoCallActive = false;
          _remoteStreamId  = null;
          await _pip.dispose();
          return;
        }

        final activeCall = state.activeCalls.current;
        final isVideo    = activeCall.video;
        final streamId   = activeCall.remoteStream?.id;

        if (!isVideo || streamId == null) {
          _videoCallActive = false;
          return;
        }

        // Video call is active and we have a remote stream.
        if (!_videoCallActive || streamId != _remoteStreamId) {
          _videoCallActive = true;
          _remoteStreamId  = streamId;
          await _pip.setup(
            remoteStreamId: streamId,
            aspectRatioX: 9,
            aspectRatioY: 16,
          );
        }
      },
    );
  }
```

**Also expose `_pip` to `_CallScreenOverlayContent`** so the call screen can listen to PiP mode changes. Modify `_showCallScreen`:

```dart
  void _showCallScreen(BuildContext context, CallBloc callBloc) {
    // ... existing overlay lookup code ...
    final entry = OverlayEntry(
      builder: (entryCtx) {
        return BlocProvider<CallBloc>.value(
          value: callBloc,
          child: _CallScreenOverlayContent(
            callBloc:      callBloc,
            onMinimise:    () => callBloc.add(const CallScreenEvent.didPop()),
            customBuilder: customBuilder,
            callTheme:     widget.callTheme,
            pipManager:    _pip,            // ← ADD
          ),
        );
      },
    );
    // ... rest unchanged ...
  }
```

**Update `_CallScreenOverlayContent`** to accept `pipManager`:

```dart
class _CallScreenOverlayContent extends StatefulWidget {
  const _CallScreenOverlayContent({
    required this.callBloc,
    required this.onMinimise,
    this.customBuilder,
    this.callTheme,
    this.pipManager,         // ← ADD
  });

  final TringupPiPManager? pipManager;  // ← ADD
  // ... rest unchanged ...
}
```

---

### 4.3 Modified: `lib/src/default_call_screen.dart`

**Add import:**
```dart
import 'pip/tringup_pip_manager.dart';
```

**Add `pipManager` parameter to `TringupDefaultCallScreen`:**
```dart
class TringupDefaultCallScreen extends StatefulWidget {
  const TringupDefaultCallScreen({
    super.key,
    required this.info,
    required this.actions,
    this.localStream,
    this.localVideo = false,
    this.mirrorLocalVideo = true,
    this.remoteStream,
    this.remoteVideo = false,
    this.pipManager,         // ← ADD
  });

  final TringupPiPManager? pipManager;  // ← ADD
  // ... rest unchanged ...
}
```

**Add PiP state to `_TringupDefaultCallScreenState`:**
```dart
class _TringupDefaultCallScreenState extends State<TringupDefaultCallScreen> {
  Timer? _timer;
  bool _isInPiP = false;
  StreamSubscription<bool>? _pipSub;

  // ... existing PiP drag fields ...

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    // Subscribe to native PiP mode changes.
    _pipSub = widget.pipManager?.pipModeStream.listen((inPiP) {
      if (mounted) setState(() => _isInPiP = inPiP);
    });
  }

  @override
  void dispose() {
    _pipSub?.cancel();
    _timer?.cancel();
    super.dispose();
  }
```

**Add PiP-mode layout at the top of `build()`:**
```dart
  @override
  Widget build(BuildContext context) {
    // ── PiP mode: show ONLY remote video, no chrome ──────────────────────
    // On Android the Activity is resized by the OS into the floating window;
    // Flutter continues rendering so we just strip the controls.
    // On iOS this branch is reached briefly during the PiP animation.
    if (_isInPiP) {
      final hasRemoteVideo = widget.remoteVideo && widget.remoteStream != null;
      return Scaffold(
        backgroundColor: Colors.black,
        body: hasRemoteVideo
            ? RTCStreamView(stream: widget.remoteStream)
            : const ColoredBox(color: Colors.black),
      );
    }

    // Normal full-screen call layout below ...
    // ... rest of existing build() unchanged ...
```

**Pass `pipManager` from `_CallScreenOverlayContentState.build()`** where `TringupDefaultCallScreen` is constructed:

```dart
            final scaffold = TringupDefaultCallScreen(
              info:          info,
              actions:       actions,
              localStream:   activeCall.localStream,
              localVideo:    activeCall.localVideo,
              remoteStream:  activeCall.remoteStream,
              remoteVideo:   activeCall.remoteVideo,
              pipManager:    widget.pipManager,    // ← ADD
            );
```

---

### 4.4 Modified: `lib/tringup_call.dart` (barrel)

Add the export so host apps can reference `TringupPiPManager` if needed:

```dart
export 'src/pip/tringup_pip_manager.dart';
```

---

## 5. Phase 2 — Android Native (host app)

### 5.1 `android/app/src/main/AndroidManifest.xml`

Add **one attribute** to the `<activity>` element:

```xml
<activity
    android:name=".MainActivity"
    android:supportsPictureInPicture="true"    ← ADD THIS
    android:configChanges="screenSize|smallestScreenSize|screenLayout|orientation|..."
    ...
```

The `configChanges` already includes `screenSize|smallestScreenSize` in your manifest — no change needed there.

---

### 5.2 `android/app/src/main/kotlin/com/criteriontech/corncallnew/MainActivity.kt`

Replace the current file content with the following (preserves all existing functionality and adds PiP support):

```kotlin
package com.criteriontech.corncallnew

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    // ── Channels ─────────────────────────────────────────────────────────────
    private val activityChannel = "com.tringup/activity"
    private val pipChannel      = "com.tringup/pip"
    private val pipEventChannel = "com.tringup/pip/events"

    // ── PiP state ─────────────────────────────────────────────────────────────
    private var pipEventSink: EventChannel.EventSink? = null
    private var pipAspectX: Int = 9
    private var pipAspectY: Int = 16
    private var pipReady:   Boolean = false   // true after setup() called

    // ── FlutterEngine setup ───────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerActivityChannel(flutterEngine)
        registerPipChannel(flutterEngine)
        registerPipEventChannel(flutterEngine)
    }

    // ── Activity channel (existing) ───────────────────────────────────────────

    private fun registerActivityChannel(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, activityChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "moveTaskToBack" -> {
                        moveTaskToBack(true)
                        result.success(null)
                    }
                    "setShowWhenLocked" -> {
                        val enable = call.argument<Boolean>("enable") ?: false
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                            setShowWhenLocked(enable)
                            setTurnScreenOn(enable)
                        } else {
                            @Suppress("DEPRECATION")
                            if (enable) {
                                window.addFlags(
                                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                                )
                            } else {
                                window.clearFlags(
                                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                                )
                            }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ── PiP method channel ────────────────────────────────────────────────────

    private fun registerPipChannel(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, pipChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "isSupported" -> {
                        val supported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                        result.success(supported)
                    }

                    "setup" -> {
                        // remoteStreamId is informational on Android
                        // (Flutter TextureView keeps rendering; no native binding needed).
                        pipAspectX = call.argument<Int>("aspectRatioX") ?: 9
                        pipAspectY = call.argument<Int>("aspectRatioY") ?: 16
                        pipReady   = true
                        applyPipParams()
                        result.success(null)
                    }

                    "enterPiP" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && pipReady) {
                            val params = buildPipParams()
                            enterPictureInPictureMode(params)
                            result.success(null)
                        } else {
                            result.success(null) // no-op on unsupported devices
                        }
                    }

                    "exitPiP" -> {
                        // On Android there is no API to programmatically exit PiP —
                        // the user taps the expand button or switches back to the app.
                        // Calling moveTaskToBack(false) brings the app forward.
                        moveTaskToBack(false)
                        result.success(null)
                    }

                    "dispose" -> {
                        pipReady = false
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // ── PiP event channel ─────────────────────────────────────────────────────

    private fun registerPipEventChannel(engine: FlutterEngine) {
        EventChannel(engine.dartExecutor.binaryMessenger, pipEventChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    pipEventSink = sink
                }
                override fun onCancel(args: Any?) {
                    pipEventSink = null
                }
            })
    }

    // ── PiP lifecycle callbacks ───────────────────────────────────────────────

    /**
     * Called when the user presses Home during an active call.
     * Entering PiP here prevents the app from going fully to the background.
     */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && pipReady) {
            enterPictureInPictureMode(buildPipParams())
        }
    }

    /**
     * Called by the OS when PiP mode changes (entering or leaving the floating window).
     * Sends the new state to Flutter via EventChannel.
     */
    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        runOnUiThread {
            pipEventSink?.success(isInPictureInPictureMode)
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun buildPipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(pipAspectX, pipAspectY))

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+: auto-enter PiP on home press (no onUserLeaveHint needed).
            builder.setAutoEnterEnabled(true)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Android 13+: hide navigation controls inside PiP window.
            builder.setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }

    /** Apply params to the activity so the OS knows this screen supports PiP. */
    private fun applyPipParams() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            setPictureInPictureParams(buildPipParams())
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
```

---

## 6. Phase 3 — iOS Native (host app)

### 6.1 `ios/Runner/Info.plist`

Ensure the following keys exist (add if missing):

```xml
<key>UIBackgroundModes</key>
<array>
    <string>voip</string>
    <string>audio</string>
    <!-- add this if not present: -->
    <string>video-call-pip</string>   <!-- not a real key — just voip+audio is enough -->
</array>
```

> **Note**: `voip` and `audio` background modes are required. iOS 15.4+ PiP for video calls does not need a separate background mode key — `voip` is sufficient.

---

### 6.2 New file: `ios/Runner/TringupPiPHandler.swift`

```swift
import AVKit
import Flutter
import WebRTC

/// Manages AVPictureInPictureController for active video calls.
///
/// Requires iOS 15.4+ (AVPictureInPictureController.ContentSource activeVideoCallSourceView).
/// On older iOS the handler no-ops gracefully.
@available(iOS 15.4, *)
class TringupPiPHandler: NSObject,
                         AVPictureInPictureControllerDelegate,
                         AVPictureInPictureVideoCallViewController.ContentDelegate {

    // ── Channel wiring ────────────────────────────────────────────────────────
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel:  FlutterEventChannel?
    private var eventSink:     FlutterEventSink?

    // ── PiP state ─────────────────────────────────────────────────────────────
    private var pipController:  AVPictureInPictureController?
    private var pipContentVC:   AVPictureInPictureVideoCallViewController?
    private var rtcVideoView:   RTCMTLVideoView?
    private var boundTrack:     RTCVideoTrack?
    private var preferredWidth:  CGFloat = 360
    private var preferredHeight: CGFloat = 640

    // ── Registration ──────────────────────────────────────────────────────────

    /// Call from AppDelegate.application(_:didFinishLaunchingWithOptions:)
    /// after the Flutter engine is created.
    func register(with registrar: FlutterPluginRegistrar) {
        methodChannel = FlutterMethodChannel(
            name: "com.tringup/pip",
            binaryMessenger: registrar.messenger()
        )
        methodChannel?.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }

        eventChannel = FlutterEventChannel(
            name: "com.tringup/pip/events",
            binaryMessenger: registrar.messenger()
        )
        eventChannel?.setStreamHandler(self)
    }

    // ── MethodCall handling ───────────────────────────────────────────────────

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        case "isSupported":
            if #available(iOS 15.4, *) {
                result(AVPictureInPictureController.isPictureInPictureSupported())
            } else {
                result(false)
            }

        case "setup":
            guard let args      = call.arguments as? [String: Any],
                  let streamId  = args["remoteStreamId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "remoteStreamId required", details: nil))
                return
            }
            let aspectX = args["aspectRatioX"] as? CGFloat ?? 9
            let aspectY = args["aspectRatioY"] as? CGFloat ?? 16
            preferredWidth  = 360 * (aspectX / aspectY)   // scale to aspect
            preferredHeight = 360

            setup(remoteStreamId: streamId)
            result(nil)

        case "enterPiP":
            pipController?.startPictureInPicture()
            result(nil)

        case "exitPiP":
            pipController?.stopPictureInPicture()
            result(nil)

        case "dispose":
            tearDown()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // ── PiP Setup ─────────────────────────────────────────────────────────────

    private func setup(remoteStreamId: String) {
        tearDown()

        // 1. Find the RTCVideoTrack from flutter_webrtc's plugin registry.
        guard let track = findVideoTrack(streamId: remoteStreamId) else {
            print("[TringupPiP] Could not find video track for stream: \(remoteStreamId)")
            return
        }

        // 2. Create a native RTCMTLVideoView and bind the track.
        let videoView = RTCMTLVideoView(frame: .zero)
        videoView.videoContentMode = .scaleAspectFill
        track.add(videoView)
        self.rtcVideoView = videoView
        self.boundTrack   = track

        // 3. Create the AVPictureInPictureVideoCallViewController whose .view
        //    is what the OS shows inside the PiP floating window.
        let contentVC = AVPictureInPictureVideoCallViewController()
        contentVC.preferredContentSize = CGSize(width: preferredWidth, height: preferredHeight)
        contentVC.view.backgroundColor = .black
        contentVC.view.addSubview(videoView)

        videoView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: contentVC.view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: contentVC.view.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: contentVC.view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: contentVC.view.bottomAnchor),
        ])
        self.pipContentVC = contentVC

        // 4. Create AVPictureInPictureController with the video-call content source.
        //    sourceView: the Flutter root view — used for the zoom animation.
        guard let sourceView = UIApplication.shared.keyWindow?.rootViewController?.view else {
            print("[TringupPiP] Cannot find root view for PiP source")
            return
        }

        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: contentVC
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.pipController = controller

        print("[TringupPiP] PiP controller ready for stream: \(remoteStreamId)")
    }

    private func tearDown() {
        pipController?.stopPictureInPicture()
        pipController = nil
        boundTrack?.remove(rtcVideoView!)
        rtcVideoView = nil
        boundTrack   = nil
        pipContentVC = nil
    }

    // ── RTCVideoTrack lookup ──────────────────────────────────────────────────

    /// Locate the remote video track from flutter_webrtc's internal peer
    /// connection map using the MediaStream ID provided by Flutter.
    ///
    /// flutter_webrtc stores peer connections in `FlutterWebRTCPlugin`.
    /// Access pattern: iterate peerConnections → find stream ID → get video track.
    private func findVideoTrack(streamId: String) -> RTCVideoTrack? {
        // FlutterWebRTCPlugin is registered as a singleton.
        // Access via Objective-C runtime since Swift modules differ per version.
        guard let pluginClass = NSClassFromString("FlutterWebRTCPlugin") as? NSObject.Type,
              let plugin = pluginClass.value(forKey: "sharedSingleton") as? NSObject else {
            print("[TringupPiP] FlutterWebRTCPlugin not found via runtime")
            return findVideoTrackFallback()
        }

        // plugin.peerConnections: [String: RTCPeerConnection]
        guard let pcs = plugin.value(forKey: "peerConnections") as? [String: AnyObject] else {
            return findVideoTrackFallback()
        }

        for (_, pc) in pcs {
            guard let rtcPC = pc as? RTCPeerConnection else { continue }
            for receiver in rtcPC.receivers {
                guard let track = receiver.track as? RTCVideoTrack else { continue }
                // Match by stream ID: each receiver has associated stream IDs.
                let streamIds = receiver.streamIds
                if streamIds.contains(streamId) || track.trackId.contains(streamId) {
                    return track
                }
            }
        }
        return nil
    }

    /// Fallback: return the first active remote video track found in any PC.
    private func findVideoTrackFallback() -> RTCVideoTrack? {
        guard let pluginClass = NSClassFromString("FlutterWebRTCPlugin") as? NSObject.Type,
              let plugin = pluginClass.value(forKey: "sharedSingleton") as? NSObject,
              let pcs = plugin.value(forKey: "peerConnections") as? [String: AnyObject] else {
            return nil
        }
        for (_, pc) in pcs {
            guard let rtcPC = pc as? RTCPeerConnection else { continue }
            for receiver in rtcPC.receivers {
                if let track = receiver.track as? RTCVideoTrack, track.isEnabled {
                    print("[TringupPiP] Using fallback track: \(track.trackId)")
                    return track
                }
            }
        }
        return nil
    }

    // ── AVPictureInPictureControllerDelegate ──────────────────────────────────

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        eventSink?(true)
        print("[TringupPiP] PiP started")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        eventSink?(false)
        print("[TringupPiP] PiP stopped")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        print("[TringupPiP] PiP failed: \(error.localizedDescription)")
        eventSink?(false)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // Bring app to foreground.
        completionHandler(true)
    }
}

// ── FlutterStreamHandler ──────────────────────────────────────────────────────

@available(iOS 15.4, *)
extension TringupPiPHandler: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
```

---

### 6.3 Modified: `ios/Runner/AppDelegate.swift`

Find the section where the Flutter engine is configured (typically `application(_:didFinishLaunchingWithOptions:)`) and register the PiP handler.

Add near the top of the class:
```swift
private var pipHandler: AnyObject?   // AnyObject to avoid @available(iOS 15.4) on class property
```

Inside `application(_:didFinishLaunchingWithOptions:)`, after `GeneratedPluginRegistrant.register(with: self)`:
```swift
// ── PiP handler registration ───────────────────────────────────────────
if #available(iOS 15.4, *) {
    let handler = TringupPiPHandler()
    handler.register(with: self.registrar(forPlugin: "TringupPiPHandler")!)
    self.pipHandler = handler
}
```

> **Note**: If `AppDelegate` does not have a `registrar(forPlugin:)` call available, use the `FlutterEngine`'s registrar directly:
> ```swift
> handler.register(with: flutterEngine.registrar(forPlugin: "TringupPiPHandler"))
> ```

---

## 7. Full Data-Flow Diagram

### Android — user presses Home during video call

```
User presses Home
       │
       ▼
MainActivity.onUserLeaveHint()
       │
       ▼  (pipReady == true, Android O+)
enterPictureInPictureMode(PictureInPictureParams)
       │
       ▼
OS resizes Activity to floating window
Flutter TextureView keeps rendering WebRTC video  ← video continues!
       │
       ▼
onPictureInPictureModeChanged(true)
       │
       ▼
EventChannel → pipEventSink.success(true)
       │
       ▼
TringupPiPManager.pipModeStream emits true
       │
       ▼
DefaultCallScreen._isInPiP = true
       │
       ▼
build() returns: Scaffold(body: RTCStreamView(remoteStream))
Controls hidden. Clean PiP layout.
```

### iOS — user presses Home during video call

```
TringupCallShell.didChangeAppLifecycleState(inactive)
       │
       ▼
_pip.enterPiP()
       │  MethodChannel 'enterPiP'
       ▼
TringupPiPHandler.pipController.startPictureInPicture()
       │
       ▼
AVPictureInPictureController presents PiP window
  content: RTCMTLVideoView bound to remote RTCVideoTrack
  source:  Flutter root UIView (for zoom animation)
       │
       ▼
delegate: pictureInPictureControllerWillStartPictureInPicture
       │
       ▼
EventChannel → eventSink(true)
       │
       ▼
TringupPiPManager.pipModeStream emits true
Flutter UI → DefaultCallScreen shows video-only (though app is backgrounded)
```

---

## 8. Testing Checklist

### Android

- [ ] `android:supportsPictureInPicture="true"` present in manifest
- [ ] Build on physical Android device (API 26+; PiP does not work on emulator)
- [ ] Start a **video call** (not audio) between two devices
- [ ] Press Home → app shrinks into PiP floating window
- [ ] Remote video continues playing in PiP window
- [ ] No control buttons visible in PiP
- [ ] Tap PiP window → app restores to full screen with controls
- [ ] Tap ✕ in PiP window → call ends and PiP dismisses
- [ ] Rotate device while in PiP → video maintains aspect ratio
- [ ] Android 12+ device: auto-enter PiP on swipe-up gesture

### iOS

- [ ] Physical iOS 15.4+ device (Simulator does not support PiP)
- [ ] `voip` in `UIBackgroundModes` in Info.plist
- [ ] WebRTC framework linked correctly (flutter_webrtc)
- [ ] Start a video call → remote video visible
- [ ] Press Home → PiP window appears with remote video
- [ ] Remote video continues in PiP
- [ ] `FlutterWebRTCPlugin.sharedSingleton` accessible via Obj-C runtime
- [ ] Tap PiP → app restores
- [ ] Call ends in PiP → PiP window dismisses

### Both platforms

- [ ] Audio-only call → PiP does NOT activate (guard `_videoCallActive`)
- [ ] Call ends while in PiP → `_pip.dispose()` called, PiP exits
- [ ] App killed from recents while in PiP → handled gracefully
- [ ] Back-to-back calls work (PiP teardown on call end, new setup on next)

---

## 9. Known Limitations & Edge Cases

| Issue | Notes |
|---|---|
| **Android emulator** | PiP is not supported; always test on physical hardware |
| **iOS < 15.4** | `activeVideoCallSourceView` API not available; handler returns `isSupported=false` gracefully |
| **iOS Simulator** | `AVPictureInPictureController.isPictureInPictureSupported()` returns false |
| **`FlutterWebRTCPlugin` internal API** | Access via Obj-C runtime is fragile; if `flutter_webrtc` renames its class or property, the `findVideoTrack` lookup fails → falls back to first active track |
| **Group calls** | Only the `activeCalls.current` stream is used; extend `_videoPiPListener` if multi-party video is needed |
| **Android 12 auto-enter** | `setAutoEnterEnabled(true)` means PiP activates on ANY navigation away, not only Home. Add a back-navigation guard if needed |
| **iOS `keyWindow` deprecation** | `UIApplication.shared.keyWindow` is deprecated in iOS 15; replace with `UIApplication.shared.connectedScenes.first?.windows.first` for iOS 16+ |
| **Aspect ratio mismatch** | If remote video is landscape (16:9), pass `aspectRatioX=16, aspectRatioY=9` from the video call metadata |
| **CallKit + PiP on iOS** | If the app uses CallKit fullscreen (incoming call UI), the PiP activation should be deferred until `CXCallObserver` reports `call.hasConnected == true` |

---

## Summary: Complete File Change List

```
packages/tringup_call/
  lib/src/pip/tringup_pip_manager.dart     ← CREATE
  lib/src/tringup_call_shell.dart          ← MODIFY (WidgetsBindingObserver, TringupPiPManager, _videoPiPListener)
  lib/src/default_call_screen.dart         ← MODIFY (pipManager param, _isInPiP state, PiP layout branch)
  lib/tringup_call.dart                    ← MODIFY (export pip manager)

android/
  app/src/main/AndroidManifest.xml                                   ← MODIFY (supportsPictureInPicture)
  app/src/main/kotlin/com/criteriontech/corncallnew/MainActivity.kt  ← MODIFY (PiP channel + lifecycle)

ios/
  Runner/TringupPiPHandler.swift           ← CREATE
  Runner/AppDelegate.swift                 ← MODIFY (register TringupPiPHandler)
  Runner/Info.plist                        ← VERIFY (voip + audio background modes)
```

Total files: **8** (2 new, 6 modified).
