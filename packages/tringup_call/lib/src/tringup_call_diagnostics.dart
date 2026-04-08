import 'package:flutter/foundation.dart';

/// Snapshot of the call subsystem's current connectivity/health state.
///
/// All fields are safe to read from any isolate. Updated by
/// [TringupCallShell] (signaling + registration) and [TringupCallWidget]
/// (token presence) whenever the underlying [CallBloc] state changes.
class TringupCallDiagnosticsStatus {
  const TringupCallDiagnosticsStatus({
    this.isSignalingConnected = false,
    this.isUserRegistered = false,
    this.signalingStatusLabel = 'disconnected',
    this.registrationStatusLabel = '—',
    this.callTokenPresent = false,
  });

  /// WebSocket to the call backend is fully established.
  final bool isSignalingConnected;

  /// Handshake completed and this device's phone number is registered
  /// on the signaling server.
  final bool isUserRegistered;

  /// Human-readable WebSocket status:
  /// "connected" | "connecting" | "disconnecting" | "disconnected" | "failed"
  final String signalingStatusLabel;

  /// Human-readable SIP/signaling registration status:
  /// "registered" | "registering" | "unregistered" | "unregistering" | "failed" | "—"
  final String registrationStatusLabel;

  /// Whether a non-empty call JWT is currently loaded in [TringupCallWidget].
  /// False means no user is logged in or token fetch failed.
  final bool callTokenPresent;

  TringupCallDiagnosticsStatus copyWith({
    bool? isSignalingConnected,
    bool? isUserRegistered,
    String? signalingStatusLabel,
    String? registrationStatusLabel,
    bool? callTokenPresent,
  }) =>
      TringupCallDiagnosticsStatus(
        isSignalingConnected:
            isSignalingConnected ?? this.isSignalingConnected,
        isUserRegistered: isUserRegistered ?? this.isUserRegistered,
        signalingStatusLabel:
            signalingStatusLabel ?? this.signalingStatusLabel,
        registrationStatusLabel:
            registrationStatusLabel ?? this.registrationStatusLabel,
        callTokenPresent: callTokenPresent ?? this.callTokenPresent,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TringupCallDiagnosticsStatus &&
          other.isSignalingConnected == isSignalingConnected &&
          other.isUserRegistered == isUserRegistered &&
          other.signalingStatusLabel == signalingStatusLabel &&
          other.registrationStatusLabel == registrationStatusLabel &&
          other.callTokenPresent == callTokenPresent;

  @override
  int get hashCode => Object.hash(
        isSignalingConnected,
        isUserRegistered,
        signalingStatusLabel,
        registrationStatusLabel,
        callTokenPresent,
      );
}

/// Singleton that exposes live call diagnostics to the host app.
///
/// Updated internally by [TringupCallShell] and [TringupCallWidget].
/// Host apps should treat this as **read-only**.
///
/// Example — reactive widget:
/// ```dart
/// ValueListenableBuilder<TringupCallDiagnosticsStatus>(
///   valueListenable: TringupCallDiagnostics.instance.statusNotifier,
///   builder: (context, status, _) => Text(
///     'Signaling: ${status.signalingStatusLabel}\n'
///     'Registered: ${status.isUserRegistered}',
///   ),
/// )
/// ```
///
/// Example — one-shot read:
/// ```dart
/// final s = TringupCallDiagnostics.instance.status;
/// print(s.signalingStatusLabel);
/// ```
class TringupCallDiagnostics {
  TringupCallDiagnostics._();

  static final TringupCallDiagnostics instance = TringupCallDiagnostics._();

  /// Reactive notifier — listen to get updates every time state changes.
  final ValueNotifier<TringupCallDiagnosticsStatus> statusNotifier =
      ValueNotifier(const TringupCallDiagnosticsStatus());

  /// Latest snapshot — safe for synchronous reads.
  TringupCallDiagnosticsStatus get status => statusNotifier.value;

  /// Called by [TringupCallShell] on every [CallBloc] state change.
  /// Do not call from host-app code.
  void updateFromShell(TringupCallDiagnosticsStatus newStatus) {
    if (statusNotifier.value != newStatus) {
      statusNotifier.value = newStatus;
    }
  }

  /// Called by [TringupCallWidget] when the call token changes.
  /// Do not call from host-app code.
  void updateTokenPresence(bool present) {
    if (statusNotifier.value.callTokenPresent != present) {
      statusNotifier.value =
          statusNotifier.value.copyWith(callTokenPresent: present);
    }
  }
}
