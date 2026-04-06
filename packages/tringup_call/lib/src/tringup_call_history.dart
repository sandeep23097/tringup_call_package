import 'package:flutter/foundation.dart';
import 'package:webtrit_api/webtrit_api.dart' hide CdrRecord;
import 'package:webtrit_phone/app/session/empty_session_guard.dart';
import 'package:webtrit_phone/common/isolate_database.dart';
import 'package:webtrit_phone/models/models.dart';
import 'package:webtrit_phone/repositories/cdrs/cdrs_local_repository.dart';
import 'package:webtrit_phone/repositories/cdrs/cdrs_remote_repository.dart';

export 'package:webtrit_phone/models/call_direction.dart';
export 'package:webtrit_phone/models/cdr.dart';
export 'package:webtrit_phone/repositories/cdrs/cdrs_local_repository.dart'
    show CdrsLocalRepository;

/// Cache TTL — only fetch from remote if local data is older than this.
const _kCacheTtl = Duration(minutes: 15);

/// Provides access to Call Detail Records (CDRs), with a local SQLite cache.
///
/// On first call, remote CDRs are fetched and stored locally. Subsequent calls
/// within [_kCacheTtl] are served from the local DB (fast, offline-capable).
///
/// The instance is kept up-to-date by [TringupCallGetxController] whenever
/// the token changes. Always obtain it via [TringupCallGetxController.history].
class TringupCallHistory {
  TringupCallHistory._({required this.serverUrl, required this.tenantId, required String token})
      : _remote = CdrsRemoteRepositoryApiImpl(
          WebtritApiClient(Uri.parse(serverUrl), tenantId),
          token,
          const EmptySessionGuard(),
        );

  /// Creates a ready-to-use instance. Called internally by [TringupCallGetxController].
  factory TringupCallHistory.create({
    required String serverUrl,
    required String tenantId,
    required String token,
  }) =>
      TringupCallHistory._(serverUrl: serverUrl, tenantId: tenantId, token: token);

  final String serverUrl;
  final String tenantId;
  final CdrsRemoteRepositoryApiImpl _remote;

  // Shared across all instances — only one DB connection is needed.
  static Future<CdrsLocalRepository?>? _localRepoFuture;

  static Future<CdrsLocalRepository?> _getLocalRepo() {
    _localRepoFuture ??= _initLocalRepo();
    return _localRepoFuture!;
  }

  static Future<CdrsLocalRepository?> _initLocalRepo() async {
    try {
      final db = await IsolateDatabase.create();
      return CdrsLocalRepositoryDriftImpl(db);
    } catch (e) {
      debugPrint('[TringupCallHistory] Local DB init failed: $e');
      return null;
    }
  }

  /// Fetches CDRs — local cache first, remote when stale or empty.
  ///
  /// - [from] / [to] — optional date-range filter (UTC).
  /// - [limit]        — max records to return (server default if null).
  /// - [forceRemote]  — skip cache and always fetch from server.
  ///
  /// Returns an empty list on network failure (error is debug-printed).
  Future<List<CdrRecord>> fetchHistory({
    DateTime? from,
    DateTime? to,
    int? limit,
    bool forceRemote = false,
  }) async {
    final local = await _getLocalRepo();

    if (local != null && !forceRemote) {
      final lastUpdate = await local.getLastUpdate();
      final cacheValid = lastUpdate != null &&
          DateTime.now().toUtc().difference(lastUpdate) < _kCacheTtl;

      if (cacheValid) {
        final cached = await local.getHistory(from: from, to: to, limit: limit);
        if (cached.isNotEmpty) {
          debugPrint('[TringupCallHistory] Returning ${cached.length} CDRs from local cache');
          return cached;
        }
      }
    }

    // Fetch from remote
    try {
      final records = await _remote.getHistory(from: from, to: to, limit: limit);
      debugPrint('[TringupCallHistory] Fetched ${records.length} CDRs from remote');

      if (local != null && records.isNotEmpty) {
        await local.upsertCdrs(records, silent: true);
        debugPrint('[TringupCallHistory] Upserted ${records.length} CDRs to local DB');
      }

      return records;
    } catch (e,st) {
      debugPrintStack(stackTrace: st);
      debugPrint('[TringupCallHistory] Remote fetch failed: $e');

      // Fallback to local even if stale
      if (local != null) {
        final cached = await local.getHistory(from: from, to: to, limit: limit);
        if (cached.isNotEmpty) {
          debugPrint('[TringupCallHistory] Remote failed — returning ${cached.length} stale CDRs from cache');
          return cached;
        }
      }

      rethrow;
    }
  }
}
