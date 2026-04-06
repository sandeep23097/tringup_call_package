import '../abstract_requests.dart';

class IceTrickleRequest extends LineRequest {
  const IceTrickleRequest({required super.transaction, required super.line, this.callId, this.feedId, this.candidate});

  /// Optional call ID sent alongside the trickle so the backend can look up
  /// the call by ID (more reliable than line-based lookup).
  final String? callId;

  /// When set, this candidate is for a VideoRoom subscriber handle (not the publisher).
  /// The value is the Janus feedId of the publisher being subscribed to.
  final int? feedId;

  final Map<String, dynamic>? candidate;

  @override
  List<Object?> get props => [...super.props, callId, feedId, candidate];

  static const typeValue = 'ice_trickle';

  factory IceTrickleRequest.fromJson(Map<String, dynamic> json) {
    final requestTypeValue = json[Request.typeKey];
    if (requestTypeValue != typeValue) {
      throw ArgumentError.value(requestTypeValue, Request.typeKey, 'Not equal $typeValue');
    }

    return IceTrickleRequest(
      transaction: json['transaction'],
      line: json['line'],
      callId: json['call_id'] as String?,
      feedId: json['feed_id'] as int?,
      candidate: json['candidate'],
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      Request.typeKey: typeValue,
      'transaction': transaction,
      'line': line,
      if (callId != null) 'call_id': callId,
      if (feedId != null) 'feed_id': feedId,
      'candidate': candidate,
    };
  }
}
