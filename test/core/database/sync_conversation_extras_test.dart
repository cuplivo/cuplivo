import 'dart:convert';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/tool_permission_mode.dart';
import 'package:Cuplivo/core/models/workspace_binding.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// A grant says *this device* approved, so it is not a thing that travels.
///
/// Both keys live in the conversation row's `extras_json`, which the wire carries
/// as one column under whole-row LWW. Without a rule, pressing "full access for
/// this conversation" on one device turns into automatic approval on the other,
/// and a peer's rename — which rewrites the same column — erases the grant here.
/// The rule therefore has two halves, and a test proves each one separately:
/// the wire read strips the keys, the applier merges them back from the local row.
void main() {
  late AppDatabase database;
  late ChatDatabaseRepository repository;
  const conversationId = 'conv';

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    repository = ChatDatabaseRepository(database);
    await repository.ensureReady();
  });

  tearDown(() => database.close());

  /// A wire row carries every column of `currentSchemaColumns` except the ones
  /// that never travel — the same shape `syncReadWireConversationRow` produces.
  Map<String, dynamic> wireConversationRow({
    required String id,
    required int updatedAtUs,
    Object? extras = '{}',
  }) => {
    'id': id,
    'title': id,
    'created_at': 1000,
    'updated_at': updatedAtUs,
    'is_pinned': 0,
    'assistant_id': null,
    'truncate_index': 0,
    'version_selections_json': '{}',
    'summary': null,
    'last_summarized_message_count': 0,
    'chat_suggestions_json': '[]',
    'last_memory_extracted_order': -1,
    'chat_model_provider': null,
    'chat_model_id': null,
    'extras_json': extras,
  };

  Future<void> seedLocal({
    Map<String, dynamic> extras = const {},
    int updatedAtUs = 1000,
  }) async {
    await database.customStatement(
      'INSERT INTO conversation_rows (id, title, created_at, updated_at, '
      'extras_json) VALUES (?, ?, ?, ?, ?);',
      [conversationId, conversationId, 1000, updatedAtUs, jsonEncode(extras)],
    );
  }

  Future<Map<String, dynamic>> readRow([String id = conversationId]) async {
    final rows = await database
        .customSelect(
          'SELECT extras_json, updated_at FROM conversation_rows WHERE id = ?;',
          variables: [Variable.withString(id)],
        )
        .get();
    final row = rows.single;
    return {
      'extras': jsonDecode(row.read<String>('extras_json')) as Map,
      'updated_at': row.read<int>('updated_at'),
    };
  }

  Future<Map<String, dynamic>> apply({
    required int updatedAtUs,
    Object? extras = '{}',
    String id = conversationId,
  }) async {
    await repository.syncApplySubtree(
      payload: SyncSubtreePayload(
        conversation: wireConversationRow(
          id: id,
          updatedAtUs: updatedAtUs,
          extras: extras,
        ),
        families: const {},
      ),
      myDeviceId: 'me',
      peerDeviceId: 'peer',
      checkpointRows: const {},
    );
    return readRow(id);
  }

  Future<Map<String, dynamic>> wireExtras() async {
    final wire = await repository.syncReadWireConversationRow(conversationId);
    return jsonDecode(wire!['extras_json'] as String) as Map<String, dynamic>;
  }

  // One list, three readers: the sync halves and the backup sanitizer strip the
  // grant keys, and nothing else. The backup half of this claim is asserted in
  // `backup_portability_test.dart`.
  test('the device-local extras set is the grants and nothing else', () {
    expect(ChatDatabaseRepository.syncLocalExtrasKeys, {
      ...ToolPermissionMode.grantExtrasKeys,
    });
    // `workspace.cwd` sits beside them in the bag but is a *workspace-relative*
    // folder — the picker validates it as one and it resolves against the
    // workspace root — so the peer's tools must land in the same folder. It
    // travels; it is not a grant.
    expect(
      ChatDatabaseRepository.syncLocalExtrasKeys,
      isNot(contains(WorkspaceBinding.keyCwd)),
    );
  });

  test('the wire row carries no grant, and the folder still travels', () async {
    await seedLocal(
      extras: {
        'tools.permission_mode': 'fullAccess',
        'workspace.allowAll': true,
        'workspace.cwd': 'src',
        'workspace.id': 'w1',
        'other.feature': 'keep',
      },
    );

    final extras = await wireExtras();
    expect(extras, isNot(contains('tools.permission_mode')));
    expect(extras, isNot(contains('workspace.allowAll')));
    // `workspace.id` names a row that does sync, and `workspace.cwd` is the
    // folder inside it: both travel.
    expect(extras['workspace.id'], 'w1');
    expect(extras['workspace.cwd'], 'src');
    expect(extras['other.feature'], 'keep');
  });

  test('a bag holding only a grant travels as an empty object', () async {
    await seedLocal(extras: {'tools.permission_mode': 'fullAccess'});
    expect(await wireExtras(), isEmpty);
  });

  test('a peer row that wins the conversation keeps the local grant', () async {
    await seedLocal(
      extras: {
        'tools.permission_mode': 'fullAccess',
        'workspace.allowAll': true,
        'workspace.cwd': 'mine',
        'workspace.id': 'w1',
      },
    );

    final row = await apply(
      updatedAtUs: 2000,
      extras: jsonEncode({
        'workspace.id': 'w1',
        'workspace.cwd': 'theirs',
        'peer.feature': true,
      }),
    );

    final extras = row['extras'] as Map;
    // The grant is still this device's.
    expect(extras['tools.permission_mode'], 'fullAccess');
    expect(extras['workspace.allowAll'], true);
    // The folder is shared state, so the winner's folder is the one that counts.
    expect(extras['workspace.cwd'], 'theirs');
    // And the rest of the bag followed the winner, key by key.
    expect(extras['peer.feature'], true);
    // The winner's clock is what both peers compare next session.
    expect(row['updated_at'], 2000);
  });

  test('a peer that still sends its grant does not hand it over', () async {
    await seedLocal(extras: {'workspace.id': 'w1'});

    final row = await apply(
      updatedAtUs: 2000,
      extras: jsonEncode({
        'workspace.id': 'w1',
        'tools.permission_mode': 'fullAccess',
        'workspace.allowAll': true,
        'workspace.cwd': 'elsewhere',
      }),
    );

    final extras = row['extras'] as Map;
    expect(extras, isNot(contains('tools.permission_mode')));
    expect(extras, isNot(contains('workspace.allowAll')));
    expect(extras['workspace.id'], 'w1');
    // The folder is not a grant, so it arrives with the row.
    expect(extras['workspace.cwd'], 'elsewhere');
  });

  test('a conversation arriving from a peer arrives without a grant', () async {
    final row = await apply(
      updatedAtUs: 2000,
      id: 'fresh',
      extras: jsonEncode({
        'workspace.id': 'w1',
        'tools.permission_mode': 'fullAccess',
        'workspace.allowAll': true,
        'workspace.cwd': 'src',
        'peer.feature': true,
      }),
    );

    final extras = row['extras'] as Map;
    expect(extras, isNot(contains('tools.permission_mode')));
    expect(extras, isNot(contains('workspace.allowAll')));
    expect(extras['workspace.id'], 'w1');
    expect(extras['workspace.cwd'], 'src');
    expect(extras['peer.feature'], true);
  });

  test('a rebind does not carry the grant over', () async {
    // A grant is issued against the conversation *and* its binding: writing a
    // new binding clears it on this device, so a rebind arriving from a peer
    // must not restore it. The folder follows the winner, so the old binding's
    // folder goes with the old binding.
    await seedLocal(
      extras: {
        'workspace.id': 'w1',
        'workspace.cwd': 'old',
        'tools.permission_mode': 'fullAccess',
      },
    );

    final row = await apply(
      updatedAtUs: 2000,
      extras: jsonEncode({'workspace.id': 'w2', 'peer.feature': true}),
    );

    final extras = row['extras'] as Map;
    expect(extras['workspace.id'], 'w2');
    expect(extras, isNot(contains('tools.permission_mode')));
    expect(extras, isNot(contains('workspace.cwd')));
  });

  test('an unreadable peer bag leaves the local one alone', () async {
    await seedLocal(
      extras: {
        'tools.permission_mode': 'fullAccess',
        'workspace.cwd': '/tmp/mine',
        'keep.me': 1,
      },
    );

    final row = await apply(updatedAtUs: 2000, extras: 'not-json');

    final extras = row['extras'] as Map;
    expect(extras['tools.permission_mode'], 'fullAccess');
    expect(extras['workspace.cwd'], '/tmp/mine');
    expect(extras['keep.me'], 1);
  });

  test('a key that merely starts like a grant key still travels', () async {
    // Stripping is by equality: a future feature may name a key in the same
    // namespace, and a prefix rule would take it out of the bag silently.
    await seedLocal(
      extras: {
        'workspace.id': 'w1',
        'tools.permission_mode.extra': 'fullAccess',
      },
    );
    final extras = await wireExtras();
    expect(extras['tools.permission_mode.extra'], 'fullAccess');
  });

  test('the folder reaches the peer, and both digests still agree', () async {
    // `workspace.cwd` is a workspace-*relative* folder — the picker validates it
    // as one, `WorkspacePaths.normalizeCwd` resolves it against the workspace
    // root — so the peer must receive it: without it the conversation's tools
    // resolve against the workspace root there while they resolve against `src`
    // here. Two real databases and the real wire read, so the rule is held end
    // to end rather than through a helper.
    await seedLocal(
      extras: {
        'workspace.id': 'w1',
        'workspace.cwd': 'src',
        'tools.permission_mode': 'fullAccess',
      },
    );

    final peerDatabase = AppDatabase(NativeDatabase.memory());
    final peer = ChatDatabaseRepository(peerDatabase);
    await peer.ensureReady();
    try {
      final wire = await repository.syncReadWireConversationRow(conversationId);
      expect(wire, isNotNull);
      await peer.syncApplySubtree(
        payload: SyncSubtreePayload(conversation: wire!, families: const {}),
        myDeviceId: 'peer',
        peerDeviceId: 'me',
        checkpointRows: const {},
      );

      final peerExtras =
          jsonDecode(
                (await peer.syncReadConversationRow(
                      conversationId,
                    ))!['extras_json']
                    as String,
              )
              as Map<String, dynamic>;
      final peerBinding = WorkspaceBinding.fromExtras(peerExtras);
      expect(peerBinding.workspaceId, 'w1');
      expect(peerBinding.cwd, 'src');
      expect(
        peerExtras.keys,
        isNot(anyElement(isIn(ToolPermissionMode.grantExtrasKeys))),
      );

      // The extras are device-local, so a key only one device holds must not
      // move the identity either: the strip cannot start a re-push loop.
      expect(
        await peer.syncConversationDigest(conversationId),
        await repository.syncConversationDigest(conversationId),
      );
    } finally {
      await peerDatabase.close();
    }
  });
}
