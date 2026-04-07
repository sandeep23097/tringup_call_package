import 'tringup_call_screen_api.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Phase enum
// ─────────────────────────────────────────────────────────────────────────────

enum TringupCallPhase {
  /// No call is active for this chatId / userId.
  idle,

  /// Outgoing call is dialling — waiting for the remote to answer.
  calling,

  /// Remote device is ringing (outgoing) OR an incoming call is arriving.
  ringing,

  /// Call has been accepted; media is negotiating.
  connecting,

  /// Media is flowing — call is fully connected.
  connected,

  /// Call has ended. [TringupCallStatus.endedCdr] carries the full CDR.
  /// Transitions to [idle] once the host app dismisses its "ended" UI.
  ended,
}

// ─────────────────────────────────────────────────────────────────────────────
// Status snapshot
// ─────────────────────────────────────────────────────────────────────────────

/// Immutable snapshot of a call's state, keyed by [chatId].
///
/// Emitted by [TringupCallStatusStream] on every phase transition.
class TringupCallStatus {
  const TringupCallStatus({
    required this.chatId,
    required this.phase,
    this.callId,
    this.remoteNumber,
    this.displayName,
    this.isGroupCall = false,
    this.groupName,
    this.connectedAt,
    this.endedCdr,
  });

  /// The chat thread this call belongs to (set when a call is initiated from a
  /// chat screen via [chatId] parameter).
  final String chatId;

  /// Current lifecycle phase.
  final TringupCallPhase phase;

  /// Signalling call ID — useful for correlation / logging.
  final String? callId;

  /// Remote party's phone number.
  final String? remoteNumber;

  /// Resolved display name for the remote party.
  final String? displayName;

  /// True when this is a group / conference call.
  final bool isGroupCall;

  /// Group name (non-null for group calls).
  final String? groupName;

  /// When the call was answered; null before acceptance.
  final DateTime? connectedAt;

  /// Full CDR — only non-null when [phase] == [TringupCallPhase.ended].
  final TringupCallCDR? endedCdr;

  /// True while a call is in-progress (not idle and not ended).
  bool get isActive =>
      phase != TringupCallPhase.idle && phase != TringupCallPhase.ended;

  /// True when the user can attempt to rejoin the group call.
  bool get canRejoin =>
      phase == TringupCallPhase.ended && isGroupCall && chatId.isNotEmpty;

  @override
  String toString() =>
      'TringupCallStatus(chatId: $chatId, phase: $phase, remoteNumber: $remoteNumber)';
}