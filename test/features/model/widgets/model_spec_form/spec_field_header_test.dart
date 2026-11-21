import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/model_spec/model_spec_resolver.dart';
import 'package:Cuplivo/features/model/widgets/model_spec_form/spec_field_header.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

/// The capsule next to a field header exists to say where a value came from.
/// A field the resolver does not own has no such answer, and a made-up one is
/// worse than none.
void main() {
  Widget host(Widget child) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );

  testWidgets('a field with no resolved source shows no capsule', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const SpecFieldHeader(label: 'Decision URL', overridden: false)),
    );

    expect(find.byKey(const ValueKey('spec-source-capsule')), findsNothing);
    expect(find.text('Decision URL'), findsOneWidget);
  });

  testWidgets('a resolved source still shows its capsule', (tester) async {
    await tester.pumpWidget(
      host(
        const SpecFieldHeader(
          label: 'Temperature',
          source: SpecSource.override,
          overridden: false,
        ),
      ),
    );

    expect(find.byKey(const ValueKey('spec-source-capsule')), findsOneWidget);
  });
}
