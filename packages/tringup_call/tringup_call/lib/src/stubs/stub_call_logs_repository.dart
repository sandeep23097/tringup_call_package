import 'package:webtrit_phone/data/data.dart';
import 'package:webtrit_phone/mappers/mappers.dart';
import 'package:webtrit_phone/models/models.dart';
import 'package:webtrit_phone/repositories/call_logs/call_logs_repository.dart';

/// No-op call logs repository.
///
/// Call history is not required for basic calling. We use [implements] instead
/// of [extends] so we never have to call [CallLogsRepository]'s constructor
/// (which requires a non-nullable [AppDatabase]). Dart's sound null-safety
/// rejects the old `null as dynamic` cast at runtime.
class StubCallLogsRepository implements CallLogsRepository {
  @override
  Stream<List<CallLogEntry>> watchHistoryByNumber(String number) =>
      Stream.value([]);

  @override
  Future<void> add(NewCall call) async {}

  @override
  Future<void> deleteById(int id) async {}

  /// Part of the [CallLogsDriftMapper] interface — never called because
  /// [watchHistoryByNumber] above returns an empty stream directly.
  @override
  CallLogEntry callLogEntryFromDrift(CallLogData callLogData) {
    throw UnimplementedError('StubCallLogsRepository.callLogEntryFromDrift');
  }
}
