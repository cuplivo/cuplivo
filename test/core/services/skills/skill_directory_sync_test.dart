import 'dart:io';

import 'package:Cuplivo/core/services/skills/skill_directory_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// Skill body carriage: hashing (the content clock), zip serving, and the
/// staging + verify + atomic-swap apply. The extraction bounds themselves are
/// `skill_archive`'s, already covered by its own test.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('skill_dir_sync_test_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> writeSkill(
    Map<String, String> files, {
    String id = 'demo',
  }) async {
    for (final entry in files.entries) {
      final file = File('${root.path}/$id/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value, flush: true);
    }
  }

  test('directory hash tracks content, not mtimes or write order', () async {
    final sync = SkillDirectorySync(root);
    await writeSkill({'SKILL.md': '# demo\n', 'scripts/run.sh': 'echo hi\n'});
    final first = await sync.hashOf('demo');
    expect(first, isNotNull);

    // Rewriting identical bytes (new mtime) must not move the hash.
    await writeSkill({'SKILL.md': '# demo\n'});
    expect(await sync.hashOf('demo'), first);

    // A content edit must.
    await writeSkill({'scripts/run.sh': 'echo bye\n'});
    expect(await sync.hashOf('demo'), isNot(first));

    // A missing body is absent, not an error.
    expect(await sync.hashOf('nope'), isNull);
  });

  test('zip round-trips through apply with hash verification', () async {
    final source = SkillDirectorySync(root);
    await writeSkill({
      'SKILL.md': '# demo\n',
      'nested/deep/file.txt': 'payload',
    });
    final hash = (await source.hashOf('demo'))!;
    final zip = await source.zipToCache(skillId: 'demo', dirHash: hash);
    expect(await zip.exists(), isTrue);

    // A second device is just another root.
    final otherRoot = await Directory.systemTemp.createTemp('skill_dir_peer_');
    addTearDown(() async {
      if (await otherRoot.exists()) await otherRoot.delete(recursive: true);
    });
    final target = SkillDirectorySync(otherRoot);
    final applied = await target.applyZip(
      skillId: 'demo',
      dirHash: hash,
      zip: zip,
    );

    expect(applied, isTrue);
    expect(await target.hashOf('demo'), hash);
    expect(
      await File('${otherRoot.path}/demo/nested/deep/file.txt').readAsString(),
      'payload',
    );
    // No staging leftovers.
    final entries = await otherRoot.list().toList();
    expect(
      entries.where((e) => e.path.contains('.sync-')),
      isEmpty,
      reason: 'staging directories are cleaned up',
    );
  });

  test(
    'a zip whose content does not hash to the expected value is refused',
    () async {
      final source = SkillDirectorySync(root);
      await writeSkill({'SKILL.md': '# demo\n'});
      final hash = (await source.hashOf('demo'))!;
      final zip = await source.zipToCache(skillId: 'demo', dirHash: hash);

      final otherRoot = await Directory.systemTemp.createTemp(
        'skill_dir_peer_',
      );
      addTearDown(() async {
        if (await otherRoot.exists()) await otherRoot.delete(recursive: true);
      });
      final target = SkillDirectorySync(otherRoot);

      final applied = await target.applyZip(
        skillId: 'demo',
        dirHash: 'deadbeef' * 8,
        zip: zip,
      );

      expect(applied, isFalse);
      // Nothing was installed and no staging directory survived.
      expect(await Directory('${otherRoot.path}/demo').exists(), isFalse);
      expect((await otherRoot.list().toList()), isEmpty);
    },
  );

  test('apply replaces an existing body wholesale', () async {
    final source = SkillDirectorySync(root);
    await writeSkill({'SKILL.md': '# demo v2\n'});
    final hash = (await source.hashOf('demo'))!;
    final zip = await source.zipToCache(skillId: 'demo', dirHash: hash);

    final otherRoot = await Directory.systemTemp.createTemp('skill_dir_peer_');
    addTearDown(() async {
      if (await otherRoot.exists()) await otherRoot.delete(recursive: true);
    });
    final target = SkillDirectorySync(otherRoot);
    for (final entry in {
      'SKILL.md': '# demo v1\n',
      'stale.txt': 'old',
    }.entries) {
      final file = File('${otherRoot.path}/demo/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }

    expect(
      await target.applyZip(skillId: 'demo', dirHash: hash, zip: zip),
      isTrue,
    );
    expect(
      await File('${otherRoot.path}/demo/SKILL.md').readAsString(),
      '# demo v2\n',
    );
    expect(await File('${otherRoot.path}/demo/stale.txt').exists(), isFalse);
  });

  test('deleteDirectory removes the body and keeps sibling skills', () async {
    final sync = SkillDirectorySync(root);
    await writeSkill({'SKILL.md': '# a\n'}, id: 'a');
    await writeSkill({'SKILL.md': '# b\n'}, id: 'b');

    await sync.deleteDirectory('a');

    expect(await Directory('${root.path}/a').exists(), isFalse);
    expect(await Directory('${root.path}/b').exists(), isTrue);
    expect(await sync.hashOf('a'), isNull);
  });

  test('a wire-crafted skill id never leaves the skills root', () async {
    // Skill ids arrive from a peer's manifest, so `applyZip` must refuse any
    // id whose destination escapes the root: the swap renames a directory and
    // recursively deletes the displaced one, which outside the root would be
    // another app's data.
    final source = SkillDirectorySync(root);
    await writeSkill({'SKILL.md': '# demo\n'});
    final hash = (await source.hashOf('demo'))!;
    final zip = await source.zipToCache(skillId: 'demo', dirHash: hash);

    final otherRoot = await Directory.systemTemp.createTemp('skill_dir_peer_');
    addTearDown(() async {
      if (await otherRoot.exists()) await otherRoot.delete(recursive: true);
    });
    // Files and directories the crafted ids try to reach.
    final parentFile = File('${otherRoot.parent.path}/cuplivo-skill-guard');
    await parentFile.writeAsString('original');
    addTearDown(() => parentFile.delete().catchError((_) => parentFile));
    final victim = Directory('${otherRoot.parent.path}/cuplivo-skill-victim');
    await victim.create(recursive: true);
    await File('${victim.path}/keep.txt').writeAsString('original');
    addTearDown(() => victim.delete(recursive: true).catchError((_) => victim));
    final target = SkillDirectorySync(otherRoot);

    final crafted = <String>[
      '..',
      '../cuplivo-skill-victim',
      // An absolute path names a target outright.
      Directory.systemTemp.path,
    ];
    for (final id in crafted) {
      expect(await target.applyZip(skillId: id, dirHash: hash, zip: zip),
          isFalse, reason: 'applyZip must refuse the crafted id "$id"');
      expect(await target.hashOf(id), isNull,
          reason: 'hashOf must not resolve the crafted id "$id"');
      expect(await target.hashesOf({id}), isEmpty);
      await target.deleteDirectory(id); // must be a no-op, not a delete
    }

    // Nothing outside the root was created, replaced or deleted.
    expect(await parentFile.readAsString(), 'original');
    expect(await File('${victim.path}/keep.txt').readAsString(), 'original');
    // And nothing was installed inside the root either.
    expect(await otherRoot.list().toList(), isEmpty);
  });
}
