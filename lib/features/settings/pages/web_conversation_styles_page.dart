import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/web_conversation_style.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/network/dio_http_client.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_checkbox.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_settings_section.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../services/web_conversation_style_importer.dart';

class WebConversationStylesPage extends StatefulWidget {
  const WebConversationStylesPage({super.key, this.desktop = false});

  final bool desktop;

  @override
  State<WebConversationStylesPage> createState() =>
      _WebConversationStylesPageState();
}

class _WebConversationStylesPageState extends State<WebConversationStylesPage> {
  static const _importer = WebConversationStyleImporter();
  bool _busy = false;

  Future<void> _runImport(
    Future<List<WebConversationStyleCandidate>?> Function() discover,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      var candidates = await discover();
      if (candidates == null || !mounted) return;
      if (candidates.length > 1) {
        candidates = await _selectCandidates(candidates);
        if (candidates == null || candidates.isEmpty || !mounted) return;
      }
      final styles = _importer.validateBatch(candidates);
      await context.read<SettingsProvider>().importWebConversationStyles(
        styles,
      );
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      showAppSnackBar(
        context,
        message: l10n.webConversationStylesImportSuccess(styles.length),
        type: NotificationType.success,
      );
      final warningLines = <String>[
        for (final style in styles)
          for (final warning in style.warnings) '${style.name}: $warning',
      ];
      final warningCount = warningLines.length;
      if (warningCount > 0) {
        showAppSnackBar(
          context,
          message: l10n.webConversationStylesImportWarnings(warningCount),
          type: NotificationType.warning,
          duration: const Duration(seconds: 6),
        );
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(l10n.webConversationStylesImport),
            content: SizedBox(
              width: 520,
              child: SelectableText(
                '${l10n.webConversationStylesImportWarnings(warningCount)}\n\n'
                '${warningLines.join('\n')}',
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(MaterialLocalizations.of(context).okButtonLabel),
              ),
            ],
          ),
        );
      }
    } on Object catch (error, stackTrace) {
      debugPrint(
        'WebConversationStylesPage: import failed: $error\n$stackTrace',
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: AppLocalizations.of(
          context,
        )!.webConversationStylesImportFailed('$error'),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showImportChoice() async {
    final l10n = AppLocalizations.of(context)!;
    final choice = await showDialog<_ImportSource>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.webConversationStylesImportChoiceTitle),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              IosTileButton(
                label: l10n.webConversationStylesImportManual,
                icon: Lucide.Clipboard,
                onTap: () => Navigator.pop(dialogContext, _ImportSource.manual),
              ),
              const SizedBox(height: 10),
              IosTileButton(
                label: l10n.webConversationStylesImportFile,
                icon: Lucide.FileText,
                onTap: () => Navigator.pop(dialogContext, _ImportSource.file),
              ),
              const SizedBox(height: 10),
              IosTileButton(
                label: l10n.webConversationStylesImportGithub,
                icon: Lucide.GitFork,
                onTap: () => Navigator.pop(dialogContext, _ImportSource.github),
              ),
            ],
          ),
        ),
      ),
    );
    switch (choice) {
      case _ImportSource.manual:
        await _importManual();
      case _ImportSource.file:
        await _importFile();
      case _ImportSource.github:
        await _importGithub();
      case null:
        return;
    }
  }

  Future<void> _importManual() async {
    final controller = TextEditingController();
    final l10n = AppLocalizations.of(context)!;
    final source = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.webConversationStylesImportManualTitle),
        content: SizedBox(
          width: 520,
          child: IosFormTextField(
            label: l10n.webConversationStylesImportManual,
            controller: controller,
            hintText: l10n.webConversationStylesImportManualHint,
            minLines: 10,
            maxLines: 16,
            autofocus: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
    controller.dispose();
    if (source == null || source.trim().isEmpty) return;
    await _runImport(() async => [_importer.manual(source)]);
  }

  Future<void> _importFile() async {
    await _runImport(() async {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return null;
      final picked = result.files.single;
      final bytes =
          picked.bytes ??
          (picked.path == null ? null : await File(picked.path!).readAsBytes());
      if (bytes == null) {
        throw const WebConversationStyleImportException(
          WebConversationStyleImportErrorCode.invalidFileName,
        );
      }
      if (picked.name.toLowerCase().endsWith('.zip')) {
        return _importer.scanArchive(bytes);
      }
      return [_importer.singleFile(picked.name, bytes)];
    });
  }

  Future<void> _importGithub() async {
    final controller = TextEditingController();
    final l10n = AppLocalizations.of(context)!;
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.webConversationStylesGithubTitle),
        content: SizedBox(
          width: 520,
          child: IosFormTextField(
            label: l10n.webConversationStylesImportGithub,
            controller: controller,
            hintText: l10n.webConversationStylesGithubHint,
            autofocus: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null || url.trim().isEmpty) return;
    await _runImport(() {
      final settings = context.read<SettingsProvider>();
      return _importer.downloadGithub(url, proxy: _proxyConfig(settings));
    });
  }

  NetworkProxyConfig? _proxyConfig(SettingsProvider settings) {
    final host = settings.globalProxyHost.trim();
    final port = int.tryParse(settings.globalProxyPort.trim());
    if (!settings.globalProxyEnabled || host.isEmpty || port == null) {
      return null;
    }
    return NetworkProxyConfig(
      enabled: true,
      type: settings.globalProxyType,
      host: host,
      port: port,
      username: settings.globalProxyUsername.trim().isEmpty
          ? null
          : settings.globalProxyUsername.trim(),
      password: settings.globalProxyPassword.isEmpty
          ? null
          : settings.globalProxyPassword,
    );
  }

  Future<List<WebConversationStyleCandidate>?> _selectCandidates(
    List<WebConversationStyleCandidate> candidates,
  ) {
    final selected = <int>{
      for (var index = 0; index < candidates.length; index++) index,
    };
    return showDialog<List<WebConversationStyleCandidate>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final l10n = AppLocalizations.of(context)!;
          final allSelected = selected.length == candidates.length;
          return AlertDialog(
            title: Text(l10n.webConversationStylesSelectTitle),
            content: SizedBox(
              width: 520,
              height: 420,
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => setDialogState(() {
                        if (allSelected) {
                          selected.clear();
                        } else {
                          selected.addAll(
                            List.generate(candidates.length, (index) => index),
                          );
                        }
                      }),
                      child: Text(
                        allSelected
                            ? l10n.webConversationStylesDeselectAll
                            : l10n.webConversationStylesSelectAll,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      itemCount: candidates.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final selectedNow = selected.contains(index);
                        return IosCardPress(
                          onTap: () => setDialogState(() {
                            selectedNow
                                ? selected.remove(index)
                                : selected.add(index);
                          }),
                          borderRadius: BorderRadius.circular(10),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              IosCheckbox(
                                value: selectedNow,
                                onChanged: (_) => setDialogState(() {
                                  selectedNow
                                      ? selected.remove(index)
                                      : selected.add(index);
                                }),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  candidates[index].sourceName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(
                  MaterialLocalizations.of(context).cancelButtonLabel,
                ),
              ),
              FilledButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.pop(dialogContext, [
                        for (final index in selected) candidates[index],
                      ]),
                child: Text(MaterialLocalizations.of(context).okButtonLabel),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _activate(String? id) async {
    try {
      await context.read<SettingsProvider>().setActiveWebConversationStyle(id);
    } on Object catch (error, stackTrace) {
      debugPrint(
        'WebConversationStylesPage: activation failed: $error\n$stackTrace',
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: AppLocalizations.of(
          context,
        )!.webConversationStylesImportFailed('$error'),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _export(WebConversationStyle style) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final bytes = utf8.encode(style.exportJson());
      final desktop =
          Platform.isMacOS || Platform.isWindows || Platform.isLinux;
      final path = await FilePicker.platform.saveFile(
        dialogTitle: l10n.webConversationStylesExport,
        fileName: '${style.id}$webConversationStyleFileSuffix',
        bytes: desktop ? null : bytes,
      );
      if (path == null) return;
      if (desktop) await File(path).writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.webConversationStylesExportSuccess,
        type: NotificationType.success,
      );
    } on Object catch (error, stackTrace) {
      debugPrint(
        'WebConversationStylesPage: export failed: $error\n$stackTrace',
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.webConversationStylesExportFailed('$error'),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _delete(WebConversationStyle style) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.webConversationStylesDeleteTitle),
        content: Text(l10n.webConversationStylesDeleteMessage(style.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n.webConversationStylesDeleteAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.read<SettingsProvider>().deleteWebConversationStyle(
        style.id,
      );
    } on Object catch (error, stackTrace) {
      debugPrint(
        'WebConversationStylesPage: delete failed: $error\n$stackTrace',
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.webConversationStylesImportFailed('$error'),
        type: NotificationType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final l10n = AppLocalizations.of(context)!;
    final content = _buildContent(context, settings, l10n);
    if (widget.desktop) {
      return Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.webConversationStylesTitle,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: AppFontWeights.semibold,
                      ),
                    ),
                  ),
                  IosTileButton(
                    label: l10n.webConversationStylesImport,
                    icon: Lucide.Download,
                    enabled: !_busy,
                    onTap: _showImportChoice,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ),
            ),
            Expanded(child: content),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.webConversationStylesTitle),
        actions: [
          IosIconButton(
            icon: Lucide.Download,
            semanticLabel: l10n.webConversationStylesImport,
            enabled: !_busy,
            onTap: _showImportChoice,
            minSize: 44,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: content,
    );
  }

  Widget _buildContent(
    BuildContext context,
    SettingsProvider settings,
    AppLocalizations l10n,
  ) {
    final entries = settings.webConversationStyleLibrary.sortedEntries;
    final activeId = settings.webConversationStyleLibrary.activeId;
    final cs = Theme.of(context).colorScheme;
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            if (widget.desktop) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: IosSettingsSection(
                    children: [
                      IosSettingsSwitchRow(
                        icon: Lucide.Globe,
                        label: l10n
                            .displaySettingsPageExperimentalWebViewRenderingTitle,
                        subtitle: l10n
                            .displaySettingsPageExperimentalWebViewRenderingSubtitle,
                        value: settings.experimentalWebViewRendering,
                        onChanged: context
                            .read<SettingsProvider>()
                            .setExperimentalWebViewRendering,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (!settings.experimentalWebViewRendering)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.appColors.warningContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Lucide.info, size: 18, color: cs.onSurface),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l10n.webConversationStylesInactiveNotice,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withValues(alpha: 0.82),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Align(
                alignment: Alignment.topCenter,
                child: IosSettingsSection(
                  children: [
                    _StyleRow(
                      name: l10n.webConversationStylesDefaultName,
                      description: l10n.webConversationStylesDefaultDescription,
                      active: activeId == null,
                      onActivate: () => _activate(null),
                    ),
                    for (var index = 0; index < entries.length; index++) ...[
                      const IosSettingsDivider(),
                      _StyleRow(
                        key: ValueKey(entries[index].id),
                        name: entries[index].name,
                        description:
                            entries[index].description?.trim().isNotEmpty ==
                                true
                            ? entries[index].description!
                            : l10n.webConversationStylesNoDescription,
                        active: activeId == entries[index].id,
                        onActivate: () => _activate(entries[index].id),
                        onExport: () => _export(entries[index]),
                        onDelete: () => _delete(entries[index]),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 18),
                child: Text(
                  l10n.webConversationStylesEmpty,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurface.withValues(alpha: 0.58)),
                ),
              ),
          ],
        ),
        if (_busy)
          const Positioned.fill(
            child: AbsorbPointer(
              child: Center(child: CircularProgressIndicator.adaptive()),
            ),
          ),
      ],
    );
  }
}

enum _ImportSource { manual, file, github }

class _StyleRow extends StatelessWidget {
  const _StyleRow({
    super.key,
    required this.name,
    required this.description,
    required this.active,
    required this.onActivate,
    this.onExport,
    this.onDelete,
  });

  final String name;
  final String description;
  final bool active;
  final VoidCallback onActivate;
  final VoidCallback? onExport;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      onTap: active ? null : onActivate,
      baseColor: context.appColors.surfaceCard,
      padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
      child: Row(
        children: [
          Icon(
            active ? Lucide.CheckCircle : Lucide.Square,
            size: 20,
            color: active ? cs.primary : cs.onSurface.withValues(alpha: 0.45),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: AppFontWeights.semibold,
                        ),
                      ),
                    ),
                    if (active) ...[
                      const SizedBox(width: 8),
                      Text(
                        l10n.webConversationStylesActive,
                        style: TextStyle(fontSize: 12, color: cs.primary),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.62),
                  ),
                ),
              ],
            ),
          ),
          if (!active)
            Tooltip(
              message: l10n.webConversationStylesUseStyle,
              child: IosIconButton(
                icon: Lucide.Check,
                semanticLabel: l10n.webConversationStylesUseStyle,
                onTap: onActivate,
              ),
            ),
          if (onExport != null)
            Tooltip(
              message: l10n.webConversationStylesExport,
              child: IosIconButton(
                icon: Lucide.Upload,
                semanticLabel: l10n.webConversationStylesExport,
                onTap: onExport,
              ),
            ),
          if (onDelete != null)
            Tooltip(
              message: l10n.webConversationStylesDeleteAction,
              child: IosIconButton(
                icon: Lucide.Trash2,
                color: cs.error,
                semanticLabel: l10n.webConversationStylesDeleteAction,
                onTap: onDelete,
              ),
            ),
        ],
      ),
    );
  }
}
