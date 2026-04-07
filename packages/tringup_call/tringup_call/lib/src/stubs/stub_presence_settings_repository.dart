import 'package:webtrit_phone/repositories/presence/presence_settings_repository.dart';
import 'package:webtrit_phone/models/models.dart';

/// No-op presence settings repository.
/// Presence is disabled in the package (sipPresenceEnabled = false).
class StubPresenceSettingsRepository implements PresenceSettingsRepository {
  PresenceSettings _settings = PresenceSettings.blank(device: 'tringup_call');

  @override
  PresenceSettings get presenceSettings => _settings;

  @override
  void updatePresenceSettings(PresenceSettings settings) {
    _settings = settings;
  }

  @override
  DateTime? get lastSettingsSync => null;

  @override
  void updateLastSettingsSync(DateTime time) {}

  @override
  void resetLastSettingsSync() {}

  @override
  Future<void> clear() async {
    _settings = PresenceSettings.blank(device: 'tringup_call');
  }
}
