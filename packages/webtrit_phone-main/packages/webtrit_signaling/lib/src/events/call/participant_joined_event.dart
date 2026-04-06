import '../abstract_events.dart';

/// Sent to all participants when a new participant joins the call.
/// Replaces conference_participant_joined.
///
/// The [number] field is the participant's phone number — the client
/// resolves the display name from device contacts.
class ParticipantJoinedEvent extends CallEvent {
  const ParticipantJoinedEvent({
    super.transaction,
    required super.line,
    required super.callId,
    required this.userId,
    required this.number,
  });

  final String userId;
  final String number;

  @override
  List<Object?> get props => [...super.props, userId, number];

  static const typeValue = 'participant_joined';

  factory ParticipantJoinedEvent.fromJson(Map<String, dynamic> json) {
    final eventTypeValue = json[Event.typeKey];
    if (eventTypeValue != typeValue) {
      throw ArgumentError.value(eventTypeValue, Event.typeKey, 'Not equal $typeValue');
    }

    return ParticipantJoinedEvent(
      transaction: json['transaction'],
      line:        json['line'] ?? 0,
      callId:      json['call_id'],
      userId:      json['user_id'] ?? '',
      number:      json['number'] ?? '',
    );
  }
}
