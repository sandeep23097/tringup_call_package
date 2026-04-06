import '../abstract_events.dart';

class ConferenceParticipantJoinedEvent extends CallEvent {
  const ConferenceParticipantJoinedEvent({
    super.transaction,
    required super.line,
    required super.callId,
    this.roomId,
    required this.userId,
    this.displayName,
  });

  final int? roomId;
  final String userId;
  final String? displayName;

  static const typeValue = 'conference_participant_joined';

  @override
  List<Object?> get props => [...super.props, roomId, userId, displayName];

  factory ConferenceParticipantJoinedEvent.fromJson(Map<String, dynamic> json) {
    return ConferenceParticipantJoinedEvent(
      transaction: json['transaction'],
      line: json['line'],
      callId: json['call_id'],
      roomId: json['room_id'],
      userId: json['user_id'],
      displayName: json['display_name'],
    );
  }
}
