import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:logging/logging.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
final _logger = Logger('LiveKitRoomManager');

/// Manages a single LiveKit room connection for one call leg.
class LiveKitRoomManager {
  lk.Room? _room;
  lk.LocalAudioTrack? _audioTrack;
  lk.LocalVideoTrack? _videoTrack;
  lk.LocalVideoTrack? _screenShareTrack;

  lk.Room? get room => _room;

  bool get isConnected => _room != null;

  Future<void> connect({
    required String url,
    required String token,
    required bool videoEnabled,
    bool audioEnabled = true,
  }) async {
    if (_room != null) return;

    final room = lk.Room();
    _room = room;

    try {
      await room.connect(
        url,
        token,
        roomOptions: const lk.RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultAudioPublishOptions: lk.AudioPublishOptions(name: 'microphone'),
          defaultVideoPublishOptions: lk.VideoPublishOptions(simulcast: true),
        ),
      );

      // room.connect() can return while the room is still in CONNECTING state
      // (signaling WebSocket ready but WebRTC peer connection not yet established).
      // Publishing tracks before ConnectionState.connected throws
      // [UnexpectedConnectionState].  Poll until connected or timeout.
      const _pollInterval = Duration(milliseconds: 100);
      const _timeout     = Duration(seconds: 15);
      final deadline     = DateTime.now().add(_timeout);
      while (room.connectionState != lk.ConnectionState.connected) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException(
            'LiveKit room did not reach connected state within '
            '${_timeout.inSeconds}s (state: ${room.connectionState})',
          );
        }
        await Future.delayed(_pollInterval);
      }
      _logger.info('LiveKit room connected: ${room.name} '
          'state=${room.connectionState}');

      if (audioEnabled) {
        _audioTrack = await lk.LocalAudioTrack.create(const lk.AudioCaptureOptions());
        await room.localParticipant?.publishAudioTrack(_audioTrack!);
      }

      if (videoEnabled) {
        _videoTrack = await lk.LocalVideoTrack.createCameraTrack(const lk.CameraCaptureOptions());
        await room.localParticipant?.publishVideoTrack(_videoTrack!);
      }

      _logger.info('Tracks published to LiveKit room: ${room.name}');
    } catch (e, s) {
      _logger.warning('Failed to connect to LiveKit room', e, s);
      await disconnect();
      rethrow;
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
    } catch (e) {
      _logger.warning('LiveKitRoomManager.disconnect error: $e');
    } finally {
      _room = null;
      _audioTrack = null;
      _videoTrack = null;
      _screenShareTrack = null;
    }
  }
}
