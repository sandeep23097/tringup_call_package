import 'package:flutter/material.dart';
import 'package:webtrit_phone/features/call/call.dart';
import 'package:webtrit_phone/theme/extension/gradients.dart';
import 'package:webtrit_phone/theme/styles/styles.dart';

/// Simple call-screen theme that the host app passes to [TringupCallConfig].
///
/// All fields are optional — omit any you want to keep at their default.
///
/// ```dart
/// TringupCallConfig(
///   ...
///   callTheme: TringupCallTheme(
///     backgroundColor: Color(0xFF1A1A2E),
///     primaryColor: Color(0xFF00BCD4),
///     hangupColor: Colors.redAccent,
///     textColor: Colors.white,
///     nameFontSize: 24,
///     statusFontSize: 14,
///   ),
/// )
/// ```
class TringupCallTheme {
  const TringupCallTheme({
    // Background
    this.backgroundColor,
    this.backgroundGradient,

    // Text colours
    this.textColor,
    this.subTextColor,

    // Font sizes
    this.nameFontSize,
    this.numberFontSize,
    this.statusFontSize,

    // App-bar (the thin bar at the top with the back button)
    this.appBarBackgroundColor,
    this.appBarForegroundColor,

    // Action buttons (mute, speaker, camera, hold…)
    this.actionActiveColor,
    this.actionInactiveColor,
    this.actionIconColor,

    // Primary action buttons
    this.hangupColor,
    this.answerColor,
  });

  // ── Background ─────────────────────────────────────────────────────────────

  /// Solid background colour. Overridden by [backgroundGradient] when set.
  final Color? backgroundColor;

  /// Gradient drawn behind the call UI (fills entire screen).
  /// When provided, [backgroundColor] is ignored.
  final Gradient? backgroundGradient;

  // ── Text ───────────────────────────────────────────────────────────────────

  /// Colour of the caller name / number text.
  final Color? textColor;

  /// Colour of secondary text (call status, processing status).
  final Color? subTextColor;

  /// Font size of the caller / callee name label.
  final double? nameFontSize;

  /// Font size of the phone-number label.
  final double? numberFontSize;

  /// Font size of the call status label (e.g. "Calling…", "00:42").
  final double? statusFontSize;

  // ── App bar ────────────────────────────────────────────────────────────────

  /// Background colour of the thin AppBar at the top of the call screen.
  /// Defaults to transparent.
  final Color? appBarBackgroundColor;

  /// Foreground (icon / back-arrow) colour on the AppBar.
  final Color? appBarForegroundColor;

  // ── Action buttons ─────────────────────────────────────────────────────────

  /// Background when a toggle button is active (e.g. mute is ON).
  final Color? actionActiveColor;

  /// Background when a toggle button is inactive (normal state).
  final Color? actionInactiveColor;

  /// Icon colour on action buttons.
  final Color? actionIconColor;

  // ── Primary buttons ────────────────────────────────────────────────────────

  /// Background colour of the hang-up button. Defaults to red.
  final Color? hangupColor;

  /// Background colour of the answer button. Defaults to green.
  final Color? answerColor;

  // ── Internal: build theme extensions ──────────────────────────────────────

  /// Wraps [child] in a [Theme] that injects [CallScreenStyles] and [Gradients]
  /// built from this theme object on top of the current ambient [ThemeData].
  Widget wrap(BuildContext context, Widget child) {
    final base = Theme.of(context);

    final gradient = backgroundGradient ??
        (backgroundColor != null
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [backgroundColor!, backgroundColor!],
              )
            : null);

    final tc = textColor ?? Colors.white;
    final stc = subTextColor ?? Colors.white70;

    ButtonStyle _actionStyle(Color? bg) => ButtonStyle(
          backgroundColor: bg != null ? WidgetStateProperty.all(bg) : null,
          foregroundColor: actionIconColor != null
              ? WidgetStateProperty.all(actionIconColor)
              : null,
        );

    final callScreenStyle = CallScreenStyle(
      appBar: AppBarStyle(
        backgroundColor: appBarBackgroundColor ?? Colors.transparent,
        foregroundColor: appBarForegroundColor ?? tc,
        primary: false,
        showBackButton: true,
      ),
      callInfo: CallInfoStyle(
        userInfo: TextStyle(
          color: tc,
          fontSize: nameFontSize,
          fontWeight: FontWeight.w600,
        ),
        number: TextStyle(
          color: tc.withOpacity(0.8),
          fontSize: numberFontSize,
        ),
        callStatus: TextStyle(
          color: stc,
          fontSize: statusFontSize,
        ),
        processingStatus: TextStyle(
          color: stc,
          fontSize: statusFontSize != null ? statusFontSize! - 2 : null,
        ),
      ),
      actions: CallScreenActionsStyle(
        hangup: hangupColor != null
            ? ButtonStyle(
                backgroundColor: WidgetStateProperty.all(hangupColor),
                foregroundColor: WidgetStateProperty.all(Colors.white),
              )
            : null,
        callStart: answerColor != null
            ? ButtonStyle(
                backgroundColor: WidgetStateProperty.all(answerColor),
                foregroundColor: WidgetStateProperty.all(Colors.white),
              )
            : null,
        muted: _actionStyle(actionInactiveColor),
        speaker: _actionStyle(actionInactiveColor),
        camera: _actionStyle(actionInactiveColor),
        held: _actionStyle(actionInactiveColor),
      ),
    );

    final extensions = <ThemeExtension<dynamic>>[
      CallScreenStyles(primary: callScreenStyle),
      if (gradient != null) Gradients(tab: gradient),
    ];

    return Theme(
      data: base.copyWith(extensions: extensions),
      child: child,
    );
  }
}
