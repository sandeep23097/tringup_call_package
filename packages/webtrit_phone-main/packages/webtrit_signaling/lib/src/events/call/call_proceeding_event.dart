import '../abstract_events.dart';

/// Sent to the caller immediately after call_initiate is processed.
/// Replaces the legacy 'calling' / 'proceeding' events.
class CallProceedingEvent extends CallEvent {
  const CallProceedingEvent({
    super.transaction,
    required super.line,
    required super.callId,
  });

  @override
  List<Object?> get props => [...super.props];

  static const typeValue = 'call_proceeding';

  factory CallProceedingEvent.fromJson(Map<String, dynamic> json) {
    final eventTypeValue = json[Event.typeKey];
    if (eventTypeValue != typeValue) {
      throw ArgumentError.value(eventTypeValue, Event.typeKey, 'Not equal $typeValue');
    }

    return CallProceedingEvent(
      transaction: json['transaction'],
      line:        json['line'] ?? 0,
      callId:      json['call_id'],
    );
  }
}
