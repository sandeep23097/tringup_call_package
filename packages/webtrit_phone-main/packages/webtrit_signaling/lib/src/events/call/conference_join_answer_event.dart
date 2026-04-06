import '../abstract_events.dart';

class ConferenceJoinAnswerEvent extends CallEvent {
  const ConferenceJoinAnswerEvent({
    super.transaction,
    required super.line,
    required super.callId,
    required this.roomId,
    required this.jsep,
  });

  final int roomId;
  final Map<String, dynamic> jsep;

  static const typeValue = 'conference_join_answer';

  @override
  List<Object?> get props => [...super.props, roomId, jsep];

  factory ConferenceJoinAnswerEvent.fromJson(Map<String, dynamic> json) {
    return ConferenceJoinAnswerEvent(
      transaction: json['transaction'],
      line: json['line'],
      callId: json['call_id'],
      roomId: json['room_id'],
      jsep: Map<String, dynamic>.from(json['jsep']),
    );
  }
}
