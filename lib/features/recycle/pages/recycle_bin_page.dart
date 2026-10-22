import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/database/startup_failure_report.dart' show formatBytes;
import '../../../core/services/recycle/recycle_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_settings_rows.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/segmented_tabs.dart';
import '../../../theme/app_font_weights.dart';
import '../recycle_actions.dart';
import 'recycle_entry_detail_page.dart';

/// The device-local recycle bin, as a list.
///
/// It shows what a deletion removed and what a losing last-write-wins
/// comparison replaced, and it is the only place those rows are written back:
/// every restore goes through [RecycleService], so the clock and the path rules
/// stay in one implementation. Nothing here is shared state — the bin is this
/// device's alone, which is why the page has no sync affordance at all.
enum _BinFilter { all, conversations, assistants, settings, files }

/// One group header, emitted where a deletion event's entries begin.
class _BinGroup {
  const _BinGroup(this.group, this.count);

  final RecycleGroup group;

  /// How many of this group's entries the current filter still shows, so the
  /// header shrinks as its entries are restored.
  final int count;
}

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
  bool _groupBusy = false;

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
    List<RecycleEntry> entries;
    try {
      // Retention and the size caps are enforced when the user looks, not only
      // when something is staged: an install that stops deleting still shrinks.
      await service.evict();
      entries = await service.list();
    } catch (error) {
      // The bin is a folder on disk, and a folder can be unreadable — a
      // permission change, a full disk, a root that is no longer a directory.
      // Falling through to the empty state leaves the page usable and navigable;
      // letting the throw escape would strand it on a spinner nothing resolves.
      debugPrint('recycle: reading the bin failed: $error');
      if (mounted) setState(() => _loading = false);
      return;
    }
    // Summed from the entries the list just read, rather than asking for a
    // second scan of the whole bin for the same numbers.
    final bytes = entries.fold<int>(0, (sum, entry) => sum + entry.sizeBytes);
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
    setState(() => _busy.add(entry.id));
    try {
      await restoreRecycleEntry(context, service: service, entry: entry);
    } finally {
      if (mounted) setState(() => _busy.remove(entry.id));
    }
    await _load();
  }

  /// Restores every entry of one deletion event, one at a time so each keeps its
  /// own refusal (`skippedExisting`, a damaged copy) instead of a batch that can
  /// only report "some of it worked".
  Future<void> _restoreGroup(RecycleGroup group) async {
    final service = _service;
    if (service == null || _groupBusy) return;
    final entries = _entries
        .where((entry) => entry.group?.id == group.id)
        .toList(growable: false);
    if (entries.isEmpty) return;
    setState(() => _groupBusy = true);
    try {
      // One report for the act, not one toast per entry: the batch owns both the
      // refresh and the message.
      await restoreRecycleGroup(context, service: service, entries: entries);
    } finally {
      if (mounted) setState(() => _groupBusy = false);
    }
    if (!mounted) return;
    await _load();
  }

  Future<void> _purge(RecycleEntry entry) async {
    final service = _service;
    if (service == null || _busy.contains(entry.id)) return;
    if (!await purgeRecycleEntry(context, service: service, entry: entry)) {
      return;
    }
    await _load();
  }

  Future<void> _clearAll() async {
    final service = _service;
    if (service == null || _busy.isNotEmpty) return;
    if (!await clearRecycleBin(context, service: service)) return;
    await _load();
  }

  Future<void> _openDetail(RecycleEntry entry) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => RecycleEntryDetailPage(entry: entry)),
    );
    // The detail page can restore or purge the entry it shows.
    if (mounted) await _load();
  }

  List<RecycleEntry> get _visibleEntries => switch (_filter) {
    _BinFilter.all => _entries,
    _BinFilter.conversations => [
      for (final entry in _entries)
        if (entry.type == RecycleEntryType.conversation) entry,
    ],
    _BinFilter.assistants => [
      for (final entry in _entries)
        if (entry.type == RecycleEntryType.businessEntity &&
            entry.kindWire == 'assistant_rows')
          entry,
    ],
    _BinFilter.settings => [
      for (final entry in _entries)
        if (entry.type == RecycleEntryType.preference ||
            (entry.type == RecycleEntryType.businessEntity &&
                entry.kindWire != 'assistant_rows'))
          entry,
    ],
    _BinFilter.files => [
      for (final entry in _entries)
        if (entry.type == RecycleEntryType.workspaceFile) entry,
    ],
  };

  /// Entries with a day header in front of the first entry of each day, and one
  /// group header in front of the first entry of each deletion event.
  ///
  /// A group is an assistant's cascade: the assistant's own row and the
  /// conversations it took. The header names the assistant and counts the
  /// *conversations*, so it reads the same in every tab, and it is drawn only
  /// where a conversation is visible — the Assistants tab shows the assistant as
  /// a card of its own rather than under a header that talks about the
  /// conversations that tab filters out.
  List<Object> get _rows {
    final visible = _visibleEntries;
    final counts = <String, int>{};
    final headed = <String>{};
    for (final entry in _entries) {
      final group = entry.group;
      if (group == null) continue;
      if (entry.type == RecycleEntryType.conversation) {
        counts[group.id] = (counts[group.id] ?? 0) + 1;
      }
    }
    for (final entry in visible) {
      final group = entry.group;
      if (group != null && entry.type == RecycleEntryType.conversation) {
        headed.add(group.id);
      }
    }
    final rows = <Object>[];
    DateTime? day;
    String? openGroup;
    for (final entry in visible) {
      final local = entry.deletedAt.toLocal();
      final start = DateTime(local.year, local.month, local.day);
      if (day != start) {
        day = start;
        rows.add(start);
        openGroup = null;
      }
      final group = entry.group;
      if (group == null) {
        openGroup = null;
      } else if (group.id != openGroup) {
        openGroup = group.id;
        if (headed.contains(group.id)) {
          rows.add(_BinGroup(group, counts[group.id] ?? 1));
        }
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
          // The retention and cap rules live behind this button, not in the
          // footer: the footer scrolls away, this does not.
          IosIconButton(
            icon: Lucide.BadgeInfo,
            size: 18,
            minSize: 44,
            color: cs.onSurface.withValues(alpha: 0.55),
            tooltip: l10n.recycleBinInfoTitle,
            semanticLabel: l10n.recycleBinInfoTitle,
            onTap: () => showRecycleBinInfoDialog(context),
          ),
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
          : _list(rows, l10n),
    );
  }

  /// The list, centred and capped the way the storage page it is opened from
  /// is: at a desktop window width an uncapped row puts its two actions a
  /// metre away from the text they act on.
  Widget _list(List<Object> rows, AppLocalizations l10n) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          itemCount: rows.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) return _filterHeader(l10n);
            final row = rows[index - 1];
            if (row is DateTime) {
              return IosSectionHeader(text: _dayFormat.format(row));
            }
            if (row is _BinGroup) return _groupHeader(row, l10n);
            return _entryCard(row as RecycleEntry, l10n);
          },
        ),
      ),
    );
  }

  Widget _filterHeader(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedTabs(
            tabs: [
              SegmentedTab(label: l10n.recycleBinFilterAll),
              SegmentedTab(label: l10n.recycleBinFilterConversation),
              SegmentedTab(label: l10n.recycleBinFilterAssistants),
              SegmentedTab(label: l10n.recycleBinFilterSettings),
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
              '${formatBytes(_bytes)}',
        ),
      ],
    );
  }

  Widget _groupHeader(_BinGroup row, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 4, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.recycleBinGroupHeader(row.count, row.group.label),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.3,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
          TextButton(
            onPressed: _groupBusy ? null : () => _restoreGroup(row.group),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              l10n.recycleBinRestoreGroup,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
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
            onTap: busy ? null : () => _openDetail(entry),
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
