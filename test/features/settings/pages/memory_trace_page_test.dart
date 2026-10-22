import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/memory/memory_trace.dart';
import 'package:Cuplivo/features/settings/pages/memory_trace_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

import '../../../support/business_test_harness.dart';

void main() {
  setUp(() {
    MemoryTraceRecorder.instance
      ..setEnabled(true)
      ..clear();
  });

  tearDown(() {
    MemoryTraceRecorder.instance
      ..setEnabled(true)
      ..clear();
  });

  Future<Widget> buildPage() async {
    final harness = await createBusinessTestHarness();
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(harness.preferences),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const MemoryTracePage(),
      ),
    );
  }

  void seedTrace() {
    final handle = MemoryTraceRecorder.instance.begin(
      trigger: MemoryTraceTrigger.manual,
      scope: MemoryTraceScope.global,
      conversationId: 'c1',
      conversationTitle: 'Trace demo chat',
      assistantId: 'a1',
      assistantName: 'Nova',
    )!;
    handle.setWindow(watermark: -1, startOrder: 0, endOrder: 3, size: 4);
    final step = handle.beginStep(MemoryTraceStepKind.gatekeeper)!;
    step.appendPrompt('GATE PROMPT BODY');
    step.appendResponse('<user_memory>true</user_memory>');
    step.parsedResult = 'worthRemembering';
    step.addMutation(
      const MemoryTraceMutation(
        kind: MemoryTraceMutationKind.memoryCreated,
        targetId: 'mem_1234',
        after: 'The user prefers concise answers.',
      ),
    );
    step.finish(MemoryTraceStepStatus.success);
    handle.commit(advanced: true);
  }

  testWidgets('lists traces and opens the step detail', (tester) async {
    seedTrace();
    await tester.pumpWidget(await buildPage());
    await tester.pumpAndSettle();

    expect(find.text('Trace demo chat'), findsOneWidget);
    expect(find.text('Watermark advanced'), findsWidgets);

    await tester.tap(find.text('Trace demo chat'));
    await tester.pumpAndSettle();

    expect(find.text('Trace detail'), findsOneWidget);
    expect(find.text('Gatekeeper'), findsOneWidget);
    expect(find.text('GATE PROMPT BODY'), findsOneWidget);
    expect(find.text('<user_memory>true</user_memory>'), findsOneWidget);
    expect(find.text('The user prefers concise answers.'), findsOneWidget);
  });

  testWidgets('shows the disabled state when the toggle is off', (
    tester,
  ) async {
    seedTrace();
    await tester.pumpWidget(await buildPage());
    await tester.pumpAndSettle();

    final settings = tester
        .element(find.byType(MemoryTraceContent))
        .read<SettingsProvider>();
    await settings.setMemoryTraceEnabled(false);
    await tester.pumpAndSettle();

    expect(find.text('Recording is off'), findsOneWidget);
    expect(find.text('Trace demo chat'), findsNothing);
  });
}
