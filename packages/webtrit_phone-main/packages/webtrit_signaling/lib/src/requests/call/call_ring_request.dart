import '../abstract_requests.dart';

/// Sent by the callee device when it receives and displays the call_invite.
/// Tells the server (and thus all participants) that this device is ringing.
/// Replaces call_received + conference_ringing.
class CallRingRequest extends SessionRequest {
  const CallRingRequest({
    required super.transaction,
    required this.callId,
  });

  final String callId;

  static const typeValue = 'call_ring';

  @override
  List<Object?> get props => [...super.props, callId];

  @override
  Map<String, dynamic> toJson() => {
    Request.typeKey: typeValue,
    'transaction':   transaction,
    'call_id':       callId,
  };
}
