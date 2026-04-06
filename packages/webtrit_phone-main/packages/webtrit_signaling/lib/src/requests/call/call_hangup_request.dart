import '../abstract_requests.dart';

/// Leave / end a call.
/// Replaces hangup + conference_leave.
class CallHangupRequest extends SessionRequest {
  const CallHangupRequest({
    required super.transaction,
    required this.callId,
  });

  final String callId;

  static const typeValue = 'call_hangup';

  @override
  List<Object?> get props => [...super.props, callId];

  @override
  Map<String, dynamic> toJson() => {
    Request.typeKey: typeValue,
    'transaction':   transaction,
    'call_id':       callId,
  };
}
