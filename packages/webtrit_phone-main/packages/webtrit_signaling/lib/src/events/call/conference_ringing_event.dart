import '../abstract_events.dart';

/// Sent by the backend to the inviter when the invited user's device has
/// received the [conference_invite] (confirmed via socket or push ack).
class ConferenceRingingEvent extends CallEvent {
  const ConferenceRingingEvent({
    super.transaction,
    required super.line,
    required super.callId,
    required this.userId, // the invitee who is ringing
  });

  final String userId;

  static const typeValue = 'conference_ringing';

  @override
  List<Object?> get props => [...super.props, userId];

  factory ConferenceRingingEvent.fromJson(Map<String, dynamic> json) {
    return ConferenceRingingEvent(
      transaction: json['transaction'],
      line: json['line'] ?? 0,
      callId: json['call_id'],
      userId: json['user_id'],
    );
  }
}
