// The composer's two roster entries, judged by what a group round will actually
// do: a member whose model cannot reason never reasons, and a member whose model
// cannot call tools offers none. Both are the pairs the send path checks
// (`supportsReasoning && isReasoningEnabled(...)`, `supportsModelTools &&
// _isToolsActive`), so configuration alone must not light an entry.
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/models/model_spec.dart';
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

import '../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BusinessPreferences preferences;

  setUp(() async {
    preferences = createBusinessTestPreferences();
  });

  Future<AssistantProvider> loadAssistants(
    WidgetTester tester,
    List<Assistant> roster,
  ) async {
    late AssistantProvider provider;
    await tester.runAsync(() async {
      await preferences.setString(
        'assistants_v1',
        Assistant.encodeList(roster),
      );
      await preferences.setString('current_assistant_id_v1', roster.first.id);
      provider = AssistantProvider(preferences: preferences);
      await provider.loaded;
    });
    return provider;
  }

  GroupChat panel(List<String> ids) => GroupChat(
    id: 'g1',
    name: 'Panel',
    memberIds: ids,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  Future<ChatInputBar> pumpGroupComposer(
    WidgetTester tester, {
    required AssistantProvider assistants,
    required List<String> memberIds,
    bool Function(String providerKey, String modelId)? isToolModel,
  }) async {
    tester.view.physicalSize = const Size(360, 800);
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
          theme: ThemeData(platform: TargetPlatform.android),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 360,
                child: ChatInputSection(
                  inputBarKey: GlobalKey(),
                  group: panel(memberIds),
                  onOpenGroupMembers: () {},
                  inputFocus: focus,
                  inputController: controller,
                  mediaController: ChatInputBarController(),
                  isTablet: false,
                  isLoading: false,
                  chatModelProviderKey: 'openai',
                  chatModelId: 'gpt-4o',
                  onOpenSearch: () {},
                  onConfigureReasoning: () {},
                  isToolModel: isToolModel ?? (_, _) => true,
                  // Only `o3` can reason; `gpt-4o` cannot (the catalog says
                  // supportsReasoning=false, defaultLevel=auto).
                  isReasoningModel: (_, modelId) => modelId == 'o3',
                  isReasoningEnabled: (request) =>
                      request.level != ReasoningLevel.off,
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

  Assistant capableModelOff() => const Assistant(
    id: 'a1',
    name: 'Alice',
    chatModelProvider: 'openai',
    chatModelId: 'o3',
    reasoning: ReasoningRequest(ReasoningLevel.off),
  );

  /// A member whose model cannot reason, so it carries no preference and
  /// resolves to the spec default (`auto`, never `off`).
  Assistant withoutReasoning() => const Assistant(
    id: 'a2',
    name: 'Bob',
    chatModelProvider: 'openai',
    chatModelId: 'gpt-4o',
  );

  group('reasoning entry', () {
    testWidgets('a member that cannot reason never lights it', (tester) async {
      final assistants = await loadAssistants(tester, [
        capableModelOff(),
        withoutReasoning(),
      ]);
      final bar = await pumpGroupComposer(
        tester,
        assistants: assistants,
        memberIds: const ['a1', 'a2'],
      );

      // The entry is offered (somebody could reason in principle) and says
      // nothing uniform, but it must not claim this round reasons: Alice is off
      // and Bob cannot.
      expect(bar.supportsReasoning, isTrue);
      expect(bar.reasoning, isNull);
      expect(bar.reasoningActive, isFalse);
    });

    testWidgets('a capable member left on lights it', (tester) async {
      final assistants = await loadAssistants(tester, [
        const Assistant(
          id: 'a1',
          name: 'Alice',
          chatModelProvider: 'openai',
          chatModelId: 'o3',
          reasoning: ReasoningRequest(ReasoningLevel.low),
        ),
        withoutReasoning(),
      ]);
      final bar = await pumpGroupComposer(
        tester,
        assistants: assistants,
        memberIds: const ['a1', 'a2'],
      );

      expect(bar.reasoningActive, isTrue);
    });

    testWidgets('every capable member off is not lit', (tester) async {
      final assistants = await loadAssistants(tester, [
        capableModelOff(),
        const Assistant(
          id: 'a2',
          name: 'Bob',
          chatModelProvider: 'openai',
          chatModelId: 'o3',
          reasoning: ReasoningRequest(ReasoningLevel.off),
        ),
      ]);
      final bar = await pumpGroupComposer(
        tester,
        assistants: assistants,
        memberIds: const ['a1', 'a2'],
      );

      expect(bar.reasoningActive, isFalse);
    });
  });

  group('tools entry', () {
    Assistant withLocalTools() => const Assistant(
      id: 'a1',
      name: 'Alice',
      chatModelProvider: 'openai',
      chatModelId: 'gpt-4o',
      localToolIds: ['current_time'],
    );

    testWidgets('a member whose model cannot call tools does not light it', (
      tester,
    ) async {
      final assistants = await loadAssistants(tester, [
        withLocalTools(),
        withoutReasoning(),
      ]);
      final bar = await pumpGroupComposer(
        tester,
        assistants: assistants,
        memberIds: const ['a1', 'a2'],
        // Neither model is known to call tools, so the member's local tools
        // cannot run: the 1:1 rule would not offer the entry either.
        isToolModel: (_, _) => false,
      );

      expect(bar.toolsActive, isFalse);
    });

    testWidgets('the same member with a tool-capable model lights it', (
      tester,
    ) async {
      final assistants = await loadAssistants(tester, [
        withLocalTools(),
        withoutReasoning(),
      ]);
      final bar = await pumpGroupComposer(
        tester,
        assistants: assistants,
        memberIds: const ['a1', 'a2'],
      );

      expect(bar.toolsActive, isTrue);
    });
  });
}
