import '../abstract_requests.dart';

class ConferenceSubscribeAnswerRequest extends SessionRequest {
  const ConferenceSubscribeAnswerRequest({
    required super.transaction,
    required this.callId,
    required this.feedId,
    required this.jsep,
  });

  final String callId;
  final int feedId;
  final Map<String, dynamic> jsep;

  static const typeValue = 'conference_subscribe_answer';

  @override
  List<Object?> get props => [...super.props, callId, feedId, jsep];

  @override
  Map<String, dynamic> toJson() {
    return {
      Request.typeKey: typeValue,
      'transaction': transaction,
      'call_id': callId,
      'feed_id': feedId,
      'jsep': jsep,
    };
  }
}
