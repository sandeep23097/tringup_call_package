import 'dart:async';
import 'tringup_call_status.dart';

/// Singleton broadcast stream of [TringupCallStatus] snapshots.
///
/// Feed it by wiring [TringupCallShell] as shown in section 3, then subscribe
/// anywhere in the host app without needing a [BuildContext].
///
/// ```dart
/// // Subscribe in a StatefulWidget or a GetX controller:
/// TringupCallStatusStream.instance
///     .forChatId(chatId)
///     .listen((status) { ... });
/// ```
class TringupCallStatusStream {
  TringupCallStatusStream._();
  static final TringupCallStatusStream instance = TringupCallStatusStream._();

  final _controller = StreamController<TringupCallStatus>.broadcast();

  // Latest snapshot per chatId — so new subscribers can read the current state
  // immediately without waiting for the next emission.
  final Map<String, TringupCallStatus> _latest = {};

  // ── Public API ─────────────────────────────────────────────────────────────

  /// All status changes from every call.
  Stream<TringupCallStatus> get all => _controller.stream;

  /// Changes for a specific chat thread.
  Stream<TringupCallStatus> forChatId(String chatId) =>
      _controller.stream.where((s) => s.chatId == chatId);

  /// Changes involving a specific remote phone number.
  Stream<TringupCallStatus> forUserId(String userId) =>
      _controller.stream.where((s) => s.remoteNumber == userId);

  /// The most-recently emitted status for [chatId], or `null` if no call has
  /// been made for that chat in the current app session.
  TringupCallStatus? latestForChatId(String chatId) => _latest[chatId];

  /// Whether a call is currently active for [chatId].
  bool isCallActive(String chatId) =>
      _latest[chatId]?.isActive ?? false;

  // ── Internal (called from TringupCallShell) ────────────────────────────────

  /// Push a new snapshot.  Called by the integration in [TringupCallShell].
  void push(TringupCallStatus status) {
    if (status.chatId.isNotEmpty) {
      _latest[status.chatId] = status;
    }
    if (!_controller.isClosed) _controller.add(status);
  }
}