import '../../../support/business_test_harness.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/features/home/widgets/message_list_view.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final role in ['user', 'assistant']) {
    for (final dragSelection in [false, true]) {
      testWidgets(
        '$role message ${dragSelection ? 'drag' : 'multi-click'} selection copies with Ctrl+C',
        (tester) async {
          var clipboard = 'clipboard sentinel';
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                clipboard = (call.arguments as Map)['text'] as String;
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          await tester.pumpWidget(_MessageCopyHarness(role: role));
          await tester.pumpAndSettle();
          final rect = tester.getRect(
            find.text('copyable', findRichText: true),
          );
          if (dragSelection) {
            final gesture = await tester.startGesture(
              Offset(rect.left + 1, rect.center.dy),
              kind: PointerDeviceKind.mouse,
            );
            await gesture.moveTo(Offset(rect.right + 1, rect.center.dy));
            await gesture.up();
            await tester.pump();
          } else {
            for (var click = 0; click < 3; click++) {
              await tester.tapAt(
                Offset(rect.left + 20, rect.center.dy),
                kind: PointerDeviceKind.mouse,
              );
              await tester.pump(const Duration(milliseconds: 100));
            }
          }
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
          expect(clipboard.trim(), 'copyable');
        },
        variant: TargetPlatformVariant.only(TargetPlatform.linux),
      );
    }
  }
}

class _MessageCopyHarness extends StatefulWidget {
  const _MessageCopyHarness({required this.role});
  final String role;

  @override
  State<_MessageCopyHarness> createState() => _MessageCopyHarnessState();
}

class _MessageCopyHarnessState extends State<_MessageCopyHarness> {
  final scrollController = ScrollController();
  final listController = ListController();
  final processing = ValueNotifier<String?>(null);

  @override
  void dispose() {
    scrollController.dispose();
    listController.dispose();
    processing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(createBusinessTestPreferences()),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              AssistantProvider(preferences: createBusinessTestPreferences()),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              UserProvider(preferences: createBusinessTestPreferences()),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              TtsProvider(preferences: createBusinessTestPreferences()),
        ),
        ChangeNotifierProvider(create: (_) => AskUserInteractionService()),
        ChangeNotifierProvider(create: (_) => ToolApprovalService()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MessageListView(
            scrollController: scrollController,
            listController: listController,
            messages: [
              ChatMessage(
                id: 'copy-message',
                role: widget.role,
                content: 'copyable',
                conversationId: 'copy-conversation',
              ),
            ],
            byGroup: const {},
            versionSelections: const {},
            reasoning: const {},
            reasoningSegments: const {},
            contentSplits: const {},
            toolParts: const {},
            translations: const {},
            selecting: false,
            selectedItems: const {},
            dividerPadding: EdgeInsets.zero,
            processingFilesMessageId: processing,
          ),
        ),
      ),
    );
  }
}
