import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

import '../../../support/business_test_harness.dart';

/// Builds the tree a DSH picker is opened from.
///
/// The pickers themselves read no providers, but their rows and tiles are the
/// shared `IosCardPress`, which reads the "haptic on card tap" preference from
/// [SettingsProvider]. Mounting the provider above the `MaterialApp` (and
/// therefore above the navigator) keeps it visible inside the modal sheet route
/// the pickers open. It is backed by the in-memory business preferences harness,
/// so the tests stay hermetic.
Future<Widget> buildDshPickerTestApp({required Widget home}) async {
  final settings = SettingsProvider(createBusinessTestPreferences());
  await settings.loaded;
  return ChangeNotifierProvider<SettingsProvider>.value(
    value: settings,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
}
