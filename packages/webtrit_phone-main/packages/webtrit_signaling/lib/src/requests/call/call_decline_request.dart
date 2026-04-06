import '../abstract_requests.dart';

/// Decline an incoming call_invite.
/// Replaces decline + conference_decline.
class CallDeclineRequest extends SessionRequest {
  const CallDeclineRequest({
    required super.transaction,
    required this.callId,
  });

  final String callId;

  static const typeValue = 'call_decline';

  @override
  List<Object?> get props => [...super.props, callId];

  @override
  Map<String, dynamic> toJson() => {
    Request.typeKey: typeValue,
    'transaction':   transaction,
    'call_id':       callId,
  };
}
