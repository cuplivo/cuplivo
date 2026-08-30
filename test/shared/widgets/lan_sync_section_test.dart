import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_models.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/lan_sync_section.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

/// Minimal ChatService fake: the client index builder never touches the
/// repo when there are no conversations.
class _FakeChatService extends ChatService {
  @override
  List<Conversation> getAllCompleteConversations() => const [];

  @override
  Future<List<Assistant>> getAllAssistants() async => const [];
}

/// DataSync fake whose file-manifest builder needs no real filesystem — the
/// client index builder calls `buildFileManifest`, and real file I/O cannot
/// complete inside `testWidgets`'s fake-async zone.
class _FakeDataSync extends DataSync {
  _FakeDataSync(BusinessPreferences preferences, ChatService chatService)
    : super(chatService: chatService, preferences: preferences);

  @override
  Future<Map<String, FileManifestEntry>> buildFileManifest() async => const {};
}

/// Returns a plan with zero changes and a null `since`, so the exchange
/// round never builds a zip or touches DataSync.
String _emptyPlanJson() {
  return const SyncPlan(
    conversations: [],
    missingAssistantIds: [],
    remoteMissingAssistantIds: [],
    since: null,
  ).toJsonString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeChatService chatService;

  setUp(() {
    businessPrefs = BusinessPreferences.memoryForTests();
    businessPrefs = BusinessPreferences.memoryForTests({});
    chatService = _FakeChatService();
  });

  Widget buildHarness(http.Client httpClient) {
    return MultiProvider(
      providers: [
        Provider<BusinessPreferences>.value(value: businessPrefs),
        ChangeNotifierProvider<ChatService>.value(value: chatService),
        // IosCardPress reads SettingsProvider for its tactile feedback.
        ChangeNotifierProvider<SettingsProvider>.value(
          value: SettingsProvider(preferences: businessPrefs),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LanSyncSection(
            lanSyncHttpClient: httpClient,
            dataSync: _FakeDataSync(businessPrefs, chatService),
          ),
        ),
      ),
    );
  }

  /// Opens the mobile client sheet and fills host/port/PIN.
  Future<void> openSheet(WidgetTester tester, http.Client httpClient) async {
    await tester.pumpWidget(buildHarness(httpClient));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect to Server'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), '127.0.0.1');
    await tester.enterText(fields.at(1), '9527');
    await tester.enterText(fields.at(2), '1234');
  }

  testWidgets('error during negotiate keeps the sheet open (retryable)', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final client = MockClient(
      (request) async => throw const SocketException('connection refused'),
    );

    await openSheet(tester, client);
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    // Error snackbar shown, sheet still open with all three fields.
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(3));
    expect(find.text('Client Mode'), findsOneWidget);

    // Must be reset before the binding's invariant check runs (i.e. in
    // the body itself, not in a tearDown).
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('empty exchange response closes the sheet', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final client = MockClient((request) async {
      if (request.url.path == '/sync/plan') {
        return http.Response(_emptyPlanJson(), 200);
      }
      if (request.url.path == '/sync/exchange') {
        return http.Response(
          '{"empty":true}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('Not found', 404);
    });

    await openSheet(tester, client);
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.text('Start Sync'), findsOneWidget);

    await tester.tap(find.text('Start Sync'));
    await tester.pumpAndSettle();

    // noData → the sheet closes itself; the host page stays.
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Client Mode'), findsNothing);
    expect(find.byType(LanSyncSection), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'conflict priority picker sends the chosen syncPriority in the plan '
    'request',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      String? planBody;
      final client = MockClient((request) async {
        if (request.url.path == '/sync/plan') {
          planBody = request.body;
          return http.Response(_emptyPlanJson(), 200);
        }
        return http.Response('Not found', 404);
      });

      await openSheet(tester, client);

      // Picker is visible pre-negotiate and defaults to auto.
      expect(find.text('Conflict resolution'), findsOneWidget);
      await tester.tap(find.text('This device wins'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      expect(planBody, isNotNull);
      expect(
        planBody,
        contains('"syncPriority":"initiatorWins"'),
        reason: 'chosen direction must ride the plan request',
      );

      // After negotiate the picker is locked (choice fixed per session).
      await tester.tap(find.text('Peer wins'));
      await tester.pumpAndSettle();
      expect(find.text('Peer wins'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    },
  );

  group('shared LAN sync builders', () {
    /// Renders the output of a shared builder against the real l10n/theme.
    Future<void> pumpBuilders(
      WidgetTester tester,
      List<Widget> Function(AppLocalizations l10n, ColorScheme cs) builder,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final l10n = AppLocalizations.of(context)!;
                final cs = Theme.of(context).colorScheme;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: builder(l10n, cs),
                );
              },
            ),
          ),
        ),
      );
    }

    testWidgets('plan summary shows file lines only when known and > 0', (
      tester,
    ) async {
      final plan = SyncPlan(
        conversations: const [
          SyncConvPlan(
            conversationId: 'c1',
            state: SyncConvState.initiatorOnly,
            initiatorIncrementCount: 2,
            serverIncrementCount: 0,
          ),
        ],
        missingAssistantIds: const [],
        remoteMissingAssistantIds: const [],
        since: DateTime(2026, 1, 1),
        serverFileCount: 3,
        serverFileSizeBytes: 2048,
      );

      await pumpBuilders(
        tester,
        (l10n, cs) => buildPlanSummary(
          l10n,
          plan,
          cs,
          outboundFileCount: 5,
          outboundFileSizeBytes: 1024,
        ),
      );
      expect(find.text('1 conversations to send'), findsOneWidget);
      expect(find.text('5 files to send (1.00 KB)'), findsOneWidget);
      expect(find.text('3 files to receive (2.00 KB)'), findsOneWidget);

      // Zero outbound → send line disappears; receive line stays.
      await pumpBuilders(
        tester,
        (l10n, cs) => buildPlanSummary(
          l10n,
          plan,
          cs,
          outboundFileCount: 0,
          outboundFileSizeBytes: 0,
        ),
      );
      expect(find.textContaining('files to send'), findsNothing);
      expect(find.text('3 files to receive (2.00 KB)'), findsOneWidget);

      // Unknown server stats (old peer) → receive line disappears.
      await pumpBuilders(
        tester,
        (l10n, cs) => buildPlanSummary(
          l10n,
          SyncPlan(
            conversations: plan.conversations,
            missingAssistantIds: const [],
            remoteMissingAssistantIds: const [],
            since: DateTime(2026, 1, 1),
          ),
          cs,
          outboundFileCount: 5,
          outboundFileSizeBytes: 1024,
        ),
      );
      expect(find.text('5 files to send (1.00 KB)'), findsOneWidget);
      expect(find.textContaining('files to receive'), findsNothing);
    });

    testWidgets('empty plan renders the no-changes line', (tester) async {
      await pumpBuilders(
        tester,
        (l10n, cs) => buildPlanSummary(
          l10n,
          const SyncPlan(
            conversations: [],
            missingAssistantIds: [],
            remoteMissingAssistantIds: [],
            since: null,
          ),
          cs,
          outboundFileCount: 0,
          outboundFileSizeBytes: 0,
        ),
      );
      expect(find.text('No changes to sync.'), findsOneWidget);
    });

    testWidgets('restore progress: determinate bar on the file-copy stage', (
      tester,
    ) async {
      const progress = RestoreProgress(
        stage: RestoreStage.copyingFiles,
        fraction: 0.5,
        filesCopied: 1,
        filesTotal: 2,
        bytesCopied: 100,
        bytesTotal: 2048,
      );
      await pumpBuilders(
        tester,
        (l10n, cs) => [buildRestoreProgress(progress, l10n, cs)],
      );
      expect(find.text('Writing files...'), findsOneWidget);
      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.value, 0.5);
      expect(find.text('1/2 files · 2.00 KB'), findsOneWidget);
    });

    testWidgets('restore progress: indeterminate stage hides the file line', (
      tester,
    ) async {
      const progress = RestoreProgress(stage: RestoreStage.extracting);
      await pumpBuilders(
        tester,
        (l10n, cs) => [buildRestoreProgress(progress, l10n, cs)],
      );
      expect(find.text('Extracting data...'), findsOneWidget);
      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.value, isNull);
      expect(find.textContaining('files ·'), findsNothing);
    });

    testWidgets('restore progress: chat-merge stage shows the conversation '
        'counter', (tester) async {
      const progress = RestoreProgress(
        stage: RestoreStage.mergingChats,
        fraction: 0.5,
        conversationsMerged: 3,
        conversationsTotal: 6,
      );
      await pumpBuilders(
        tester,
        (l10n, cs) => [buildRestoreProgress(progress, l10n, cs)],
      );
      expect(find.text('Merging chats...'), findsOneWidget);
      expect(find.text('3/6 conversations'), findsOneWidget);
      expect(find.textContaining('files ·'), findsNothing);
    });

    testWidgets('restore error shows the message and a close action', (
      tester,
    ) async {
      var closed = false;
      await pumpBuilders(
        tester,
        (l10n, cs) => [
          buildRestoreError('boom', l10n, cs, onClose: () => closed = true),
        ],
      );
      expect(find.text('Sync data merge failed'), findsOneWidget);
      expect(find.text('boom'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      expect(closed, isTrue);
    });
  });
}
