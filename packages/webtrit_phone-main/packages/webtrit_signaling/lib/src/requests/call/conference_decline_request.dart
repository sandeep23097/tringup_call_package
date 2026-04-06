import '../abstract_requests.dart';

class ConferenceDeclineRequest extends SessionRequest {
  const ConferenceDeclineRequest({
    required super.transaction,
    required this.callId,
    required this.roomId,
  });

  final String callId;
  final int roomId;

  static const typeValue = 'conference_decline';

  @override
  List<Object?> get props => [...super.props, callId, roomId];

  @override
  Map<String, dynamic> toJson() {
    return {
      Request.typeKey: typeValue,
      'transaction': transaction,
      'call_id': callId,
      'room_id': roomId,
    };
  }
}
