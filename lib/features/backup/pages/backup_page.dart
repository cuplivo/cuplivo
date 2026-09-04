import 'dart:io';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../shared/widgets/loading_dialog_card.dart';
import 'package:provider/provider.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../core/services/haptics.dart';
import '../../../core/models/backup.dart';
import '../../../core/providers/backup_provider.dart';
import '../../../core/providers/backup_reminder_provider.dart';
import '../../../core/providers/s3_backup_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/trash_restore_coordinator.dart';
import '../../../core/services/backup/data_sync.dart';
import '../../../core/services/backup/restore_refresher.dart';
import '../../../core/services/native_file_save.dart';
import '../../../core/services/workspace/workspace_terminal_native_bridge.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/dialogs/incremental_backup_dialog.dart';
import '../../../shared/dialogs/restart_required_dialog.dart';
import '../../../shared/dialogs/rikkahub_migrate_dialog.dart';
import '../../../shared/dialogs/kelivo_import_dialog.dart';
import '../../../shared/dialogs/kelivo_compat_dialog.dart';
import '../../../core/services/backup/cherry_importer.dart';
import '../../../core/services/backup/chatbox_importer.dart';
import '../../../shared/widgets/lan_sync_section.dart';
import '../../../utils/format.dart';
import '../../../utils/platform_utils.dart';
import '../widgets/backup_channel_config_dialog.dart';
import '../widgets/backup_reminder_helpers.dart';
import '../widgets/backup_hero_card.dart';
import '../widgets/backup_action_row.dart';
import '../widgets/backup_migration_dialog.dart';
import '../../../shared/widgets/segmented_toggle.dart';

class BackupPage extends StatefulWidget {
  const BackupPage({super.key, this.trashRestoreCoordinator});

  final TrashRestoreCoordinator? trashRestoreCoordinator;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  /// Hero card state: where the next backup goes.
  BackupDestination _destination = BackupDestination.local;

  String _restoreFailureMessage(BuildContext context, Object error) =>
      error is WorkspaceTerminalStopException
      ? AppLocalizations.of(context)!.workspaceTerminalStopFailed
      : error.toString();

  Future<bool?> _confirmCherryImport(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final locale = Localizations.localeOf(context);
    final isZh = locale.languageCode.startsWith('zh');
    final String body = isZh
        ? '此功能目前仍处于实验阶段。\n目前仅能导入助手，对话内容，供应商和文件，\n一些供应商需要在baseurl后面添加/v1 or /v1beta。 \n为确保数据安全，建议在导入前先执行备份。\n是否已知晓并继续选择文件？'
        : 'This feature is experimental.\nTo keep your data safe, it is recommended to back up before importing.\nProceed to choose a file?';

    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final bottom = MediaQuery.of(ctx).viewInsets.bottom;
        final onSurface60 = cs.onSurface.withValues(alpha: 0.72);
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, bottom + 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    l10n.backupPageImportFromCherryStudio,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: AppFontWeights.semibold,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Padding(
                    //   padding: const EdgeInsets.only(top: 2),
                    //   child: Icon(Lucide.BadgeInfo, size: 18, color: cs.primary),
                    // ),
                    // const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        body,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.35,
                          color: onSurface60,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _IosOutlineButton(
                        label: l10n.backupPageCancel,
                        onTap: () => Navigator.of(ctx).pop(false),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _IosFilledButton(
                        label: l10n.backupPageOK,
                        onTap: () => Navigator.of(ctx).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<RestoreMode?> _chooseImportModeDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cardColor = context.appColors.surfaceFill;

    return showDialog<RestoreMode>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.backupPageSelectImportMode),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ActionCard(
              color: cardColor,
              icon: Lucide.RotateCw,
              title: l10n.backupPageOverwriteMode,
              subtitle: l10n.backupPageOverwriteModeDescription,
              onTap: () => Navigator.of(ctx).pop(RestoreMode.overwrite),
            ),
            const SizedBox(height: 10),
            _ActionCard(
              color: cardColor,
              icon: Lucide.GitFork,
              title: l10n.backupPageMergeMode,
              subtitle: l10n.backupPageMergeModeDescription,
              onTap: () => Navigator.of(ctx).pop(RestoreMode.merge),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.backupPageCancel),
          ),
        ],
      ),
    );
  }

  Future<T> _runWithExportingOverlay<T>(
    BuildContext context,
    Future<T> Function() task, {
    String Function(int seconds)? elapsedTextBuilder,
    ValueListenable<String>? labelListenable,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    return _runWithLoadingOverlay(
      context,
      task,
      label: l10n.backupPageExporting,
      elapsedTextBuilder: elapsedTextBuilder,
      labelListenable: labelListenable,
    );
  }

  Future<T> _runWithLoadingOverlay<T>(
    BuildContext context,
    Future<T> Function() task, {
    String? label,
    String Function(int seconds)? elapsedTextBuilder,
    ValueListenable<String>? labelListenable,
  }) {
    return runWithLoadingDialog(
      context,
      task,
      label: label,
      elapsedTextBuilder: elapsedTextBuilder,
      labelListenable: labelListenable,
    );
  }

  /// Runs a backup task under the modal overlay with a live stage label
  /// (生成文件 → 整合压缩 → 上传). The notifier is created/disposed here so
  /// callers never leak listeners.
  Future<T> _runWithStageOverlay<T>(
    BuildContext context,
    Future<T> Function(BackupStageCallback onStage) task,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final stageLabel = ValueNotifier<String>(l10n.backupStageGenerating);
    try {
      return await _runWithExportingOverlay(
        context,
        () => task((stage) => stageLabel.value = backupStageLabel(l10n, stage)),
        elapsedTextBuilder: l10n.backupPageExportElapsed,
        labelListenable: stageLabel,
      );
    } finally {
      stageLabel.dispose();
    }
  }

  /// Runs a restore-family task behind the shared modal overlay with live
  /// [RestoreProgress] (stage → determinate bar → counts) and an elapsed
  /// ticker. [label], when set (third-party importers without a progress
  /// pipeline), swaps the progress body for a fixed importing label. Single
  /// source shared with the desktop backup pane.
  Future<T> _runWithImportingOverlay<T>(
    BuildContext context,
    Future<T> Function(RestoreProgressCallback onProgress) task, {
    String? label,
  }) => runRestoreWithProgressOverlay(context, task, label: label);

  Future<void> _afterSuccessfulRestore(BuildContext context) async {
    if (!context.mounted) return;
    await _refreshProvidersAfterRestore(context);
    if (!context.mounted) return;
    await showRestartRequiredDialog(context);
  }

  Future<void> _restoreIncrementalItem({
    required BuildContext context,
    required Future<void> Function(RestoreProgressCallback onProgress)
    performRestore,
  }) async {
    try {
      await _runWithImportingOverlay(context, performRestore);
    } catch (e) {
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        message: _restoreFailureMessage(context, e),
        type: NotificationType.error,
      );
      return;
    }
    if (!context.mounted) return;
    await _afterSuccessfulRestore(context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final reminder = context.watch<BackupReminderProvider>();
    final coordinator =
        widget.trashRestoreCoordinator ??
        context.read<TrashRestoreCoordinator>();

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => BackupProvider(
            chatService: context.read<ChatService>(),
            trashRestoreCoordinator: coordinator,
            preferences: context.read<BusinessPreferences>(),
            initialConfig: settings.webDavConfig,
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => S3BackupProvider(
            chatService: context.read<ChatService>(),
            trashRestoreCoordinator: coordinator,
            preferences: context.read<BusinessPreferences>(),
            initialConfig: settings.s3Config,
          ),
        ),
      ],
      child: Builder(
        builder: (context) {
          final vm = context.watch<BackupProvider>();
          final s3Vm = context.watch<S3BackupProvider>();
          final cfg = vm.config;
          final s3Cfg = s3Vm.config;
          final webdavEnabled = cfg.isConfigured;
          final s3Enabled = s3Cfg.isConfigured;
          final busy = vm.busy || s3Vm.busy;

          // iOS-style section header
          Widget header(String text, {bool first = false}) => Padding(
            padding: EdgeInsets.fromLTRB(12, first ? 2 : 18, 12, 6),
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: AppFontWeights.semibold,
                color: cs.onSurface.withValues(alpha: 0.8),
              ),
            ),
          );

          final scope = cfg.content;
          final scopeOptions =
              <(String, BackupContentScope Function(BackupContentScope))>[
                (
                  l10n.backupScopeChatsAssistants,
                  (s) => s.copyWith(chatsAndAssistants: !s.chatsAndAssistants),
                ),
                (
                  l10n.backupScopeSettings,
                  (s) => s.copyWith(settings: !s.settings),
                ),
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

          return Scaffold(
            appBar: AppBar(
              leading: Tooltip(
                message: l10n.settingsPageBackButton,
                child: _TactileIconButton(
                  icon: Lucide.ArrowLeft,
                  color: cs.onSurface,
                  size: 22,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ),
              title: Text(l10n.backupPageTitle),
              actions: const [SizedBox(width: 12)],
            ),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                // ① Status + full lifecycle (destination picker + one CTA row:
                // full / incremental / restore — all on the destination).
                BackupHeroCard(
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

                // ② 局域网同步 first; the migration entry (搬去/搬来) right
                // after — no "export" section header (LAN sync is its own
                // card).
                header(l10n.lanSyncSectionTitle),
                const LanSyncSection(),

                // ③ 数据迁移 — rare "move house" ops behind one row + flat
                // chooser dialog.
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: _iosSectionCard(
                    children: [
                      BackupActionRow(
                        icon: Lucide.Import,
                        label: l10n.backupMigrateTitle,
                        subtitle: l10n.backupMigrateRowSubtitle,
                        onTap: () => showBackupMigrationChooser(
                          context,
                          onExportKelivo: () => _doExport(
                            context,
                            vm,
                            format: BackupFormat.kelivoLegacy,
                          ),
                          onImportKelivo: () =>
                              showKelivoImportDialog(context: context),
                          onImportRikkaHub: () =>
                              showRikkaHubMigrateDialog(context: context),
                          onImportCherryStudio: () => _doCherryImport(context),
                          onImportChatbox: () => _doChatboxImport(context),
                        ),
                      ),
                    ],
                  ),
                ),

                // ⑤ 备份内容 — 6-section scope (assistant "能力" look, 2×3)
                header(l10n.backupPageContentLabel),
                _iosSectionCard(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
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
                        itemsPerRow: 2,
                        onChanged: (i) => _applyScopeBit(
                          context,
                          vm,
                          s3Vm,
                          scopeOptions[i].$2(scope),
                        ),
                      ),
                    ),
                  ],
                ),

                // ⑥ 备份提醒 — switch + rows; due adds an extra row, never
                // replaces anything.
                header(l10n.backupReminderSectionTitle),
                _iosSectionCard(
                  children: [
                    if (reminder.shouldShowReminder) ...[
                      BackupActionRow(
                        icon: Lucide.TriangleAlert,
                        label: l10n.backupHeroDueTitle,
                        value: backupReminderDateTimeLabel(
                          context,
                          reminder.lastBackupAt,
                        ),
                        dotColor: context.appColors.warning,
                        onTap: () => _heroBackupNow(context),
                      ),
                      _iosDivider(context),
                    ],
                    _iosSwitchRow(
                      context,
                      icon: Lucide.Timer,
                      label: l10n.backupReminderEnableTitle,
                      value: reminder.enabled,
                      onChanged: (value) async {
                        final provider = context.read<BackupReminderProvider>();
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
                    _iosDivider(context),
                    _iosSwitchRow(
                      context,
                      icon: Lucide.Pin,
                      label: l10n.backupEntryAlwaysVisibleTitle,
                      value: reminder.entryAlwaysVisible,
                      onChanged: (value) async {
                        await context
                            .read<BackupReminderProvider>()
                            .setEntryAlwaysVisible(value);
                      },
                    ),
                    if (reminder.enabled) ...[
                      _iosDivider(context),
                      BackupActionRow(
                        icon: Lucide.Repeat,
                        label: l10n.backupReminderFrequencyTitle,
                        value: backupReminderFrequencyLabel(
                          l10n,
                          reminder.intervalDays,
                        ),
                        onTap: () => _showBackupReminderFrequencySheet(context),
                      ),
                      _iosDivider(context),
                      BackupActionRow(
                        icon: Lucide.clock,
                        label: l10n.backupReminderTimeTitle,
                        value: backupReminderTimeLabel(
                          context,
                          reminder.reminderMinutesOfDay,
                        ),
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
                    ],
                  ],
                ),

                // ⑦ 备份渠道 — WebDAV/S3 own card
                header(l10n.backupPageChannelManagement),
                _iosSectionCard(
                  children: [
                    BackupActionRow(
                      icon: Lucide.databaseBackup,
                      label: l10n.backupPageWebDavBackup,
                      value: webdavEnabled
                          ? l10n.backupPageChannelEnabled
                          : l10n.backupPageChannelNotConfigured,
                      dotColor: webdavEnabled
                          ? context.appColors.success
                          : cs.onSurface.withValues(alpha: 0.25),
                      enabled: !busy,
                      onTap: () => _openWebDavConfig(context),
                    ),
                    _iosDivider(context),
                    BackupActionRow(
                      icon: Lucide.Globe,
                      label: l10n.backupPageS3Backup,
                      value: s3Enabled
                          ? l10n.backupPageChannelEnabled
                          : l10n.backupPageChannelNotConfigured,
                      dotColor: s3Enabled
                          ? context.appColors.success
                          : cs.onSurface.withValues(alpha: 0.25),
                      enabled: !busy,
                      onTap: () => _openS3Config(context),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Hero restore: read back from the SELECTED destination — the mirror
  /// image of the two backup actions. Unconfigured remotes fall through to
  /// their config dialog (the enable path).
  Future<void> _heroRestore(BuildContext context) async {
    final vm = context.read<BackupProvider>();
    final s3Vm = context.read<S3BackupProvider>();
    switch (_destination) {
      case BackupDestination.local:
        await _doImportLocal(context, vm);
      case BackupDestination.webdav:
        if (!vm.config.isConfigured) {
          await _openWebDavConfig(context);
        } else {
          await _openRemoteList(context, channel: BackupChannel.webdav);
        }
      case BackupDestination.s3:
        if (!s3Vm.config.isConfigured) {
          await _openS3Config(context);
        } else {
          await _openRemoteList(context, channel: BackupChannel.s3);
        }
    }
  }

  /// Hero CTA: dispatch by the selected destination.
  Future<void> _heroBackupNow(BuildContext context) async {
    switch (_destination) {
      case BackupDestination.local:
        await _doExport(context, context.read<BackupProvider>());
      case BackupDestination.webdav:
        await _runWebDavBackup(context);
      case BackupDestination.s3:
        await _runS3Backup(context);
    }
  }

  /// Hero incremental link: dispatch by the selected destination, applying
  /// the chosen scope back to both channel configs (persisted).
  Future<void> _heroIncremental(BuildContext context) async {
    final vm = context.read<BackupProvider>();
    final s3Vm = context.read<S3BackupProvider>();
    final scope = vm.config.content;
    switch (_destination) {
      case BackupDestination.local:
        await _runLocalIncremental(context, vm, vm.config, initialScope: scope);
      case BackupDestination.webdav:
        await _runWebDavIncremental(
          context,
          vm,
          vm.config,
          initialScope: scope,
        );
      case BackupDestination.s3:
        await _runS3Incremental(
          context,
          s3Vm,
          s3Vm.config,
          initialScope: scope,
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
    await BackupChannelConfigDialog.showSheet(
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
    final v3m = context.read<S3BackupProvider>();
    await BackupChannelConfigDialog.showSheet(
      context,
      channel: BackupChannel.s3,
      s3Cfg: v3m.config,
      onTestS3: (draft) async {
        final ok = await v3m.test(config: draft);
        return ChannelTestResult(
          ok: ok,
          message: v3m.message ?? l10n.backupPageTestDone,
        );
      },
      onSaveS3: (c) async {
        await context.read<SettingsProvider>().setS3Config(c);
        v3m.updateConfig(c);
        if (c.isConfigured && mounted) {
          setState(() => _destination = BackupDestination.s3);
        }
      },
    );
  }

  Future<void> _doExport(
    BuildContext context,
    BackupProvider vm, {
    BackupFormat format = BackupFormat.jsonl,
  }) {
    return _saveLocalExport(
      context,
      (onStage) => vm.exportToFile(onStage: onStage, format: format),
    );
  }

  /// Pack a local backup (full or incremental) into a staging ZIP, deliver it
  /// through the system save dialog, and clean the staging file up. The pack
  /// task is supplied by the caller; everything after pack (deliver + cleanup)
  /// is shared between the full-export and incremental-export entry points.
  /// [recordBackupReminder] records the last-backup time on success — local
  /// incremental passes the dialog's "update backup time" checkbox here.
  Future<void> _saveLocalExport(
    BuildContext context,
    Future<File> Function(BackupStageCallback onStage) pack, {
    bool recordBackupReminder = true,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final stopwatch = Stopwatch()..start();
    final File file;
    try {
      debugPrint('BackupExport: pack begin');
      file = await _runWithStageOverlay(context, pack);
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
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        message: l10n.backupPageExportFailed(e.toString()),
        type: NotificationType.error,
      );
      return;
    }

    try {
      if (!context.mounted) return;
      final isMobile = Platform.isAndroid || Platform.isIOS;
      if (isMobile) {
        try {
          debugPrint('BackupExport: opening system save dialog');
          final saved = await NativeFileSave.saveFileFromPath(
            sourcePath: file.path,
            fileName: file.uri.pathSegments.last,
          );
          debugPrint('BackupExport: system save result=$saved');
          if (saved && context.mounted && recordBackupReminder) {
            await _recordBackupReminderQuietly(context);
          }
        } catch (e) {
          debugPrint('BackupExport: system save failed: $e');
          if (!context.mounted) return;
          showAppSnackBar(
            context,
            message: l10n.backupPageExportFailed(e.toString()),
            type: NotificationType.error,
          );
        }
      } else {
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
          if (!context.mounted) return;
          showAppSnackBar(
            context,
            message: l10n.backupPageExportFailed(e.toString()),
            type: NotificationType.error,
          );
          return;
        }
        if (savePath != null) {
          try {
            await File(savePath).parent.create(recursive: true);
            await file.copy(savePath);
            debugPrint('BackupExport: copied to $savePath');
            if (context.mounted && recordBackupReminder) {
              await _recordBackupReminderQuietly(context);
            }
          } catch (e) {
            debugPrint('BackupExport: copy failed: $e');
            if (!context.mounted) return;
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

  /// Best-effort: recording the backup reminder is a non-critical side effect
  /// after the file was already saved — its failure must not surface as an
  /// export error.
  Future<void> _recordBackupReminderQuietly(BuildContext context) async {
    try {
      await context.read<BackupReminderProvider>().recordBackupCompleted();
    } catch (e) {
      debugPrint('BackupExport: recordBackupCompleted failed: $e');
    }
  }

  /// After wipe/restore, providers must re-read SQLite; otherwise UI keeps a
  /// cleared or pre-restore in-memory snapshot (P0 empty chats/assistants).
  /// Delegates to the shared refresh list so every restore entry point
  /// (mobile page, desktop pane, LAN sync) stays in sync.
  Future<void> _refreshProvidersAfterRestore(BuildContext context) async {
    await refreshProvidersAfterRestore(context);
  }

  Future<void> _doImportLocal(BuildContext context, BackupProvider vm) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    if (!context.mounted) return;

    final mode = await _chooseImportModeDialog(context);
    if (mode == null) return;
    if (!context.mounted) return;

    try {
      await _runWithImportingOverlay(
        context,
        (onProgress) => vm.restoreFromLocalFile(
          File(path),
          mode: mode,
          onProgress: onProgress,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      if (await maybeShowKelivoCompatError(context, e)) return;
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        message: _restoreFailureMessage(context, e),
        type: NotificationType.error,
      );
      return;
    }
    if (!context.mounted) return;
    await _afterSuccessfulRestore(context);
  }

  Future<void> _runWebDavBackup(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final vm = context.read<BackupProvider>();
    final reminderProvider = context.read<BackupReminderProvider>();
    final success = await _runWithStageOverlay(
      context,
      (onStage) => vm.backup(onStage: onStage),
    );
    if (!context.mounted) return;
    final rawMessage = vm.message;
    if (success) {
      await reminderProvider.recordBackupCompleted();
      if (!context.mounted) return;
    }
    final message = rawMessage ?? l10n.backupPageBackupUploaded;
    showAppSnackBar(context, message: message, type: NotificationType.info);
  }

  Future<void> _runS3Backup(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final vm = context.read<S3BackupProvider>();
    final reminderProvider = context.read<BackupReminderProvider>();
    final success = await _runWithStageOverlay(
      context,
      (onStage) => vm.backup(onStage: onStage),
    );
    if (!context.mounted) return;
    final rawMessage = vm.message;
    if (success) {
      await reminderProvider.recordBackupCompleted();
      if (!context.mounted) return;
    }
    final message = rawMessage ?? l10n.backupPageBackupUploaded;
    showAppSnackBar(context, message: message, type: NotificationType.info);
  }

  Future<void> _runWebDavIncremental(
    BuildContext context,
    BackupProvider vm,
    WebDavConfig cfg, {
    BackupContentScope? initialScope,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final config = await IncrementalBackupDialog.showSheet(
      context,
      lastBackupTime: context.read<BackupReminderProvider>().lastBackupAt,
      initialScope: initialScope ?? cfg.content,
      analyzer: vm.analyzeIncrementalScope,
    );
    if (config == null || !context.mounted) return;
    if (config.contentScope != null) {
      await _applyScopeBit(
        context,
        vm,
        context.read<S3BackupProvider>(),
        config.contentScope!,
      );
      if (!context.mounted) return;
    }
    final success = await _runWithStageOverlay(
      context,
      (onStage) => vm.incrementalBackup(config, onStage: onStage),
    );
    if (!context.mounted) return;
    if (success && config.updateBackupTime) {
      await context.read<BackupReminderProvider>().recordBackupCompleted();
    }
    if (!context.mounted) return;
    final rawMessage = vm.message;
    final message = rawMessage ?? l10n.backupPageBackupUploaded;
    showAppSnackBar(context, message: message, type: NotificationType.info);
  }

  Future<void> _runS3Incremental(
    BuildContext context,
    S3BackupProvider vm,
    S3Config cfg, {
    BackupContentScope? initialScope,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final config = await IncrementalBackupDialog.showSheet(
      context,
      lastBackupTime: context.read<BackupReminderProvider>().lastBackupAt,
      initialScope: initialScope ?? cfg.content,
      analyzer: vm.analyzeIncrementalScope,
    );
    if (config == null || !context.mounted) return;
    if (config.contentScope != null) {
      await _applyScopeBit(
        context,
        context.read<BackupProvider>(),
        vm,
        config.contentScope!,
      );
      if (!context.mounted) return;
    }
    final success = await _runWithStageOverlay(
      context,
      (onStage) => vm.incrementalBackup(config, onStage: onStage),
    );
    if (!context.mounted) return;
    if (success && config.updateBackupTime) {
      await context.read<BackupReminderProvider>().recordBackupCompleted();
    }
    if (!context.mounted) return;
    final rawMessage = vm.message;
    final message = rawMessage ?? l10n.backupPageBackupUploaded;
    showAppSnackBar(context, message: message, type: NotificationType.info);
  }

  Future<void> _runLocalIncremental(
    BuildContext context,
    BackupProvider vm,
    WebDavConfig cfg, {
    BackupContentScope? initialScope,
  }) async {
    final config = await IncrementalBackupDialog.showSheet(
      context,
      lastBackupTime: context.read<BackupReminderProvider>().lastBackupAt,
      initialScope: initialScope ?? cfg.content,
      analyzer: vm.analyzeIncrementalScope,
    );
    if (config == null || !context.mounted) return;
    if (config.contentScope != null) {
      await _applyScopeBit(
        context,
        vm,
        context.read<S3BackupProvider>(),
        config.contentScope!,
      );
      if (!context.mounted) return;
    }
    await _saveLocalExport(
      context,
      (onStage) => vm.incrementalExportToFile(config, onStage: onStage),
      recordBackupReminder: config.updateBackupTime,
    );
  }

  /// Shared remote-list flow for WebDAV / S3 (issue #306): load with the
  /// importing overlay, then show the sheet with delete/restore. Deleting a
  /// file re-opens the sheet with the refreshed list, mirroring the former
  /// per-channel behavior.
  Future<void> _openRemoteList(
    BuildContext context, {
    required BackupChannel channel,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isS3 = channel == BackupChannel.s3;
    final vm = context.read<BackupProvider>();
    final s3Vm = context.read<S3BackupProvider>();
    final listRemote = isS3 ? s3Vm.listRemote : vm.listRemote;
    final restoreFromItem = isS3
        ? (
            BackupFileItem item,
            RestoreMode mode,
            RestoreProgressCallback onProgress,
          ) => s3Vm.restoreFromItem(item, mode: mode, onProgress: onProgress)
        : (
            BackupFileItem item,
            RestoreMode mode,
            RestoreProgressCallback onProgress,
          ) => vm.restoreFromItem(item, mode: mode, onProgress: onProgress);
    final deleteAndReload = isS3 ? s3Vm.deleteAndReload : vm.deleteAndReload;

    Future<void> showSheetWith(List<BackupFileItem> items) async {
      if (!context.mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: cs.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => _RemoteListSheet(
          items: items,
          loading: false,
          onDelete: (item) async {
            final confirm = await showDialog<bool>(
              context: context,
              builder: (dctx) => AlertDialog(
                title: Text(l10n.backupPageDeleteConfirmTitle),
                content: Text(
                  l10n.backupPageDeleteConfirmContent(item.displayName),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dctx).pop(false),
                    child: Text(l10n.backupPageCancel),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(dctx).pop(true),
                    style: TextButton.styleFrom(foregroundColor: cs.error),
                    child: Text(l10n.backupPageDeleteTooltip),
                  ),
                ],
              ),
            );
            if (confirm != true) return;

            // 1. Close current sheet
            if (context.mounted) {
              Navigator.of(context).pop();
            }

            // 2. Show loading dialog
            if (context.mounted) {
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (ctx) => const LoadingDialogCard(),
              );
            }

            try {
              final list = await deleteAndReload(item);
              if (context.mounted) {
                Navigator.of(context, rootNavigator: true).pop();
              }
              BackupFileItem.sortByNewest(list);
              await showSheetWith(list);
            } catch (e) {
              if (context.mounted && Navigator.canPop(context)) {
                Navigator.of(context, rootNavigator: true).pop();
              }
              if (context.mounted) {
                showAppSnackBar(
                  context,
                  message: _restoreFailureMessage(context, e),
                  type: NotificationType.error,
                );
              }
            }
          },
          onRestore: (item) async {
            Navigator.of(ctx).pop();
            if (!context.mounted) return;

            if (item.displayName.startsWith('cuplivo_incr_')) {
              return _restoreIncrementalItem(
                context: context,
                performRestore: (onProgress) =>
                    restoreFromItem(item, RestoreMode.merge, onProgress),
              );
            }

            final mode = await _chooseImportModeDialog(context);
            if (mode == null) return;
            if (!context.mounted) return;
            try {
              await _runWithImportingOverlay(
                context,
                (onProgress) => restoreFromItem(item, mode, onProgress),
              );
            } catch (e) {
              if (!context.mounted) return;
              if (await maybeShowKelivoCompatError(context, e)) return;
              if (!context.mounted) return;
              showAppSnackBar(
                context,
                message: _restoreFailureMessage(context, e),
                type: NotificationType.error,
              );
              return;
            }
            if (!context.mounted) return;
            await _afterSuccessfulRestore(context);
          },
        ),
      );
    }

    final list = await _runWithImportingOverlay(context, (_) => listRemote());
    BackupFileItem.sortByNewest(list);
    await showSheetWith(list);
  }

  Future<void> _doCherryImport(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    // 1) Warn user that Cherry import is experimental
    final acknowledged = await _confirmCherryImport(context);
    if (acknowledged != true) return;

    if (!context.mounted) return;
    // Pick Cherry Studio backup (.zip or .bak)
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip', 'bak'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    if (!context.mounted) return;

    final mode = await _chooseImportModeDialog(context);
    if (mode == null) return;
    if (!context.mounted) return;

    await _runWithImportingOverlay(context, (_) async {
      try {
        final settings = context.read<SettingsProvider>();
        final cs = context.read<ChatService>();
        final file = File(path);
        // Defer import to service
        final res = await CherryImporter.importFromCherryStudio(
          file: file,
          mode: mode,
          settings: settings,
          chatService: cs,
          preferences: context.read<BusinessPreferences>(),
        );
        if (!context.mounted) return;
        await showDialog(
          context: context,
          builder: (dctx) => AlertDialog(
            title: Text(l10n.backupPageRestartRequired),
            content: Text(
              '${l10n.backupPageImportFromCherryStudio}:\n'
              '${l10n.backupPageImportStats(res.assistants, res.conversations, res.files, res.messages, res.providers)}\n\n'
              '${l10n.backupPageRestartContent}',
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  Navigator.of(dctx).pop();
                  PlatformUtils.restartApp();
                },
                child: Text(l10n.backupPageOK),
              ),
            ],
          ),
        );
      } catch (e) {
        if (!context.mounted) return;
        showAppSnackBar(
          context,
          message: _restoreFailureMessage(context, e),
          type: NotificationType.error,
        );
      }
    }, label: l10n.backupPageImportInProgress);
  }

  Future<void> _doChatboxImport(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    // Pick Chatbox exported json
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    if (!context.mounted) return;

    final mode = await _chooseImportModeDialog(context);
    if (mode == null) return;
    if (!context.mounted) return;

    await _runWithImportingOverlay(context, (_) async {
      try {
        final cs = context.read<ChatService>();
        final settings = context.read<SettingsProvider>();
        final file = File(path);
        final res = await ChatboxImporter.importFromChatbox(
          file: file,
          mode: mode,
          settings: settings,
          chatService: cs,
          preferences: context.read<BusinessPreferences>(),
        );
        if (!context.mounted) return;
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (dctx) => PopScope(
            // Import contract matches restore: restart is required
            // for the imported data to take effect.
            canPop: false,
            child: AlertDialog(
              title: Text(l10n.backupPageRestartRequired),
              content: Text(
                '${l10n.backupPageImportFromChatbox}:\n'
                '${l10n.backupPageImportStatsNoFiles(res.assistants, res.conversations, res.messages, res.providers)}\n\n'
                '${l10n.backupPageRestartContent}',
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    Navigator.of(dctx).pop();
                    PlatformUtils.restartApp();
                  },
                  child: Text(l10n.backupPageOK),
                ),
              ],
            ),
          ),
        );
      } catch (e) {
        if (!context.mounted) return;
        showAppSnackBar(
          context,
          message: _restoreFailureMessage(context, e),
          type: NotificationType.error,
        );
      }
    }, label: l10n.backupPageImportInProgress);
  }
}

Future<void> _showBackupReminderFrequencySheet(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final provider = context.read<BackupReminderProvider>();
  final selected = await showModalBottomSheet<int>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      final options = <int>[
        ...BackupReminderProvider.presetIntervals,
        if (!BackupReminderProvider.presetIntervals.contains(
          provider.intervalDays,
        ))
          provider.intervalDays,
        0,
      ];
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final days in options)
                _ReminderFrequencyTile(
                  label: days == 0
                      ? l10n.backupReminderCustomOption
                      : backupReminderFrequencyLabel(l10n, days),
                  selected: days != 0 && days == provider.intervalDays,
                  onTap: () => Navigator.of(ctx).pop(days),
                ),
            ],
          ),
        ),
      );
    },
  );
  if (!context.mounted || selected == null) return;

  final days = selected == 0
      ? await showBackupReminderCustomDaysDialog(
          context,
          initialDays: provider.intervalDays,
        )
      : selected;
  if (!context.mounted || days == null) return;
  final providerAfterDialog = context.read<BackupReminderProvider>();
  var minutes = providerAfterDialog.reminderMinutesOfDay;
  minutes ??= await showBackupReminderTimePicker(context);
  if (!context.mounted || minutes == null) return;
  await context.read<BackupReminderProvider>().saveSchedule(
    enabled: true,
    intervalDays: days,
    reminderMinutesOfDay: minutes,
  );
}

class _ReminderFrequencyTile extends StatefulWidget {
  const _ReminderFrequencyTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ReminderFrequencyTile> createState() => _ReminderFrequencyTileState();
}

class _ReminderFrequencyTileState extends State<_ReminderFrequencyTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        Haptics.soft();
        widget.onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: widget.selected
              ? cs.primary.withValues(alpha: 0.12)
              : _pressed
              ? cs.onSurface.withValues(alpha: 0.05)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.label,
                style: TextStyle(fontSize: 15, color: cs.onSurface),
              ),
            ),
            if (widget.selected)
              Icon(Lucide.Check, size: 18, color: cs.primary),
          ],
        ),
      ),
    );
  }
}

// --- iOS-style widgets ---

class _TactileIconButton extends StatefulWidget {
  const _TactileIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 22,
  });
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;
  @override
  State<_TactileIconButton> createState() => _TactileIconButtonState();
}

class _TactileIconButtonState extends State<_TactileIconButton> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final base = widget.color;
    final press = base.withValues(alpha: 0.7);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        Haptics.light();
        widget.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          widget.icon,
          size: widget.size,
          color: _pressed ? press : base,
        ),
      ),
    );
  }
}

class _TactileRow extends StatefulWidget {
  const _TactileRow({
    required this.builder,
    this.onTap,
    this.pressedScale = 1.0,
  });
  final Widget Function(bool pressed) builder;
  final VoidCallback? onTap;
  final double pressedScale;
  @override
  State<_TactileRow> createState() => _TactileRowState();
}

class _TactileRowState extends State<_TactileRow> {
  bool _pressed = false;
  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => _set(true),
      onTapUp: widget.onTap == null ? null : (_) => _set(false),
      onTapCancel: widget.onTap == null ? null : () => _set(false),
      onTap: widget.onTap == null
          ? null
          : () {
              if (context.read<SettingsProvider>().hapticsOnListItemTap) {
                Haptics.soft();
              }
              widget.onTap!.call();
            },
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: widget.builder(_pressed),
      ),
    );
  }
}

class _SmallTactileIcon extends StatefulWidget {
  const _SmallTactileIcon({
    required this.icon,
    required this.onTap,
    this.baseColor,
  });
  final IconData icon;
  final VoidCallback onTap;
  final Color? baseColor;
  @override
  State<_SmallTactileIcon> createState() => _SmallTactileIconState();
}

class _SmallTactileIconState extends State<_SmallTactileIcon> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final base = widget.baseColor ?? Theme.of(context).colorScheme.onSurface;
    final c = _pressed ? base.withValues(alpha: 0.7) : base;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        Haptics.soft();
        widget.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(widget.icon, size: 18, color: c),
      ),
    );
  }
}

Widget _iosSectionCard({required List<Widget> children}) {
  return Builder(
    builder: (context) {
      final theme = Theme.of(context);
      final cs = theme.colorScheme;
      final isDark = theme.brightness == Brightness.dark;
      final Color bg = context.appColors.surfaceCard;
      return Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
            width: 0.6,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: children),
        ),
      );
    },
  );
}

Widget _iosDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Divider(
    height: 6,
    thickness: 0.6,
    indent: 54,
    endIndent: 12,
    color: cs.outlineVariant.withValues(alpha: 0.18),
  );
}

class _AnimatedPressColor extends StatelessWidget {
  const _AnimatedPressColor({
    required this.pressed,
    required this.base,
    required this.builder,
  });
  final bool pressed;
  final Color base;
  final Widget Function(Color color) builder;
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final target = pressed
        ? (Color.lerp(base, isDark ? Colors.black : Colors.white, 0.55) ?? base)
        : base;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: target),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, color, _) => builder(color ?? base),
    );
  }
}

// --- Local iOS-style buttons for sheets ---
class _IosOutlineButton extends StatefulWidget {
  const _IosOutlineButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  State<_IosOutlineButton> createState() => _IosOutlineButtonState();
}

class _IosOutlineButtonState extends State<_IosOutlineButton> {
  bool _pressed = false;
  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) =>
          Future.delayed(const Duration(milliseconds: 80), () => _set(false)),
      onTapCancel: () => _set(false),
      onTap: () {
        Haptics.soft();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.primary.withValues(alpha: 0.5)),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: cs.primary,
              fontWeight: AppFontWeights.semibold,
            ),
          ),
        ),
      ),
    );
  }
}

class _IosFilledButton extends StatefulWidget {
  const _IosFilledButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  State<_IosFilledButton> createState() => _IosFilledButtonState();
}

class _IosFilledButtonState extends State<_IosFilledButton> {
  bool _pressed = false;
  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) =>
          Future.delayed(const Duration(milliseconds: 80), () => _set(false)),
      onTapCancel: () => _set(false),
      onTap: () {
        Haptics.soft();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: cs.primary,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: cs.onPrimary,
              fontWeight: AppFontWeights.semibold,
            ),
          ),
        ),
      ),
    );
  }
}

Widget _iosSwitchRow(
  BuildContext context, {
  IconData? icon,
  required String label,
  required bool value,
  required ValueChanged<bool> onChanged,
}) {
  final cs = Theme.of(context).colorScheme;
  return _TactileRow(
    onTap: () => onChanged(!value),
    pressedScale: 1.00,
    builder: (pressed) {
      final baseColor = cs.onSurface.withValues(alpha: 0.9);
      return _AnimatedPressColor(
        pressed: pressed,
        base: baseColor,
        builder: (c) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Row(
              children: [
                if (icon != null) ...[
                  SizedBox(width: 36, child: Icon(icon, size: 20, color: c)),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(label, style: TextStyle(fontSize: 15, color: c)),
                ),
                IosSwitch(value: value, onChanged: onChanged),
              ],
            ),
          );
        },
      );
    },
  );
}

class _RemoteListSheet extends StatelessWidget {
  const _RemoteListSheet({
    required this.items,
    required this.loading,
    required this.onDelete,
    required this.onRestore,
  });
  final List<BackupFileItem> items;
  final bool loading;
  final Future<void> Function(BackupFileItem) onDelete;
  final Future<void> Function(BackupFileItem) onRestore;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        builder: (ctx, controller) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
          child: Column(
            children: [
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 10),
              Stack(
                alignment: Alignment.center,
                children: [
                  Center(
                    child: Text(
                      l10n.backupPageRemoteBackups,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: AppFontWeights.semibold,
                      ),
                    ),
                  ),
                  if (loading)
                    const Positioned(
                      right: 0,
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: (items.isEmpty)
                    ? Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          l10n.backupPageNoBackups,
                          style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: controller,
                        itemCount: items.length,
                        itemBuilder: (ctx, i) {
                          final it = items[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Container(
                              decoration: BoxDecoration(
                                color: context.appColors.surfaceFill,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: cs.outlineVariant.withValues(
                                    alpha: 0.18,
                                  ),
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          it.displayName,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontWeight: AppFontWeights.semibold,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          formatBytes(it.size),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: cs.onSurface.withValues(
                                              alpha: 0.7,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  _SmallTactileIcon(
                                    icon: Lucide.Import,
                                    onTap: () => onRestore(it),
                                  ),
                                  const SizedBox(width: 6),
                                  _SmallTactileIcon(
                                    icon: Lucide.Trash2,
                                    onTap: () => onDelete(it),
                                    baseColor: cs.error,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final Color color;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _TactileRow(
      pressedScale: 0.98,
      onTap: onTap,
      builder: (pressed) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final overlay = pressed
            ? cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.05)
            : Colors.transparent;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: Color.alphaBlend(overlay, color),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.18),
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: cs.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(fontWeight: AppFontWeights.semibold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Lucide.ChevronRight, size: 18),
            ],
          ),
        );
      },
    );
  }
}
