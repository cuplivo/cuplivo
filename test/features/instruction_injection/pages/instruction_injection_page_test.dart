import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/quick_instruction.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/instruction_injection_group_provider.dart';
import 'package:Cuplivo/core/providers/quick_instruction_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/quick_instruction_store.dart';
import 'package:Cuplivo/features/instruction_injection/pages/instruction_injection_page.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/shared/widgets/plain_text_code_editor.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('plus opens the three-way creation chooser', (tester) async {
    final harness = _buildHarness();
    await _pumpPage(tester, harness.app);
    final initialIds = harness.quickInstructions.items
        .map((item) => item.id)
        .toList(growable: false);

    await tester.tap(find.byIcon(Lucide.Plus));
    await tester.pumpAndSettle();

    expect(find.text('Create quick instruction'), findsOneWidget);
    expect(find.text('New instruction injection'), findsOneWidget);
    expect(find.text('New quick phrase'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);

    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(harness.quickInstructions.items.map((item) => item.id), initialIds);
  });

  testWidgets('instruction injection preset saves legacy-compatible defaults', (
    tester,
  ) async {
    final harness = _buildHarness();
    await _pumpPage(tester, harness.app);

    final item = await _createInstruction(
      tester,
      harness.quickInstructions,
      optionKey: 'quick-instruction-create-injection',
      title: 'System preset',
      prompt: 'System prompt',
      expectedGroup: QuickInstructionStore.instructionInjectionGroup,
    );

    expect(item.placement, QuickInstructionPlacement.systemPrompt);
    expect(item.toolPolicy.enabled, isFalse);
    expect(harness.quickInstructions.activeIds, isEmpty);
  });

  testWidgets('quick phrase preset saves legacy-compatible defaults', (
    tester,
  ) async {
    final harness = _buildHarness();
    await _pumpPage(tester, harness.app);

    final item = await _createInstruction(
      tester,
      harness.quickInstructions,
      optionKey: 'quick-instruction-create-phrase',
      title: 'Phrase preset',
      prompt: 'Phrase prompt',
      expectedGroup: QuickInstructionStore.migratedQuickPhraseGroup,
    );

    expect(item.placement, QuickInstructionPlacement.inputBox);
    expect(item.toolPolicy.enabled, isFalse);
  });

  testWidgets('custom preset keeps the normal quick-instruction defaults', (
    tester,
  ) async {
    final harness = _buildHarness();
    await _pumpPage(tester, harness.app);

    final item = await _createInstruction(
      tester,
      harness.quickInstructions,
      optionKey: 'quick-instruction-create-custom',
      title: 'Custom preset',
      prompt: 'Custom prompt',
      expectedGroup: '',
    );

    expect(item.placement, QuickInstructionPlacement.beforeUserMessage);
    expect(item.triggerMode, QuickInstructionTriggerMode.oneShot);
    expect(item.retainInHistory, isTrue);
    expect(item.toolPolicy.enabled, isFalse);
  });

  testWidgets('cancelling the editor creates no instruction', (tester) async {
    final harness = _buildHarness();
    await _pumpPage(tester, harness.app);
    final initialIds = harness.quickInstructions.items
        .map((item) => item.id)
        .toList(growable: false);

    await tester.tap(find.byIcon(Lucide.Plus));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('quick-instruction-create-custom')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(harness.quickInstructions.items.map((item) => item.id), initialIds);
  });

  testWidgets('desktop embedded page uses the same creation chooser', (
    tester,
  ) async {
    final harness = _buildHarness(embedded: true);
    await _pumpPage(tester, harness.app);

    await tester.tap(find.byIcon(Lucide.Plus));
    await tester.pumpAndSettle();

    expect(find.text('Create quick instruction'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('quick-instruction-create-injection')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('quick-instruction-create-phrase')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('quick-instruction-create-custom')),
      findsOneWidget,
    );
  });
}

Future<QuickInstruction> _createInstruction(
  WidgetTester tester,
  QuickInstructionProvider provider, {
  required String optionKey,
  required String title,
  required String prompt,
  required String expectedGroup,
}) async {
  await tester.tap(find.byIcon(Lucide.Plus));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(optionKey)));
  await tester.pumpAndSettle();

  final fields = find.byType(TextField);
  expect(fields, findsNWidgets(2));
  expect(
    tester.widget<TextField>(fields.at(1)).controller?.text,
    expectedGroup,
  );
  await tester.enterText(fields.at(0), title);
  final promptEditor = find.byType(PlainTextCodeEditor);
  expect(promptEditor, findsOneWidget);
  final promptController = tester
      .widget<PlainTextCodeEditor>(promptEditor)
      .controller;
  promptController.text = prompt;
  await tester.pump();
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();

  return provider.items.singleWhere((item) => item.title == title);
}

Future<void> _pumpPage(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

({Widget app, QuickInstructionProvider quickInstructions}) _buildHarness({
  bool embedded = false,
}) {
  final preferences = BusinessPreferences.memoryForTests();
  final settings = SettingsProvider(preferences: preferences);
  final quickInstructions = QuickInstructionProvider(preferences: preferences);
  final assistants = AssistantProvider(preferences: preferences);
  final groups = InstructionInjectionGroupProvider(preferences: preferences);

  return (
    quickInstructions: quickInstructions,
    app: MultiProvider(
      providers: [
        Provider<BusinessPreferences>.value(value: preferences),
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ChangeNotifierProvider<QuickInstructionProvider>.value(
          value: quickInstructions,
        ),
        ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
        ChangeNotifierProvider<InstructionInjectionGroupProvider>.value(
          value: groups,
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: InstructionInjectionPage(embedded: embedded),
      ),
    ),
  );
}
