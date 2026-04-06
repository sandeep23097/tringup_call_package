import '../abstract_events.dart';

/// Sent to all remaining participants when a call ends for any reason.
/// Replaces hangup, missed_call, and conference cleanup events.
class CallEndedEvent extends CallEvent {
  const CallEndedEvent({
    super.transaction,
    required super.line,
    required super.callId,
    required this.reason,
  });

  /// Why the call ended.  One of:
  ///   'normal'    — hung up normally
  ///   'missed'    — caller cancelled before anyone answered
  ///   'declined'  — all callees declined
  ///   'no_answer' — no callee device acknowledged receipt within timeout
  ///   'busy'      — callee is busy
  ///   'not_found' — no user matched the dialled number
  final String reason;

  @override
  List<Object?> get props => [...super.props, reason];

  static const typeValue = 'call_ended';

  factory CallEndedEvent.fromJson(Map<String, dynamic> json) {
    final eventTypeValue = json[Event.typeKey];
    if (eventTypeValue != typeValue) {
      throw ArgumentError.value(eventTypeValue, Event.typeKey, 'Not equal $typeValue');
    }

    return CallEndedEvent(
      transaction: json['transaction'],
      line:        json['line'] ?? 0,
      callId:      json['call_id'],
      reason:      json['reason'] ?? 'normal',
    );
  }
}
