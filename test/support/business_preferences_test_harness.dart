import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/services/recycle/recycle_service.dart';
import 'package:drift/native.dart';

final class BusinessPreferencesTestHarness {
  BusinessPreferencesTestHarness._(this.directory, this.file);

  final Directory directory;
  final File file;
  final List<BusinessPreferencesTestSession> _sessions =
      <BusinessPreferencesTestSession>[];

  static Future<BusinessPreferencesTestHarness> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'kelivo_business_preferences_test_',
    );
    return BusinessPreferencesTestHarness._(
      directory,
      File('${directory.path}/kelivo.db'),
    );
  }

  /// Opens one session over the harness's database file.
  ///
  /// [recycle] is opt-in, exactly as the gateway's `recycleFactory` is: the
  /// default session stages nothing, and only a test about the bin passes a
  /// service — which also owns the bin directory it writes to.
  Future<BusinessPreferencesTestSession> open({
    RecycleService Function(AppDatabase database)? recycle,
  }) async {
    final database = AppDatabase(NativeDatabase(file));
    final bin = recycle?.call(database);
    final preferences = BusinessPreferences(
      BusinessRepository(database, recycle: bin),
    );
    await preferences.load();
    final session = BusinessPreferencesTestSession._(
      database,
      preferences,
      bin,
    );
    _sessions.add(session);
    return session;
  }

  Future<void> dispose() async {
    for (final session in _sessions.reversed) {
      await session.close();
    }
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

final class BusinessPreferencesTestSession {
  BusinessPreferencesTestSession._(
    this.database,
    this.preferences,
    this.recycle,
  );

  final AppDatabase database;
  final BusinessPreferences preferences;

  /// The bin this session's repository stages into, when [open] was given one.
  /// A test that asserts what the bin holds settles it first: the write is
  /// detached from the operation that fed it.
  final RecycleService? recycle;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await database.close();
  }
}
