import '../abstract_events.dart';

class ConferenceUpgradeEvent extends CallEvent {
  const ConferenceUpgradeEvent({
    super.transaction,
    required super.line,
    required super.callId,
    required this.roomId,
    this.livekitUrl,
    this.livekitToken,
    this.chatId,
    this.groupName,
    this.groupPhotoUrl,
    this.memberPhotoUrls,
  });

  final int roomId;
  final String? livekitUrl;
  final String? livekitToken;
  final String? chatId;
  final String? groupName;
  final String? groupPhotoUrl;
  final Map<String, String>? memberPhotoUrls;

  static const typeValue = 'conference_upgrade';

  @override
  List<Object?> get props => [
        ...super.props,
        roomId,
        livekitUrl,
        livekitToken,
        chatId,
        groupName,
        groupPhotoUrl,
        memberPhotoUrls,
      ];

  factory ConferenceUpgradeEvent.fromJson(Map<String, dynamic> json) {
    final rawMembers = json['member_photo_urls'];
    return ConferenceUpgradeEvent(
      transaction:      json['transaction'],
      line:             json['line'],
      callId:           json['call_id'],
      roomId:           json['room_id'] ?? 0,
      livekitUrl:       json['livekit_url'],
      livekitToken:     json['livekit_token'],
      chatId:           json['chat_id'],
      groupName:        json['group_name'],
      groupPhotoUrl:    json['group_photo_url'],
      memberPhotoUrls:  rawMembers != null
          ? Map<String, String>.from(rawMembers as Map)
          : null,
    );
  }
}
