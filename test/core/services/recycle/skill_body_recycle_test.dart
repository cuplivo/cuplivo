import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/recycle/recycle_service.dart';
import 'package:Cuplivo/core/services/skills/skill_directory_sync.dart';
import 'package:Cuplivo/core/services/skills/skills_service.dart';
import 'package:Cuplivo/core/services/sync/sync_data_plane.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A skill body through the recycle bin: the three places a body leaves this
/// device (the user's delete, a peer's delete, and the body a swap replaces)
/// all move it — with its record — into one entry, and every one of them comes
/// back whole.
///
/// The swap side of the plane is proved in
/// `test/core/services/skills/skill_body_lifecycle_test.dart`; what is tested
/// here is the way back, which is the half that used to be impossible: a peer's
/// deletion staged the record and destroyed the directory, so the entry it left
/// behind could only restore a skill with no body.
void main() {
  late Directory root;
  late Directory skillsDir;
  late Directory binDir;
  late AppDatabase database;
  late ExtensionEntityStore store;
  late RecycleService recycle;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cuplivo_skill_bin_');
    skillsDir = Directory(p.join(root.path, 'skills'));
    binDir = Directory(p.join(root.path, 'bin'));
    await skillsDir.create(recursive: true);
    database = AppDatabase(NativeDatabase.memory());
    store = ExtensionEntityStore(database);
    recycle = RecycleService(
      database,
      store: RecycleStore(directory: () async => binDir),
      skillsRoot: () async => skillsDir,
    );
  });

  tearDown(() async {
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> putSkill(
    String id, {
    Map<String, String> files = const {'SKILL.md': '# writer\n'},
    bool withRow = true,
    bool enabled = true,
  }) async {
    for (final entry in files.entries) {
      final file = File(p.join(skillsDir.path, id, entry.key));
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value, flush: true);
    }
    if (!withRow) return;
    await store.upsert(ExtensionEntityStore.kindSkill, id, {
      'id': id,
      'enabled': enabled,
      'useCount': 0,
      'source': 'file',
      'installedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
      'updatedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
    });
  }

  Future<String?> bodyHash(String id) =>
      SkillDirectorySync(skillsDir).hashOf(id);

  File bodyOf(String id, String relPath) =>
      File(p.join(skillsDir.path, id, relPath));

  test('a user delete moves the body and the record into one entry', () async {
    await putSkill('writer');
    final hash = await bodyHash('writer');
    final service = SkillsService(
      store: store,
      skillsDirectory: skillsDir,
      recycle: recycle,
    );
    addTearDown(service.dispose);
    await service.loaded;

    await service.delete('writer');

    expect(bodyOf('writer', 'SKILL.md').existsSync(), isFalse);
    expect(await store.get(ExtensionEntityStore.kindSkill, 'writer'), isNull);
    final entries = await recycle.list();
    expect(entries, hasLength(1));
    expect(entries.single.type, RecycleEntryType.skillBody);
    expect(entries.single.key, 'writer');

    expect(
      await recycle.restore(entries.single),
      RecycleRestoreOutcome.restored,
    );

    expect(await bodyOf('writer', 'SKILL.md').readAsString(), '# writer\n');
    expect(
      await store.get(ExtensionEntityStore.kindSkill, 'writer'),
      isNotNull,
    );
    expect(
      await bodyHash('writer'),
      hash,
      reason: 'the body comes back byte for byte, so the content clock agrees',
    );
    expect(await recycle.list(), isEmpty, reason: 'the entry is retired');
  });

  test(
    'a peer delete through the data plane is recoverable, body and all',
    () async {
      // The path that was broken: the engine deletes the row it sees missing on
      // the peer, and the row's directory went with it unrecorded.
      final repository = ChatDatabaseRepository(database, recycle: recycle);
      await repository.ensureReady();
      final businessRepository = BusinessRepository(database, recycle: recycle);
      // Deliberately not initialized: a business-row deletion touches no chat
      // state, and `init` reaches for the platform's app data directory, which a
      // pure service test has no business needing.
      final chatService = ChatService(existingRepository: repository);
      final plane = SyncDataPlane(
        repository: repository,
        chatService: chatService,
        businessRepository: businessRepository,
        skillDirectories: SkillDirectorySync(skillsDir),
        recycle: recycle,
      );
      await putSkill('writer');
      final hash = await bodyHash('writer');

      final outcome = await plane.deleteBusinessRow('skill', 'writer');

      expect(outcome.removed, isTrue);
      expect(bodyOf('writer', 'SKILL.md').existsSync(), isFalse);
      expect(await store.get(ExtensionEntityStore.kindSkill, 'writer'), isNull);
      final entries = await recycle.list();
      expect(
        entries,
        hasLength(1),
        reason: 'the row must not be staged on its own beside the body',
      );
      expect(entries.single.type, RecycleEntryType.skillBody);

      expect(
        await recycle.restore(entries.single),
        RecycleRestoreOutcome.restored,
      );

      expect(await bodyOf('writer', 'SKILL.md').readAsString(), '# writer\n');
      expect(
        await store.get(ExtensionEntityStore.kindSkill, 'writer'),
        isNotNull,
      );
      expect(await bodyHash('writer'), hash);
    },
  );

  test('a skill of that name being back refuses the restore', () async {
    await putSkill('writer');
    final entry = (await recycle.stageSkillBody(
      skillId: 'writer',
      origin: RecycleOrigin.remote,
      reason: RecycleReason.deleted,
    ))!;
    // The row goes with the body it belonged to, and then the skill is back —
    // re-sent by the peer, or made again by the user with other settings. That
    // is not this entry's version to overwrite.
    await store.delete(ExtensionEntityStore.kindSkill, 'writer');
    await putSkill('writer', files: {'SKILL.md': '# newer\n'}, enabled: false);

    expect(await recycle.restore(entry), RecycleRestoreOutcome.skippedExisting);
    expect(await bodyOf('writer', 'SKILL.md').readAsString(), '# newer\n');
    expect(
      (await store.get(
        ExtensionEntityStore.kindSkill,
        'writer',
      ))!.payload['enabled'],
      isFalse,
      reason: 'nothing was written: the live row is untouched',
    );
  });

  test(
    'an empty body is a body: it goes into the bin and comes back empty',
    () async {
      // A directory holding only names the policy excludes carries nothing, and
      // its hash is the empty body's. It still has to be preservable, or a body a
      // peer could never receive is silently destroyed here.
      await putSkill('blank', files: {'.DS_Store': 'noise'});
      expect(await bodyHash('blank'), kEmptySkillBodyHash);
      final entry = (await recycle.stageSkillBody(
        skillId: 'blank',
        origin: RecycleOrigin.local,
        reason: RecycleReason.deleted,
      ))!;
      await store.delete(ExtensionEntityStore.kindSkill, 'blank');

      expect(await recycle.restore(entry), RecycleRestoreOutcome.restored);

      expect(await bodyHash('blank'), kEmptySkillBodyHash);
      expect(
        await bodyOf('blank', '.DS_Store').readAsString(),
        'noise',
        reason: 'the whole tree was moved, not the part the policy counts',
      );
    },
  );

  test(
    'a body a swap replaced is restorable, and the restore displaces the live one',
    () async {
      await putSkill('writer', files: {'SKILL.md': '# v1\n'});
      // A peer's newer body arrives and is installed over this one.
      final peer = await Directory.systemTemp.createTemp('cuplivo_skill_peer_');
      addTearDown(() async {
        if (await peer.exists()) await peer.delete(recursive: true);
      });
      for (final entry in {'SKILL.md': '# v2\n'}.entries) {
        final file = File(p.join(peer.path, 'writer', entry.key));
        await file.parent.create(recursive: true);
        await file.writeAsString(entry.value, flush: true);
      }
      final peerSync = SkillDirectorySync(peer);
      final v2Hash = (await peerSync.hashOf('writer'))!;
      final zip = await peerSync.zipToCache(skillId: 'writer', dirHash: v2Hash);
      final sync = SkillDirectorySync(
        skillsDir,
        preserveBody: (skillId, displaced) async {
          final staged = await recycle.stageSkillBody(
            skillId: skillId,
            source: displaced,
            origin: RecycleOrigin.remote,
            reason: RecycleReason.overwritten,
          );
          return staged != null;
        },
      );
      expect(
        await sync.applyZip(skillId: 'writer', dirHash: v2Hash, zip: zip),
        isTrue,
      );
      expect(await bodyOf('writer', 'SKILL.md').readAsString(), '# v2\n');

      final replaced = (await recycle.list()).single;
      expect(replaced.type, RecycleEntryType.skillBody);
      expect(replaced.reason, RecycleReason.overwritten);

      expect(await recycle.restore(replaced), RecycleRestoreOutcome.restored);

      expect(
        await bodyOf('writer', 'SKILL.md').readAsString(),
        '# v1\n',
        reason: 'the swap is undone',
      );
      final displaced = (await recycle.list()).single;
      expect(displaced.key, 'writer');
      expect(
        await recycle
            .bodyDirectory(displaced)
            .then((dir) => File(p.join(dir!.path, 'SKILL.md')).readAsString()),
        '# v2\n',
        reason:
            'the restore is undoable in turn: the live version went to the bin',
      );
    },
  );

  test('a bin that cannot take the body falls back to the delete', () async {
    final blocked = RecycleService(
      database,
      // The bin's root is a *file*: creating an entry directory under it fails,
      // which is the shape of an unwritable bin.
      store: RecycleStore(
        directory: () async => Directory(p.join(root.path, 'not-a-dir')),
      ),
      skillsRoot: () async => skillsDir,
    );
    await File(p.join(root.path, 'not-a-dir')).writeAsString('x', flush: true);
    await putSkill('writer');
    final service = SkillsService(
      store: store,
      skillsDirectory: skillsDir,
      recycle: blocked,
    );
    addTearDown(service.dispose);
    await service.loaded;

    await service.delete('writer');

    expect(bodyOf('writer', 'SKILL.md').existsSync(), isFalse);
    expect(await store.get(ExtensionEntityStore.kindSkill, 'writer'), isNull);
    expect(
      await blocked.list(),
      isEmpty,
      reason: 'nothing was preserved, and the delete still happened',
    );
  });

  test('an id that is not a path segment is never staged', () async {
    // Skill ids arrive from the wire, so the body path is derived by the one
    // rule every other body path uses.
    for (final id in <String>[
      '..',
      '../victim',
      p.join(root.path, 'elsewhere'),
    ]) {
      expect(
        await recycle.stageSkillBody(
          skillId: id,
          origin: RecycleOrigin.remote,
          reason: RecycleReason.deleted,
        ),
        isNull,
        reason: id,
      );
    }
    expect(await recycle.list(), isEmpty);
    expect(Directory(p.join(root.path, 'victim')).existsSync(), isFalse);
    expect(binDir.existsSync(), isFalse, reason: 'nothing was ever created');
  });
}
