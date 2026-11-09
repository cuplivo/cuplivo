import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/services/skills/skill_archive.dart';
import 'package:Cuplivo/core/services/skills/skill_directory_sync.dart';
import 'package:Cuplivo/core/services/skills/skills_service.dart';
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

    test('an edit in place keeps the shape and still moves the clock', () async {
      // The other half of the fingerprint: same paths, same size, new bytes. The
      // shape alone cannot see this, which is why the newest mtime stays in it.
      final sync = SkillDirectorySync(root);
      await writeBody(root, {'SKILL.md': '# v1\n'});
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
        Directory(
          p.join(root.path, 'writer${kParkedBodyMarker}1'),
        ).existsSync(),
        isTrue,
        reason: 'the rescan refuses it; reclaiming it is the sweep\'s job',
      );
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
    test('the extractor installs exactly what the hash counts', () async {
      // The third reader of the same policy: a name the hash ignores must not be
      // installed from a peer's archive either, or the body on disk holds
      // something the content clock can never see change.
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

      extractSkillArchive(zip.path, out.path);

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
}
