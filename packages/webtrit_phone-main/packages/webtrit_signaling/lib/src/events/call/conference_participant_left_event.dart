import '../abstract_events.dart';

class ConferenceParticipantLeftEvent extends CallEvent {
  const ConferenceParticipantLeftEvent({
    super.transaction,
    required super.line,
    required super.callId,
    this.roomId,
    required this.userId,
  });

  final int? roomId;
  final String userId;

  static const typeValue = 'conference_participant_left';

  @override
  List<Object?> get props => [...super.props, roomId, userId];

  factory ConferenceParticipantLeftEvent.fromJson(Map<String, dynamic> json) {
    return ConferenceParticipantLeftEvent(
      transaction: json['transaction'],
      line: json['line'],
      callId: json['call_id'],
      roomId: json['room_id'],
      userId: json['user_id'],
    );
  }
}
