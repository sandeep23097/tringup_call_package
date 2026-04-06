import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import 'package:ssl_certificates/ssl_certificates.dart';
import 'package:webtrit_callkeep/webtrit_callkeep.dart';
import 'package:webtrit_signaling/webtrit_signaling.dart';

import 'package:webtrit_phone/common/common.dart';
import 'package:webtrit_phone/data/data.dart';
import 'package:webtrit_phone/models/models.dart';
import 'package:webtrit_phone/repositories/repositories.dart';

final _logger = Logger('PushNotificationIsolateManager');

class PushNotificationIsolateManager implements CallkeepBackgroundServiceDelegate {
  PushNotificationIsolateManager({
    required CallLogsRepository callLogsRepository,
    required BackgroundPushNotificationService callkeep,
    required SecureStorage storage,
    required TrustedCertificates certificates,
  }) : _callLogsRepository = callLogsRepository,
       _callkeep = callkeep {
    _initSignalingManager(storage, certificates);
    _callkeep.setBackgroundServiceDelegate(this);
  }

  final CallLogsRepository _callLogsRepository;
  final BackgroundPushNotificationService _callkeep;

  late final SignalingManager _signalingManager;

  void _initSignalingManager(SecureStorage storage, TrustedCertificates certificates) {
    _signalingManager = SignalingManager(
      coreUrl: storage.readCoreUrl() ?? '',
      tenantId: storage.readTenantId() ?? '',
      token: storage.readToken() ?? '',
      certificates: certificates,
      onError: _handleSignalingError,
      onHangupCall: _handleHangupCall,
      onMissedCall: _handleMissedCall,
      onUnregistered: _handleUnregisteredEvent,
      onNoActiveLines: _handleAvoidLines,
    );
  }

  Future<void> close() async {
    return _signalingManager.dispose();
  }

  // Handles the service startup. This can occur under several scenarios:
  // - Launching from an FCM isolate.
  // - User enabling the socket type.
  // - Service being restarted.
  // - Automatic start during system boot.
  Future<void> sync() async {
    _logger.info('Starting background call event service');
    return _signalingManager.launch();
  }

  void _handleHangupCall(HangupEvent event) async {
    try {
      _logger.info('Ending call: ${event.callId}');
      await _callkeep.endCall(event.callId);
    } catch (e) {
      _handleExceptions(e);
    }
  }

  void _handleMissedCall(MissedCallEvent event) async {
    try {
      _logger.info('Missed call: ${event.callId} from ${event.caller}');
      // Use _callkeep.endCall (BackgroundPushNotificationService) which routes through
      // PHostBackgroundPushNotificationIsolateApi → CallLifecycleHandler.endCall(SERVER)
      // → handleServerDecline → PhoneConnection.declineCall() → showMissedCallNotification()
      // when the connection is in RINGING state.
      // DO NOT use WebtritCallkeepPlatform.instance.reportEndCall here — that goes through
      // PHostApi → ForegroundService, which is not running in this background isolate context.
      await _callkeep.endCall(event.callId);
    } catch (e) {
      _handleExceptions(e);
    }
  }

  void _handleSignalingError(Object error, [StackTrace? stackTrace]) async {
    try {
      await _callkeep.endCalls();
    } catch (e) {
      _handleExceptions(e);
    }
  }

  void _handleAvoidLines() async {
    // Caller hung up before the background isolate connected — the server has no
    // active lines but a CallKit notification may still be ringing on-screen.
    // Calling endCall() per-connection routes through PhoneConnection.declineCall()
    // which shows the missed call notification when state == RINGING.
    // Fall back to endCalls() (tearDown, no missed notification) only if we cannot
    // enumerate connections or there are none.
    try {
      final connections = await WebtritCallkeepPlatform.instance.getConnections();
      if (connections.isNotEmpty) {
        for (final conn in connections) {
          _logger.info('No active server lines — declining ringing connection: ${conn.callId}');
          await _callkeep.endCall(conn.callId);
        }
      } else {
        await _callkeep.endCalls();
      }
    } catch (e) {
      _logger.warning('_handleAvoidLines: failed to get connections, falling back to endCalls(): $e');
      await _callkeep.endCalls();
    }
  }

  void _handleUnregisteredEvent(UnregisteredEvent event) async {
    try {
      await _callkeep.endCalls();
    } catch (e) {
      _handleExceptions(e);
    }
  }

  @override
  void performAnswerCall(String callId) async {
    // Check if the device is connected to the network only then proceed
    if (!(await _signalingManager.hasNetworkConnection())) {
      throw Exception('Not connected');
    }
  }

  @override
  void performEndCall(String callId) async {
    // Try REST API first — reliable even when the WebSocket is not connected
    // (background / killed app). Falls back to WebSocket signaling if REST fails.
    final declined = await _declineViaRestApi(callId);
    if (!declined) {
      return _signalingManager.declineCall(callId);
    }
  }

  /// POST {coreUrl}/api/v1/call/decline with Bearer token.
  /// Returns true if the server confirmed the decline (2xx), false otherwise.
  Future<bool> _declineViaRestApi(String callId) async {
    try {
      final baseUrl = _signalingManager.coreUrl.replaceAll(RegExp(r'/$'), '');
      final uri = Uri.parse('$baseUrl/api/v1/call/decline');
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..badCertificateCallback = (_, __, ___) => true; // accept self-signed in dev

      final request = await client.postUrl(uri);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${_signalingManager.token}');
      request.write(jsonEncode({'call_id': callId}));

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _logger.info('REST decline succeeded for callId=$callId: $body');
        return true;
      } else {
        _logger.warning('REST decline failed (${response.statusCode}) for callId=$callId: $body');
        return false;
      }
    } catch (e, st) {
      _logger.warning('REST decline exception for callId=$callId', e, st);
      return false;
    }
  }

  // TODO (Serdun): Rename this callback to align with naming conventions.
  @override
  Future<void> performReceivedCall(
    String callId,
    String number,
    DateTime createdTime,
    String? displayName,
    DateTime? acceptedTime,
    DateTime? hungUpTime, {
    bool video = false,
  }) async {
    NewCall call = (
      direction: CallDirection.incoming,
      number: number,
      video: video,
      username: displayName,
      createdTime: createdTime,
      acceptedTime: acceptedTime,
      hungUpTime: hungUpTime,
    );
    try {
      _logger.info('Adding call log: $callId');
      await _callLogsRepository.add(call);
    } catch (e) {
      _logger.severe('Failed to add call log', e);
    }
    return;
  }

  void _handleExceptions(Object e) {
    _logger.severe(e);
  }
}
