import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../core/providers/assistant_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../github_importer.dart';
import '../skill_manager.dart';

class SkillsPage extends StatefulWidget {
  const SkillsPage({super.key});

  @override
  State<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends State<SkillsPage> {
  List<SkillMetadata> _skills = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    SkillManager.initRoot().then((_) => _refresh());
  }

  Future<void> _refresh() async {
    final skills = await SkillManager.listSkills();
    if (!mounted) return;
    setState(() {
      _skills = skills;
      _loading = false;
    });
  }

  String? _extractNameFromFrontmatter(String content) {
    final parsed = SkillManager.parseFrontmatter(content);
    return parsed?.fields['name'];
  }

  String _localizeSaveError(SkillSaveError? error, AppLocalizations l10n) {
    if (error == null) return '';
    switch (error.code) {
      case 'invalid_frontmatter':
        return l10n.skillsInvalidFrontmatter;
      case 'name_invalid':
        return l10n.skillsNameInvalid;
      case 'name_missing':
        return l10n.skillsFrontmatterNameMissing;
      case 'name_mismatch':
        return l10n.skillsFrontmatterNameMismatch(
          error.params['frontmatterName'] ?? '',
          error.params['dirName'] ?? '',
        );
      case 'io_error':
        return l10n.skillsSaveFailed(error.params['detail'] ?? '');
      default:
        return l10n.skillsSaveFailed(error.params['detail'] ?? '');
    }
  }

  Future<void> _showAddDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            String? liveName;
            if (controller.text.trim().isNotEmpty) {
              final parsed = SkillManager.parseFrontmatter(controller.text);
              if (parsed != null) {
                liveName = parsed.fields['name'];
              }
            }

            return AlertDialog(
              title: Text(l10n.skillsImportManualTitle),
              content: SizedBox(
                width: 400,
                child: TextField(
                  controller: controller,
                  maxLines: 12,
                  decoration: InputDecoration(
                    hintText: l10n.skillsImportManualHint,
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.all(12),
                  ),
                  style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                  onChanged: (_) => setDialogState(() {}),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
                ),
                FilledButton(
                  onPressed: liveName != null && liveName.isNotEmpty
                      ? () => Navigator.of(ctx).pop(controller.text)
                      : null,
                  child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null || result.isEmpty || !mounted) return;

    final name = _extractNameFromFrontmatter(result) ?? '';
    if (name.isEmpty) return;

    final error = await SkillManager.saveSkill(name: name, content: result);
    if (error != null) {
      if (!mounted) return;
      showAppSnackBar(context, message: _localizeSaveError(error, l10n));
      return;
    }
    await _refresh();
  }

  Future<void> _showImportChoice() async {
    final l10n = AppLocalizations.of(context)!;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.skillsImportChoiceTitle),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('file'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const Icon(Lucide.FileText),
                  const SizedBox(width: 16),
                  Text(l10n.skillsImportFromFile),
                ],
              ),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('github'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const Icon(Lucide.Globe),
                  const SizedBox(width: 16),
                  Text(l10n.skillsImportFromGitHub),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'file') {
      await _importFromFile();
    } else if (choice == 'github') {
      await _importFromGitHub();
    }
  }

  Future<void> _importFromGitHub() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();

    final url = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final text = controller.text.trim();
            final isValid = text.isEmpty || parseGitHubUrl(text) != null;

            return AlertDialog(
              title: Text(l10n.skillsGitHubImportTitle),
              content: SizedBox(
                width: 400,
                child: TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: l10n.skillsGitHubUrlHint,
                    border: const OutlineInputBorder(),
                    errorText: isValid ? null : l10n.skillsGitHubUrlInvalid,
                  ),
                  style: const TextStyle(fontSize: 13),
                  onChanged: (_) => setDialogState(() {}),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
                ),
                FilledButton(
                  onPressed: text.isNotEmpty && isValid
                      ? () => Navigator.of(ctx).pop(text)
                      : null,
                  child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
                ),
              ],
            );
          },
        );
      },
    );

    if (url == null || url.isEmpty || !mounted) return;

    final info = parseGitHubUrl(url);
    if (info == null) return;

    final zipFile = await downloadGitHubArchive(info);
    if (zipFile == null || !mounted) {
      if (mounted) {
        showAppSnackBar(
          context,
          message: l10n.skillsGitHubDownloadFailed,
          type: NotificationType.error,
        );
      }
      return;
    }

    try {
      final discovered = _scanZipForSkills(
        zipFile,
        subPath: info.subPath,
        stripPrefix: info.stripPrefix,
      );

      if (discovered.isEmpty) {
        if (!mounted) return;
        showAppSnackBar(
          context,
          message: l10n.skillsImportFailed(0),
          type: NotificationType.error,
        );
        return;
      }

      List<_DiscoveredSkill> selected;
      if (discovered.length == 1) {
        selected = discovered;
      } else {
        if (!mounted) return;
        final result = await _showSkillSelectionDialog(discovered);
        if (result == null || result.isEmpty) return;
        selected = result;
      }

      if (!mounted) return;
      await _importDiscoveredSkills(selected);
    } finally {
      try {
        await zipFile.delete();
      } catch (_) {}
    }
  }

  List<_DiscoveredSkill> _scanZipForSkills(
    File file, {
    String? subPath,
    String? stripPrefix,
  }) {
    final discovered = <_DiscoveredSkill>[];
    try {
      final bytes = file.readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);

      final skillDirs = <String>{};
      final allFiles = <String, List<int>>{};

      for (final entry in archive) {
        if (!entry.isFile) continue;

        var relativePath = entry.name;
        if (stripPrefix != null && relativePath.startsWith(stripPrefix)) {
          relativePath = relativePath.substring(stripPrefix.length);
        }
        if (subPath != null && subPath.isNotEmpty) {
          final normalized = subPath.endsWith('/') ? subPath : '$subPath/';
          if (!relativePath.startsWith(normalized) && relativePath != subPath) {
            continue;
          }
        }

        if (_isExcludedPath(relativePath)) continue;
        if (entry.size > _maxImportFileSize) continue;

        allFiles[relativePath] = entry.content as List<int>;

        if (p.basename(relativePath) == 'SKILL.md') {
          final dir = p.dirname(relativePath);
          skillDirs.add(dir == '.' ? '' : dir);
        }
      }

      for (final skillDir in skillDirs) {
        final skillMdKey = skillDir.isEmpty ? 'SKILL.md' : '$skillDir/SKILL.md';
        final skillMdBytes = allFiles[skillMdKey];
        if (skillMdBytes == null) continue;

        final content = utf8.decode(skillMdBytes);
        final parsed = SkillManager.parseFrontmatter(content);
        if (parsed == null) continue;
        final name = parsed.fields['name'];
        if (name == null || name.isEmpty) continue;

        final files = <String, String>{};
        final prefix = skillDir.isEmpty ? '' : '$skillDir/';
        for (final entry in allFiles.entries) {
          if (!entry.key.startsWith(prefix)) continue;
          final relativeToSkill = entry.key.substring(prefix.length);
          if (relativeToSkill.isEmpty) continue;
          files[relativeToSkill] = utf8.decode(
            entry.value,
            allowMalformed: true,
          );
        }

        discovered.add(
          _DiscoveredSkill(
            name: name,
            description: parsed.fields['description'] ?? '',
            files: files,
          ),
        );
      }
      archive.clear();
    } catch (_) {}
    return discovered;
  }

  static bool _isExcludedPath(String path) {
    final segments = path.split('/');
    for (final seg in segments) {
      if (seg.startsWith('.')) return true;
      if (seg == '__pycache__' || seg == 'node_modules') return true;
    }
    return false;
  }

  static const int _maxImportFileSize = 1024 * 1024;

  Future<List<_DiscoveredSkill>?> _showSkillSelectionDialog(
    List<_DiscoveredSkill> skills,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final selected = skills.length >= 5
        ? <int>{}
        : Set<int>.from(List.generate(skills.length, (i) => i));

    return showDialog<List<_DiscoveredSkill>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text(l10n.skillsGitHubSelectTitle),
              content: SizedBox(
                width: 400,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: skills.length,
                  itemBuilder: (_, i) {
                    final skill = skills[i];
                    return CheckboxListTile(
                      value: selected.contains(i),
                      title: Text(skill.name),
                      subtitle: skill.description.isNotEmpty
                          ? Text(
                              skill.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : null,
                      onChanged: (v) {
                        setDialogState(() {
                          if (v == true) {
                            selected.add(i);
                          } else {
                            selected.remove(i);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
                ),
                FilledButton(
                  onPressed: selected.isNotEmpty
                      ? () => Navigator.of(
                          ctx,
                        ).pop(selected.map((i) => skills[i]).toList())
                      : null,
                  child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _importDiscoveredSkills(List<_DiscoveredSkill> skills) async {
    int imported = 0;
    int failed = 0;

    for (final skill in skills) {
      final error = await SkillManager.saveSkillWithFiles(
        name: skill.name,
        files: skill.files,
      );
      if (error != null) {
        failed++;
      } else {
        imported++;
      }
    }

    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    if (imported > 0) {
      showAppSnackBar(context, message: l10n.skillsImportSuccess(imported));
    }
    if (failed > 0) {
      showAppSnackBar(
        context,
        message: l10n.skillsImportFailed(failed),
        type: NotificationType.error,
      );
    }
    await _refresh();
  }

  Future<void> _importFromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.path == null) return;

    final path = file.path!;
    final ext = p.extension(path).toLowerCase();

    if (ext == '.zip') {
      final discovered = _scanZipForSkills(File(path));
      if (discovered.isEmpty) {
        if (!mounted) return;
        final l10n = AppLocalizations.of(context)!;
        showAppSnackBar(
          context,
          message: l10n.skillsImportFailed(0),
          type: NotificationType.error,
        );
        return;
      }
      await _importDiscoveredSkills(discovered);
    } else {
      int imported = 0;
      int failed = 0;
      try {
        final content = await File(path).readAsString();
        final name = _extractNameFromFrontmatter(content);
        if (name == null) {
          failed++;
        } else {
          final error = await SkillManager.saveSkill(
            name: name,
            content: content,
          );
          if (error != null) {
            failed++;
          } else {
            imported++;
          }
        }
      } catch (_) {
        failed++;
      }

      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      if (imported > 0) {
        showAppSnackBar(context, message: l10n.skillsImportSuccess(imported));
      }
      if (failed > 0) {
        showAppSnackBar(
          context,
          message: l10n.skillsImportFailed(failed),
          type: NotificationType.error,
        );
      }
      await _refresh();
    }
  }

  Future<void> _deleteSkill(String name) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.skillsDeleteConfirmTitle),
        content: Text(l10n.skillsDeleteConfirmMessage(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(l10n.skillsDeleteConfirmDeleteButton),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await SkillManager.deleteSkill(name);
    if (mounted) {
      context.read<AssistantProvider>().removeSkillFromAllAssistants(name);
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.skillsTitle),
        actions: [
          IconButton(
            icon: const Icon(Lucide.Upload),
            tooltip: l10n.skillsImportChoiceTitle,
            onPressed: _showImportChoice,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddDialog,
        child: const Icon(Lucide.Plus),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _skills.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  l10n.skillsEmptyMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: cs.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: () async => _refresh(),
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _skills.length,
                itemBuilder: (ctx, i) {
                  final skill = _skills[i];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: Icon(Lucide.BookOpen, color: cs.primary),
                      title: Text(
                        skill.name,
                        style: TextStyle(fontWeight: AppFontWeights.semibold),
                      ),
                      subtitle: skill.description.isNotEmpty
                          ? Text(
                              skill.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            )
                          : null,
                      trailing: IconButton(
                        icon: const Icon(Lucide.Trash2),
                        color: cs.error,
                        onPressed: () => _deleteSkill(skill.name),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

class _DiscoveredSkill {
  final String name;
  final String description;
  final Map<String, String> files;

  const _DiscoveredSkill({
    required this.name,
    required this.description,
    required this.files,
  });
}
