import '../abstract_events.dart';

/// Sent to all call participants when any participant accepts the call.
/// Replaces the legacy 'accepted' event.
class CallAcceptedEvent extends CallEvent {
  const CallAcceptedEvent({
    super.transaction,
    required super.line,
    required super.callId,
  });

  @override
  List<Object?> get props => [...super.props];

  static const typeValue = 'call_accepted';

  factory CallAcceptedEvent.fromJson(Map<String, dynamic> json) {
    final eventTypeValue = json[Event.typeKey];
    if (eventTypeValue != typeValue) {
      throw ArgumentError.value(eventTypeValue, Event.typeKey, 'Not equal $typeValue');
    }

    return CallAcceptedEvent(
      transaction: json['transaction'],
      line:        json['line'] ?? 0,
      callId:      json['call_id'],
    );
  }
}
