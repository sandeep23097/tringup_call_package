import '../abstract_events.dart';

class IceTrickleEvent extends LineEvent {
  const IceTrickleEvent({super.transaction, required super.line, this.callId, this.feedId, required this.candidate});

  /// The call ID, sent by the backend in `ice_trickle` messages.
  /// Used to buffer candidates before the call is registered in the state by line.
  final String? callId;

  /// When set, this candidate is for a VideoRoom subscriber PC (not the publisher PC).
  /// The value is the Janus feedId of the publisher whose stream is being subscribed to.
  final int? feedId;

  final Map<String, dynamic>? candidate;

  @override
  List<Object?> get props => [...super.props, callId, feedId, candidate];

  static const typeValue = 'ice_trickle';

  factory IceTrickleEvent.fromJson(Map<String, dynamic> json) {
    final eventTypeValue = json[Event.typeKey];
    if (eventTypeValue != typeValue) {
      throw ArgumentError.value(eventTypeValue, Event.typeKey, 'Not equal $typeValue');
    }

    final candidateRaw = json['candidate'];
    // null or {completed:true} both mean ICE gathering is done — no candidate.
    if (candidateRaw == null ||
        (candidateRaw is Map && candidateRaw['completed'] == true)) {
      return IceTrickleEvent(
        transaction: json['transaction'],
        line: json['line'],
        callId: json['call_id'] as String?,
        feedId: json['feed_id'] as int?,
        candidate: null,
      );
    }
    return IceTrickleEvent(
      transaction: json['transaction'],
      line: json['line'],
      callId: json['call_id'] as String?,
      feedId: json['feed_id'] as int?,
      candidate: Map<String, dynamic>.from(candidateRaw as Map),
    );
  }
}
