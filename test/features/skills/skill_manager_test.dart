import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Cuplivo/features/skills/skill_manager.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

String _skillMd(String name, {String? category, String body = 'body text'}) {
  final cat = category == null ? '' : 'category: $category\n';
  return '---\nname: $name\n${cat}description: test skill\n---\n$body';
}

void main() {
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('skills_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
  });

  tearDownAll(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  group('SkillManager category parsing', () {
    test('parseFrontmatter reads the category field', () {
      final parsed = SkillManager.parseFrontmatter(
        _skillMd('alpha', category: 'coding'),
      );
      expect(parsed?.fields['category'], 'coding');
    });

    test('parseFrontmatter returns null category when absent', () {
      final parsed = SkillManager.parseFrontmatter(_skillMd('alpha'));
      expect(parsed?.fields['category'], isNull);
    });

    test('listSkills exposes category and trims it', () async {
      await SkillManager.saveSkill(
        name: 'alpha',
        content: _skillMd('alpha', category: '  coding  '),
      );
      await SkillManager.saveSkill(name: 'beta', content: _skillMd('beta'));
      final skills = await SkillManager.listSkills();
      final alpha = skills.firstWhere((s) => s.name == 'alpha');
      final beta = skills.firstWhere((s) => s.name == 'beta');
      expect(alpha.category, 'coding');
      expect(beta.category, isNull);
    });

    test('readSkill exposes category', () async {
      await SkillManager.saveSkill(
        name: 'gamma',
        content: _skillMd('gamma', category: 'research'),
      );
      final meta = await SkillManager.readSkill('gamma');
      expect(meta?.category, 'research');
    });
  });

  group('SkillManager.updateCategory', () {
    test('adds a category to a skill without one', () async {
      await SkillManager.saveSkill(name: 'delta', content: _skillMd('delta'));
      expect(await SkillManager.updateCategory('delta', 'research'), isNull);
      final skills = await SkillManager.listSkills();
      expect(skills.firstWhere((s) => s.name == 'delta').category, 'research');
    });

    test('updates an existing category and preserves name/body', () async {
      await SkillManager.saveSkill(
        name: 'echo',
        content: _skillMd('echo', category: 'old', body: 'keep me'),
      );
      expect(await SkillManager.updateCategory('echo', 'new'), isNull);
      final meta = await SkillManager.readSkill('echo');
      expect(meta?.name, 'echo');
      expect(meta?.category, 'new');
      expect(meta?.body, 'keep me');
    });

    test('clears the category when null is passed', () async {
      await SkillManager.saveSkill(
        name: 'foxtrot',
        content: _skillMd('foxtrot', category: 'coding'),
      );
      expect(await SkillManager.updateCategory('foxtrot', null), isNull);
      final meta = await SkillManager.readSkill('foxtrot');
      expect(meta?.category, isNull);
    });

    test('clears the category when only whitespace is passed', () async {
      await SkillManager.saveSkill(
        name: 'golf',
        content: _skillMd('golf', category: 'coding'),
      );
      expect(await SkillManager.updateCategory('golf', '   '), isNull);
      final meta = await SkillManager.readSkill('golf');
      expect(meta?.category, isNull);
    });

    test('rejects a category containing a newline', () async {
      await SkillManager.saveSkill(name: 'hotel', content: _skillMd('hotel'));
      final error = await SkillManager.updateCategory('hotel', 'a\nb');
      expect(error, isNotNull);
      expect(error?.code, 'io_error');
      final meta = await SkillManager.readSkill('hotel');
      expect(meta?.category, isNull);
    });

    test('returns an error for an unknown skill', () async {
      final error = await SkillManager.updateCategory(
        'missing-skill',
        'coding',
      );
      expect(error, isNotNull);
      expect(error?.code, 'io_error');
    });

    test('preserves auxiliary files in the skill directory', () async {
      await SkillManager.saveSkillWithFiles(
        name: 'india',
        files: {
          'SKILL.md': utf8.encode(_skillMd('india')),
          'references/ref.md': utf8.encode('# ref'),
          'scripts/run.sh': utf8.encode('#!/bin/sh'),
        },
      );
      expect(await SkillManager.updateCategory('india', 'coding'), isNull);
      final ref = await SkillManager.readSkillFile(
        'india',
        'references/ref.md',
      );
      expect(ref?.content, '# ref');
      final script = await SkillManager.readSkillFile(
        'india',
        'scripts/run.sh',
      );
      expect(script?.content, '#!/bin/sh');
      final meta = await SkillManager.readSkill('india');
      expect(meta?.category, 'coding');
    });

    test('preserves body trailing newlines', () async {
      await SkillManager.saveSkill(
        name: 'juliet',
        content: '${_skillMd('juliet', category: 'a')}\n\n',
      );
      expect(await SkillManager.updateCategory('juliet', 'b'), isNull);
      final text = await File(
        '${root.path}/skills/juliet/SKILL.md',
      ).readAsString();
      expect(text.endsWith('\n\n'), isTrue);
      expect(text, contains('category: b\n'));
    });

    test('preserves CRLF line endings', () async {
      const crlf =
          '---\r\nname: kilo\r\ncategory: a\r\ndescription: test skill\r\n'
          '---\r\nbody\r\n';
      await SkillManager.saveSkill(name: 'kilo', content: crlf);
      expect(await SkillManager.updateCategory('kilo', 'b'), isNull);
      final text = await File(
        '${root.path}/skills/kilo/SKILL.md',
      ).readAsString();
      expect(text, contains('category: b\r\n'));
      final lines = text.split('\n');
      for (final line in lines.take(lines.length - 1)) {
        expect(
          line.endsWith('\r'),
          isTrue,
          reason: 'mixed line ending in "$line"',
        );
      }
    });

    test('rejects a category YAML silently mangles', () async {
      await SkillManager.saveSkill(name: 'lima', content: _skillMd('lima'));
      final error = await SkillManager.updateCategory('lima', 'foo # bar');
      expect(error, isNotNull);
      expect(error?.code, 'invalid_frontmatter');
      final meta = await SkillManager.readSkill('lima');
      expect(meta?.category, isNull);
    });
  });

  group('groupSkillsByCategory', () {
    test('sorts groups A-Z and puts uncategorized last', () {
      final skills = [
        const SkillMetadata(name: 'c', description: '', body: ''),
        const SkillMetadata(
          name: 'a',
          description: '',
          body: '',
          category: 'zeta',
        ),
        const SkillMetadata(
          name: 'b',
          description: '',
          body: '',
          category: 'alpha',
        ),
      ];
      final groups = groupSkillsByCategory(skills);
      expect(groups.map((g) => g.$1).toList(), ['alpha', 'zeta', null]);
      expect(groups[0].$2.single.name, 'b');
      expect(groups[1].$2.single.name, 'a');
      expect(groups[2].$2.single.name, 'c');
    });

    test('returns a single uncategorized group for empty categories', () {
      final skills = [
        const SkillMetadata(name: 'a', description: '', body: ''),
        const SkillMetadata(name: 'b', description: '', body: ''),
      ];
      final groups = groupSkillsByCategory(skills);
      expect(groups.length, 1);
      expect(groups.single.$1, isNull);
      expect(groups.single.$2.map((s) => s.name), ['a', 'b']);
    });
  });
}
