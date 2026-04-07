import 'package:flutter/material.dart';
import 'package:webtrit_phone/l10n/app_localizations.g.dart';

/// Shared [GlobalKey] for the [OverlayState] that [TringupCallShell] inserts
/// call-UI entries into.
///
/// Place a `Positioned.fill(child: Overlay(key: TringupCallOverlay.key, initialEntries: const []))`
/// inside a [Stack] in your `MaterialApp.builder` so that call screens appear
/// over the entire app (including the navigator).
///
/// Also add [TringupCallOverlay.localizationsDelegates] to your
/// `MaterialApp.localizationsDelegates` so that webtrit_phone's call widgets
/// can resolve their localizations.
class TringupCallOverlay {
  TringupCallOverlay._();

  static final key = GlobalKey<OverlayState>();

  /// Localizations delegates required by the call UI widgets.
  /// Include these in your app's [MaterialApp.localizationsDelegates].
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = [
    AppLocalizations.delegate,
  ];
}
