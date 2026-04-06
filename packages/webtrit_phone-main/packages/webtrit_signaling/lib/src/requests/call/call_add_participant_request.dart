import '../abstract_requests.dart';

/// Add a new participant to an active call.
/// Replaces add_to_call.
class CallAddParticipantRequest extends SessionRequest {
  const CallAddParticipantRequest({
    required super.transaction,
    required this.callId,
    required this.number,
    this.hasVideo = false,
  });

  final String callId;
  final String number;
  final bool hasVideo;
  static const typeValue = 'call_add_participant';

  @override
  List<Object?> get props => [...super.props, callId, number, hasVideo];

  @override
  Map<String, dynamic> toJson() => {
    Request.typeKey: typeValue,
    'transaction':   transaction,
    'call_id':       callId,
    'number':        number,
    'has_video':     hasVideo,
  };
}
