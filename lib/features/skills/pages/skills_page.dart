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
import '../../../shared/widgets/ios_checkbox.dart';
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
    await _promptEnableImported([name]);
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

      if (discovered == null) {
        if (!mounted) return;
        showAppSnackBar(
          context,
          message: l10n.skillsGitHubDownloadFailed,
          type: NotificationType.error,
        );
        return;
      }

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

  List<_DiscoveredSkill>? _scanZipForSkills(
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

        if (_isExcludedPath(relativePath) ||
            relativePath.contains('..') ||
            !p.isRelative(relativePath)) {
          continue;
        }
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

        final files = <String, List<int>>{};
        final prefix = skillDir.isEmpty ? '' : '$skillDir/';
        for (final entry in allFiles.entries) {
          if (!entry.key.startsWith(prefix)) continue;
          final relativeToSkill = entry.key.substring(prefix.length);
          if (relativeToSkill.isEmpty) continue;
          files[relativeToSkill] = entry.value;
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
    } catch (e) {
      debugPrint('_scanZipForSkills: failed to scan ZIP: $e');
      return null;
    }
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
            final allSelected = selected.length == skills.length;
            return AlertDialog(
              title: Text(l10n.skillsGitHubSelectTitle),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TactileSelectAllRow(
                      label: allSelected
                          ? l10n.skillsDeselectAll
                          : l10n.skillsSelectAll,
                      checked: allSelected,
                      onTap: () {
                        setDialogState(() {
                          selected.clear();
                          if (!allSelected) {
                            selected.addAll(
                              List.generate(skills.length, (i) => i),
                            );
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 4),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: skills.length,
                        itemBuilder: (_, i) {
                          final skill = skills[i];
                          return ListTile(
                            leading: IosCheckbox(
                              value: selected.contains(i),
                              onChanged: (v) {
                                setDialogState(() {
                                  if (v) {
                                    selected.add(i);
                                  } else {
                                    selected.remove(i);
                                  }
                                });
                              },
                            ),
                            title: Text(skill.name),
                            subtitle: skill.description.isNotEmpty
                                ? Text(
                                    skill.description,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : null,
                            onTap: () {
                              setDialogState(() {
                                if (selected.contains(i)) {
                                  selected.remove(i);
                                } else {
                                  selected.add(i);
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ],
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

  Future<void> _promptEnableImported(List<String> names) async {
    if (names.isEmpty || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final assistant = context.read<AssistantProvider>().currentAssistant;
    if (assistant == null) return;

    final enabled = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.skillsEnableImportedTitle),
        content: Text(
          l10n.skillsEnableImportedMessage(names.length, assistant.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.skillsEnableImportedDismiss),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.skillsEnableImportedAction),
          ),
        ],
      ),
    );
    if (enabled != true || !mounted) return;

    final ids = {...assistant.skillIds, ...names};
    await context.read<AssistantProvider>().updateAssistant(
      assistant.copyWith(skillIds: ids.toList(growable: false)),
    );
  }

  Future<void> _importDiscoveredSkills(List<_DiscoveredSkill> skills) async {
    int imported = 0;
    int failed = 0;
    final importedNames = <String>[];

    for (final skill in skills) {
      final error = await SkillManager.saveSkillWithFiles(
        name: skill.name,
        files: skill.files,
      );
      if (error != null) {
        failed++;
      } else {
        imported++;
        importedNames.add(skill.name);
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
    await _promptEnableImported(importedNames);
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
      if (discovered == null || discovered.isEmpty) {
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
      final importedNames = <String>[];
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
            importedNames.add(name);
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
      await _promptEnableImported(importedNames);
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
            icon: const Icon(Lucide.Download),
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
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final (group, skills) in groupSkillsByCategory(
                    _skills,
                  )) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                      child: Text(
                        group ?? l10n.skillsUncategorizedGroup,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: AppFontWeights.semibold,
                          color: cs.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                    for (final skill in skills)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Icon(Lucide.BookOpen, color: cs.primary),
                          title: Text(
                            skill.name,
                            style: TextStyle(
                              fontWeight: AppFontWeights.semibold,
                            ),
                          ),
                          subtitle: skill.description.isNotEmpty
                              ? Text(
                                  skill.description,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                )
                              : null,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 120,
                                ),
                                child: _CategoryTag(
                                  category: skill.category,
                                  label:
                                      skill.category ??
                                      l10n.skillsUncategorizedGroup,
                                  onTap: () => _editCategory(skill),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Lucide.Trash2),
                                color: cs.error,
                                onPressed: () => _deleteSkill(skill.name),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
    );
  }

  Future<void> _editCategory(SkillMetadata skill) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: skill.category ?? '');
    final known =
        _skills
            .map((s) => s.category)
            .whereType<String>()
            .where((c) => c.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text(l10n.skillsEditCategoryTitle),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: l10n.skillsCategoryHint,
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      style: const TextStyle(fontSize: 13),
                      onChanged: (_) => setDialogState(() {}),
                      onSubmitted: (_) =>
                          Navigator.of(ctx).pop(controller.text.trim()),
                    ),
                    if (known.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final c in known)
                            _CategorySuggestionPill(
                              label: c,
                              onTap: () {
                                controller.text = c;
                                setDialogState(() {});
                              },
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(''),
                  child: Text(l10n.skillsCategoryClear),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(ctx).pop(controller.text.trim()),
                  child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null || !mounted) return;
    final newCategory = result.trim();
    if (newCategory == (skill.category ?? '')) return;
    final error = await SkillManager.updateCategory(
      skill.name,
      newCategory.isEmpty ? null : newCategory,
    );
    if (error != null) {
      if (!mounted) return;
      showAppSnackBar(context, message: _localizeSaveError(error, l10n));
      return;
    }
    await _refresh();
  }
}

class _CategoryTag extends StatelessWidget {
  const _CategoryTag({
    required this.category,
    required this.label,
    required this.onTap,
  });
  final String? category;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasCategory = category != null && category!.isNotEmpty;
    final fg = hasCategory ? cs.primary : cs.onSurface.withValues(alpha: 0.45);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: hasCategory
              ? cs.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: hasCategory
                ? cs.primary.withValues(alpha: 0.3)
                : cs.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasCategory ? Lucide.Folder : Lucide.FolderOpen,
              size: 11,
              color: fg,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategorySuggestionPill extends StatelessWidget {
  const _CategorySuggestionPill({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cs.primary.withValues(alpha: 0.25)),
        ),
        child: Text(label, style: TextStyle(fontSize: 12, color: cs.primary)),
      ),
    );
  }
}

class _TactileSelectAllRow extends StatelessWidget {
  const _TactileSelectAllRow({
    required this.label,
    required this.checked,
    required this.onTap,
  });
  final String label;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          children: [
            IosCheckbox(value: checked, onChanged: (_) => onTap()),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 14, color: cs.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoveredSkill {
  final String name;
  final String description;
  final Map<String, List<int>> files;

  const _DiscoveredSkill({
    required this.name,
    required this.description,
    required this.files,
  });
}
