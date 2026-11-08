import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/providers/asr_provider.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/instruction_injection_provider.dart';
import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/providers/quick_phrase_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/world_book_provider.dart';
import 'package:Cuplivo/features/group_chat/widgets/group_member_cluster.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_section.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

/// The left action bar carries the conversation's tools only where there is room
/// for them. A phone spends that slot on identity alone, so a group — which owns
/// attachments, the browser, the mini map and context management just as a 1:1
/// chat does — must not push them into a bar that cannot hold them: the overflow
/// then draws a second "+" beside the composer's own, with the same tooltip.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BusinessPreferences preferences;

  setUp(() async {
    preferences = createBusinessTestPreferences();
  });

  Future<AssistantProvider> loadAssistants(WidgetTester tester) async {
    late AssistantProvider provider;
    await tester.runAsync(() async {
      await preferences.setString(
        'assistants_v1',
        Assistant.encodeList([
          Assistant(
            id: 'a1',
            name: 'Alice',
            chatModelProvider: 'openai',
            chatModelId: 'gpt-4o',
          ),
          Assistant(
            id: 'a2',
            name: 'Bob',
            chatModelProvider: 'openai',
            chatModelId: 'gpt-4o',
          ),
        ]),
      );
      await preferences.setString('current_assistant_id_v1', 'a1');
      provider = AssistantProvider(preferences: preferences);
      await provider.loaded;
    });
    return provider;
  }

  GroupChat panel() => GroupChat(
    id: 'g1',
    name: 'Panel',
    memberIds: const ['a1', 'a2'],
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  Future<ChatInputBar> pumpGroupComposer(
    WidgetTester tester, {
    required AssistantProvider assistants,
    required bool isTablet,
    double width = 360,
    String? chatModelProviderKey,
    String? chatModelId,
    bool reasoningModel = false,
    VoidCallback? onOpenSearch,
    VoidCallback? onConfigureReasoning,
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
          ChangeNotifierProvider(create: (_) => SettingsProvider(preferences)),
          ChangeNotifierProvider.value(value: assistants),
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
          ChangeNotifierProvider(
            create: (_) => QuickPhraseProvider(preferences: preferences),
          ),
        ],
        child: MaterialApp(
          // A phone or tablet, never a desktop platform: the composer drops the
          // camera picker on desktops for reasons that have nothing to do with
          // where the bar puts it.
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
                  group: panel(),
                  onOpenGroupMembers: () {},
                  inputFocus: focus,
                  inputController: controller,
                  mediaController: ChatInputBarController(),
                  isTablet: isTablet,
                  isLoading: false,
                  chatModelProviderKey: chatModelProviderKey,
                  chatModelId: chatModelId,
                  onOpenSearch: onOpenSearch,
                  onConfigureReasoning: onConfigureReasoning,
                  isToolModel: (_, _) => true,
                  isReasoningModel: (_, _) => reasoningModel,
                  isReasoningEnabled: (_) => false,
                  conversationId: 'c1',
                  onPickCamera: () {},
                  onPickPhotos: () {},
                  onUploadFiles: () {},
                  onOpenBrowser: () {},
                  onOpenMiniMap: () {},
                  onClearContext: () {},
                  onCompressContext: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return tester.widget<ChatInputBar>(find.byType(ChatInputBar));
  }

  testWidgets('a phone group composer shows one + and keeps the tools in it', (
    tester,
  ) async {
    final assistants = await loadAssistants(tester);
    final bar = await pumpGroupComposer(
      tester,
      assistants: assistants,
      isTablet: false,
    );

    // Identity alone in the left bar: with nothing to overflow there is no
    // second "+" next to the panel's own.
    expect(find.byType(GroupMemberCluster), findsOneWidget);
    expect(bar.showMiniMapButton, isFalse);
    expect(bar.onOpenMiniMap, isNull);
    expect(bar.onPickCamera, isNull);
    expect(bar.onPickPhotos, isNull);
    expect(bar.onUploadFiles, isNull);
    expect(bar.onOpenBrowser, isNull);
    expect(bar.onClearContext, isNull);

    // The one "+" is the tools panel.
    expect(bar.showMoreButton, isTrue);
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ChatInputBar)),
    )!;
    expect(find.byTooltip(l10n.chatInputBarMoreTooltip), findsOneWidget);
    // This caller wired no search handler, so no globe is drawn: an action with
    // nothing to do is not an action.
    expect(find.byTooltip(l10n.chatInputBarOnlineSearchTooltip), findsNothing);
  });

  testWidgets('a group composer offers search and reasoning like a 1:1 chat', (
    tester,
  ) async {
    final assistants = await loadAssistants(tester);
    final bar = await pumpGroupComposer(
      tester,
      assistants: assistants,
      isTablet: false,
      chatModelProviderKey: 'openai',
      chatModelId: 'gpt-4o',
      reasoningModel: true,
      onOpenSearch: () {},
      onConfigureReasoning: () {},
    );

    // Both entries belong to the assistant the composer is on rather than to
    // the conversation, so a group offers them through the same handlers a 1:1
    // chat uses — and therefore through the same read and write path.
    expect(bar.onOpenSearch, isNotNull);
    expect(bar.onConfigureReasoning, isNotNull);
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ChatInputBar)),
    )!;
    expect(
      find.byTooltip(l10n.chatInputBarOnlineSearchTooltip),
      findsOneWidget,
    );
    expect(
      find.byTooltip(l10n.chatInputBarReasoningStrengthTooltip),
      findsOneWidget,
    );
  });

  testWidgets('a group hides reasoning when the composer model cannot reason', (
    tester,
  ) async {
    final assistants = await loadAssistants(tester);
    await pumpGroupComposer(
      tester,
      assistants: assistants,
      isTablet: false,
      chatModelProviderKey: 'openai',
      chatModelId: 'gpt-4o',
      reasoningModel: false,
      onOpenSearch: () {},
      onConfigureReasoning: () {},
    );

    final l10n = AppLocalizations.of(
      tester.element(find.byType(ChatInputBar)),
    )!;
    expect(
      find.byTooltip(l10n.chatInputBarReasoningStrengthTooltip),
      findsNothing,
    );
  });

  testWidgets('a group tablet still keeps the conversation tools in the bar', (
    tester,
  ) async {
    final assistants = await loadAssistants(tester);
    final bar = await pumpGroupComposer(
      tester,
      assistants: assistants,
      isTablet: true,
      width: 900,
    );

    expect(bar.onPickCamera, isNotNull);
    expect(bar.onPickPhotos, isNotNull);
    expect(bar.onUploadFiles, isNotNull);
    expect(bar.onOpenBrowser, isNotNull);
    expect(bar.onClearContext, isNotNull);
    expect(bar.showMiniMapButton, isTrue);
    expect(bar.onOpenMiniMap, isNotNull);
    // The wide layout has no tools panel to duplicate: its "+" is the only one.
    expect(bar.showMoreButton, isFalse);
    expect(find.byType(GroupMemberCluster), findsOneWidget);
  });
}
