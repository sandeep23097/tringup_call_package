import '../abstract_requests.dart';

/// Accept an incoming call_invite.
/// Replaces accept + conference_accept.
class CallAcceptRequest extends SessionRequest {
  const CallAcceptRequest({
    required super.transaction,
    required this.callId,
    this.line,
  });

  final String callId;
  final int? line;

  static const typeValue = 'call_accept';

  @override
  List<Object?> get props => [...super.props, callId, line];

  @override
  Map<String, dynamic> toJson() => {
    Request.typeKey: typeValue,
    'transaction':   transaction,
    'call_id':       callId,
    if (line != null) 'line': line,
  };
}
