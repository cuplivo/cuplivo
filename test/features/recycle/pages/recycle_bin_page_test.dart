import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/services/recycle/recycle_service.dart';
import 'package:Cuplivo/features/recycle/pages/recycle_bin_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// A bin whose folder cannot be read at all.
///
/// The one failure a page cannot see coming: every per-entry problem is handled
/// inside the store, so the store failing as a whole is what would reach the
/// page's own load. Simulated rather than provoked on disk, because a directory
/// that refuses to list is a platform question this test is not about.
class _UnreadableStore extends RecycleStore {
  _UnreadableStore({required super.directory});

  @override
  Future<int> evict({String? keepId, DateTime? now}) async =>
      throw const FileSystemException('the bin cannot be read');

  @override
  Future<List<RecycleEntry>> list() async =>
      throw const FileSystemException('the bin cannot be read');
}

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

  /// How many `runAsync` windows a wait may take before it is a failure.
  ///
  /// What is being waited on is real filesystem IO, which only progresses inside
  /// a `runAsync` window, and `flutter test` runs one isolate per file in
  /// parallel — so a loaded machine stretches the same number of windows into a
  /// much longer wall clock. This is a budget, not a delay: a wait that converges
  /// returns on the iteration it converges.
  const int waitWindows = 600;

  /// Waits for something the page only draws once its real file reads land.
  ///
  /// Every await on a real path costs one scheduler window here, and the page
  /// reads one entry file per staged entry, so the budget has to scale with the
  /// amount of staged data rather than with the number of frames.
  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    for (
      var attempt = 0;
      attempt < waitWindows && finder.evaluate().isEmpty;
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
      attempt < waitWindows && finder.evaluate().isNotEmpty;
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
    for (var attempt = 0; attempt < waitWindows; attempt++) {
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

  /// Waits for the toast a restore shows and hands back everything queued.
  ///
  /// Polled in 5 ms steps on purpose: the manager's list is real state, but the
  /// toast's auto-dismiss timer runs on the tester's fake clock, so a wait that
  /// spends seconds of fake time watches the toast it is waiting for disappear.
  Future<List<AppNotification>> pumpUntilToasts(WidgetTester tester) async {
    for (var attempt = 0; attempt < 400; attempt++) {
      final toasts = AppSnackBarManager().activeToasts;
      if (toasts.isNotEmpty) {
        return [for (final entry in toasts) entry.notification];
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 5));
    }
    fail('no toast appeared');
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
    RecycleGroup? group,
  }) => tester.runAsync(
    () => store.stageRows(
      type: RecycleEntryType.businessEntity,
      origin: RecycleOrigin.local,
      reason: RecycleReason.deleted,
      key: id,
      title: title,
      kindWire: kindWire,
      group: group,
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
    // The assistant is part of the same event, staged last because the list
    // write is what removes its row.
    await stageEntity(tester, 'a1', 'Delete Me', group: group);

    await pumpPage(tester);
    // Newest first: the assistant's own entry is the last staged, and the
    // conversations follow it, so 'Third' is the row the viewport builds.
    await pumpUntilFound(tester, find.text('Third'));

    // One header for the group, naming the assistant and counting the
    // conversations — the assistant's own entry is not a conversation, so it
    // must not inflate the number the label promises.
    expect(
      find.text('3 conversations deleted together with “Delete Me”'),
      findsOneWidget,
    );
    expect(find.text('Restore all'), findsOneWidget);

    await tester.tap(find.text('Restore all'));
    // One report for the act. The page used to loop the single-entry action,
    // which queued one toast per conversation and then a summary on top of them
    // — three conversations meant four toasts.
    final toasts = await pumpUntilToasts(tester);
    expect(toasts, hasLength(1));
    await pumpUntilBinSize(tester, 0);
    await pumpUntilGone(tester, find.text('Restore all'));

    // "Restore all" is the whole event: the assistant the header names comes
    // back with the conversations that name it, and the bin is empty.
    final restored = await tester.runAsync(() async {
      final conversations = await database
          .customSelect('SELECT COUNT(*) AS n FROM conversation_rows;')
          .getSingle();
      final assistants = await database
          .customSelect(
            "SELECT COUNT(*) AS n FROM assistant_rows WHERE id = 'a1';",
          )
          .getSingle();
      return (
        conversations: conversations.read<int>('n'),
        assistants: assistants.read<int>('n'),
      );
    });
    expect(restored?.conversations, 3);
    expect(
      restored?.assistants,
      1,
      reason: 'the row the header names is part of the act it offers',
    );

    await drainSnackBar(tester);
  });

  testWidgets('the assistants tab shows a cascade group as a plain card', (
    tester,
  ) async {
    // A group header names conversations and offers to restore the event. In the
    // Assistants tab the conversations are filtered out, so drawing the header
    // there would describe a list the tab does not show ("1 conversations…");
    // the assistant is the whole of what is visible and gets its own card.
    final group = RecycleGroup(id: 'g1', label: 'Delete Me');
    await stageConversation(tester, 'c1', 'First', group: group);
    await stageEntity(tester, 'a1', 'Delete Me', group: group);

    await pumpPage(tester);
    await pumpUntilFound(tester, find.text('Delete Me'));
    await tester.tap(find.text('Assistants'));
    await tester.pumpAndSettle();

    expect(find.text('Delete Me'), findsOneWidget);
    expect(find.textContaining('deleted together with'), findsNothing);
  });

  testWidgets('a group restore says what could not be restored', (
    tester,
  ) async {
    final group = RecycleGroup(id: 'g1', label: 'Delete Me');
    await stageConversation(tester, 'c1', 'First', group: group);
    await stageConversation(tester, 'c2', 'Second', group: group);
    // A damaged copy in the same group: `restore` reports `unreadable` and the
    // entry stays in the bin. It is not "already back", and saying so would be a
    // lie about a recovery that did not happen.
    final broken = await tester.runAsync(
      () => store.stageRows(
        type: RecycleEntryType.conversation,
        origin: RecycleOrigin.local,
        reason: RecycleReason.deleted,
        key: 'broken',
        title: 'Broken',
        group: group,
        tables: {
          'conversation_rows': [
            {
              'id': 'broken',
              'title': 'Broken',
              'created_at': 1,
              'updated_at': 1,
            },
          ],
        },
      ),
    );
    // Written through `runAsync`: real file I/O does not progress on the widget
    // tester's fake clock, and a body that is still valid would restore cleanly.
    await tester.runAsync(
      () => File(
        '${binRoot.path}/${broken!.id}/body.json',
      ).writeAsString('{ not json'),
    );

    await pumpPage(tester);
    await pumpUntilFound(tester, find.text('Broken'));

    await tester.tap(find.text('Restore all'));

    final toasts = await pumpUntilToasts(tester);
    expect(toasts, hasLength(1));
    expect(
      toasts.single.message,
      'Restored 2, 1 could not be restored',
      reason: 'a copy that could not be restored is not "already back"',
    );

    // The damaged entry stays in the bin: it was not restored, so it was not
    // retired either.
    await pumpUntilBinSize(tester, 1);
    await drainSnackBar(tester);
  });

  testWidgets('an entry a merge replaced says so, not "Deleted"', (
    tester,
  ) async {
    await tester.runAsync(
      () => store.stageRows(
        type: RecycleEntryType.preference,
        origin: RecycleOrigin.remote,
        reason: RecycleReason.overwritten,
        key: 'user_name',
        title: 'user_name',
        tables: {
          'preference_rows': [
            {'key': 'user_name', 'value': '"Mine"', 'updated_at': 1},
          ],
        },
      ),
    );

    await pumpPage(tester);
    await pumpUntilFound(tester, find.text('user_name'));
    await tester.tap(find.text('user_name'));
    await pumpUntilFound(tester, find.text('Contents'));

    // Nothing was deleted: the row two fields up says it was replaced, and the
    // date under this label is when that happened.
    expect(find.text('Replaced'), findsOneWidget);
    expect(find.text('Deleted'), findsNothing);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
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

  testWidgets('a bin that cannot be read lands on the empty state', (
    tester,
  ) async {
    // A recovery feature is opened exactly when something has gone wrong, so the
    // page must not have a state it cannot leave. The bin is a folder on disk and
    // reading it can fail; the load has to absorb that instead of leaving
    // `_loading` true, where nothing but the back button resolves it.
    service = RecycleService(
      database,
      store: _UnreadableStore(directory: () async => binRoot),
    );

    await pumpPage(tester);
    await pumpUntilFound(tester, find.text('Nothing in the bin'));
    expect(find.byType(CircularProgressIndicator), findsNothing);
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
