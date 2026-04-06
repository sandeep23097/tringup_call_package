import '../abstract_events.dart';

/// Sent to the caller when a callee device has acknowledged receipt.
/// Carries the caller's LiveKit token so they can join the room.
/// Replaces the legacy 'ringing' event.
class CallRingingEvent extends CallEvent {
  const CallRingingEvent({
    super.transaction,
    required super.line,
    required super.callId,
    this.livekitUrl,
    this.livekitToken,
  });

  final String? livekitUrl;
  final String? livekitToken;

  @override
  List<Object?> get props => [...super.props, livekitUrl, livekitToken];

  static const typeValue = 'call_ringing';

  factory CallRingingEvent.fromJson(Map<String, dynamic> json) {
    final eventTypeValue = json[Event.typeKey];
    if (eventTypeValue != typeValue) {
      throw ArgumentError.value(eventTypeValue, Event.typeKey, 'Not equal $typeValue');
    }

    return CallRingingEvent(
      transaction:  json['transaction'],
      line:         json['line'] ?? 0,
      callId:       json['call_id'],
      livekitUrl:   json['livekit_url'],
      livekitToken: json['livekit_token'],
    );
  }
}
