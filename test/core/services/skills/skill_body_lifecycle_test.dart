import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/services/skills/skill_archive.dart';
import 'package:Cuplivo/core/services/skills/skill_directory_sync.dart';
import 'package:Cuplivo/core/services/skills/skills_service.dart';
import 'package:Cuplivo/core/services/sync/workspace_content_index.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The skill body's life cycle, one cell per case of PR3's state table: what a
/// body *is* (the shape the hash and the memo fingerprint share), what a swap
/// leaves behind when one of its renames fails, and what the startup sweep
/// reclaims.
///
/// The bin round-trips live in `test/core/services/recycle/`, next to the store
/// they exercise; this file is about the body and the plane that moves it.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cuplivo_skill_body_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<Directory> peerRoot() async {
    final peer = await Directory.systemTemp.createTemp('cuplivo_skill_peer_');
    addTearDown(() async {
      if (await peer.exists()) await peer.delete(recursive: true);
    });
    return peer;
  }

  Future<void> writeBody(
    Directory dir,
    Map<String, String> files, {
    String id = 'demo',
  }) async {
    for (final entry in files.entries) {
      final file = File(p.join(dir.path, id, entry.key));
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value, flush: true);
    }
  }

  List<String> scratchChildren(Directory dir) => [
    for (final entity in dir.listSync(followLinks: false))
      if (isSyncScratchName(p.basename(entity.path))) p.basename(entity.path),
  ];

  group('the content clock is the shape of the body', () {
    test('a rename that keeps every byte and every mtime moves the clock', () async {
      // F4: the memo's fingerprint used to be (file count, total size, newest
      // mtime), so renaming a file to an equal-length name — which moves the
      // paths and nothing else — kept answering with the previous hash for the
      // rest of the launch, and the edit never reached a peer.
      final sync = SkillDirectorySync(root);
      await writeBody(root, {
        'SKILL.md': '# demo\n',
        'scripts/run.sh': 'echo hi\n',
      });
      // A later mtime that belongs to a file this test does not touch: it holds
      // the fingerprint's "newest" slot, so a rounding difference on the renamed
      // file cannot be what makes the assertion pass.
      await writeBody(root, {'notes.md': 'later\n'});
      await File(
        p.join(root.path, 'demo', 'notes.md'),
      ).setLastModified(DateTime.utc(2030, 1, 1));
      final before = (await sync.hashOf('demo'))!;

      // `run.sh` → `ran.sh`: same length, same bytes, same mtime, same count.
      final script = File(p.join(root.path, 'demo', 'scripts', 'run.sh'));
      final stamp = script.statSync().modified;
      final renamed = File(p.join(root.path, 'demo', 'scripts', 'ran.sh'));
      await script.rename(renamed.path);
      await renamed.setLastModified(stamp);

      expect(
        await sync.hashOf('demo'),
        isNot(before),
        reason: 'the path is part of what a body is',
      );
    });

    test('a file moved into a subdirectory moves the clock', () async {
      final sync = SkillDirectorySync(root);
      await writeBody(root, {'SKILL.md': '# demo\n', 'run.sh': 'echo hi\n'});
      final before = (await sync.hashOf('demo'))!;
      final file = File(p.join(root.path, 'demo', 'run.sh'));
      final stamp = file.statSync().modified;
      final moved = File(p.join(root.path, 'demo', 'scripts', 'run.sh'));
      await moved.parent.create(recursive: true);
      await file.rename(moved.path);
      await moved.setLastModified(stamp);

      expect(await sync.hashOf('demo'), isNot(before));
    });

    test(
      'an edit in place keeps the shape and still moves the clock',
      () async {
        // The other half of the fingerprint: same paths, same size, new bytes.
        // Neither the paths nor the sizes can see this, which is why every file
        // carries its own stamp.
        final sync = SkillDirectorySync(root);
        await writeBody(root, {'SKILL.md': '# v1\n'});
        final before = (await sync.hashOf('demo'))!;
        await writeBody(root, {'SKILL.md': '# v2\n'});

        expect(await sync.hashOf('demo'), isNot(before));
      },
    );

    test('a same-size edit is seen even when another file is newer', () async {
      // The stamp is per file. With one newest-mtime for the whole body, a file
      // dated ahead of the edit — copied with preserved timestamps, unpacked
      // from an archive that carried them, written before a clock correction —
      // holds that slot, and a same-size edit leaves the fingerprint identical:
      // the pre-edit hash for the rest of the launch.
      final sync = SkillDirectorySync(root);
      await writeBody(root, {
        'SKILL.md': '# v1\n',
        'notes.md': 'dated ahead\n',
      });
      await File(
        p.join(root.path, 'demo', 'notes.md'),
      ).setLastModified(DateTime.utc(2030, 1, 1));
      final before = (await sync.hashOf('demo'))!;

      await writeBody(root, {'SKILL.md': '# v2\n'});

      expect(await sync.hashOf('demo'), isNot(before));
    });
  });

  group('one policy names the scratch the plane leaves', () {
    test('every name the plane produces is one it recognises', () {
      final produced = <String>[
        skillApplyScratchName('writer', 42),
        skillParkedBodyName('writer', 42),
        kSkillBlobCacheName,
        // The form an older build parked a displaced body under: written after
        // the skill id, which is why a prefix test could not see it.
        'writer${kParkedBodyMarker}42',
      ];
      for (final name in produced) {
        expect(isSyncScratchName(name), isTrue, reason: name);
      }
      final content = <String>[
        'writer',
        '.github',
        'sync-notes',
        'notes.sync-notes.md',
      ];
      for (final name in content) {
        expect(isSyncScratchName(name), isFalse, reason: name);
      }
    });

    test('the rescan does not adopt a body a swap parked there', () async {
      // F2: the ghost skill. A swap parked the body it replaced beside the live
      // one under `<id>.sync-old-<micros>`, and the rescan read that directory as
      // a skill of its own — a second record, with the same content, that no user
      // ever made and nothing ever removed.
      await writeBody(root, {'SKILL.md': '# writer\n'}, id: 'writer');
      await writeBody(root, {
        'SKILL.md': '# writer\n',
      }, id: 'writer${kParkedBodyMarker}1');
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final store = ExtensionEntityStore(database);
      final service = SkillsService(store: store, skillsDirectory: root);
      addTearDown(service.dispose);

      await service.loaded;

      expect(service.skills.map((skill) => skill.record.id), [
        'writer',
      ], reason: 'the parked copy is scratch, not a skill');
      expect(
        FileSystemEntity.typeSync(
          p.join(root.path, 'writer${kParkedBodyMarker}1'),
        ),
        FileSystemEntityType.notFound,
        reason:
            'the load reclaims it, because the live body it was displaced by '
            'is right there — nothing is left for a later launch to trip over',
      );
    });

    test('the workspace plane keeps its own, narrower prune rule', () {
      // `report.sync-old-v2.docx` is the user's file. A workspace name is user
      // data, so the walk there asks only the prefix — the parked-body spelling
      // is the skills root's, and inheriting it would stop a real file syncing
      // in either direction, silently.
      expect(workspaceFileCarries('report.sync-old-v2.docx'), isTrue);
      expect(workspaceDirectoryCarries('drafts.sync-old-notes'), isTrue);
      expect(workspaceFileCarries('.sync-park-demo-1'), isFalse);
      expect(workspaceDirectoryCarries('.sync-apply-demo-1'), isFalse);
      expect(workspaceDirectoryCarries('.sync-blob-cache'), isFalse);
    });

    test('the startup sweep takes the scratch and nothing else', () async {
      await writeBody(root, {'SKILL.md': '# writer\n'}, id: 'writer');
      final scratch = <String>[
        skillApplyScratchName('writer', 1),
        skillParkedBodyName('writer', 2),
        'writer${kParkedBodyMarker}3',
        kSkillBlobCacheName,
      ];
      for (final name in scratch) {
        await Directory(p.join(root.path, name)).create(recursive: true);
        await File(
          p.join(root.path, name, 'leftover'),
        ).writeAsString('x', flush: true);
      }
      // Names that merely look like this plane's own: a user's directory, and
      // the skills service's own staging, which is not the sync plane's to reap.
      // Anything actually spelled `.sync-` is this plane's by definition, so the
      // names below deliberately avoid that prefix.
      final kept = <String>[
        'sync-notes',
        '.bundled-skill-creator',
        '.import-1',
      ];
      for (final name in kept) {
        await Directory(p.join(root.path, name)).create(recursive: true);
      }

      await SkillDirectorySync(root).ensureRoot();

      // Asserted against the names this test wrote, not against the predicate
      // that decided: a recogniser narrowed by some later change has to fail
      // here rather than agree with itself.
      for (final name in scratch) {
        expect(
          FileSystemEntity.typeSync(p.join(root.path, name)),
          FileSystemEntityType.notFound,
          reason: '$name is scratch and was swept',
        );
      }
      expect(scratchChildren(root), isEmpty);
      for (final name in kept) {
        expect(
          Directory(p.join(root.path, name)).existsSync(),
          isTrue,
          reason: '$name is not a scratch name',
        );
      }
      expect(
        Directory(p.join(root.path, 'writer')).existsSync(),
        isTrue,
        reason: 'a body is never walked into',
      );
    });
    test(
      'a scratch-named record is dropped even when its directory survives',
      () async {
        // The reclaim can fail — a file held open in the tree, which Windows
        // refuses to unlink — so the record must not depend on the directory being
        // gone. Dropped on its own name, it can never become the "directory-less
        // row installs a broken skill" state this PR is about.
        await writeBody(root, {'SKILL.md': '# demo\n'}, id: 'demo');
        final ghost = 'demo${kParkedBodyMarker}1';
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final store = ExtensionEntityStore(database);
        final service = SkillsService(store: store, skillsDirectory: root);
        addTearDown(service.dispose);
        await service.loaded;

        // The same state as a device whose sweep could not delete it: directory and
        // record both back, and a rescan with no load-time sweep in front of it.
        await writeBody(root, {'SKILL.md': '# demo\n'}, id: ghost);
        await store.upsert(ExtensionEntityStore.kindSkill, ghost, {
          'id': ghost,
          'enabled': true,
          'useCount': 0,
          'source': 'file',
          'installedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
          'updatedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
        });

        await service.rescan();

        expect(
          await store.get(ExtensionEntityStore.kindSkill, ghost),
          isNull,
          reason:
              'its name is scratch, so it is not a skill and owns no record',
        );
        expect(
          Directory(p.join(root.path, ghost)).existsSync(),
          isTrue,
          reason:
              'the reclaim is not what dropped it: the rescan refuses the id',
        );
      },
    );

    test('the sync apply installs exactly what the hash counts', () async {
      // The third reader of the same policy: a name the hash ignores must not be
      // installed from a peer's archive either, or the body on disk holds
      // something the content clock can never see change. The apply is the caller
      // that asks for the filter, because the tree a peer's body becomes must
      // hold exactly the names its hash counted.
      final zip = File(p.join(root.path, 'body.zip'));
      await zip.writeAsBytes(
        encodeSkillZip({
          'SKILL.md': utf8.encode('# demo\n'),
          '.DS_Store': utf8.encode('noise'),
          '.sync-apply-1/leftover': utf8.encode('x'),
        }),
        flush: true,
      );
      final out = Directory(p.join(root.path, 'out'));
      await out.create(recursive: true);

      extractSkillArchive(zip.path, out.path, installsName: carriesSkillEntry);

      expect(File(p.join(out.path, 'SKILL.md')).existsSync(), isTrue);
      expect(
        File(p.join(out.path, '.DS_Store')).existsSync(),
        isFalse,
        reason: 'an OS bookkeeping file is not part of a body',
      );
      expect(
        Directory(p.join(out.path, '.sync-apply-1')).existsSync(),
        isFalse,
        reason: 'nor is this plane\'s own scratch',
      );
    });

    test('an import installs the archive the user picked, scratch-named file '
        'and all', () async {
      // The same extractor, the other caller. An imported archive is not a body
      // this device produced, so there is no hash for it to agree with, and a
      // user file called `notes.sync-old-v2.md` is the user's: dropping it here
      // silently edits what they chose to import. The filter is the caller's,
      // and this caller passes none.
      final zip = File(p.join(root.path, 'import.zip'));
      await zip.writeAsBytes(
        encodeSkillZip({
          'SKILL.md': utf8.encode('# mine\n'),
          'notes.sync-old-v2.md': utf8.encode('keep me\n'),
          '.DS_Store': utf8.encode('noise'),
        }),
        flush: true,
      );
      final out = Directory(p.join(root.path, 'unpacked'));
      await out.create(recursive: true);

      extractSkillArchive(zip.path, out.path);

      expect(
        await File(p.join(out.path, 'notes.sync-old-v2.md')).readAsString(),
        'keep me\n',
        reason: 'an import passes no filter, so nothing is dropped',
      );
      expect(
        File(p.join(out.path, '.DS_Store')).existsSync(),
        isTrue,
        reason: 'not even the OS bookkeeping file: the archive is the user\'s',
      );
    });
  });

  group('an interrupted swap is recovered, not swept away', () {
    /// The state a swap leaves when it dies between its two renames, or when the
    /// install and the put-back both fail: the live path is empty and the body
    /// the record still describes is parked.
    Future<void> abandonSwap(String id) async {
      await writeBody(root, {'SKILL.md': '# v1\n'}, id: id);
      await Directory(
        p.join(root.path, id),
      ).rename(p.join(root.path, skillParkedBodyName(id, 1)));
      // The received body the apply was staging is debris on its own; the copy
      // that matters is the parked one.
      await Directory(
        p.join(root.path, skillApplyScratchName(id, 2)),
      ).create(recursive: true);
    }

    test('the parked body goes back to its live path', () async {
      await abandonSwap('demo');

      await SkillDirectorySync(root).ensureRoot();

      expect(
        await File(p.join(root.path, 'demo', 'SKILL.md')).readAsString(),
        '# v1\n',
        reason: 'it is the only copy of the body the record describes',
      );
      expect(scratchChildren(root), isEmpty);
    });

    test('a parked body whose replacement did land is reclaimed', () async {
      await writeBody(root, {'SKILL.md': '# v2\n'}, id: 'demo');
      await writeBody(root, {
        'SKILL.md': '# v1\n',
      }, id: skillParkedBodyName('demo', 1));

      await SkillDirectorySync(root).ensureRoot();

      expect(
        await File(p.join(root.path, 'demo', 'SKILL.md')).readAsString(),
        '# v2\n',
        reason: 'the body at the live path is the one the swap installed',
      );
      expect(scratchChildren(root), isEmpty);
    });

    test('the record survives the launch the swap died in', () async {
      // The half that made the sweep dangerous: recovering *after* the rescan
      // would restore the body to a record the rescan had already dropped for
      // want of a `SKILL.md`, losing the enabled switch and the use count.
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final store = ExtensionEntityStore(database);
      await store.upsert(ExtensionEntityStore.kindSkill, 'demo', {
        'id': 'demo',
        'enabled': false,
        'useCount': 7,
        'source': 'github',
        'installedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
        'updatedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
      });
      await abandonSwap('demo');
      final service = SkillsService(store: store, skillsDirectory: root);
      addTearDown(service.dispose);

      await service.loaded;

      expect(
        await File(p.join(root.path, 'demo', 'SKILL.md')).readAsString(),
        '# v1\n',
      );
      expect(service.skills.map((skill) => skill.record.id), ['demo']);
      final record = await store.get(ExtensionEntityStore.kindSkill, 'demo');
      expect(record, isNotNull);
      expect(
        record!.payload['useCount'],
        7,
        reason:
            'the recovery runs before the records are read, so the record '
            'is never dropped',
      );
    });

    test(
      'a ghost record an older build adopted is gone after one launch',
      () async {
        // The pre-fix build adopted the parked directory as a skill of its own.
        // The directory is reclaimed — unless a file in it is held open — so the
        // record has to be dropped on its own name as well, or it lists a skill
        // with no directory until some later launch.
        await writeBody(root, {'SKILL.md': '# demo\n'}, id: 'demo');
        final ghost = 'demo${kParkedBodyMarker}1';
        await writeBody(root, {'SKILL.md': '# demo\n'}, id: ghost);
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final store = ExtensionEntityStore(database);
        await store.upsert(ExtensionEntityStore.kindSkill, ghost, {
          'id': ghost,
          'enabled': true,
          'useCount': 0,
          'source': 'file',
          'installedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
          'updatedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
        });
        final service = SkillsService(store: store, skillsDirectory: root);
        addTearDown(service.dispose);

        await service.loaded;

        expect(service.skills.map((skill) => skill.record.id), ['demo']);
        expect(
          await store.get(ExtensionEntityStore.kindSkill, ghost),
          isNull,
          reason:
              'the record is dropped on its own name, not only for want of a '
              'directory',
        );
      },
    );
  });

  group('a swap is a transaction', () {
    late Directory peer;
    late String v2Hash;
    late File v2Zip;

    setUp(() async {
      peer = await peerRoot();
      await writeBody(peer, {'SKILL.md': '# v2\n'});
      final source = SkillDirectorySync(peer);
      v2Hash = (await source.hashOf('demo'))!;
      v2Zip = await source.zipToCache(skillId: 'demo', dirHash: v2Hash);
    });

    test(
      'a failed install puts the old body back and the next round retries',
      () async {
        await writeBody(root, {'SKILL.md': '# v1\n'});
        var renames = 0;
        final sync = SkillDirectorySync(
          root,
          rename: (from, to) async {
            renames++;
            // 1: the old body aside. 2: the new body in — the one failure whose
            // recovery is the whole point of the order.
            if (renames == 2) throw const FileSystemException('held open');
            await Directory(from).rename(to);
          },
        );

        expect(
          await sync.applyZip(skillId: 'demo', dirHash: v2Hash, zip: v2Zip),
          isFalse,
        );
        expect(
          await File(p.join(root.path, 'demo', 'SKILL.md')).readAsString(),
          '# v1\n',
          reason:
              'the identity is not lost: the record and its body are as they were',
        );
        expect(scratchChildren(root), isEmpty);

        // The next round is a retry, not a recovery: nothing was left behind.
        expect(
          await SkillDirectorySync(
            root,
          ).applyZip(skillId: 'demo', dirHash: v2Hash, zip: v2Zip),
          isTrue,
        );
        expect(
          await File(p.join(root.path, 'demo', 'SKILL.md')).readAsString(),
          '# v2\n',
        );
      },
    );

    test(
      'the body a swap replaces is handed to the bin, not deleted',
      () async {
        await writeBody(root, {'SKILL.md': '# v1\n'});
        final bin = Directory(p.join(root.path, 'bin'));
        await bin.create(recursive: true);
        Directory? preserved;
        final sync = SkillDirectorySync(
          root,
          preserveBody: (skillId, displaced) async {
            expect(skillId, 'demo');
            expect(
              await File(p.join(displaced.path, 'SKILL.md')).readAsString(),
              '# v1\n',
              reason:
                  'the bin is offered the body that was live, not the new one',
            );
            preserved = Directory(p.join(bin.path, 'entry'));
            await displaced.rename(preserved!.path);
            return true;
          },
        );

        expect(
          await sync.applyZip(skillId: 'demo', dirHash: v2Hash, zip: v2Zip),
          isTrue,
        );

        expect(
          await File(p.join(root.path, 'demo', 'SKILL.md')).readAsString(),
          '# v2\n',
        );
        expect(scratchChildren(root), isEmpty);
        expect(
          await File(p.join(preserved!.path, 'SKILL.md')).readAsString(),
          '# v1\n',
          reason: 'the version the peer replaced is recoverable',
        );
      },
    );

    test('a bin that cannot take it leaves the body for the sweep', () async {
      await writeBody(root, {'SKILL.md': '# v1\n'});
      final sync = SkillDirectorySync(
        root,
        preserveBody: (skillId, displaced) async => false,
      );

      expect(
        await sync.applyZip(skillId: 'demo', dirHash: v2Hash, zip: v2Zip),
        isTrue,
      );

      expect(
        await File(p.join(root.path, 'demo', 'SKILL.md')).readAsString(),
        '# v2\n',
      );
      final parked = scratchChildren(root);
      expect(
        parked,
        hasLength(1),
        reason: 'the old body is parked under a scratch name, not destroyed',
      );
      expect(
        await File(p.join(root.path, parked.single, 'SKILL.md')).readAsString(),
        '# v1\n',
      );

      await SkillDirectorySync(root).ensureRoot();
      expect(scratchChildren(root), isEmpty);
    });

    test('a body the plane never had is installed without a swap', () async {
      final sync = SkillDirectorySync(root);
      expect(
        await sync.applyZip(skillId: 'demo', dirHash: v2Hash, zip: v2Zip),
        isTrue,
      );
      expect(await sync.hashOf('demo'), v2Hash);
      expect(scratchChildren(root), isEmpty);
    });
  });

  group('a parked body names its skill, and a skill nobody describes', () {
    Future<ExtensionEntityStore> storeWith(List<String> ids) async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final store = ExtensionEntityStore(database);
      for (final id in ids) {
        await store.upsert(ExtensionEntityStore.kindSkill, id, {
          'id': id,
          'enabled': false,
          'useCount': 3,
          'source': 'github',
          'installedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
          'updatedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
        });
      }
      return store;
    }

    test('each spelling names its own skill, and only a stamp comes off', () {
      // The two spellings put the microsecond stamp in different places. The new
      // one appends it to the id, so the last dash-separated field is the stamp
      // and may come off. The legacy one — `'${dest.path}.sync-old-<micros>'`,
      // which is what the base build's swap left — uses the marker *as* the
      // delimiter, so what precedes it is the id entire: applying the stamp rule
      // there truncates an id with a dash (`my-skill-2`, what a second skill
      // called "my skill" becomes) and answers null for an id without one.
      expect(skillParkedBodyName('demo', 1723), '.sync-park-demo-1723');
      expect(parkedBodySkillId('.sync-park-demo-1723'), 'demo');
      expect(parkedBodySkillId('.sync-park-my-skill-2-1723'), 'my-skill-2');
      expect(parkedBodySkillId('demo${kParkedBodyMarker}1723'), 'demo');
      expect(
        parkedBodySkillId('my-skill-2${kParkedBodyMarker}1723'),
        'my-skill-2',
        reason: 'the id keeps its own dash',
      );
      // Not a parked body: a tail that is not a stamp, no stamp at all, no
      // marker at all, or another scratch name entirely.
      expect(parkedBodySkillId('demo${kParkedBodyMarker}abc'), isNull);
      expect(parkedBodySkillId('demo$kParkedBodyMarker'), isNull);
      expect(parkedBodySkillId('.sync-park-demo'), isNull);
      expect(parkedBodySkillId('demo'), isNull);
      expect(parkedBodySkillId('.sync-apply-demo-1723'), isNull);
    });

    test('a legacy parked body that is the only copy comes back', () async {
      // The pre-fix parse answered null for a legacy name whose id has no dash,
      // so the sweep read the only copy of the body as debris: it deleted the
      // directory, and the rescan then dropped the record for want of a
      // `SKILL.md`. Both halves of the skill, gone, in the operation meant to
      // recover it — with no live twin to hide behind, which is what the older
      // cells in this file all had.
      final store = await storeWith(['demo']);
      await writeBody(root, {
        'SKILL.md': '# v1\n',
      }, id: 'demo${kParkedBodyMarker}1723');
      final service = SkillsService(store: store, skillsDirectory: root);
      addTearDown(service.dispose);

      await service.loaded;

      expect(
        await File(p.join(root.path, 'demo', 'SKILL.md')).readAsString(),
        '# v1\n',
        reason: 'the only copy is recovered, not reclaimed',
      );
      expect(service.skills.map((skill) => skill.record.id), ['demo']);
      expect(
        (await store.get(
          ExtensionEntityStore.kindSkill,
          'demo',
        ))!.payload['useCount'],
        3,
        reason: 'the record is never dropped for a body that comes back',
      );
      expect(scratchChildren(root), isEmpty);
    });

    test('a legacy parked body of an id with a dash comes back under that id, '
        'not under its neighbour', () async {
      // The other half of the same parse: `my-skill-2.sync-old-1723` read as
      // `my-skill`, so the body was renamed into another skill's path when that
      // path was free, and destroyed as debris when it was taken.
      final store = await storeWith(['my-skill-2']);
      await writeBody(root, {'SKILL.md': '# mine\n'}, id: 'my-skill');
      await writeBody(root, {
        'SKILL.md': '# v1\n',
      }, id: 'my-skill-2${kParkedBodyMarker}1723');
      final service = SkillsService(store: store, skillsDirectory: root);
      addTearDown(service.dispose);

      await service.loaded;

      expect(
        await File(p.join(root.path, 'my-skill-2', 'SKILL.md')).readAsString(),
        '# v1\n',
      );
      expect(
        await File(p.join(root.path, 'my-skill', 'SKILL.md')).readAsString(),
        '# mine\n',
        reason: 'the neighbour\'s body is not overwritten',
      );
      expect(
        service.skills.map((skill) => skill.record.id),
        contains('my-skill-2'),
      );
    });

    test(
      'a parked body whose skill no record describes is not put back',
      () async {
        // The mirror of the recovery: the user deleted the skill while the body
        // was parked, so the delete found an empty live path and staged nothing.
        // Renaming the body back would invent the skill they deleted (a fresh
        // record, `installedAt: now`, advertised to peers); deleting it would
        // destroy the last copy there is. With no bin wired it stays parked —
        // inert, named as scratch, and asked about again next launch.
        final store = await storeWith([]);
        await writeBody(root, {
          'SKILL.md': '# orphan\n',
        }, id: skillParkedBodyName('demo', 1723));
        final service = SkillsService(store: store, skillsDirectory: root);
        addTearDown(service.dispose);

        await service.loaded;

        expect(
          service.skills,
          isEmpty,
          reason: 'a skill the user deleted does not come back',
        );
        expect(
          File(p.join(root.path, 'demo', 'SKILL.md')).existsSync(),
          isFalse,
          reason: 'and it is not renamed to the live path either',
        );
        expect(scratchChildren(root), [
          skillParkedBodyName('demo', 1723),
        ], reason: 'kept: it is the only copy, so it is never debris');
      },
    );
  });
}
