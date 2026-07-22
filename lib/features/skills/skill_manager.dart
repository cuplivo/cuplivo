import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import '../../utils/app_directories.dart';
import 'skill_paths.dart';

class SkillMetadata {
  final String name;
  final String description;
  final String body;

  const SkillMetadata({
    required this.name,
    required this.description,
    required this.body,
  });
}

class FrontmatterResult {
  final Map<String, String> fields;
  final String body;
  const FrontmatterResult({required this.fields, required this.body});
}

class SkillSaveError {
  final String code;
  final Map<String, String> params;
  const SkillSaveError(this.code, [this.params = const {}]);
}

class SkillFileInfo {
  final String path;
  final int size;
  const SkillFileInfo({required this.path, required this.size});
}

class SkillFileContent {
  final String? content;
  final bool isBinary;
  final bool truncated;
  final int size;
  const SkillFileContent({
    required this.content,
    required this.isBinary,
    required this.truncated,
    required this.size,
  });
}

class SkillManager {
  SkillManager._();

  static FrontmatterResult? parseFrontmatter(String content) {
    final trimmed = content.trim();
    if (!trimmed.startsWith('---')) return null;

    final endIndex = trimmed.indexOf('---', 3);
    if (endIndex == -1) return null;

    final raw = trimmed.substring(3, endIndex).trim();
    final body = trimmed.substring(endIndex + 3).trim();

    final fields = <String, String>{};
    try {
      final doc = loadYaml(raw);
      if (doc is YamlMap) {
        for (final entry in doc.entries) {
          final key = entry.key.toString().toLowerCase();
          final value = entry.value?.toString() ?? '';
          if (key.isNotEmpty) {
            fields[key] = value;
          }
        }
      }
    } catch (_) {
      return null;
    }

    return FrontmatterResult(fields: fields, body: body);
  }

  static Future<String?> _readFileContent(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  static Future<String>? _rootFuture;

  static Future<String> _getSkillsRoot() {
    _rootFuture ??= _resolveRoot();
    return _rootFuture!;
  }

  static Future<String> _resolveRoot() async {
    final dir = await AppDirectories.getSkillsDirectory();
    return dir.path;
  }

  static Future<void> _ensureSkillsDir() async {
    final dir = await AppDirectories.getSkillsDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  static String? _dirNameFor(String name) {
    final safe = SkillPaths.isNameSafe(name) ? name.trim() : null;
    return safe;
  }

  static Future<List<SkillMetadata>> listSkills() async {
    final root = await _getSkillsRoot();

    final dir = Directory(root);
    if (!await dir.exists()) return [];

    final skills = <SkillMetadata>[];
    final entries = await dir.list(followLinks: false).toList();
    for (final entry in entries) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (!SkillPaths.isNameSafe(name)) continue;

      final skillFile = File(p.join(entry.path, 'SKILL.md'));

      final content = await _readFileContent(skillFile.path);
      if (content == null) continue;

      final parsed = parseFrontmatter(content);
      if (parsed == null) continue;

      final skillName = parsed.fields['name'] ?? name;
      final description = parsed.fields['description'] ?? '';
      skills.add(
        SkillMetadata(
          name: skillName,
          description: description,
          body: parsed.body,
        ),
      );
    }
    return skills;
  }

  static Future<SkillMetadata?> readSkill(String name) async {
    final dirName = _dirNameFor(name);
    if (dirName == null) return null;

    final root = await _getSkillsRoot();

    final filePath = SkillPaths.skillFilePath(root, dirName);
    final content = await _readFileContent(filePath);
    if (content == null) return null;

    final parsed = parseFrontmatter(content);
    if (parsed == null) return null;

    final skillName = parsed.fields['name'] ?? name;
    final description = parsed.fields['description'] ?? '';
    return SkillMetadata(
      name: skillName,
      description: description,
      body: parsed.body,
    );
  }

  static Future<String?> readSkillBody(String name) async {
    final meta = await readSkill(name);
    return meta?.body;
  }

  static Future<SkillMetadata?> readSkillMetadata(String name) async {
    return readSkill(name);
  }

  static Future<bool> skillExists(String name) async {
    final dirName = _dirNameFor(name);
    if (dirName == null) return false;
    final root = await _getSkillsRoot();
    return File(SkillPaths.skillFilePath(root, dirName)).exists();
  }

  static Future<SkillSaveError?> saveSkill({
    required String name,
    required String content,
  }) {
    return saveSkillWithFiles(name: name, files: {'SKILL.md': content});
  }

  static Future<SkillSaveError?> saveSkillWithFiles({
    required String name,
    required Map<String, String> files,
  }) async {
    final nameError = SkillPaths.validateName(name);
    if (nameError != null) {
      return SkillSaveError('name_invalid', {'detail': nameError});
    }

    final skillMdContent = files['SKILL.md'];
    if (skillMdContent == null) {
      return const SkillSaveError('invalid_frontmatter');
    }

    await _ensureSkillsDir();
    final root = await _getSkillsRoot();

    final parsed = parseFrontmatter(skillMdContent);
    if (parsed == null) {
      return const SkillSaveError('invalid_frontmatter');
    }

    final skillName = parsed.fields['name'] ?? '';
    if (skillName.isEmpty) {
      return const SkillSaveError('name_missing');
    }
    if (skillName != name) {
      return SkillSaveError('name_mismatch', {
        'frontmatterName': skillName,
        'dirName': name,
      });
    }
    final desc = parsed.fields['description'] ?? '';
    final descError = SkillPaths.validateDescription(desc);
    if (descError != null) {
      return SkillSaveError('io_error', {'detail': descError});
    }

    final dirPath = SkillPaths.skillDirPath(root, name);

    final tmpId = DateTime.now().microsecondsSinceEpoch;
    final stagingDir = Directory('$dirPath.staging.$tmpId.tmp');
    final targetDir = Directory(dirPath);

    try {
      await stagingDir.create(recursive: true);

      for (final entry in files.entries) {
        final filePath = p.join(stagingDir.path, entry.key);
        final file = File(filePath);
        await file.parent.create(recursive: true);
        await file.writeAsString(entry.value, flush: true);
      }

      if (!await File(p.join(stagingDir.path, 'SKILL.md')).exists()) {
        await _deleteDirQuietly(stagingDir);
        return const SkillSaveError('io_error', {
          'detail': 'Failed to write SKILL.md to staging',
        });
      }

      Directory? backupDir;
      if (await targetDir.exists()) {
        final backupPath = '$dirPath.backup.$tmpId.tmp';
        await targetDir.rename(backupPath);
        backupDir = Directory(backupPath);
      }

      try {
        await stagingDir.rename(dirPath);
      } catch (e) {
        if (backupDir != null && await backupDir.exists()) {
          await backupDir.rename(dirPath);
        }
        await _deleteDirQuietly(stagingDir);
        return SkillSaveError('io_error', {
          'detail': 'Failed to finalize skill directory: $e',
        });
      }

      if (backupDir != null) {
        await _deleteDirQuietly(backupDir);
      }
    } catch (e) {
      await _deleteDirQuietly(stagingDir);
      return SkillSaveError('io_error', {'detail': 'Failed to save skill: $e'});
    }

    return null;
  }

  static Future<void> deleteSkill(String name) async {
    final dirName = _dirNameFor(name);
    if (dirName == null) return;

    final root = await _getSkillsRoot();

    final dir = Directory(SkillPaths.skillDirPath(root, dirName));
    if (await dir.exists()) {
      await _deleteDirQuietly(dir);
    }
  }

  static Future<void> _deleteDirQuietly(Directory dir) async {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  static Future<void> initRoot() async {
    await _getSkillsRoot();
  }

  static Future<List<SkillFileInfo>> listSkillFiles(String name) async {
    final dirName = _dirNameFor(name);
    if (dirName == null) return [];

    final root = await _getSkillsRoot();
    final skillDir = Directory(SkillPaths.skillDirPath(root, dirName));
    if (!await skillDir.exists()) return [];

    final files = <SkillFileInfo>[];
    await for (final entity in skillDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final relativePath = p
          .relative(entity.path, from: skillDir.path)
          .replaceAll('\\', '/');
      if (relativePath == 'SKILL.md') continue;
      final stat = await entity.stat();
      files.add(SkillFileInfo(path: relativePath, size: stat.size));
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  static Future<SkillFileContent?> readSkillFile(
    String name,
    String relativePath,
  ) async {
    if (relativePath.contains('..') ||
        relativePath.contains('\\') ||
        p.isAbsolute(relativePath)) {
      return null;
    }

    final dirName = _dirNameFor(name);
    if (dirName == null) return null;

    final root = await _getSkillsRoot();
    final skillDir = Directory(SkillPaths.skillDirPath(root, dirName));
    final file = File(p.join(skillDir.path, relativePath));

    if (!await file.exists()) return null;

    final stat = await file.stat();
    const maxSize = 64 * 1024;

    final bytes = await file.readAsBytes();
    if (_isBinary(bytes)) {
      return SkillFileContent(
        content: null,
        isBinary: true,
        truncated: false,
        size: stat.size,
      );
    }

    var content = utf8.decode(bytes, allowMalformed: true);
    var truncated = false;
    if (content.length > maxSize) {
      content = '${content.substring(0, maxSize)}\n[truncated]';
      truncated = true;
    }

    return SkillFileContent(
      content: content,
      isBinary: false,
      truncated: truncated,
      size: stat.size,
    );
  }

  static bool _isBinary(List<int> bytes) {
    final checkLen = bytes.length < 8000 ? bytes.length : 8000;
    for (var i = 0; i < checkLen; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }
}
