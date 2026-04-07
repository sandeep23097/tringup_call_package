import 'dart:async';
import 'package:webtrit_phone/repositories/auth/session_repository.dart';
import 'package:webtrit_phone/models/models.dart';

/// No-op session repository for the package context.
/// The chat app manages its own session; the call package is always "signed in"
/// because it receives a pre-issued JWT from the chat backend.
class StubSessionRepository implements SessionRepository {
  final _controller = StreamController<Session?>.broadcast();

  @override
  bool get isSignedIn => true;

  @override
  Stream<Session?> watch() => _controller.stream;

  @override
  Future<void> reload() async {}

  @override
  Future<void> save(Session session) async {}

  @override
  Session? getCurrent() => null;

  @override
  Future<void> logout() async {}

  @override
  Future<void> clean() async {}
}
