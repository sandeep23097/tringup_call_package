import 'package:equatable/equatable.dart';

class ConferenceParticipant extends Equatable {
  const ConferenceParticipant({
    required this.userId,
    this.displayName,
    this.phoneNumber,
  });

  final String userId;
  final String? displayName;
  /// Always the E.164 phone number regardless of whether userId is a phone
  /// number or a server-assigned identity (user_XXXX).  Used for
  /// cross-namespace matching in the group-members panel.
  final String? phoneNumber;

  @override
  List<Object?> get props => [userId, displayName, phoneNumber];
}
