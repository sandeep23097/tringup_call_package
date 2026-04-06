import '../abstract_events.dart';

class UpdatedEvent extends CallEvent {
  const UpdatedEvent({super.transaction, required super.line, required super.callId, this.jsep});

  final Map<String, dynamic>? jsep;

  static const typeValue = 'updated';

  @override
  List<Object?> get props => [...super.props, jsep];

  factory UpdatedEvent.fromJson(Map<String, dynamic> json) {
    final eventTypeValue = json[Event.typeKey];
    if (eventTypeValue != typeValue) {
      throw ArgumentError.value(eventTypeValue, Event.typeKey, 'Not equal $typeValue');
    }

    return UpdatedEvent(
      transaction: json['transaction'],
      line: json['line'],
      callId: json['call_id'],
      jsep: json['jsep'] as Map<String, dynamic>?,
    );
  }
}
