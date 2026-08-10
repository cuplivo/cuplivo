import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/deleted_records_store.dart';
import '../../../core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart'
    show isSafeWireSegment;
import '../../../core/services/trash_restore_coordinator.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/expansion_setting_tile.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/app_directories.dart';

class TrashDetailPage extends StatefulWidget {
  const TrashDetailPage({
    super.key,
    this.embedded = false,
    this.initialTab = 0,
  });

  final bool embedded;
  final int initialTab;

  @override
  State<TrashDetailPage> createState() => _TrashDetailPageState();
}

class _TrashDetailPageState extends State<TrashDetailPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<DeletedRecordRow> _localTrash = [];
  List<DeletionMarkerRow> _conflicts = [];
  List<DeletionMarkerRow> _fileMarks = [];
  int _localCount = 0;
  int _pendingCount = 0;
  bool _loading = true;

  static const _trashCapOptions = [0, 1, 5, 10, 25, 50, 100, 200, 500];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 2),
    );
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final store = context.read<ChatService>().deletedRecordsStore;
    if (store == null) return;
    final settings = context.read<SettingsProvider>();
    final coordinator = context.read<TrashRestoreCoordinator>();
    await store.setCapMb(settings.trashCapMb);
    final local = await store.listDeletedRecords();
    final conflicts = await store.listConflicts(coordinator.getLocalIds);
    final fileMarks = await store.listFileDeletionMarkers();
    if (!mounted) return;
    setState(() {
      _localTrash = local;
      _conflicts = conflicts;
      _fileMarks = fileMarks;
      _localCount = local.length;
      _pendingCount = conflicts.length;
      _loading = false;
    });
  }

  String _typeLabel(String type, AppLocalizations l10n) {
    switch (type) {
      case DeletionEntityType.conversation:
        return l10n.storageSpaceCategoryChatData;
      case DeletionEntityType.message:
        return l10n.storageSpaceCategoryChatData;
      case DeletionEntityType.assistant:
        return l10n.storageSpaceCategoryAssistantData;
      case DeletionEntityType.worldBook:
        return l10n.trashTypeWorldBook;
      case DeletionEntityType.quickPhrase:
        return l10n.trashTypeQuickPhrase;
      case DeletionEntityType.mcpServer:
        return l10n.trashTypeMcpServer;
      case DeletionEntityType.memory:
        return l10n.trashTypeMemory;
      case DeletionEntityType.groupChat:
        return l10n.groupChatMyGroupChats;
      default:
        return type;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Parses a human-readable display name from [recoveryJson] for the given
  /// entity [type]. Returns null when parsing fails.
  String? _parseDisplayName(String recoveryJson, String type) {
    try {
      final json = jsonDecode(recoveryJson) as Map?;
      if (json == null) return null;
      final raw = switch (type) {
        DeletionEntityType.conversation =>
          (json['conversation'] as Map?)?['title'] as String? ??
              _contentPreview(json['conversation']),
        DeletionEntityType.assistant => json['name'] as String?,
        DeletionEntityType.worldBook =>
          (json['name'] as String?) ?? _contentPreview(json['content']),
        DeletionEntityType.quickPhrase =>
          (json['title'] as String?) ?? _contentPreview(json['content']),
        DeletionEntityType.mcpServer =>
          (json['name'] as String?) ?? (json['url'] as String?),
        DeletionEntityType.message => _contentPreview(
          (json['message'] as Map?)?['content'],
        ),
        DeletionEntityType.memory => _contentPreview(json['content']),
        _ => null,
      };
      if (raw == null || raw.isEmpty) return null;
      return raw.length > 80 ? '${raw.substring(0, 80)}\u2026' : raw;
    } catch (_) {
      return null;
    }
  }

  /// Returns the first ~50 characters of [content] as a plain-text preview,
  /// stripping markdown markers.
  String? _contentPreview(Object? content) {
    if (content == null) return null;
    final s = content.toString().trim();
    if (s.isEmpty) return null;
    final clean = s
        .replaceAll(RegExp(r'^[#*>\-\d\.]+\s*'), '')
        .replaceAll(RegExp(r'\*\*|__|~~'), '')
        .trim();
    return clean.length > 50 ? '${clean.substring(0, 50)}\u2026' : clean;
  }

  Future<void> _restoreEntity(String id, String type) async {
    final coordinator = context.read<TrashRestoreCoordinator>();
    final l10n = AppLocalizations.of(context)!;
    final error = await coordinator.restoreEntity(id, type);
    if (!mounted) return;
    if (error != null) {
      showAppSnackBar(context, message: error);
    } else {
      showAppSnackBar(context, message: l10n.trashRestoreButton);
      await _loadData();
    }
  }

  Future<void> _purgeRecord(String id, String type) async {
    final store = context.read<ChatService>().deletedRecordsStore;
    if (store == null) return;
    await store.purgeDeletedRecord(id, type);
    await _loadData();
  }

  Future<void> _clearAllLocal() async {
    final store = context.read<ChatService>().deletedRecordsStore;
    if (store == null) return;
    await store.clearAllDeletedRecords();
    await _loadData();
  }

  /// Deletes a conflicting entity locally (user chose to honor the deletion).
  Future<void> _deleteConflictLocally(DeletionMarkerRow marker) async {
    final coordinator = context.read<TrashRestoreCoordinator>();
    final store = context.read<ChatService>().deletedRecordsStore;
    await coordinator.deleteLocally(marker.id, marker.type);
    if (store != null) {
      await _purgeMarker(store, marker);
    }
    await _loadData();
  }

  /// Keeps a conflicting entity (user chose to ignore the deletion marker).
  Future<void> _keepConflict(DeletionMarkerRow marker) async {
    final store = context.read<ChatService>().deletedRecordsStore;
    if (store == null) return;
    await _purgeMarker(store, marker);
    await _loadData();
  }

  /// Removes a marker regardless of origin.
  Future<void> _purgeMarker(
    DeletedRecordsStore store,
    DeletionMarkerRow marker,
  ) async {
    if (marker.origin == DeletionOrigin.remote) {
      await store.purgeRemoteMarker(marker.id, marker.type);
    } else {
      await store.purgeLocalMarker(marker.id, marker.type);
    }
  }

  /// Keeps all pending conflicts (remove all markers, keep all entities).
  Future<void> _keepAllConflicts() async {
    final store = context.read<ChatService>().deletedRecordsStore;
    if (store == null) return;
    for (final m in _conflicts) {
      await _purgeMarker(store, m);
    }
    await _loadData();
  }

  Future<void> _setCap(int mb) async {
    final settings = context.read<SettingsProvider>();
    final store = context.read<ChatService>().deletedRecordsStore;
    await settings.setTrashCapMb(mb);
    if (store != null) {
      await store.setCapMb(mb);
    }
    await _loadData();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();

    final tabs = [
      Tab(text: '${l10n.trashSectionLocalTab} ($_localCount)'),
      Tab(text: '${l10n.trashSectionPendingTab} ($_pendingCount)'),
      Tab(text: l10n.trashWorkspaceMarksTab),
    ];

    final tabBarView = Expanded(
      child: TabBarView(
        controller: _tabController,
        children: [
          _buildLocalTab(cs, l10n, settings),
          _buildPendingTab(cs, l10n),
          _buildFileMarksTab(cs, l10n),
        ],
      ),
    );

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (widget.embedded) {
      // Desktop: embedded in StorageSpacePage right panel, no Scaffold/AppBar.
      return Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Column(
          children: [
            TabBar(controller: _tabController, tabs: tabs),
            tabBarView,
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.storageSpaceCategoryDeletedRecords),
        bottom: TabBar(controller: _tabController, tabs: tabs),
      ),
      body: Column(children: [tabBarView]),
    );
  }

  Widget _buildFileMarksTab(ColorScheme cs, AppLocalizations l10n) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Row(
            children: [
              Icon(
                Lucide.info,
                size: 14,
                color: cs.onSurface.withValues(alpha: 0.45),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.trashWorkspaceMarksNotRecoverable,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _fileMarks.isEmpty
              ? Center(
                  child: Text(
                    l10n.trashWorkspaceMarksEmpty,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _fileMarks.length,
                  itemBuilder: (ctx, i) {
                    final m = _fileMarks[i];
                    return ListTile(
                      leading: Icon(
                        Lucide.FileText,
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                      title: Text(
                        m.id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      subtitle: Text(
                        '${m.origin == DeletionOrigin.local ? l10n.trashConflictOriginLocal : l10n.trashConflictOriginRemote} \u00b7 ${m.deletedAt.toLocal().toString().substring(0, 19)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                      trailing: _FileMarkActions(
                        marker: m,
                        resolveHost: (id) => _resolveWorkspaceHostPath(id),
                        onDeleteLocally: () => _deleteWorkspaceFileLocally(m),
                        onClearRecord: () => _clearFileMark(m),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Resolves a workspaceFile wire path to a host path, or null when the
  /// path is outside the local @workspaces tree (unknown mount alias, or
  /// unsafe segments — `..`, Win32 trailing-dot/space forms and dot-prefixed
  /// segments rejected per segment, same rule as the wire resolver and the
  /// marker plane).
  Future<String?> _resolveWorkspaceHostPath(String wirePath) async {
    if (!wirePath.startsWith('@workspaces/')) return null;
    final rel = wirePath.substring('@workspaces/'.length);
    if (rel.isEmpty) return null;
    final segments = rel.split(RegExp(r'[\\/]'));
    if (segments.any((s) => s.startsWith('.') || !isSafeWireSegment(s))) {
      return null;
    }
    final ws = await AppDirectories.getWorkspacesDirectory();
    return p.join(ws.path, segments.join(p.separator));
  }

  Future<int> _countFiles(String dirPath) async {
    var count = 0;
    try {
      // followLinks: false — symlinks are never followed in scans.
      await for (final ent in Directory(
        dirPath,
      ).list(recursive: true, followLinks: false)) {
        if (ent is File) count++;
      }
    } catch (_) {}
    return count;
  }

  /// One-click local delete for a remote workspaceFile mark: physical
  /// delete + origin='local' marker (so further peers learn) + remote row
  /// removal (done inside [DeletedRecordsStore.recordFileDeletion]).
  /// Advisory — never auto-deletes (ADR-0021).
  ///
  /// Directory marks (a recursive delete elsewhere) apply as a
  /// user-confirmed recursive local delete; the confirm dialog shows the
  /// local file count because the directory may contain files that never
  /// existed on the source device.
  Future<void> _deleteWorkspaceFileLocally(DeletionMarkerRow m) async {
    final l10n = AppLocalizations.of(context)!;
    final store = context.read<ChatService>().deletedRecordsStore;
    if (store == null) return;
    final host = await _resolveWorkspaceHostPath(m.id);
    if (host == null) {
      await _clearFileMark(m);
      return;
    }
    final isDir = await Directory(host).exists();
    if (isDir) {
      final count = await _countFiles(host);
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.trashWorkspaceMarksDeleteLocal),
          content: Text(l10n.trashWorkspaceMarksDeleteDirConfirm(count, m.id)),
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
      if (ok != true || !mounted) return;
    }
    try {
      if (isDir) {
        await Directory(host).delete(recursive: true);
      } else {
        final f = File(host);
        if (await f.exists()) await f.delete();
      }
      await store.recordFileDeletion(id: m.id, deletedAt: DateTime.now());
      await _loadData();
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.trashWorkspaceMarksDeleteLocal,
        type: NotificationType.success,
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: e.toString(),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _clearFileMark(DeletionMarkerRow m) async {
    final store = context.read<ChatService>().deletedRecordsStore;
    if (store == null) return;
    if (m.origin == DeletionOrigin.local) {
      await store.purgeLocalMarker(m.id, DeletionEntityType.workspaceFile);
    } else {
      await store.purgeRemoteMarker(m.id, DeletionEntityType.workspaceFile);
    }
    await _loadData();
  }

  Widget _buildLocalTab(
    ColorScheme cs,
    AppLocalizations l10n,
    SettingsProvider settings,
  ) {
    return Column(
      children: [
        // Cap setting row (matches ExpansionSettingTile pattern).
        ExpansionSettingTile(
          tileBg: cs.onSurface.withValues(alpha: 0.04),
          border: cs.onSurface.withValues(alpha: 0.08),
          title: l10n.trashCapLabel,
          subtitle: l10n.trashCapSubtitle,
          value: settings.trashCapMb == 0
              ? l10n.trashCapUnlimited
              : '${settings.trashCapMb} MB',
          options: _trashCapOptions
              .map((mb) => mb == 0 ? l10n.trashCapUnlimited : '$mb MB')
              .toList(),
          selectedIndex: _trashCapOptions
              .indexOf(settings.trashCapMb)
              .clamp(0, _trashCapOptions.length - 1),
          onSelected: (i) => _setCap(_trashCapOptions[i]),
        ),
        const Divider(height: 1),
        // Trash list.
        Expanded(
          child: _localTrash.isEmpty
              ? Center(
                  child: Text(
                    l10n.trashEmptyState,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _localTrash.length,
                  itemBuilder: (ctx, i) {
                    final row = _localTrash[i];
                    return _TrashListTile(
                      displayName: _parseDisplayName(
                        row.recoveryJson,
                        row.type,
                      ),
                      typeLabel: _typeLabel(row.type, l10n),
                      size: row.size,
                      createdAt: row.createdAt,
                      formatBytes: _formatBytes,
                      onRestore: () => _restoreEntity(row.id, row.type),
                      onPurge: () => _purgeRecord(row.id, row.type),
                      l10n: l10n,
                    );
                  },
                ),
        ),
        // Clear all button.
        if (_localTrash.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: IosCardPress(
                onTap: _clearAllLocal,
                baseColor: cs.errorContainer.withValues(alpha: 0.3),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    l10n.trashClearAllButton,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: cs.error),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPendingTab(ColorScheme cs, AppLocalizations l10n) {
    final coordinator = context.read<TrashRestoreCoordinator>();
    return Column(
      children: [
        Expanded(
          child: _conflicts.isEmpty
              ? Center(
                  child: Text(
                    l10n.trashConflictEmptyState,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _conflicts.length,
                  itemBuilder: (ctx, i) {
                    final m = _conflicts[i];
                    return ListTile(
                      leading: Icon(
                        Lucide.TriangleAlert,
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                      title: FutureBuilder<String?>(
                        future: coordinator.getLiveDisplayName(m.id, m.type),
                        builder: (ctx, snap) {
                          final name = snap.data ?? _typeLabel(m.type, l10n);
                          return Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          );
                        },
                      ),
                      subtitle: Text(
                        '${m.origin == DeletionOrigin.local ? l10n.trashConflictOriginLocal : l10n.trashConflictOriginRemote} \u00b7 ${m.deletedAt.toLocal().toString().substring(0, 19)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => _deleteConflictLocally(m),
                            style: TextButton.styleFrom(
                              foregroundColor: cs.error,
                            ),
                            child: Text(l10n.trashRemoteDeleteLocally),
                          ),
                          const SizedBox(width: 4),
                          TextButton(
                            onPressed: () => _keepConflict(m),
                            child: Text(l10n.trashConflictKeepButton),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        if (_conflicts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: IosCardPress(
                onTap: _keepAllConflicts,
                baseColor: cs.onSurface.withValues(alpha: 0.04),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    l10n.trashConflictKeepAllButton,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _FileMarkActions extends StatefulWidget {
  const _FileMarkActions({
    required this.marker,
    required this.resolveHost,
    required this.onDeleteLocally,
    required this.onClearRecord,
  });

  final DeletionMarkerRow marker;
  final Future<String?> Function(String wirePath) resolveHost;
  final Future<void> Function() onDeleteLocally;
  final Future<void> Function() onClearRecord;

  @override
  State<_FileMarkActions> createState() => _FileMarkActionsState();
}

class _FileMarkActionsState extends State<_FileMarkActions> {
  bool? _exists;

  @override
  void initState() {
    super.initState();
    _checkExists();
  }

  Future<void> _checkExists() async {
    final host = await widget.resolveHost(widget.marker.id);
    if (!mounted) return;
    final exists =
        host != null &&
        (await File(host).exists() || await Directory(host).exists());
    setState(() => _exists = exists);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final isRemote = widget.marker.origin == DeletionOrigin.remote;
    final canDeleteLocally = isRemote && _exists == true;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canDeleteLocally) ...[
          TextButton(
            onPressed: widget.onDeleteLocally,
            style: TextButton.styleFrom(foregroundColor: cs.error),
            child: Text(l10n.trashWorkspaceMarksDeleteLocal),
          ),
          const SizedBox(width: 4),
        ],
        TextButton(
          onPressed: widget.onClearRecord,
          child: Text(l10n.trashWorkspaceMarksClearRecord),
        ),
      ],
    );
  }
}

class _TrashListTile extends StatelessWidget {
  const _TrashListTile({
    required this.displayName,
    required this.typeLabel,
    required this.size,
    required this.createdAt,
    required this.formatBytes,
    required this.onRestore,
    required this.onPurge,
    required this.l10n,
  });

  final String? displayName;
  final String typeLabel;
  final int size;
  final DateTime createdAt;
  final String Function(int) formatBytes;
  final Future<void> Function() onRestore;
  final Future<void> Function() onPurge;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Lucide.Trash2, color: cs.onSurface.withValues(alpha: 0.5)),
      title: Text(
        displayName ?? typeLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '$typeLabel \u00b7 ${formatBytes(size)} \u00b7 ${createdAt.toLocal().toString().substring(0, 19)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: cs.onSurface.withValues(alpha: 0.5),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: onRestore,
            child: Text(l10n.trashRestoreButton),
          ),
          TextButton(
            onPressed: onPurge,
            style: TextButton.styleFrom(foregroundColor: cs.error),
            child: Text(l10n.trashPurgeButton),
          ),
        ],
      ),
    );
  }
}
