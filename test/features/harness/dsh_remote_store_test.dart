import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/models/dsh_remote.dart';
import 'package:Cuplivo/features/harness/services/dsh_remote_store.dart';

import '../../support/business_test_harness.dart';

/// The connection records are one JSON blob in `BusinessPreferences`; a
/// restart must show the same remotes, and a corrupt row must be dropped
/// rather than empty the list.
void main() {
  DshRemote remote({String id = 'r1', String name = 'Studio'}) {
    return DshRemote(
      id: id,
      name: name,
      baseUrl: 'http://192.168.1.20:3080',
      authority: '192.168.1.20:3080',
      secure: false,
      createdAt: DateTime.utc(2026, 11, 19, 10),
      lastConnectedAt: DateTime.utc(2026, 11, 19, 11),
      lastError: 'auth',
    );
  }

  test('a record round-trips through a second store', () async {
    final harness = await createBusinessTestHarness();
    final store = DshRemoteStore(harness.preferences);
    final original = remote();

    await store.add(original);

    // A fresh provider/store over the same preferences is what a restart does.
    final reopened = DshRemoteStore(harness.preferences);
    final all = await reopened.getAll();
    expect(all, hasLength(1));
    expect(all.single, original);
  });

  test('update replaces one row and remove takes it away', () async {
    final harness = await createBusinessTestHarness();
    final store = DshRemoteStore(harness.preferences);
    await store.add(remote());
    await store.add(remote(id: 'r2', name: 'Lab'));

    await store.update(remote(name: 'Studio 2', id: 'r2'));
    var all = await store.getAll();
    expect(all.map((item) => item.name), ['Studio', 'Studio 2']);

    await store.remove('r1');
    all = await store.getAll();
    expect(all.map((item) => item.id), ['r2']);
  });

  test('a row without id or origin is dropped', () async {
    final harness = await createBusinessTestHarness(
      initial: {
        DshRemoteStore.remotesKey: jsonEncode([
          {
            'id': '',
            'name': 'broken',
            'baseUrl': 'http://host:1',
            'authority': 'host:1',
            'secure': false,
            'createdAt': '2026-11-19T10:00:00Z',
          },
          {
            'id': 'ok',
            'name': 'ok',
            'baseUrl': 'http://host:2',
            'authority': 'host:2',
            'secure': false,
            'createdAt': '2026-11-19T10:00:00Z',
          },
        ]),
      },
    );
    final all = await DshRemoteStore(harness.preferences).getAll();
    expect(all.map((item) => item.id), ['ok']);
  });
}
