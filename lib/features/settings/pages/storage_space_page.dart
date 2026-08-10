import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../core/models/file_reference.dart';
import '../../../core/providers/filesystem_mounts_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/haptics.dart';
import '../../../core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import '../../../core/services/storage/message_locate_bus.dart';
import '../../../core/services/storage/storage_usage_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_checkbox.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/format.dart';
import '../../../utils/platform_utils.dart';
import '../../../utils/app_directories.dart';
import '../../../utils/path_canon.dart';
import '../../chat/pages/image_viewer_page.dart';
import '../../home/services/input_draft_persistence.dart';
import 'log_viewer_page.dart';
import 'mount_files_page.dart';
import 'trash_detail_page.dart';
import '../../../theme/app_font_weights.dart';

class StorageSpacePage extends StatefulWidget {
  const StorageSpacePage({super.key, this.embedded = false});

  final bool embedded;

  @override
  State<StorageSpacePage> createState() => _StorageSpacePageState();
}

class _StorageSpacePageState extends State<StorageSpacePage> {
  StorageUsageReport? _report;
  bool _loading = false;
  bool _clearing = false;
  StorageUsageCategoryKey _selected = StorageUsageCategoryKey.images;

  @override
  void initState() {
    super.initState();
    _refreshReport();
  }

  Future<StorageUsageReport?> _refreshReport() async {
    if (_loading) return _report;
    setState(() => _loading = true);
    try {
      final rep = await StorageUsageService.computeReport();
      if (!mounted) return rep;
      setState(() {
        _report = rep;
        _loading = false;
        final keys = rep.categories.map((c) => c.key).toSet();
        if (!keys.contains(_selected)) {
          _selected = StorageUsageCategoryKey.images;
        }
      });
      return rep;
    } catch (_) {
      if (!mounted) return null;
      setState(() => _loading = false);
      return null;
    }
  }

  Color _barColorFor(StorageUsageCategoryKey key, ColorScheme cs) {
    switch (key) {
      case StorageUsageCategoryKey.images:
        return const Color(0xFF6366F1); // indigo
      case StorageUsageCategoryKey.files:
        return const Color(0xFFA855F7); // purple
      case StorageUsageCategoryKey.chatData:
        return const Color(0xFF22C55E);
      case StorageUsageCategoryKey.assistantData:
        return const Color(0xFF3B82F6); // blue (distinct from chat green)
      case StorageUsageCategoryKey.cache:
        return const Color(0xFFEF4444); // red
      case StorageUsageCategoryKey.logs:
        return const Color(0xFFEAB308); // yellow
      case StorageUsageCategoryKey.other:
        return cs.onSurface.withValues(alpha: 0.22);
      case StorageUsageCategoryKey.deletedRecords:
        return const Color(0xFF64748B); // slate
    }
  }

  IconData _iconFor(StorageUsageCategoryKey key) {
    switch (key) {
      case StorageUsageCategoryKey.images:
        return Lucide.Image;
      case StorageUsageCategoryKey.files:
        return Lucide.Paperclip;
      case StorageUsageCategoryKey.chatData:
        return Lucide.MessagesSquare;
      case StorageUsageCategoryKey.assistantData:
        return Lucide.Bot;
      case StorageUsageCategoryKey.cache:
        return Lucide.Boxes;
      case StorageUsageCategoryKey.logs:
        return Lucide.FileText;
      case StorageUsageCategoryKey.other:
        return Lucide.Box;
      case StorageUsageCategoryKey.deletedRecords:
        return Lucide.Trash2;
    }
  }

  String _titleFor(StorageUsageCategoryKey key, AppLocalizations l10n) {
    switch (key) {
      case StorageUsageCategoryKey.images:
        return l10n.storageSpaceCategoryImages;
      case StorageUsageCategoryKey.files:
        return l10n.storageSpaceCategoryFiles;
      case StorageUsageCategoryKey.chatData:
        return l10n.storageSpaceCategoryChatData;
      case StorageUsageCategoryKey.assistantData:
        return l10n.storageSpaceCategoryAssistantData;
      case StorageUsageCategoryKey.cache:
        return l10n.storageSpaceCategoryCache;
      case StorageUsageCategoryKey.logs:
        return l10n.storageSpaceCategoryLogs;
      case StorageUsageCategoryKey.other:
        return l10n.storageSpaceCategoryOther;
      case StorageUsageCategoryKey.deletedRecords:
        return l10n.storageSpaceCategoryDeletedRecords;
    }
  }

  String _subTitleFor(String id, AppLocalizations l10n) {
    switch (id) {
      case 'messages':
        return l10n.storageSpaceSubChatMessages;
      case 'conversations':
        return l10n.storageSpaceSubChatConversations;
      case 'tool_events_v1':
        return l10n.storageSpaceSubChatToolEvents;
      case 'sqlite_database':
        return l10n.storageSpaceSubChatDatabase;
      case 'sqlite_wal':
        return l10n.storageSpaceSubChatWriteAheadLog;
      case 'sqlite_shm':
        return l10n.storageSpaceSubChatSharedMemory;
      case 'avatars':
        return l10n.storageSpaceSubAssistantAvatars;
      case 'images':
        return l10n.storageSpaceSubAssistantImages;
      case 'avatar_cache':
        return l10n.storageSpaceSubCacheAvatars;
      case 'other_cache':
        return l10n.storageSpaceSubCacheOther;
      case 'system_cache':
        return l10n.storageSpaceSubCacheSystem;
      case 'tmp_cache':
        return l10n.storageSpaceSubCacheTmp;
      case 'flutter_logs':
        return l10n.storageSpaceSubLogsFlutter;
      case 'request_logs':
        return l10n.storageSpaceSubLogsRequests;
      case 'other_logs':
        return l10n.storageSpaceSubLogsOther;
      default:
        return id;
    }
  }

  String? _subDescFor(String id, AppLocalizations l10n) {
    switch (id) {
      case 'avatar_cache':
        return l10n.storageSpaceSubDescAvatarCache;
      case 'other_cache':
        return l10n.storageSpaceSubDescOtherCache;
      case 'system_cache':
        return l10n.storageSpaceSubDescSystemCache;
      case 'tmp_cache':
        return l10n.storageSpaceSubDescTmpCache;
      default:
        return null;
    }
  }

  Future<bool> _confirmAction(
    BuildContext context, {
    required String title,
    required String message,
    required String actionLabel,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.homePageCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(actionLabel),
            ),
          ],
        );
      },
    );
    return res ?? false;
  }

  Future<void> _doClearCache({required bool avatarsOnly}) async {
    if (_clearing) return;
    final l10n = AppLocalizations.of(context)!;
    final targetName = avatarsOnly
        ? l10n.storageSpaceSubCacheAvatars
        : l10n.storageSpaceCategoryCache;
    final ok = await _confirmAction(
      context,
      title: l10n.storageSpaceClearConfirmTitle,
      message: l10n.storageSpaceClearConfirmMessage(targetName),
      actionLabel: l10n.storageSpaceClearButton,
    );
    if (!ok) return;

    setState(() => _clearing = true);
    try {
      await StorageUsageService.clearCache(avatarsOnly: avatarsOnly);
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearDone(targetName),
        type: NotificationType.success,
      );
      await _refreshReport();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearFailed(e.toString()),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _doClearOtherCache() async {
    if (_clearing) return;
    final l10n = AppLocalizations.of(context)!;
    final targetName = l10n.storageSpaceSubCacheOther;
    final ok = await _confirmAction(
      context,
      title: l10n.storageSpaceClearConfirmTitle,
      message: l10n.storageSpaceClearConfirmMessage(targetName),
      actionLabel: l10n.storageSpaceClearButton,
    );
    if (!ok) return;

    setState(() => _clearing = true);
    try {
      await StorageUsageService.clearOtherCache();
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearDone(targetName),
        type: NotificationType.success,
      );
      await _refreshReport();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearFailed(e.toString()),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _doClearSystemCache() async {
    if (_clearing) return;
    final l10n = AppLocalizations.of(context)!;
    final targetName = l10n.storageSpaceSubCacheSystem;
    final ok = await _confirmAction(
      context,
      title: l10n.storageSpaceClearConfirmTitle,
      message: l10n.storageSpaceClearConfirmMessage(targetName),
      actionLabel: l10n.storageSpaceClearButton,
    );
    if (!ok) return;

    setState(() => _clearing = true);
    try {
      await StorageUsageService.clearSystemCache();
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearDone(targetName),
        type: NotificationType.success,
      );
      await _refreshReport();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearFailed(e.toString()),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _doClearTmpCache() async {
    if (_clearing) return;
    final l10n = AppLocalizations.of(context)!;
    final targetName = l10n.storageSpaceSubCacheTmp;
    final ok = await _confirmAction(
      context,
      title: l10n.storageSpaceClearConfirmTitle,
      message: l10n.storageSpaceClearConfirmMessage(targetName),
      actionLabel: l10n.storageSpaceClearButton,
    );
    if (!ok) return;

    setState(() => _clearing = true);
    try {
      await StorageUsageService.clearTmpCache();
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearDone(targetName),
        type: NotificationType.success,
      );
      await _refreshReport();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearFailed(e.toString()),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _doClearLogs() async {
    if (_clearing) return;
    final l10n = AppLocalizations.of(context)!;
    final targetName = l10n.storageSpaceCategoryLogs;
    final ok = await _confirmAction(
      context,
      title: l10n.storageSpaceClearConfirmTitle,
      message: l10n.storageSpaceClearConfirmMessage(targetName),
      actionLabel: l10n.storageSpaceClearButton,
    );
    if (!ok) return;

    setState(() => _clearing = true);
    try {
      await StorageUsageService.clearLogs();
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearDone(targetName),
        type: NotificationType.success,
      );
      await _refreshReport();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearFailed(e.toString()),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _openWorkspaceFiles() async {
    // The provider's async init is normally done long before the user
    // reaches this page; fall back to a direct path resolve if not.
    final navigator = Navigator.of(context);
    final provider = context.read<FilesystemMountsProvider>();
    final path =
        provider.workspaces?.path ??
        (await AppDirectories.getWorkspacesDirectory()).path;
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => MountFilesPage(
          mount: FilesystemMount(
            alias: FilesystemMountsProvider.workspacesAlias,
            path: path,
            readOnly: false,
          ),
        ),
      ),
    );
    await _refreshReport();
  }

  Future<void> _openCategoryDetail(StorageUsageCategoryKey key) async {
    final report = _report;
    if (report == null) return;
    final l10n = AppLocalizations.of(context)!;
    final title = _titleFor(key, l10n);
    if (key == StorageUsageCategoryKey.deletedRecords) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const TrashDetailPage()));
      // Refresh report after potential trash changes.
      await _refreshReport();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _StorageCategoryPage(
          title: title,
          categoryKey: key,
          initialReport: report,
          fmtBytes: formatBytes,
          subTitleFor: (id) => _subTitleFor(id, l10n),
          subDescFor: (id) => _subDescFor(id, l10n),
          refreshReport: _refreshReport,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final isDesktop = PlatformUtils.isDesktopTarget;

    final body = _loading && _report == null
        ? const Center(child: CircularProgressIndicator())
        : _report == null
        ? Center(
            child: Text(
              l10n.storageSpaceLoadFailed,
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7)),
            ),
          )
        : isDesktop
        ? _buildDesktop(context, _report!)
        : _buildMobile(context, _report!);

    if (widget.embedded) {
      // Desktop pages in the main IndexedStack are not wrapped by Scaffold/AppBar.
      // Ensure a Material ancestor + correct background to avoid odd text artifacts
      // (e.g., yellow underlines) and unreadable contrast in light mode.
      if (isDesktop) {
        return Material(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: body,
        );
      }
      return body;
    }

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
        title: Text(l10n.storageSpacePageTitle),
        actions: [
          IosIconButton(
            icon: Lucide.RefreshCw,
            size: 20,
            minSize: 44,
            enabled: !_loading,
            onTap: _loading ? null : _refreshReport,
            semanticLabel: l10n.storageSpaceRefreshTooltip,
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _buildDesktop(BuildContext context, StorageUsageReport report) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final total = report.totalBytes;
    final clearable = report.clearable.bytes;
    final showTopBar = widget.embedded;

    StorageUsageCategory cat(StorageUsageCategoryKey k) =>
        report.categories.firstWhere((c) => c.key == k);

    final selectedCat = cat(_selected);

    final topBar = SizedBox(
      height: 36,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 8),
            child: Text(
              l10n.storageSpacePageTitle,
              style: TextStyle(
                fontSize: 14,
                fontWeight: AppFontWeights.semibold,
                color: cs.onSurface,
                decoration: TextDecoration.none,
              ),
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(right: 8, top: 2),
            child: IosIconButton(
              icon: Lucide.RefreshCw,
              size: 18,
              enabled: !_loading,
              onTap: _loading ? null : _refreshReport,
              semanticLabel: l10n.storageSpaceRefreshTooltip,
            ),
          ),
        ],
      ),
    );

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '${l10n.storageSpaceTotalLabel}: ${formatBytes(total)}',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurface.withValues(alpha: 0.7),
                      decoration: TextDecoration.none,
                    ),
                  ),
                  if (clearable > 0) ...[
                    const SizedBox(width: 12),
                    Text(
                      l10n.storageSpaceClearableLabel(formatBytes(clearable)),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: cs.onSurface.withValues(alpha: 0.7),
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(
                      width: 280,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _MountsPanel(
                            onOpenWorkspace: () => _openWorkspaceFiles(),
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: _CategoryMenu(
                              categories: report.categories,
                              selected: _selected,
                              iconFor: _iconFor,
                              titleFor: (k) => _titleFor(k, l10n),
                              fmtBytes: formatBytes,
                              onSelect: (k) => setState(() => _selected = k),
                            ),
                          ),
                        ],
                      ),
                    ),
                    VerticalDivider(
                      width: 24,
                      color: cs.onSurface.withValues(alpha: 0.08),
                    ),
                    Expanded(
                      child:
                          selectedCat.key ==
                              StorageUsageCategoryKey.deletedRecords
                          ? const TrashDetailPage(embedded: true)
                          : _CategoryDetail(
                              category: selectedCat,
                              title: _titleFor(selectedCat.key, l10n),
                              fmtBytes: formatBytes,
                              subTitleFor: (id) => _subTitleFor(id, l10n),
                              subDescFor: (id) => _subDescFor(id, l10n),
                              clearing: _clearing,
                              onClearCache: _clearing ? null : _doClearCache,
                              onClearOtherCache: _clearing
                                  ? null
                                  : _doClearOtherCache,
                              onClearSystemCache: _clearing
                                  ? null
                                  : _doClearSystemCache,
                              onClearTmpCache: _clearing
                                  ? null
                                  : _doClearTmpCache,
                              onClearLogs: _clearing ? null : _doClearLogs,
                              refreshReport: _refreshReport,
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (showTopBar) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          topBar,
          Expanded(child: content),
        ],
      );
    }

    return content;
  }

  Widget _buildMobile(BuildContext context, StorageUsageReport report) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final total = report.totalBytes;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _iosSectionCard(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.storageSpaceTotalLabel,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: AppFontWeights.semibold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  formatBytes(total),
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: AppFontWeights.emphasis,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 10),
                _UsageBar(
                  categories: report.categories,
                  totalBytes: total,
                  colorFor: (k) => _barColorFor(k, cs),
                ),
                const SizedBox(height: 10),
                _UsageLegend(
                  categories: report.categories,
                  colorFor: (k) => _barColorFor(k, cs),
                  titleFor: (k) => _titleFor(k, l10n),
                ),
                if (report.clearable.bytes > 0) ...[
                  const SizedBox(height: 10),
                  Text(
                    l10n.storageSpaceClearableHint(
                      formatBytes(report.clearable.bytes),
                    ),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _iosSectionCard(
          child: _iosNavRow(
            context,
            icon: Lucide.FolderOpen,
            label: l10n.storageWorkspaceEntryTitle,
            onTap: () => _openWorkspaceFiles(),
          ),
        ),
        const SizedBox(height: 12),
        _iosSectionCard(
          child: Column(
            children: [
              for (int i = 0; i < report.categories.length; i++) ...[
                _iosNavRow(
                  context,
                  icon: _iconFor(report.categories[i].key),
                  label: _titleFor(report.categories[i].key, l10n),
                  detailText:
                      report.categories[i].key ==
                          StorageUsageCategoryKey.deletedRecords
                      ? null
                      : '${formatBytes(report.categories[i].stats.bytes)} · ${l10n.storageSpaceFilesCount(report.categories[i].stats.fileCount)}',
                  onTap: () => _openCategoryDetail(report.categories[i].key),
                ),
                if (i != report.categories.length - 1) _iosDivider(context),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _StorageCategoryPage extends StatefulWidget {
  const _StorageCategoryPage({
    required this.title,
    required this.categoryKey,
    required this.initialReport,
    required this.fmtBytes,
    required this.subTitleFor,
    required this.subDescFor,
    required this.refreshReport,
  });

  final String title;
  final StorageUsageCategoryKey categoryKey;
  final StorageUsageReport initialReport;
  final String Function(int) fmtBytes;
  final String Function(String) subTitleFor;
  final String? Function(String) subDescFor;
  final Future<StorageUsageReport?> Function() refreshReport;

  @override
  State<_StorageCategoryPage> createState() => _StorageCategoryPageState();
}

class _StorageCategoryPageState extends State<_StorageCategoryPage> {
  late StorageUsageReport _report = widget.initialReport;
  bool _refreshing = false;
  bool _clearing = false;

  StorageUsageCategory _cat(StorageUsageCategoryKey k) =>
      _report.categories.firstWhere((c) => c.key == k);

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final next = await widget.refreshReport();
      if (!mounted) return;
      if (next != null) setState(() => _report = next);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<bool> _confirmAction({
    required String title,
    required String message,
    required String actionLabel,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.homePageCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(actionLabel),
            ),
          ],
        );
      },
    );
    return res ?? false;
  }

  Future<void> _clearCache({required bool avatarsOnly}) async {
    if (_clearing) return;
    final l10n = AppLocalizations.of(context)!;
    final targetName = avatarsOnly
        ? l10n.storageSpaceSubCacheAvatars
        : l10n.storageSpaceCategoryCache;
    final ok = await _confirmAction(
      title: l10n.storageSpaceClearConfirmTitle,
      message: l10n.storageSpaceClearConfirmMessage(targetName),
      actionLabel: l10n.storageSpaceClearButton,
    );
    if (!ok) return;

    setState(() => _clearing = true);
    try {
      await StorageUsageService.clearCache(avatarsOnly: avatarsOnly);
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearDone(targetName),
        type: NotificationType.success,
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearFailed(e.toString()),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _clearOtherCache() async {
    if (_clearing) return;
    final l10n = AppLocalizations.of(context)!;
    final targetName = l10n.storageSpaceSubCacheOther;
    final ok = await _confirmAction(
      title: l10n.storageSpaceClearConfirmTitle,
      message: l10n.storageSpaceClearConfirmMessage(targetName),
      actionLabel: l10n.storageSpaceClearButton,
    );
    if (!ok) return;

    setState(() => _clearing = true);
    try {
      await StorageUsageService.clearOtherCache();
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearDone(targetName),
        type: NotificationType.success,
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearFailed(e.toString()),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _clearSystemCache() async {
    if (_clearing) return;
    final l10n = AppLocalizations.of(context)!;
    final targetName = l10n.storageSpaceSubCacheSystem;
    final ok = await _confirmAction(
      title: l10n.storageSpaceClearConfirmTitle,
      message: l10n.storageSpaceClearConfirmMessage(targetName),
      actionLabel: l10n.storageSpaceClearButton,
    );
    if (!ok) return;

    setState(() => _clearing = true);
    try {
      await StorageUsageService.clearSystemCache();
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearDone(targetName),
        type: NotificationType.success,
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearFailed(e.toString()),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _clearTmpCache() async {
    if (_clearing) return;
    final l10n = AppLocalizations.of(context)!;
    final targetName = l10n.storageSpaceSubCacheTmp;
    final ok = await _confirmAction(
      title: l10n.storageSpaceClearConfirmTitle,
      message: l10n.storageSpaceClearConfirmMessage(targetName),
      actionLabel: l10n.storageSpaceClearButton,
    );
    if (!ok) return;

    setState(() => _clearing = true);
    try {
      await StorageUsageService.clearTmpCache();
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearDone(targetName),
        type: NotificationType.success,
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearFailed(e.toString()),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _clearLogs() async {
    if (_clearing) return;
    final l10n = AppLocalizations.of(context)!;
    final targetName = l10n.storageSpaceCategoryLogs;
    final ok = await _confirmAction(
      title: l10n.storageSpaceClearConfirmTitle,
      message: l10n.storageSpaceClearConfirmMessage(targetName),
      actionLabel: l10n.storageSpaceClearButton,
    );
    if (!ok) return;

    setState(() => _clearing = true);
    try {
      await StorageUsageService.clearLogs();
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearDone(targetName),
        type: NotificationType.success,
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.storageSpaceClearFailed(e.toString()),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final category = _cat(widget.categoryKey);

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: _TactileIconButton(
            icon: Lucide.ArrowLeft,
            color: Theme.of(context).colorScheme.onSurface,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(widget.title),
        actions: [
          IosIconButton(
            icon: Lucide.RefreshCw,
            size: 20,
            minSize: 44,
            enabled: !_refreshing,
            onTap: _refreshing ? null : _refresh,
            semanticLabel: l10n.storageSpaceRefreshTooltip,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _CategoryDetail(
          category: category,
          title: widget.title,
          fmtBytes: widget.fmtBytes,
          subTitleFor: widget.subTitleFor,
          subDescFor: widget.subDescFor,
          clearing: _clearing,
          onClearCache: (category.key == StorageUsageCategoryKey.cache)
              ? _clearCache
              : null,
          onClearOtherCache: (category.key == StorageUsageCategoryKey.cache)
              ? _clearOtherCache
              : null,
          onClearSystemCache: (category.key == StorageUsageCategoryKey.cache)
              ? _clearSystemCache
              : null,
          onClearTmpCache: (category.key == StorageUsageCategoryKey.cache)
              ? _clearTmpCache
              : null,
          onClearLogs: (category.key == StorageUsageCategoryKey.logs)
              ? _clearLogs
              : null,
          refreshReport: _refresh,
        ),
      ),
    );
  }
}

class _UsageBar extends StatelessWidget {
  const _UsageBar({
    required this.categories,
    required this.totalBytes,
    required this.colorFor,
  });

  final List<StorageUsageCategory> categories;
  final int totalBytes;
  final Color Function(StorageUsageCategoryKey) colorFor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = categories.where((c) => c.stats.bytes > 0).toList();
    if (items.isEmpty || totalBytes <= 0) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 12,
          color: cs.onSurface.withValues(alpha: 0.08),
        ),
      );
    }

    int flexFor(int bytes) {
      final f = ((bytes / totalBytes) * 1000).round();
      return f <= 0 ? 1 : f;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Row(
        children: [
          for (final c in items)
            Expanded(
              flex: flexFor(c.stats.bytes),
              child: Container(height: 12, color: colorFor(c.key)),
            ),
        ],
      ),
    );
  }
}

class _UsageLegend extends StatelessWidget {
  const _UsageLegend({
    required this.categories,
    required this.colorFor,
    required this.titleFor,
  });

  final List<StorageUsageCategory> categories;
  final Color Function(StorageUsageCategoryKey) colorFor;
  final String Function(StorageUsageCategoryKey) titleFor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = categories.where((c) => c.stats.bytes > 0).toList();
    if (items.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 14,
      runSpacing: 8,
      children: [
        for (final c in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: colorFor(c.key),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                titleFor(c.key),
                style: TextStyle(
                  fontSize: 12.5,
                  color: cs.onSurface.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _CategoryMenu extends StatelessWidget {
  const _CategoryMenu({
    required this.categories,
    required this.selected,
    required this.iconFor,
    required this.titleFor,
    required this.fmtBytes,
    required this.onSelect,
  });

  final List<StorageUsageCategory> categories;
  final StorageUsageCategoryKey selected;
  final IconData Function(StorageUsageCategoryKey) iconFor;
  final String Function(StorageUsageCategoryKey) titleFor;
  final String Function(int) fmtBytes;
  final ValueChanged<StorageUsageCategoryKey> onSelect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final border = cs.onSurface.withValues(alpha: 0.08);

    return ListView(
      children: [
        for (final c in categories)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: border),
              ),
              clipBehavior: Clip.antiAlias,
              child: IosCardPress(
                onTap: () => onSelect(c.key),
                haptics: false,
                pressedScale: 1.0,
                borderRadius: BorderRadius.circular(10),
                baseColor: c.key == selected
                    ? cs.onSurface.withValues(alpha: 0.06)
                    : cs.onSurface.withValues(alpha: 0.03),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      iconFor(c.key),
                      size: 18,
                      color: c.key == selected
                          ? cs.onSurface.withValues(alpha: 0.9)
                          : cs.onSurface.withValues(alpha: 0.82),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        titleFor(c.key),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: AppFontWeights.semibold,
                          color: c.key == selected
                              ? cs.onSurface.withValues(alpha: 0.92)
                              : cs.onSurface.withValues(alpha: 0.88),
                        ),
                      ),
                    ),
                    if (c.key != StorageUsageCategoryKey.deletedRecords) ...[
                      const SizedBox(width: 8),
                      Text(
                        fmtBytes(c.stats.bytes),
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.65),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _CategoryDetail extends StatelessWidget {
  const _CategoryDetail({
    required this.category,
    required this.title,
    required this.fmtBytes,
    required this.subTitleFor,
    required this.subDescFor,
    required this.clearing,
    required this.onClearCache,
    required this.onClearOtherCache,
    required this.onClearSystemCache,
    required this.onClearTmpCache,
    required this.onClearLogs,
    required this.refreshReport,
  });

  final StorageUsageCategory category;
  final String title;
  final String Function(int) fmtBytes;
  final String Function(String) subTitleFor;
  final String? Function(String) subDescFor;
  final bool clearing;
  final Future<void> Function({required bool avatarsOnly})? onClearCache;
  final Future<void> Function()? onClearOtherCache;
  final Future<void> Function()? onClearSystemCache;
  final Future<void> Function()? onClearTmpCache;
  final Future<void> Function()? onClearLogs;
  final Future<void> Function() refreshReport;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;

    final subtitle =
        '${fmtBytes(category.stats.bytes)} · ${l10n.storageSpaceFilesCount(category.stats.fileCount)}';
    final bool safeToClear =
        category.key == StorageUsageCategoryKey.cache ||
        category.key == StorageUsageCategoryKey.logs;
    final String hint = safeToClear
        ? l10n.storageSpaceSafeToClearHint
        : l10n.storageSpaceNotSafeToClearHint;

    Widget? actions;
    if (category.key == StorageUsageCategoryKey.cache) {
      actions = Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          IosTileButton(
            label: l10n.storageSpaceClearAvatarCacheButton,
            icon: Lucide.User,
            backgroundColor: cs.primary,
            enabled: !clearing && onClearCache != null,
            onTap: () => onClearCache?.call(avatarsOnly: true),
          ),
          IosTileButton(
            label: l10n.storageSpaceClearCacheButton,
            icon: Lucide.Trash2,
            backgroundColor: cs.primary,
            enabled: !clearing && onClearCache != null,
            onTap: () => onClearCache?.call(avatarsOnly: false),
          ),
        ],
      );
    } else if (category.key == StorageUsageCategoryKey.logs) {
      actions = Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          IosTileButton(
            label: l10n.storageSpaceViewLogsButton,
            icon: Lucide.Eye,
            backgroundColor: cs.primary,
            onTap: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const LogViewerPage()));
            },
          ),
          IosTileButton(
            label: l10n.storageSpaceClearLogsButton,
            icon: Lucide.Trash2,
            backgroundColor: cs.primary,
            enabled: !clearing && onClearLogs != null,
            onTap: () => onClearLogs?.call(),
          ),
        ],
      );
    }

    if (category.key == StorageUsageCategoryKey.images ||
        category.key == StorageUsageCategoryKey.files) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(fontSize: 16, fontWeight: AppFontWeights.emphasis),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 12.5,
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hint,
            style: TextStyle(
              fontSize: 12.5,
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _UploadManager(
              key: ValueKey(category.key),
              images: category.key == StorageUsageCategoryKey.images,
              refreshReport: refreshReport,
              fmtBytes: fmtBytes,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(fontSize: 16, fontWeight: AppFontWeights.emphasis),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 12.5,
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          hint,
          style: TextStyle(
            fontSize: 12.5,
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 14),
        if (actions != null) actions,
        if (actions != null) const SizedBox(height: 14),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (category.subcategories.isNotEmpty) ...[
                  Text(
                    l10n.storageSpaceBreakdownTitle,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: AppFontWeights.emphasis,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final s in category.subcategories)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      decoration: BoxDecoration(
                        color: cs.onSurface.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: cs.onSurface.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  subTitleFor(s.id),
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: AppFontWeights.semibold,
                                  ),
                                ),
                                if (subDescFor(s.id) case final desc?
                                    when desc.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    desc,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurface.withValues(
                                        alpha: 0.6,
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 2),
                                Text(
                                  '${fmtBytes(s.stats.bytes)} · ${l10n.storageSpaceFilesCount(s.stats.fileCount)}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: cs.onSurface.withValues(alpha: 0.65),
                                  ),
                                ),
                                if (s.path != null && s.path!.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    s.path!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: cs.onSurface.withValues(
                                        alpha: 0.55,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (category.key == StorageUsageCategoryKey.cache &&
                              s.id == 'avatar_cache')
                            _MiniActionButton(
                              label: l10n.storageSpaceClearButton,
                              enabled: !clearing,
                              onTap: () =>
                                  onClearCache?.call(avatarsOnly: true),
                            ),
                          if (category.key == StorageUsageCategoryKey.cache &&
                              s.id == 'other_cache')
                            _MiniActionButton(
                              label: l10n.storageSpaceClearButton,
                              enabled: !clearing,
                              onTap: () => onClearOtherCache?.call(),
                            ),
                          if (category.key == StorageUsageCategoryKey.cache &&
                              s.id == 'system_cache')
                            _MiniActionButton(
                              label: l10n.storageSpaceClearButton,
                              enabled: !clearing,
                              onTap: () => onClearSystemCache?.call(),
                            ),
                          if (category.key == StorageUsageCategoryKey.cache &&
                              s.id == 'tmp_cache')
                            _MiniActionButton(
                              label: l10n.storageSpaceClearButton,
                              enabled: !clearing,
                              onTap: () => onClearTmpCache?.call(),
                            ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _UploadManager extends StatefulWidget {
  const _UploadManager({
    super.key,
    required this.images,
    required this.refreshReport,
    required this.fmtBytes,
  });

  final bool images;
  final Future<void> Function() refreshReport;
  final String Function(int) fmtBytes;

  @override
  State<_UploadManager> createState() => _UploadManagerState();
}

class _UploadManagerState extends State<_UploadManager> {
  bool _loading = false;
  List<StorageFileEntry> _entries = const <StorageFileEntry>[];
  final Set<String> _selected = <String>{};
  bool _bySize = false;
  bool _descending = true;
  Map<String, List<FileReference>>? _refs;
  bool _computing = false;
  bool _showOrphansOnly = false;
  String? _imagesDirPath;

  bool get _selectMode => _selected.isNotEmpty;

  bool _isAiGenerated(String diskPath) {
    final imagesDir = _imagesDirPath;
    if (imagesDir == null || imagesDir.isEmpty) return false;
    return p.isWithin(canonicalizePath(imagesDir), canonicalizePath(diskPath));
  }

  int get _orphanCount {
    final refs = _refs;
    if (refs == null) return 0;
    return _entries
        .where((e) => !_isAiGenerated(e.path) && _refCountFor(e.path) == 0)
        .length;
  }

  List<StorageFileEntry> get _displayEntries {
    var list = _showOrphansOnly && _refs != null
        ? _entries
              .where(
                (e) => !_isAiGenerated(e.path) && _refCountFor(e.path) == 0,
              )
              .toList()
        : _entries.toList();
    final cmp = _bySize
        ? ((a, b) => a.bytes.compareTo(b.bytes))
        : ((a, b) => a.modifiedAt.compareTo(b.modifiedAt));
    list.sort((a, b) {
      final r = cmp(a, b);
      if (r != 0) return _descending ? -r : r;
      return a.name.compareTo(b.name); // tie-break
    });
    return list;
  }

  int _refCountFor(String diskPath) {
    final refs = _refs;
    if (refs == null) return 0;
    return refs[canonicalizePath(diskPath)]?.length ?? 0;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _UploadManager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.images != widget.images) {
      setState(() {
        _selected.clear();
        _entries = const <StorageFileEntry>[];
        _loading = false;
        _refs = null;
        _showOrphansOnly = false;
        _bySize = false;
        _descending = true;
      });
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final list = await StorageUsageService.listUploadEntries(
        images: widget.images,
      );
      final imagesDir = await AppDirectories.getImagesDirectory();
      if (!mounted) return;
      setState(() {
        _entries = list;
        _imagesDirPath = imagesDir.path;
        final paths = _entries.map((e) => e.path).toSet();
        _selected.removeWhere((p) => !paths.contains(p));
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _computeRefs() async {
    if (_computing) return;
    setState(() => _computing = true);
    try {
      final refs = await context.read<ChatService>().computeFileReferences();
      if (!mounted) return;
      setState(() => _refs = refs);
    } finally {
      if (mounted) setState(() => _computing = false);
    }
  }

  void _toggleSelect(String path) {
    setState(() {
      if (_selected.contains(path)) {
        _selected.remove(path);
      } else {
        _selected.add(path);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selected
        ..clear()
        ..addAll(_displayEntries.map((e) => e.path));
    });
  }

  void _clearSelection() {
    setState(() => _selected.clear());
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final count = _selected.length;
    final refCount = _refs != null
        ? _selected.where((p) => _refCountFor(p) > 0).length
        : 0;
    final hasRefs = refCount > 0;
    final draftFiles = context
        .read<InputDraftPersistence>()
        .draftReferencedFiles();
    final draftHitCount = _selected.where(draftFiles.contains).length;
    var content = hasRefs
        ? '${l10n.storageSpaceDeleteUploadsConfirmMessage(count)}\n\n${l10n.storageSpaceDeleteRefWarning(refCount)}'
        : l10n.storageSpaceDeleteSimpleConfirm(count);
    // Deletion guardrail: warn (but do not block) when the selected files
    // are still referenced by the unsent input draft.
    if (draftHitCount > 0) {
      content =
          '$content\n\n${l10n.storageSpaceDeleteDraftWarning(draftHitCount)}';
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.storageSpaceDeleteConfirmTitle),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.homePageCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.homePageDelete),
            ),
          ],
        );
      },
    );
    if (ok != true) return;

    final deleted = await StorageUsageService.deleteUploadFiles(
      _selected,
      images: widget.images,
    );
    if (!mounted) return;

    _clearSelection();
    showAppSnackBar(
      context,
      message: l10n.storageSpaceDeletedUploadsDone(deleted),
      type: NotificationType.success,
    );
    await _load();
    await widget.refreshReport();
  }

  Future<void> _openImageViewer(int initialIndex) async {
    final images = _displayEntries.map((e) => e.path).toList(growable: false);
    final route = PlatformUtils.isDesktopTarget
        ? PageRouteBuilder(
            pageBuilder: (_, __, ___) =>
                ImageViewerPage(images: images, initialIndex: initialIndex),
            transitionDuration: const Duration(milliseconds: 180),
            reverseTransitionDuration: const Duration(milliseconds: 160),
            transitionsBuilder: (ctx, anim, sec, child) {
              final curved = CurvedAnimation(
                parent: anim,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              );
              return FadeTransition(opacity: curved, child: child);
            },
          )
        : MaterialPageRoute(
            builder: (_) =>
                ImageViewerPage(images: images, initialIndex: initialIndex),
          );
    await Navigator.of(context).push(route);
  }

  Future<void> _openFile(String path) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final res = await OpenFilex.open(path);
      if (res.type != ResultType.done) {
        if (!mounted) return;
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetCannotOpenFile(res.message),
          type: NotificationType.error,
        );
      }
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.chatMessageWidgetOpenFileError(e.toString()),
        type: NotificationType.error,
      );
    }
  }

  void _locateReferences(List<FileReference> refs) {
    if (refs.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final isDesktop = PlatformUtils.isDesktopTarget;
    if (isDesktop) {
      MessageLocateBus.instance.fire(
        conversationId: refs.first.conversationId,
        messageId: refs.first.messageId,
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Text(
                  l10n.storageSpaceLocateTitle,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.semibold,
                  ),
                ),
              ),
              ...refs.map(
                (ref) => ListTile(
                  title: Text(
                    ref.conversationTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: ref.preview.isNotEmpty
                      ? Text(
                          ref.preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        )
                      : null,
                  onTap: () {
                    Navigator.of(ctx).maybePop();
                    if (Navigator.of(context).canPop()) {
                      Navigator.of(context).maybePop();
                    }
                    MessageLocateBus.instance.fire(
                      conversationId: ref.conversationId,
                      messageId: ref.messageId,
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSortSegment(ColorScheme cs) {
    final border = cs.onSurface.withValues(alpha: 0.12);
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sortCell(
            label: _bySize
                ? '${_descending ? '↓' : '↑'} ${l10n.storageSpaceSortBySize}'
                : l10n.storageSpaceSortBySize,
            active: _bySize,
            cs: cs,
            onTap: () => setState(() {
              if (_bySize) {
                _descending = !_descending;
              } else {
                _bySize = true;
                _descending = true;
              }
            }),
          ),
          Container(width: 1, height: 20, color: border),
          _sortCell(
            label: !_bySize
                ? '${_descending ? '↓' : '↑'} ${l10n.storageSpaceSortByTime}'
                : l10n.storageSpaceSortByTime,
            active: !_bySize,
            cs: cs,
            onTap: () => setState(() {
              if (!_bySize) {
                _descending = !_descending;
              } else {
                _bySize = false;
                _descending = true;
              }
            }),
          ),
        ],
      ),
    );
  }

  Widget _togglePill(
    ColorScheme cs,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selBg = isDark
        ? cs.primary.withValues(alpha: 0.20)
        : cs.primary.withValues(alpha: 0.12);
    final baseBg = isDark ? Colors.white10 : const Color(0xFFF7F7F9);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? selBg : baseBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? cs.primary.withValues(alpha: 0.35)
                : cs.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: selected ? cs.primary : cs.onSurface.withValues(alpha: 0.82),
            fontSize: 13,
            fontWeight: AppFontWeights.semibold,
          ),
        ),
      ),
    );
  }

  Widget _buildActions(ColorScheme cs, AppLocalizations l10n) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _buildSortSegment(cs),
        if (_refs != null && _orphanCount > 0)
          _togglePill(
            cs,
            l10n.storageSpaceShowOrphansOnly,
            _showOrphansOnly,
            () => setState(() => _showOrphansOnly = !_showOrphansOnly),
          )
        else if (_refs == null)
          IosTileButton(
            label: l10n.storageSpaceComputeRefs,
            icon: _computing ? Icons.hourglass_empty : Lucide.Search,
            backgroundColor: cs.primary,
            enabled: !_computing,
            onTap: () {
              _computeRefs();
            },
          ),
        IosTileButton(
          label: _selectMode
              ? l10n.storageSpaceClearSelection
              : l10n.storageSpaceSelectAll,
          icon: _selectMode ? Lucide.XCircle : Lucide.CheckSquare,
          backgroundColor: cs.primary,
          onTap: _selectMode ? _clearSelection : _selectAll,
        ),
        IosTileButton(
          label: l10n.homePageDelete,
          icon: Lucide.Trash2,
          backgroundColor: cs.error,
          enabled: _selected.isNotEmpty,
          onTap: _deleteSelected,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final display = _displayEntries;

    if (_loading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_entries.isEmpty) {
      return Center(
        child: Text(
          l10n.storageSpaceNoUploads,
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7)),
        ),
      );
    }

    final actions = _buildActions(cs, l10n);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        actions,
        const SizedBox(height: 12),
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    _selectMode
                        ? l10n.storageSpaceSelectedCount(_selected.length)
                        : l10n.storageSpaceUploadsCount(display.length),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ),
              ),
              if (_refs != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Lucide.TriangleAlert,
                          size: 13,
                          color: cs.onSurface.withValues(alpha: 0.55),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            l10n.storageSpaceMarkdownRefLimitation,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: cs.onSurface.withValues(alpha: 0.55),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (widget.images)
                SliverPadding(
                  padding: const EdgeInsets.only(bottom: 16),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 140,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: 1,
                        ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final e = display[index];
                      final selected = _selected.contains(e.path);
                      final rc = _refCountFor(e.path);
                      final aiGen = _isAiGenerated(e.path);
                      return _ImageTile(
                        path: e.path,
                        bytes: e.bytes,
                        selected: selected,
                        refCount: _refs != null ? rc : null,
                        isAiGenerated: aiGen,
                        fmtBytes: widget.fmtBytes,
                        onToggle: () => _toggleSelect(e.path),
                        onTap: () {
                          if (_selectMode) {
                            _toggleSelect(e.path);
                          } else {
                            _openImageViewer(index);
                          }
                        },
                        onLongPress: () => _toggleSelect(e.path),
                        onRefCountTap: _refs != null && rc > 0 && !aiGen
                            ? () => _locateReferences(
                                _refs![canonicalizePath(e.path)]!,
                              )
                            : null,
                      );
                    }, childCount: display.length),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final e = display[index];
                    final selected = _selected.contains(e.path);
                    final rc = _refCountFor(e.path);
                    final aiGen = _isAiGenerated(e.path);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _FileRow(
                        entry: e,
                        selected: selected,
                        refCount: _refs != null ? rc : null,
                        isAiGenerated: aiGen,
                        fmtBytes: widget.fmtBytes,
                        onTap: () {
                          if (_selectMode) {
                            _toggleSelect(e.path);
                          } else {
                            _openFile(e.path);
                          }
                        },
                        onLongPress: () => _toggleSelect(e.path),
                        onToggle: () => _toggleSelect(e.path),
                        onRefCountTap: _refs != null && rc > 0 && !aiGen
                            ? () => _locateReferences(
                                _refs![canonicalizePath(e.path)]!,
                              )
                            : null,
                      ),
                    );
                  }, childCount: display.length),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _sortCell({
  required String label,
  required bool active,
  required ColorScheme cs,
  required VoidCallback onTap,
}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      color: active ? cs.primary.withValues(alpha: 0.12) : Colors.transparent,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: active ? AppFontWeights.semibold : AppFontWeights.regular,
          color: active ? cs.primary : cs.onSurface.withValues(alpha: 0.75),
        ),
      ),
    ),
  );
}

class _ImageTile extends StatelessWidget {
  const _ImageTile({
    required this.path,
    required this.bytes,
    required this.selected,
    required this.refCount,
    required this.isAiGenerated,
    required this.fmtBytes,
    required this.onToggle,
    required this.onTap,
    required this.onLongPress,
    this.onRefCountTap,
  });

  final String path;
  final int bytes;
  final bool selected;
  final int? refCount;
  final bool isAiGenerated;
  final String Function(int) fmtBytes;
  final VoidCallback onToggle;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onRefCountTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cs = Theme.of(context).colorScheme;
        final border = cs.onSurface.withValues(alpha: 0.10);
        final dpr = MediaQuery.of(context).devicePixelRatio;
        final side = constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : 140.0;
        final int cachePx = (side * dpr).clamp(64.0, 1024.0).round();

        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? cs.primary.withValues(alpha: 0.55) : border,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: IosCardPress(
            onTap: onTap,
            onLongPress: onLongPress,
            haptics: false,
            pressedScale: 1.0,
            borderRadius: BorderRadius.circular(12),
            baseColor: cs.onSurface.withValues(alpha: 0.03),
            padding: EdgeInsets.zero,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  cacheWidth: cachePx,
                  cacheHeight: cachePx,
                  filterQuality: FilterQuality.low,
                  errorBuilder: (_, __, ___) {
                    return Container(
                      color: cs.onSurface.withValues(alpha: 0.04),
                      alignment: Alignment.center,
                      child: Icon(
                        Lucide.ImageOff,
                        size: 18,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    );
                  },
                ),
                // Size overlay (eager — always visible)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 22,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.55),
                        ],
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      fmtBytes(bytes),
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: AppFontWeights.semibold,
                        color: Colors.white.withValues(alpha: 0.92),
                      ),
                    ),
                  ),
                ),
                // refCount / AI-generated badge (on-demand — appears after compute)
                if (refCount != null || isAiGenerated)
                  Positioned(
                    top: 4,
                    left: 4,
                    child: GestureDetector(
                      onTap: refCount != null && refCount! > 0 && !isAiGenerated
                          ? onRefCountTap
                          : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: isAiGenerated
                              ? const Color(0xFF8B5CF6).withValues(alpha: 0.85)
                              : refCount! > 0
                              ? cs.primary.withValues(alpha: 0.85)
                              : cs.onSurface.withValues(alpha: 0.50),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          isAiGenerated
                              ? AppLocalizations.of(
                                  context,
                                )!.storageSpaceAiGenerated
                              : refCount! > 0
                              ? '×${refCount!}'
                              : AppLocalizations.of(
                                  context,
                                )!.storageSpaceRefNone,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: AppFontWeights.semibold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                // Checkbox (top-right)
                Positioned(
                  top: 6,
                  right: 6,
                  child: IosCheckbox(
                    value: selected,
                    size: 20,
                    hitTestSize: 22,
                    borderWidth: 1.6,
                    activeColor: cs.primary,
                    borderColor: cs.primary.withValues(alpha: 0.55),
                    onChanged: (_) => onToggle(),
                    enableHaptics: false,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.entry,
    required this.selected,
    required this.fmtBytes,
    this.refCount,
    this.isAiGenerated = false,
    required this.onTap,
    required this.onLongPress,
    required this.onToggle,
    this.onRefCountTap,
  });

  final StorageFileEntry entry;
  final bool selected;
  final String Function(int) fmtBytes;
  final int? refCount;
  final bool isAiGenerated;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggle;
  final VoidCallback? onRefCountTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final border = cs.onSurface.withValues(alpha: 0.08);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: IosCardPress(
        onTap: onTap,
        onLongPress: onLongPress,
        haptics: false,
        pressedScale: 1.0,
        borderRadius: BorderRadius.circular(12),
        baseColor: cs.onSurface.withValues(alpha: 0.03),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            IosCheckbox(
              value: selected,
              size: 20,
              hitTestSize: 22,
              borderWidth: 1.6,
              activeColor: cs.primary,
              borderColor: cs.primary.withValues(alpha: 0.55),
              onChanged: (_) => onToggle(),
              enableHaptics: false,
            ),
            const SizedBox(width: 10),
            Icon(
              Lucide.Paperclip,
              size: 18,
              color: cs.onSurface.withValues(alpha: 0.82),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: AppFontWeights.semibold,
                      color: cs.onSurface.withValues(alpha: 0.88),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${fmtBytes(entry.bytes)} · ${_fmtTime(entry.modifiedAt)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
            ),
            // refCount / AI-generated label (on-demand)
            if (refCount != null || isAiGenerated) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: refCount != null && refCount! > 0 && !isAiGenerated
                    ? onRefCountTap
                    : null,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: isAiGenerated
                        ? const Color(0xFF8B5CF6).withValues(alpha: 0.12)
                        : refCount! > 0
                        ? cs.primary.withValues(alpha: 0.12)
                        : cs.onSurface.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isAiGenerated
                        ? l10n.storageSpaceAiGenerated
                        : refCount! > 0
                        ? l10n.storageSpaceRefCount(refCount!)
                        : l10n.storageSpaceRefNone,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: AppFontWeights.semibold,
                      color: isAiGenerated
                          ? const Color(0xFF8B5CF6)
                          : refCount! > 0
                          ? cs.primary
                          : cs.onSurface.withValues(alpha: 0.50),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _fmtTime(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }
}

class _MiniActionButton extends StatelessWidget {
  const _MiniActionButton({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color fg = enabled
        ? cs.primary
        : cs.onSurface.withValues(alpha: 0.35);
    final Color bg = enabled
        ? cs.primary.withValues(alpha: 0.12)
        : cs.onSurface.withValues(alpha: 0.03);
    final Color border = enabled
        ? cs.primary.withValues(alpha: 0.35)
        : cs.onSurface.withValues(alpha: 0.10);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: AppFontWeights.semibold,
            color: fg,
          ),
        ),
      ),
    );
  }
}

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
    final pressColor = base.withValues(alpha: 0.7);
    final icon = Icon(
      widget.icon,
      size: widget.size,
      color: _pressed ? pressColor : base,
    );

    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          Haptics.light();
          widget.onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: icon,
        ),
      ),
    );
  }
}

Widget _iosSectionCard({required Widget child}) {
  return Builder(
    builder: (context) {
      final theme = Theme.of(context);
      final cs = theme.colorScheme;
      final isDark = theme.brightness == Brightness.dark;
      final Color bg = isDark
          ? Colors.white10
          : Colors.white.withValues(alpha: 0.96);
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
        child: child,
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

Widget _iosNavRow(
  BuildContext context, {
  required IconData icon,
  required String label,
  String? detailText,
  Widget? trailing,
  required VoidCallback onTap,
}) {
  final cs = Theme.of(context).colorScheme;
  return IosCardPress(
    onTap: onTap,
    pressedScale: 1.0,
    borderRadius: BorderRadius.zero,
    baseColor: Colors.transparent,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    child: Row(
      children: [
        SizedBox(
          width: 36,
          child: Icon(
            icon,
            size: 20,
            color: cs.onSurface.withValues(alpha: 0.9),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              color: cs.onSurface.withValues(alpha: 0.9),
              fontWeight: AppFontWeights.medium,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (detailText != null)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              detailText,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        if (trailing != null) ...[
          const SizedBox(width: 6),
          trailing,
          const SizedBox(width: 6),
        ],
        Icon(
          Lucide.ChevronRight,
          size: 16,
          color: cs.onSurface.withValues(alpha: 0.75),
        ),
      ],
    ),
  );
}

/// Desktop-only panel: `@workspaces` entry + external mount config.
/// External mounts are never synced and never appear on mobile.
class _MountsPanel extends StatelessWidget {
  const _MountsPanel({required this.onOpenWorkspace});

  final VoidCallback onOpenWorkspace;

  Future<void> _confirmRemove(
    BuildContext context,
    FilesystemMountsProvider provider,
    FilesystemMount mount,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.storageMountsRemoveConfirmTitle),
        content: Text(
          l10n.storageMountsRemoveConfirmMessage('@${mount.alias}'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.homePageCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.workspaceFilesDeleteButton),
          ),
        ],
      ),
    );
    if (ok == true) {
      await provider.removeExternalMount(mount.alias);
    }
  }

  Future<void> _openEdit(
    BuildContext context,
    FilesystemMountsProvider provider, {
    FilesystemMount? existing,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) =>
          _MountEditDialog(provider: provider, existing: existing),
    );
  }

  Future<void> _openPreview(BuildContext context, FilesystemMount mount) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => MountFilesPage(mount: mount)));
  }

  Future<void> _openWorkspaceLocationDialog(
    BuildContext context,
    FilesystemMountsProvider provider,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _WorkspacesLocationDialog(provider: provider),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<FilesystemMountsProvider>();

    return _iosSectionCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Lucide.HardDrive,
                  size: 16,
                  color: cs.onSurface.withValues(alpha: 0.8),
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.storageMountsTitle,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface.withValues(alpha: 0.9),
                  ),
                ),
                const Spacer(),
                IosIconButton(
                  icon: Lucide.Plus,
                  size: 16,
                  minSize: 28,
                  semanticLabel: l10n.storageMountsAddButton,
                  onTap: () => _openEdit(context, provider),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _MountRow(
              alias: '@workspaces',
              path: provider.workspaces?.path ?? '',
              readOnly: false,
              builtin: true,
              onTap: onOpenWorkspace,
              onEdit: () => _openWorkspaceLocationDialog(context, provider),
            ),
            for (final m in provider.externalMounts) ...[
              const SizedBox(height: 6),
              _MountRow(
                alias: '@${m.alias}',
                path: m.path,
                readOnly: m.readOnly,
                builtin: false,
                onTap: () => _openPreview(context, m),
                onEdit: () => _openEdit(context, provider, existing: m),
                onDelete: () => _confirmRemove(context, provider, m),
              ),
            ],
            if (provider.workspaces != null) ...[
              const SizedBox(height: 8),
              Text(
                l10n.storageMountsWorkspacesNote,
                style: TextStyle(
                  fontSize: 11.5,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MountRow extends StatelessWidget {
  const _MountRow({
    required this.alias,
    required this.path,
    required this.readOnly,
    required this.builtin,
    required this.onTap,
    this.onEdit,
    this.onDelete,
  });

  final String alias;
  final String path;
  final bool readOnly;
  final bool builtin;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      alias,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: AppFontWeights.medium,
                        color: cs.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: readOnly
                            ? cs.onSurface.withValues(alpha: 0.06)
                            : cs.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        readOnly ? l10n.storageMountsReadOnlyLabel : 'rw',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: readOnly
                              ? cs.onSurface.withValues(alpha: 0.6)
                              : cs.primary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  path,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (onEdit != null)
            _TactileIconButton(
              icon: Lucide.Pencil,
              color: cs.onSurface.withValues(alpha: 0.7),
              size: 16,
              onTap: onEdit!,
            ),
          if (!builtin && onDelete != null)
            _TactileIconButton(
              icon: Lucide.Trash2,
              color: cs.error.withValues(alpha: 0.8),
              size: 16,
              onTap: onDelete!,
            ),
        ],
      ),
    );
  }
}

class _MountEditDialog extends StatefulWidget {
  const _MountEditDialog({required this.provider, this.existing});

  final FilesystemMountsProvider provider;
  final FilesystemMount? existing;

  @override
  State<_MountEditDialog> createState() => _MountEditDialogState();
}

class _MountEditDialogState extends State<_MountEditDialog> {
  late final TextEditingController _alias = TextEditingController(
    text: widget.existing?.alias ?? '',
  );
  late final TextEditingController _path = TextEditingController(
    text: widget.existing?.path ?? '',
  );
  late bool _readOnly = widget.existing?.readOnly ?? true;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _alias.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _pickDirectory() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null || result.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _path.text = result;
      _error = null;
    });
  }

  String? _localizedError(String code) {
    final l10n = AppLocalizations.of(context)!;
    switch (code) {
      case FilesystemMountsProvider.errorAliasInvalid:
        return l10n.storageMountsErrorAliasInvalid;
      case FilesystemMountsProvider.errorAliasReserved:
        return l10n.storageMountsErrorAliasReserved;
      case FilesystemMountsProvider.errorAliasDuplicate:
        return l10n.storageMountsErrorAliasDuplicate;
      case FilesystemMountsProvider.errorPathInvalid:
        return l10n.storageMountsErrorPathInvalid;
      case FilesystemMountsProvider.errorPathNotFound:
        return l10n.storageMountsErrorPathNotFound;
      case FilesystemMountsProvider.errorSyncOverlap:
        return l10n.storageMountsErrorSyncOverlap;
      default:
        return null;
    }
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _saving = true;
      _error = null;
    });
    final existing = widget.existing;
    final String? err;
    if (existing == null) {
      err = await widget.provider.addExternalMount(
        alias: _alias.text.trim(),
        path: _path.text.trim(),
        readOnly: _readOnly,
      );
    } else {
      err = await widget.provider.updateExternalMount(
        alias: existing.alias,
        path: _path.text.trim(),
        readOnly: _readOnly,
      );
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (err != null) {
      final errorMessage = _localizedError(err);
      setState(() => _error = errorMessage);
      return;
    }
    if (context.mounted) {
      showAppSnackBar(
        context,
        message: l10n.storageMountsSaved('@${_alias.text.trim()}'),
        type: NotificationType.success,
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(
        widget.existing == null
            ? l10n.storageMountsAddDialogTitle
            : l10n.storageMountsEditDialogTitle,
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IosFormTextField(
              label: l10n.storageMountsAliasLabel,
              controller: _alias,
              enabled: widget.existing == null,
              hintText: 'docs',
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: IosFormTextField(
                    label: l10n.storageMountsPathLabel,
                    controller: _path,
                    hintText: '/path/to/dir',
                  ),
                ),
                const SizedBox(width: 8),
                IosTileButton(
                  label: l10n.storageMountsPickButton,
                  icon: Lucide.FolderOpen,
                  onTap: _pickDirectory,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  l10n.storageMountsReadOnlyLabel,
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                IosSwitch(
                  value: _readOnly,
                  onChanged: (v) => setState(() => _readOnly = v),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.homePageCancel),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: Text(
            widget.existing == null
                ? l10n.assistantTagsCreateDialogOk
                : l10n.homePageDone,
          ),
        ),
      ],
    );
  }
}

/// Desktop-only dialog to relocate the built-in `@workspaces` sandbox.
/// New locations are validated against the sync scope (overlapping the
/// backup/LAN-sync trees is rejected) and against nesting inside the
/// current sandbox.
class _WorkspacesLocationDialog extends StatefulWidget {
  const _WorkspacesLocationDialog({required this.provider});

  final FilesystemMountsProvider provider;

  @override
  State<_WorkspacesLocationDialog> createState() =>
      _WorkspacesLocationDialogState();
}

class _WorkspacesLocationDialogState extends State<_WorkspacesLocationDialog> {
  String? _path;
  bool _moveFiles = true;
  String? _error;
  bool _saving = false;

  Future<void> _pick() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null || result.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _path = result;
      _error = null;
    });
  }

  String? _localizedError(String code) {
    final l10n = AppLocalizations.of(context)!;
    switch (code) {
      case FilesystemMountsProvider.errorPathInvalid:
        return l10n.storageMountsErrorPathInvalid;
      case FilesystemMountsProvider.errorSyncOverlap:
        return l10n.storageMountsErrorSyncOverlap;
      case FilesystemMountsProvider.errorInsideWorkspaces:
        return l10n.storageMountsErrorInsideWorkspaces;
      case FilesystemMountsProvider.errorDestinationNotEmpty:
        return l10n.storageMountsErrorDestinationNotEmpty;
      default:
        // Unknown codes still surface — never silently no-op.
        return code;
    }
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final path = _path;
    if (path == null || path.isEmpty) {
      setState(() => _error = l10n.storageMountsErrorPathInvalid);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final String? err;
    try {
      err = await widget.provider.setWorkspacesLocation(
        path,
        moveFiles: _moveFiles,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = l10n.storageMountsWorkspacesMoveFailed('$e');
      });
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (err != null) {
      final errorMessage = _localizedError(err);
      setState(() => _error = errorMessage);
      return;
    }
    if (context.mounted) {
      showAppSnackBar(
        context,
        message: _moveFiles
            ? l10n.storageMountsWorkspacesMoved(path)
            : l10n.storageMountsWorkspacesLocationChanged,
        type: NotificationType.success,
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(l10n.storageMountsWorkspacesLocationDialogTitle),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.storageMountsWorkspacesLocationTitle,
              style: TextStyle(
                fontSize: 12.5,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _path ?? widget.provider.workspaces?.path ?? '',
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      color: cs.onSurface,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                IosTileButton(
                  label: l10n.storageMountsPickButton,
                  icon: Lucide.FolderOpen,
                  onTap: _pick,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.storageMountsWorkspacesMoveFilesLabel,
                    style: TextStyle(fontSize: 13.5, color: cs.onSurface),
                  ),
                ),
                const SizedBox(width: 8),
                IosSwitch(
                  value: _moveFiles,
                  onChanged: (v) => setState(() => _moveFiles = v),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(fontSize: 12.5, color: cs.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.homePageCancel),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: Text(l10n.homePageDone),
        ),
      ],
    );
  }
}
