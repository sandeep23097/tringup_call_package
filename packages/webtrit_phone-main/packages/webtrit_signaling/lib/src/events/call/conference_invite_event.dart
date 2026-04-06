import '../abstract_events.dart';

class ConferenceInviteEvent extends CallEvent {
  const ConferenceInviteEvent({
    super.transaction,
    required super.line,
    required super.callId,
    required this.roomId,
    required this.inviter,
    this.inviterDisplayName,
    this.livekitUrl,
    this.livekitToken,
    this.hasVideo = false,
    this.chatId,
    this.groupName,
    this.groupPhotoUrl,
    this.memberPhotoUrls,
  });

  final int roomId;
  final String inviter;
  final String? inviterDisplayName;
  final String? livekitUrl;
  final String? livekitToken;
  final bool hasVideo;
  final String? chatId;
  final String? groupName;
  final String? groupPhotoUrl;
  final Map<String, String>? memberPhotoUrls;

  static const typeValue = 'conference_invite';

  @override
  List<Object?> get props => [
        ...super.props,
        roomId,
        inviter,
        inviterDisplayName,
        livekitUrl,
        livekitToken,
        hasVideo,
        chatId,
        groupName,
        groupPhotoUrl,
        memberPhotoUrls,
      ];

  factory ConferenceInviteEvent.fromJson(Map<String, dynamic> json) {
    final rawMembers = json['member_photo_urls'];
    return ConferenceInviteEvent(
      transaction:      json['transaction'],
      line:             json['line'],
      callId:           json['call_id'],
      roomId:           json['room_id'] ?? 0,
      inviter:          json['inviter'],
      inviterDisplayName: json['inviter_display_name'],
      livekitUrl:       json['livekit_url'],
      livekitToken:     json['livekit_token'],
      hasVideo:         json['has_video'] == true || json['has_video'] == 'true',
      chatId:           json['chat_id'],
      groupName:        json['group_name'],
      groupPhotoUrl:    json['group_photo_url'],
      memberPhotoUrls:  rawMembers != null
          ? Map<String, String>.from(rawMembers as Map)
          : null,
    );
  }
}
