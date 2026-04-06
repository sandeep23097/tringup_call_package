import '../abstract_requests.dart';

class ConferenceJoinRequest extends SessionRequest {
  const ConferenceJoinRequest({
    required super.transaction,
    required this.callId,
    required this.roomId,
    required this.jsep,
  });

  final String callId;
  final int roomId;
  final Map<String, dynamic> jsep;

  static const typeValue = 'conference_join';

  @override
  List<Object?> get props => [...super.props, callId, roomId, jsep];

  @override
  Map<String, dynamic> toJson() {
    return {
      Request.typeKey: typeValue,
      'transaction': transaction,
      'call_id': callId,
      'room_id': roomId,
      'jsep': jsep,
    };
  }
}
