// The switch's two awkward moments, both about what gets *persisted*: a read
// that answers after the user has already chosen, and a write that fails. A
// hold that is lost is a server that syncs on the next round — the stdio command
// on the other device, which is the defect the switch exists for.

import 'dart:async';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/providers/sync_provider.dart';
import 'package:Cuplivo/core/services/business_state_reloader.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/mcp/widgets/mcp_local_only_form.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _key = 'mcp_server_rows\u0000m1';

void main() {
  // The toast queue is one instance per file, so a failure that skips the
  // in-body drain must not reach the next test.
  setUp(AppSnackBarManager().dismissAll);
  tearDown(AppSnackBarManager().dismissAll);

  testWidgets('a read that answers after the toggle keeps the answer', (
    tester,
  ) async {
    final sync = _FakeSyncProvider();
    addTearDown(sync.dispose);
    await _pumpHost(tester, sync);
    expect(find.text('held=false'), findsOneWidget);

    // The user chooses while the file read is still in flight.
    await tester.tap(find.text('hold'));
    await tester.pump();
    expect(find.text('held=true'), findsOneWidget);

    // The file's answer — "nothing held" — arrives afterwards.
    sync.answer(const <String>{});
    await tester.pump();
    expect(
      find.text('held=true'),
      findsOneWidget,
      reason: 'the user answered first; the file is the stale one',
    );

    await tester.tap(find.text('save'));
    await tester.pump();
    expect(
      sync.written[_key],
      isTrue,
      reason: 'saving the switch must write what the user chose, not the file',
    );
  });

  testWidgets('a hold the disk refused is said out loud', (tester) async {
    final sync = _FakeSyncProvider(failWrites: true);
    addTearDown(sync.dispose);
    await _pumpHost(tester, sync);
    sync.answer({_key});
    await tester.pump();

    // The row is held; the user releases it and the write fails.
    await tester.tap(find.text('save'));
    await tester.pump();
    expect(
      AppSnackBarManager().activeToasts.single.notification.message,
      'Saved, but this server could not be held on this device.',
      reason: 'a hold that did not persist has to be named, not swallowed',
    );

    // Drain the toast's own timer so the test does not end on it.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}

Future<void> _pumpHost(WidgetTester tester, SyncProvider sync) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<SyncProvider>.value(
      value: sync,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const _Host(),
      ),
    ),
  );
}

/// Drives the mixin directly: the same code both edit forms use, without either
/// form's layout in the way.
class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with McpLocalOnlyForm {
  @override
  void initState() {
    super.initState();
    attachLocalOnly('m1');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text('held=$localOnlyHeld'),
        TextButton(
          onPressed: () => setLocalOnlyHeld(true),
          child: const Text('hold'),
        ),
        TextButton(
          onPressed: () => saveLocalOnly('m1'),
          child: const Text('save'),
        ),
      ],
    ),
  );
}

class _FakeSyncProvider extends SyncProvider {
  _FakeSyncProvider({this.failWrites = false})
    : super(
        chatService: ChatService(),
        repository: ChatDatabaseRepository(_database),
        businessRepository: BusinessRepository(_database),
        businessPreferences: BusinessPreferences(BusinessRepository(_database)),
        reloader: BusinessStateReloader(
          BusinessPreferences(BusinessRepository(_database)),
        ),
        syncDirectory: () async => throw UnimplementedError('no store'),
      );

  /// Whether [setLocalOnly] refuses, the way a store that cannot be opened does.
  final bool failWrites;

  /// The read the form started; the test decides when and with what it answers.
  final Completer<Set<String>> _read = Completer<Set<String>>();

  /// Every write the form attempted, by key.
  final Map<String, bool> written = {};

  void answer(Set<String> held) => _read.complete(held);

  @override
  Future<Set<String>> readLocalOnlyKeys() => _read.future;

  @override
  Future<bool> setLocalOnly(String key, bool hold) async {
    written[key] = hold;
    if (failWrites) throw const FileSystemException('no store');
    return true;
  }
}

final AppDatabase _database = AppDatabase(NativeDatabase.memory());
