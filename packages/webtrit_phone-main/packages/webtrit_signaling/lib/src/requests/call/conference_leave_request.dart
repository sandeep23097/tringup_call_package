import '../abstract_requests.dart';

class ConferenceLeaveRequest extends SessionRequest {
  const ConferenceLeaveRequest({
    required super.transaction,
    required this.callId,
  });

  final String callId;

  static const typeValue = 'conference_leave';

  @override
  List<Object?> get props => [...super.props, callId];

  @override
  Map<String, dynamic> toJson() {
    return {
      Request.typeKey: typeValue,
      'transaction': transaction,
      'call_id': callId,
    };
  }
}
