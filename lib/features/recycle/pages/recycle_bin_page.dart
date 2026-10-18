import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/database/startup_failure_report.dart' show formatBytes;
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/recycle/recycle_service.dart';
import '../../../core/services/sync/business_state_reloader.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_settings_rows.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/segmented_tabs.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';

/// The device-local recycle bin, as a list.
///
/// It shows what a deletion removed and what a losing last-write-wins
/// comparison replaced, and it is the only place those rows are written back:
/// every restore goes through [RecycleService], so the clock and the path rules
/// stay in one implementation. Nothing here is shared state — the bin is this
/// device's alone, which is why the page has no sync affordance at all.
enum _BinFilter { all, conversations, rows, files }

class RecycleBinPage extends StatefulWidget {
  const RecycleBinPage({super.key});

  @override
  State<RecycleBinPage> createState() => _RecycleBinPageState();
}

class _RecycleBinPageState extends State<RecycleBinPage> {
  static final DateFormat _dayFormat = DateFormat('yyyy-MM-dd');
  static final DateFormat _timeFormat = DateFormat('HH:mm');

  List<RecycleEntry> _entries = const <RecycleEntry>[];
  int _bytes = 0;
  bool _loading = true;
  _BinFilter _filter = _BinFilter.all;
  final Set<String> _busy = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  /// Null when the page is shown outside the app's provider tree.
  RecycleService? get _service {
    try {
      return context.read<RecycleService>();
    } catch (_) {
      return null;
    }
  }

  Future<void> _load() async {
    final service = _service;
    if (service == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    // Retention and the size caps are enforced when the user looks, not only
    // when something is staged: an install that stops deleting still shrinks.
    await service.evict();
    final entries = await service.list();
    final bytes = await service.totalBytes();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _bytes = bytes;
      _loading = false;
    });
  }

  Future<void> _restore(RecycleEntry entry) async {
    final service = _service;
    if (service == null || _busy.contains(entry.id)) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy.add(entry.id));
    RecycleRestoreOutcome outcome;
    try {
      outcome = await service.restore(entry);
    } finally {
      if (mounted) setState(() => _busy.remove(entry.id));
    }
    if (!mounted) return;
    if (outcome == RecycleRestoreOutcome.restored) {
      await _refreshAfterRestore(entry);
      if (!mounted) return;
    }
    showAppSnackBar(
      context,
      message: _outcomeMessage(outcome, l10n),
      type: outcome == RecycleRestoreOutcome.restored
          ? NotificationType.success
          : NotificationType.warning,
    );
    await _load();
  }

  /// Makes the restored rows visible without a restart: chat state for a
  /// conversation, the business view for a row or a preference. Both seams
  /// already exist for the sync apply, which has the same problem.
  Future<void> _refreshAfterRestore(RecycleEntry entry) async {
    try {
      switch (entry.type) {
        case RecycleEntryType.conversation:
          final chat = _maybe<ChatService>();
          if (chat == null) return;
          await chat.reloadAfterExternalChange(
            touchedConversations: <String>{entry.key},
          );
        case RecycleEntryType.businessEntity:
        case RecycleEntryType.preference:
          final reloader = _maybe<BusinessStateReloader>();
          if (reloader == null) return;
          await reloader.reloadAll();
        case RecycleEntryType.workspaceFile:
          break;
      }
    } catch (error) {
      // A provider that cannot reload must not make a completed restore look
      // like a failure; the rows are back and the next load picks them up.
      debugPrint('recycle: refreshing after a restore failed: $error');
    }
  }

  /// The provider of [T], or null when this page is shown outside the tree that
  /// supplies it — a missing refresh seam is not an error worth reporting.
  T? _maybe<T extends Object>() {
    try {
      return context.read<T>();
    } catch (_) {
      return null;
    }
  }

  Future<void> _purge(RecycleEntry entry) async {
    final service = _service;
    if (service == null || _busy.contains(entry.id)) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await _confirm(
      title: l10n.recycleBinDeleteForever,
      body: l10n.recycleBinDeleteForeverBody,
      confirmLabel: l10n.recycleBinDeleteForever,
      cancelLabel: l10n.recycleBinCancel,
    );
    if (!confirmed || !mounted) return;
    await service.purge(entry);
    await _load();
  }

  Future<void> _clearAll() async {
    final service = _service;
    if (service == null || _busy.isNotEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await _confirm(
      title: l10n.recycleBinClearAll,
      body: l10n.recycleBinClearAllBody,
      confirmLabel: l10n.recycleBinClearAll,
      cancelLabel: l10n.recycleBinCancel,
    );
    if (!confirmed || !mounted) return;
    await service.clear();
    await _load();
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
    required String cancelLabel,
  }) async {
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(cancelLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel, style: TextStyle(color: cs.error)),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  String _outcomeMessage(
    RecycleRestoreOutcome outcome,
    AppLocalizations l10n,
  ) => switch (outcome) {
    RecycleRestoreOutcome.restored => l10n.recycleBinRestored,
    RecycleRestoreOutcome.skippedExisting => l10n.recycleBinRestoreSkipped,
    RecycleRestoreOutcome.unreadable => l10n.recycleBinRestoreUnreadable,
    RecycleRestoreOutcome.unsupported => l10n.recycleBinRestoreUnsupported,
    RecycleRestoreOutcome.failed => l10n.recycleBinRestoreFailed,
  };

  List<RecycleEntry> get _visibleEntries => switch (_filter) {
    _BinFilter.all => _entries,
    _BinFilter.conversations => [
      for (final entry in _entries)
        if (entry.type == RecycleEntryType.conversation) entry,
    ],
    _BinFilter.rows => [
      for (final entry in _entries)
        if (entry.type == RecycleEntryType.businessEntity ||
            entry.type == RecycleEntryType.preference)
          entry,
    ],
    _BinFilter.files => [
      for (final entry in _entries)
        if (entry.type == RecycleEntryType.workspaceFile) entry,
    ],
  };

  /// Entries with a day header in front of the first entry of each day.
  List<Object> get _rows {
    final rows = <Object>[];
    DateTime? day;
    for (final entry in _visibleEntries) {
      final local = entry.deletedAt.toLocal();
      final start = DateTime(local.year, local.month, local.day);
      if (day != start) {
        day = start;
        rows.add(start);
      }
      rows.add(entry);
    }
    return rows;
  }

  IconData _iconFor(RecycleEntry entry) => switch (entry.type) {
    RecycleEntryType.conversation => Lucide.MessageSquare,
    RecycleEntryType.preference => Lucide.Settings2,
    RecycleEntryType.workspaceFile => Lucide.FileText,
    RecycleEntryType.businessEntity => switch (entry.kindWire) {
      'assistant_rows' => Lucide.Bot,
      _ => Lucide.SlidersHorizontal,
    },
  };

  String _kindLabel(RecycleEntry entry, AppLocalizations l10n) =>
      switch (entry.type) {
        RecycleEntryType.conversation => l10n.recycleBinKindConversation,
        RecycleEntryType.preference => l10n.recycleBinKindPreference,
        RecycleEntryType.workspaceFile => l10n.recycleBinKindWorkspaceFile,
        RecycleEntryType.businessEntity => switch (entry.kindWire) {
          'assistant_rows' => l10n.recycleBinKindAssistant,
          'provider_rows' ||
          'provider_group_rows' => l10n.recycleBinKindProvider,
          'world_book_rows' => l10n.recycleBinKindWorldBook,
          'assistant_memory_rows' ||
          'memory_entry_rows' => l10n.recycleBinKindMemory,
          _ => l10n.recycleBinKindConfig,
        },
      };

  /// Why the entry is here. An overwrite is always something sync did — the
  /// local side lost a comparison — so the reason wins over the origin.
  String _originLabel(RecycleEntry entry, AppLocalizations l10n) =>
      entry.reason == RecycleReason.overwritten
      ? l10n.recycleBinReasonOverwritten
      : entry.origin == RecycleOrigin.remote
      ? l10n.recycleBinOriginRemote
      : l10n.recycleBinOriginLocal;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final rows = _rows;

    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          size: 22,
          minSize: 44,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.recycleBinTitle),
        actions: [
          if (_entries.isNotEmpty)
            IosIconButton(
              icon: Lucide.Trash2,
              size: 20,
              minSize: 44,
              color: cs.error,
              tooltip: l10n.recycleBinClearAll,
              semanticLabel: l10n.recycleBinClearAll,
              onTap: _clearAll,
            ),
          const SizedBox(width: 6),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
          ? _empty(l10n)
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: rows.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) return _filterHeader(l10n);
                final row = rows[index - 1];
                if (row is DateTime) {
                  return IosSectionHeader(text: _dayFormat.format(row));
                }
                return _entryCard(row as RecycleEntry, l10n);
              },
            ),
    );
  }

  Widget _filterHeader(AppLocalizations l10n) {
    if (_entries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedTabs(
            tabs: [
              SegmentedTab(label: l10n.recycleBinFilterAll),
              SegmentedTab(label: l10n.recycleBinFilterConversation),
              SegmentedTab(label: l10n.recycleBinFilterRows),
              SegmentedTab(label: l10n.recycleBinFilterFiles),
            ],
            index: _filter.index,
            expand: false,
            onChanged: (index) =>
                setState(() => _filter = _BinFilter.values[index]),
          ),
        ),
        IosSectionFooter(
          text:
              '${_entries.length} ${l10n.recycleBinEntriesLabel} · '
              '${formatBytes(_bytes)}\n${l10n.recycleBinRetentionNote}',
        ),
      ],
    );
  }

  Widget _entryCard(RecycleEntry entry, AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    final busy = _busy.contains(entry.id);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SectionCard(
        children: [
          IosNavRow(
            icon: _iconFor(entry),
            label: entry.title.trim().isEmpty
                ? l10n.recycleBinUntitled
                : entry.title,
            subtitle:
                '${_kindLabel(entry, l10n)} · ${_originLabel(entry, l10n)}',
            caption:
                '${_timeFormat.format(entry.deletedAt.toLocal())} · '
                '${formatBytes(entry.sizeBytes)}',
            haptics: false,
            trailing: busy
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IosIconButton(
                        icon: Lucide.RotateCcw,
                        size: 18,
                        minSize: 40,
                        tooltip: l10n.recycleBinRestore,
                        semanticLabel: l10n.recycleBinRestore,
                        onTap: () => _restore(entry),
                      ),
                      IosIconButton(
                        icon: Lucide.Trash2,
                        size: 18,
                        minSize: 40,
                        color: cs.error,
                        tooltip: l10n.recycleBinDeleteForever,
                        semanticLabel: l10n.recycleBinDeleteForever,
                        onTap: () => _purge(entry),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _empty(AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 32, 32, 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Lucide.Trash2,
              size: 40,
              color: cs.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.recycleBinEmptyTitle,
              style: TextStyle(
                fontSize: 16,
                fontWeight: AppFontWeights.semibold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.recycleBinEmptyBody,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
