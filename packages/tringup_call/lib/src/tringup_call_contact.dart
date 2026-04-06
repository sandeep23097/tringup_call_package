/// Identifies a participant in a call.
/// Carries both userId (chat DB primary key) and phoneNumber (routing key)
/// so resolvers can choose the most efficient lookup.
class TringupCallContact {
  const TringupCallContact({
    required this.userId,
    required this.phoneNumber,
  });

  /// The chat app's own user identifier (UUID or opaque string).
  final String userId;

  /// E.164 phone number used for routing the call.
  final String phoneNumber;

  @override
  String toString() => 'TringupCallContact(userId: $userId, phone: $phoneNumber)';
}
