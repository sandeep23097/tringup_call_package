import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:ssl_certificates/ssl_certificates.dart';
import 'package:webtrit_api/webtrit_api.dart';
import 'package:webtrit_callkeep/webtrit_callkeep.dart';
import 'package:webtrit_phone/features/call/call.dart';
import 'package:webtrit_phone/repositories/repositories.dart';

import 'stubs/stub_call_logs_repository.dart';
import 'stubs/stub_presence_info_repository.dart';
import 'tringup_call_background_handler.dart';
import 'stubs/stub_presence_settings_repository.dart';
import 'stubs/stub_session_repository.dart';
import 'tringup_call_config.dart';
import 'tringup_call_contact.dart';
import 'tringup_call_controller.dart';
import 'tringup_call_diagnostics.dart';
import 'tringup_call_shell.dart';

const _tag = '[TringupCallWidget]';

class TringupCallWidget extends StatefulWidget {
  const TringupCallWidget({
    super.key,
    required this.config,
    required this.child,
    this.controller,
  });

  final TringupCallConfig config;
  final TringupCallController? controller;
  final Widget child;

  @override
  State<TringupCallWidget> createState() => _TringupCallWidgetState();
}

class _TringupCallWidgetState extends State<TringupCallWidget> {
  late final Callkeep _callkeep;
  late final CallkeepConnections _callkeepConnections;
  late CallBloc _callBloc;
  late _BufferingCallkeepDelegate _bufferingDelegate;
  // Kept alive across token refreshes so the stream never breaks.
  late final CallPullRepositoryMemoryImpl _callPullRepository;
  _VoipTokenDelegate? _voipDelegate;

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      debugPrint('$_tag initState — serverUrl=${widget.config.serverUrl} '
          'tenantId=${widget.config.tenantId} '
          'token=${widget.config.token.isEmpty ? "<EMPTY>" : "${widget.config.token.substring(0, widget.config.token.length.clamp(0, 20))}..."}');
    }

    _callPullRepository = CallPullRepositoryMemoryImpl();
    _callkeep = Callkeep();
    _callkeepConnections = CallkeepConnections();

    _callkeep.setUp(
      const CallkeepOptions(
        ios: CallkeepIOSOptions(
          localizedName: 'TringupCall',
          maximumCallGroups: 13,
          maximumCallsPerCallGroup: 13,
          supportedHandleTypes: {CallkeepHandleType.number},
        ),
        android: CallkeepAndroidOptions(),
      ),
    );
    if (kDebugMode) debugPrint('$_tag Callkeep.setUp done');

    _callBloc = _buildCallBloc(widget.config);
    if (kDebugMode) debugPrint('$_tag CallBloc created, CallStarted dispatched');

    // Reflect token presence in diagnostics immediately on init.
    TringupCallDiagnostics.instance
        .updateTokenPresence(widget.config.token.isNotEmpty);

    // Persist credentials so the background push-notification isolate can
    // authenticate against the signaling server when the app is killed.
    _persistCredentials(widget.config);

    // Wire up iOS VoIP push token callback.
    // PushKit fires didUpdatePushToken once when the app registers and again
    // whenever the token changes. We forward it to the host app so it can
    // register the token with its backend (type 'apkvoip').
    if (Platform.isIOS) {
      _voipDelegate = _VoipTokenDelegate(widget.config.onVoipTokenReceived);
      _callkeep.setPushRegistryDelegate(_voipDelegate);
    }
  }

  CallBloc _buildCallBloc(TringupCallConfig cfg) {
    if (kDebugMode) {
      debugPrint('$_tag _buildCallBloc — token isEmpty=${cfg.token.isEmpty}');
    }
    final webtritApiClient = WebtritApiClient(
      Uri.parse(cfg.serverUrl),
      cfg.tenantId,
    );

    final bloc = CallBloc(
      coreUrl: cfg.serverUrl,
      tenantId: cfg.tenantId,
      token: cfg.token,
      trustedCertificates: TrustedCertificates.empty,
      callLogsRepository: StubCallLogsRepository(),
      callPullRepository: _callPullRepository,
      linesStateRepository: LinesStateRepositoryInMemoryImpl(),
      presenceInfoRepository: StubPresenceInfoRepository(),
      presenceSettingsRepository: StubPresenceSettingsRepository(),
      sessionRepository: StubSessionRepository(),
      userRepository: UserRepository(webtritApiClient, cfg.token),
      submitNotification: (_) {},
      callkeep: _callkeep,
      callkeepConnections: _callkeepConnections,
      sdpMunger: null,
      sdpSanitizer: RemoteSdpSanitizer(),
      webRtcOptionsBuilder: null,
      userMediaBuilder: const DefaultUserMediaBuilder(),
      contactNameResolver: _TringupContactNameResolver(cfg),
      contactPhotoResolver: _TringupContactPhotoResolver(cfg),
      groupChatPhotoResolver: _TringupGroupChatPhotoResolver(cfg),
      callErrorReporter: _DebugCallErrorReporter(),
      iceFilter: null,
      iceServers: cfg.iceServers,
      peerConnectionPolicyApplier: null,
      sipPresenceEnabled: false,
      groupCallEnabled: cfg.groupCallEnabled,
      onCallEnded: null,
      onDiagnosticReportRequested: (_, __) {},
    )..add(const CallStarted());

    if (kDebugMode) {
      debugPrint('$_tag _buildCallBloc — serverUrl=${cfg.serverUrl} '
          'tenantId=${cfg.tenantId} '
          'token isEmpty=${cfg.token.isEmpty} '
          'userId=${cfg.userId.isEmpty ? "<EMPTY>" : cfg.userId}');
    }

    // CallBloc registers itself as the callkeep delegate in its constructor.
    // We replace it with our buffering proxy so that early accept/decline events
    // from the native UI (received before the WebSocket incoming-call event
    // arrives) are held until the call appears in activeCalls, then replayed.
    _bufferingDelegate = _BufferingCallkeepDelegate(inner: bloc, callBloc: bloc);
    _callkeep.setDelegate(_bufferingDelegate);

    return bloc;
  }

  @override
  void didUpdateWidget(TringupCallWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Keep VoIP delegate's callback in sync if it changes.
    if (Platform.isIOS &&
        widget.config.onVoipTokenReceived != oldWidget.config.onVoipTokenReceived) {
      _voipDelegate?.callback = widget.config.onVoipTokenReceived;
    }

    final oldToken = oldWidget.config.token;
    final newToken = widget.config.token;
    if (oldToken != newToken) {
      // Keep diagnostics in sync whenever the token changes.
      TringupCallDiagnostics.instance.updateTokenPresence(newToken.isNotEmpty);
      if (kDebugMode) {
        debugPrint('$_tag didUpdateWidget — token changed, rebuilding CallBloc '
            '(new token isEmpty=${newToken.isEmpty})');
      }
      // CallBloc.token is a final field — add(CallStarted()) would still use
      // the old token. We must close the old bloc and create a fresh one.
      _bufferingDelegate.dispose();
      _callBloc.close();
      _callBloc = _buildCallBloc(widget.config);
      setState(() {}); // rebuild so BlocProvider.value picks up the new bloc

      // First-install safety net: if the bloc is still idle after 3 seconds,
      // dispatch CallStarted again. This handles the case where the first
      // connection attempt silently fails (common on first install when the
      // signaling stack isn't fully warm).
      final capturedBloc = _callBloc;
      Future.delayed(const Duration(seconds: 3), () {
        if (!mounted) return;
        if (capturedBloc.state.activeCalls.isEmpty) {
          if (kDebugMode) debugPrint('$_tag first-launch retry: re-dispatching CallStarted');
          capturedBloc.add(const CallStarted());
        }
      });
    } else {
      if (kDebugMode) debugPrint('$_tag didUpdateWidget — token unchanged, no reconnect');
    }
    // Always keep stored credentials in sync (token may change on refresh).
    if (widget.config != oldWidget.config) {
      _persistCredentials(widget.config);
    }
  }

  @override
  void dispose() {
    if (kDebugMode) debugPrint('$_tag dispose');
    widget.controller?.detach();
    _bufferingDelegate.dispose();
    _callBloc.close();
    if (Platform.isIOS) {
      _callkeep.setPushRegistryDelegate(null);
    }
    _callkeep.tearDown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kDebugMode) debugPrint('$_tag build — attaching controller=${widget.controller != null}');
    return BlocProvider<CallBloc>.value(
      value: _callBloc,
      child: Builder(
        builder: (ctx) {
          widget.controller?.attach(ctx, callPullRepository: _callPullRepository);
          if (kDebugMode) debugPrint('$_tag controller attached, isAttached=${widget.controller?.isAttached}');
          // TringupCallShell must live INSIDE the host app's MaterialApp
          // (in GetMaterialApp.builder) so Overlay.of(context) resolves to
          // the Navigator's Overlay. Do NOT wrap child here.
          return widget.child;
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Buffering CallkeepDelegate proxy
// ---------------------------------------------------------------------------

/// Wraps [CallBloc] (which implements [CallkeepDelegate]) and buffers
/// [performAnswerCall] / [performEndCall] events that arrive before the call
/// appears in [CallBloc.activeCalls].
///
/// **Why this is needed**: When the app is backgrounded, the FCM handler shows
/// the native incoming-call UI via [BackgroundPushNotificationBootstrapService]
/// immediately. The user may tap Accept/Decline on that UI before the
/// WebSocket signaling event has reached [CallBloc]. At that point
/// [CallBloc.__onCallPerformEventAnswered] returns early because
/// `retrieveActiveCall(callId)` is null. This proxy detects that race condition
/// and holds the perform-event in a pending map, then replays it as soon as
/// the matching call appears in [CallBloc.state.activeCalls].
class _BufferingCallkeepDelegate implements CallkeepDelegate {
  _BufferingCallkeepDelegate({
    required CallkeepDelegate inner,
    required CallBloc callBloc,
  })  : _inner = inner,
        _callBloc = callBloc {
    _stateSub = callBloc.stream.listen(_onCallBlocState);
  }

  final CallkeepDelegate _inner;
  final CallBloc _callBloc;
  late final StreamSubscription<CallState> _stateSub;

  // callId → completer that resolves when the buffered event is processed
  final Map<String, _PendingPerform> _pending = {};

  void dispose() {
    _stateSub.cancel();
    // Fail any still-pending operations so callers don't hang.
    for (final p in _pending.values) {
      if (!p.completer.isCompleted) p.completer.complete(false);
    }
    _pending.clear();
  }

  // Replay buffered answers/ends when the call finally appears in activeCalls.
  void _onCallBlocState(CallState state) {
    for (final callId in _pending.keys.toList()) {
      if (state.retrieveActiveCall(callId) != null) {
        final pending = _pending.remove(callId)!;
        if (kDebugMode) {
          debugPrint('$_tag [BufferingDelegate] replaying buffered '
              '${pending.isAnswer ? "answer" : "end"} for callId=$callId');
        }
        final future = pending.isAnswer
            ? _inner.performAnswerCall(callId)
            : _inner.performEndCall(callId);
        future.then(
          (ok) => pending.completer.isCompleted ? null : pending.completer.complete(ok),
          onError: (_) => pending.completer.isCompleted ? null : pending.completer.complete(false),
        );
      }
    }
  }

  Future<bool> _bufferOrForward({
    required String callId,
    required bool isAnswer,
    required Future<bool> Function() forward,
  }) {
    final existing = _callBloc.state.retrieveActiveCall(callId);
    if (existing != null) {
      // Call is already known — forward immediately.
      return forward();
    }
    if (kDebugMode) {
      debugPrint('$_tag [BufferingDelegate] buffering ${isAnswer ? "answer" : "end"} '
          'for callId=$callId (call not yet in activeCalls)');
    }
    final pending = _PendingPerform(isAnswer: isAnswer);
    _pending[callId] = pending;
    return pending.completer.future;
  }

  // ── CallkeepDelegate implementation ────────────────────────────────────────

  @override
  Future<bool> performAnswerCall(String callId) => _bufferOrForward(
        callId: callId,
        isAnswer: true,
        forward: () => _inner.performAnswerCall(callId),
      );

  @override
  Future<bool> performEndCall(String callId) => _bufferOrForward(
        callId: callId,
        isAnswer: false,
        forward: () => _inner.performEndCall(callId),
      );

  // All other delegate methods are forwarded directly — no buffering needed.

  @override
  Future<bool> performStartCall(
    String callId,
    CallkeepHandle handle,
    String? displayNameOrContactIdentifier,
    bool video,
  ) =>
      _inner.performStartCall(callId, handle, displayNameOrContactIdentifier, video);

  @override
  Future<bool> performSetHeld(String callId, bool onHold) =>
      _inner.performSetHeld(callId, onHold);

  @override
  Future<bool> performSetMuted(String callId, bool muted) =>
      _inner.performSetMuted(callId, muted);

  @override
  Future<bool> performSendDTMF(String callId, String key) =>
      _inner.performSendDTMF(callId, key);

  @override
  Future<bool> performAudioDeviceSet(String callId, CallkeepAudioDevice device) =>
      _inner.performAudioDeviceSet(callId, device);

  @override
  Future<bool> performAudioDevicesUpdate(
          String callId, List<CallkeepAudioDevice> devices) =>
      _inner.performAudioDevicesUpdate(callId, devices);

  @override
  void continueStartCallIntent(
          CallkeepHandle handle, String? displayName, bool video) =>
      _inner.continueStartCallIntent(handle, displayName, video);

  @override
  void didPushIncomingCall(
    CallkeepHandle handle,
    String? displayName,
    bool video,
    String callId,
    CallkeepIncomingCallError? error,
  ) =>
      _inner.didPushIncomingCall(handle, displayName, video, callId, error);

  @override
  void didActivateAudioSession() => _inner.didActivateAudioSession();

  @override
  void didDeactivateAudioSession() => _inner.didDeactivateAudioSession();

  @override
  void didReset() => _inner.didReset();
}

class _PendingPerform {
  _PendingPerform({required this.isAnswer});
  final bool isAnswer;
  final completer = Completer<bool>();
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

void _persistCredentials(TringupCallConfig cfg) {
  // Fire-and-forget — failure is logged inside saveCredentials.
  TringupCallBackgroundHandler.saveCredentials(
    serverUrl: cfg.serverUrl,
    tenantId: cfg.tenantId,
    token: cfg.token,
    userId: cfg.userId,
  );
}

class _TringupContactNameResolver implements ContactNameResolver {
  const _TringupContactNameResolver(this._config);
  final TringupCallConfig _config;

  @override
  Future<String?> resolveWithNumber(String? number) async {
    final resolver = _config.nameResolver;
    if (resolver == null || number == null) return null;
    return resolver(TringupCallContact(userId: '', phoneNumber: number));
  }
}

class _TringupContactPhotoResolver implements ContactPhotoResolver {
  const _TringupContactPhotoResolver(this._config);
  final TringupCallConfig _config;

  @override
  Future<String?> resolvePathWithNumber(String? number) async {
    final resolver = _config.photoPathResolver;
    if (resolver == null || number == null) return null;
    return resolver(TringupCallContact(userId: '', phoneNumber: number));
  }
}

class _TringupGroupChatPhotoResolver implements GroupChatPhotoResolver {
  const _TringupGroupChatPhotoResolver(this._config);
  final TringupCallConfig _config;

  @override
  Future<String?> resolvePathWithChatId(String? chatId) async {
    final resolver = _config.groupChatPhotoPathResolver;
    if (resolver == null || chatId == null) return null;
    return resolver(chatId);
  }
}

// ---------------------------------------------------------------------------
// VoIP push token delegate
// ---------------------------------------------------------------------------

/// Forwards PushKit VoIP token updates to the host app's callback.
///
/// Set on [Callkeep] via [Callkeep.setPushRegistryDelegate] so that iOS
/// PushKit token changes are forwarded to the host app for backend registration.
class _VoipTokenDelegate implements PushRegistryDelegate {
  _VoipTokenDelegate(this.callback);

  void Function(String token)? callback;

  @override
  void didUpdatePushTokenForPushTypeVoIP(String? token) {
    if (token != null) {
      if (kDebugMode) debugPrint('$_tag VoIP token received (${token.length} chars)');
      callback?.call(token);
    }
  }
}

/// Logs errors instead of silently swallowing them during development.
class _DebugCallErrorReporter implements CallErrorReporter {
  @override
  void handle(Object error, StackTrace? stack, String context) {
    if (kDebugMode) {
      debugPrint('[TringupCall ERROR] context=$context error=$error');
      if (stack != null) debugPrint(stack.toString());
    }
  }
}
