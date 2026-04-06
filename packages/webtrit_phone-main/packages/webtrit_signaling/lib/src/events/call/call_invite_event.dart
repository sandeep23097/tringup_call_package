import '../abstract_events.dart';

/// Unified incoming call event sent by the server for all call types
/// (1-on-1, group, add-member).  Replaces incoming_call, conference_invite,
/// and conference_upgrade.
///
/// Display names are NOT included — the client resolves phone numbers against
/// device contacts.
class CallInviteEvent extends CallEvent {
  const CallInviteEvent({
    super.transaction,
    required super.line,
    required super.callId,
    required this.callerNumber,
    required this.callerId,
    required this.participantNumbers,
    this.hasVideo,
    this.livekitUrl,
    this.livekitToken,
    this.groupName,
    this.chatId,
  });

  /// Phone number of the person who initiated the call.
  final String callerNumber;

  /// User-ID of the caller (opaque server identifier).
  final String callerId;

  /// Phone numbers of all other participants (excluding the recipient of this
  /// event and the caller).
  final List<String> participantNumbers;

  final bool? hasVideo;
  final String? livekitUrl;
  final String? livekitToken;

  /// Group/chat name set by the caller — shown on the incoming call screen
  /// instead of just the caller's number for group calls.
  final String? groupName;

  /// Host-app chat thread ID forwarded from the caller for CDR linking.
  final String? chatId;

  @override
  List<Object?> get props => [
    ...super.props,
    callerNumber,
    callerId,
    participantNumbers,
    hasVideo,
    livekitUrl,
    livekitToken,
    groupName,
    chatId,
  ];

  static const typeValue = 'call_invite';

  factory CallInviteEvent.fromJson(Map<String, dynamic> json) {
    final eventTypeValue = json[Event.typeKey];
    if (eventTypeValue != typeValue) {
      throw ArgumentError.value(eventTypeValue, Event.typeKey, 'Not equal $typeValue');
    }

    final rawNums = json['participant_numbers'];
    final participantNumbers = rawNums is List
        ? rawNums.cast<String>()
        : <String>[];

    return CallInviteEvent(
      transaction:         json['transaction'],
      line:                json['line'] ?? 0,
      callId:              json['call_id'],
      callerNumber:        json['caller_number'] ?? '',
      callerId:            json['caller_id'] ?? '',
      participantNumbers:  participantNumbers,
      hasVideo:            json['has_video'],
      livekitUrl:          json['livekit_url'],
      livekitToken:        json['livekit_token'],
      groupName:           json['group_name'],
      chatId:              json['chat_id'],
    );
  }
}
