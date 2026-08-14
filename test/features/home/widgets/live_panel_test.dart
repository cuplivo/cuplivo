import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/providers/download_progress_store.dart';
import 'package:Cuplivo/core/providers/input_status_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/generation_engine.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/features/home/widgets/live_panel.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

class _FakeChatService extends ChatService {
  _FakeChatService(this.currentConversationId);

  @override
  final String? currentConversationId;
}

void main() {
  late _FakeChatService chatService;
  late GenerationEngine engine;
  late ToolApprovalService approvalService;
  late AskUserInteractionService askUserService;
  late DownloadProgressStore downloadStore;
  late InputStatusProvider inputStatus;

  Future<void> pumpPanel(
    WidgetTester tester, {
    ValueChanged<String>? onOpenChild,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsProvider>(
              create: (_) => SettingsProvider(),
            ),
            ChangeNotifierProvider<ChatService>.value(value: chatService),
            ChangeNotifierProvider<GenerationEngine>.value(value: engine),
            ChangeNotifierProvider<ToolApprovalService>.value(
              value: approvalService,
            ),
            ChangeNotifierProvider<AskUserInteractionService>.value(
              value: askUserService,
            ),
            ChangeNotifierProvider<DownloadProgressStore>.value(
              value: downloadStore,
            ),
            ChangeNotifierProvider<InputStatusProvider>.value(
              value: inputStatus,
            ),
          ],
          child: Scaffold(body: LivePanel(onOpenChild: onOpenChild)),
        ),
      ),
    );
  }

  setUp(() {
    chatService = _FakeChatService('parent-conv');
    engine = GenerationEngine(chatService: chatService);
    approvalService = ToolApprovalService();
    askUserService = AskUserInteractionService();
    downloadStore = DownloadProgressStore();
    inputStatus = InputStatusProvider();
  });

  group('LivePanel', () {
    testWidgets('renders nothing without an active wait job', (tester) async {
      await pumpPanel(tester);
      expect(find.byType(LivePanel), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('renders one card per concurrent wait job', (tester) async {
      engine.prepareRound(
        conversationId: 'child-a',
        assistantMessageId: 'msg-child-a',
        parentConversationId: 'parent-conv',
        wait: true,
        targetName: 'Agent A',
      );
      engine.prepareRound(
        conversationId: 'child-b',
        assistantMessageId: 'msg-child-b',
        parentConversationId: 'parent-conv',
        wait: true,
        targetName: 'Agent B',
      );

      await pumpPanel(tester);

      expect(find.textContaining('Agent A'), findsOneWidget);
      expect(find.textContaining('Agent B'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNWidgets(2));
    });

    testWidgets('renders the pill for an active wait job keyed to the current '
        'conversation', (tester) async {
      engine.prepareRound(
        conversationId: 'child-conv',
        assistantMessageId: 'msg-child-conv',
        parentConversationId: 'parent-conv',
        wait: true,
        targetName: 'Research Bot',
      );

      await pumpPanel(tester);

      expect(find.textContaining('Research Bot'), findsOneWidget);
      expect(find.textContaining('▸'), findsNothing);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('expanded row shows tool calls and opens the child', (
      tester,
    ) async {
      final job = engine.prepareRound(
        conversationId: 'child-conv',
        assistantMessageId: 'msg-child-conv',
        parentConversationId: 'parent-conv',
        wait: true,
        targetName: 'Research Bot',
      );
      job.toolCallCount = 3;
      job.lastStep = 'kelivo_read';
      job.lastStepKind = SlotLastStepKind.done;
      String? openedChildId;
      await pumpPanel(tester, onOpenChild: (id) => openedChildId = id);

      // Expand, then the row is tappable and opens the child.
      await tester.tap(find.textContaining('Research Bot'));
      await tester.pump();
      expect(find.textContaining('3 tool calls'), findsOneWidget);
      expect(find.text('kelivo_read'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_forward_ios), findsOneWidget);

      await tester.tap(find.textContaining('3 tool calls'));
      await tester.pump();
      expect(openedChildId, 'child-conv');
    });

    testWidgets('renders nothing when the job belongs to another conversation', (
      tester,
    ) async {
      // Regression: the handoff used to move ChatService.currentConversationId
      // to the child (setAsCurrent default). The panel keys off the current
      // conversation, so a mismatched key must not show the job.
      engine.prepareRound(
        conversationId: 'child-conv',
        assistantMessageId: 'msg-child-conv',
        parentConversationId: 'parent-conv',
        wait: true,
        targetName: 'Research Bot',
      );
      chatService = _FakeChatService('child-conv');

      await pumpPanel(tester);

      expect(find.textContaining('Research Bot'), findsNothing);
    });

    testWidgets(
      '✕ cancels the sub-agent and resolves its pending approval after '
      'confirmation',
      (tester) async {
        engine.prepareRound(
          conversationId: 'child-conv',
          assistantMessageId: 'msg-child-conv',
          parentConversationId: 'parent-conv',
          wait: true,
          targetName: 'Research Bot',
        );
        final approvalFuture = approvalService.requestApproval(
          toolCallId: 'tool_call_1',
          toolName: 'kelivo_delete',
          arguments: const {'path': '/x'},
          conversationId: 'child-conv',
        );

        await pumpPanel(tester);
        await tester.tap(find.byIcon(Icons.close));
        // The panel runs a 1s ticker, so pumpAndSettle never settles — pump
        // fixed durations instead.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Confirmation dialog: tap 终止 (Stop).
        await tester.tap(find.text('Stop'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final approval = await approvalFuture.timeout(
          const Duration(seconds: 1),
        );
        expect(approval.approved, isFalse);
        expect(approval.denyReason, 'cancelled');
        // The waiter was resolved as cancelled and the record cleaned up.
        final waitResult = await engine
            .waitFor('child-conv')
            .timeout(const Duration(seconds: 1));
        expect(waitResult.cancelled, isTrue);
      },
    );

    testWidgets('approval pending auto-expands and Approve completes it', (
      tester,
    ) async {
      engine.prepareRound(
        conversationId: 'child-conv',
        assistantMessageId: 'msg-child-conv',
        parentConversationId: 'parent-conv',
        wait: true,
        targetName: 'Research Bot',
      );
      final approvalFuture = approvalService.requestApproval(
        toolCallId: 'tool_call_1',
        toolName: 'kelivo_delete',
        arguments: const {'path': '/x'},
        conversationId: 'child-conv',
      );

      await pumpPanel(tester);

      expect(find.text('kelivo_delete'), findsOneWidget);
      await tester.tap(find.text('Approve'));
      await tester.pump();

      final approval = await approvalFuture.timeout(const Duration(seconds: 1));
      expect(approval.approved, isTrue);
    });

    testWidgets('renders a download entry for the current conversation', (
      tester,
    ) async {
      downloadStore.begin(
        conversationId: 'parent-conv',
        url: 'https://example.com/report.zip',
        displayPath: '/workspace/report.zip',
      );

      await pumpPanel(tester);

      expect(find.textContaining('report.zip'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('hides a download entry for another conversation', (
      tester,
    ) async {
      downloadStore.begin(
        conversationId: 'other-conv',
        url: 'https://example.com/report.zip',
        displayPath: '/workspace/report.zip',
      );

      await pumpPanel(tester);

      expect(find.textContaining('report.zip'), findsNothing);
    });

    testWidgets('renders and dismisses the image-mode info pill', (
      tester,
    ) async {
      inputStatus.updateImageModeKey('parent-conv::p::m');

      await pumpPanel(tester);

      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Lucide.Brush), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('renders and dismisses the image-warning pill', (tester) async {
      inputStatus.updateImageWarningKey('parent-conv::p::m');

      await pumpPanel(tester);

      expect(find.byIcon(Lucide.ImageOff), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(find.byIcon(Icons.close), findsNothing);
    });
  });
}
