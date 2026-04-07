import 'package:webtrit_phone/repositories/presence/presence_info_repository.dart';
import 'package:webtrit_phone/models/models.dart';

/// No-op presence info repository.
/// Presence is disabled in the package (sipPresenceEnabled = false).
class StubPresenceInfoRepository implements PresenceInfoRepository {
  @override
  void setNumberPresence(String number, List<PresenceInfo> presenceInfo) {}

  @override
  Future<List<PresenceInfo>> getNumberPresence(String number) async => [];

  @override
  Stream<List<PresenceInfo>> watchNumberPresence(String number) => const Stream.empty();
}
