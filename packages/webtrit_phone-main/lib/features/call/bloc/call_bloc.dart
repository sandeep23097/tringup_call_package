import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart' hide Notification;

import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:clock/clock.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:logging/logging.dart';
import 'package:ssl_certificates/ssl_certificates.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:webtrit_api/webtrit_api.dart';
import 'package:webtrit_callkeep/webtrit_callkeep.dart';
import 'package:webtrit_phone/mappers/signaling/signaling.dart';
import 'package:webtrit_signaling/webtrit_signaling.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import '../livekit/livekit_room_manager.dart';

import 'package:webtrit_phone/app/constants.dart';
import 'package:webtrit_phone/app/notifications/notifications.dart';
import 'package:webtrit_phone/extensions/extensions.dart';
import 'package:webtrit_phone/models/models.dart';
import 'package:webtrit_phone/repositories/repositories.dart';
import 'package:webtrit_phone/utils/utils.dart';

import '../extensions/extensions.dart';
import '../models/models.dart';
import '../utils/utils.dart';

export 'package:webtrit_callkeep/webtrit_callkeep.dart' show CallkeepHandle, CallkeepHandleType;

part 'call_bloc.freezed.dart';

part 'call_event.dart';

part 'call_state.dart';

const int _kUndefinedLine = -1;

/// Sentinel error used to signal that a call is in LiveKit mode (no WebRTC
/// peer connection is needed).  Completing the peer-connection completer with
/// this error causes [_peerConnectionRetrieve] to return `null`, which
/// naturally skips all WebRTC operations that guard on `pc != null`.
class LiveKitModeSignal implements Exception {
  const LiveKitModeSignal();
  @override
  String toString() => 'LiveKitModeSignal';
}

final _logger = Logger('CallBloc');

/// A callback function type for handling diagnostic reports for call request errors.
/// It takes the [callId] of the failed call and the specific [CallkeepCallRequestError]
/// as parameters, allowing for detailed error logging or reporting.
typedef OnDiagnosticReportRequested = void Function(String callId, CallkeepCallRequestError error);

class CallBloc extends Bloc<CallEvent, CallState> with WidgetsBindingObserver implements CallkeepDelegate {
  final String coreUrl;
  final String tenantId;
  final String token;
  final TrustedCertificates trustedCertificates;

  final CallLogsRepository callLogsRepository;
  final CallPullRepository callPullRepository;
  final UserRepository userRepository;
  final SessionRepository sessionRepository;
  final LinesStateRepository linesStateRepository;
  final PresenceInfoRepository presenceInfoRepository;
  final PresenceSettingsRepository presenceSettingsRepository;
  final Function(Notification) submitNotification;

  final Callkeep callkeep;
  final CallkeepConnections callkeepConnections;

  final SDPMunger? sdpMunger;
  final SdpSanitizer? sdpSanitizer;
  final WebrtcOptionsBuilder? webRtcOptionsBuilder;
  final IceFilter? iceFilter;
  final List<Map<String, dynamic>>? iceServers;
  final UserMediaBuilder userMediaBuilder;
  final PeerConnectionPolicyApplier? peerConnectionPolicyApplier;
  final ContactNameResolver contactNameResolver;
  final ContactPhotoResolver? contactPhotoResolver;
  final GroupChatPhotoResolver? groupChatPhotoResolver;
  final CallErrorReporter callErrorReporter;
  final bool sipPresenceEnabled;
  final VoidCallback? onCallEnded;
  final OnDiagnosticReportRequested onDiagnosticReportRequested;

  StreamSubscription<List<ConnectivityResult>>? _connectivityChangedSubscription;
  StreamSubscription<PendingCall>? _pendingCallHandlerSubscription;

  late final SignalingClientFactory _signalingClientFactory;
  WebtritSignalingClient? _signalingClient;
  Timer? _signalingClientReconnectTimer;
  Timer? _presenceInfoSyncTimer;
  Timer? _foregroundWatchdogTimer;
  int _reconnectAttempts = 0;
  static const _kWatchdogInterval = Duration(minutes: 5);

  final _peerConnectionCompleters = <String, Completer<RTCPeerConnection>>{};

  // ── LiveKit mode state ──────────────────────────────────────────────────────
  // Keyed by callId.  Populated when the signaling layer delivers LiveKit
  // credentials via incoming_call (callee) or ringing (caller) events.
  final _livekitUrls           = <String, String>{};
  final _livekitTokens         = <String, String>{};
  final _livekitRooms          = <String, LiveKitRoomManager>{};
  // Tracks whether the local camera is enabled in LiveKit mode (per callId).
  final _livekitCameraEnabled  = <String, bool>{};
  // Tracks server-confirmed joined participants per callId (via participant_joined /
  // participant_left signaling events only — no LK SDK race condition).
  // Used for reliable group-call auto-end decisions.
  final _connectedParticipantIds = <String, Set<String>>{};

  // Call IDs for which call_ended arrived before (or concurrently with) call_invite.
  // Guards against the concurrent-handler race: _onCallEnded and _onCallInvite can run
  // at the same time because sequential() is per-event-type, not global.
  // _onCallInvite checks this set at two points so it can dismiss the native UI even
  // if call_ended was already consumed before reportNewIncomingCall was called.
  final _earlyEndedCallIds = <String>{};

  /// ICE candidates received before [setRemoteDescription] was called.
  /// Drained after each [setRemoteDescription] via [_drainPendingIceCandidates].
  final _pendingIceCandidates = <String, List<RTCIceCandidate>>{};

  /// ICE candidates received before the call was added to [state.activeCalls]
  /// (e.g. push case where call has line=-1 but ICE trickle carries the real callId).
  /// Moved to [_pendingIceCandidates] when the call is registered in state.
  final _orphanedIceCandidates = <String, List<RTCIceCandidate>>{};

  /// Tracks which callIds have had [setRemoteDescription] called at least once.
  final _remoteDescriptionSet = <String>{};

  /// Counts ICE restarts per call to prevent infinite restart loops.
  final _iceRestartCounts = <String, int>{};

  final _callkeepSound = WebtritCallkeepSound();

  // ── conference (group call) state ──────────────────────────────────────────
  bool groupCallEnabled = false;

  /// callIds using the new unified call protocol (call_initiate / call_invite flow).
  final Set<String> _unifiedFlowCallIds = {};

  /// Returns the current participant list for a call, or empty list.
  /// Participants are stored directly on [ActiveCall.conferenceParticipants].
  List<ConferenceParticipant> getConferenceParticipants(String callId) =>
      state.retrieveActiveCall(callId)?.conferenceParticipants ?? const [];

  /// Returns a map of serverUserId → phoneNumber for all participants whose
  /// phone number is known for the given call.  Includes both pre-populated
  /// phone entries (userId == phone) and server-ID entries populated after
  /// participant_joined.  Used for cross-namespace matching in the UI.
  Map<String, String> getParticipantPhoneMap(String callId) {
    final result = <String, String>{};
    for (final p in getConferenceParticipants(callId)) {
      final phone = p.phoneNumber ?? (p.userId.startsWith('+') ? p.userId : null);
      if (phone != null) result[p.userId] = phone;
    }
    return result;
  }

  /// Returns the group name for a call. Unified-flow calls use
  /// [ActiveCall.displayName]; always returns null for 1-on-1 1-to-1 calls.
  String? getConferenceGroupName(String callId) => null;

  /// Returns the active LiveKit room for [callId], or null if the call is not
  /// in LiveKit mode or the room has not connected yet.
  lk.Room? getLiveKitRoom(String callId) => _livekitRooms[callId]?.room;

  /// Returns whether the local camera is currently enabled for a LiveKit call.
  /// Returns true by default (camera on) when not explicitly set.
  bool getLiveKitCameraEnabled(String callId) =>
      _livekitCameraEnabled[callId] ?? (_livekitRooms.containsKey(callId) &&
          (state.retrieveActiveCall(callId)?.video ?? false));

  /// Override the display name for [callId] with a name resolved by the host
  /// app (e.g. from the local contacts database).  Updates both the BLoC state
  /// and the native CallKeep notification so the system call UI shows the
  /// correct name.
  void updateCallDisplayName(String callId, String displayName, {String? avatarFilePath}) {
    add(_DisplayNameUpdateEvent(callId: callId, displayName: displayName, avatarFilePath: avatarFilePath));
  }

  CallBloc({
    required this.coreUrl,
    required this.tenantId,
    required this.token,
    required this.trustedCertificates,
    required this.callLogsRepository,
    required this.callPullRepository,
    required this.linesStateRepository,
    required this.presenceInfoRepository,
    required this.presenceSettingsRepository,
    required this.sessionRepository,
    required this.userRepository,
    required this.submitNotification,
    required this.callkeep,
    required this.callkeepConnections,
    required this.userMediaBuilder,
    required this.contactNameResolver,
    this.contactPhotoResolver,
    this.groupChatPhotoResolver,
    required this.callErrorReporter,
    required this.sipPresenceEnabled,
    required this.onDiagnosticReportRequested,
    this.sdpMunger,
    this.sdpSanitizer,
    this.webRtcOptionsBuilder,
    this.iceFilter,
    this.iceServers,
    this.peerConnectionPolicyApplier,
    SignalingClientFactory signalingClientFactory = defaultSignalingClientFactory,
    this.onCallEnded,
    bool groupCallEnabled = false,
  }) : super(const CallState()) {
    _signalingClientFactory = signalingClientFactory;
    this.groupCallEnabled = groupCallEnabled;

    on<CallStarted>(_onCallStarted, transformer: sequential());
    on<_AppLifecycleStateChanged>(_onAppLifecycleStateChanged, transformer: sequential());
    on<_ConnectivityResultChanged>(_onConnectivityResultChanged, transformer: sequential());
    on<_NavigatorMediaDevicesChange>(_onNavigatorMediaDevicesChange, transformer: debounce());
    on<_RegistrationChange>(_onRegistrationChange, transformer: droppable());
    on<_ResetStateEvent>(_onResetStateEvent, transformer: droppable());
    on<_SignalingClientEvent>(_onSignalingClientEvent, transformer: restartable());
    on<_HandshakeSignalingEventState>(_onHandshakeSignalingEventState, transformer: sequential());
    on<_CallSignalingEvent>(_onCallSignalingEvent, transformer: sequential());
    on<_CallPushEventIncoming>(_onCallPushEventIncoming, transformer: sequential());
    on<CallControlEvent>(_onCallControlEvent, transformer: sequential());
    on<_CallPerformEvent>(_onCallPerformEvent, transformer: sequential());
    on<_PeerConnectionEvent>(_onPeerConnectionEvent, transformer: sequential());
    on<CallScreenEvent>(_onCallScreenEvent, transformer: sequential());
    on<_DisplayNameUpdateEvent>(_onDisplayNameUpdateEvent, transformer: sequential());

    // New unified call flow events
    on<_CallSignalingEventInvite>(_onCallInvite, transformer: sequential());
    on<_CallSignalingEventCallRinging>(_onCallRinging, transformer: sequential());
    on<_CallSignalingEventCallAccepted>(_onCallAccepted, transformer: sequential());
    on<_CallSignalingEventCallEnded>(_onCallEnded, transformer: sequential());
    on<_CallSignalingEventParticipantJoined>(_onParticipantJoined, transformer: sequential());
    on<_CallSignalingEventParticipantLeft>(_onParticipantLeft, transformer: sequential());

    // Legacy conference events are no longer handled (Phase 3 cleanup).

    navigator.mediaDevices.ondevicechange = (event) {
      add(const _NavigatorMediaDevicesChange());
    };

    WidgetsBinding.instance.addObserver(this);

    callkeep.setDelegate(this);

    if (sipPresenceEnabled) {
      _presenceInfoSyncTimer = Timer.periodic(const Duration(seconds: 5), (_) => syncPresenceSettings());
    }
  }

  @override
  Future<void> close() async {
    // MUST run synchronously before the first `await` so it takes effect
    // immediately even when close() is called without await (e.g. in
    // didUpdateWidget).  Moving this after an await would let the new bloc's
    // delegate get wiped after _buildCallBloc() already set it.
    callkeep.setDelegate(null);

    WidgetsBinding.instance.removeObserver(this);

    navigator.mediaDevices.ondevicechange = null;

    await _connectivityChangedSubscription?.cancel();

    await _pendingCallHandlerSubscription?.cancel();

    _signalingClientReconnectTimer?.cancel();
    _foregroundWatchdogTimer?.cancel();

    _presenceInfoSyncTimer?.cancel();

    await _signalingClient?.disconnect();

    await _stopRingbackSound();

    // Disconnect all active LiveKit rooms
    for (final room in _livekitRooms.values) {
      room.disconnect().ignore();
    }
    _livekitRooms.clear();
    _livekitUrls.clear();
    _livekitTokens.clear();
    _livekitCameraEnabled.clear();

    await super.close();
  }

  @override
  void onError(Object error, StackTrace stackTrace) {
    super.onError(error, stackTrace);
    _logger.warning('onError', error, stackTrace);

    // Keepalive timed out — the WebSocket is a zombie connection.
    // Null out the client so reconnect guard clauses allow a fresh connect,
    // then force-reconnect immediately without waiting for a lifecycle event.
    if (error is WebtritSignalingKeepaliveTransactionTimeoutException) {
      _logger.warning('Keepalive timed out — forcing signaling reconnect');
      _signalingClient = null;
      _reconnectInitiated(Duration.zero, true);
    }
  }

  @override
  void onChange(Change<CallState> change) {
    super.onChange(change);

    // Update the signaling status in Callkeep to ensure proper call handling when the app is minimized or in the background
    callkeepConnections.updateActivitySignalingStatus(
      change.nextState.callServiceState.signalingClientStatus.toCallkeepSignalingStatus(),
    );

    // TODO: add detailed explanation of the following code and why it is necessary to initialize signaling client in background
    if (change.currentState.isActive != change.nextState.isActive) {
      final appLifecycleState = change.nextState.currentAppLifecycleState;
      final appInactive =
          appLifecycleState == AppLifecycleState.paused ||
          appLifecycleState == AppLifecycleState.detached ||
          appLifecycleState == AppLifecycleState.inactive;
      final hasActiveCalls = change.nextState.isActive;
      final connected = _signalingClient != null;

      if (appInactive) {
        if (hasActiveCalls && !connected) _reconnectInitiated(kSignalingClientFastReconnectDelay, true);
        if (!hasActiveCalls && connected) _disconnectInitiated();
      }
    }

    final currentActiveCallUuids = Set.from(change.currentState.activeCalls.map((e) => e.callId));
    final nextActiveCallUuids = Set.from(change.nextState.activeCalls.map((e) => e.callId));
    for (final removeUuid in currentActiveCallUuids.difference(nextActiveCallUuids)) {
      assert(_peerConnectionCompleters.containsKey(removeUuid) == true);
      _logger.finer(() => 'Remove peerConnection completer with uuid: $removeUuid');
      _peerConnectionCompleters.remove(removeUuid);
      _pendingIceCandidates.remove(removeUuid);
      _orphanedIceCandidates.remove(removeUuid);
      _remoteDescriptionSet.remove(removeUuid);
      _iceRestartCounts.remove(removeUuid);
      // Disconnect and clean up LiveKit room if this was a LiveKit call
      final lkRoom = _livekitRooms.remove(removeUuid);
      if (lkRoom != null) lkRoom.disconnect().ignore();
      _livekitUrls.remove(removeUuid);
      _livekitTokens.remove(removeUuid);
      _livekitCameraEnabled.remove(removeUuid);
    }
    for (final addUuid in nextActiveCallUuids.difference(currentActiveCallUuids)) {
      assert(_peerConnectionCompleters.containsKey(addUuid) == false);
      _logger.finer(() => 'Add peerConnection completer with uuid: $addUuid');
      final completer = Completer<RTCPeerConnection>();
      completer.future.ignore(); // prevent escalating possible error that was not awaited to the error zone level
      _peerConnectionCompleters[addUuid] = completer;
      // Move any ICE candidates that arrived before this call was registered.
      final orphaned = _orphanedIceCandidates.remove(addUuid);
      if (orphaned != null && orphaned.isNotEmpty) {
        // ignore: avoid_print
        print('[CallBloc] IceTrickle: absorbing ${orphaned.length} orphaned candidates into pending for callId=$addUuid');
        _pendingIceCandidates.putIfAbsent(addUuid, () => []).addAll(orphaned);
      }
    }

    final currentProcessingStatuses = Set.from(
      change.currentState.activeCalls.map((e) => '${e.line}:${e.processingStatus.name}'),
    ).join(', ');
    final nextProcessingStatuses = Set.from(
      change.nextState.activeCalls.map((e) => '${e.line}:${e.processingStatus.name}'),
    ).join(', ');
    if (currentProcessingStatuses != nextProcessingStatuses) {
      _logger.info(() => 'status transitions: $currentProcessingStatuses -> $nextProcessingStatuses');
    }

    /// RegistrationStatus can be null if the signaling state
    /// was not yet fully initialized. In this case, RegistrationStatus was made nullable to indicate that signaling has not been initialized yet.
    ///
    /// This scenario is particularly relevant when a call is triggered before the app
    /// is fully active, such as via [CallkeepDelegate.continueStartCallIntent]
    /// (e.g., from phone recents).

    final newRegistration = change.nextState.callServiceState.registration;
    final previousRegistration = change.currentState.callServiceState.registration;

    if (newRegistration != previousRegistration) {
      _logger.fine('_onRegistrationChange: $newRegistration to $previousRegistration');

      final newRegistrationStatus = newRegistration?.status;
      final previousRegistrationStatus = previousRegistration?.status;

      if (newRegistrationStatus?.isRegistered == true && previousRegistrationStatus?.isRegistered != true) {
        presenceSettingsRepository.resetLastSettingsSync();
        submitNotification(AppOnlineNotification());
      }

      if (newRegistrationStatus?.isRegistered != true && previousRegistrationStatus?.isRegistered == true) {
        submitNotification(AppOfflineNotification());
      }

      if (newRegistrationStatus?.isFailed == true || newRegistrationStatus?.isUnregistered == true) {
        add(const _ResetStateEvent.completeCalls());
      }

      if (newRegistrationStatus?.isFailed == true) {
        submitNotification(
          SipRegistrationFailedNotification(
            knownCode: SignalingRegistrationFailedCode.values.byCode(newRegistration?.code),
            systemCode: newRegistration?.code,
            systemReason: newRegistration?.reason,
          ),
        );
      }
    }

    final linesCount = change.nextState.linesCount;
    final activeCalls = change.nextState.activeCalls;
    final List<LineState> mainLinesState = [];
    for (var i = 0; i < linesCount; i++) {
      final inUse = activeCalls.any((e) => e.line == i);
      mainLinesState.add(inUse ? LineState.inUse : LineState.idle);
    }
    final guestLineInUse = activeCalls.any((e) => e.line == null);
    final guestLineState = guestLineInUse ? LineState.inUse : LineState.idle;

    linesStateRepository.setState(LinesState(mainLines: mainLinesState, guestLine: guestLineState));
    _handleSignalingSessionError(
      previous: change.currentState.callServiceState,
      current: change.nextState.callServiceState,
    );

    if (change.nextState.activeCalls.length < change.currentState.activeCalls.length) {
      onCallEnded?.call();
    }
  }

  void _handleSignalingSessionError({required CallServiceState previous, required CallServiceState current}) {
    final signalingChanged =
        previous.signalingClientStatus != current.signalingClientStatus ||
        previous.lastSignalingDisconnectCode != current.lastSignalingDisconnectCode;

    if (!signalingChanged) return;

    if (current.signalingClientStatus == SignalingClientStatus.disconnect &&
        current.lastSignalingDisconnectCode is int) {
      final code = SignalingDisconnectCode.values.byCode(current.lastSignalingDisconnectCode as int);

      if (code == SignalingDisconnectCode.sessionMissedError) {
        _logger.info('Signaling session listener: session is missing ${current.lastSignalingDisconnectCode}');

        unawaited(_notifyAccountErrorSafely());
        sessionRepository.logout().catchError((e, st) {
          _logger.warning('Logout failed after sessionMissedError', e, st);
        });
      }
    }
  }

  // TODO: Consider moving this method to a separate repository
  Future<void> _notifyAccountErrorSafely() async {
    try {
      await userRepository.getInfo(true);
    } on RequestFailure catch (e, st) {
      final errorCode = AccountErrorCode.values.firstWhereOrNull((it) => it.value == e.error?.code);
      if (errorCode != null) {
        submitNotification(AccountErrorNotification(errorCode));
      } else {
        _logger.fine('Account error code not mapped: ${e.error?.code}', e, st);
      }
    } catch (e, st) {
      _logger.warning('Unexpected error during account info refresh', e, st);
    }
  }

  //

  void _peerConnectionComplete(String callId, RTCPeerConnection peerConnection) {
    try {
      _logger.finer(() => 'Complete peerConnection completer with callId: $callId');
      final peerConnectionCompleter = _peerConnectionCompleters[callId]!;
      peerConnectionCompleter.complete(peerConnection);
    } catch (e) {
      // Handle the exception for correct functionality, for example, when the peer connection has already been completed.
      _logger.warning('_peerConnectionComplete: $e');
    }
  }

  void _peerConnectionCompleteError(String callId, Object error, [StackTrace? stackTrace]) {
    try {
      _logger.finer(() => 'CompleteError peerConnection completer with callId: $callId');
      final peerConnectionCompleter = _peerConnectionCompleters[callId]!;
      peerConnectionCompleter.completeError(error, stackTrace);
    } catch (e) {
      // Handle the exception for correct functionality, for example, when the peer connection has already been completed.
      _logger.warning('_peerConnectionCompleteError: $e');
    }
  }

  void _peerConnectionConditionalCompleteError(String callId, Object error, [StackTrace? stackTrace]) {
    try {
      final peerConnectionCompleter = _peerConnectionCompleters[callId]!;
      if (peerConnectionCompleter.isCompleted) {
        _logger.finer(
          () => 'ConditionalCompleteError peerConnection completer with callId: $callId - already completed',
        );
      } else {
        _logger.finer(() => 'ConditionalCompleteError peerConnection completer with callId: $callId');
        peerConnectionCompleter.completeError(error, stackTrace);
      }
    } catch (e) {
      // Handle the exception for correct functionality, for example, when the peer connection has already been completed.
      _logger.warning('_peerConnectionConditionalCompleteError: $e');
    }
  }

  Future<RTCPeerConnection?> _peerConnectionRetrieve(String callId, [bool allowWaiting = true]) async {
    final peerConnectionCompleter = _peerConnectionCompleters[callId];
    if (peerConnectionCompleter == null) {
      _logger.finer(() => 'Retrieve peerConnection completer with callId: $callId - null');
      return null;
    }

    try {
      if (!peerConnectionCompleter.isCompleted) {
        if (allowWaiting) {
          _logger.finer(() => 'Retrieve peerConnection completer with callId: $callId - waiting');
        } else {
          _logger.finer(() => 'Retrieve peerConnection completer with callId: $callId - cancelling');
          throw UncompletedPeerConnectionException(
            'Peer connection completer is not completed and waiting is not allowed',
          );
        }
      }

      _logger.finer(() => 'Retrieve peerConnection completer with callId: $callId - awaiting with timeout');

      final peerConnection = await peerConnectionCompleter.future.timeout(
        kPeerConnectionRetrieveTimeout,
        onTimeout: () => throw TimeoutException('Timeout while retrieving peer connection for callId: $callId'),
      );

      _logger.finer(() => 'Retrieve peerConnection completer with callId: $callId - value received');
      return peerConnection;
    } on UncompletedPeerConnectionException catch (e) {
      _logger.info('Uncompleted peer connection completer with callId: $callId - error', e);
      return null;
    } catch (e, stackTrace) {
      _logger.finer(() => 'Retrieve peerConnection completer with callId: $callId - error', e, stackTrace);
      return null;
    }
  }

  //

  void _reconnectInitiated([Duration delay = kSignalingClientFastReconnectDelay, bool force = false]) {
    _signalingClientReconnectTimer?.cancel();

    // Use exponential backoff unless the caller requests an immediate/forced reconnect.
    final effectiveDelay = (force || delay == Duration.zero)
        ? Duration.zero
        : _reconnectBackoffDelay(_reconnectAttempts);

    _signalingClientReconnectTimer = Timer(effectiveDelay, () {
      final appActive = state.currentAppLifecycleState == AppLifecycleState.resumed;
      final connectionActive = state.callServiceState.networkStatus != NetworkStatus.none;
      final signalingRemains = _signalingClient != null;

      _logger.info(
        '_reconnectInitiated Timer callback after $effectiveDelay (attempt $_reconnectAttempts), '
        'isClosed: $isClosed, appActive: $appActive, connectionActive: $connectionActive',
      );

      // Guard clause to prevent reconnection when the bloc was closed after delay.
      if (isClosed) return;

      // Guard clause to prevent reconnection when the app is in the background.
      // Coz reconnect can be triggered by another action e.g conectivity change.
      if (appActive == false && force == false) {
        _logger.info('__onSignalingClientEventConnectInitiated: skipped due to appActive: $appActive');
        return;
      }

      // Guard clause to prevent reconnection when there is no connectivity.
      // Coz reconnect can be triggered by another action e.g app lifecycle change.
      if (connectionActive == false && force == false) {
        _logger.info('__onSignalingClientEventConnectInitiated: skipped due to connectionActive: $connectionActive');
        return;
      }

      // Guard clause to prevent reconnection when the signaling client is already connected.
      //
      // Can be triggered by switching from wifi to mobile data.
      // In this case, the connection is recovers automatically, and signaling wasnt disposed.
      //
      // Or if app resumes from background or native call screen durning active call,
      // in this case signaling wasnt disposed
      if (signalingRemains == true && force == false) {
        _logger.info('__onSignalingClientEventConnectInitiated: skipped due signalingRemains: $signalingRemains');
        return;
      }

      _reconnectAttempts++;
      add(const _SignalingClientEvent.connectInitiated());
    });
  }

  /// Exponential backoff: 1 s, 2 s, 4 s, 8 s, 16 s, capped at 30 s.
  Duration _reconnectBackoffDelay(int attempt) {
    const maxSeconds = 30;
    final seconds = math.min(math.pow(2, attempt).toInt(), maxSeconds);
    return Duration(seconds: seconds);
  }

  void _resetReconnectAttempts() {
    _reconnectAttempts = 0;
  }

  // ── Foreground watchdog ───────────────────────────────────────────────────

  void _startForegroundWatchdog() {
    _foregroundWatchdogTimer?.cancel();
    _foregroundWatchdogTimer = Timer.periodic(_kWatchdogInterval, (_) {
      if (isClosed) {
        _stopForegroundWatchdog();
        return;
      }
      final appActive = state.currentAppLifecycleState == AppLifecycleState.resumed;
      if (!appActive) {
        _stopForegroundWatchdog();
        return;
      }
      if (_signalingClient == null) {
        _logger.info('Watchdog: signaling is null while foregrounded — reconnecting');
        _reconnectInitiated(Duration.zero);
      }
    });
  }

  void _stopForegroundWatchdog() {
    _foregroundWatchdogTimer?.cancel();
    _foregroundWatchdogTimer = null;
  }

  // ── Wait for signaling before outgoing call ───────────────────────────────

  /// Ensures a signaling connection is established before an outgoing call.
  /// If the client is already connected, returns immediately. Otherwise triggers
  /// a reconnect and polls for up to [timeout] before giving up.
  Future<bool> _ensureSignalingConnected({Duration timeout = const Duration(seconds: 3)}) async {
    if (_signalingClient != null) return true;

    _logger.info('_ensureSignalingConnected: signaling not ready — triggering reconnect');
    _reconnectInitiated(Duration.zero, true);

    final deadline = DateTime.now().add(timeout);
    while (_signalingClient == null && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    final connected = _signalingClient != null;
    _logger.info('_ensureSignalingConnected: connected=$connected');
    return connected;
  }

  void _disconnectInitiated() {
    _signalingClientReconnectTimer?.cancel();
    _signalingClientReconnectTimer = null;
    add(const _SignalingClientEvent.disconnectInitiated());
  }

  //

  Future<void> _onCallStarted(CallStarted event, Emitter<CallState> emit) async {
    // Initialize app lifecycle state
    final lifecycleState = WidgetsFlutterBinding.ensureInitialized().lifecycleState;
    emit(state.copyWith(currentAppLifecycleState: lifecycleState));
    _logger.fine('_onCallStarted initial lifecycle state: $lifecycleState');

    // Initialize connectivity state
    final connectivityState = (await Connectivity().checkConnectivity()).first;
    emit(
      state.copyWith(
        callServiceState: state.callServiceState.copyWith(networkStatus: connectivityState.toNetworkStatus()),
      ),
    );
    _logger.finer('_onCallStarted initial connectivity state: $connectivityState');

    // Subscribe to future connectivity changes
    _connectivityChangedSubscription = Connectivity().onConnectivityChanged.listen((result) {
      final currentConnectivityResult = result.first;
      add(_ConnectivityResultChanged(currentConnectivityResult));
    });

    _reconnectInitiated(Duration.zero);

    WebRTC.initialize(options: webRtcOptionsBuilder?.build());
  }

  Future<void> _onAppLifecycleStateChanged(_AppLifecycleStateChanged event, Emitter<CallState> emit) async {
    final appLifecycleState = event.state;
    _logger.fine('_onAppLifecycleStateChanged: $appLifecycleState');

    emit(state.copyWith(currentAppLifecycleState: appLifecycleState));

    if (appLifecycleState == AppLifecycleState.paused || appLifecycleState == AppLifecycleState.detached) {
      _stopForegroundWatchdog();
      if (state.isActive == false) _disconnectInitiated();
    } else if (appLifecycleState == AppLifecycleState.resumed) {
      _reconnectInitiated();
      _startForegroundWatchdog();
    }
  }

  Future<void> _onConnectivityResultChanged(_ConnectivityResultChanged event, Emitter<CallState> emit) async {
    final connectivityResult = event.result;
    _logger.fine('_onConnectivityResultChanged: $connectivityResult');
    if (connectivityResult == ConnectivityResult.none) {
      _disconnectInitiated();
    } else {
      _reconnectInitiated();
    }
    emit(
      state.copyWith(
        callServiceState: state.callServiceState.copyWith(networkStatus: connectivityResult.toNetworkStatus()),
      ),
    );
  }

  Future<void> _onNavigatorMediaDevicesChange(_NavigatorMediaDevicesChange event, Emitter<CallState> emit) async {
    if (Platform.isIOS) {
      // Cleanup devices info if change happened after hangup
      // to avoid presenting stale data on next call initialization
      if (state.activeCalls.isEmpty) return emit(state.copyWith(availableAudioDevices: [], audioDevice: null));

      final devices = await navigator.mediaDevices.enumerateDevices();
      final output = devices.where((d) => d.kind == 'audiooutput').toList();
      final input = devices.where((d) => d.kind == 'audioinput').toList();
      _logger.info('Devices change - out:${output.map((e) => e.str).toList()}, in:${input.map((e) => e.str).toList()}');

      final available = [
        CallAudioDevice(type: CallAudioDeviceType.speaker),
        ...input.map(CallAudioDevice.fromMediaInput),
      ];

      CallAudioDevice current;

      if (output.isNotEmpty) {
        current = CallAudioDevice.fromMediaOutput(output.first);
      } else {
        // Fallback behavior for iOS when out:[]
        // We prioritize the Earpiece (Receiver) if available (derived from MicrophoneBuiltIn),
        // otherwise fallback to the first available device (which is Speaker based on the list above).
        current = available.firstWhere(
          (device) => device.type == CallAudioDeviceType.earpiece,
          orElse: () => available.first,
        );

        _logger.warning(
          'No "audiooutput" devices reported. Fallback selected: ${current.name} (type: ${current.type})',
        );
      }

      emit(state.copyWith(availableAudioDevices: available, audioDevice: current));
    }
  }

  // processing the registration event change

  Future<void> _onRegistrationChange(_RegistrationChange event, Emitter<CallState> emit) async {
    emit(state.copyWith(callServiceState: state.callServiceState.copyWith(registration: event.registration)));
  }

  // processing the handling of the app state
  Future<void> _onResetStateEvent(_ResetStateEvent event, Emitter<CallState> emit) {
    return switch (event) {
      _ResetStateEventCompleteCalls() => __onResetStateEventCompleteCalls(event, emit),
      _ResetStateEventCompleteCall() => __onResetStateEventCompleteCall(event, emit),
    };
  }

  Future<void> __onResetStateEventCompleteCalls(_ResetStateEventCompleteCalls event, Emitter<CallState> emit) async {
    _logger.warning('__onResetStateEventCompleteCalls: ${state.activeCalls}');

    for (var element in state.activeCalls) {
      add(_ResetStateEvent.completeCall(element.callId));
    }
  }

  Future<void> __onResetStateEventCompleteCall(_ResetStateEventCompleteCall event, Emitter<CallState> emit) async {
    _logger.warning('__onResetStateEventCompleteCall: ${event.callId}');
    // ignore: avoid_print
    print('[CallBloc] ⚠️ completeCall (local reset, NO hangup sent) callId=${event.callId}');

    try {
      emit(
        state.copyWithMappedActiveCall(event.callId, (activeCall) {
          return activeCall.copyWith(processingStatus: CallProcessingStatus.disconnecting);
        }),
      );

      await state.performOnActiveCall(event.callId, (activeCall) async {
        await (await _peerConnectionRetrieve(activeCall.callId))?.close();
        await callkeep.reportEndCall(
          activeCall.callId,
          activeCall.displayName ?? activeCall.handle.value,
          CallkeepEndCallReason.remoteEnded,
        );
        await activeCall.localStream?.dispose();
      });
      _clearPullableCall(event.callId);
      emit(state.copyWithPopActiveCall(event.callId));
    } catch (e) {
      _logger.warning('__onResetStateEventCompleteCall: $e');
    }
  }

  // processing signaling client events

  Future<void> _onSignalingClientEvent(_SignalingClientEvent event, Emitter<CallState> emit) {
    return switch (event) {
      _SignalingClientEventConnectInitiated() => __onSignalingClientEventConnectInitiated(event, emit),
      _SignalingClientEventDisconnectInitiated() => __onSignalingClientEventDisconnectInitiated(event, emit),
      _SignalingClientEventDisconnected() => __onSignalingClientEventDisconnected(event, emit),
    };
  }

  Future<void> __onSignalingClientEventConnectInitiated(
    _SignalingClientEventConnectInitiated event,
    Emitter<CallState> emit,
  ) async {
    emit(
      state.copyWith(
        callServiceState: state.callServiceState.copyWith(
          signalingClientStatus: SignalingClientStatus.connecting,
          lastSignalingClientDisconnectError: null,
        ),
      ),
    );

    try {
      {
        final signalingClient = _signalingClient;
        if (signalingClient != null) {
          _signalingClient = null;
          await signalingClient.disconnect();
        }
      }

      if (emit.isDone) return;

      final signalingUrl = WebtritSignalingUtils.parseCoreUrlToSignalingUrl(coreUrl);

      final signalingClient = await _signalingClientFactory(
        url: signalingUrl,
        tenantId: tenantId,
        token: token,
        connectionTimeout: kSignalingClientConnectionTimeout,
        certs: trustedCertificates,
        force: true,
      );

      if (emit.isDone) {
        await signalingClient.disconnect(SignalingDisconnectCode.goingAway.code);
        return;
      }

      signalingClient.listen(
        onStateHandshake: _onSignalingStateHandshake,
        onEvent: _onSignalingEvent,
        onError: _onSignalingError,
        onDisconnect: (c, r) => _onSignalingDisconnect(c, r),
      );
      _signalingClient = signalingClient;

      emit(
        state.copyWith(
          callServiceState: state.callServiceState.copyWith(
            signalingClientStatus: SignalingClientStatus.connect,
            lastSignalingClientConnectError: null,
            lastSignalingDisconnectCode: null,
          ),
        ),
      );
    } catch (e, s) {
      if (emit.isDone) return;
      _logger.warning('__onSignalingClientEventConnectInitiated: $e', s);

      final repeated = state.callServiceState.lastSignalingClientConnectError == e;
      if (repeated == false) submitNotification(const SignalingConnectFailedNotification());

      emit(
        state.copyWith(
          callServiceState: state.callServiceState.copyWith(
            signalingClientStatus: SignalingClientStatus.failure,
            lastSignalingClientConnectError: e,
          ),
        ),
      );

      _reconnectInitiated(kSignalingClientReconnectDelay);
    }
  }

  Future<void> __onSignalingClientEventDisconnectInitiated(
    _SignalingClientEventDisconnectInitiated event,
    Emitter<CallState> emit,
  ) async {
    emit(
      state.copyWith(
        callServiceState: state.callServiceState.copyWith(
          signalingClientStatus: SignalingClientStatus.disconnecting,
          lastSignalingClientConnectError: null,
        ),
      ),
    );

    try {
      final signalingClient = _signalingClient;
      if (signalingClient != null) {
        _signalingClient = null;
        await signalingClient.disconnect();
      }

      if (emit.isDone) return;

      emit(
        state.copyWith(
          callServiceState: state.callServiceState.copyWith(
            signalingClientStatus: SignalingClientStatus.disconnect,
            lastSignalingClientDisconnectError: null,
            lastSignalingDisconnectCode: null,
          ),
        ),
      );
    } catch (e) {
      if (emit.isDone) return;

      emit(
        state.copyWith(
          callServiceState: state.callServiceState.copyWith(
            signalingClientStatus: SignalingClientStatus.failure,
            lastSignalingClientDisconnectError: e,
          ),
        ),
      );
    }
  }

  Future<void> __onSignalingClientEventDisconnected(
    _SignalingClientEventDisconnected event,
    Emitter<CallState> emit,
  ) async {
    final code = SignalingDisconnectCode.values.byCode(event.code ?? -1);
    final repeated = event.code == state.callServiceState.lastSignalingDisconnectCode;

    CallState newState = state.copyWith(
      callServiceState: state.callServiceState.copyWith(
        signalingClientStatus: SignalingClientStatus.disconnect,
        lastSignalingDisconnectCode: event.code,
      ),
    );
    Notification? notificationToShow;
    bool shouldReconnect = true;

    if (code == SignalingDisconnectCode.appUnregisteredError) {
      add(const _CallSignalingEvent.registration(RegistrationStatus.unregistered));

      newState = state.copyWith(
        callServiceState: state.callServiceState.copyWith(
          signalingClientStatus: SignalingClientStatus.disconnect,
          lastSignalingDisconnectCode: event.code,
        ),
      );
    } else if (code == SignalingDisconnectCode.requestCallIdError) {
      state.activeCalls.where((e) => e.wasHungUp).forEach((e) => add(_ResetStateEvent.completeCall(e.callId)));
    } else if (code == SignalingDisconnectCode.controllerExitError) {
      _logger.info('__onSignalingClientEventDisconnected: skipping expected system unregistration notification');
    } else if (code == SignalingDisconnectCode.sessionMissedError) {
      notificationToShow = const SignalingSessionMissedNotification();
    } else if (code.type == SignalingDisconnectCodeType.auxiliary) {
      _logger.info('__onSignalingClientEventDisconnected: socket goes down');

      /// Fun facts
      /// - in case of network disconnection on android this section is evaluating faster than [_onConnectivityResultChanged].
      /// - also in case of network disconnection error code is protocolError instead of normalClosure by unknown reason
      /// so we need to handle it here as regular disconnection
      if (code == SignalingDisconnectCode.protocolError) {
        shouldReconnect = false;
      } else {
        notificationToShow = SignalingDisconnectNotification(
          knownCode: code,
          systemCode: event.code,
          systemReason: event.reason,
        );
      }
    } else {
      notificationToShow = SignalingDisconnectNotification(
        knownCode: code,
        systemCode: event.code,
        systemReason: event.reason,
      );
    }
    emit(newState);
    _signalingClient = null;
    if (notificationToShow != null && !repeated) submitNotification(notificationToShow);
    if (shouldReconnect) _reconnectInitiated(kSignalingClientReconnectDelay);
  }

  // processing call push events

  Future<void> _onCallPushEventIncoming(_CallPushEventIncoming event, Emitter<CallState> emit) async {
    final eventError = event.error;
    if (eventError != null) {
      _logger.warning('_onCallPushEventIncoming event.error: $eventError');
      // TODO: implement correct incoming call hangup (take into account that _signalingClient is disconnected)
      return;
    }

    final contactName = await contactNameResolver.resolveWithNumber(event.handle.value);
    final displayName = contactName ?? event.displayName;
    final avatarFilePath = await contactPhotoResolver?.resolvePathWithNumber(event.handle.value);

    emit(
      state.copyWithPushActiveCall(
        ActiveCall(
          direction: CallDirection.incoming,
          line: _kUndefinedLine,
          callId: event.callId,
          handle: event.handle,
          displayName: displayName,
          video: event.video,
          createdTime: clock.now(),
          processingStatus: CallProcessingStatus.incomingFromPush,
        ),
      ),
    );

    // Replace the display name in Callkeep if it differs from the one in the event
    // mostly needed for ios, coz android can do it on background fcm isolate directly before push
    // TODO:
    // - do it on backend side same as for messaging
    //   currently push notification contain display name from sip header
    if (displayName != event.displayName || avatarFilePath != null) {
      await callkeep.reportUpdateCall(event.callId, displayName: displayName, avatarFilePath: avatarFilePath);
    }

    // Function to verify speaker availability for the upcoming event, ensuring the speaker button is correctly enabled or disabled
    add(const _NavigatorMediaDevicesChange());

    // the rest logic implemented within _onSignalingStateHandshake on IncomingCallEvent from call logs processing
  }

  // processing handshake signaling events

  Future<void> _onHandshakeSignalingEventState(_HandshakeSignalingEventState event, Emitter<CallState> emit) async {
    emit(state.copyWith(linesCount: event.linesCount));

    // StateHandshake received = the connection is genuinely healthy.
    // Only reset reconnect backoff here, not at TCP-connect time, so that
    // a connect→immediate-server-close cycle (bad token, wrong URL, etc.)
    // still backs off exponentially instead of spamming every 1 s.
    _resetReconnectAttempts();

    add(_RegistrationChange(registration: event.registration));
  }

  // processing call signaling events

  Future<void> _onCallSignalingEvent(_CallSignalingEvent event, Emitter<CallState> emit) {
    return switch (event) {
      _CallSignalingEventIncoming() => __onCallSignalingEventIncoming(event, emit),
      _CallSignalingEventRinging() => __onCallSignalingEventRinging(event, emit),
      _CallSignalingEventProgress() => __onCallSignalingEventProgress(event, emit),
      _CallSignalingEventAccepted() => __onCallSignalingEventAccepted(event, emit),
      _CallSignalingEventHangup() => __onCallSignalingEventHangup(event, emit),
      _CallSignalingEventUpdating() => __onCallSignalingEventUpdating(event, emit),
      _CallSignalingEventUpdated() => __onCallSignalingEventUpdated(event, emit),
      _CallSignalingEventTransfer() => __onCallSignalingEventTransfer(event, emit),
      _CallSignalingEventTransferring() => __onCallSignalingEventTransfering(event, emit),
      _CallSignalingEventNotifyDialog() => __onCallSignalingEventNotifyDialog(event, emit),
      _CallSignalingEventNotifyRefer() => __onCallSignalingEventNotifyRefer(event, emit),
      _CallSignalingEventNotifyPresence() => __onCallSignalingEventNotifyPresence(event, emit),
      _CallSignalingEventNotifyUnknown() => __onCallSignalingEventNotifyUnknown(event, emit),
      _CallSignalingEventRegistration() => __onCallSignalingEventRegistration(event, emit),
      _CallSignalingEventIceTrickle() => __onCallSignalingEventIceTrickle(event, emit),
      // New unified call flow events are handled by their own on<T> registrations.
      _CallSignalingEventInvite()          => Future.value(),
      _CallSignalingEventCallRinging()     => Future.value(),
      _CallSignalingEventCallAccepted()    => Future.value(),
      _CallSignalingEventCallEnded()       => Future.value(),
      _CallSignalingEventParticipantJoined() => Future.value(),
      _CallSignalingEventParticipantLeft() => Future.value(),
      // TODO: Handle this case.
      _ => throw UnimplementedError(),
    };
  }

  /// Handles incoming call offer.
  ///
  /// - Creates a new full [ActiveCall] with offer and line.
  /// - Or enriches existing [ActiveCall] with line and offer if
  /// its placed by push [__onCallPushEventIncoming] before the signaling was initialized.
  ///
  /// - continues in  [__onCallControlEventAnswered], [__onCallPerformEventAnswered] or [__onCallControlEventEnded], [__onCallPerformEventEnded]
  ///
  /// Be aware the answering intent can be submitted before the full [ActiveCall].
  /// So the answering method [__onCallPerformEventAnswered] will wait until offer and line is assigned
  /// to the [ActiveCall] by logic below, do not change status in that case.
  Future<void> __onCallSignalingEventIncoming(_CallSignalingEventIncoming event, Emitter<CallState> emit) async {
    // Store LiveKit credentials if this is a LiveKit call
    if (event.livekitUrl != null && event.livekitToken != null) {
      _livekitUrls[event.callId]   = event.livekitUrl!;
      _livekitTokens[event.callId] = event.livekitToken!;
    }

    final video = event.hasVideo ?? event.jsep?.hasVideo ?? false;
    final handle = CallkeepHandle.number(event.caller);
    final contactName = await contactNameResolver.resolveWithNumber(handle.value);
    final displayName = contactName ?? event.callerDisplayName;
    final avatarFilePath = await contactPhotoResolver?.resolvePathWithNumber(handle.value);
    print("FFFFFFFFFFFFFF${displayName}");
    final error = await callkeep.reportNewIncomingCall(event.callId, handle, displayName: displayName, hasVideo: video, avatarFilePath: avatarFilePath);

    // Check if a call instance already exists in the callkeep, which might have been added via push notifications
    // before the signaling was initialized.
    final callAlreadyExists = error == CallkeepIncomingCallError.callIdAlreadyExists;

    // Check if a call instance already exists in the callkeep, which might have been added via push notifications
    // before the signaling  was initialized. Also, check if the call status has been changed to "answered,"
    // indicating it can be triggered by pressing the answer button in the notification.
    final callAlreadyAnswered = error == CallkeepIncomingCallError.callIdAlreadyExistsAndAnswered;

    // Check if a call instance already terminated in the callkeep, which might have been added via push notifications
    // before the signaling  was initialized. Also, check if the call status has been changed to "terminated"
    // indicating it can be triggered by pressing the decline button in the notification or flutter ui.
    final callAlreadyTerminated = error == CallkeepIncomingCallError.callIdAlreadyTerminated;

    if (error != null && !callAlreadyExists && !callAlreadyAnswered && !callAlreadyTerminated) {
      _logger.warning('__onCallSignalingEventIncoming reportNewIncomingCall error: $error');
      // TODO: implement correct incoming call hangup (take into account that _signalingClient could be disconnected)
      return;
    }

    // Push notification (or Android foreground service) may have pre-registered the call
    // with the server display name before this signaling event arrived.
    // reportNewIncomingCall returned callAlreadyExists — push the locally resolved
    // contact name to the native UI so the notification/lock screen shows the right name.
    if ((callAlreadyExists || callAlreadyAnswered) && (contactName != null || avatarFilePath != null)) {
      print("DDDDDDDDDDDDDDDDDDD${displayName}");
      await callkeep.reportUpdateCall(event.callId, displayName: displayName, avatarFilePath: avatarFilePath);
    }

    final transfer = (event.referredBy != null && event.replaceCallId != null)
        ? InviteToAttendedTransfer(replaceCallId: event.replaceCallId!, referredBy: event.referredBy!)
        : null;

    ActiveCall? activeCall = state.retrieveActiveCall(event.callId);

    if (activeCall != null) {
      activeCall = activeCall.copyWith(
        line: event.line,
        handle: handle,
        displayName: displayName,
        video: video,
        transfer: transfer,
        incomingOffer: event.jsep,
      );
      emit(state.copyWithMappedActiveCall(event.callId, (_) => activeCall!));
    } else {
      activeCall = ActiveCall(
        direction: CallDirection.incoming,
        line: event.line,
        callId: event.callId,
        handle: handle,
        displayName: displayName,
        video: video,
        createdTime: clock.now(),
        transfer: transfer,
        incomingOffer: event.jsep,
        processingStatus: CallProcessingStatus.incomingFromOffer,
      );
      emit(state.copyWithPushActiveCall(activeCall));
    }

    // LiveKit mode: acknowledge receipt to backend so caller transitions to "ringing" state.
    // This triggers the smart ringing state feature (backend defers ringing event until call_received).
    if (event.livekitUrl != null && event.livekitToken != null) {
      _signalingClient?.execute(
        CallReceivedRequest(
          transaction: WebtritSignalingClient.generateTransactionId(),
          line: event.line ?? 0,
          callId: event.callId,
        ),
      ).ignore();
    }

    // Ensure to continue processing call if push action(answer, decline) pressed but app was'nt active at this moment
    // typically happens on android from terminated or background state,
    // on ios it produce second call of [__onCallPerformEventAnswered] or [__onCallPerformEventEnded]
    // so make sure to guard it from race conditions
    await Future.delayed(Duration.zero); // Defer execution to avoid exceptions like CallkeepCallRequestError.internal.
    if (callAlreadyAnswered) add(CallControlEvent.answered(event.callId));
    if (callAlreadyTerminated) add(CallControlEvent.ended(event.callId));
  }

  // no early media - play ringtone
  Future<void> __onCallSignalingEventRinging(_CallSignalingEventRinging event, Emitter<CallState> emit) async {
    await _playRingbackSound();

    emit(
      state.copyWithMappedActiveCall(event.callId, (call) {
        return call.copyWith(processingStatus: CallProcessingStatus.outgoingRinging);
      }),
    );

    // LiveKit mode: connect to room now that we have the caller token.
    if (event.livekitUrl != null && event.livekitToken != null) {
      _livekitUrls[event.callId]   = event.livekitUrl!;
      _livekitTokens[event.callId] = event.livekitToken!;

      final activeCall = state.retrieveActiveCall(event.callId);
      final videoEnabled = activeCall?.video ?? false;

      final roomManager = LiveKitRoomManager();
      _livekitRooms[event.callId] = roomManager;

      // Connect in background — do not await to avoid blocking the ringing handler
      roomManager.connect(
        url:          event.livekitUrl!,
        token:        event.livekitToken!,
        videoEnabled: videoEnabled,
      ).catchError((e) {
        _logger.warning('LiveKit caller connect error callId=${event.callId}: $e');
        _peerConnectionCompleteError(event.callId, e);
      });

      // Signal "no WebRTC peer connection" so downstream handlers skip it
      _peerConnectionCompleteError(event.callId, const LiveKitModeSignal());
    }
  }

  // early media - set specified session description
  Future<void> __onCallSignalingEventProgress(_CallSignalingEventProgress event, Emitter<CallState> emit) async {
    await _stopRingbackSound();

    final jsep = event.jsep;
    if (jsep != null) {
      final peerConnection = await _peerConnectionRetrieve(event.callId);
      if (peerConnection == null) {
        _logger.warning('__onCallSignalingEventProgress: peerConnection is null - most likely some permissions issue');
      } else {
        final remoteDescription = jsep.toDescription();
        sdpSanitizer?.apply(remoteDescription);
        await peerConnection.setRemoteDescription(remoteDescription);
        _remoteDescriptionSet.add(event.callId);
        await _drainPendingIceCandidates(event.callId);
      }
    } else {
      _logger.warning('__onCallSignalingEventProgress: jsep must not be null');
    }
  }

  /// Event fired when the call is accepted by any! user or call update request aplied.
  /// main cases:
  /// as call connected event after [__onCallPerformEventAnswered] or [__onCallPerformEventStarted]
  /// or as acknowledge of [UpdateRequest] with new jsep.
  Future<void> __onCallSignalingEventAccepted(_CallSignalingEventAccepted event, Emitter<CallState> emit) async {
    ActiveCall? call = state.retrieveActiveCall(event.callId);
    if (call == null) return;

    final initialAccept = call.acceptedTime == null;
    final outgoing = call.direction == CallDirection.outgoing;
    final jsep = event.jsep;

    if (initialAccept) {
      call = call.copyWith(processingStatus: CallProcessingStatus.connected, acceptedTime: clock.now());

      if (outgoing) {
        await _stopRingbackSound();
        await callkeep.reportConnectedOutgoingCall(event.callId);
      }
    }

    emit(state.copyWithMappedActiveCall(event.callId, (_) => call!));

    final pc = await _peerConnectionRetrieve(event.callId);
    // ignore: avoid_print
    print('[CallBloc] accepted callId=${event.callId} hasJsep=${jsep != null} hasPc=${pc != null}');
    if (jsep != null && pc != null) {
      try {
        final remoteDescription = jsep.toDescription();
        sdpSanitizer?.apply(remoteDescription);
        // ignore: avoid_print
        print('[CallBloc] 📋 ANSWER SDP (callId=${event.callId}):\n${remoteDescription.sdp}');
        await pc.setRemoteDescription(remoteDescription);
        _remoteDescriptionSet.add(event.callId);
        // ignore: avoid_print
        print('[CallBloc] setRemoteDescription(answer) done callId=${event.callId} — draining candidates');
        await _drainPendingIceCandidates(event.callId);
      } catch (e, s) {
        // ignore: avoid_print
        print('[CallBloc] ❌ setRemoteDescription(answer) FAILED callId=${event.callId} error=$e');
        callErrorReporter.handle(e, s, '__onCallSignalingEventAccepted setRemoteDescription');
      }
    }
  }

  Future<void> __onCallSignalingEventHangup(_CallSignalingEventHangup event, Emitter<CallState> emit) async {
    final code = SignalingResponseCode.values.byCode(event.code);
    _logger.fine('__onCallSignalingEventHangup code: ${code?.name} ${code?.code} ${code?.type.name}');
    // ignore: avoid_print
    print('[CallBloc] 📵 HANGUP received callId=${event.callId} code=${event.code} codeName=${code?.name}');

    switch (code) {
      case null:
        break;
      case SignalingResponseCode.declineCall:
        break;
      case SignalingResponseCode.normalUnspecified:
        break;
      case SignalingResponseCode.requestTerminated:
        break;
      case SignalingResponseCode.unauthorizedRequest:
        submitNotification(CallWhileUnregisteredNotification());
      case SignalingResponseCode.userBusy:
        // endReason = CallkeepEndCallReason.declinedElsewhere;
        // Show brief "busy" UI the same way as the unified flow.
        emit(state.copyWithMappedActiveCall(
          event.callId,
              (c) => c.copyWith(processingStatus: CallProcessingStatus.busySignal),
        ));
        await Future.delayed(const Duration(seconds: 2));
        break;
      default:
        final signalingHangupException = SignalingHangupFailure(code);
        final defaultErrorNotification = DefaultErrorNotification(signalingHangupException);
        submitNotification(defaultErrorNotification);
    }

    try {
      _stopRingbackSound();

      ActiveCall? call = state.retrieveActiveCall(event.callId);

      if (call != null) {
        CallkeepEndCallReason endReason = CallkeepEndCallReason.remoteEnded;

        if (call.wasHungUp == false) {
          _addToRecents(call.copyWith(hungUpTime: clock.now()));
        }

        // Fix B-3: Only treat requestTerminated as unanswered (missed-call) when WE
        // were the receiver. If WE placed the call, the remote simply didn't pick up.
        if (!call.wasAccepted) {
          if (code == SignalingResponseCode.declineCall) {
            endReason = CallkeepEndCallReason.declinedElsewhere;
          } else if (code == SignalingResponseCode.requestTerminated) {
            endReason = call.direction == CallDirection.incoming
                ? CallkeepEndCallReason.unanswered
                : CallkeepEndCallReason.remoteEnded;
          }
        }

        await (await _peerConnectionRetrieve(event.callId, false))?.close();
        await call.localStream?.dispose();

        _clearPullableCall(event.callId);
        emit(state.copyWithPopActiveCall(event.callId));

        await callkeep.reportEndCall(event.callId, call.displayName ?? call.handle.value, endReason);
      }
    } catch (e) {
      _logger.warning('__onCallSignalingEventHangup: $e');
    }
  }

  Future<void> __onCallSignalingEventUpdating(_CallSignalingEventUpdating event, Emitter<CallState> emit) async {
    // ignore: avoid_print
    print('[CallBloc] 🔄 UPDATING received (ICE restart re-offer) callId=${event.callId} hasJsep=${event.jsep != null}');
    final handle = CallkeepHandle.number(event.caller);
    final contactName = await contactNameResolver.resolveWithNumber(handle.value);
    final displayName = contactName ?? event.callerDisplayName;
    final avatarFilePath = await contactPhotoResolver?.resolvePathWithNumber(handle.value);

    emit(
      state.copyWithMappedActiveCall(event.callId, (activeCall) {
        return activeCall.copyWith(
          handle: handle,
          displayName: displayName ?? activeCall.displayName,
          video: event.jsep?.hasVideo ?? activeCall.video,
          updating: true,
        );
      }),
    );

    final activeCall = state.retrieveActiveCall(event.callId)!;

    await callkeep.reportUpdateCall(
      event.callId,
      handle: handle,
      displayName: activeCall.displayName,
      hasVideo: activeCall.video,
      proximityEnabled: state.shouldListenToProximity,
      avatarFilePath: avatarFilePath,
    );

    try {
      final jsep = event.jsep;
      if (jsep != null) {
        final remoteDescription = jsep.toDescription();
        sdpSanitizer?.apply(remoteDescription);
        await state.performOnActiveCall(event.callId, (activeCall) async {
          final peerConnection = await _peerConnectionRetrieve(activeCall.callId);
          if (peerConnection == null) {
            _logger.warning('__onCallSignalingEventUpdating: peerConnection is null - most likely some state issue');
          } else {
            await peerConnectionPolicyApplier?.apply(peerConnection, hasRemoteVideo: jsep.hasVideo);
            await peerConnection.setRemoteDescription(remoteDescription);
            _remoteDescriptionSet.add(activeCall.callId);
            await _drainPendingIceCandidates(activeCall.callId);
            final localDescription = await peerConnection.createAnswer({});
            sdpMunger?.apply(localDescription);

            // According to RFC 8829 5.6 (https://datatracker.ietf.org/doc/html/rfc8829#section-5.6),
            // localDescription should be set before sending the answer to transition into stable state.
            await peerConnection.setLocalDescription(localDescription);

            await _signalingClient?.execute(
              UpdateRequest(
                transaction: WebtritSignalingClient.generateTransactionId(),
                line: activeCall.line,
                callId: activeCall.callId,
                jsep: localDescription.toMap(),
              ),
            );
          }
        });
      }
    } catch (e, s) {
      callErrorReporter.handle(e, s, '__onCallSignalingEventUpdating && jsep error:');

      _peerConnectionCompleteError(event.callId, e);
      add(_ResetStateEvent.completeCall(event.callId));
    }
  }

  Future<void> __onCallSignalingEventUpdated(_CallSignalingEventUpdated event, Emitter<CallState> emit) async {
    // ignore: avoid_print
    print('[CallBloc] ✅ UPDATED (ICE restart answer) callId=${event.callId} hasJsep=${event.jsep != null}');
    emit(
      state.copyWithMappedActiveCall(event.callId, (activeCall) {
        return activeCall.copyWith(updating: false);
      }),
    );

    // Apply the SDP answer from the ICE restart so the peer connection can reconnect.
    final jsep = event.jsep;
    if (jsep != null) {
      final pc = await _peerConnectionRetrieve(event.callId);
      if (pc != null) {
        try {
          final remoteDescription = jsep.toDescription();
          sdpSanitizer?.apply(remoteDescription);
          await pc.setRemoteDescription(remoteDescription);
          _remoteDescriptionSet.add(event.callId);
          await _drainPendingIceCandidates(event.callId);
          // ignore: avoid_print
          print('[CallBloc] ✅ setRemoteDescription(ICE restart answer) done callId=${event.callId}');
        } catch (e, s) {
          // ignore: avoid_print
          print('[CallBloc] ❌ setRemoteDescription(ICE restart answer) FAILED callId=${event.callId} error=$e');
          callErrorReporter.handle(e, s, '__onCallSignalingEventUpdated setRemoteDescription');
        }
      }
    }
  }

  Future<void> __onCallSignalingEventTransfer(_CallSignalingEventTransfer event, Emitter<CallState> emit) async {
    final replaceCallId = event.replaceCallId;
    final referredBy = event.referredBy;
    final referId = event.referId;
    final referTo = event.referTo;

    // If replaceCallId exists, it means that the REFER request for attended transfer
    if (replaceCallId != null && referredBy != null) {
      // Find the active call that is should be replaced
      final callToReplace = state.retrieveActiveCall(replaceCallId);
      if (callToReplace == null) return;

      // Update call with confirmation request state
      final transfer = Transfer.attendedTransferConfirmationRequested(
        referId: referId,
        referTo: referTo,
        referredBy: referredBy,
      );
      final callUpdate = callToReplace.copyWith(transfer: transfer);
      emit(state.copyWithMappedActiveCall(replaceCallId, (_) => callUpdate));
    }
  }

  Future<void> __onCallSignalingEventTransfering(_CallSignalingEventTransferring event, Emitter<CallState> emit) async {
    final call = state.retrieveActiveCall(event.callId);
    if (call == null) return;

    final prev = call.transfer;
    final transfer = Transfer.transfering(
      fromAttendedTransfer: prev is AttendedTransferTransferSubmitted,
      fromBlindTransfer: prev is BlindTransferTransferSubmitted,
    );

    final callUpdate = call.copyWith(transfer: transfer);
    emit(state.copyWithMappedActiveCall(event.callId, (_) => callUpdate));
  }

  Future<void> __onCallSignalingEventNotifyDialog(
    _CallSignalingEventNotifyDialog event,
    Emitter<CallState> emit,
  ) async {
    _logger.fine('_CallSignalingEventNotifyDialogs: $event');
    await _assingUserActiveCalls(event.userActiveCalls);
  }

  Future<void> __onCallSignalingEventNotifyPresence(
    _CallSignalingEventNotifyPresence event,
    Emitter<CallState> emit,
  ) async {
    _logger.fine('_CallSignalingEventNotifyPresence: $event');
    await _assingNumberPresence(event.number, event.presenceInfo);
  }

  Future<void> __onCallSignalingEventNotifyRefer(_CallSignalingEventNotifyRefer event, Emitter<CallState> emit) async {
    _logger.fine('_CallSignalingEventNotifyRefer: $event');
    if (event.subscriptionState != SubscriptionState.terminated) return;
    if (event.state != ReferNotifyState.ok) return;

    // Verifies if the original call line is currently active in the state
    if (state.activeCalls.any((it) => it.callId == event.callId)) add(CallControlEvent.ended(event.callId));
  }

  Future<void> __onCallSignalingEventNotifyUnknown(
    _CallSignalingEventNotifyUnknown event,
    Emitter<CallState> emit,
  ) async {
    _logger.fine('_CallSignalingEventNotifyUnknown: $event');
  }

  Future<void> __onCallSignalingEventRegistration(
    _CallSignalingEventRegistration event,
    Emitter<CallState> emit,
  ) async {
    final registration = Registration(status: event.status, code: event.code, reason: event.reason);
    add(_RegistrationChange(registration: registration));
  }

  /// Handles incoming ICE trickle candidate from the remote peer.
  ///
  /// Buffers the candidate and drains immediately if [setRemoteDescription]
  /// has already been called.  Candidates that arrive before the remote
  /// description is set are held in [_pendingIceCandidates] and applied in
  /// [_drainPendingIceCandidates] after each [setRemoteDescription] call.
  ///
  /// If the call is not yet registered in state (e.g. push case), the candidate
  /// is held in [_orphanedIceCandidates] and moved to [_pendingIceCandidates]
  /// when the call is added to state.
  Future<void> __onCallSignalingEventIceTrickle(
    _CallSignalingEventIceTrickle event,
    Emitter<CallState> emit,
  ) async {
    // null candidate = remote ICE gathering complete — nothing to add.
    final candidateMap = event.candidate;
    if (candidateMap == null) return;

    RTCIceCandidate candidate;
    try {
      candidate = RTCIceCandidate(
        candidateMap['candidate'] as String,
        candidateMap['sdpMid'] as String?,
        candidateMap['sdpMLineIndex'] as int?,
      );
    } catch (e, s) {
      callErrorReporter.handle(e, s, '__onCallSignalingEventIceTrickle parse');
      return;
    }

    // Find the call: prefer callId lookup (reliable), fall back to line lookup.
    ActiveCall? call;
    if (event.callId != null) {
      call = state.activeCalls.where((c) => c.callId == event.callId).firstOrNull;
    }
    call ??= event.line != null
        ? state.activeCalls.where((c) => c.line == event.line).firstOrNull
        : null;

    if (call == null) {
      if (event.callId != null) {
        // Not yet in state — buffer it
        print('[CallBloc] IceTrickle: pre-buffering candidate for callId=${event.callId} (call not yet in state)');
        _orphanedIceCandidates.putIfAbsent(event.callId!, () => []).add(candidate);
      } else {
        // ignore: avoid_print
        print('[CallBloc] IceTrickle: no call found for line=${event.line} and no callId — dropping candidate');
      }
      return;
    }

    // Buffer the candidate — drain only when remote SDP is set.
    _pendingIceCandidates.putIfAbsent(call.callId, () => []).add(candidate);

    // Try to drain immediately (succeeds when setRemoteDescription is already done).
    await _drainPendingIceCandidates(call.callId);
  }

  /// Adds all buffered ICE candidates for [callId] to the peer connection.
  /// Only runs after [setRemoteDescription] has been confirmed via [_remoteDescriptionSet].
  ///
  /// Pass [directPc] when you already hold a reference to the peer connection
  /// (e.g. immediately after answering, before [_peerConnectionComplete] is called).
  /// If omitted, the connection is retrieved from the completer — which requires
  /// the completer to be already completed; if not, the drain is skipped.
  Future<void> _drainPendingIceCandidates(String callId, [RTCPeerConnection? directPc]) async {
    if (!_remoteDescriptionSet.contains(callId)) return;

    final pending = _pendingIceCandidates[callId];
    if (pending == null || pending.isEmpty) return;

    final pc = directPc ?? await _peerConnectionRetrieve(callId, false); // don't wait
    if (pc == null) return;

    final toAdd = List<RTCIceCandidate>.from(pending);
    pending.clear();

    // ignore: avoid_print
    print('[CallBloc] IceTrickle: draining ${toAdd.length} buffered candidates callId=$callId');
    for (final candidate in toAdd) {
      // ignore: avoid_print
      print('[CallBloc] IceTrickle: addCandidate mid=${candidate.sdpMid} idx=${candidate.sdpMLineIndex} → ${candidate.candidate?.split(' ').take(8).join(' ')} callId=$callId');
      try {
        await pc.addCandidate(candidate);
      } catch (e, s) {
        callErrorReporter.handle(e, s, '_drainPendingIceCandidates');
      }
    }
  }

  // processing call control events

  Future<void> _onCallControlEvent(CallControlEvent event, Emitter<CallState> emit) {
    return switch (event) {
      _CallControlEventInitiate() => _onCallControlEventInitiate(event, emit),
      _CallControlEventStarted() => __onCallControlEventStarted(event, emit),
      _CallControlEventAnswered() => __onCallControlEventAnswered(event, emit),
      _CallControlEventEnded() => __onCallControlEventEnded(event, emit),
      _CallControlEventSetHeld() => __onCallControlEventSetHeld(event, emit),
      _CallControlEventSetMuted() => __onCallControlEventSetMuted(event, emit),
      _CallControlEventSentDTMF() => __onCallControlEventSentDTMF(event, emit),
      _CallControlEventCameraSwitched() => _onCallControlEventCameraSwitched(event, emit),
      _CallControlEventCameraEnabled() => _onCallControlEventCameraEnabled(event, emit),
      _CallControlEventAudioDeviceSet() => _onCallControlEventAudioDeviceSet(event, emit),
      _CallControlEventFailureApproved() => _onCallControlEventFailureApproved(event, emit),
      _CallControlEventBlindTransferInitiated() => _onCallControlEventBlindTransferInitiated(event, emit),
      _CallControlEventAttendedTransferInitiated() => _onCallControlEventAttendedTransferInitiated(event, emit),
      _CallControlEventBlindTransferSubmitted() => _onCallControlEventBlindTransferSubmitted(event, emit),
      _CallControlEventAttendedTransferSubmitted() => _onCallControlEventAttendedTransferSubmitted(event, emit),
      _CallControlEventAttendedRequestApproved() => _onCallControlEventAttendedRequestApproved(event, emit),
      _CallControlEventAttendedRequestDeclined() => _onCallControlEventAttendedRequestDeclined(event, emit),
      _CallControlEventAddParticipant() => _onCallControlEventAddParticipant(event, emit),
    };
  }

  Future<void> __onCallControlEventStarted(_CallControlEventStarted event, Emitter<CallState> emit) async {
    // On fresh install (or after coming back from background) the signaling
    // WebSocket may not be connected yet and registration is null.
    // Wait up to kSignalingClientConnectionTimeout for both to be ready
    // before checking registration — the same pattern _continueStartCallIntent uses.
    if (!state.isHandshakeEstablished || !state.isSignalingEstablished) {
      _logger.info('__onCallControlEventStarted: waiting for signaling ready...');
      try {
        await stream
            .firstWhere((s) => s.isHandshakeEstablished && s.isSignalingEstablished)
            .timeout(kSignalingClientConnectionTimeout);
        if (isClosed) return;
      } on TimeoutException {
        _logger.warning('__onCallControlEventStarted: timed out waiting for signaling');
        submitNotification(const SignalingConnectFailedNotification());
        return;
      }
    }

    if (state.callServiceState.registration?.status.isRegistered != true) {
      _logger.info('__onCallControlEventStarted account is not registered');
      submitNotification(CallWhileUnregisteredNotification());
      return;
    }

    int? line;
    if (event.fromNumber != null) {
      line = null;
    } else {
      line = state.retrieveIdleLine();
      if (line == null) {
        _logger.info('__onCallControlEventStarted no idle line');
        submitNotification(const CallUndefinedLineNotification());
        return;
      }
    }

    /// If there is an active call, the call should be put on hold before making a new call.
    /// Or it will be ended automatically by platform (via callkeep:performEndAction).
    await Future.forEach(state.activeCalls, (ActiveCall activeCall) async {
      final shouldHold = activeCall.held == false;
      if (shouldHold) await callkeep.setHeld(activeCall.callId, onHold: true);
    });

    final callId = WebtritSignalingClient.generateCallId();
    final contactName = await contactNameResolver.resolveWithNumber(event.handle.value);
    final displayName = contactName ?? event.displayName;

    final newCall = ActiveCall(
      direction:        CallDirection.outgoing,
      line:             line,
      callId:           callId,
      handle:           event.handle,
      displayName:      displayName,
      video:            event.video,
      createdTime:      clock.now(),
      processingStatus: CallProcessingStatus.outgoingCreated,
      fromReplaces:     event.replaces,
      fromNumber:       event.fromNumber,
    );

    emit(state.copyWithPushActiveCall(newCall).copyWith(minimized: false));

    final callkeepError = await callkeep.startCall(
      callId,
      event.handle,
      displayNameOrContactIdentifier: displayName,
      hasVideo: event.video,
      proximityEnabled: !event.video,
    );

    if (callkeepError != null) {
      if (callkeepError == CallkeepCallRequestError.emergencyNumber) {
        final Uri telLaunchUri = Uri(scheme: 'tel', path: event.handle.value);
        launchUrl(telLaunchUri);
      } else if (callkeepError == CallkeepCallRequestError.selfManagedPhoneAccountNotRegistered) {
        _logger.warning('__onCallControlEventStarted selfManagedPhoneAccountNotRegistered');
        submitNotification(const CallErrorRegisteringSelfManagedPhoneAccountNotification());
      } else {
        _logger.warning('__onCallControlEventStarted callkeepError: $callkeepError');
        onDiagnosticReportRequested(callId, callkeepError);
      }
      _clearPullableCall(callId);
      emit(state.copyWithPopActiveCall(callId));

      return;
    }
  }

  /// Submitting the answer intent to system when answer button is pressed from app ui
  ///
  /// quick shortcut:
  /// call placed in [__onCallSignalingEventIncoming] or [__onCallPushEventIncoming]
  /// continues in [__onCallPerformEventAnswered]
  Future<void> __onCallControlEventAnswered(_CallControlEventAnswered event, Emitter<CallState> emit) async {
    final call = state.retrieveActiveCall(event.callId);
    if (call == null) return;

    // Prevents event doubling and race conditions
    final canSubmitAnswer = switch (call.processingStatus) {
      CallProcessingStatus.incomingFromPush => true,
      CallProcessingStatus.incomingFromOffer => true,
      CallProcessingStatus.conferenceInvitePending => true,
      _ => false,
    };

    if (canSubmitAnswer == false) {
      _logger.info('__onCallControlEventAnswered: skipping due stale status: ${call.processingStatus}');
      return;
    }

    // For conference invites: do NOT overwrite conferenceInvitePending with
    // incomingSubmittedAnswer — __onCallPerformEventAnswered needs to see it.
    if (call.processingStatus == CallProcessingStatus.conferenceInvitePending) {
      final error = await callkeep.answerCall(event.callId);
      if (error != null) _logger.warning('__onCallControlEventAnswered (conference) error: $error');
      return;
    }

    emit(
      state.copyWithMappedActiveCall(
        event.callId,
        (call) => call.copyWith(processingStatus: CallProcessingStatus.incomingSubmittedAnswer),
      ),
    );

    final error = await callkeep.answerCall(event.callId);
    if (error != null) _logger.warning('__onCallControlEventAnswered error: $error');
  }

  Future<void> __onCallControlEventEnded(_CallControlEventEnded event, Emitter<CallState> emit) async {
    final activeCall = state.retrieveActiveCall(event.callId);

    print('╔══ [CALL_END] USER PRESSED HANG UP ══════════════════════════════');
    print('║  callId          : ${event.callId}');
    print('║  direction       : ${activeCall?.direction}');
    print('║  groupName       : ${activeCall?.groupName}');
    print('║  processingStatus: ${activeCall?.processingStatus}');
    print('║  wasAccepted     : ${activeCall?.wasAccepted}');
    print('║  inUnifiedFlow   : ${_unifiedFlowCallIds.contains(event.callId)}');
    print('║  inLiveKit       : ${_livekitRooms.containsKey(event.callId)}');
    print('║  connectedIds    : ${_connectedParticipantIds[event.callId]}');
    print('║  conferenceParticipants: ${activeCall?.conferenceParticipants.map((p) => p.userId).toList()}');
    print('╚═════════════════════════════════════════════════════════════════');

    // ── Unified-flow: outgoing call OR accepted call being ended ──────────────
    //
    // Do ALL cleanup HERE (inside the CallControlEvent sequential queue) so
    // that state.retrieveIdleLine() is correct before the very next
    // CallControlEvent.initiate runs.  The _CallPerformEventEnded callback
    // that arrives asynchronously from callkeep.endCall will be a no-op
    // (handled by the null-guard at the top of __onCallPerformEventEnded).
    //
    // Incoming calls that have NOT yet been accepted (conferenceInvitePending)
    // use the normal endCall → _CallPerformEventEnded → callDecline path below.
    if (_unifiedFlowCallIds.contains(event.callId) &&
        activeCall?.processingStatus != CallProcessingStatus.conferenceInvitePending) {
      print('[CALL_END] → unified-flow branch: sending call_hangup and cleaning up');
      await _signalingClient
          ?.execute(CallHangupRequest(
            transaction: WebtritSignalingClient.generateTransactionId(),
            callId: event.callId,
          ))
          .catchError((e, s) => _logger.warning('[Room] call_hangup error (endCall)', e, s));
      _connectedParticipantIds.remove(event.callId);
      final lkRoom = _livekitRooms.remove(event.callId);
      if (lkRoom != null) await lkRoom.disconnect();
      _livekitUrls.remove(event.callId);
      _livekitTokens.remove(event.callId);
      _unifiedFlowCallIds.remove(event.callId);
      _clearPullableCall(event.callId);
      emit(state.copyWithPopActiveCall(event.callId));
      _logger.info('[Room] __onCallControlEventEnded: ended callId=${event.callId}');
      // Still tell the native CallKeep framework to clean up the call UI.
      // The resulting _CallPerformEventEnded will be handled as a no-op.
      await callkeep.endCall(event.callId);
      return;
    }

    // ── Legacy flow / incoming unified-flow decline ───────────────────────────
    emit(
      state.copyWithMappedActiveCall(event.callId, (activeCall) {
        return activeCall.copyWith(processingStatus: CallProcessingStatus.disconnecting);
      }),
    );

    final error = await callkeep.endCall(event.callId);
    // Handle the case where the local connection is no longer available,
    // sending the call completion event directly to the signaling.
    if (error == CallkeepCallRequestError.unknownCallUuid) {
      add(_CallPerformEvent.ended(event.callId));
    }
    if (error != null) {
      _logger.warning('__onCallControlEventEnded error: $error');
    }
  }

  Future<void> __onCallControlEventSetHeld(_CallControlEventSetHeld event, Emitter<CallState> emit) async {
    final error = await callkeep.setHeld(event.callId, onHold: event.onHold);
    if (error != null) {
      _logger.warning('__onCallControlEventSetHeld error: $error');
    }
  }

  Future<void> __onCallControlEventSetMuted(_CallControlEventSetMuted event, Emitter<CallState> emit) async {
    final error = await callkeep.setMuted(event.callId, muted: event.muted);
    if (error != null) {
      _logger.warning('__onCallControlEventSetMuted error: $error');
    }
  }

  Future<void> __onCallControlEventSentDTMF(_CallControlEventSentDTMF event, Emitter<CallState> emit) async {
    final error = await callkeep.sendDTMF(event.callId, event.key);
    if (error != null) {
      _logger.warning('__onCallControlEventSentDTMF error: $error');
    }
  }

  Future<void> _onCallControlEventCameraSwitched(_CallControlEventCameraSwitched event, Emitter<CallState> emit) async {
    // LiveKit mode: delegate camera switch to the room manager.
    final lkRoom = _livekitRooms[event.callId];
    if (lkRoom != null) {
      try {
        await lkRoom.switchCamera();
      } catch (e) {
        _logger.warning('_onCallControlEventCameraSwitched (LiveKit) error: $e');
      }
      return;
    }

    // WebRTC mode (original behaviour).
    emit(
      state.copyWithMappedActiveCall(event.callId, (activeCall) {
        return activeCall.copyWith(frontCamera: null);
      }),
    );
    final frontCamera = await state.performOnActiveCall(event.callId, (activeCall) {
      final videoTrack = activeCall.localStream?.getVideoTracks()[0];
      if (videoTrack != null) {
        return Helper.switchCamera(videoTrack);
      }
    });
    emit(
      state.copyWithMappedActiveCall(event.callId, (activeCall) {
        return activeCall.copyWith(frontCamera: frontCamera);
      }),
    );
  }

  /// Enables or disables the camera for the active call, using local track enable state.
  ///
  /// If its audiocall, try to upgrade to videocal using renegotiation
  /// by adding the tracks to the peer connection.
  /// after succes [_createPeerConnection].onRenegotiationNeeded will fired accordingly to webrtc state
  /// than [__onCallSignalingEventAccepted] will be called as acknowledge of [UpdateRequest] with new remote jsep.
  Future<void> _onCallControlEventCameraEnabled(_CallControlEventCameraEnabled event, Emitter<CallState> emit) async {
    final activeCall = state.retrieveActiveCall(event.callId);
    if (activeCall == null) return;

    // ── LiveKit mode ────────────────────────────────────────────────────────
    final lkRoom = _livekitRooms[event.callId];
    if (lkRoom != null) {
      try {
        await lkRoom.setCameraEnabled(event.enabled);
        _livekitCameraEnabled[event.callId] = event.enabled;
        // Emit a state change so the shell's buildWhen detects the update.
        // We use frontCamera as the camera-active signal for LiveKit:
        //   null / true  → camera active
        //   false        → camera inactive
        emit(state.copyWithMappedActiveCall(event.callId, (call) => call.copyWith(
          // Enable the video flag on first camera activation (audio→video upgrade).
          video: event.enabled ? true : call.video,
          // null / true = enabled, false = disabled.
          // Reset to null (not false) when re-enabling so the ?? operator in
          // subsequent reads does not get stuck on the previous false value.
          frontCamera: event.enabled ? null : false,
        )));
        if (event.enabled) {
          await callkeep.reportUpdateCall(event.callId, hasVideo: true);
        }
      } catch (e) {
        _logger.warning('_onCallControlEventCameraEnabled (LiveKit) error: $e');
      }
      return;
    }
    // ── WebRTC mode ─────────────────────────────────────────────────────────

    final localStream = activeCall.localStream;
    if (localStream == null) return;

    final currentVideoTrack = localStream.getVideoTracks().firstOrNull;
    if (currentVideoTrack != null) {
      currentVideoTrack.enabled = event.enabled;
      return;
    }

    final peerConnection = await _peerConnectionRetrieve(event.callId);
    if (peerConnection == null) return;

    try {
      // Capture new audio and video pair together to avoid time sync issues
      // and avoid storing separate audio and video tracks to control them on mute, camera switch etc
      final newLocalStream = await userMediaBuilder.build(video: true, frontCamera: activeCall.frontCamera);

      final newAudioTrack = newLocalStream.getAudioTracks().firstOrNull;
      final newVideoTrack = newLocalStream.getVideoTracks().firstOrNull;

      final senders = await peerConnection.getSenders();
      final audioSender = senders.firstWhereOrNull((s) => s.track?.kind == 'audio');
      final videoSender = senders.firstWhereOrNull((s) => s.track?.kind == 'video');

      /// Replace audio/video tracks using existing senders to avoid adding new m= lines
      ///
      /// Alternatively, you can use (remove || stop) + add tracks flow
      /// but it has weak support on infrastructure level:
      /// - second audio m= line causes problems with call recordings and music on hold
      /// - second video m= line causes empty video stream
      ///
      /// So for best compatibility, use existing senders and control them via .enabled or .replaceTrack
      if (audioSender != null && newAudioTrack != null) {
        await audioSender.track?.stop();
        await audioSender.replaceTrack(newAudioTrack);
      } else if (newAudioTrack != null) {
        final audioSenderResult = await peerConnection.safeAddTrack(newAudioTrack, newLocalStream);
        _checkSenderResult(audioSenderResult, 'audio');
      }

      if (videoSender != null && newVideoTrack != null) {
        await videoSender.track?.stop();
        await videoSender.replaceTrack(newVideoTrack);
      } else if (newVideoTrack != null) {
        final videoSenderResult = await peerConnection.safeAddTrack(newVideoTrack, newLocalStream);
        _checkSenderResult(videoSenderResult, 'video');
      }

      emit(
        state.copyWithMappedActiveCall(event.callId, (call) => call.copyWith(localStream: newLocalStream, video: true)),
      );

      await callkeep.reportUpdateCall(event.callId, hasVideo: true);
    } on UserMediaError catch (e) {
      _logger.warning('_onCallControlEventCameraEnabled cant enable: $e');
      submitNotification(const CallUserMediaErrorNotification());
    }
  }

  Future<void> _onCallControlEventAudioDeviceSet(_CallControlEventAudioDeviceSet event, Emitter<CallState> emit) async {
    await state.performOnActiveCall(event.callId, (activeCall) async {
      if (Platform.isAndroid) {
        callkeep.setAudioDevice(event.callId, event.device.toCallkeep());
      } else if (Platform.isIOS) {
        if (event.device.type == CallAudioDeviceType.speaker) {
          Helper.setSpeakerphoneOn(true);
        } else {
          Helper.setSpeakerphoneOn(false);
          final deviceId = event.device.id;
          if (deviceId != null) Helper.selectAudioInput(deviceId);
        }
      }
    });
  }

  Future<void> _onCallControlEventFailureApproved(
    _CallControlEventFailureApproved event,
    Emitter<CallState> emit,
  ) async {
    emit(
      state.copyWithMappedActiveCall(event.callId, (activeCall) {
        return activeCall.copyWith(failure: null);
      }),
    );
  }

  Future<void> _onCallControlEventBlindTransferInitiated(
    _CallControlEventBlindTransferInitiated event,
    Emitter<CallState> emit,
  ) async {
    var newState = state.copyWith(
      minimized: true,
      speakerOnBeforeMinimize: state.audioDevice?.type == CallAudioDeviceType.speaker,
    );
    await __onCallControlEventSetHeld(_CallControlEventSetHeld(event.callId, true), emit);

    newState = newState.copyWithMappedActiveCall(event.callId, (activeCall) {
      return activeCall.copyWith(transfer: const Transfer.blindTransferInitiated());
    });

    emit(newState);

    await callkeep.reportUpdateCall(state.activeCalls.current.callId, proximityEnabled: state.shouldListenToProximity);
  }

  Future<void> _onCallControlEventAttendedTransferInitiated(
    _CallControlEventAttendedTransferInitiated event,
    Emitter<CallState> emit,
  ) async {
    emit(
      state.copyWith(minimized: true, speakerOnBeforeMinimize: state.audioDevice?.type == CallAudioDeviceType.speaker),
    );
    await __onCallControlEventSetHeld(_CallControlEventSetHeld(event.callId, true), emit);
  }

  Future<void> _onCallControlEventBlindTransferSubmitted(
    _CallControlEventBlindTransferSubmitted event,
    Emitter<CallState> emit,
  ) async {
    final activeCallBlindTransferInitiated = state.activeCalls.blindTransferInitiated;
    final currentCall = state.activeCalls.current;

    final line = activeCallBlindTransferInitiated?.line ?? currentCall.line;
    final callId = activeCallBlindTransferInitiated?.callId ?? currentCall.callId;

    // Check if the number is already in active calls
    final isNumberAlreadyConnected = state.activeCalls.any((call) => call.handle.value == event.number);
    if (isNumberAlreadyConnected) {
      submitNotification(ActiveLineBlindTransferWarningNotification());
      return;
    }

    try {
      final transferRequest = TransferRequest(
        transaction: WebtritSignalingClient.generateTransactionId(),
        line: line,
        callId: callId,
        number: event.number,
      );

      await _signalingClient?.execute(transferRequest);

      var newState = state.copyWith(minimized: false);
      newState = newState.copyWithMappedActiveCall(callId, (activeCall) {
        final transfer = Transfer.blindTransferTransferSubmitted(toNumber: event.number);
        return activeCall.copyWith(transfer: transfer);
      });
      emit(newState);

      await callkeep.reportUpdateCall(
        state.activeCalls.current.callId,
        proximityEnabled: state.shouldListenToProximity,
      );

      if (state.speakerOnBeforeMinimize == true) {
        add(CallControlEvent.audioDeviceSet(state.activeCalls.current.callId, state.availableAudioDevices.getSpeaker));
      }

      // After request succesfully submitted, transfer flow will continue
      // by TransferringEvent event from anus and handled in [_CallSignalingEventTransferring]
      // that means that call transfering is now in progress
    } catch (e, s) {
      callErrorReporter.handle(e, s, '_onCallControlEventBlindTransferSubmitted request error:');
    }
  }

  Future<void> _onCallControlEventAttendedTransferSubmitted(
    _CallControlEventAttendedTransferSubmitted event,
    Emitter<CallState> emit,
  ) async {
    final referorCall = event.referorCall;
    final replaceCall = event.replaceCall;

    try {
      final transferRequest = TransferRequest(
        transaction: WebtritSignalingClient.generateTransactionId(),
        line: referorCall.line,
        callId: referorCall.callId,
        number: replaceCall.handle.normalizedValue(),
        replaceCallId: replaceCall.callId,
      );

      await _signalingClient?.execute(transferRequest);

      emit(
        state.copyWithMappedActiveCall(referorCall.callId, (activeCall) {
          final transfer = Transfer.attendedTransferTransferSubmitted(replaceCallId: replaceCall.callId);
          return activeCall.copyWith(transfer: transfer);
        }),
      );

      // After request succesfully submitted, transfer flow will continue
      // by TransferringEvent event from anus and handled in [_CallSignalingEventTransferring]
      // that means that call transfering is now in progress
    } catch (e, s) {
      callErrorReporter.handle(e, s, '_onCallControlEventAttendedTransferSubmitted request error:');
    }
  }

  Future<void> _onCallControlEventAttendedRequestApproved(
    _CallControlEventAttendedRequestApproved event,
    Emitter<CallState> emit,
  ) async {
    final referId = event.referId;
    final referTo = event.referTo;

    final newHandle = CallkeepHandle.number(referTo);

    final callId = WebtritSignalingClient.generateCallId();

    final error = await callkeep.startCall(callId, newHandle, hasVideo: false, proximityEnabled: true);

    if (error != null) {
      _logger.warning('__onCallControlEventStarted error: $error');
      submitNotification(ErrorMessageNotification(error.toString()));
      return;
    }

    final newCall = ActiveCall(
      direction: CallDirection.outgoing,
      line: state.retrieveIdleLine() ?? _kUndefinedLine,
      callId: callId,
      handle: newHandle,
      fromReferId: referId,
      video: false,
      createdTime: clock.now(),
      processingStatus: CallProcessingStatus.outgoingCreatedFromRefer,
    );

    emit(state.copyWithPushActiveCall(newCall).copyWith(minimized: false));
  }

  Future<void> _onCallControlEventAttendedRequestDeclined(
    _CallControlEventAttendedRequestDeclined event,
    Emitter<CallState> emit,
  ) async {
    final referId = event.referId;
    final callId = event.callId;

    final call = state.retrieveActiveCall(callId);
    if (call == null) return;

    try {
      final declineRequest = DeclineRequest(
        transaction: WebtritSignalingClient.generateTransactionId(),
        line: call.line,
        callId: callId,
        referId: referId,
      );

      await _signalingClient?.execute(declineRequest);

      emit(
        state.copyWithMappedActiveCall(callId, (activeCall) {
          return activeCall.copyWith(transfer: null);
        }),
      );
    } catch (e, s) {
      callErrorReporter.handle(e, s, '_onCallControlEventAttendedRequestDeclined request error:');
    }
  }

  // processing call perform events

  Future<void> _onCallPerformEvent(_CallPerformEvent event, Emitter<CallState> emit) {
    return switch (event) {
      _CallPerformEventStarted() => __onCallPerformEventStarted(event, emit),
      _CallPerformEventAnswered() => __onCallPerformEventAnswered(event, emit),
      _CallPerformEventEnded() => __onCallPerformEventEnded(event, emit),
      _CallPerformEventSetHeld() => __onCallPerformEventSetHeld(event, emit),
      _CallPerformEventSetMuted() => __onCallPerformEventSetMuted(event, emit),
      _CallPerformEventSentDTMF() => __onCallPerformEventSentDTMF(event, emit),
      _CallPerformEventAudioDeviceSet() => __onCallPerformEventAudioDeviceSet(event, emit),
      _CallPerformEventAudioDevicesUpdate() => __onCallPerformEventAudioDevicesUpdate(event, emit),
    };
  }

  Future<void> __onCallPerformEventStarted(_CallPerformEventStarted event, Emitter<CallState> emit) async {
    // Unified-flow calls are fully set up in _onCallControlEventInitiate via call_initiate.
    // The native side still fires performStartCall — just acknowledge it and return.
    // Sending a SIP OutgoingCallRequest here would conflict with the unified flow and
    // cause the call to be torn down immediately by the error handler.
    if (_unifiedFlowCallIds.contains(event.callId)) {
      event.fulfill();
      _logger.info('[Room] __onCallPerformEventStarted: unified-flow call, skipping SIP path callId=${event.callId}');
      return;
    }

    if (state.callServiceState.registration?.status.isRegistered != true) {
      _logger.info('__onCallPerformEventStarted account is not registered');
      submitNotification(CallWhileUnregisteredNotification());

      event.fail();
      return;
    }

    if (await state.performOnActiveCall(event.callId, (activeCall) => activeCall.line != _kUndefinedLine) != true) {
      event.fail();

      _clearPullableCall(event.callId);
      emit(state.copyWithPopActiveCall(event.callId));

      submitNotification(const CallUndefinedLineNotification());
      return;
    }

    ///
    /// Ensuring that the signaling client is connected before attempting to make an outgoing call
    ///

    bool signalingConnected = state.callServiceState.signalingClientStatus.isConnect;

    // Attempt to wait for the desired signaling client status within the signaling client connection timeout period
    if (signalingConnected == false) {
      emit(
        state.copyWithMappedActiveCall(event.callId, (activeCall) {
          return activeCall.copyWith(processingStatus: CallProcessingStatus.outgoingConnectingToSignaling);
        }),
      );

      final nextStatus = await stream
          .firstWhere(
            (state) =>
                state.callServiceState.signalingClientStatus.isConnect ||
                state.callServiceState.signalingClientStatus.isFailure,
            orElse: () => state,
          )
          .timeout(kSignalingClientConnectionTimeout, onTimeout: () => state);
      signalingConnected = nextStatus.callServiceState.signalingClientStatus.isConnect;
      if (isClosed) return;
    }

    // If the signaling client is not connected, hung up the call and notify user
    if (signalingConnected == false) {
      event.fail();

      // Notice that the tube was already hung up to avoid sending an extra event to the server
      emit(
        state.copyWithMappedActiveCall(event.callId, (activeCall) {
          return activeCall.copyWith(hungUpTime: clock.now());
        }),
      );

      // Remove local connection
      callkeep.endCall(event.callId);

      submitNotification(const CallWhileOfflineNotification());
      return;
    }

    ///
    /// LiveKit mode: skip WebRTC entirely — send outgoing_call without jsep.
    /// LiveKit token will arrive in the ringing event after callee acknowledges receipt.
    ///
    try {
      final activeCall = state.retrieveActiveCall(event.callId);
      event.fulfill();

      emit(
        state.copyWithMappedActiveCall(event.callId, (activeCall) {
          return activeCall.copyWith(processingStatus: CallProcessingStatus.outgoingOfferSent);
        }),
      );

      await _signalingClient?.execute(
        OutgoingCallRequest(
          transaction: WebtritSignalingClient.generateTransactionId(),
          line: activeCall!.line,
          from: activeCall.fromNumber,
          callId: activeCall.callId,
          number: activeCall.handle.normalizedValue(),
          hasVideo: event.video,
          referId: activeCall.fromReferId,
          replaces: activeCall.fromReplaces,
          // jsep is null — LiveKit mode: backend generates room + tokens
        ),
      );

      await callkeep.reportConnectingOutgoingCall(event.callId);
    } catch (e, s) {
      callErrorReporter.handle(e, s, '__onCallPerformEventStarted error:');
      await _stopRingbackSound();
      _peerConnectionCompleteError(event.callId, e);
      add(_ResetStateEvent.completeCall(event.callId));
    }
  }

  /// Performs answer after incoming call accepted by ui call controlls or native controls
  /// quick shortcuts:
  /// ui control event - [__onCallControlEventAnswered]
  /// after success - [__onCallSignalingEventAccepted]
  /// jsep processing in - [__onCallSignalingEventIncoming]
  Future<void> __onCallPerformEventAnswered(_CallPerformEventAnswered event, Emitter<CallState> emit) async {
    event.fulfill();

    ActiveCall? call = state.retrieveActiveCall(event.callId);
    if (call == null) return;

    // Conference invite accept: user tapped Accept on the incoming call UI.
    if (call.processingStatus == CallProcessingStatus.conferenceInvitePending) {
      event.fulfill();
      final livekitUrl   = _livekitUrls[event.callId];
      final livekitToken = _livekitTokens[event.callId];
      if (livekitUrl == null || livekitToken == null) {
        _logger.warning('[Room] __onCallPerformEventAnswered: no LiveKit credentials for ${event.callId}');
        return;
      }
      try {
        await _joinLiveKitConference(event.callId, livekitUrl, livekitToken, emit);
        await _signalingClient?.execute(
          CallAcceptRequest(
            transaction: WebtritSignalingClient.generateTransactionId(),
            callId: event.callId,
          ),
        );
        _logger.info('[Room] call_accept sent callId=${event.callId}');
        emit(state.copyWithMappedActiveCall(event.callId, (call) {
          return call.copyWith(
            processingStatus: CallProcessingStatus.connected,
            acceptedTime: clock.now(),
          );
        }));
      } catch (e, s) {
        _logger.warning('[Room] __onCallPerformEventAnswered error', e, s);
      }
      return;
    }

    // Prevent performing double answer and race conditions
    //
    // Main case happens when the call is answered from background(ios) or from the lock screen using navite controls
    // In such case performAnswered called emidiately and after signaling initialized via
    // [IncomingEvent] + (callAlreadyAnswered == true) > [callControlAnswered] > [performAnswered] called again
    //
    final canPerformAnswer = switch (call.processingStatus) {
      CallProcessingStatus.incomingFromPush => true,
      CallProcessingStatus.incomingFromOffer => true,
      CallProcessingStatus.incomingSubmittedAnswer => true,
      CallProcessingStatus.conferenceInvitePending => true,
      _ => false,
    };

    if (canPerformAnswer == false) {
      _logger.info('__onCallPerformEventAnswered: skipping due stale status: ${call.processingStatus}');
      return;
    }

    emit(
      state.copyWithMappedActiveCall(event.callId, (call) {
        return call.copyWith(processingStatus: CallProcessingStatus.incomingPerformingStarted);
      }),
    );

    try {
      final isLiveKit = _livekitTokens.containsKey(event.callId);

      if (!isLiveKit) {
        /// Prevent performing answer without offer (WebRTC mode only)
        ///
        /// Main case happens when the call is answered from push event while signaling is disconnected
        /// and main [IncomingEvent] with offer wasnt received yet
        ///
        if (call.incomingOffer == null) {
          _logger.info('__onCallPerformEventAnswered: wait for offer');

          await stream
              .firstWhere((s) {
                final activeCall = s.retrieveActiveCall(event.callId);
                return activeCall?.incomingOffer != null;
              })
              .timeout(
                const Duration(seconds: 10),
                onTimeout: () {
                  throw TimeoutException('Timed out waiting for offer');
                },
              );

          call = state.retrieveActiveCall(event.callId)!;
        }
        final offer = call.incomingOffer!;

        emit(
          state.copyWithMappedActiveCall(event.callId, (call) {
            return call.copyWith(processingStatus: CallProcessingStatus.incomingInitializingMedia);
          }),
        );

        final localStream = await userMediaBuilder.build(video: offer.hasVideo, frontCamera: call.frontCamera);
        final peerConnection = await _createPeerConnection(event.callId, call.line);
        final calleeTracks = localStream.getTracks();
        // ignore: avoid_print
        print('[CallBloc] 🎬 addTracks (callee): ${calleeTracks.map((t) => "${t.kind}(enabled=${t.enabled})").join(", ")} offer.hasVideo=${offer.hasVideo}');
        await Future.forEach(calleeTracks, (t) => peerConnection.addTrack(t, localStream));

        emit(
          state.copyWithMappedActiveCall(event.callId, (call) {
            return call.copyWith(localStream: localStream, processingStatus: CallProcessingStatus.incomingAnswering);
          }),
        );

        final remoteDescription = offer.toDescription();
        sdpSanitizer?.apply(remoteDescription);
        // ignore: avoid_print
        print('[CallBloc] 📋 OFFER SDP (callee, callId=${event.callId}):\n${remoteDescription.sdp}');
        await peerConnection.setRemoteDescription(remoteDescription);
        _remoteDescriptionSet.add(event.callId);
        // Pass peerConnection directly — the completer is not complete yet at this point.
        await _drainPendingIceCandidates(event.callId, peerConnection);
        final localDescription = await peerConnection.createAnswer({});
        // ignore: avoid_print
        print('[CallBloc] 📋 ANSWER SDP (callee generated, callId=${event.callId}):\n${localDescription.sdp}');
        sdpMunger?.apply(localDescription);

        // According to RFC 8829 5.6 (https://datatracker.ietf.org/doc/html/rfc8829#section-5.6),
        // localDescription should be set before sending the answer to transition into stable state.
        await peerConnection.setLocalDescription(localDescription).catchError((e) => throw SDPConfigurationError(e));

        await _signalingClient?.execute(
          AcceptRequest(
            transaction: WebtritSignalingClient.generateTransactionId(),
            line: call.line,
            callId: call.callId,
            jsep: localDescription.toMap(),
          ),
        );

        _peerConnectionComplete(event.callId, peerConnection);
        // Drain ICE candidates that arrived before setLocalDescription completed
        // (the earlier drain at line ~2020 returned null because the completer
        // wasn't complete yet; now it is, so we can actually apply them).
        await _drainPendingIceCandidates(event.callId);
      } else {
        // ── LiveKit mode: skip WebRTC entirely ──────────────────────────────
        _logger.info('__onCallPerformEventAnswered: LiveKit mode callId=${event.callId}');

        emit(
          state.copyWithMappedActiveCall(event.callId, (call) {
            return call.copyWith(processingStatus: CallProcessingStatus.incomingAnswering);
          }),
        );

        // Wait until signaling line is known (incoming event sets it)
        if (call.line == _kUndefinedLine) {
          await stream
              .firstWhere((s) => (s.retrieveActiveCall(event.callId)?.line ?? _kUndefinedLine) != _kUndefinedLine)
              .timeout(const Duration(seconds: 10), onTimeout: () => state);
          call = state.retrieveActiveCall(event.callId) ?? call;
        }

        // Send accept without jsep
        await _signalingClient?.execute(
          AcceptRequest(
            transaction: WebtritSignalingClient.generateTransactionId(),
            line: call.line,
            callId: call.callId,
          ),
        );

        // Signal "no WebRTC peer connection"
        _peerConnectionCompleteError(event.callId, const LiveKitModeSignal());

        // Connect to LiveKit room
        final livekitUrl   = _livekitUrls[event.callId]!;
        final livekitToken = _livekitTokens[event.callId]!;
        final videoEnabled = call.video;

        final roomManager = LiveKitRoomManager();
        _livekitRooms[event.callId] = roomManager;

        roomManager.connect(
          url:          livekitUrl,
          token:        livekitToken,
          videoEnabled: videoEnabled,
        ).catchError((e) => _logger.warning('LiveKit callee connect error callId=${event.callId}: $e'));
      }

      // Self-transition callee to connected state immediately after AcceptRequest succeeds.
      //
      // In the normal (app-open) scenario the server sends AcceptedEvent to both caller and
      // callee, so __onCallSignalingEventAccepted handles the transition. But when the app
      // is launched from a push notification there are briefly two WebSocket sessions
      // (IncomingCallService + main app). Even after the background session disconnects,
      // the server may route AcceptedEvent to the old (now-closed) session, meaning the
      // callee never receives it and the UI stays on the incoming-call screen forever.
      //
      // Transitioning here is semantically correct: the server acknowledged the AcceptRequest
      // (AckResponse received above), so the call is accepted. If AcceptedEvent does arrive
      // later, __onCallSignalingEventAccepted is a no-op because acceptedTime is already set.
      final acceptedCall = state.retrieveActiveCall(event.callId);
      if (acceptedCall != null && acceptedCall.acceptedTime == null) {
        emit(
          state.copyWithMappedActiveCall(event.callId, (c) {
            return c.copyWith(
              processingStatus: CallProcessingStatus.connected,
              acceptedTime: clock.now(),
            );
          }),
        );
      }
    } catch (e, s) {
      _peerConnectionCompleteError(event.callId, e);
      add(_ResetStateEvent.completeCall(event.callId));

      _addToRecents(call!);

      final declineId = WebtritSignalingClient.generateTransactionId();
      final declineRequest = DeclineRequest(transaction: declineId, line: call.line, callId: call.callId);
      _signalingClient?.execute(declineRequest).ignore();

      callErrorReporter.handle(e, s, '__onCallPerformEventAnswered error:');
    }
  }

  Future<void> __onCallPerformEventEnded(_CallPerformEventEnded event, Emitter<CallState> emit) async {
    // Condition occur when the user interacts with a push notification before signaling is properly initialized.
    // In this case, the CallKeep method "reportNewIncomingCall" may return callIdAlreadyTerminated.
    if (state.retrieveActiveCall(event.callId)?.line == _kUndefinedLine) {
      add(_ResetStateEvent.completeCall(event.callId));
      return;
    }

    // Guard: unified-flow outgoing/active calls are fully cleaned up in
    // __onCallControlEventEnded (including state.copyWithPopActiveCall).
    // The _CallPerformEventEnded callback arrives here asynchronously; since
    // the call is already gone from state AND _unifiedFlowCallIds, just fulfil
    // the CallKeep action and return.
    if (state.retrieveActiveCall(event.callId) == null &&
        !_unifiedFlowCallIds.contains(event.callId)) {
      event.fulfill();
      _logger.fine('[Room] __onCallPerformEventEnded: call already cleaned up callId=${event.callId}');
      return;
    }

    if (state.retrieveActiveCall(event.callId)?.wasHungUp == true) {
      // TODO: There's an issue where the user might have already ended the call, but the active call screen remains visible.
      if (state.isActive) {
        _clearPullableCall(event.callId);
        emit(state.copyWithPopActiveCall(event.callId));
      }
      event.fail();
      return;
    }

    // Unified-flow invite decline: user tapped Decline before accepting.
    final activeCallForDecline = state.retrieveActiveCall(event.callId);
    final isIncomingUnifiedDecline = _unifiedFlowCallIds.contains(event.callId) &&
        (activeCallForDecline?.processingStatus == CallProcessingStatus.conferenceInvitePending ||
            (activeCallForDecline == null || activeCallForDecline.direction == CallDirection.incoming && !activeCallForDecline.wasAccepted));
    if (isIncomingUnifiedDecline) {
      event.fulfill();
      await _signalingClient
          ?.execute(CallDeclineRequest(
            transaction: WebtritSignalingClient.generateTransactionId(),
            callId: event.callId,
          ))
          .catchError((e, s) => _logger.warning('[Room] call_decline error', e, s));
      _unifiedFlowCallIds.remove(event.callId);
      _livekitUrls.remove(event.callId);
      _livekitTokens.remove(event.callId);
      _clearPullableCall(event.callId);
      emit(state.copyWithPopActiveCall(event.callId));
      _logger.info('[Room] invite declined callId=${event.callId}');
      return;
    }

    // Unified-flow call end: send call_hangup for any unified-flow call,
    // regardless of accepted state. This covers:
    //   • Caller cancels before any callee accepts (wasAccepted == false)
    //   • Caller/callee leaves an active call (wasAccepted == true)
    final activeGroupCall = state.retrieveActiveCall(event.callId);
    if (_unifiedFlowCallIds.contains(event.callId)) {
      event.fulfill();
      await _signalingClient
          ?.execute(CallHangupRequest(
            transaction: WebtritSignalingClient.generateTransactionId(),
            callId: event.callId,
          ))
          .catchError((e, s) => _logger.warning('[Room] call_hangup error', e, s));
      final lkRoom = _livekitRooms.remove(event.callId);
      if (lkRoom != null) await lkRoom.disconnect();
      _livekitUrls.remove(event.callId);
      _livekitTokens.remove(event.callId);
      _unifiedFlowCallIds.remove(event.callId);
      _clearPullableCall(event.callId);
      emit(state.copyWithPopActiveCall(event.callId));
      _logger.info('[Room] ended call callId=${event.callId}');
      return;
    }

    event.fulfill();

    await _stopRingbackSound();

    emit(
      state.copyWithMappedActiveCall(event.callId, (activeCall) {
        final activeCallUpdated = activeCall.copyWith(hungUpTime: clock.now());
        _addToRecents(activeCallUpdated);
        return activeCallUpdated;
      }),
    );

    await state.performOnActiveCall(event.callId, (activeCall) async {
      if (activeCall.isIncoming && !activeCall.wasAccepted) {
        final declineRequest = DeclineRequest(
          transaction: WebtritSignalingClient.generateTransactionId(),
          line: activeCall.line,
          callId: activeCall.callId,
        );
        await _signalingClient?.execute(declineRequest).catchError((e, s) {
          callErrorReporter.handle(e, s, '__onCallPerformEventEnded declineRequest error');
        });
      } else {
        final hangupRequest = HangupRequest(
          transaction: WebtritSignalingClient.generateTransactionId(),
          line: activeCall.line,
          callId: activeCall.callId,
        );
        await _signalingClient?.execute(hangupRequest).catchError((e, s) {
          callErrorReporter.handle(e, s, '__onCallPerformEventEnded hangupRequest error');
        });
      }

      // Need to close peer connection after executing [HangupRequest]
      // to prevent "Simulate a "hangup" coming from the application"
      // because of "No WebRTC media anymore".
      await (await _peerConnectionRetrieve(activeCall.callId))?.close();
      await activeCall.localStream?.dispose();
    });

    _clearPullableCall(event.callId);
    emit(state.copyWithPopActiveCall(event.callId));
  }

  Future<void> __onCallPerformEventSetHeld(_CallPerformEventSetHeld event, Emitter<CallState> emit) async {
    event.fulfill();

    try {
      await state.performOnActiveCall(event.callId, (activeCall) {
        if (event.onHold) {
          return _signalingClient?.execute(
            HoldRequest(
              transaction: WebtritSignalingClient.generateTransactionId(),
              line: activeCall.line,
              callId: activeCall.callId,
              direction: HoldDirection.inactive,
            ),
          );
        } else {
          return _signalingClient?.execute(
            UnholdRequest(
              transaction: WebtritSignalingClient.generateTransactionId(),
              line: activeCall.line,
              callId: activeCall.callId,
            ),
          );
        }
      });

      emit(
        state.copyWithMappedActiveCall(event.callId, (activeCall) {
          return activeCall.copyWith(held: event.onHold);
        }),
      );
    } catch (e, s) {
      callErrorReporter.handle(e, s, '__onCallPerformEventSetHeld error');

      _peerConnectionCompleteError(event.callId, e);
      add(_ResetStateEvent.completeCall(event.callId));
    }
  }

  Future<void> __onCallPerformEventSetMuted(_CallPerformEventSetMuted event, Emitter<CallState> emit) async {
    event.fulfill();

    await state.performOnActiveCall(event.callId, (activeCall) async {
      final audioTrack = activeCall.localStream?.getAudioTracks()[0];
      if (audioTrack != null) {
        Helper.setMicrophoneMute(event.muted, audioTrack);
      } else {
        // LiveKit mode: mute/unmute the LiveKit audio track directly.
        await _livekitRooms[event.callId]?.setMicEnabled(!event.muted);
      }
    });

    emit(
      state.copyWithMappedActiveCall(event.callId, (activeCall) {
        return activeCall.copyWith(muted: event.muted);
      }),
    );
  }

  Future<void> __onCallPerformEventSentDTMF(_CallPerformEventSentDTMF event, Emitter<CallState> emit) async {
    event.fulfill();

    await state.performOnActiveCall(event.callId, (activeCall) async {
      final peerConnection = await _peerConnectionRetrieve(activeCall.callId);
      if (peerConnection == null) {
        _logger.warning('__onCallPerformEventSentDTMF: peerConnection is null - most likely some permissions issue');
      } else {
        final senders = await peerConnection.senders;
        try {
          final audioSender = senders.firstWhere((sender) {
            final track = sender.track;
            if (track != null) {
              return track.kind == 'audio';
            } else {
              return false;
            }
          });
          await audioSender.dtmfSender.insertDTMF(event.key);
        } on StateError catch (_) {
          _logger.warning('__onCallPerformEventSentDTMF can\'t send DTMF');
        }
      }
    });
  }

  Future<void> __onCallPerformEventAudioDeviceSet(
    _CallPerformEventAudioDeviceSet event,
    Emitter<CallState> emit,
  ) async {
    _logger.info('CallPerformEventAudioDeviceSet: ${event.device}');
    event.fulfill();
    emit(state.copyWith(audioDevice: event.device));
  }

  Future<void> __onCallPerformEventAudioDevicesUpdate(
    _CallPerformEventAudioDevicesUpdate event,
    Emitter<CallState> emit,
  ) async {
    _logger.info('CallPerformEventAudioDevicesUpdate: ${event.devices}');
    event.fulfill();
    emit(state.copyWith(availableAudioDevices: event.devices));
  }

  // processing peer connection events

  Future<void> _onPeerConnectionEvent(_PeerConnectionEvent event, Emitter<CallState> emit) {
    return switch (event) {
      _PeerConnectionEventSignalingStateChanged() => __onPeerConnectionEventSignalingStateChanged(event, emit),
      _PeerConnectionEventConnectionStateChanged() => __onPeerConnectionEventConnectionStateChanged(event, emit),
      _PeerConnectionEventIceGatheringStateChanged() => __onPeerConnectionEventIceGatheringStateChanged(event, emit),
      _PeerConnectionEventIceConnectionStateChanged() => __onPeerConnectionEventIceConnectionStateChanged(event, emit),
      _PeerConnectionEventIceCandidateIdentified() => __onPeerConnectionEventIceCandidateIdentified(event, emit),
      _PeerConnectionEventStreamAdded() => __onPeerConnectionEventStreamAdded(event, emit),
      _PeerConnectionEventStreamRemoved() => __onPeerConnectionEventStreamRemoved(event, emit),
    };
  }

  Future<void> __onPeerConnectionEventSignalingStateChanged(
    _PeerConnectionEventSignalingStateChanged event,
    Emitter<CallState> emit,
  ) async {}

  Future<void> __onPeerConnectionEventConnectionStateChanged(
    _PeerConnectionEventConnectionStateChanged event,
    Emitter<CallState> emit,
  ) async {
    // ignore: avoid_print
    print('[CallBloc] 🔗 PC connectionState → ${event.state.name} callId=${event.callId}');

    switch (event.state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        // ignore: avoid_print
        print('[CallBloc] ✅ PC CONNECTED — media should flow callId=${event.callId}');

      default:
        break;
    }
  }

  Future<void> __onPeerConnectionEventIceGatheringStateChanged(
    _PeerConnectionEventIceGatheringStateChanged event,
    Emitter<CallState> emit,
  ) async {
    // ignore: avoid_print
    print('[CallBloc] 🧊 ICE gathering → ${event.state.name} callId=${event.callId}');
    if (event.state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
      try {
        await state.performOnActiveCall(event.callId, (activeCall) {
          if (!activeCall.wasHungUp) {
            final iceTrickleRequest = IceTrickleRequest(
              transaction: WebtritSignalingClient.generateTransactionId(),
              line: activeCall.line,
              callId: activeCall.callId,
              candidate: null,
            );
            return _signalingClient?.execute(iceTrickleRequest);
          }
        });
      } catch (e, s) {
        // Sending the end-of-gathering null candidate is optional signaling.
        // A failure here must NOT kill the call — ICE may still connect.
        // ignore: avoid_print
        print('[CallBloc] ⚠️ ICE gathering-complete signal failed (non-fatal) callId=${event.callId} error=$e');
        callErrorReporter.handle(e, s, '__onPeerConnectionEventIceGatheringStateChanged error');
      }
    }
  }

  Future<void> __onPeerConnectionEventIceConnectionStateChanged(
    _PeerConnectionEventIceConnectionStateChanged event,
    Emitter<CallState> emit,
  ) async {
    // ignore: avoid_print
    print('[CallBloc] 🧊 ICE connectionState → ${event.state.name} callId=${event.callId}');

    if (event.state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
      final restartCount = (_iceRestartCounts[event.callId] ?? 0) + 1;
      // Cap restarts at 3 to avoid an infinite restart loop.
      if (restartCount > 3) {
        // ignore: avoid_print
        print('[CallBloc] ❌ ICE FAILED after $restartCount restarts — ending call callId=${event.callId}');
        add(CallControlEvent.ended(event.callId));
        return;
      }
      _iceRestartCounts[event.callId] = restartCount;
      // ignore: avoid_print
      print('[CallBloc] ❌ ICE FAILED (#$restartCount) callId=${event.callId} — attempting ICE restart');
      try {
        await state.performOnActiveCall(event.callId, (activeCall) async {
          final peerConnection = await _peerConnectionRetrieve(activeCall.callId, false);
          if (peerConnection == null) {
            _logger.warning(
              '__onPeerConnectionEventIceConnectionStateChanged: peerConnection is null - most likely some state issue',
            );
            return;
          }
          // ignore: avoid_print
          print('[CallBloc] 🔄 ICE restart: createOffer(iceRestart) callId=${event.callId}');
          // Use iceRestart:true flag — compatible with all WebRTC versions.
          final localDescription = await peerConnection.createOffer({'iceRestart': true});
          sdpMunger?.apply(localDescription);

          // According to RFC 8829 5.6, setLocalDescription before sending to remote.
          await peerConnection.setLocalDescription(localDescription);

          final updateRequest = UpdateRequest(
            transaction: WebtritSignalingClient.generateTransactionId(),
            line: activeCall.line,
            callId: activeCall.callId,
            jsep: localDescription.toMap(),
          );
          // ignore: avoid_print
          print('[CallBloc] 📤 sending UpdateRequest (ICE restart) callId=${event.callId}');
          await _signalingClient?.execute(updateRequest);
          // ignore: avoid_print
          print('[CallBloc] ✅ ICE restart offer sent callId=${event.callId}');
        });
      } catch (e, s) {
        // ignore: avoid_print
        print('[CallBloc] ⚠️ ICE restart error (non-fatal) callId=${event.callId} error=$e');
        callErrorReporter.handle(e, s, '__onPeerConnectionEventIceConnectionStateChanged error');
      }
    } else if (event.state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
        event.state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
      // Reset restart counter on successful connection.
      _iceRestartCounts.remove(event.callId);
    }
  }

  Future<void> __onPeerConnectionEventIceCandidateIdentified(
    _PeerConnectionEventIceCandidateIdentified event,
    Emitter<CallState> emit,
  ) async {
    if (iceFilter?.filter(event.candidate) == true) {
      _logger.fine('__onPeerConnectionEventIceCandidateIdentified: skip by iceFiler');
      return;
    }

    try {
      await state.performOnActiveCall(event.callId, (activeCall) {
        if (!activeCall.wasHungUp) {
          final iceTrickleRequest = IceTrickleRequest(
            transaction: WebtritSignalingClient.generateTransactionId(),
            line: activeCall.line,
            callId: activeCall.callId,
            candidate: event.candidate.toMap(),
          );
          return _signalingClient?.execute(iceTrickleRequest);
        }
      });
    } catch (e, s) {
      callErrorReporter.handle(e, s, '__onPeerConnectionEventIceCandidateIdentified error');

      _peerConnectionCompleteError(event.callId, e);
      add(_ResetStateEvent.completeCall(event.callId));
    }
  }

  Future<void> __onPeerConnectionEventStreamAdded(
    _PeerConnectionEventStreamAdded event,
    Emitter<CallState> emit,
  ) async {
    // Skip stub stream created by Janus on unidirectional video
    if (event.stream.id == 'janus') return;

    // Deduplicate: skip if the same stream is already set (onAddStream fires multiple times)
    final existing = state.retrieveActiveCall(event.callId)?.remoteStream;
    if (existing?.id == event.stream.id) {
      // ignore: avoid_print
      print('[CallBloc] 🎥 remoteStream ALREADY SET (dup) callId=${event.callId} streamId=${event.stream.id}');
      return;
    }

    // ignore: avoid_print
    print('[CallBloc] 🎥 remoteStream ADDED callId=${event.callId} '
        'streamId=${event.stream.id} '
        'tracks=${event.stream.getTracks().length}');

    emit(
      state.copyWithMappedActiveCall(event.callId, (activeCall) {
        return activeCall.copyWith(remoteStream: event.stream);
      }),
    );
  }

  Future<void> __onPeerConnectionEventStreamRemoved(
    _PeerConnectionEventStreamRemoved event,
    Emitter<CallState> emit,
  ) async {
    emit(
      state.copyWithMappedActiveCall(event.callId, (activeCall) {
        final prevStream = activeCall.remoteStream;
        if (prevStream != null && prevStream.id == event.stream.id) {
          return activeCall.copyWith(remoteStream: null);
        }
        return activeCall;
      }),
    );
  }

  // procession call screen events

  Future<void> _onCallScreenEvent(CallScreenEvent event, Emitter<CallState> emit) {
    return switch (event) {
      _CallScreenEventDidPush() => __onCallScreenEventDidPush(event, emit),
      _CallScreenEventDidPop() => __onCallScreenEventDidPop(event, emit),
    };
  }

  Future<void> __onCallScreenEventDidPush(_CallScreenEventDidPush event, Emitter<CallState> emit) async {
    final hasActiveCalls = state.activeCalls.isNotEmpty;
    var newState = state.copyWith(minimized: false);

    if (hasActiveCalls) {
      newState = newState.copyWithMappedActiveCalls((activeCall) {
        final transfer = activeCall.transfer;
        if (transfer != null && transfer is BlindTransferInitiated) {
          return activeCall.copyWith(transfer: null);
        } else {
          return activeCall;
        }
      });

      emit(newState);

      await callkeep.reportUpdateCall(
        state.activeCalls.current.callId,
        proximityEnabled: state.shouldListenToProximity,
      );

      if (state.speakerOnBeforeMinimize == true) {
        add(CallControlEvent.audioDeviceSet(state.activeCalls.current.callId, state.availableAudioDevices.getSpeaker));
      }
    } else {
      _logger.warning('__onCallScreenEventDidPush: activeCalls is empty');
    }
  }

  Future<void> __onCallScreenEventDidPop(_CallScreenEventDidPop event, Emitter<CallState> emit) async {
    final shouldMinimize = state.activeCalls.isNotEmpty;
    _logger.info('__onCallScreenEventDidPop: shouldMinimize: $shouldMinimize');

    if (shouldMinimize) {
      emit(
        state.copyWith(
          minimized: true,
          speakerOnBeforeMinimize: state.audioDevice?.type == CallAudioDeviceType.speaker,
        ),
      );
      await callkeep.reportUpdateCall(
        state.activeCalls.current.callId,
        proximityEnabled: state.shouldListenToProximity,
      );
    }
  }

  // Host-app display-name override

  Future<void> _onDisplayNameUpdateEvent(_DisplayNameUpdateEvent event, Emitter<CallState> emit) async {
    final activeCall = state.retrieveActiveCall(event.callId);
    if (activeCall == null) return;
    // Skip if the name is already correct (avoid duplicate CallKeep updates).
    if (activeCall.displayName == event.displayName) return;
    emit(state.copyWithMappedActiveCall(
      event.callId,
      (call) => call.copyWith(displayName: event.displayName),
    ));
    await callkeep.reportUpdateCall(event.callId, displayName: event.displayName, avatarFilePath: event.avatarFilePath);
  }

  // WebtritSignalingClient listen handlers

  void _onSignalingStateHandshake(StateHandshake stateHandshake) async {
    add(
      _HandshakeSignalingEventState(registration: stateHandshake.registration, linesCount: stateHandshake.lines.length),
    );

    _assingUserActiveCalls(stateHandshake.userActiveCalls);
    stateHandshake.contactsPresenceInfo.forEach(_assingNumberPresence);

    // Hang up all active calls that are not associated with any line
    // or guest line, indicating that they are no longer valid.
    //
    // This is needed to drop or retain calls after reconnecting to the signaling server
    activeCallsLoop:
    for (final activeCall in state.activeCalls) {
      // Skip unified-flow (LiveKit) calls — they don't use SIP lines and should
      // never be hung up by the SIP-line reconciliation logic.
      if (_unifiedFlowCallIds.contains(activeCall.callId)) continue activeCallsLoop;

      // Ignore active calls that are already associated with a line or guest line
      //
      // If you have troubles with line position mismatch replace this with
      // following code that deal with it: https://gist.github.com/digiboridev/f7f1020731e8f247b5891983433bd159
      for (final line in [...stateHandshake.lines, stateHandshake.guestLine]) {
        if (line != null && line.callId == activeCall.callId) {
          continue activeCallsLoop;
        }
      }

      // Handles an outgoing active call that has not yet started, typically initiated
      // by the `continueStartCallIntent` callback of `CallkeepDelegate`.
      //
      // TODO: Implement a dedicated flag to confirm successful execution of
      // OutgoingCallRequest, ensuring reliable outgoing active call state tracking.
      if (activeCall.direction == CallDirection.outgoing &&
          activeCall.acceptedTime == null &&
          activeCall.hungUpTime == null) {
        continue activeCallsLoop;
      }

      _peerConnectionConditionalCompleteError(activeCall.callId, 'Active call Request Terminated');

      add(
        _CallSignalingEvent.hangup(
          line: activeCall.line,
          callId: activeCall.callId,
          code: 487,
          reason: 'Request Terminated',
        ),
      );
    }

    final lines = [...stateHandshake.lines, stateHandshake.guestLine].whereType<Line>();
    final localConnections = await callkeepConnections.getConnections();

    for (final activeLine in lines) {
      // Get the first call event from the call logs, if any
      final callEvent = activeLine.callLogs.whereType<CallEventLog>().map((log) => log.callEvent).firstOrNull;

      if (callEvent != null) {
        // Obtain the corresponding Callkeep connection for the line.
        // Callkeep maintains connection states even if the app's lifecycle has ended.
        final connection = await callkeepConnections.getConnection(callEvent.callId);

        // Check if the Callkeep connection exists and its state is `stateDisconnected`.
        // Indicates that the call has been terminated by the user or system (e.g., due to connectivity issues).
        // Synchronize the signaling state with the local state for such scenarios.
        if (connection?.state == CallkeepConnectionState.stateDisconnected) {
          // Handle outgoing or accepted calls. If the event is `AcceptedEvent` or `ProceedingEvent`,
          // initiate a hang-up request to align the signaling state.
          if (callEvent is AcceptedEvent || callEvent is ProceedingEvent) {
            // Handle outgoing or accepted calls. If the event is `AcceptedEvent` or `ProceedingEvent`,
            // initiate a hang-up request to align the signaling state.
            final hangupRequest = HangupRequest(
              transaction: WebtritSignalingClient.generateTransactionId(),
              line: callEvent.line,
              callId: callEvent.callId,
            );
            await _signalingClient?.execute(hangupRequest).catchError((e, s) {
              callErrorReporter.handle(e, s, '__onCallPerformEventEnded hangupRequest error');
            });

            return;
          } else if (callEvent is IncomingCallEvent) {
            // Handle incoming calls. If the event is `IncomingCallEvent`, send a decline request to update the signaling state accordingly.
            final declineRequest = DeclineRequest(
              transaction: WebtritSignalingClient.generateTransactionId(),
              line: callEvent.line,
              callId: callEvent.callId,
            );
            await _signalingClient?.execute(declineRequest).catchError((e, s) {
              callErrorReporter.handle(e, s, '__onCallPerformEventEnded declineRequest error');
            });
            return;
          }
        }
      }

      if (activeLine.callLogs.length == 1) {
        final singleCallLog = activeLine.callLogs.first;
        if (singleCallLog is CallEventLog && singleCallLog.callEvent is IncomingCallEvent) {
          _onSignalingEvent(singleCallLog.callEvent as IncomingCallEvent);
        }
      }
    }

    // Synchronize the signaling state with the local state for calls.
    // If a local connection exists that is not present in the signaling state, end the call to ensure consistency between the local and signaling states.
    for (var connection in localConnections) {
      if (!lines.map((e) => e.callId).contains(connection.callId)) {
        await callkeep.endCall(connection.callId);
      }
    }
  }

  void _onSignalingEvent(Event event) {
    if (event is IncomingCallEvent) {
      add(
        _CallSignalingEvent.incoming(
          line: event.line,
          callId: event.callId,
          callee: event.callee,
          caller: event.caller,
          callerDisplayName: event.callerDisplayName,
          referredBy: event.referredBy,
          replaceCallId: event.replaceCallId,
          isFocus: event.isFocus,
          jsep: JsepValue.fromOptional(event.jsep),
          livekitUrl: event.livekitUrl,
          livekitToken: event.livekitToken,
          hasVideo: event.hasVideo,
        ),
      );
    } else if (event is RingingEvent) {
      add(_CallSignalingEvent.ringing(
        line: event.line,
        callId: event.callId,
        livekitUrl: event.livekitUrl,
        livekitToken: event.livekitToken,
      ));
    } else if (event is ProgressEvent) {
      add(
        _CallSignalingEvent.progress(
          line: event.line,
          callId: event.callId,
          callee: event.callee,
          jsep: JsepValue.fromOptional(event.jsep),
        ),
      );
    } else if (event is AcceptedEvent) {
      add(
        _CallSignalingEvent.accepted(
          line: event.line,
          callId: event.callId,
          callee: event.callee,
          jsep: JsepValue.fromOptional(event.jsep),
        ),
      );
    } else if (event is HangupEvent) {
      add(_CallSignalingEvent.hangup(line: event.line, callId: event.callId, code: event.code, reason: event.reason));
    } else if (event is MissedCallEvent) {
      // Caller cancelled before callee answered — dismiss incoming call UI.
      // Missed call notification is handled via CallkeepEndCallReason.missed
      // in the background path, or the system call log in the foreground path.
      add(_CallSignalingEvent.hangup(line: event.line, callId: event.callId, code: 487, reason: 'unanswered'));
    } else if (event is UpdatingCallEvent) {
      add(
        _CallSignalingEvent.updating(
          line: event.line,
          callId: event.callId,
          callee: event.callee,
          caller: event.caller,
          callerDisplayName: event.callerDisplayName,
          referredBy: event.referredBy,
          replaceCallId: event.replaceCallId,
          isFocus: event.isFocus,
          jsep: JsepValue.fromOptional(event.jsep),
        ),
      );
    } else if (event is UpdatedEvent) {
      add(_CallSignalingEvent.updated(
        line: event.line,
        callId: event.callId,
        jsep: JsepValue.fromOptional(event.jsep),
      ));
    } else if (event is TransferEvent) {
      add(
        _CallSignalingEvent.transfer(
          line: event.line,
          referId: event.referId,
          referTo: event.referTo,
          referredBy: event.referredBy,
          replaceCallId: event.replaceCallId,
        ),
      );
    } else if (event is NotifyEvent) {
      add(switch (event) {
        DialogNotifyEvent event => _CallSignalingEvent.notifyDialog(
          line: event.line,
          callId: event.callId,
          notify: event.notify,
          subscriptionState: event.subscriptionState,
          userActiveCalls: event.userActiveCalls,
        ),
        ReferNotifyEvent event => _CallSignalingEvent.notifyRefer(
          line: event.line,
          callId: event.callId,
          notify: event.notify,
          subscriptionState: event.subscriptionState,
          state: event.state,
        ),
        PresenceNotifyEvent event => _CallSignalingEvent.notifyPresence(
          line: event.line,
          callId: event.callId,
          notify: event.notify,
          subscriptionState: event.subscriptionState,
          number: event.number,
          presenceInfo: event.presenceInfo,
        ),
        UnknownNotifyEvent event => _CallSignalingEvent.notifyUnknown(
          line: event.line,
          callId: event.callId,
          notify: event.notify,
          subscriptionState: event.subscriptionState,
          contentType: event.contentType,
          content: event.content,
        ),
      });
    } else if (event is RegisteringEvent) {
      add(const _CallSignalingEvent.registration(RegistrationStatus.registering));
    } else if (event is RegisteredEvent) {
      add(const _CallSignalingEvent.registration(RegistrationStatus.registered));
    } else if (event is RegistrationFailedEvent) {
      final registrationFailedEvent = _CallSignalingEvent.registration(
        RegistrationStatus.registration_failed,
        code: event.code,
        reason: event.reason,
      );
      add(registrationFailedEvent);
    } else if (event is UnregisteringEvent) {
      add(const _CallSignalingEvent.registration(RegistrationStatus.unregistering));
    } else if (event is UnregisteredEvent) {
      add(const _CallSignalingEvent.registration(RegistrationStatus.unregistered));
    } else if (event is TransferringEvent) {
      add(_CallSignalingEvent.transferring(line: event.line, callId: event.callId));
    } else if (event is CallInviteEvent) {
      add(_CallSignalingEventInvite(
        callId:              event.callId,
        callerNumber:        event.callerNumber,
        callerId:            event.callerId,
        participantNumbers:  event.participantNumbers,
        hasVideo:            event.hasVideo ?? (event.participantNumbers.isNotEmpty ? true : false),
        livekitUrl:          event.livekitUrl,
        livekitToken:        event.livekitToken,
        line:                event.line,
        groupName:           event.groupName,
        chatId:              event.chatId,
      ));
    } else if (event is CallRingingEvent) {
      add(_CallSignalingEventCallRinging(
        callId:       event.callId,
        livekitUrl:   event.livekitUrl,
        livekitToken: event.livekitToken,
        line:         event.line,
      ));
    } else if (event is CallAcceptedEvent) {
      add(_CallSignalingEventCallAccepted(callId: event.callId, line: event.line));
    } else if (event is CallEndedEvent) {
      add(_CallSignalingEventCallEnded(callId: event.callId, reason: event.reason, line: event.line));
    } else if (event is ParticipantJoinedEvent) {
      add(_CallSignalingEventParticipantJoined(
        callId: event.callId,
        userId: event.userId,
        number: event.number,
      ));
    } else if (event is ParticipantLeftEvent) {
      add(_CallSignalingEventParticipantLeft(callId: event.callId, userId: event.userId));
    } else if (event is IceTrickleEvent) {
      add(_CallSignalingEvent.iceTrickle(line: event.line, callId: event.callId, candidate: event.candidate));
    } else {
      _logger.warning('unhandled signaling event $event');
    }
  }

  void _onSignalingError(Object error, [StackTrace? stackTrace]) {
    _logger.severe('_onErrorCallback', error, stackTrace);

    _reconnectInitiated();
  }

  void _onSignalingDisconnect(int? code, String? reason) {
    add(_SignalingClientEvent.disconnected(code, reason));
  }

  // WidgetsBindingObserver

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _logger.finer('didChangeAppLifecycleState: $state');
    add(_AppLifecycleStateChanged(state));
  }

  // CallkeepDelegate

  @override
  void continueStartCallIntent(CallkeepHandle handle, String? displayName, bool video) {
    _logger.fine(() => 'continueStartCallIntent handle: $handle displayName: $displayName video: $video');

    _continueStartCallIntent(handle, displayName, video);
  }

  Future<void> _continueStartCallIntent(CallkeepHandle handle, String? displayName, bool video) async {
    _logger.fine(
      () => StringBuffer()
        ..write('_continueStartCallIntent - Attempting to start call')
        ..write(' handle: $handle')
        ..write(' displayName: $displayName')
        ..write(' video: $video')
        ..write(' isHandshakeActive: ${state.isHandshakeEstablished}')
        ..write(' isSignalingActive: ${state.isSignalingEstablished}'),
    );

    try {
      // Wait until both signaling and handshake are active.
      // If the desired state is not reached within kSignalingClientConnectionTimeout, a TimeoutException will be thrown.
      final resolvedState = await stream
          .firstWhere((state) => state.isHandshakeEstablished && state.isSignalingEstablished)
          .timeout(kSignalingClientConnectionTimeout);

      if (isClosed) return;

      _logger.fine(
        () => StringBuffer()
          ..write('_continueStartCallIntent - Signaling and handshake are now active for')
          ..write(' handle: $handle')
          ..write(' displayName: $displayName')
          ..write(' video: $video')
          ..write(' isHandshakeActive: ${resolvedState.isHandshakeEstablished}')
          ..write(' isSignalingActive: ${resolvedState.isSignalingEstablished}'),
      );

      final event = CallControlEvent.started(
        generic: handle.isGeneric ? handle.value : null,
        number: handle.isNumber ? handle.value : null,
        email: handle.isEmail ? handle.value : null,
        displayName: displayName,
        video: video,
      );

      add(event);
    } on TimeoutException {
      if (isClosed) return;

      _logger.warning(
        () => StringBuffer()
          ..write('_continueStartCallIntent - Failed to start call')
          ..write(' handle: $handle')
          ..write(' (Signaling/handshake connection timed out after ${kSignalingClientConnectionTimeout.inSeconds}s)')
          ..write(' isHandshakeActive: ${state.isHandshakeEstablished}')
          ..write(' isSignalingActive: ${state.isSignalingEstablished}'),
      );

      submitNotification(const SignalingConnectFailedNotification());
    } catch (e, s) {
      if (isClosed) return;

      final severeMessage = StringBuffer()
        ..write('_continueStartCallIntent - An unexpected error occurred while waiting for signaling')
        ..write(' handle: $handle');
      _logger.severe(() => severeMessage, e, s);

      submitNotification(ErrorMessageNotification(e.toString()));
    }
  }

  @override
  // Handles incoming call notifications from the native side.
  // On iOS, this is triggered via PushKit when a push is received.
  //
  // On Android, this method is currently not used. Call state synchronization
  // from the background is handled by `CallkeepConnections`. A future refactoring
  // could unify this logic so that both platforms use this delegate method.
  //
  // On Android, this is now fully feasible because after the recent callback
  // improvement we can reliably detect when the bloc is ready.
  //
  // PDelegateFlutterApi.setUp(null);
  // _api.onDelegateSet();
  //
  // TODO: Unify incoming-call handling for both iOS and Android so that
  // this method becomes the shared entry point. This may require removing
  // `CallkeepConnections` and adjusting the method signature.
  void didPushIncomingCall(
    CallkeepHandle handle,
    String? displayName,
    bool video,
    String callId,
    CallkeepIncomingCallError? error,
  ) {
    _logger.fine(
      () =>
          'didPushIncomingCall handle: $handle displayName: $displayName video: $video'
          ' callId: $callId error: $error',
    );

    add(_CallPushEventIncoming(callId: callId, handle: handle, displayName: displayName, video: video, error: error));
  }

  @override
  Future<bool> performStartCall(
    String callId,
    CallkeepHandle handle,
    String? displayNameOrContactIdentifier,
    bool video,
  ) {
    return _perform(
      _CallPerformEvent.started(callId, handle: handle, displayName: displayNameOrContactIdentifier, video: video),
    );
  }

  @override
  Future<bool> performAnswerCall(String callId) {
    return _perform(_CallPerformEvent.answered(callId));
  }

  @override
  Future<bool> performEndCall(String callId) {
    return _perform(_CallPerformEvent.ended(callId));
  }

  @override
  Future<bool> performSetHeld(String callId, bool onHold) {
    return _perform(_CallPerformEvent.setHeld(callId, onHold));
  }

  @override
  Future<bool> performSetMuted(String callId, bool muted) {
    return _perform(_CallPerformEvent.setMuted(callId, muted));
  }

  @override
  Future<bool> performSendDTMF(String callId, String key) {
    return _perform(_CallPerformEvent.sentDTMF(callId, key));
  }

  @override
  @Deprecated('Used performAudioDeviceSet instead')
  Future<bool> performSetSpeaker(String callId, bool enabled) {
    return Future.value(true);
  }

  @override
  Future<bool> performAudioDeviceSet(String callId, CallkeepAudioDevice device) {
    final callDevice = CallAudioDevice.fromCallkeep(device);
    return _perform(_CallPerformEvent.audioDeviceSet(callId, callDevice));
  }

  @override
  Future<bool> performAudioDevicesUpdate(String callId, List<CallkeepAudioDevice> devices) {
    final callDevices = devices.map(CallAudioDevice.fromCallkeep).toList();
    return _perform(_CallPerformEvent.audioDevicesUpdate(callId, callDevices));
  }

  @override
  void didActivateAudioSession() {
    _logger.fine('didActivateAudioSession');
    () async {
      await AppleNativeAudioManagement.setAppleAudioConfiguration(
        AppleNativeAudioManagement.getAppleAudioConfigurationForMode(
          AppleAudioIOMode.localAndRemote,
        ),
      );
    }();
  }

  @override
  void didDeactivateAudioSession() {
    _logger.fine('didDeactivateAudioSession');
    () async {
      await AppleNativeAudioManagement.setAppleAudioConfiguration(
        AppleNativeAudioManagement.getAppleAudioConfigurationForMode(
          AppleAudioIOMode.none,
        ),
      );
    }();
  }

  @override
  void didReset() {
    _logger.warning('didReset');
  }

  // helpers

  Future<bool> _perform(_CallPerformEvent callPerformEvent) {
    add(callPerformEvent);
    return callPerformEvent.future;
  }

  Future<RTCPeerConnection> _createPeerConnection(String callId, int? lineId) async {
    final servers = iceServers ?? [{'url': 'stun:stun.l.google.com:19302'}];
    // ignore: avoid_print
    print('[CallBloc] _createPeerConnection callId=$callId iceServers=${servers.length} entries');
    // ignore: avoid_print
    print('[CallBloc] 🧊 ICE servers: ${servers.map((s) => (s['urls'] ?? s['url']).toString()).join(', ')}');
    final peerConnection = await createPeerConnection({
      'iceServers': servers,
      'sdpSemantics': 'unified-plan',
      // Use 'all' so host candidates work on same-WiFi and srflx candidates
      // are available as fallback. Relay-only mode failed because metered.ca
      // allocates different TURN servers per region (US vs India) and UDP
      // between them is blocked — relay-relay cross-region is broken.
      'iceTransportPolicy': 'all',
    }, {});
    final logger = Logger(peerConnection.toString());

    return peerConnection
      ..onSignalingState = (signalingState) {
        logger.fine(() => 'onSignalingState state: ${signalingState.name}');

        add(_PeerConnectionEvent.signalingStateChanged(callId, signalingState));
      }
      ..onConnectionState = (connectionState) {
        logger.fine(() => 'onConnectionState state: ${connectionState.name}');

        add(_PeerConnectionEvent.connectionStateChanged(callId, connectionState));
      }
      ..onIceGatheringState = (iceGatheringState) {
        logger.fine(() => 'onIceGatheringState state: ${iceGatheringState.name}');

        add(_PeerConnectionEvent.iceGatheringStateChanged(callId, iceGatheringState));
      }
      ..onIceConnectionState = (iceConnectionState) {
        logger.fine(() => 'onIceConnectionState state: ${iceConnectionState.name}');
        add(_PeerConnectionEvent.iceConnectionStateChanged(callId, iceConnectionState));
      }
      ..onIceCandidate = (candidate) {
        logger.fine(() => 'onIceCandidate candidate: ${candidate.str}');
        // Parse candidate type from the SDP candidate string for diagnosis:
        // format: "candidate:<foundation> <component> <protocol> <priority> <ip> <port> typ <type> ..."
        final candStr = candidate.candidate ?? '';
        final typeMatch = RegExp(r'\btyp\s+(\S+)').firstMatch(candStr);
        final relAddrMatch = RegExp(r'raddr\s+(\S+)').firstMatch(candStr);
        final candType = typeMatch?.group(1) ?? '?';
        final relAddr = relAddrMatch?.group(1);
        // ignore: avoid_print
        print('[CallBloc] 🧊 ICE candidate type=$candType${relAddr != null ? " raddr=$relAddr" : ""} callId=$callId');

        add(_PeerConnectionEvent.iceCandidateIdentified(callId, candidate));
      }
      ..onAddStream = (stream) {
        logger.fine(() => 'onAddStream stream: ${stream.str}');

        add(_PeerConnectionEvent.streamAdded(callId, stream));
      }
      ..onRemoveStream = (stream) {
        logger.fine(() => 'onRemoveStream stream: ${stream.str}');

        add(_PeerConnectionEvent.streamRemoved(callId, stream));
      }
      ..onAddTrack = (stream, track) {
        logger.fine(() => 'onAddTrack stream: ${stream.str} track: ${track.str}');
      }
      ..onRemoveTrack = (stream, track) {
        logger.fine(() => 'onRemoveTrack stream: ${stream.str} track: ${track.str}');
      }
      ..onDataChannel = (channel) {
        logger.fine(() => 'onDataChannel channel: $channel');
      }
      ..onRenegotiationNeeded = () async {
        // TODO(Serdun): Handle renegotiation needed
        // This implementation does not handle all possible signaling states.
        // Specifically, if the current state is `have-remote-offer`, calling
        // setLocalDescription with an offer will throw:
        //   WEBRTC_SET_LOCAL_DESCRIPTION_ERROR: Failed to set local offer sdp: Called in wrong state: have-remote-offer
        //
        // Known case: when CalleeVideoOfferPolicy.includeInactiveTrack is used,
        // the callee may trigger onRenegotiationNeeded before the current remote offer is processed.
        // This causes a race where the local peer is still in 'have-remote-offer' state,
        // leading to the above error. Currently this does not severely affect behavior,
        // since the offer includes only an inactive track, but it should still be handled correctly.
        //
        // Proper handling should include:
        // - Waiting until the signaling state becomes 'stable' before creating and setting a new offer
        // - Avoiding renegotiation if a remote offer is currently being processed
        // - Ensuring renegotiation is coordinated and state-aware

        final pcState = peerConnection.signalingState;
        logger.fine(() => 'onRenegotiationNeeded signalingState: $pcState');
        if (pcState != null) {
          final localDescription = await peerConnection.createOffer({});
          sdpMunger?.apply(localDescription);

          // According to RFC 8829 5.6 (https://datatracker.ietf.org/doc/html/rfc8829#section-5.6),
          // localDescription should be set before sending the offer to transition into have-local-offer state.
          await peerConnection.setLocalDescription(localDescription);

          try {
            final updateRequest = UpdateRequest(
              transaction: WebtritSignalingClient.generateTransactionId(),
              line: lineId,
              callId: callId,
              jsep: localDescription.toMap(),
            );
            await _signalingClient?.execute(updateRequest);
          } catch (e, s) {
            callErrorReporter.handle(e, s, '_createPeerConnection:onRenegotiationNeeded error');
          }
        }
      }
      ..onTrack = (event) {
        logger.fine(() => 'onTrack ${event.str}');
        // ignore: avoid_print
        print('[CallBloc] 🎬 onTrack kind=${event.track.kind} '
            'streams=${event.streams.length} callId=$callId');
        // In unified-plan P2P calls onAddStream may not fire — only onTrack
        // fires per remote track. Dispatch a streamAdded event so the UI gets
        // the remote stream exactly as it would from onAddStream.
        if (event.streams.isNotEmpty) {
          add(_PeerConnectionEvent.streamAdded(callId, event.streams[0]));
        }
      };
  }

  void _addToRecents(ActiveCall activeCall) {
    NewCall call = (
      direction: activeCall.direction,
      number: activeCall.handle.value,
      video: activeCall.video,
      username: activeCall.displayName,
      createdTime: activeCall.createdTime,
      acceptedTime: activeCall.acceptedTime,
      hungUpTime: activeCall.hungUpTime,
    );
    callLogsRepository.add(call);
  }

  Future<void> _playRingbackSound() => _callkeepSound.playRingbackSound();

  Future<void> _stopRingbackSound() => _callkeepSound.stopRingbackSound();

  /// Remove a call from the pullable-calls repository when it ends.
  void _clearPullableCall(String callId) {
    final remaining = callPullRepository.pullableCalls.where((pc) => pc.callId != callId).toList();
    callPullRepository.setPullableCalls(remaining);
  }

  // TODO(Vlad): extract mapper,find better naming
  Future<void> _assingUserActiveCalls(List<UserActiveCall> userActiveCalls) async {
    final pullableCalls = userActiveCalls
        .map(
          (call) => PullableCall(
            id: call.id,
            state: PullableCallState.values.byName(call.state.name),
            callId: call.callId,
            localTag: call.localTag,
            remoteTag: call.remoteTag,
            remoteNumber: call.remoteNumber,
            remoteDisplayName: call.remoteDisplayName,
            direction: PullableCallDirection.values.byName(call.direction.name),
          ),
        )
        .toList();

    List<PullableCall> pullableCallsToSet = [];

    for (final pullableCall in pullableCalls) {
      // Skip calls that are already active
      if (state.activeCalls.any((call) => call.callId == pullableCall.callId)) continue;

      // Resolve contact name for the call's remote number
      final contactName = await contactNameResolver.resolveWithNumber(pullableCall.remoteNumber);
      pullableCallsToSet.add(pullableCall.copyWith(remoteDisplayName: contactName));
    }

    callPullRepository.setPullableCalls(pullableCallsToSet);
  }

  Future<void> _assingNumberPresence(String number, List<SignalingPresenceInfo> data) async {
    final presenceInfo = data.map(SignalingPresenceInfoMapper.fromSignaling).toList();
    presenceInfoRepository.setNumberPresence(number, presenceInfo);
  }

  Future<void> syncPresenceSettings() async {
    final now = DateTime.now();
    final lastSync = presenceSettingsRepository.lastSettingsSync;
    final presenceSettings = presenceSettingsRepository.presenceSettings;

    final canUpdate = state.callServiceState.status == CallStatus.ready;
    bool shouldUpdate = false;
    if (lastSync == null) {
      shouldUpdate = true;
    } else if (presenceSettings.timestamp.difference(lastSync).inSeconds > 0) {
      shouldUpdate = true;
    } else if (now.difference(lastSync).inMinutes >= 30) {
      shouldUpdate = true;
    }

    if (shouldUpdate && canUpdate) {
      _logger.fine('_presenceInfoSyncTimer: updating presence settings');
      try {
        await _signalingClient?.execute(
          PresenceSettingsUpdateRequest(
            transaction: clock.now().millisecondsSinceEpoch.toString(),
            settings: SignalingPresenceSettingsMapper.toSignaling(presenceSettings),
          ),
        );
        presenceSettingsRepository.updateLastSettingsSync(now);
        _logger.fine('Presence settings updated at $now');
      } on Exception catch (e, s) {
        _logger.warning('Failed to update presence settings', e, s);
      }
    }
  }

  void _checkSenderResult(RTCRtpSender? senderResult, String kind) {
    if (senderResult == null) {
      _logger.warning('safeAddTrack for $kind returned null: track not added, possibly due to closed connection');
    }
  }

  // ── LiveKit helper ──────────────────────────────────────────────────────────

  /// Connect to a LiveKit room for a call.
  /// Stores the room in [_livekitRooms] and attaches a listener for participant changes.
  Future<void> _joinLiveKitConference(
    String callId,
    String livekitUrl,
    String livekitToken,
    Emitter<CallState> emit,
  ) async {
    final videoEnabled = state.retrieveActiveCall(callId)?.video ?? false;

    // Disconnect any existing LiveKit room for this callId before reconnecting
    final existing = _livekitRooms.remove(callId);
    if (existing != null) await existing.disconnect();

    final manager = LiveKitRoomManager();
    _livekitRooms[callId]          = manager;
    _livekitCameraEnabled[callId]  = videoEnabled;
    _livekitUrls[callId]           = livekitUrl;
    _livekitTokens[callId]         = livekitToken;

    manager.connect(
      url:          livekitUrl,
      token:        livekitToken,
      videoEnabled: videoEnabled,
      audioEnabled: true,
    );

    _logger.info('[Conference] joined LiveKit room callId=$callId videoEnabled=$videoEnabled');
  }

  // ── Unified call flow handlers ─────────────────────────────────────────────

  /// Unified incoming call invite — works for 1-on-1, group, and add-member calls.
  /// Replaces _onConferenceInvite and __onCallSignalingEventIncoming for new-protocol calls.
  Future<void> _onCallInvite(
    _CallSignalingEventInvite event,
    Emitter<CallState> emit,
  ) async {
    _logger.info('[Room] call_invite callId=${event.callId} caller=${event.callerNumber} '
        'participants=${event.participantNumbers}');

    // Mark this call as using the new unified protocol
    _unifiedFlowCallIds.add(event.callId);

    // Store LiveKit credentials
    if (event.livekitUrl != null && event.livekitToken != null) {
      _livekitUrls[event.callId]   = event.livekitUrl!;
      _livekitTokens[event.callId] = event.livekitToken!;
    }

    // Store participant numbers in conference state so the UI can show them
    final participants = <ConferenceParticipant>[];
    for (final number in event.participantNumbers) {
      final name = await contactNameResolver.resolveWithNumber(number);
      participants.add(ConferenceParticipant(
        userId:      number,
        displayName: name ?? number,
        phoneNumber: number,
      ));
    }
    // Also add the caller as a participant (userId = server ID, phone stored separately)
    final callerName = await contactNameResolver.resolveWithNumber(event.callerNumber);
    participants.add(ConferenceParticipant(
      userId:      event.callerId,
      displayName: callerName ?? event.callerNumber,
      phoneNumber: event.callerNumber,
    ));

    // Acknowledge receipt — sends call_ring so the server/caller knows device is ringing
    try {
      await _signalingClient?.execute(
        CallRingRequest(
          transaction: WebtritSignalingClient.generateTransactionId(),
          callId: event.callId,
        ),
      );
      _logger.info('[Room] call_ring sent callId=${event.callId}');
    } catch (e) {
      _logger.warning('[Room] failed to send call_ring', e);
    }

    // Resolve caller display name from contacts.
    // For group calls, prefer the group name sent by the caller so the
    // incoming screen shows the group name rather than the caller's number.
    final handle = CallkeepHandle.number(event.callerNumber);
    // A 1:1 invite always contains [recipient's own number] in participantNumbers
    // (server sends allNumbers.slice(1) which equals [callee] for a 1:1 call).
    // A real group invite has 2+ entries.  Use length >= 2 to tell them apart.
    final isGroupInvite = event.participantNumbers.length >= 2;
    final displayName = (isGroupInvite && event.groupName != null && event.groupName!.isNotEmpty)
        ? event.groupName!
        : (callerName ?? event.callerNumber);

    // Resolve avatar: group calls use the group chat photo; 1:1 calls use the contact photo.
    final String? avatarFilePath;
    if (isGroupInvite && event.chatId != null && event.chatId!.isNotEmpty) {
      avatarFilePath = await groupChatPhotoResolver?.resolvePathWithChatId(event.chatId);
    } else {
      avatarFilePath = await contactPhotoResolver?.resolvePathWithNumber(handle.value);
    }

    // ── Race guard #1 ────────────────────────────────────────────────────────────
    // call_ended arrived before we reached this point (processed concurrently in
    // _onCallEnded which runs in a separate sequential queue).
    // Bail out before showing the native incoming-call UI.
    if (_earlyEndedCallIds.remove(event.callId)) {
      _logger.warning('[Room] call_invite discarded — call ${event.callId} already ended before UI shown');
      _livekitUrls.remove(event.callId);
      _livekitTokens.remove(event.callId);
      _unifiedFlowCallIds.remove(event.callId);
      return;
    }
    // ─────────────────────────────────────────────────────────────────────────────

    final callkeepError = await callkeep.reportNewIncomingCall(
      event.callId,
      handle,
      displayName: displayName,
      hasVideo: event.hasVideo,
      avatarFilePath: avatarFilePath,
    );

    // ── Race guard #2 ────────────────────────────────────────────────────────────
    // call_ended arrived and was processed DURING the reportNewIncomingCall await
    // (the native UI may have flashed on screen briefly).
    // Dismiss it immediately and bail out before emitting to BLoC state.
    if (_earlyEndedCallIds.remove(event.callId)) {
      _logger.warning('[Room] call_invite: call ${event.callId} ended during reportNewIncomingCall — dismissing');
      try {
        await callkeep.reportEndCall(event.callId, displayName, CallkeepEndCallReason.remoteEnded);
      } catch (_) {}
      _livekitUrls.remove(event.callId);
      _livekitTokens.remove(event.callId);
      _unifiedFlowCallIds.remove(event.callId);
      return;
    }
    // ─────────────────────────────────────────────────────────────────────────────

    if (callkeepError != null &&
        callkeepError != CallkeepIncomingCallError.callIdAlreadyExists &&
        callkeepError != CallkeepIncomingCallError.callIdAlreadyExistsAndAnswered &&
        callkeepError != CallkeepIncomingCallError.callIdAlreadyTerminated) {
      _logger.warning('[Room] reportNewIncomingCall error: $callkeepError');
      return;
    }
print("DDDDDDDDDDDDDDDDDDD${displayName}");
    // Always push the contact-resolved name to the native UI when available.
    // Covers all three scenarios:
    //   1-A) Push or foreground-service pre-registered the call with server name
    //        (callIdAlreadyExists) — any app state.
    //   1-B) Android foreground service used event.callerDisplayName (server name)
    //        without contact lookup — callIdAlreadyExists from foreground service path.
    //   1-C) App was fully open and won the race, but resolver returned null and
    //        registration used the raw callerNumber fallback — no error code, but we
    //        still update if we now have a resolved name.
    // Same pattern as legacy path (line 966): reportUpdateCall is idempotent and safe
    // to call even when the call was just freshly registered.
    if (callerName != null || avatarFilePath != null) {
      await callkeep.reportUpdateCall(event.callId, displayName: displayName, avatarFilePath: avatarFilePath);
    }

    final existingCall = state.retrieveActiveCall(event.callId);
    // For a group invite, prefer the explicit groupName from the server.
    // If none is provided (e.g. a 1:1 call that was promoted when a third
    // participant was added), fall back to the resolved caller name so C sees
    // "Alice" on their incoming screen instead of the generic "Group Call".
    final groupName = (isGroupInvite && event.groupName != null && event.groupName!.isNotEmpty)
        ? event.groupName
        : null;

    if (existingCall != null) {
      emit(state.copyWithMappedActiveCall(
        event.callId,
        (call) => call.copyWith(
          line:                   event.line,
          handle:                 handle,
          displayName:            displayName,
          groupName:              groupName,
          chatId:                 event.chatId,
          video:                  event.hasVideo,
          processingStatus:       CallProcessingStatus.conferenceInvitePending,
          conferenceParticipants: participants,
        ),
      ));
    } else {
      final activeCall = ActiveCall(
        direction:               CallDirection.incoming,
        line:                    event.line ?? 0,
        callId:                  event.callId,
        handle:                  handle,
        displayName:             displayName,
        groupName:               groupName,
        chatId:                  event.chatId,
        video:                   event.hasVideo,
        createdTime:             clock.now(),
        processingStatus:        CallProcessingStatus.conferenceInvitePending,
        conferenceParticipants:  participants,
      );
      emit(state.copyWithPushActiveCall(activeCall));
    }
  }

  /// call_ringing received on caller side — join LiveKit room now.
  Future<void> _onCallRinging(
    _CallSignalingEventCallRinging event,
    Emitter<CallState> emit,
  ) async {
    _logger.info('[Room] call_ringing callId=${event.callId}');

    if (event.livekitUrl != null && event.livekitToken != null) {
      _livekitUrls[event.callId]   = event.livekitUrl!;
      _livekitTokens[event.callId] = event.livekitToken!;
    }

    // Transition to conferenceActive so the call screen shows the LiveKit UI
    emit(state.copyWithMappedActiveCall(
      event.callId,
      (call) => call.copyWith(processingStatus: CallProcessingStatus.conferenceActive),
    ));

    // Join LiveKit room on the first call_ringing only.
    // For group calls the server sends call_ringing once per receiver that
    // rings — we must not reconnect (and re-publish tracks) on subsequent ones.
    if (_livekitRooms[event.callId] == null) {
      final url   = event.livekitUrl   ?? _livekitUrls[event.callId];
      final token = event.livekitToken ?? _livekitTokens[event.callId];
      if (url != null && token != null) {
        try {
          await _joinLiveKitConference(event.callId, url, token, emit);
        } catch (e, s) {
          _logger.warning('[Room] _onCallRinging LiveKit connect error', e, s);
        }
      }
    }
  }

  /// call_accepted received — the call is now connected.
  ///
  /// The server broadcasts this to ALL room participants when ANY one participant
  /// accepts.  For incoming calls not yet answered on this device (e.g. C while
  /// B is the one who accepted), we must do nothing — leave C's UI in the
  /// accept/reject state and do NOT join the LiveKit room yet.
  Future<void> _onCallAccepted(
    _CallSignalingEventCallAccepted event,
    Emitter<CallState> emit,
  ) async {
    _logger.info('[Room] call_accepted callId=${event.callId}');

    final call = state.retrieveActiveCall(event.callId);
    if (call == null) return;

    print('╔══ [CALL_ACCEPTED] SERVER → call_accepted received ══════════════');
    print('║  callId          : ${event.callId}');
    print('║  direction       : ${call.direction}');
    print('║  wasAccepted     : ${call.wasAccepted}');
    print('║  processingStatus: ${call.processingStatus}');
    print('║  inLiveKit       : ${_livekitRooms.containsKey(event.callId)}');
    print('║  connectedIds    : ${_connectedParticipantIds[event.callId]}');
    print('╚═════════════════════════════════════════════════════════════════');

    // Guard: if this is an incoming call that has not yet been answered on
    // this device, ignore the call_accepted broadcast entirely.
    // - Caller (outgoing): always proceed.
    // - Receiver who already answered (wasAccepted): already in LK, proceed.
    // - Receiver who has NOT answered yet: return early — keep accept/reject UI
    //   and do NOT join the LiveKit room (which would deliver media prematurely).
    if (call.direction == CallDirection.incoming && !call.wasAccepted) {
      print('[CALL_ACCEPTED] → IGNORED (incoming + not yet answered on this device)');
      _logger.info('[Room] call_accepted ignored — incoming call not yet answered '
          'on this device callId=${event.callId}');
      return;
    }
    print('[CALL_ACCEPTED] → PROCEEDING (caller or already-answered receiver)');

    emit(state.copyWithMappedActiveCall(
      event.callId,
      (c) => c.copyWith(
        // Transition outgoing callers from conferenceActive → connected so the
        // caller's screen reliably switches from "Calling…" to the active UI.
        // Incoming callers who already answered stay at their current status.
        processingStatus: c.direction == CallDirection.outgoing
            ? CallProcessingStatus.connected
            : c.processingStatus,
        acceptedTime: c.direction == CallDirection.outgoing
            ? (c.acceptedTime ?? clock.now())
            : c.acceptedTime, // preserve existing value (already set when answered)
      ),
    ));

    // If we haven't joined LiveKit yet (e.g., incoming side after accepting),
    // join now using stored credentials.
    if (_livekitRooms[event.callId] == null) {
      final url   = _livekitUrls[event.callId];
      final token = _livekitTokens[event.callId];
      if (url != null && token != null) {
        try {
          await _joinLiveKitConference(event.callId, url, token, emit);
        } catch (e, s) {
          _logger.warning('[Room] _onCallAccepted LiveKit connect error', e, s);
        }
      }
    }
  }

  /// call_ended received — end the call for any reason.
  Future<void> _onCallEnded(
    _CallSignalingEventCallEnded event,
    Emitter<CallState> emit,
  ) async {
    _logger.info('[Room] call_ended callId=${event.callId} reason=${event.reason}');
    print('[Room] call_ended callId=${event.callId} reason=${event.reason}');

    final call = state.retrieveActiveCall(event.callId);

    // ── Fix A-3: Safety net — call_ended arrived before call_invite was processed ──
    if (call == null) {
      _logger.warning('[Room] call_ended for unknown callId=${event.callId} reason=${event.reason} — '
          'dismissing via callkeep as safety net');
      try {
        await callkeep.reportEndCall(
          event.callId,
          event.callId,
          CallkeepEndCallReason.remoteEnded,
        );
      } catch (_) { /* callkeep throws if the call was never registered — safe to ignore */ }
      final lkRoom = _livekitRooms.remove(event.callId);
      if (lkRoom != null) await lkRoom.disconnect();
      _livekitUrls.remove(event.callId);
      _livekitTokens.remove(event.callId);
      // Mark so _onCallInvite can detect the race and dismiss the native UI
      // if call_invite is processed after (or concurrently with) this call_ended.
      _earlyEndedCallIds.add(event.callId);
      return;
    }
    // ── End Fix A-3 ────────────────────────────────────────────────────────────────

    print('╔══ [CALL_ENDED] SERVER → call_ended received ════════════════════');
    print('║  callId          : ${event.callId}');
    print('║  reason          : ${event.reason}');
    print('║  direction       : ${call?.direction}');
    print('║  groupName       : ${call?.groupName}');
    print('║  processingStatus: ${call?.processingStatus}');
    print('║  wasAccepted     : ${call?.wasAccepted}');
    print('║  inLiveKit       : ${_livekitRooms.containsKey(event.callId)}');
    print('║  lkRemoteCount   : ${_livekitRooms[event.callId]?.room?.remoteParticipants.length ?? 0}');
    print('║  connectedIds    : ${_connectedParticipantIds[event.callId]}');
    print('║  conferenceParticipants: ${call?.conferenceParticipants.map((p) => p.userId).toList()}');
    print('╚═════════════════════════════════════════════════════════════════');

    // ── Group-call guard ─────────────────────────────────────────────────
    // The server is authoritative. It sends:
    //   • participant_left          → call continues (handled in _onParticipantLeft)
    //   • call_ended(declined)      → one invitee declined; IGNORE — call continues
    //   • call_ended(no_answer)     → one invitee timed out; IGNORE — call continues
    //   • call_ended(normal/missed) → server decided call is over; ALWAYS teardown
    //
    // We no longer second-guess the server with lkRemoteCount / connectedCount.
    // If the server wanted the call to continue it would have sent participant_left.
    final isGroupCall = call?.groupName != null;

    if (isGroupCall) {
      if (event.reason == 'declined') {
        print('[CALL_ENDED] → group guard: IGNORED (reason=declined) — '
            'one invitee declined, call continues for everyone else');
        _logger.info('[Room] group call: participant declined, call continues');
        return;
      }
      if (event.reason == 'no_answer') {
        print('[CALL_ENDED] → group guard: IGNORED (reason=no_answer) — '
            'invitee timed out, call continues for everyone else');
        _logger.info('[Room] group call: invitee timed out, call continues');
        return;
      }
      // ── NEW: Busy signal ──────────────────────────────────────────────────
      if (event.reason == 'busy') {
        _logger.info('[Room] call_ended(busy) — remote party is in another call callId=${event.callId}');
        // Emit a transient "busy" processing status so the call screen can display
        // the busy UI for a moment before the call is torn down.
        emit(state.copyWithMappedActiveCall(
          event.callId,
              (call) => call.copyWith(processingStatus: CallProcessingStatus.busySignal),
        ));
        // Brief pause so the caller sees the "busy" UI before auto-dismiss.
        await Future.delayed(const Duration(seconds: 2));
        // Now tear down normally (fall through to teardown code below).
      }
      // reason == 'normal' or 'missed' → server decided call is over for everyone.
      print('[CALL_ENDED] → group guard: TEARDOWN (reason=${event.reason}) — '
          'server ended the call for all participants');
    } else {
      print('[CALL_ENDED] → 1-on-1 call: TEARDOWN (reason=${event.reason})');
    }
    // ─────────────────────────────────────────────────────────────────────

    print('[CALL_ENDED] → TEARING DOWN callId=${event.callId}');
    _connectedParticipantIds.remove(event.callId);
    final lkRoom = _livekitRooms.remove(event.callId);
    if (lkRoom != null) await lkRoom.disconnect();

    if (call != null) {
      if (!call.wasHungUp) {
        _addToRecents(call.copyWith(hungUpTime: clock.now()));
      }

      // Fix B-2: 'missed' on an outgoing call means the remote didn't answer —
      // use remoteEnded so the OS does not record a "Missed call" for the caller.
      final endReason = switch (event.reason) {
        'missed' when call.direction == CallDirection.outgoing
                    => CallkeepEndCallReason.remoteEnded,
        'missed'    => CallkeepEndCallReason.unanswered,
        'declined'  => CallkeepEndCallReason.declinedElsewhere,
        'no_answer' => CallkeepEndCallReason.unanswered,
        _           => CallkeepEndCallReason.remoteEnded,
      };

      _unifiedFlowCallIds.remove(event.callId);
      _livekitUrls.remove(event.callId);
      _livekitTokens.remove(event.callId);
      _clearPullableCall(event.callId);
      emit(state.copyWithPopActiveCall(event.callId));
      await callkeep.reportEndCall(
        event.callId,
        call.displayName ?? call.handle.value,
        endReason,
      );
    }
  }

  /// participant_joined — a new participant has entered the room.
  Future<void> _onParticipantJoined(
    _CallSignalingEventParticipantJoined event,
    Emitter<CallState> emit,
  ) async {
    _logger.info('[Room] participant_joined callId=${event.callId} userId=${event.userId} number=${event.number}');

    final currentCall = state.retrieveActiveCall(event.callId);
    if (currentCall == null) return;

    // participant_joined is only ever sent by room.ts (unified flow).
    // If this callId is not yet in _unifiedFlowCallIds (e.g. it started as a
    // legacy outgoing_call and was just promoted to activeRooms by the backend),
    // mark it as unified now so that subsequent call_hangup goes through the
    // unified path instead of the legacy "hangup" path.
    if (!_unifiedFlowCallIds.contains(event.callId)) {
      _unifiedFlowCallIds.add(event.callId);
      _logger.info('[Room] _onParticipantJoined: callId=${event.callId} promoted to unified flow');
    }

    // Resolve display name from device contacts
    final displayName = await contactNameResolver.resolveWithNumber(event.number) ?? event.number;

    final participant = ConferenceParticipant(
      userId:      event.userId,
      displayName: displayName,
      phoneNumber: event.number,
    );
    // Deduplicate by BOTH server userId AND phone number because the pre-populated
    // entries (from call_invite / call_initiate) use phone numbers as userId, while
    // participant_joined/left events use the server-assigned identity.
    final updatedParticipants = currentCall.conferenceParticipants
        .where((p) => p.userId != event.userId && p.userId != event.number)
        .toList()
      ..add(participant);

    // Track server-confirmed joined participants for reliable auto-end.
    _connectedParticipantIds
        .putIfAbsent(event.callId, () => {})
        .add(event.userId);

    print('╔══ [PARTICIPANT_JOINED] ══════════════════════════════════════════');
    print('║  callId          : ${event.callId}');
    print('║  userId (server) : ${event.userId}');
    print('║  number (phone)  : ${event.number}');
    print('║  displayName     : $displayName');
    print('║  connectedIds now: ${_connectedParticipantIds[event.callId]}');
    print('║  conferenceParticipants now: ${updatedParticipants.map((p) => p.userId).toList()}');
    print('╚═════════════════════════════════════════════════════════════════');

    emit(state.copyWithMappedActiveCall(
      event.callId,
          (call) => call.copyWith(
        conferenceParticipants: updatedParticipants,
        updating:               !call.updating,
        // ── NEW: promote to group-call mode when 2+ remote participants exist ──
        // Covers user B (original callee) and user C (new invitee):
        //   • B: after C joins, participants = [A, C] → length 2 → group UI
        //   • C: after A+B participant_joined events → length 2 → group UI
        // Also covers A if Change 1 wasn't applied (fallback safety net).
        // groupName: call.groupName ??
        //     (updatedParticipants.length >= 2
        //         ? (call.displayName ?? 'Group Call')
        //         : null),
        // ── END NEW ────────────────────────────────────────────────────────────
        processingStatus: call.direction == CallDirection.outgoing
            ? CallProcessingStatus.connected
            : call.processingStatus,
        acceptedTime: call.direction == CallDirection.outgoing
            ? (call.acceptedTime ?? clock.now())
            : call.acceptedTime,
      ),
    ));
  }

  /// participant_left — a participant has left the room.
  Future<void> _onParticipantLeft(
    _CallSignalingEventParticipantLeft event,
    Emitter<CallState> emit,
  ) async {
    _logger.info('[Room] participant_left callId=${event.callId} userId=${event.userId}');

    final currentCall = state.retrieveActiveCall(event.callId);
    if (currentCall == null) return;

    final updatedParticipants = currentCall.conferenceParticipants
        .where((p) => p.userId != event.userId)
        .toList();

    // Keep confirmed-joined set in sync (used for debug logging).
    _connectedParticipantIds[event.callId]?.remove(event.userId);
    final connectedCount = _connectedParticipantIds[event.callId]?.length ?? 0;

    print('╔══ [PARTICIPANT_LEFT] ════════════════════════════════════════════');
    print('║  callId              : ${event.callId}');
    print('║  userId (server)     : ${event.userId}');
    print('║  connectedIds after  : ${_connectedParticipantIds[event.callId]}');
    print('║  connectedCount      : $connectedCount');
    print('║  inLiveKit           : ${_livekitRooms.containsKey(event.callId)}');
    print('║  lkRemoteCount       : ${_livekitRooms[event.callId]?.room?.remoteParticipants.length ?? 0}');
    print('║  confParticipants after: ${updatedParticipants.map((p) => p.userId).toList()}');
    print('║  action              : UPDATE LIST ONLY — server sends call_ended to teardown');
    print('╚═════════════════════════════════════════════════════════════════');

    emit(state.copyWithMappedActiveCall(
      event.callId,
      (call) => call.copyWith(
        conferenceParticipants: updatedParticipants,
        updating: !call.updating,
      ),
    ));

    // Auto-end safety net: if we are in a LiveKit room and the LK SDK reports
    // zero remote participants AND no participants are still pending (ringing /
    // invited but not yet in LK), everyone has truly left — end the call.
    //
    // We use lkRemoteCount (real LK state) instead of connectedCount
    // (_connectedParticipantIds) because _connectedParticipantIds only tracks
    // participants who fired participant_joined AFTER our tracking code ran.
    // The original callee B (1:1 call accepted via call_accepted before the
    // promotion to group) is never in _connectedParticipantIds, so connectedCount
    // would drop to 0 when only C leaves — prematurely ending the call.
    // The LK SDK reliably tracks everyone actually connected in the room.
    //
    // The updatedParticipants.isEmpty guard prevents a false auto-end when a
    // third party (C) was invited but hasn't joined LK yet.  Example:
    //   • A-B 1:1 call, B adds C (C is ringing), A leaves.
    //   • lkRemoteCount = 0 (A gone, C not in LK yet) but C is still in
    //     updatedParticipants.  Without this guard B would incorrectly end.
    final inLiveKit = _livekitRooms.containsKey(event.callId);
    final lkRemoteCount = _livekitRooms[event.callId]?.room?.remoteParticipants.length ?? 0;
    if (inLiveKit && lkRemoteCount == 0 && updatedParticipants.isEmpty) {
      print('[PARTICIPANT_LEFT] → AUTO-ENDING: in LK with 0 LK remote '
          'participants callId=${event.callId}');
      // Tell the server we are leaving so it can clean up activeRooms.
      // Without this the server still considers us in the call, blocking
      // future outgoing calls with "already in a call".
      _signalingClient
          ?.execute(CallHangupRequest(
            transaction: WebtritSignalingClient.generateTransactionId(),
            callId: event.callId,
          ))
          .catchError((e, s) => _logger.warning(
                '[Room] auto-end call_hangup failed callId=${event.callId}', e, s));
      _connectedParticipantIds.remove(event.callId);
      final lkRoom = _livekitRooms.remove(event.callId);
      if (lkRoom != null) await lkRoom.disconnect();
      if (!currentCall.wasHungUp) {
        _addToRecents(currentCall.copyWith(hungUpTime: clock.now()));
      }
      _unifiedFlowCallIds.remove(event.callId);
      _livekitUrls.remove(event.callId);
      _livekitTokens.remove(event.callId);
      _clearPullableCall(event.callId);
      emit(state.copyWithPopActiveCall(event.callId));
      await callkeep.reportEndCall(
        event.callId,
        currentCall.displayName ?? currentCall.handle.value,
        CallkeepEndCallReason.remoteEnded,
      );
    }
  }

  /// Initiate a new unified-flow call via call_initiate (new backend room.ts).
  Future<void> _onCallControlEventInitiate(
    _CallControlEventInitiate event,
    Emitter<CallState> emit,
  ) async {
    if (state.callServiceState.registration?.status.isRegistered != true) {
      _logger.info('[Room] _onCallControlEventInitiate: not registered');
      submitNotification(CallWhileUnregisteredNotification());
      return;
    }

    // Ensure the signaling WebSocket is up before sending the call request.
    // This covers the race condition where the user taps "Call" immediately
    // after foregrounding the app before the reconnect timer has fired.
    final signalingReady = await _ensureSignalingConnected();
    if (!signalingReady) {
      _logger.warning('[Room] _onCallControlEventInitiate: signaling not available, aborting');
      submitNotification(const SignalingConnectFailedNotification());
      return;
    }

    final line = event.line ?? state.retrieveIdleLine();
    if (line == null) {
      _logger.warning('[Room] _onCallControlEventInitiate: no idle line');
      return;
    }

    if (event.numbers.isEmpty) {
      _logger.warning('[Room] _onCallControlEventInitiate: empty numbers');
      return;
    }

    final callId = WebtritSignalingClient.generateCallId();
    _unifiedFlowCallIds.add(callId);

    // Resolve display name for the first callee
    final firstNumber  = event.numbers.first;
    final contactName  = await contactNameResolver.resolveWithNumber(firstNumber);
    final displayName  = event.numbers.length == 1
        ? (contactName ?? event.displayName ?? firstNumber)
        : (event.displayName ?? event.numbers.join(', '));

    final handle = CallkeepHandle.number(firstNumber);

    // Resolve group name before ActiveCall is created.
    // Prefer explicit groupName, fall back to displayName for multi-number calls
    // (when makeGroupCall is used, displayName IS the group name).
    final groupName = event.groupName ?? (event.numbers.length > 1 ? event.displayName : null);

    await callkeep.startCall(callId, handle, displayNameOrContactIdentifier: displayName, hasVideo: event.video);

    // For group calls, resolve display names for all invited numbers so the
    // caller's members panel shows everyone as "Ringing" from the start.
    // (The server does not send call_invite back to the initiator, so without
    // this the caller's conferenceParticipants would start empty.)
    final initialParticipants = groupName != null
        ? await Future.wait(
            event.numbers.map((n) async {
              final name = await contactNameResolver.resolveWithNumber(n);
              return ConferenceParticipant(
                userId:      n,
                displayName: name ?? n,
                phoneNumber: n,
              );
            }),
          )
        : const <ConferenceParticipant>[];

    final activeCall = ActiveCall(
      direction:              CallDirection.outgoing,
      line:                   line,
      callId:                 callId,
      handle:                 handle,
      displayName:            displayName,
      groupName:              groupName,
      chatId:                 event.chatId,
      video:                  event.video,
      createdTime:            clock.now(),
      processingStatus:       CallProcessingStatus.conferenceActive,
      conferenceParticipants: initialParticipants,
    );
    emit(state.copyWithPushActiveCall(activeCall));

    try {
      await _signalingClient?.execute(
        CallInitiateRequest(
          transaction: WebtritSignalingClient.generateTransactionId(),
          callId:      callId,
          numbers:     event.numbers,
          line:        line,
          from:        event.from,
          hasVideo:    event.video,
          groupName:   groupName,
          chatId:      event.chatId,
        ),
      );
      _logger.info('[Room] call_initiate sent callId=$callId numbers=${event.numbers}');
    } catch (e, s) {
      _logger.warning('[Room] _onCallControlEventInitiate error', e, s);
    }
  }

  /// Handle the "Add Participant" user action — only active when groupCallEnabled.
  // Future<void> _onCallControlEventAddParticipant(
  //   _CallControlEventAddParticipant event,
  //   Emitter<CallState> emit,
  // ) async {
  //   if (!groupCallEnabled) {
  //     _logger.info('[Conference] group call not enabled, ignoring addParticipant');
  //     return;
  //   }
  //
  //   _logger.info('[Conference] addParticipant callId=${event.callId} number=${event.number}');
  //
  //   try {
  //     if (_unifiedFlowCallIds.contains(event.callId)) {
  //       await _signalingClient?.execute(
  //         CallAddParticipantRequest(
  //           transaction: WebtritSignalingClient.generateTransactionId(),
  //           callId:      event.callId,
  //           number:      event.number,
  //         ),
  //       );
  //     } else {
  //       await _signalingClient?.execute(
  //         AddToCallRequest(
  //           transaction:     WebtritSignalingClient.generateTransactionId(),
  //           callId:          event.callId,
  //           number:          event.number,
  //           chatId:          event.chatId,
  //           groupName:       event.groupName,
  //           groupPhotoUrl:   event.groupPhotoUrl,
  //           memberPhotoUrls: event.memberPhotoUrls,
  //         ),
  //       );
  //     }
  //   } catch (e, s) {
  //     _logger.warning('[Conference] _onCallControlEventAddParticipant error', e, s);
  //   }
  // }

  Future<void> _onCallControlEventAddParticipant(
      _CallControlEventAddParticipant event,
      Emitter<CallState> emit,
      ) async {
    if (!groupCallEnabled) {
      _logger.info('[Conference] group call not enabled, ignoring addParticipant');
      return;
    }

    print("RRRRRRRRRRRRRRRRRRRRRRRRRRRR");
    _logger.info('[Conference] addParticipant callId=${event.callId} number=${event.number} '
        'wasUnified=${_unifiedFlowCallIds.contains(event.callId)}');

    _unifiedFlowCallIds.add(event.callId);

    // ── NEW: Immediately promote this call to group-call mode ──────────────
    // This switches the caller's (A's) UI to the group layout as soon as
    // they tap "Add", without waiting for the invitee to accept.
    // Also pre-populates conferenceParticipants with the invited number so
    // the members panel shows them as "Ringing" right away.
    final currentCall = state.retrieveActiveCall(event.callId);
    if (currentCall != null) {
      // Use event.groupName if provided; fall back to current displayName
      // (the existing callee's name) so the panel header has a meaningful label.
      final promotedGroupName = currentCall.groupName ??
          null;

      // Avoid duplicates: only add the new invitee if not already present.
      final alreadyInList = currentCall.conferenceParticipants
          .any((p) => p.userId == event.number || p.phoneNumber == event.number);

      // Resolve the contact name immediately so the UI shows the contact name
      // (not the raw phone number) during the "Ringing" state before
      // participant_joined fires and _onParticipantJoined can update it.
      final inviteeName = await contactNameResolver.resolveWithNumber(event.number) ?? event.number;

      final updatedParticipants = alreadyInList
          ? currentCall.conferenceParticipants
          : [
        ...currentCall.conferenceParticipants,
        ConferenceParticipant(
          userId:      event.number,
          displayName: inviteeName,
          phoneNumber: event.number,
        ),
      ];

      emit(state.copyWithMappedActiveCall(
        event.callId,
            (call) => call.copyWith(
          groupName:              promotedGroupName,
          conferenceParticipants: updatedParticipants,
        ),
      ));

      _logger.info('[Conference] call promoted to group: groupName=$promotedGroupName '
          'participants=${updatedParticipants.length}');
    }
    // ── END NEW ────────────────────────────────────────────────────────────

    try {
      await _signalingClient?.execute(
        CallAddParticipantRequest(
          transaction: WebtritSignalingClient.generateTransactionId(),
          callId:      event.callId,
          number:      event.number,
          hasVideo:    currentCall?.video ?? false,
        ),
      );
      _logger.info('[Conference] call_add_participant sent callId=${event.callId} number=${event.number}');
    } catch (e, s) {
      _logger.warning('[Conference] _onCallControlEventAddParticipant error', e, s);
    }
  }
}

