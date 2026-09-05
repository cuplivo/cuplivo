import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/memory_provider.dart';
import 'package:Cuplivo/core/providers/quick_instruction_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/tts/tts_playback_models.dart';
import 'package:Cuplivo/features/assistant/pages/assistant_settings_edit_page.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:Cuplivo/shared/widgets/ios_switch.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

const _assistantId = 'assistant-time-test';

class _FakeTtsProvider extends ChangeNotifier implements TtsProvider {
  @override
  TtsPlaybackState get playbackState => const TtsPlaybackState();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubChatService extends ChatService {
  @override
  bool get initialized => true;

  @override
  List<Conversation> getConversationsWithSummaryForAssistant(String id) => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _seedPreferences({String systemPrompt = ''}) {
  SharedPreferences.setMockInitialValues({
    'assistants_v1': Assistant.encodeList([
      Assistant(
        id: _assistantId,
        name: 'Test Assistant',
        temperature: 0.6,
        systemPrompt: systemPrompt,
      ),
    ]),
  });
  businessPrefs = BusinessPreferences.memoryForTests();
}

Future<AssistantProvider> _createAssistantProvider({
  required BusinessPreferences preferences,
}) async {
  final provider = AssistantProvider(preferences: preferences);
  await provider.loadFromPrefs();
  return provider;
}

Widget _buildHarness({
  required AssistantProvider assistantProvider,
  required Widget child,
}) {
  return MultiProvider(
    providers: [
      Provider<BusinessPreferences>.value(value: businessPrefs),
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(preferences: businessPrefs),
      ),
      ChangeNotifierProvider(
        create: (_) => UserProvider(preferences: businessPrefs),
      ),
      ChangeNotifierProvider<TtsProvider>(create: (_) => _FakeTtsProvider()),
      Provider<ChatService>(create: (_) => _StubChatService()),
      ChangeNotifierProvider.value(value: assistantProvider),
      ChangeNotifierProvider(
        create: (_) => MemoryProvider(preferences: businessPrefs),
      ),
      ChangeNotifierProvider(
        create: (_) => QuickInstructionProvider(preferences: businessPrefs),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}

Future<void> _openPromptsTab(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 2800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    _buildHarness(
      assistantProvider: await _createAssistantProvider(
        preferences: businessPrefs,
      ),
      child: const AssistantSettingsEditPage(assistantId: _assistantId),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text('Prompts'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _settleTabSwitch(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 600));
}

Finder get _warningIcons =>
    find.byWidgetPredicate((w) => w is Icon && w.icon == Lucide.TriangleAlert);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'volatile variables get a warning badge in the system prompt list',
    (tester) async {
      _seedPreferences();
      await _openPromptsTab(tester);

      expect(_warningIcons, findsNWidgets(4));
    },
  );

  testWidgets('warning banner appears while system prompt contains time vars', (
    tester,
  ) async {
    _seedPreferences(systemPrompt: 'The time is {cur_datetime}.');
    await _openPromptsTab(tester);

    expect(find.textContaining('prompt caching cannot hit'), findsOneWidget);
  });

  testWidgets('no warning banner without volatile vars', (tester) async {
    _seedPreferences();
    await _openPromptsTab(tester);

    expect(find.textContaining('prompt caching cannot hit'), findsNothing);
  });

  testWidgets('memory tab badges the time memory variables', (tester) async {
    _seedPreferences();
    await _openPromptsTab(tester);

    await tester.tap(find.text('Memory'));
    await _settleTabSwitch(tester);

    expect(_warningIcons, findsNWidgets(3));
  });

  testWidgets('enable gate: Enable anyway turns the switch on', (tester) async {
    _seedPreferences(systemPrompt: 'Time: {cur_datetime}');
    await _openPromptsTab(tester);

    await tester.tap(find.byType(IosSwitch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('System prompt contains time variables'), findsOneWidget);

    await tester.tap(find.text('Enable anyway'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('System prompt contains time variables'), findsNothing);
    expect(tester.widget<IosSwitch>(find.byType(IosSwitch)).value, isTrue);
  });

  testWidgets('enable gate: Go remove keeps the switch off', (tester) async {
    _seedPreferences(systemPrompt: 'Time: {cur_datetime}');
    await _openPromptsTab(tester);

    await tester.tap(find.byType(IosSwitch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Go remove'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('System prompt contains time variables'), findsNothing);
    expect(tester.widget<IosSwitch>(find.byType(IosSwitch)).value, isFalse);
  });

  testWidgets('info dialog shows the appended time format', (tester) async {
    _seedPreferences();
    await _openPromptsTab(tester);

    await tester.tap(find.byIcon(Lucide.BadgeInfo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Appended time format'), findsOneWidget);
    expect(find.textContaining('(Mon 26-08-08 14:30:05)'), findsOneWidget);
  });
}
