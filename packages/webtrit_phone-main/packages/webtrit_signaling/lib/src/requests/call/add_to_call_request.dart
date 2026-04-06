import '../abstract_requests.dart';

class AddToCallRequest extends SessionRequest {
  const AddToCallRequest({
    required super.transaction,
    required this.callId,
    required this.number,
    this.chatId,
    this.groupName,
    this.groupPhotoUrl,
    this.memberPhotoUrls,
  });

  final String callId;
  final String number;
  final String? chatId;
  final String? groupName;
  final String? groupPhotoUrl;
  final Map<String, String>? memberPhotoUrls;

  static const typeValue = 'add_to_call';

  @override
  List<Object?> get props => [...super.props, callId, number, chatId, groupName, groupPhotoUrl, memberPhotoUrls];

  @override
  Map<String, dynamic> toJson() {
    return {
      Request.typeKey: typeValue,
      'transaction': transaction,
      'call_id': callId,
      'number': number,
      if (chatId != null) 'chat_id': chatId,
      if (groupName != null) 'group_name': groupName,
      if (groupPhotoUrl != null) 'group_photo_url': groupPhotoUrl,
      if (memberPhotoUrls != null) 'member_photo_urls': memberPhotoUrls,
    };
  }
}
