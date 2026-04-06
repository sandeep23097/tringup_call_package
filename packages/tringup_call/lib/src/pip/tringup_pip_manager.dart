import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _tag = '[TringupPiPManager]';

/// Manages native Picture-in-Picture lifecycle for active video calls.
///
/// - Android: wraps [enterPictureInPictureMode] via the `com.tringup/pip` MethodChannel.
///   The OS auto-enters PiP on Home press after [setup] is called.
/// - iOS 15.4+: wraps [AVPictureInPictureController] with [activeVideoCallSourceView].
///   [TringupPiPHandler.swift] in the host app binds the remote [RTCVideoTrack]
///   to an [RTCMTLVideoView] shown inside the system PiP floating window.
///
/// Usage (driven internally by [TringupCallShell]):
/// ```dart
/// await _pip.checkSupport();
/// await _pip.setup(remoteStreamId: stream.id);
/// // PiP auto-enters on Home press (Android) or app inactive (iOS).
/// // Listen to pipModeStream to rebuild UI.
/// await _pip.dispose(); // call when the video call ends
/// ```
class TringupPiPManager {
  static const _methodChannel = MethodChannel('com.tringup/pip');
  static const _eventChannel  = EventChannel('com.tringup/pip/events');

  StreamSubscription<dynamic>? _eventSub;
  final _pipModeController = StreamController<bool>.broadcast();

  bool _isInPiP   = false;
  bool _supported = false;

  /// Whether the current device supports native PiP.
  bool get isSupported => _supported;

  /// Whether native PiP is currently active.
  bool get isInPiP => _isInPiP;

  /// Emits [true] when the OS enters PiP, [false] when it exits.
  Stream<bool> get pipModeStream => _pipModeController.stream;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Query native PiP support. Must be awaited before calling [setup].
  Future<void> checkSupport() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      _supported = false;
      return;
    }
    try {
      _supported = await _methodChannel.invokeMethod<bool>('isSupported') ?? false;
      debugPrint('$_tag checkSupport → $_supported');
    } catch (e) {
      debugPrint('$_tag checkSupport error: $e');
      _supported = false;
    }
  }

  /// Configure PiP for the active video call.
  ///
  /// [remoteStreamId] is the [MediaStream.id] of the remote track.
  /// On iOS the native handler uses this to bind an [RTCMTLVideoView] to the
  /// matching [RTCVideoTrack] inside [FlutterWebRTCPlugin]'s peer-connection map.
  Future<void> setup({
    required String remoteStreamId,
    int aspectRatioX = 9,
    int aspectRatioY = 16,
  }) async {
    if (!_supported) return;
    try {
      await _methodChannel.invokeMethod<void>('setup', {
        'remoteStreamId': remoteStreamId,
        'aspectRatioX':   aspectRatioX,
        'aspectRatioY':   aspectRatioY,
      });
      _startListening();
      debugPrint('$_tag setup — stream=$remoteStreamId ratio=$aspectRatioX:$aspectRatioY');
    } catch (e) {
      debugPrint('$_tag setup error: $e');
    }
  }

  /// Programmatically request PiP entry.
  ///
  /// Android: usually not needed — the OS enters PiP automatically via
  /// [onUserLeaveHint] after [setup] arms the params.
  /// iOS: called when the app transitions to [AppLifecycleState.inactive].
  Future<void> enterPiP() async {
    if (!_supported) return;
    try {
      await _methodChannel.invokeMethod<void>('enterPiP');
      debugPrint('$_tag enterPiP requested');
    } catch (e) {
      debugPrint('$_tag enterPiP error: $e');
    }
  }

  /// Exit PiP and restore the full app view.
  Future<void> exitPiP() async {
    if (!_supported || !_isInPiP) return;
    try {
      await _methodChannel.invokeMethod<void>('exitPiP');
      debugPrint('$_tag exitPiP requested');
    } catch (e) {
      debugPrint('$_tag exitPiP error: $e');
    }
  }

  /// Release native PiP resources. Call when the video call ends.
  ///
  /// NOTE: [_pipModeController] is intentionally NOT closed here so the
  /// broadcast stream remains valid for the next call.  The shell's listener
  /// ([TringupCallShell._pipNativeSub]) can therefore stay subscribed across
  /// multiple successive calls without re-subscribing.
  Future<void> dispose() async {
    await _eventSub?.cancel();
    _eventSub = null;
    _isInPiP  = false;
    // Do NOT close _pipModeController — see doc above.
    if (!_supported) return;
    try {
      await _methodChannel.invokeMethod<void>('dispose');
      debugPrint('$_tag dispose');
    } catch (e) {
      debugPrint('$_tag dispose error: $e');
    }
  }

  // ── Private ───────────────────────────────────────────────────────────────

  void _startListening() {
    if (_eventSub != null) return; // already listening
    _eventSub = _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        final inPiP = event as bool;
        _isInPiP = inPiP;
        debugPrint('$_tag pipModeChanged → isInPiP=$inPiP');
        if (!_pipModeController.isClosed) _pipModeController.add(inPiP);
      },
      onError: (dynamic e) => debugPrint('$_tag event error: $e'),
    );
  }
}
