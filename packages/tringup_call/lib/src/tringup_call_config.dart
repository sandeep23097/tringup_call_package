import 'package:flutter/widgets.dart';
import 'tringup_call_contact.dart';
import 'tringup_call_theme.dart';

/// Resolve a display name for a call participant.
/// Return null to fall back to the raw phone number.
typedef TringupNameResolver = Future<String?> Function(TringupCallContact contact);

/// Resolve a profile photo for a call participant.
/// Return null to show the default initial-letter avatar.
typedef TringupPhotoResolver = Future<ImageProvider?> Function(TringupCallContact contact);

/// Resolve a local file path for a contact's photo, used for the system
/// incoming-call notification avatar on Android.
/// Return null when no local photo is available.
typedef TringupPhotoPathResolver = Future<String?> Function(TringupCallContact contact);

/// Resolve a local file path for a group chat's photo by [chatId], used for
/// the system incoming-call notification avatar on Android for group calls.
/// Return null when no local photo is available.
typedef TringupGroupChatPhotoPathResolver = Future<String?> Function(String chatId);

/// Configuration passed to [TringupCallWidget].
class TringupCallConfig {
  const TringupCallConfig({
    required this.serverUrl,
    required this.tenantId,
    required this.token,
    required this.userId,
    required this.phoneNumber,
    this.firstName,
    this.lastName,
    this.nameResolver,
    this.photoResolver,
    this.photoPathResolver,
    this.groupChatPhotoPathResolver,
    this.groupCallEnabled = false,
    this.iceServers,
    this.callTheme,
    this.onVoipTokenReceived,
  });

  /// Base URL of the call backend, e.g. "https://call.example.com"
  final String serverUrl;

  /// Tenant ID, e.g. "f1rIih5iS3yACprjOBbF-0"
  final String tenantId;

  /// Call JWT obtained from POST /integration/token
  final String token;

  /// Chat app's user ID (must match the userId used to issue the token)
  final String userId;

  /// User's E.164 phone number
  final String phoneNumber;

  final String? firstName;
  final String? lastName;

  /// Optional: resolve a display name from contact info.
  final TringupNameResolver? nameResolver;

  /// Optional: resolve a profile photo from contact info (for the in-app call UI).
  final TringupPhotoResolver? photoResolver;

  /// Optional: resolve a local file path for a contact's photo.
  /// Used for the Android system incoming-call notification avatar.
  /// Return null when no local photo is available.
  final TringupPhotoPathResolver? photoPathResolver;

  /// Optional: resolve a local file path for a group chat's photo by chatId.
  /// Used for the Android system incoming-call notification avatar for group calls.
  /// Return null when no local photo is available.
  final TringupGroupChatPhotoPathResolver? groupChatPhotoPathResolver;

  /// Enable group call (conference) feature. Default: false.
  final bool groupCallEnabled;

  /// ICE servers for WebRTC peer connections.
  ///
  /// Each entry is a map with 'url'/'urls', and optionally 'username'/'credential'
  /// for TURN servers. When null the default Google STUN server is used, which
  /// only works when both devices are on the same local network. For production
  /// deployments where callers and callees are on different networks (mobile
  /// data, different Wi-Fi), you MUST supply at least one TURN relay server —
  /// otherwise ICE will fail and no media will flow.
  ///
  /// Example:
  /// ```dart
  /// iceServers: [
  ///   {'url': 'stun:stun.l.google.com:19302'},
  ///   {
  ///     'urls': 'turn:your-turn.example.com:3478',
  ///     'username': 'user',
  ///     'credential': 'password',
  ///   },
  /// ]
  /// ```
  final List<Map<String, dynamic>>? iceServers;

  /// Optional theme for the built-in call screen.
  ///
  /// Pass a [TringupCallTheme] to customise colours and font sizes without
  /// needing to provide a full [callScreenBuilder].
  /// Ignored when [callScreenBuilder] is set on [TringupCallShell].
  final TringupCallTheme? callTheme;

  /// Called when the iOS VoIP push token (PushKit) is available or refreshed.
  ///
  /// Use this to register the token with your backend so that incoming calls
  /// can wake a killed/terminated iOS app via PushKit. Without this, calls
  /// only work when the app is in the foreground or background (not killed).
  ///
  /// Register the token as type 'apkvoip' with your call backend:
  /// ```dart
  /// onVoipTokenReceived: (token) async {
  ///   await http.post(
  ///     Uri.parse('${callServerUrl}/integration/push-token'),
  ///     headers: {'x-integration-key': integrationKey, 'Content-Type': 'application/json'},
  ///     body: jsonEncode({'userId': userId, 'token_type': 'apkvoip', 'device_token': token}),
  ///   );
  /// },
  /// ```
  /// Only fires on iOS. Never fires on Android.
  final void Function(String token)? onVoipTokenReceived;
}
