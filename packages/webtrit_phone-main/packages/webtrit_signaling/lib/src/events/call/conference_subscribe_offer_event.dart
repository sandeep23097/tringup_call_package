import '../abstract_events.dart';

class ConferenceSubscribeOfferEvent extends CallEvent {
  const ConferenceSubscribeOfferEvent({
    super.transaction,
    required super.line,
    required super.callId,
    required this.feedId,
    required this.userId,
    required this.jsep,
  });

  final int feedId;
  final String userId;
  final Map<String, dynamic> jsep;

  static const typeValue = 'conference_subscribe_offer';

  @override
  List<Object?> get props => [...super.props, feedId, userId, jsep];

  factory ConferenceSubscribeOfferEvent.fromJson(Map<String, dynamic> json) {
    return ConferenceSubscribeOfferEvent(
      transaction: json['transaction'],
      line: json['line'],
      callId: json['call_id'],
      feedId: json['feed_id'],
      userId: json['user_id'],
      jsep: Map<String, dynamic>.from(json['jsep']),
    );
  }
}
