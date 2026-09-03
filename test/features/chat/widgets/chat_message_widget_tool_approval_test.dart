import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/core/services/haptics.dart';
import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

SettingsProvider _createSettings() {
  businessPrefs = BusinessPreferences.memoryForTests(const <String, Object>{});
  return SettingsProvider(preferences: businessPrefs);
}

Widget _buildHarness({
  required SettingsProvider settings,
  required ToolApprovalService approvalService,
  required Widget child,
}) {
  return MultiProvider(
    providers: [
      Provider<BusinessPreferences>.value(value: businessPrefs),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider(
        create: (_) => TtsProvider(preferences: businessPrefs),
      ),
      ChangeNotifierProvider<ToolApprovalService>.value(value: approvalService),
      ChangeNotifierProvider(create: (_) => AskUserInteractionService()),
    ],
    child: MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

const List<ToolUIPart> _twoShellParts = [
  ToolUIPart(
    id: 'shell-1',
    toolName: 'shell',
    arguments: {'command': 'echo done'},
    content: 'done',
    loading: false,
  ),
  ToolUIPart(
    id: 'shell-2',
    toolName: 'shell',
    arguments: {'command': 'echo pending'},
    loading: true,
  ),
];

const List<ToolUIPart> _blankIdShellPart = [
  ToolUIPart(
    id: '',
    toolName: 'shell',
    arguments: {'command': 'echo blank'},
    loading: true,
  ),
];

const List<ToolUIPart> _paddedShellPart = [
  ToolUIPart(
    id: ' shell-2 ',
    toolName: 'shell',
    arguments: {'command': 'echo padded'},
    loading: true,
  ),
];

const List<ToolUIPart> _resolvedNoIdAndPendingParts = [
  ToolUIPart(
    id: '',
    toolName: 'shell',
    arguments: {'command': 'echo done'},
    content: 'done',
    loading: false,
  ),
  ToolUIPart(
    id: 'shell-2',
    toolName: 'shell',
    arguments: {'command': 'echo pending'},
    loading: true,
  ),
];

const List<ToolUIPart> _twoLoadingShellParts = [
  ToolUIPart(
    id: 'call-1',
    toolName: 'shell',
    arguments: {'command': 'echo one'},
    loading: true,
  ),
  ToolUIPart(
    id: 'call-2',
    toolName: 'shell',
    arguments: {'command': 'echo two'},
    loading: true,
  ),
];

ChatMessageWidget _toolMessage(List<ToolUIPart> parts) => ChatMessageWidget(
  message: ChatMessage(
    role: 'assistant',
    content: '',
    conversationId: 'conv-approval',
  ),
  showModelIcon: false,
  toolParts: parts,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('tool call approval buttons', () {
    testWidgets('only the pending tool part shows approval buttons; '
        'resolved past steps stay inactive', (tester) async {
      Haptics.setEnabled(false);
      final settings = _createSettings();
      final approvalService = ToolApprovalService();
      final approvalFuture = approvalService.requestApproval(
        toolCallId: 'shell-2',
        toolName: 'shell',
        arguments: const {'command': 'echo pending'},
      );

      await tester.pumpWidget(
        _buildHarness(
          settings: settings,
          approvalService: approvalService,
          child: _toolMessage(_twoShellParts),
        ),
      );
      await tester.pump();

      expect(find.widgetWithIcon(IosIconButton, Lucide.Check), findsOneWidget);
      expect(find.widgetWithIcon(IosIconButton, Lucide.X), findsOneWidget);

      await tester.tap(find.widgetWithIcon(IosIconButton, Lucide.Check));
      await tester.pump();

      final result = await approvalFuture;
      expect(result.approved, isTrue);
      expect(find.widgetWithIcon(IosIconButton, Lucide.Check), findsNothing);
      expect(find.widgetWithIcon(IosIconButton, Lucide.X), findsNothing);
    });

    testWidgets('an approval request with a different id does not bind to a '
        'same-named tool part', (tester) async {
      Haptics.setEnabled(false);
      final settings = _createSettings();
      final approvalService = ToolApprovalService();
      final approvalFuture = approvalService.requestApproval(
        toolCallId: 'shell-other',
        toolName: 'shell',
        arguments: const {'command': 'echo other'},
      );

      await tester.pumpWidget(
        _buildHarness(
          settings: settings,
          approvalService: approvalService,
          child: _toolMessage(_twoShellParts),
        ),
      );
      await tester.pump();

      expect(find.widgetWithIcon(IosIconButton, Lucide.Check), findsNothing);
      expect(find.widgetWithIcon(IosIconButton, Lucide.X), findsNothing);

      approvalService.approve('shell-other');
      expect(await approvalFuture, isNotNull);
    });

    testWidgets('a no-id tool part never shows approval buttons', (
      tester,
    ) async {
      Haptics.setEnabled(false);
      final settings = _createSettings();
      final approvalService = ToolApprovalService();
      final approvalFuture = approvalService.requestApproval(
        toolCallId: 'shell_1725000000000',
        toolName: 'shell',
        arguments: const {'command': 'echo blank'},
      );

      await tester.pumpWidget(
        _buildHarness(
          settings: settings,
          approvalService: approvalService,
          child: _toolMessage(_blankIdShellPart),
        ),
      );
      await tester.pump();

      expect(find.widgetWithIcon(IosIconButton, Lucide.Check), findsNothing);
      expect(find.widgetWithIcon(IosIconButton, Lucide.X), findsNothing);

      approvalService.approve('shell_1725000000000');
      expect(await approvalFuture, isNotNull);
    });

    testWidgets('a whitespace-padded part id matches the trimmed request id', (
      tester,
    ) async {
      Haptics.setEnabled(false);
      final settings = _createSettings();
      final approvalService = ToolApprovalService();
      final approvalFuture = approvalService.requestApproval(
        toolCallId: 'shell-2',
        toolName: 'shell',
        arguments: const {'command': 'echo padded'},
      );

      await tester.pumpWidget(
        _buildHarness(
          settings: settings,
          approvalService: approvalService,
          child: _toolMessage(_paddedShellPart),
        ),
      );
      await tester.pump();

      expect(find.widgetWithIcon(IosIconButton, Lucide.Check), findsOneWidget);
      expect(find.widgetWithIcon(IosIconButton, Lucide.X), findsOneWidget);

      await tester.tap(find.widgetWithIcon(IosIconButton, Lucide.Check));
      await tester.pump();

      final result = await approvalFuture;
      expect(result.approved, isTrue);
    });

    testWidgets('a resolved no-id part stays inactive while a same-named '
        'request pends', (tester) async {
      Haptics.setEnabled(false);
      final settings = _createSettings();
      final approvalService = ToolApprovalService();
      final approvalFuture = approvalService.requestApproval(
        toolCallId: 'shell-2',
        toolName: 'shell',
        arguments: const {'command': 'echo pending'},
      );

      await tester.pumpWidget(
        _buildHarness(
          settings: settings,
          approvalService: approvalService,
          child: _toolMessage(_resolvedNoIdAndPendingParts),
        ),
      );
      await tester.pump();

      expect(find.widgetWithIcon(IosIconButton, Lucide.Check), findsOneWidget);
      expect(find.widgetWithIcon(IosIconButton, Lucide.X), findsOneWidget);

      await tester.tap(find.widgetWithIcon(IosIconButton, Lucide.Check));
      await tester.pump();

      final result = await approvalFuture;
      expect(result.approved, isTrue);
    });

    testWidgets('concurrent same-name calls each target their own approval '
        '(approve then deny)', (tester) async {
      Haptics.setEnabled(false);
      final settings = _createSettings();
      final approvalService = ToolApprovalService();
      final firstFuture = approvalService.requestApproval(
        toolCallId: 'call-1',
        toolName: 'shell',
        arguments: const {'command': 'echo one'},
      );
      final secondFuture = approvalService.requestApproval(
        toolCallId: 'call-2',
        toolName: 'shell',
        arguments: const {'command': 'echo two'},
      );

      await tester.pumpWidget(
        _buildHarness(
          settings: settings,
          approvalService: approvalService,
          child: _toolMessage(_twoLoadingShellParts),
        ),
      );
      await tester.pump();

      expect(
        find.widgetWithIcon(IosIconButton, Lucide.Check),
        findsNWidgets(2),
      );
      expect(find.widgetWithIcon(IosIconButton, Lucide.X), findsNWidgets(2));

      await tester.tap(find.widgetWithIcon(IosIconButton, Lucide.Check).first);
      await tester.pump();

      final firstResult = await firstFuture;
      expect(firstResult.approved, isTrue);
      expect(approvalService.isPending('call-2'), isTrue);
      expect(find.widgetWithIcon(IosIconButton, Lucide.Check), findsOneWidget);

      await tester.tap(find.widgetWithIcon(IosIconButton, Lucide.X));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final dialogContext = tester.element(find.byType(AlertDialog));
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(
            AppLocalizations.of(dialogContext)!.toolApprovalDeny,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final secondResult = await secondFuture;
      expect(secondResult.approved, isFalse);
      expect(find.widgetWithIcon(IosIconButton, Lucide.X), findsNothing);
    });
  });
}
