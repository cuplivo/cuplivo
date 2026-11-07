// A phone 1:1 composer can run out of room in its left action bar. The bar then
// unfolds what did not fit behind a button of its own — which must not be the
// tools panel's "+": both are drawn in the same row, so a second button wearing
// `chatInputBarMoreTooltip` and `Lucide.Plus` reads as one control drawn twice.
//
// Widths below are the real bar in a 1:1 chat with the reasoning badge on, a
// tool-capable model and one quick phrase: a 30dp model button, 32dp buttons
// around a 60dp reasoning button, 8dp gaps, and whatever the panel "+", the mic
// and Send leave over. At 320dp the five actions span 218dp against a 206dp bar;
// at 360dp they span 238dp against 246dp.
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/model_spec.dart';
import 'package:Cuplivo/core/models/quick_phrase.dart';
import 'package:Cuplivo/core/models/reasoning_request.dart';
import 'package:Cuplivo/core/providers/asr_provider.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/instruction_injection_provider.dart';
import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/providers/quick_phrase_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/world_book_provider.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_section.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

typedef _Fixtures = ({
  AssistantProvider assistants,
  QuickPhraseProvider quickPhrases,
  SettingsProvider settings,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BusinessPreferences preferences;

  setUp(() {
    preferences = createBusinessTestPreferences();
  });

  /// Every drift read/write happens here, inside `runAsync`: a widget test's
  /// fake clock never advances the database futures. The settings provider is
  /// built here for the same reason and awaited, so the badge below is already
  /// part of the first frame — a provider built inside the tree only reaches its
  /// seeded state after the assertion has run.
  Future<_Fixtures> loadFixtures(WidgetTester tester) async {
    late AssistantProvider assistants;
    late SettingsProvider settings;
    final quickPhrases = QuickPhraseProvider(preferences: preferences);
    await tester.runAsync(() async {
      await preferences.setString(
        'assistants_v1',
        Assistant.encodeList([
          Assistant(
            id: 'a1',
            name: 'Alice',
            // A pinned level, not `auto`: the composer then draws the badge
            // label beside the brain, which widens that button to 60dp.
            reasoning: const ReasoningRequest(ReasoningLevel.high),
          ),
        ]),
      );
      await preferences.setString('current_assistant_id_v1', 'a1');
      await preferences.setBool('display_show_reasoning_level_badge_v1', true);
      settings = SettingsProvider(preferences);
      await settings.loaded;
      assistants = AssistantProvider(preferences: preferences);
      await assistants.loaded;
      await quickPhrases.initialize();
      await quickPhrases.add(
        const QuickPhrase(id: 'q1', title: 'Hello', content: 'Hello'),
      );
    });
    return (
      assistants: assistants,
      quickPhrases: quickPhrases,
      settings: settings,
    );
  }

  Future<void> pumpOneToOne(
    WidgetTester tester, {
    required _Fixtures fixtures,
    required double width,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<BusinessPreferences>.value(value: preferences),
          ChangeNotifierProvider.value(value: fixtures.settings),
          ChangeNotifierProvider.value(value: fixtures.assistants),
          ChangeNotifierProvider(create: (_) => AsrProvider()),
          ChangeNotifierProvider(
            create: (_) => WorldBookProvider(preferences: preferences),
          ),
          ChangeNotifierProvider(
            create: (_) =>
                InstructionInjectionProvider(preferences: preferences),
          ),
          ChangeNotifierProvider(
            create: (_) => McpProvider(preferences: preferences),
          ),
          ChangeNotifierProvider.value(value: fixtures.quickPhrases),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: width,
                child: ChatInputSection(
                  inputBarKey: GlobalKey(),
                  chatModelProviderKey: 'P',
                  chatModelId: 'M',
                  inputFocus: focus,
                  inputController: controller,
                  mediaController: ChatInputBarController(),
                  isTablet: false,
                  isLoading: false,
                  isToolModel: (_, _) => true,
                  isReasoningModel: (_, _) => true,
                  isReasoningEnabled: (_) => true,
                  conversationId: 'c1',
                  onOpenSearch: () {},
                  onOpenTools: () {},
                  onOpenMiniMap: () {},
                  onPickCamera: () {},
                  onPickPhotos: () {},
                  onUploadFiles: () {},
                  onOpenBrowser: () {},
                  onClearContext: () {},
                  onCompressContext: () {},
                  onSelectModel: () {},
                  onQuickPhrase: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(ChatInputSection)))!;

  testWidgets('an overflowing phone bar keeps one + and a menu of its own', (
    tester,
  ) async {
    final fixtures = await loadFixtures(tester);
    await pumpOneToOne(tester, fixtures: fixtures, width: 320);
    final l10n = l10nOf(tester);

    // The tools panel's "+" is the only "+". The bar's overflow has its own
    // identity: same row, different control.
    expect(find.byTooltip(l10n.chatInputBarMoreTooltip), findsOneWidget);
    expect(find.byTooltip(l10n.chatInputBarOverflowTooltip), findsOneWidget);

    // What did not fit left the row rather than vanishing.
    expect(find.byTooltip(l10n.chatInputBarToolsTooltip), findsNothing);
    expect(find.byTooltip(l10n.chatInputBarQuickPhraseTooltip), findsNothing);

    await tester.tap(find.byTooltip(l10n.chatInputBarOverflowTooltip));
    await tester.pumpAndSettle();
    expect(find.text(l10n.chatInputBarToolsTooltip), findsOneWidget);
    expect(find.text(l10n.chatInputBarQuickPhraseTooltip), findsOneWidget);
  });

  testWidgets('a phone bar that fits draws no overflow button at all', (
    tester,
  ) async {
    final fixtures = await loadFixtures(tester);
    await pumpOneToOne(tester, fixtures: fixtures, width: 360);
    final l10n = l10nOf(tester);

    expect(find.byTooltip(l10n.chatInputBarMoreTooltip), findsOneWidget);
    expect(find.byTooltip(l10n.chatInputBarOverflowTooltip), findsNothing);
    expect(find.byTooltip(l10n.chatInputBarToolsTooltip), findsOneWidget);
    expect(find.byTooltip(l10n.chatInputBarQuickPhraseTooltip), findsOneWidget);
  });
}
