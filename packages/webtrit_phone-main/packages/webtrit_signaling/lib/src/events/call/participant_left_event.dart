import '../abstract_events.dart';

/// Sent to remaining participants when someone leaves the call.
/// Replaces conference_participant_left.
class ParticipantLeftEvent extends CallEvent {
  const ParticipantLeftEvent({
    super.transaction,
    required super.line,
    required super.callId,
    required this.userId,
  });

  final String userId;

  @override
  List<Object?> get props => [...super.props, userId];

  static const typeValue = 'participant_left';

  factory ParticipantLeftEvent.fromJson(Map<String, dynamic> json) {
    final eventTypeValue = json[Event.typeKey];
    if (eventTypeValue != typeValue) {
      throw ArgumentError.value(eventTypeValue, Event.typeKey, 'Not equal $typeValue');
    }

    return ParticipantLeftEvent(
      transaction: json['transaction'],
      line:        json['line'] ?? 0,
      callId:      json['call_id'],
      userId:      json['user_id'] ?? '',
    );
  }
}
