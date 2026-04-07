import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
/// Manages a single LiveKit room connection for one call leg.
///
/// Create one instance per call leg (caller and callee each get their own).
/// Call [connect] once the LiveKit URL and token are available, and
/// [disconnect] when the call ends.
class LiveKitRoomManager {
  lk.Room? _room;
  lk.LocalAudioTrack? _audioTrack;
  lk.LocalVideoTrack? _videoTrack;
  lk.LocalVideoTrack? _screenShareTrack;

  lk.Room? get room => _room;

  bool get isConnected => _room != null;

  /// Connect to the LiveKit room and publish local audio/video tracks.
  Future<void> connect({
    required String url,
    required String token,
    required bool videoEnabled,
    bool audioEnabled = true,
  }) async {
    if (_room != null) return; // already connected

    final room = lk.Room();
    _room = room;

    await room.connect(
      url,
      token,
      roomOptions: const lk.RoomOptions(
        // adaptiveStream pauses subscriptions when no VideoTrackRenderer is
        // visible, which creates a deadlock with conditional rendering logic
        // (no track → no renderer → stream paused → no track). Keep it off.
        adaptiveStream: false,
        dynacast: true,
        defaultAudioPublishOptions: lk.AudioPublishOptions(
          name: 'microphone',
        ),
        defaultVideoPublishOptions: lk.VideoPublishOptions(
          simulcast: true,
        ),
      ),
    );

    // Publish microphone
    if (audioEnabled) {
      _audioTrack = await lk.LocalAudioTrack.create(const lk.AudioCaptureOptions());
      await room.localParticipant?.publishAudioTrack(_audioTrack!);
    }

    // Publish camera
    if (videoEnabled) {
      _videoTrack = await lk.LocalVideoTrack.createCameraTrack(const lk.CameraCaptureOptions());
      await room.localParticipant?.publishVideoTrack(_videoTrack!);
    }
  }

  Future<void> setMicEnabled(bool enabled) async {
    if (enabled) {
      await _audioTrack?.unmute();
    } else {
      await _audioTrack?.mute();
    }
  }

  Future<void> setCameraEnabled(bool enabled) async {
    if (_videoTrack != null) {
      if (enabled) {
        await _videoTrack!.unmute();
      } else {
        await _videoTrack!.mute();
      }
    } else if (enabled && _room != null) {
      _videoTrack = await lk.LocalVideoTrack.createCameraTrack(const lk.CameraCaptureOptions());
      await _room!.localParticipant?.publishVideoTrack(_videoTrack!);
    }
  }

  Future<void> switchCamera() async {
    if (_videoTrack == null) return;
    final cameras = await webrtc.Helper.cameras;
    if (cameras.length < 2) return;
    final current = _videoTrack!.mediaStreamTrack.getSettings()['deviceId'] as String?;
    final next = cameras.firstWhere(
      (c) => c.deviceId != current,
      orElse: () => cameras.first,
    );
    await _videoTrack!.switchCamera(next.deviceId);
  }

  Future<void> setScreenShareEnabled(bool enabled) async {
    if (enabled) {
      if (_screenShareTrack != null) return;
      _screenShareTrack = await lk.LocalVideoTrack.createScreenShareTrack(
        const lk.ScreenShareCaptureOptions(useiOSBroadcastExtension: true),
      );
      await _room?.localParticipant?.publishVideoTrack(_screenShareTrack!);
    } else {
      if (_screenShareTrack == null) return;
      // await _room?.localParticipant?.unpublishTrack(_screenShareTrack!);
      await _screenShareTrack!.stop();
      _screenShareTrack = null;
    }
  }

  Future<void> disconnect() async {
    try {
      await _screenShareTrack?.stop();
      await _videoTrack?.stop();
      await _audioTrack?.stop();
      await _room?.disconnect();
      await _room?.dispose();
    } finally {
      _room = null;
      _audioTrack = null;
      _videoTrack = null;
      _screenShareTrack = null;
    }
  }
}
