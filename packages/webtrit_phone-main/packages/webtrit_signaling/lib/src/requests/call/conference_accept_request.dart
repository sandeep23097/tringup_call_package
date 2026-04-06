import '../abstract_requests.dart';

class ConferenceAcceptRequest extends SessionRequest {
  const ConferenceAcceptRequest({
    required super.transaction,
    required this.callId,
    this.roomId,
    this.jsep,
  });

  final String callId;
  final int? roomId;
  final Map<String, dynamic>? jsep;

  static const typeValue = 'conference_accept';

  @override
  List<Object?> get props => [...super.props, callId, roomId, jsep];

  @override
  Map<String, dynamic> toJson() {
    return {
      Request.typeKey: typeValue,
      'transaction': transaction,
      'call_id': callId,
      if (roomId != null) 'room_id': roomId,
      if (jsep != null) 'jsep': jsep,
    };
  }
}
