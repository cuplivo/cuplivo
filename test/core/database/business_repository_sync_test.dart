import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The business sync section at repository level: manifest refs, LWW apply and
/// the guarantees the engine relies on (the peer's clock is preserved, an older
/// row never overwrites a newer one, unknown kinds are inert).
void main() {
  late AppDatabase database;
  late BusinessRepository repository;
  late BusinessPreferences preferences;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    repository = BusinessRepository(database);
    preferences = BusinessPreferences(repository);
    await preferences.load();
  });

  tearDown(() => database.close());

  Future<void> setAssistants(
    List<({String id, String name})> list,
  ) => preferences.setString(
    'assistants_v1',
    '[${[for (final item in list) '{"id":"${item.id}","name":"${item.name}"}'].join(',')}]',
  );

  test('refs cover entity rows and only synced preferences', () async {
    await setAssistants([(id: 'a1', name: 'One')]);
    await preferences.setString('user_name', 'Alice');
    await preferences.setString('current_assistant_id_v1', 'a1');

    final entityRefs = await repository.syncEntityRefs();
    expect(
      entityRefs
          .where((ref) => ref.kindWire == 'assistant_rows')
          .map((r) => r.id),
      contains('a1'),
    );
    expect(entityRefs.every((ref) => ref.updatedAtUs > 0), isTrue);

    final preferenceRefs = await repository.syncPreferenceRefs();
    expect(preferenceRefs.map((ref) => ref.key), contains('user_name'));
    expect(
      preferenceRefs.map((ref) => ref.key),
      isNot(contains('current_assistant_id_v1')),
      reason: 'device-local keys never reach the wire',
    );
  });

  test('a sync read returns only registry-synced preferences', () async {
    // The read answers fetch requests whose key list arrives from the wire;
    // a peer naming a device-local (or unclassified) key must not have its
    // value handed back, exactly as the manifest never advertises it.
    await preferences.setString('user_name', 'Alice');
    await preferences.setString('current_assistant_id_v1', 'a1');

    final rows = await repository.syncReadPreferenceRows({
      'user_name',
      'current_assistant_id_v1',
      'never_classified_key_v9',
    });

    expect(rows.map((row) => row['key']), ['user_name']);
    expect(rows.single['value'] as String, contains('Alice'));
  });

  test('an applied row keeps the peer clock and older rows never win', () async {
    await setAssistants([(id: 'a1', name: 'Mine')]);
    final mine = (await repository.readEntities(
      BusinessEntityKind.assistant,
    )).single;
    final mineAt = (await repository.syncEntityRefs())
        .firstWhere((ref) => ref.id == 'a1')
        .updatedAtUs;

    // An older row from the peer loses...
    await repository.syncApplyBusinessRows(
      entities: {
        'assistant_rows': [
          {
            'id': 'a1',
            'sort_order': 0,
            'payload': '{"id":"a1","name":"Older peer"}',
            'updated_at': mineAt - 1000,
          },
        ],
      },
      preferences: const [],
      myDeviceId: 'me',
      peerDeviceId: 'peer',
    );
    expect(
      (await repository.readEntities(
        BusinessEntityKind.assistant,
      )).single.payload,
      mine.payload,
    );

    // ...a newer one wins, and carries the peer's timestamp rather than a fresh
    // local one — that clock is what the next session compares against.
    final peerAt = mineAt + 5000;
    final outcome = await repository.syncApplyBusinessRows(
      entities: {
        'assistant_rows': [
          {
            'id': 'a1',
            'sort_order': 0,
            'payload': '{"id":"a1","name":"Newer peer"}',
            'updated_at': peerAt,
          },
        ],
      },
      preferences: const [],
      myDeviceId: 'me',
      peerDeviceId: 'peer',
    );
    expect(outcome.entityRowsWritten, 1);
    expect(outcome.changed, isTrue);
    final applied = (await repository.readEntities(
      BusinessEntityKind.assistant,
    )).single;
    expect(applied.payload, contains('Newer peer'));
    final appliedAt = (await repository.syncEntityRefs())
        .firstWhere((ref) => ref.id == 'a1')
        .updatedAtUs;
    expect(appliedAt, peerAt);
  });

  test('a loss is counted only when the local content changes', () async {
    await setAssistants([(id: 'a1', name: 'Mine')]);
    await preferences.setString('user_name', 'Mine');
    final mineAt = (await repository.syncEntityRefs())
        .firstWhere((ref) => ref.id == 'a1')
        .updatedAtUs;
    final minePrefAt = (await repository.syncPreferenceRefs())
        .firstWhere((ref) => ref.key == 'user_name')
        .updatedAtUs;

    // The bothSend echo: this device's own row comes back at a tied clock
    // (deviceId `peer` wins the tie). It is written — adopting the peer's clock
    // is what makes the next session's digests agree — but the content is
    // unchanged, so calling it a lost edit would be false.
    final echo = await repository.syncApplyBusinessRows(
      entities: {
        'assistant_rows': [
          {
            'id': 'a1',
            'sort_order': 0,
            'payload': '{"id":"a1","name":"Mine"}',
            'updated_at': mineAt,
          },
        ],
      },
      preferences: [
        // Preference values travel JSON-encoded, exactly as they are stored.
        {'key': 'user_name', 'value': '"Mine"', 'updated_at': minePrefAt},
      ],
      myDeviceId: 'me',
      peerDeviceId: 'peer',
    );
    expect(echo.entityRowsWritten, 1, reason: 'the clock is still adopted');
    expect(echo.entityRowsLost, 0);
    expect(echo.preferencesLost, 0);

    // A different row at the same tied clock does replace the local content,
    // and that is the case the report has to name.
    final replaced = await repository.syncApplyBusinessRows(
      entities: {
        'assistant_rows': [
          {
            'id': 'a1',
            'sort_order': 0,
            'payload': '{"id":"a1","name":"Peer"}',
            'updated_at': mineAt,
          },
        ],
      },
      preferences: [
        {'key': 'user_name', 'value': '"Peer"', 'updated_at': minePrefAt},
      ],
      myDeviceId: 'me',
      peerDeviceId: 'peer',
    );
    expect(replaced.entityRowsLost, 1);
    expect(replaced.preferencesLost, 1);
  });

  test('a preference is applied and deleted through the same rules', () async {
    await repository.syncApplyBusinessRows(
      entities: const {},
      preferences: [
        {'key': 'user_name', 'value': '"Alice"', 'updated_at': 5000},
      ],
      myDeviceId: 'me',
      peerDeviceId: 'peer',
    );
    expect((await repository.syncPreferenceRefs()).single.key, 'user_name');

    // A device-local key cannot be pushed in, even by a peer.
    final ignored = await repository.syncApplyBusinessRows(
      entities: const {},
      preferences: [
        {
          'key': 'current_assistant_id_v1',
          'value': '"injected"',
          'updated_at': 9000,
        },
      ],
      myDeviceId: 'me',
      peerDeviceId: 'peer',
    );
    expect(ignored.preferencesWritten, 0);
    expect(await repository.getPreference('current_assistant_id_v1'), isNull);

    expect(await repository.syncDeletePreference('user_name'), isTrue);
    expect(await repository.getPreference('user_name'), isNull);
    // A device-local key is not deletable through the sync path either.
    expect(
      await repository.syncDeletePreference('current_assistant_id_v1'),
      isFalse,
    );
  });

  test('unknown kinds and rows without an id are inert', () async {
    final outcome = await repository.syncApplyBusinessRows(
      entities: {
        'future_rows': [
          {'id': 'x', 'payload': '{}', 'updated_at': 1},
        ],
        'assistant_rows': [
          {'sort_order': 0, 'payload': '{}', 'updated_at': 1},
        ],
      },
      preferences: const [],
      myDeviceId: 'me',
      peerDeviceId: 'peer',
    );
    expect(outcome.entityRowsWritten, 0);
    expect(outcome.changed, isFalse);
  });

  test('the reload picks up writes that bypassed the view', () async {
    await preferences.setString('user_name', 'Local');
    await repository.syncApplyBusinessRows(
      entities: const {},
      preferences: [
        {'key': 'theme_mode_v1', 'value': '"dark"', 'updated_at': 10},
      ],
      myDeviceId: 'me',
      peerDeviceId: 'peer',
    );
    // Written straight to the repository: the in-memory view does not know yet.
    expect(preferences.getString('theme_mode_v1'), isNull);
    await preferences.reload();
    expect(preferences.getString('theme_mode_v1'), 'dark');
    expect(preferences.getString('user_name'), 'Local');
  });
}
