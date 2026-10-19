import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/services/recycle/recycle_service.dart';
import 'package:Cuplivo/features/recycle/pages/recycle_bin_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// The bin page against a real store: what an entry looks like, that restore
/// retires it, and that a permanent delete is confirmed first.
void main() {
  late Directory binRoot;
  late AppDatabase database;
  late RecycleStore store;
  late RecycleService service;

  setUp(() async {
    binRoot = await Directory.systemTemp.createTemp('kelivo_recycle_ui_');
    database = AppDatabase(NativeDatabase.memory());
    store = RecycleStore(directory: () async => binRoot);
    service = RecycleService(database, store: store);
  });

  tearDown(() async {
    await database.close();
    if (await binRoot.exists()) await binRoot.delete(recursive: true);
  });

  /// Waits for something the page only draws once its real file reads land.
  ///
  /// Every await on a real path costs one scheduler window here, and the page
  /// reads one entry file per staged entry, so the budget has to scale with the
  /// amount of staged data rather than with the number of frames.
  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    for (
      var attempt = 0;
      attempt < 200 && finder.evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      finder,
      findsWidgets,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data)
          .whereType<String>()
          .join(' | '),
    );
  }

  /// The mirror of [pumpUntilFound], for something the page draws only after its
  /// reload: pumping alone never lets a real file read complete.
  Future<void> pumpUntilGone(WidgetTester tester, Finder finder) async {
    for (
      var attempt = 0;
      attempt < 200 && finder.evaluate().isNotEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(finder, findsNothing);
  }

  Future<void> pumpPage(WidgetTester tester) => tester.pumpWidget(
    Provider<RecycleService>.value(
      value: service,
      child: const MaterialApp(
        locale: Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: RecycleBinPage(),
      ),
    ),
  );

  /// Lets the real filesystem work the page awaits actually finish: `pump`
  /// alone only advances fake time, and the bin reads and writes real files.
  /// Polls the store rather than pumping a fixed number of frames, so the test
  /// does not race the page's own reload.
  Future<void> pumpUntilBinSize(WidgetTester tester, int expected) async {
    for (var attempt = 0; attempt < 200; attempt++) {
      final entries = await tester.runAsync(() => store.list());
      if ((entries ?? const <RecycleEntry>[]).length == expected) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(await tester.runAsync(() => store.list()), hasLength(expected));
  }

  /// Runs the confirmation snackbar's timer out and its dismissal animation to
  /// the end. The snackbar manager is a process-wide singleton, so a test that
  /// leaves one in flight poisons whichever test pumps next.
  Future<void> drainSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  Future<void> stageConversation(
    WidgetTester tester,
    String id,
    String title, {
    RecycleOrigin origin = RecycleOrigin.remote,
    RecycleGroup? group,
    Map<String, Object?> extra = const <String, Object?>{},
    int messageCount = 0,
  }) => tester.runAsync(
    () => store.stageRows(
      type: RecycleEntryType.conversation,
      origin: origin,
      reason: RecycleReason.deleted,
      key: id,
      title: title,
      group: group,
      tables: {
        'conversation_rows': [
          {
            'id': id,
            'title': title,
            'created_at': 1,
            'updated_at': 1,
            ...extra,
          },
        ],
        if (messageCount > 0)
          'message_rows': [
            for (var index = 0; index < messageCount; index++)
              {
                'id': '$id-m$index',
                'conversation_id': id,
                'content': 'message $index',
              },
          ],
      },
    ),
  );

  Future<void> stageEntity(
    WidgetTester tester,
    String id,
    String title, {
    String kindWire = 'assistant_rows',
  }) => tester.runAsync(
    () => store.stageRows(
      type: RecycleEntryType.businessEntity,
      origin: RecycleOrigin.local,
      reason: RecycleReason.deleted,
      key: id,
      title: title,
      kindWire: kindWire,
      tables: {
        kindWire: [
          {'id': id, 'payload': '{}', 'sort_order': 0, 'updated_at': 1},
        ],
      },
    ),
  );

  Future<void> stagePreference(WidgetTester tester, String key) =>
      tester.runAsync(
        () => store.stageRows(
          type: RecycleEntryType.preference,
          origin: RecycleOrigin.remote,
          reason: RecycleReason.overwritten,
          key: key,
          title: key,
          tables: {
            'preference_rows': [
              {'key': key, 'value': '"on"', 'updated_at': 1},
            ],
          },
        ),
      );

  Future<void> stageFile(WidgetTester tester, String relPath) async {
    final source = File('${binRoot.parent.path}/${relPath.split('/').last}');
    await tester.runAsync(() async {
      await source.writeAsString('notes');
      await store.stageFile(
        workspaceId: 'w1',
        relPath: relPath,
        source: source,
        origin: RecycleOrigin.remote,
        reason: RecycleReason.overwritten,
      );
    });
  }

  testWidgets('an entry shows what it is, who removed it and when', (
    tester,
  ) async {
    await stageConversation(tester, 'c1', 'Weekly notes');

    await pumpPage(tester);
    await pumpUntilFound(tester, find.text('Weekly notes'));

    expect(find.text('Conversation · Deleted by sync'), findsOneWidget);
    // The restore and permanent-delete actions are the row's whole vocabulary.
    expect(find.byTooltip('Restore'), findsOneWidget);
    expect(find.byTooltip('Delete permanently'), findsOneWidget);
  });

  testWidgets('each tab shows one kind, and settings keep assistants out', (
    tester,
  ) async {
    await stageConversation(tester, 'c1', 'A chat');
    await stageEntity(tester, 'a1', 'An assistant');
    await stageEntity(tester, 'p1', 'A provider', kindWire: 'provider_rows');
    await stagePreference(tester, 'stream_enabled');
    await stageFile(tester, 'notes/todo.md');

    await pumpPage(tester);
    // Newest first: the file is the last thing staged, so it is the row that is
    // built first — a builder list only builds what the viewport shows.
    await pumpUntilFound(tester, find.text('notes/todo.md'));

    await tester.tap(find.text('Assistants'));
    await tester.pumpAndSettle();
    expect(find.text('An assistant'), findsOneWidget);
    expect(find.text('A provider'), findsNothing);
    expect(find.text('A chat'), findsNothing);
    expect(find.text('notes/todo.md'), findsNothing);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('A provider'), findsOneWidget);
    expect(find.text('stream_enabled'), findsOneWidget);
    expect(find.text('An assistant'), findsNothing);

    await tester.tap(find.text('Conversations'));
    await tester.pumpAndSettle();
    expect(find.text('A chat'), findsOneWidget);
    expect(find.text('A provider'), findsNothing);

    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    expect(find.text('notes/todo.md'), findsOneWidget);
    expect(find.text('A chat'), findsNothing);
  });

  testWidgets('a cascade shows one group header that can restore it all', (
    tester,
  ) async {
    final group = RecycleGroup(id: 'g1', label: 'Delete Me');
    await stageConversation(tester, 'c1', 'First', group: group);
    await stageConversation(tester, 'c2', 'Second', group: group);
    await stageConversation(tester, 'c3', 'Third', group: group);
    await stageEntity(tester, 'a1', 'Delete Me');

    await pumpPage(tester);
    // Newest first: the assistant's own entry is the last staged, and the
    // conversations follow it, so 'Third' is the row the viewport builds.
    await pumpUntilFound(tester, find.text('Third'));

    // One header for the three, naming the assistant and the count.
    expect(
      find.text('3 conversations deleted together with “Delete Me”'),
      findsOneWidget,
    );
    expect(find.text('Restore all'), findsOneWidget);

    await tester.tap(find.text('Restore all'));
    await pumpUntilBinSize(tester, 1);
    await pumpUntilGone(tester, find.text('Restore all'));

    // Only the assistant's own entry is left, and the header went with the
    // conversations it described.
    expect(find.text('Delete Me'), findsOneWidget);
    final restored = await tester.runAsync(
      () => database
          .customSelect('SELECT COUNT(*) AS n FROM conversation_rows;')
          .getSingle(),
    );
    expect(restored?.read<int>('n'), 3);

    await drainSnackBar(tester);
  });

  testWidgets('tapping a row opens what it holds, and the info button explains '
      'the bin', (tester) async {
    await stageConversation(
      tester,
      'c1',
      'Weekly notes',
      extra: {'assistant_id': 'assistant-x'},
      messageCount: 2,
    );

    await pumpPage(tester);
    await pumpUntilFound(tester, find.text('Weekly notes'));

    await tester.tap(find.text('Weekly notes'));
    await pumpUntilFound(tester, find.text('Contents'));
    expect(find.text('Identity'), findsOneWidget);
    // The staged rows, as the JSON a restore would write.
    String? selectableContaining(String needle) {
      for (final widget in find.byType(SelectableText).evaluate()) {
        final text = widget.widget as SelectableText;
        final data = text.data ?? text.textSpan?.toPlainText() ?? '';
        if (data.contains(needle)) return data;
      }
      return null;
    }

    expect(selectableContaining('c1'), isNotNull);
    expect(selectableContaining('"conversation_rows"'), isNotNull);
    expect(selectableContaining('"message_rows"'), isNotNull);
    expect(find.text('2 rows'), findsOneWidget);
    expect(find.text('Copy JSON'), findsOneWidget);

    // Popping by hand: the app draws its own back affordance (a Lucide arrow,
    // not a Material BackButton), so the icon is the only way to tap it and the
    // list underneath offers one too.
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('About the recycle bin').first);
    await pumpUntilFound(tester, find.text('Got it'));
    expect(find.textContaining('never syncs'), findsOneWidget);
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
  });

  testWidgets('restoring an entry retires it and empties the bin', (
    tester,
  ) async {
    await stageConversation(tester, 'c1', 'Weekly notes');
    await pumpPage(tester);
    await pumpUntilFound(tester, find.text('Weekly notes'));

    await tester.tap(find.byTooltip('Restore'));
    await pumpUntilFound(tester, find.text('Nothing in the bin'));

    await pumpUntilBinSize(tester, 0);
    final restored = await tester.runAsync(
      () => database
          .customSelect("SELECT title FROM conversation_rows WHERE id = 'c1';")
          .getSingleOrNull(),
    );
    expect(restored?.read<String>('title'), 'Weekly notes');

    await drainSnackBar(tester);
  });

  testWidgets('a permanent delete asks first, then removes only that entry', (
    tester,
  ) async {
    await stageConversation(tester, 'c1', 'Weekly notes');
    await stageConversation(
      tester,
      'c2',
      'Older notes',
      origin: RecycleOrigin.local,
    );
    await pumpPage(tester);
    await pumpUntilFound(tester, find.text('Weekly notes'));
    expect(find.text('Conversation · Deleted here'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete permanently').first);
    await pumpUntilFound(tester, find.textContaining('This entry will be'));

    // Backing out leaves the entry alone.
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    await pumpUntilBinSize(tester, 2);

    await tester.tap(find.byTooltip('Delete permanently').first);
    await pumpUntilFound(tester, find.textContaining('This entry will be'));
    await tester.tap(find.widgetWithText(TextButton, 'Delete permanently'));
    await tester.pumpAndSettle();
    await pumpUntilBinSize(tester, 1);
  });
}
