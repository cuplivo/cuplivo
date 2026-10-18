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

  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    for (
      var attempt = 0;
      attempt < 40 && finder.evaluate().isEmpty;
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
    for (var attempt = 0; attempt < 40; attempt++) {
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
  }) => tester.runAsync(
    () => store.stageRows(
      type: RecycleEntryType.conversation,
      origin: origin,
      reason: RecycleReason.deleted,
      key: id,
      title: title,
      tables: {
        'conversation_rows': [
          {'id': id, 'title': title, 'created_at': 1, 'updated_at': 1},
        ],
      },
    ),
  );

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
