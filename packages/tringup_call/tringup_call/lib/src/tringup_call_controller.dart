import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webtrit_phone/features/call/call.dart';
import 'package:webtrit_phone/models/pullable_call.dart';
import 'package:webtrit_phone/repositories/dialing/call_pull_repository.dart';

const _tag = '[TringupCallController]';
const _kChatIdsPrefKey = 'tringup_call.chat_ids';

class TringupCallController {
  TringupCallController() {
    _loadPersistedChatIds(); // fire-and-forget
  }

  BuildContext? _context;
  CallPullRepository? _pullRepository;

  // ── chatId persistence ────────────────────────────────────────────────────
  // callId → chatId is stored in SharedPreferences so it survives app restarts.
  // Entries are never auto-pruned so CDR lookups work even after a call ends.

  final Map<String, String> _callChatIds = {};

  String? _pendingChatId;
  StreamSubscription<CallState>? _pendingChatIdSub;

  Future<void> _loadPersistedChatIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kChatIdsPrefKey);
      if (raw != null) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        _callChatIds.addAll(decoded.cast<String, String>());
        if (kDebugMode) {
          debugPrint('$_tag Loaded ${_callChatIds.length} persisted chatId mappings');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('$_tag Failed to load persisted chatIds: $e');
    }
  }

  Future<void> _persistChatIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kChatIdsPrefKey, jsonEncode(_callChatIds));
    } catch (e) {
      if (kDebugMode) debugPrint('$_tag Failed to persist chatIds: $e');
    }
  }

  /// Returns the [chatId] linked to [callId], or null if none was supplied.
  ///
  /// Works across app restarts — the mapping is persisted to SharedPreferences.
  String? getChatIdForCall(String callId) => _callChatIds[callId];

  /// The chatId that is waiting to be associated with the next new callId.
  ///
  /// Set synchronously in [makeCall]/[makeGroupCall] before the BLoC event
  /// is dispatched — still valid at the moment the first BlocListener fires
  /// for the new call (before [_pendingChatIdSub] has run its mapping).
  /// Returns null if no call initiation is in progress.
  String? get pendingChatId => _pendingChatId;

  /// Starts watching [CallBloc] for the first new outgoing callId so the
  /// pending chatId can be associated with it, then persists the mapping.
  void _trackPendingChatId(BuildContext ctx, String chatId) {
    final bloc = ctx.read<CallBloc>();
    final knownIds = bloc.state.activeCalls.map((c) => c.callId).toSet();

    _pendingChatId = chatId;
    _pendingChatIdSub?.cancel();
    _pendingChatIdSub = bloc.stream.listen((state) {
      for (final call in state.activeCalls) {
        if (!knownIds.contains(call.callId) && _pendingChatId != null) {
          _callChatIds[call.callId] = _pendingChatId!;
          if (kDebugMode) {
            debugPrint('$_tag chatId mapped: ${call.callId} → $_pendingChatId');
          }
          _persistChatIds(); // fire-and-forget
          _pendingChatId = null;
          _pendingChatIdSub?.cancel();
          _pendingChatIdSub = null;
          break;
        }
      }
    });
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  // Subscription that auto-populates _callChatIds from incoming calls that
  // carry a chatId in their ActiveCall (set by the backend via call_invite).
  StreamSubscription<CallState>? _incomingChatIdSub;

  void attach(BuildContext context, {CallPullRepository? callPullRepository}) {
    _context = context;
    if (callPullRepository != null) _pullRepository = callPullRepository;

    // Auto-track chatIds from incoming calls (forwarded by the backend).
    final bloc = context.read<CallBloc>();
    _incomingChatIdSub?.cancel();
    _incomingChatIdSub = bloc.stream.listen((state) {
      for (final call in state.activeCalls) {
        final cid = call.chatId;
        if (cid != null && !_callChatIds.containsKey(call.callId)) {
          _callChatIds[call.callId] = cid;
          if (kDebugMode) {
            debugPrint('$_tag auto-tracked chatId: ${call.callId} → $cid');
          }
          _persistChatIds();
        }
      }
    });

    if (kDebugMode) debugPrint('$_tag attach — controller is now attached');

    // Kick off signaling warmup automatically so that registration is ready
    // before the user interacts with the app. Fire-and-forget — errors are
    // swallowed since a failed warmup just means the first call attempt will
    // go through the normal reconnect path.
    _warmupSignaling(bloc);
  }

  /// Ensures the signaling WebSocket is connected and the server has confirmed
  /// registration. Returns `true` when ready, `false` if timed out.
  ///
  /// Call this from the host app at startup (e.g. after `attach()`) if you
  /// want to guarantee signaling is ready before the user can place a call:
  ///
  /// ```dart
  /// await callController.ensureSignalingReady();
  /// ```
  Future<bool> ensureSignalingReady({Duration timeout = const Duration(seconds: 10)}) async {
    final ctx = _context;
    if (ctx == null) {
      if (kDebugMode) debugPrint('$_tag ensureSignalingReady — not attached');
      return false;
    }
    final bloc = ctx.read<CallBloc>();
    return _waitForSignalingReady(bloc, timeout: timeout);
  }

  /// Waits (up to [timeout]) for the bloc to reach the ready state:
  /// signaling connected + handshake received (registration status set).
  Future<bool> _waitForSignalingReady(CallBloc bloc, {required Duration timeout}) async {
    if (bloc.state.isHandshakeEstablished && bloc.state.isSignalingEstablished) {
      return true;
    }
    try {
      await bloc.stream
          .firstWhere((s) => s.isHandshakeEstablished && s.isSignalingEstablished)
          .timeout(timeout);
      if (kDebugMode) debugPrint('$_tag signaling ready');
      return true;
    } on TimeoutException {
      if (kDebugMode) debugPrint('$_tag ensureSignalingReady timed out after ${timeout.inSeconds}s');
      return false;
    } catch (e) {
      if (kDebugMode) debugPrint('$_tag ensureSignalingReady error: $e');
      return false;
    }
  }

  /// Background warmup with simple exponential retry so that a transient
  /// failure (e.g. app opens while offline) doesn't block the UI.
  Future<void> _warmupSignaling(CallBloc bloc) async {
    const maxAttempts = 4;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        final delaySecs = math.min(math.pow(2, attempt - 1).toInt(), 16);
        await Future.delayed(Duration(seconds: delaySecs));
      }
      final ready = await _waitForSignalingReady(bloc, timeout: const Duration(seconds: 8));
      if (ready) return;
      // If the context is gone (widget disposed), stop retrying.
      if (_context == null) return;
    }
    if (kDebugMode) debugPrint('$_tag _warmupSignaling gave up after $maxAttempts attempts');
  }

  void detach() {
    if (kDebugMode) debugPrint('$_tag detach');
    _pendingChatIdSub?.cancel();
    _pendingChatIdSub = null;
    _incomingChatIdSub?.cancel();
    _incomingChatIdSub = null;
    _context = null;
  }

  // ── Call Pull ─────────────────────────────────────────────────────────────

  Stream<List<PullableCall>>? get pullableCallsStream =>
      _pullRepository?.pullableCallsStreamWithValue;

  List<PullableCall> get pullableCalls => _pullRepository?.pullableCalls ?? [];

  void pickUp(PullableCall call) {
    final ctx = _context;
    if (ctx == null) {
      if (kDebugMode) debugPrint('$_tag pickUp ABORTED — not attached');
      return;
    }
    if (kDebugMode) {
      debugPrint('$_tag pickUp — number=${call.remoteNumber} callId=${call.callId}');
    }
    ctx.read<CallBloc>().add(
      CallControlEvent.started(
        number: call.remoteNumber,
        displayName: call.remoteDisplayName,
        video: false,
        replaces:
            '${call.callId};from-tag=${call.localTag};to-tag=${call.remoteTag ?? ''}',
      ),
    );
  }

  // ── Group Call ────────────────────────────────────────────────────────────

  /// Start a new group call, inviting all [numbers] simultaneously.
  ///
  /// [numbers]    — phone numbers of ALL participants to invite (must have ≥1)
  /// [video]      — true = video call, false = audio only (default: false)
  /// [chatId]     — host-app chat thread ID; links the call to the chat
  /// [groupName]  — display name shown on the outgoing call screen ("Calling groupName")
  void makeGroupCall({
    required List<String> numbers,
    bool video = false,
    String? chatId,
    String? groupName,
  }) {
    if (numbers.isEmpty) return;
    final ctx = _context;
    if (ctx == null) {
      if (kDebugMode) debugPrint('$_tag makeGroupCall ABORTED — not attached');
      return;
    }
    if (kDebugMode) {
      debugPrint('$_tag makeGroupCall — participants=${numbers.length} '
          'numbers=$numbers chatId=$chatId groupName=$groupName');
    }

    if (chatId != null) _trackPendingChatId(ctx, chatId);

    // Invite all participants simultaneously via a single call_initiate.
    // The backend creates one LiveKit room and sends call_invite to every
    // callee at the same time — no sequential dial-first-then-add needed.
    ctx.read<CallBloc>().add(
      CallControlEvent.initiate(
        numbers:     numbers,
        video:       video,
        displayName: groupName,
        groupName:   groupName,
        chatId:      chatId,
      ),
    );
  }

  /// Add a single participant to the currently active call.
  void addParticipantToCurrentCall(String number) {
    final ctx = _context;
    if (ctx == null) {
      if (kDebugMode) debugPrint('$_tag addParticipantToCurrentCall ABORTED — not attached');
      return;
    }
    final callBloc = ctx.read<CallBloc>();
    final activeCalls = callBloc.state.activeCalls;
    if (activeCalls.isEmpty) {
      if (kDebugMode) debugPrint('$_tag addParticipantToCurrentCall — no active call');
      return;
    }
    final callId = activeCalls.first.callId;
    if (kDebugMode) {
      debugPrint('$_tag addParticipantToCurrentCall — callId=$callId number=$number');
    }
    callBloc.add(CallControlEvent.addParticipant(callId, number));
  }

  String? get activeCallId {
    final ctx = _context;
    if (ctx == null) return null;
    final calls = ctx.read<CallBloc>().state.activeCalls;
    return calls.isEmpty ? null : calls.first.callId;
  }

  /// Initiates an outgoing call.
  ///
  /// [chatId] links this call to a host-app chat thread. The mapping is
  /// persisted to SharedPreferences and survives app restarts.
  /// Retrieve it via [getChatIdForCall] using the call's [callId].
  void makeCall({
    required String number,
    String? displayName,
    bool video = false,
    String? chatId,
  }) {
    if (kDebugMode) {
      debugPrint('$_tag makeCall — number=$number displayName=$displayName '
          'video=$video chatId=$chatId isAttached=$isAttached');
    }
    final ctx = _context;
    assert(
      ctx != null,
      'TringupCallController must be attached to a TringupCallWidget before calling makeCall',
    );
    if (ctx == null) {
      if (kDebugMode) debugPrint('$_tag makeCall ABORTED — context is null (not attached)');
      return;
    }

    if (chatId != null) _trackPendingChatId(ctx, chatId);

    if (kDebugMode) debugPrint('$_tag makeCall — dispatching CallControlEvent.started');
    ctx.read<CallBloc>().add(
      CallControlEvent.started(
        number: number,
        displayName: displayName,
        video: video,
      ),
    );
    if (kDebugMode) debugPrint('$_tag makeCall — event dispatched to CallBloc');
  }

  void updateToken(String newToken) {
    if (kDebugMode) debugPrint('$_tag updateToken — isAttached=$isAttached');
    final ctx = _context;
    if (ctx == null) {
      if (kDebugMode) debugPrint('$_tag updateToken — context null, skipping');
      return;
    }
    ctx.read<CallBloc>().add(const CallStarted());
  }

  bool get isAttached => _context != null;
}
