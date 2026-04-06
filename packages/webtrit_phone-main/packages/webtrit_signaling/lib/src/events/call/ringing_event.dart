import '../abstract_events.dart';

class RingingEvent extends CallEvent {
  const RingingEvent({
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

  static const typeValue = 'ringing';

  factory RingingEvent.fromJson(Map<String, dynamic> json) {
    final eventTypeValue = json[Event.typeKey];
    if (eventTypeValue != typeValue) {
      throw ArgumentError.value(eventTypeValue, Event.typeKey, 'Not equal $typeValue');
    }

    return RingingEvent(
      transaction: json['transaction'],
      line: json['line'],
      callId: json['call_id'],
      livekitUrl: json['livekit_url'],
      livekitToken: json['livekit_token'],
    );
  }
}
