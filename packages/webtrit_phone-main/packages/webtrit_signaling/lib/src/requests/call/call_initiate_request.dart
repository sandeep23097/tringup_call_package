import '../abstract_requests.dart';

/// Initiate a call to one or more participants.
/// Replaces outgoing_call for all call types.
class CallInitiateRequest extends SessionRequest {
  const CallInitiateRequest({
    required super.transaction,
    required this.callId,
    required this.numbers,
    this.line,
    this.from,
    this.hasVideo,
    this.groupName,
    this.chatId,
  });

  final String callId;

  /// Phone numbers of all intended callees.
  final List<String> numbers;

  final int? line;

  /// Caller's own phone number override.
  final String? from;

  final bool? hasVideo;

  /// Group name shown on each callee's incoming call screen.
  final String? groupName;

  /// Host-app chat thread ID forwarded to all callees for CDR linking.
  final String? chatId;

  static const typeValue = 'call_initiate';

  @override
  List<Object?> get props => [...super.props, callId, numbers, line, from, hasVideo, groupName, chatId];

  @override
  Map<String, dynamic> toJson() => {
    Request.typeKey: typeValue,
    'transaction':   transaction,
    'call_id':       callId,
    'numbers':       numbers,
    if (line != null)      'line':       line,
    if (from != null)      'from':       from,
    if (hasVideo != null)  'has_video':  hasVideo,
    if (groupName != null) 'group_name': groupName,
    if (chatId != null)    'chat_id':    chatId,
  };
}
