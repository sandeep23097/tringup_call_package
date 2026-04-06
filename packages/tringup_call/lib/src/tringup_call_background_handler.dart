import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssl_certificates/ssl_certificates.dart';
import 'package:webtrit_callkeep/webtrit_callkeep.dart';
import 'package:webtrit_phone/data/data.dart';
import 'package:webtrit_phone/features/call/services/push_notification_isolate_manager.dart';

import 'stubs/stub_call_logs_repository.dart';

// ---------------------------------------------------------------------------
// NOTE: The @pragma('vm:entry-point') callback MUST live in the host app,
// not in this package. Dart's PluginUtilities.getCallbackHandle only works
// reliably for top-level functions defined in the app's own Dart code.
// Functions inside packages are not guaranteed to have stable callback handles.
//
// Host app usage:
//
// ```dart
// // In main.dart or fcm_service.dart (host app — NOT inside a package):
// @pragma('vm:entry-point')
// Future<void> tringupCallPushNotificationSyncCallback(
//   CallkeepPushNotificationSyncStatus status,
// ) async {
//   await TringupCallBackgroundHandler.handlePushNotificationSync(status);
// }
//
// // In main():
// await TringupCallBackgroundHandler.setup(
//   onSync: tringupCallPushNotificationSyncCallback,
// );
// ```
// ---------------------------------------------------------------------------

PushNotificationIsolateManager? _tringupCallManager;

/// Entry point for background push-notification handling.
class TringupCallBackgroundHandler {
  TringupCallBackgroundHandler._();

  static const _kCoreUrlKey = 'core-url';
  static const _kTenantIdKey = 'tenant-id';
  static const _kTokenKey = 'token';
  static const _kUserIdKey = 'user-id';

  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  // ── Main-isolate setup (call once before runApp) ──────────────────────────

  /// Register the background push-notification Dart callback with Android.
  ///
  /// [onSync] MUST be a top-level function defined in the **host app** and
  /// annotated with `@pragma('vm:entry-point')`. It should call
  /// [handlePushNotificationSync]. See the file comment above for an example.
  ///
  /// Must be called **once** from `main()` before `runApp()`.
  /// On iOS or web this is a no-op.
  static Future<void> setup({
    required CallKeepPushNotificationSyncStatusHandle onSync,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;
    if (kDebugMode) debugPrint('[TringupCallBgHandler] setup — registering callback');
    try {
      AndroidCallkeepServices.backgroundPushNotificationBootstrapService
          .initializeCallback(onSync);

      // Explicitly set false so the background isolate is NOT launched while
      // the app is in the foreground. If omitted, some Android versions default
      // to launching the isolate even when the app is open, which creates a
      // second SignalingManager that competes with the foreground CallBloc's
      // WebSocket and breaks the incoming-call overlay.
      await AndroidCallkeepServices.backgroundPushNotificationBootstrapService
          .configurePushNotificationSignalingService(
        launchBackgroundIsolateEvenIfAppIsOpen: false,
      );
      if (kDebugMode) debugPrint('[TringupCallBgHandler] setup — done');
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[TringupCallBgHandler] setup ERROR: $e');
        debugPrint(st.toString());
      }
    }
  }

  // ── Background-isolate sync handler (called by the host app's callback) ───

  /// Handles a sync status change from the Android background push service.
  ///
  /// Call this from the `@pragma('vm:entry-point')` function in the host app.
  static Future<void> handlePushNotificationSync(
    CallkeepPushNotificationSyncStatus status,
  ) async {
    if (kDebugMode) {
      debugPrint('[TringupCallBgHandler] handlePushNotificationSync status=$status');
    }
    if (_tringupCallManager == null) {
      final storage = await SecureStorageImpl.init();
      _tringupCallManager = PushNotificationIsolateManager(
        callLogsRepository: StubCallLogsRepository(),
        callkeep: BackgroundPushNotificationService(),
        storage: storage,
        certificates: TrustedCertificates.empty,
      );
    }
    switch (status) {
      case CallkeepPushNotificationSyncStatus.synchronizeCallStatus:
        await _tringupCallManager?.sync();
      case CallkeepPushNotificationSyncStatus.releaseResources:
        await _tringupCallManager?.close();
        _tringupCallManager = null;
    }
  }

  // ── Credential persistence (call after login) ─────────────────────────────

  /// Persist call credentials to secure storage so the background isolate
  /// can read them when a push notification arrives.
  ///
  /// Call this whenever the token changes (login, token refresh, logout).
  static Future<void> saveCredentials({
    required String serverUrl,
    required String tenantId,
    required String token,
    required String userId,
  }) async {
    if (kDebugMode) {
      debugPrint('[TringupCallBgHandler] saveCredentials — '
          'serverUrl=$serverUrl tenantId=$tenantId userId=$userId '
          'token=${token.isEmpty ? "<empty>" : "${token.substring(0, token.length.clamp(0, 12))}..."}');
    }
    try {
      // user-id MUST be written first — SecureStorageImpl clears its cache if
      // this key is absent, wiping out the other values.
      await _storage.write(key: _kUserIdKey, value: userId);
      await _storage.write(key: _kCoreUrlKey, value: serverUrl);
      await _storage.write(key: _kTenantIdKey, value: tenantId);
      await _storage.write(key: _kTokenKey, value: token);
    } catch (e) {
      if (kDebugMode) debugPrint('[TringupCallBgHandler] saveCredentials ERROR: $e');
    }
  }

  // ── FCM background handler helper ─────────────────────────────────────────

  /// Report an incoming call from a FCM push notification payload on Android.
  ///
  /// Call this from your FCM `onBackgroundMessage` handler when the data
  /// contains `callId`, `handleValue` (and optionally `displayName`, `hasVideo`).
  /// Shows the native incoming-call screen immediately.
  ///
  /// [groupName] — when non-null/non-empty this is a group call and the
  /// server-provided group name is used directly; the local contact-name cache
  /// is NOT consulted so the group name is never overwritten by an individual
  /// contact name.
  static Future<void> reportIncomingCall({
    required String callId,
    required String handleValue,
    String? displayName,
    bool hasVideo = false,
    String? groupName,
    String? chatId,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;
    if (callId.isEmpty || handleValue.isEmpty) {
      if (kDebugMode) {
        debugPrint('[TringupCallBgHandler] reportIncomingCall — '
            'skipped: callId or handleValue is empty');
      }
      return;
    }

    String? avatarFilePath;

    if (groupName != null && groupName.isNotEmpty) {
      // Group call — use the server-provided group name as-is.
      displayName = groupName;
      // Resolve the group chat photo from the background cache.
      if (chatId != null && chatId.isNotEmpty) {
        avatarFilePath = await _resolveGroupChatPhotoFromCache(chatId);
      }
    } else {
      // 1:1 call — resolve the local contact name and photo from cache.
      final resolvedName = await _resolveContactNameFromCache(handleValue);
      if (resolvedName != null && resolvedName.isNotEmpty) {
        displayName = resolvedName;
      }
      avatarFilePath = await _resolveContactPhotoPathFromCache(handleValue);
    }

    if (kDebugMode) {
      debugPrint('[TringupCallBgHandler] reportIncomingCall — '
          'callId=$callId handle=$handleValue displayName=$displayName '
          'hasVideo=$hasVideo avatarFilePath=$avatarFilePath');
    }
    try {
      final error = await AndroidCallkeepServices
          .backgroundPushNotificationBootstrapService
          .reportNewIncomingCall(
        callId,
        CallkeepHandle.number(handleValue),
        displayName: displayName,
        hasVideo: hasVideo,
        avatarFilePath: avatarFilePath,
      );
      if (error != null && kDebugMode) {
        debugPrint('[TringupCallBgHandler] reportIncomingCall error: $error');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[TringupCallBgHandler] reportIncomingCall EXCEPTION: $e');
        debugPrint(st.toString());
      }
    }
  }

  /// Acknowledge receipt of an incoming call to the backend.
  ///
  /// This advances the caller's state from "calling" to "ringing" (the smart
  /// ringing state feature).  Call this immediately after [reportIncomingCall]
  /// in the FCM background handler.
  ///
  /// Attempts a WebSocket-based acknowledgment first (via the signaling
  /// connection manager if it is already open).  Falls back to a REST call
  /// to `POST /api/v1/call/received` when the WebSocket is not yet available,
  /// which is the common case in the FCM background isolate.
  static Future<void> sendCallReceived({
    required String callId,
  }) async {
    if (callId.isEmpty) return;
    if (kDebugMode) {
      debugPrint('[TringupCallBgHandler] sendCallReceived callId=$callId');
    }
    try {
      final serverUrl = await _storage.read(key: _kCoreUrlKey);
      final token     = await _storage.read(key: _kTokenKey);
      final tenantId  = await _storage.read(key: _kTenantIdKey);

      if (serverUrl == null || token == null) {
        if (kDebugMode) {
          debugPrint('[TringupCallBgHandler] sendCallReceived — no credentials stored, skipping');
        }
        return;
      }

      // Build REST URL: strip trailing slash, inject tenant path if present
      final base = serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;
      final tenantPath = (tenantId != null && tenantId.isNotEmpty) ? '/tenant/$tenantId' : '';
      final uri = Uri.parse('$base$tenantPath/api/v1/call/received');

      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: '{"call_id":"$callId"}',
      ).timeout(const Duration(seconds: 8));

      if (kDebugMode) {
        debugPrint('[TringupCallBgHandler] sendCallReceived response=${response.statusCode}');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[TringupCallBgHandler] sendCallReceived ERROR: $e');
      }
    }
  }

  /// Show a missed call notification for a call that was cancelled before answer.
  ///
  /// Uses [WebtritCallkeepPlatform.reportEndCall] with [CallkeepEndCallReason.missed]
  /// which dismisses the incoming call UI and posts a missed call notification
  /// in the system call log — no extra dependencies needed.
  ///
  /// Call this from your FCM `onBackgroundMessage` handler when the data contains
  /// `type == 'missed_call'` and `callId`.
  /// Called from FCM `onBackgroundMessage` when `type == 'missed_call'`.
  ///
  /// NOTE: `WebtritCallkeepPlatform.instance.reportEndCall` (PHostApi) is NOT
  /// available in the FCM background isolate — the ForegroundService channel is
  /// only set up when the app has an Activity. Attempting to call it throws
  /// PlatformException(channel-error, ...).
  ///
  /// Missed call notification is instead handled by the background WS isolate
  /// (`PushNotificationIsolateManager`):
  ///  • If caller hangs up while WS is connected → `missed_call` event →
  ///    `_handleMissedCall` → `_callkeep.endCall()` → `PhoneConnection.declineCall()`
  ///    → `showMissedCallNotification()`.
  ///  • If caller hangs up before WS connects → empty handshake → `_handleAvoidLines`
  ///    → `getConnections()` + `_callkeep.endCall()` per connection → same path.
  ///
  /// This method is intentionally a no-op in the FCM isolate context.
  static Future<void> reportMissedCall({
    required String callId,
    required String handleValue,
    String? displayName,
  }) async {
    if (kDebugMode) {
      debugPrint('[TringupCallBgHandler] reportMissedCall — '
          'callId=$callId (no-op: WS isolate handles missed call notification)');
    }
  }

  /// Tear down the background handler (e.g. on logout).
  static Future<void> dispose() async {
    await _tringupCallManager?.close();
    _tringupCallManager = null;
  }

  // ── Background contact name resolver ──────────────────────────────────────

  /// Resolves a caller's phone number to a local contact name using the
  /// SharedPreferences cache written by ContactsDataService in the main isolate.
  ///
  /// This runs entirely in the background headless engine — no full app
  /// initialization required. SharedPreferences is the bridge between the main
  /// isolate (writes the cache) and the background isolate (reads it here).
  static Future<String?> _resolveContactNameFromCache(String phoneNumber) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheJson = prefs.getString('bg_contacts_phone_name_cache');
      if (cacheJson == null) return null;
      final map = jsonDecode(cacheJson) as Map<String, dynamic>;
      // Try exact match first
      final name = map[phoneNumber] as String?;
      if (name != null && name.isNotEmpty) return name;
      // Strip leading '+' and retry for number format variations
      final stripped = phoneNumber.startsWith('+') ? phoneNumber.substring(1) : null;
      if (stripped != null) return map[stripped] as String?;
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[TringupCallBgHandler] _resolveContactNameFromCache error: $e');
      return null;
    }
  }

  /// Resolves a group chat's photo file path from the SharedPreferences cache
  /// written by ChatsDataService._persistGroupChatBackgroundCache.
  static Future<String?> _resolveGroupChatPhotoFromCache(String chatId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheJson = prefs.getString('bg_group_chats_cache');
      if (cacheJson == null) return null;
      final map = jsonDecode(cacheJson) as Map<String, dynamic>;
      final entry = map[chatId] as Map<String, dynamic>?;
      final path = entry?['photoPath'] as String?;
      if (path == null || path.isEmpty) return null;
      if (await File(path).exists()) return path;
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[TringupCallBgHandler] _resolveGroupChatPhotoFromCache error: $e');
      return null;
    }
  }

  /// Resolves a caller's phone number to a local cached photo file path.
  /// Returns null when no photo is cached or if the file no longer exists.
  static Future<String?> _resolveContactPhotoPathFromCache(String phoneNumber) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheJson = prefs.getString('bg_contacts_phone_photo_path_cache');
      if (cacheJson == null) return null;
      final map = jsonDecode(cacheJson) as Map<String, dynamic>;
      String? path = map[phoneNumber] as String?;
      if (path == null || path.isEmpty) {
        final stripped = phoneNumber.startsWith('+') ? phoneNumber.substring(1) : null;
        if (stripped != null) path = map[stripped] as String?;
      }
      if (path == null || path.isEmpty) return null;
      if (await File(path).exists()) return path;
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[TringupCallBgHandler] _resolveContactPhotoPathFromCache error: $e');
      return null;
    }
  }
}
