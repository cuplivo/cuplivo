import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/assistant/pages/subagent_delegation_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

const _idTranslator = 'assistant-a';
const _idResearcher = 'assistant-b';
const _idCoder = 'assistant-c';
const _idWriter = 'assistant-d';

void _seedPrefs(List<Assistant> assistants) {
  SharedPreferences.setMockInitialValues({
    'assistants_v1': Assistant.encodeList(assistants),
  });
  businessPrefs = BusinessPreferences.memoryForTests();
}

Future<AssistantProvider> _createProvider() async {
  final provider = AssistantProvider(preferences: businessPrefs);
  await provider.loadFromPrefs();
  return provider;
}

Widget _harness(AssistantProvider provider, {required Widget child}) {
  return MultiProvider(
    providers: [
      Provider<BusinessPreferences>.value(value: businessPrefs),
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(preferences: businessPrefs),
      ),
      ChangeNotifierProvider.value(value: provider),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}

List<Assistant> _assistants() => [
  Assistant(
    id: _idTranslator,
    name: 'Translator',
    discoverable: true,
    handoffId: 'translator',
    handoffDescription: 'zh-en translation',
  ),
  Assistant(
    id: _idResearcher,
    name: 'Researcher',
    discoverable: true,
    handoffId: 'researcher',
    handoffDescription: 'web research',
  ),
  Assistant(id: _idCoder, name: 'Coder', discoverable: true, handoffId: ''),
  Assistant(
    id: _idWriter,
    name: 'Writer',
    discoverable: false,
    handoffId: 'writer2',
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('page renders delegatable and unconfigured sections', (
    tester,
  ) async {
    _seedPrefs(_assistants());
    final provider = await _createProvider();

    await tester.pumpWidget(
      _harness(provider, child: const SubagentDelegationPage()),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final l10n = AppLocalizations.of(
      tester.element(find.byType(SubagentDelegationPage)),
    )!;

    expect(find.text(l10n.subagentPageTitle), findsOneWidget);
    expect(find.text('Delegatable'), findsOneWidget);
    expect(find.text('Not configured'), findsOneWidget);
    expect(find.text('(2)'), findsNWidgets(2));

    expect(find.text('translator'), findsOneWidget);
    expect(find.text('researcher'), findsOneWidget);
    expect(find.text('zh-en translation'), findsOneWidget);
    expect(find.text(l10n.subagentReasonNoId), findsOneWidget);
    expect(find.text(l10n.subagentReasonNotDiscoverable), findsOneWidget);
    expect(find.text(l10n.subagentTargetStatus(2)), findsOneWidget);
  });

  testWidgets('duplicate id conflict badges both assistants', (tester) async {
    _seedPrefs([
      Assistant(
        id: _idTranslator,
        name: 'Translator',
        discoverable: true,
        handoffId: 'twin-bot',
      ),
      Assistant(
        id: _idResearcher,
        name: 'Researcher',
        discoverable: true,
        handoffId: 'twin-bot',
      ),
    ]);
    final provider = await _createProvider();

    await tester.pumpWidget(
      _harness(provider, child: const SubagentDelegationPage()),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('ID conflict'), findsNWidgets(2));
    expect(find.text('Delegatable'), findsOneWidget);
    expect(find.text('(2)'), findsOneWidget);
  });

  testWidgets('editor validates duplicate id and blocks save', (tester) async {
    _seedPrefs(_assistants());
    final provider = await _createProvider();

    await tester.pumpWidget(
      _harness(provider, child: const SubagentDelegationPage()),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Coder'));
    await tester.pump(const Duration(milliseconds: 300));

    final l10n = AppLocalizations.of(
      tester.element(find.byType(SubagentDelegationPage)),
    )!;
    expect(find.text(l10n.quickPhraseSaveButton), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'translator');
    await tester.pump();

    expect(find.text(l10n.assistantEditHandoffIdUnique), findsOneWidget);

    final save = find.text(l10n.quickPhraseSaveButton);
    await tester.ensureVisible(save);
    await tester.pump();
    await tester.tap(save);
    await tester.pump(const Duration(milliseconds: 300));

    // Save blocked: sheet stays open, no duplicate persisted.
    expect(find.text(l10n.quickPhraseSaveButton), findsOneWidget);
    expect(provider.getById(_idCoder)!.handoffId, isEmpty);
  });

  testWidgets('editor valid save moves row into delegatable section', (
    tester,
  ) async {
    _seedPrefs(_assistants());
    final provider = await _createProvider();

    await tester.pumpWidget(
      _harness(provider, child: const SubagentDelegationPage()),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Coder'));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextField).first, 'coder-101');
    await tester.pump();
    final save = find.text('Save');
    await tester.ensureVisible(save);
    await tester.pump();
    await tester.tap(save);
    await tester.pump(const Duration(milliseconds: 300));

    expect(provider.getById(_idCoder)!.handoffId, 'coder-101');
    expect(find.text('Save'), findsNothing);
    expect(find.text('coder-101'), findsOneWidget);
    expect(find.text('Delegatable'), findsOneWidget);
    expect(find.text('(3)'), findsOneWidget);
    expect(
      find.text(
        AppLocalizations.of(
          tester.element(find.byType(SubagentDelegationPage)),
        )!.subagentReasonNoId,
      ),
      findsNothing,
    );
  });

  testWidgets('editor closes safely when assistant is deleted mid-edit', (
    tester,
  ) async {
    _seedPrefs(_assistants());
    final provider = await _createProvider();

    await tester.pumpWidget(
      _harness(provider, child: const SubagentDelegationPage()),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Translator'));
    await tester.pump(const Duration(milliseconds: 300));

    await provider.deleteAssistant(_idTranslator);
    await tester.pump(const Duration(milliseconds: 300));

    final save = find.text('Save');
    await tester.ensureVisible(save);
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();

    // No crash: vanished target closes the editor.
    expect(find.text('Save'), findsNothing);
  });
}
