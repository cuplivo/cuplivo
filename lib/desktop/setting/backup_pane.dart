import 'package:Cuplivo/core/database/business_preferences.dart';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../core/models/backup.dart';
import '../../core/providers/backup_provider.dart';
import '../../core/providers/backup_reminder_provider.dart';
import '../../core/providers/s3_backup_provider.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/services/chat/chat_service.dart';
import '../../core/services/backup/chatbox_importer.dart';
import '../../core/services/backup/cherry_importer.dart';
import '../../core/services/backup/data_sync.dart';
import '../../core/services/backup/restore_refresher.dart';
import '../../utils/platform_utils.dart';
import '../../shared/widgets/ios_switch.dart';
import '../../shared/widgets/loading_dialog_card.dart';
import '../../shared/widgets/snackbar.dart';
import '../../shared/dialogs/incremental_backup_dialog.dart';
import '../../shared/dialogs/restart_required_dialog.dart';
import '../../shared/dialogs/rikkahub_migrate_dialog.dart';
import '../../shared/dialogs/kelivo_import_dialog.dart';
import '../../shared/dialogs/kelivo_compat_dialog.dart';
import '../../utils/format.dart';
import '../../features/backup/widgets/backup_channel_config_dialog.dart';
import '../../features/backup/widgets/backup_reminder_helpers.dart';
import '../../features/backup/widgets/backup_hero_card.dart';
import '../../features/backup/widgets/backup_action_row.dart';
import '../../features/backup/widgets/backup_migration_dialog.dart';
import '../../shared/widgets/segmented_toggle.dart';
import '../../shared/widgets/lan_sync_section.dart';
import '../../core/models/incremental_backup.dart';
import '../widgets/desktop_select_dropdown.dart';
import '../../theme/app_font_weights.dart';
import '../../theme/app_semantic_colors.dart';

class DesktopBackupPane extends StatefulWidget {
  const DesktopBackupPane({super.key});
  @override
  State<DesktopBackupPane> createState() => _DesktopBackupPaneState();
}

class _DesktopBackupPaneState extends State<DesktopBackupPane> {
  /// Runs a backup task behind a modal dialog with a live stage label
  /// (生成文件 → 整合压缩 → 上传) and an elapsed-seconds ticker. Throws
  /// propagate to the caller after the dialog pops.
  Future<T> _runStageTask<T>(
    BuildContext context,
    Future<T> Function(BackupStageCallback onStage) task, {
    String? label,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final stageLabel = ValueNotifier<String>(l10n.backupStageGenerating);
    try {
      return await runWithLoadingDialog(
        context,
        () => task((stage) => stageLabel.value = backupStageLabel(l10n, stage)),
        label: label ?? l10n.backupPageExporting,
        elapsedTextBuilder: l10n.backupPageExportElapsed,
        labelListenable: stageLabel,
      );
    } finally {
      stageLabel.dispose();
    }
  }

  /// Best-effort: recording the backup reminder is a non-critical side effect
  /// after a success — its failure must not surface as an error snackbar.
  Future<void> _recordReminderQuietly(BuildContext context) async {
    try {
      await context.read<BackupReminderProvider>().recordBackupCompleted();
    } catch (e) {
      debugPrint('BackupExport: recordBackupCompleted failed: $e');
    }
  }

  /// Local FilePicker export of a backup ZIP — full ([format]) or
  /// [incremental] pack, then save dialog, then staging cleanup.
  /// [recordBackupReminder] records the last-backup time on success — local
  /// incremental passes the dialog's "update backup time" checkbox here.
  Future<void> _saveLocalZip(
    BuildContext context, {
    BackupFormat format = BackupFormat.jsonl,
    IncrementalBackupConfig? incremental,
    bool recordBackupReminder = true,
  }) async {
    final backupProvider = context.read<BackupProvider>();
    final l10n = AppLocalizations.of(context)!;
    final File file;
    final stopwatch = Stopwatch()..start();
    try {
      debugPrint('BackupExport: pack begin');
      file = await _runStageTask(
        context,
        (onStage) => incremental != null
            ? backupProvider.incrementalExportToFile(
                incremental,
                onStage: onStage,
              )
            : backupProvider.exportToFile(onStage: onStage, format: format),
      );
      stopwatch.stop();
      debugPrint(
        'BackupExport: pack done in ${stopwatch.elapsedMilliseconds} ms -> '
        '${file.path}',
      );
    } catch (e) {
      debugPrint(
        'BackupExport: pack failed after ${stopwatch.elapsedMilliseconds} ms: '
        '$e',
      );
      if (context.mounted) {
        showAppSnackBar(
          context,
          message: l10n.backupPageExportFailed(e.toString()),
          type: NotificationType.error,
        );
      }
      return;
    }
    try {
      final String? savePath;
      try {
        savePath = await FilePicker.platform.saveFile(
          dialogTitle: l10n.backupPageExportToFile,
          fileName: file.uri.pathSegments.last,
          type: FileType.custom,
          allowedExtensions: ['zip'],
        );
        debugPrint('BackupExport: FilePicker result=$savePath');
      } catch (e) {
        debugPrint('BackupExport: picker failed: $e');
        if (context.mounted) {
          showAppSnackBar(
            context,
            message: l10n.backupPageExportFailed(e.toString()),
            type: NotificationType.error,
          );
        }
        return;
      }
      if (savePath != null) {
        try {
          await File(savePath).parent.create(recursive: true);
          await file.copy(savePath);
          debugPrint('BackupExport: copied to $savePath');
          if (context.mounted && recordBackupReminder) {
            await _recordReminderQuietly(context);
          }
        } catch (e) {
          debugPrint('BackupExport: copy failed: $e');
          if (context.mounted) {
            showAppSnackBar(
              context,
              message: l10n.backupPageExportFailed(e.toString()),
              type: NotificationType.error,
            );
          }
        }
      }
    } finally {
      await DataSync.cleanupTemporaryBackupFile(file);
    }
  }

  BackupDestination _destination = BackupDestination.local;

  /// Runs a restore behind the shared modal overlay (see
  /// [runRestoreWithProgressOverlay]).
  Future<void> _runRestoreWithProgress(
    BuildContext context,
    Future<void> Function(RestoreProgressCallback onProgress) task,
  ) => runRestoreWithProgressOverlay(context, task);

  Future<void> _chooseRestoreModeAndRun(
    Future<void> Function(RestoreMode mode, RestoreProgressCallback onProgress)
    action,
  ) async {
    final rootCtx = Navigator.of(context, rootNavigator: true).context;
    final mode = await showDialog<RestoreMode>(
      context: context,
      builder: (ctx) => _RestoreModeDialog(),
    );
    if (mode == null) return;
    if (!rootCtx.mounted) return;
    try {
      await _runRestoreWithProgress(
        rootCtx,
        (onProgress) => action(mode, onProgress),
      );
    } catch (e) {
      if (!rootCtx.mounted) return;
      if (await maybeShowKelivoCompatError(rootCtx, e)) return;
      if (!rootCtx.mounted) return;
      showAppSnackBar(
        rootCtx,
        message: e.toString(),
        type: NotificationType.error,
      );
      return;
    }
    if (!rootCtx.mounted) return;
    await showRestartRequiredDialog(rootCtx);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final reminder = context.watch<BackupReminderProvider>();
    final webdavVm = context.watch<BackupProvider>();
    final s3Vm = context.watch<S3BackupProvider>();
    final busy = webdavVm.busy || s3Vm.busy;
    final webdavEnabled = webdavVm.config.isConfigured;
    final s3Enabled = s3Vm.config.isConfigured;

    final scope = webdavVm.config.content;
    final scopeOptions =
        <(String, BackupContentScope Function(BackupContentScope))>[
          (
            l10n.backupScopeChatsAssistants,
            (s) => s.copyWith(chatsAndAssistants: !s.chatsAndAssistants),
          ),
          (l10n.backupScopeSettings, (s) => s.copyWith(settings: !s.settings)),
          (
            l10n.backupScopeAttachments,
            (s) => s.copyWith(attachments: !s.attachments),
          ),
          (
            l10n.backupScopeWorkspaces,
            (s) => s.copyWith(workspaces: !s.workspaces),
          ),
          (l10n.backupScopeSkills, (s) => s.copyWith(skills: !s.skills)),
          (
            l10n.backupScopeFontsAvatars,
            (s) => s.copyWith(fontsAndAvatars: !s.fontsAndAvatars),
          ),
        ];

    return Container(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: CustomScrollView(
            slivers: [
              // Title row
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 36,
                  child: Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            l10n.backupPageTitle,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: AppFontWeights.regular,
                              color: cs.onSurface.withValues(alpha: 0.9),
                            ),
                          ),
                        ),
                      ),
                      if (busy) const SizedBox(width: 8),
                      if (busy)
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.0,
                            color: cs.primary,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 8)),

              // ① Status + full lifecycle (destination picker + one CTA row:
              // full / incremental / restore — all on the destination).
              SliverToBoxAdapter(
                child: BackupHeroCard(
                  destination: _destination,
                  onDestinationChanged: (d) => setState(() => _destination = d),
                  onBackupNow: () => _heroBackupNow(context),
                  onIncremental: () => _heroIncremental(context),
                  onRestore: () => _heroRestore(context),
                  onConfigureWebDav: () => _openWebDavConfig(context),
                  onConfigureS3: () => _openS3Config(context),
                  busy: busy,
                  webdavEnabled: webdavEnabled,
                  s3Enabled: s3Enabled,
                  lastBackupAt: reminder.lastBackupAt,
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),

              // ② 局域网同步 first (own card+header); the migration entry
              // right after — no "export" section header.
              const SliverToBoxAdapter(child: LanSyncSection()),
              const SliverToBoxAdapter(child: SizedBox(height: 10)),

              // ③ 数据迁移 — rare "move house" ops behind one row +
              // grouped chooser dialog.
              SliverToBoxAdapter(
                child: BackupActionRow(
                  icon: lucide.Lucide.Import,
                  label: l10n.backupMigrateTitle,
                  subtitle: l10n.backupMigrateRowSubtitle,
                  onTap: () => showBackupMigrationChooser(
                    context,
                    onExportKelivo: () => _saveLocalZip(
                      context,
                      format: BackupFormat.kelivoLegacy,
                    ),
                    onImportKelivo: () =>
                        showKelivoImportDialog(context: context),
                    onImportRikkaHub: () =>
                        showRikkaHubMigrateDialog(context: context),
                    onImportCherryStudio: () => _importCherry(context, cs),
                    onImportChatbox: () => _importChatbox(context, cs),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 10)),

              // ⑤ 备份内容 — 6-section scope (assistant "能力" look, 2×3)
              SliverToBoxAdapter(
                child: _sectionCard(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        l10n.backupPageContentLabel,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: AppFontWeights.semibold,
                          color: cs.onSurface.withValues(alpha: 0.95),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 2, 0, 8),
                      child: SegmentedToggleMulti(
                        options: [for (final o in scopeOptions) o.$1],
                        isSelected: [
                          scope.chatsAndAssistants,
                          scope.settings,
                          scope.attachments,
                          scope.workspaces,
                          scope.skills,
                          scope.fontsAndAvatars,
                        ],
                        itemsPerRow: 3,
                        onChanged: (i) => _applyScopeBit(
                          context,
                          webdavVm,
                          s3Vm,
                          scopeOptions[i].$2(scope),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 10)),

              // ⑥ 备份提醒 — switch + rows; due adds an extra row, never
              // replaces anything.
              SliverToBoxAdapter(
                child: _sectionCard(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        l10n.backupReminderSectionTitle,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: AppFontWeights.semibold,
                          color: cs.onSurface.withValues(alpha: 0.95),
                        ),
                      ),
                    ),
                    if (reminder.shouldShowReminder) ...[
                      BackupActionRow(
                        icon: lucide.Lucide.TriangleAlert,
                        label: l10n.backupHeroDueTitle,
                        value: backupReminderDateTimeLabel(
                          context,
                          reminder.lastBackupAt,
                        ),
                        dotColor: context.appColors.warning,
                        onTap: () => _heroBackupNow(context),
                      ),
                      _rowDivider(context),
                    ],
                    _ItemRow(
                      label: l10n.backupReminderEnableTitle,
                      vpad: 2,
                      trailing: IosSwitch(
                        value: reminder.enabled,
                        onChanged: (value) async {
                          final provider = context
                              .read<BackupReminderProvider>();
                          if (!value) {
                            await provider.setEnabled(false);
                            return;
                          }
                          final minutes = await showBackupReminderTimePicker(
                            context,
                            initialMinutes: provider.reminderMinutesOfDay,
                          );
                          if (minutes == null) return;
                          await provider.saveSchedule(
                            enabled: true,
                            intervalDays: provider.intervalDays,
                            reminderMinutesOfDay: minutes,
                          );
                        },
                      ),
                    ),
                    if (reminder.enabled) ...[
                      _rowDivider(context),
                      _ItemRow(
                        label: l10n.backupReminderFrequencyTitle,
                        trailing: _FrequencyDropdown(reminder: reminder),
                      ),
                      _rowDivider(context),
                      _ItemRow(
                        label: l10n.backupReminderTimeTitle,
                        trailing: _DeskIosButton(
                          label: backupReminderTimeLabel(
                            context,
                            reminder.reminderMinutesOfDay,
                          ),
                          filled: false,
                          dense: true,
                          onTap: () async {
                            final provider = context
                                .read<BackupReminderProvider>();
                            final minutes = await showBackupReminderTimePicker(
                              context,
                              initialMinutes: provider.reminderMinutesOfDay,
                            );
                            if (minutes == null) return;
                            await provider.saveSchedule(
                              enabled: true,
                              intervalDays: provider.intervalDays,
                              reminderMinutesOfDay: minutes,
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 10)),

              // ⑦ 备份渠道 — WebDAV/S3 own card
              SliverToBoxAdapter(
                child: _sectionCard(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        l10n.backupPageChannelManagement,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: AppFontWeights.semibold,
                          color: cs.onSurface.withValues(alpha: 0.95),
                        ),
                      ),
                    ),
                    BackupActionRow(
                      icon: lucide.Lucide.databaseBackup,
                      label: l10n.backupPageWebDavBackup,
                      value: webdavEnabled
                          ? l10n.backupPageChannelEnabled
                          : l10n.backupPageChannelNotConfigured,
                      dotColor: webdavEnabled
                          ? context.appColors.success
                          : cs.onSurface.withValues(alpha: 0.25),
                      enabled: !busy,
                      onTap: busy ? null : () => _openWebDavConfig(context),
                    ),
                    _rowDivider(context),
                    BackupActionRow(
                      icon: lucide.Lucide.Globe,
                      label: l10n.backupPageS3Backup,
                      value: s3Enabled
                          ? l10n.backupPageChannelEnabled
                          : l10n.backupPageChannelNotConfigured,
                      dotColor: s3Enabled
                          ? context.appColors.success
                          : cs.onSurface.withValues(alpha: 0.25),
                      enabled: !busy,
                      onTap: busy ? null : () => _openS3Config(context),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Hero restore: read back from the SELECTED destination — the mirror
  /// image of the two backup actions. Unconfigured remotes fall through to
  /// their config dialog (the enable path).
  Future<void> _heroRestore(BuildContext context) async {
    final webdavVm = context.read<BackupProvider>();
    final s3Vm = context.read<S3BackupProvider>();
    switch (_destination) {
      case BackupDestination.local:
        await _importLocalBackup(context);
      case BackupDestination.webdav:
        if (!webdavVm.config.isConfigured) {
          await _openWebDavConfig(context);
        } else {
          _showRemoteRestore(context, BackupChannel.webdav);
        }
      case BackupDestination.s3:
        if (!s3Vm.config.isConfigured) {
          await _openS3Config(context);
        } else {
          _showRemoteRestore(context, BackupChannel.s3);
        }
    }
  }

  /// Hero CTA: dispatch by the selected destination.
  Future<void> _heroBackupNow(BuildContext context) async {
    switch (_destination) {
      case BackupDestination.local:
        await _saveLocalZip(context);
      case BackupDestination.webdav:
        await _runWebDavBackupNow(context, context.read<BackupProvider>());
      case BackupDestination.s3:
        await _runS3BackupNow(context, context.read<S3BackupProvider>());
    }
  }

  /// Hero incremental link: dispatch by the selected destination, applying
  /// the chosen scope back to both channel configs (persisted).
  Future<void> _heroIncremental(BuildContext context) async {
    final vm = context.read<BackupProvider>();
    final initialScope = vm.config.content;
    switch (_destination) {
      case BackupDestination.local:
        await _runLocalIncremental(context, initialScope: initialScope);
      case BackupDestination.webdav:
        await _runWebDavIncremental(context, vm, initialScope: initialScope);
      case BackupDestination.s3:
        await _runS3Incremental(
          context,
          context.read<S3BackupProvider>(),
          initialScope: initialScope,
        );
    }
  }

  /// Toggle one backup-content bit on BOTH channel configs.
  Future<void> _applyScopeBit(
    BuildContext context,
    BackupProvider vm,
    S3BackupProvider s3Vm,
    BackupContentScope next,
  ) async {
    final settings = context.read<SettingsProvider>();
    final newW = vm.config.copyWith(content: next);
    await settings.setWebDavConfig(newW);
    vm.updateConfig(newW);
    final newS = s3Vm.config.copyWith(content: next);
    await settings.setS3Config(newS);
    s3Vm.updateConfig(newS);
  }

  Future<void> _openWebDavConfig(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final vm = context.read<BackupProvider>();
    await BackupChannelConfigDialog.show(
      context,
      channel: BackupChannel.webdav,
      webdavCfg: vm.config,
      onTestWebDav: (draft) async {
        final ok = await vm.test(config: draft);
        return ChannelTestResult(
          ok: ok,
          message: vm.message ?? l10n.backupPageTestDone,
        );
      },
      onSaveWebDav: (c) async {
        await context.read<SettingsProvider>().setWebDavConfig(c);
        vm.updateConfig(c);
        // Saving a config signals intent to use this channel.
        if (c.isConfigured && mounted) {
          setState(() => _destination = BackupDestination.webdav);
        }
      },
    );
  }

  Future<void> _openS3Config(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final vm = context.read<S3BackupProvider>();
    await BackupChannelConfigDialog.show(
      context,
      channel: BackupChannel.s3,
      s3Cfg: vm.config,
      onTestS3: (draft) async {
        final ok = await vm.test(config: draft);
        return ChannelTestResult(
          ok: ok,
          message: vm.message ?? l10n.backupPageTestDone,
        );
      },
      onSaveS3: (c) async {
        await context.read<SettingsProvider>().setS3Config(c);
        vm.updateConfig(c);
        if (c.isConfigured && mounted) {
          setState(() => _destination = BackupDestination.s3);
        }
      },
    );
  }

  Future<void> _runWebDavBackupNow(
    BuildContext context,
    BackupProvider provider,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final success = await _runStageTask(
      context,
      (onStage) => provider.backup(onStage: onStage),
    );
    if (!context.mounted) return;
    if (success) {
      await _recordReminderQuietly(context);
      if (!context.mounted) return;
    }
    final message = provider.message ?? l10n.backupPageBackupUploaded;
    showAppSnackBar(context, message: message, type: NotificationType.info);
  }

  Future<void> _runS3BackupNow(
    BuildContext context,
    S3BackupProvider provider,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final success = await _runStageTask(
      context,
      (onStage) => provider.backup(onStage: onStage),
    );
    if (!context.mounted) return;
    if (success) {
      await _recordReminderQuietly(context);
      if (!context.mounted) return;
    }
    final message = provider.message ?? l10n.backupPageBackupUploaded;
    showAppSnackBar(context, message: message, type: NotificationType.info);
  }

  Future<void> _importLocalBackup(BuildContext context) async {
    final backupProvider = context.read<BackupProvider>();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null) return;
    final f = File(path);
    await _chooseRestoreModeAndRun((mode, onProgress) async {
      await backupProvider.restoreFromLocalFile(
        f,
        mode: mode,
        onProgress: onProgress,
      );
    });
  }

  /// Restore a remote backup list for [channel] (configured only — rows
  /// route to the config dialog otherwise).
  void _showRemoteRestore(BuildContext context, BackupChannel channel) {
    final isS3 = channel == BackupChannel.s3;
    final l10n = AppLocalizations.of(context)!;
    final suffix = isS3 ? '(S3)' : '(WebDAV)';
    final webdavTm = context.read<BackupProvider>();
    final s3Tm = context.read<S3BackupProvider>();
    _showRemoteBackupsDialog(
      context,
      title: '${l10n.backupPageRemoteBackups} $suffix',
      listRemote: isS3 ? s3Tm.listRemote : webdavTm.listRemote,
      restoreFromItem: (it, mode, onProgress) => isS3
          ? s3Tm.restoreFromItem(it, mode: mode, onProgress: onProgress)
          : webdavTm.restoreFromItem(it, mode: mode, onProgress: onProgress),
      deleteAndReload: isS3 ? s3Tm.deleteAndReload : webdavTm.deleteAndReload,
    );
  }

  Future<void> _runLocalIncremental(
    BuildContext context, {
    BackupContentScope? initialScope,
  }) async {
    final backupProvider = context.read<BackupProvider>();
    final config = await IncrementalBackupDialog.show(
      context,
      lastBackupTime: context.read<BackupReminderProvider>().lastBackupAt,
      initialScope: initialScope ?? backupProvider.config.content,
      analyzer: backupProvider.analyzeIncrementalScope,
    );
    if (config == null || !context.mounted) return;
    if (config.contentScope != null) {
      await _applyScopeBit(
        context,
        backupProvider,
        context.read<S3BackupProvider>(),
        config.contentScope!,
      );
      if (!context.mounted) return;
    }
    await _saveLocalZip(
      context,
      incremental: config,
      recordBackupReminder: config.updateBackupTime,
    );
  }

  Future<void> _runWebDavIncremental(
    BuildContext context,
    BackupProvider provider, {
    BackupContentScope? initialScope,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final config = await IncrementalBackupDialog.show(
      context,
      lastBackupTime: context.read<BackupReminderProvider>().lastBackupAt,
      initialScope: initialScope ?? provider.config.content,
      analyzer: provider.analyzeIncrementalScope,
    );
    if (config == null || !context.mounted) return;
    if (config.contentScope != null) {
      await _applyScopeBit(
        context,
        provider,
        context.read<S3BackupProvider>(),
        config.contentScope!,
      );
      if (!context.mounted) return;
    }
    final success = await _runStageTask(
      context,
      (onStage) => provider.incrementalBackup(config, onStage: onStage),
    );
    if (!context.mounted) return;
    if (success && config.updateBackupTime) {
      await context.read<BackupReminderProvider>().recordBackupCompleted();
    }
    if (!context.mounted) return;
    final rawMessage = provider.message;
    final message = rawMessage ?? l10n.backupPageBackupUploaded;
    showAppSnackBar(context, message: message, type: NotificationType.info);
  }

  Future<void> _runS3Incremental(
    BuildContext context,
    S3BackupProvider provider, {
    BackupContentScope? initialScope,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final config = await IncrementalBackupDialog.show(
      context,
      lastBackupTime: context.read<BackupReminderProvider>().lastBackupAt,
      initialScope: initialScope ?? provider.config.content,
      analyzer: provider.analyzeIncrementalScope,
    );
    if (config == null || !context.mounted) return;
    if (config.contentScope != null) {
      await _applyScopeBit(
        context,
        context.read<BackupProvider>(),
        provider,
        config.contentScope!,
      );
      if (!context.mounted) return;
    }
    final success = await _runStageTask(
      context,
      (onStage) => provider.incrementalBackup(config, onStage: onStage),
    );
    if (!context.mounted) return;
    if (success && config.updateBackupTime) {
      await context.read<BackupReminderProvider>().recordBackupCompleted();
    }
    if (!context.mounted) return;
    final rawMessage = provider.message;
    final message = rawMessage ?? l10n.backupPageBackupUploaded;
    showAppSnackBar(context, message: message, type: NotificationType.info);
  }

  Future<void> _importCherry(BuildContext context, ColorScheme cs) async {
    final rootCtx = Navigator.of(context, rootNavigator: true).context;
    final l10n = AppLocalizations.of(context)!;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null) return;
    final f = File(path);
    if (!context.mounted) return;
    final mode = await showDialog<RestoreMode>(
      context: context,
      builder: (_) => _RestoreModeDialog(),
    );
    if (mode == null) return;
    if (!context.mounted) return;
    final settings = context.read<SettingsProvider>();
    final chat = context.read<ChatService>();
    try {
      final res = await runWithLoadingDialog(
        context,
        () => CherryImporter.importFromCherryStudio(
          file: f,
          mode: mode,
          settings: settings,
          chatService: chat,
          preferences: context.read<BusinessPreferences>(),
        ),
        label: l10n.backupPageImportInProgress,
        elapsedTextBuilder: l10n.backupPageImportElapsed,
      );
      if (!rootCtx.mounted) return;
      await showDialog(
        context: rootCtx,
        barrierDismissible: false,
        builder: (dctx) => PopScope(
          // Import contract matches restore: restart is required for the
          // imported data to take effect.
          canPop: false,
          child: AlertDialog(
            backgroundColor: cs.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Text(l10n.backupPageRestartRequired),
            content: Text(
              '${l10n.backupPageImportFromCherryStudio}:\n'
              '${l10n.backupPageImportStats(res.assistants, res.conversations, res.files, res.messages, res.providers)}\n\n'
              '${l10n.backupPageRestartContent}',
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  Navigator.of(rootCtx).pop();
                  PlatformUtils.restartApp();
                },
                child: Text(l10n.backupPageOK),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (!rootCtx.mounted) return;
      await showDialog(
        context: rootCtx,
        builder: (dctx) => AlertDialog(
          backgroundColor: cs.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(l10n.backupPageImportFromCherryStudio),
          content: Text(e.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: Text(l10n.backupPageOK),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _importChatbox(BuildContext context, ColorScheme cs) async {
    final rootCtx = Navigator.of(context, rootNavigator: true).context;
    final l10n = AppLocalizations.of(context)!;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null) return;
    final f = File(path);
    if (!context.mounted) return;
    final mode = await showDialog<RestoreMode>(
      context: context,
      builder: (_) => _RestoreModeDialog(),
    );
    if (mode == null) return;
    if (!context.mounted) return;
    final settings = context.read<SettingsProvider>();
    final chat = context.read<ChatService>();
    try {
      final res = await runWithLoadingDialog(
        context,
        () => ChatboxImporter.importFromChatbox(
          file: f,
          mode: mode,
          settings: settings,
          chatService: chat,
          preferences: context.read<BusinessPreferences>(),
        ),
        label: l10n.backupPageImportInProgress,
        elapsedTextBuilder: l10n.backupPageImportElapsed,
      );
      if (!rootCtx.mounted) return;
      await showDialog(
        context: rootCtx,
        builder: (dctx) => AlertDialog(
          backgroundColor: cs.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(l10n.backupPageRestartRequired),
          content: Text(
            '${l10n.backupPageImportFromChatbox}:\n'
            '${l10n.backupPageImportStatsNoFiles(res.assistants, res.conversations, res.messages, res.providers)}\n\n'
            '${l10n.backupPageRestartContent}',
          ),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.of(rootCtx).pop();
                PlatformUtils.restartApp();
              },
              child: Text(l10n.backupPageOK),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!rootCtx.mounted) return;
      await showDialog(
        context: rootCtx,
        builder: (dctx) => AlertDialog(
          backgroundColor: cs.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(l10n.backupPageImportFromChatbox),
          content: Text(e.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: Text(l10n.backupPageOK),
            ),
          ],
        ),
      );
    }
  }
}

class _FrequencyDropdown extends StatelessWidget {
  const _FrequencyDropdown({required this.reminder});

  final BackupReminderProvider reminder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final current = reminder.intervalDays;
    final preset = BackupReminderProvider.presetIntervals;
    final options = <DesktopSelectOption<int>>[
      for (final days in preset)
        DesktopSelectOption(
          value: days,
          label: backupReminderFrequencyLabel(l10n, days),
        ),
      if (!preset.contains(current))
        DesktopSelectOption(
          value: current,
          label: backupReminderFrequencyLabel(l10n, current),
        ),
      DesktopSelectOption(value: 0, label: l10n.backupReminderCustomOption),
    ];

    return DesktopSelectDropdown<int>(
      value: current,
      options: options,
      minWidth: 150,
      onSelected: (value) async {
        final provider = context.read<BackupReminderProvider>();
        final days = value == 0
            ? await showBackupReminderCustomDaysDialog(
                context,
                initialDays: provider.intervalDays,
              )
            : value;
        if (!context.mounted) return;
        if (days == null) return;
        var minutes = provider.reminderMinutesOfDay;
        minutes ??= await showBackupReminderTimePicker(context);
        if (!context.mounted) return;
        if (minutes == null) return;
        await provider.saveSchedule(
          enabled: true,
          intervalDays: days,
          reminderMinutesOfDay: minutes,
        );
      },
    );
  }
}

class _RemoteItemCard extends StatefulWidget {
  const _RemoteItemCard({
    required this.item,
    required this.onRestore,
    required this.onDelete,
  });
  final BackupFileItem item;
  final VoidCallback onRestore;
  final VoidCallback onDelete;
  @override
  State<_RemoteItemCard> createState() => _RemoteItemCardState();
}

class _RemoteItemCardState extends State<_RemoteItemCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseBg = context.appColors.surfaceCard;
    final borderColor = _hover
        ? cs.primary.withValues(alpha: isDark ? 0.35 : 0.45)
        : cs.outlineVariant.withValues(alpha: isDark ? 0.12 : 0.08);
    final l10n = AppLocalizations.of(context)!;
    final dateStr =
        widget.item.lastModified?.toLocal().toString().split('.').first ?? '';

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: Container(
        decoration: BoxDecoration(
          color: baseBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: borderColor, width: 1.0),
        ),
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(lucide.Lucide.HardDrive, size: 20, color: cs.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.item.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: AppFontWeights.semibold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${formatBytes(widget.item.size)}${dateStr.isNotEmpty ? ' · $dateStr' : ''}',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: l10n.backupPageRestoreTooltip,
              child: _SmallIconBtn(
                icon: lucide.Lucide.Import,
                onTap: widget.onRestore,
              ),
            ),
            const SizedBox(width: 6),
            Tooltip(
              message: l10n.backupPageDeleteTooltip,
              child: _SmallIconBtn(
                icon: lucide.Lucide.Trash2,
                onTap: widget.onDelete,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RemoteBackupsDialog extends StatefulWidget {
  const _RemoteBackupsDialog({
    required this.title,
    required this.listRemote,
    required this.restoreFromItem,
    required this.deleteAndReload,
  });

  final String title;
  final Future<List<BackupFileItem>> Function() listRemote;
  final Future<void> Function(
    BackupFileItem item,
    RestoreMode mode,
    RestoreProgressCallback onProgress,
  )
  restoreFromItem;
  final Future<List<BackupFileItem>> Function(BackupFileItem item)
  deleteAndReload;

  @override
  State<_RemoteBackupsDialog> createState() => _RemoteBackupsDialogState();
}

class _RemoteBackupsDialogState extends State<_RemoteBackupsDialog> {
  List<BackupFileItem> _items = const [];
  bool _loading = true;
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await widget.listRemote();
      BackupFileItem.sortByNewest(list);
      if (mounted) {
        setState(() {
          _items = list;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _items = const [];
        });
        showAppSnackBar(
          context,
          message: e.toString(),
          type: NotificationType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Runs a restore behind the shared modal overlay (see
  /// [runRestoreWithProgressOverlay]).
  Future<void> _runRestoreWithProgress(
    BuildContext context,
    Future<void> Function(RestoreProgressCallback onProgress) task,
  ) => runRestoreWithProgressOverlay(context, task);

  Future<void> _restoreWithMerge(BackupFileItem item) async {
    final rootCtx = Navigator.of(context, rootNavigator: true).context;
    setState(() => _loading = true);
    try {
      await _runRestoreWithProgress(
        rootCtx,
        (onProgress) =>
            widget.restoreFromItem(item, RestoreMode.merge, onProgress),
      );
    } catch (e) {
      if (!rootCtx.mounted) return;
      if (await maybeShowKelivoCompatError(rootCtx, e)) return;
      if (!rootCtx.mounted) return;
      showAppSnackBar(
        rootCtx,
        message: e.toString(),
        type: NotificationType.error,
      );
      return;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (!rootCtx.mounted) return;
    await refreshProvidersAfterRestore(rootCtx);
    if (!rootCtx.mounted) return;
    await showRestartRequiredDialog(rootCtx);
  }

  Future<void> _chooseRestoreModeAndRun(
    Future<void> Function(RestoreMode mode, RestoreProgressCallback onProgress)
    action,
  ) async {
    // Use a stable context so we can still show a restart prompt even if this
    // dialog is closed while the restore task is running.
    final rootCtx = Navigator.of(context, rootNavigator: true).context;
    final mode = await showDialog<RestoreMode>(
      context: context,
      builder: (_) => _RestoreModeDialog(),
    );
    if (mode == null) return;
    if (!rootCtx.mounted) return;
    setState(() => _loading = true);
    try {
      await _runRestoreWithProgress(
        rootCtx,
        (onProgress) => action(mode, onProgress),
      );
    } catch (e) {
      if (!rootCtx.mounted) return;
      if (await maybeShowKelivoCompatError(rootCtx, e)) return;
      if (!rootCtx.mounted) return;
      showAppSnackBar(
        rootCtx,
        message: e.toString(),
        type: NotificationType.error,
      );
      return;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (!rootCtx.mounted) return;
    await refreshProvidersAfterRestore(rootCtx);
    if (!rootCtx.mounted) return;
    await showRestartRequiredDialog(rootCtx);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Dialog(
      backgroundColor: cs.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 540),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: AppFontWeights.emphasis,
                      ),
                    ),
                  ),
                  _SmallIconBtn(
                    icon: lucide.Lucide.RefreshCw,
                    onTap: _loading ? () {} : _load,
                  ),
                  const SizedBox(width: 6),
                  _SmallIconBtn(
                    icon: lucide.Lucide.X,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _loading
                    ? const Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : _items.isEmpty
                    ? Center(
                        child: Text(
                          l10n.backupPageNoBackups,
                          style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      )
                    : Scrollbar(
                        controller: _controller,
                        child: ListView.separated(
                          controller: _controller,
                          primary: false,
                          itemCount: _items.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (ctx, i) {
                            final it = _items[i];
                            return _RemoteItemCard(
                              item: it,
                              onRestore: () {
                                if (it.displayName.startsWith(
                                  'cuplivo_incr_',
                                )) {
                                  _restoreWithMerge(it);
                                } else {
                                  _chooseRestoreModeAndRun((
                                    mode,
                                    onProgress,
                                  ) async {
                                    await widget.restoreFromItem(
                                      it,
                                      mode,
                                      onProgress,
                                    );
                                  });
                                }
                              },
                              onDelete: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (dctx) => AlertDialog(
                                    backgroundColor: cs.surface,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    title: Text(
                                      l10n.backupPageDeleteConfirmTitle,
                                    ),
                                    content: Text(
                                      l10n.backupPageDeleteConfirmContent(
                                        it.displayName,
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(dctx).pop(false),
                                        child: Text(l10n.backupPageCancel),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(dctx).pop(true),
                                        style: TextButton.styleFrom(
                                          foregroundColor: cs.error,
                                        ),
                                        child: Text(
                                          l10n.backupPageDeleteTooltip,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm != true) return;

                                setState(
                                  () => _loading = true,
                                ); // Show loading inside dialog
                                try {
                                  final next = await widget.deleteAndReload(it);
                                  BackupFileItem.sortByNewest(next);
                                  if (mounted) setState(() => _items = next);
                                } finally {
                                  if (mounted) setState(() => _loading = false);
                                }
                              },
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void _showRemoteBackupsDialog(
  BuildContext context, {
  required String title,
  required Future<List<BackupFileItem>> Function() listRemote,
  required Future<void> Function(
    BackupFileItem item,
    RestoreMode mode,
    RestoreProgressCallback onProgress,
  )
  restoreFromItem,
  required Future<List<BackupFileItem>> Function(BackupFileItem item)
  deleteAndReload,
}) {
  showDialog(
    context: context,
    builder: (_) => _RemoteBackupsDialog(
      title: title,
      listRemote: listRemote,
      restoreFromItem: restoreFromItem,
      deleteAndReload: deleteAndReload,
    ),
  );
}

Widget _rowDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return Container(
    height: 1,
    color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
  );
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.label, required this.trailing, this.vpad = 8});
  final String label;
  final Widget trailing;
  final double vpad;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: vpad),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface.withValues(alpha: 0.88),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Align(alignment: Alignment.centerRight, child: trailing),
        ],
      ),
    );
  }
}

class _RestoreModeDialog extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Dialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 320, maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.backupPageSelectImportMode,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: AppFontWeights.emphasis,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.backupPageSelectImportModeDescription,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(height: 12),
              _RestoreModeTile(
                title: l10n.backupPageOverwriteMode,
                subtitle: l10n.backupPageOverwriteModeDescription,
                onTap: () => Navigator.of(context).pop(RestoreMode.overwrite),
              ),
              const SizedBox(height: 8),
              _RestoreModeTile(
                title: l10n.backupPageMergeMode,
                subtitle: l10n.backupPageMergeModeDescription,
                onTap: () => Navigator.of(context).pop(RestoreMode.merge),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.backupPageCancel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RestoreModeTile extends StatefulWidget {
  const _RestoreModeTile({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  @override
  State<_RestoreModeTile> createState() => _RestoreModeTileState();
}

class _RestoreModeTileState extends State<_RestoreModeTile> {
  bool _hover = false;
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = _hover
        ? cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.04)
        : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.98 : 1.0,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOutCubic,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.12),
                width: 0.6,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: TextStyle(fontWeight: AppFontWeights.emphasis),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.subtitle,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SmallIconBtn extends StatefulWidget {
  const _SmallIconBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  State<_SmallIconBtn> createState() => _SmallIconBtnState();
}

class _SmallIconBtnState extends State<_SmallIconBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = _hover
        ? cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.05)
        : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Icon(widget.icon, size: 18, color: cs.onSurface),
        ),
      ),
    );
  }
}

class _DeskIosButton extends StatefulWidget {
  const _DeskIosButton({
    required this.label,
    required this.filled,
    required this.dense,
    required this.onTap,
  });
  final String label;
  final bool filled;
  final bool dense;
  final VoidCallback onTap;
  @override
  State<_DeskIosButton> createState() => _DeskIosButtonState();
}

class _DeskIosButtonState extends State<_DeskIosButton> {
  bool _hover = false;
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = widget.filled
        ? Colors.white
        : cs.onSurface.withValues(alpha: 0.9);
    final bg = widget.filled
        ? (_hover ? cs.primary.withValues(alpha: 0.92) : cs.primary)
        : (_hover
              ? cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.05)
              : Colors.transparent);
    final borderColor = widget.filled
        ? Colors.transparent
        : cs.outlineVariant.withValues(alpha: isDark ? 0.22 : 0.18);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.98 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: Container(
            padding: EdgeInsets.symmetric(
              vertical: widget.dense ? 8 : 12,
              horizontal: 12,
            ),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                color: textColor,
                fontWeight: AppFontWeights.semibold,
                fontSize: widget.dense ? 13 : 14,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Widget _sectionCard({required List<Widget> children}) {
  return Builder(
    builder: (context) {
      final cs = Theme.of(context).colorScheme;
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final baseBg = context.appColors.surfaceCard;
      return Container(
        decoration: BoxDecoration(
          color: baseBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: isDark ? 0.12 : 0.08),
            width: 0.8,
          ),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
    },
  );
}
