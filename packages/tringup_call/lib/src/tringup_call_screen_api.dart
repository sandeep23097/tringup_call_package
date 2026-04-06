import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Simplified audio output route exposed to the host app.
enum TringupAudioOutput { earpiece, speaker, bluetooth, wired }

/// A single participant in a group / conference call.
@immutable
class TringupParticipant {
  const TringupParticipant({
    required this.userId,
    this.displayName,
    this.phoneNumber,
    this.photoUrl,
    this.photoPath,
  });

  /// Server-side user ID — used for matching / deduplication.
  final String userId;

  /// Human-readable name shown in the UI.
  final String? displayName;

  /// Phone number to dial when adding this contact to a call.
  /// Populated only for [TringupCallInfo.addableParticipants].
  final String? phoneNumber;

  /// Remote URL of the contact's profile photo, if available.
  final String? photoUrl;

  /// Local file-system path to the contact's profile photo.
  /// Takes precedence over [photoUrl] when both are set.
  final String? photoPath;

  /// Display label: display name falling back to userId.
  String get label => (displayName?.isNotEmpty == true) ? displayName! : userId;
}

/// Immutable snapshot of the current call, provided to [TringupCallScreenBuilder].
/// Does not expose any webtrit_phone types.
@immutable
class TringupCallInfo {
  const TringupCallInfo({
    required this.callId,
    required this.number,
    this.displayName,
    this.photoUrl,
    this.photoPath,
    required this.isIncoming,
    required this.isConnected,
    this.isRinging = false,
    required this.isMuted,
    required this.isOnHold,
    this.connectedAt,
    required this.audioOutput,
    this.isGroupCallEnabled = false,
    this.isVideoCall = false,
    this.isCameraEnabled = false,
    this.participants = const [],
    this.isGroupCall = false,
    this.addableParticipants = const [],
    this.ringingUserIds = const {},
    this.localUserNumber,
    this.participantPhoneMap = const {},
    this.busySignal = false,
  });

  final String callId;

  /// The remote phone number.
  final String number;

  /// Display name resolved from contacts, if available.
  final String? displayName;

  /// Network URL of the remote party's profile photo.
  /// Provided by the host app via [TringupCallShell.photoProvider].
  final String? photoUrl;

  /// Local file-system path to the remote party's profile photo.
  /// Takes precedence over [photoUrl] when both are set.
  final String? photoPath;

  final bool isIncoming;

  /// True once the call has been answered and media is flowing.
  final bool isConnected;

  /// True when the outgoing call has been delivered to the callee's device and
  /// it is now ringing, but the callee has not answered yet.
  /// Transitions: isConnected=false → isRinging=true → isConnected=true.
  final bool isRinging;

  final bool isMuted;
  final bool isOnHold;

  /// Set when the call is connected; use for elapsed-time display.
  final DateTime? connectedAt;

  final TringupAudioOutput audioOutput;

  /// Whether the conference/group-call feature is enabled for this session.
  final bool isGroupCallEnabled;

  /// True if this is a video call (local camera was requested).
  final bool isVideoCall;

  /// True if the local camera track is currently enabled (not paused).
  final bool isCameraEnabled;

  /// Current conference participants (empty for 1:1 calls).
  final List<TringupParticipant> participants;

  /// True when this call was initiated as a group call (set from [ActiveCall.groupName]).
  /// Does not require remote participants to have joined yet.
  final bool isGroupCall;

  /// Contacts that can be added to this call (provided by the host app via
  /// [TringupCallShell.participantsProvider]).
  final List<TringupParticipant> addableParticipants;

  /// Set of userIds whose devices have confirmed receipt of a conference invite
  /// (i.e. their phone is ringing). Used to upgrade UI from "Calling…" to "Ringing…".
  final Set<String> ringingUserIds;

  /// The current user's own registered phone number.
  /// Used in the panel to identify "self" when the LiveKit identity
  /// differs from the stored phone-number userId in conferenceParticipants.
  final String? localUserNumber;

  /// userId → phoneNumber mapping for all known participants.
  /// Enables cross-namespace matching: caller pre-populates with phone-number
  /// userIds while LiveKit uses server IDs — this map bridges the two.
  final Map<String, String> participantPhoneMap;

  /// True when the remote party is busy and the call will auto-dismiss shortly.
  final bool busySignal;

  /// Caller display label: display name falling back to number.
  String get callerLabel => (displayName?.isNotEmpty == true) ? displayName! : number;
}

/// Call Detail Record — delivered to the host app via
/// [TringupCallShell.onCallEndedWithCDR] immediately when any call ends.
@immutable
class TringupCallCDR {
  const TringupCallCDR({
    required this.callId,
    required this.number,
    this.displayName,
    this.callerId,
    this.chatId,
    this.groupName,
    this.participants = const [],
    required this.createdAt,
    this.connectedAt,
    required this.endedAt,
    required this.isIncoming,
    required this.isVideo,
    required this.endReason,
  });

  final String callId;

  /// Primary remote phone number.
  final String number;
  final String? displayName;

  /// The initiator of the call — the caller's phone number or server userId.
  ///
  /// For outgoing calls this is the local user's registered phone number.
  /// For incoming calls this is the remote caller's phone number.
  /// Derived from the SIP `From` header; may be null if not available.
  final String? callerId;

  /// The host-app chat thread this call belongs to.
  ///
  /// Set for group calls and for incoming calls where the backend forwards a
  /// chatId in the signalling event.  For outgoing 1:1 calls where chatId is
  /// not carried in the signalling layer this will be null — fall back to
  /// [TringupCallController.getChatIdForCall] in that case.
  final String? chatId;

  /// Non-null for group calls.
  final String? groupName;

  /// All participants for group calls; empty for 1:1 calls.
  final List<TringupParticipant> participants;

  final DateTime createdAt;

  /// Null when the call was never answered.
  final DateTime? connectedAt;

  final DateTime endedAt;
  final bool isIncoming;
  final bool isVideo;

  /// End reason: 'normal_clearing', 'cancelled', 'missed', 'no_answer'.
  final String endReason;

  /// Null when the call was never answered.
  Duration? get duration =>
      connectedAt != null ? endedAt.difference(connectedAt!) : null;

  bool get wasAnswered => connectedAt != null;
}

/// Action callbacks backed by [CallBloc] events, with no webtrit_phone imports
/// required by the host app.
@immutable
class TringupCallActions {
  const TringupCallActions({
    required this.hangUp,
    required this.setMuted,
    required this.setSpeaker,
    required this.setHeld,
    required this.switchCamera,
    required this.setCameraEnabled,
    required this.minimize,
    this.answer,
    this.addParticipant,
  });

  final VoidCallback hangUp;
  final void Function(bool muted) setMuted;

  /// [speakerOn] true → speaker, false → earpiece.
  final void Function(bool speakerOn) setSpeaker;

  /// Put the call on hold / resume it.
  final void Function(bool onHold) setHeld;

  /// Flip between front and rear camera.
  final VoidCallback switchCamera;

  /// Enable or disable the local video camera.
  final void Function(bool enabled) setCameraEnabled;

  /// Minimize the call screen to the draggable thumbnail overlay.
  final VoidCallback minimize;

  /// Non-null when the call is incoming and has not yet been answered.
  final VoidCallback? answer;

  /// Add a participant to the current call by phone number.
  /// Non-null only when the group-call feature is enabled
  /// ([TringupCallInfo.isGroupCallEnabled] == true) and the call is connected.
  final void Function(String number)? addParticipant;
}

/// Signature for the optional custom call-screen builder passed to
/// [TringupCallShell].
///
/// The [context] has [CallBloc] available for advanced use, but [info] and
/// [actions] cover the common case without requiring webtrit_phone imports.
typedef TringupCallScreenBuilder = Widget Function(
  BuildContext context,
  TringupCallInfo info,
  TringupCallActions actions,
);

/// Builder for a custom audio-call overlay banner (shown when an audio call is
/// minimised to the [CallDisplay.overlay] state).
///
/// The widget is wrapped in a full-width [SafeArea] positioned at the top of
/// the screen by [TringupCallShell].  Return only the inner content (a [Row],
/// [Container], etc.) — do not add your own [Positioned] or [SafeArea].
///
/// [info]    — read-only snapshot of the current call state.
/// [actions] — call action callbacks; `actions.minimize` restores the full
///             call screen, `actions.hangUp` ends the call.
typedef TringupAudioCallOverlayBuilder = Widget Function(
  BuildContext context,
  TringupCallInfo info,
  TringupCallActions actions,
);
