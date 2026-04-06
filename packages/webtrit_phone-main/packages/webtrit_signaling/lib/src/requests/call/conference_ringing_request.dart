import '../abstract_requests.dart';

/// Sent by the invitee's device immediately upon receiving [conference_invite].
/// The backend forwards this as [conference_ringing] to all existing call
/// participants so they can update their UI from "Calling…" to "Ringing…".
class ConferenceRingingRequest extends SessionRequest {
  const ConferenceRingingRequest({
    required super.transaction,
    required this.callId,
  });

  final String callId;

  static const typeValue = 'conference_ringing';

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
