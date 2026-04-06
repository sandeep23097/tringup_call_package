import '../abstract_events.dart';

/// Sent by the backend to the inviter when the invited user declined the
/// [conference_invite]. The inviter's UI should stop ringing for that invitee.
class ConferenceDeclinedEvent extends CallEvent {
  const ConferenceDeclinedEvent({
    super.transaction,
    required super.line,
    required super.callId,
    required this.userId, // the invitee who declined
  });

  final String userId;

  static const typeValue = 'conference_declined';

  @override
  List<Object?> get props => [...super.props, userId];

  factory ConferenceDeclinedEvent.fromJson(Map<String, dynamic> json) {
    return ConferenceDeclinedEvent(
      transaction: json['transaction'],
      line: json['line'] ?? 0,
      callId: json['call_id'],
      userId: json['user_id'],
    );
  }
}
