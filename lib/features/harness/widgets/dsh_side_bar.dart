import 'dart:async';

import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/action_sheet.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../pages/home/harness_home_models.dart';
import '../pages/home/harness_surface_entries.dart';
import '../services/dsh_surface_harvest.dart';
import '../pages/home/harness_session_catalog.dart';
import 'dsh_whale_mark.dart';

/// Stable ids of the DSH built-in entry rows.
///
/// These three are the only ids Cuplivo itself names, because the built-ins are
/// the rows R5 renders before the official-WebUI harvest has reported anything.
/// A harvested row's id is derived from its label (see [dshSurfaceEntryId]).
abstract final class DshSidebarEntryIds {
  static const String plugins = 'plugins';
  static const String automations = 'automations';
  static const String more = 'more';
}

/// One row of R5's entry list above the workspace sections.
///
/// The list is data, not a widget tree: with a harvest snapshot the rows are the
/// official sidebar labels in official order; before one arrives they are the
/// three localized DSH built-ins. [isHarvested] decides only where a tap lands
/// (the official WebUI landed on the row's own label vs. a built-in surface),
/// never whether the row renders.
@immutable
class DshSidebarEntrySpec {
  const DshSidebarEntrySpec({
    required this.id,
    required this.label,
    required this.icon,
    this.isHarvested = false,
  });

  /// Stable id; also the `dsh-sidebar-entry-<id>` key suffix.
  final String id;

  /// Localized label for built-ins, the remote's own label for harvested rows.
  final String label;

  final IconData icon;

  /// True for rows read from the official WebUI's sidebar.
  final bool isHarvested;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshSidebarEntrySpec &&
          other.id == id &&
          other.label == label &&
          other.icon == icon &&
          other.isHarvested == isHarvested;

  @override
  int get hashCode => Object.hash(id, label, icon, isHarvested);
}

/// The DeepSeek Harness sidebar body (R5).
///
/// The existing drawer keeps its shared chrome in remote mode — the search
/// field, the history/close action and the bottom user bar — and this widget is
/// everything between them: the remote owner row, the official entry rows (the
/// harvest snapshot once a remote page has been opened, the DSH built-ins
/// before that), workspace sections with their session rows and the `新会话`
/// row. That grouping is why the remote list is its own widget instead of
/// another pinned/date mode inside the local conversation list.
///
/// The drawer passes the shared search field's [query] in; a non-empty query
/// filters session titles locally and hides workspaces with no match.
class DshSideBar extends StatefulWidget {
  const DshSideBar({
    super.key,
    required this.remoteName,
    required this.catalog,
    required this.selectedSessionId,
    required this.onSelectSession,
    required this.onNewSession,
    required this.onOpenEntry,
    this.harvestedEntries = const <DshSurfaceEntry>[],
    this.query = '',
  });

  /// The remote's display name (the owner row label).
  final String remoteName;

  /// Live session/workspace catalog. This widget listens to it; the caller owns
  /// its lifetime.
  final HarnessSessionCatalog catalog;

  /// The session currently open, highlighted in the list.
  final String? selectedSessionId;

  final ValueChanged<HarnessSessionSummary> onSelectSession;

  /// Creates a session, in [workspaceId] when the row belongs to one.
  final Future<void> Function({String? workspaceId}) onNewSession;

  /// Opens the surface one entry row stands for.
  ///
  /// Every row is an official-WebUI page: a harvested row lands on its own
  /// label, the built-in 更多 row lands on DSH's `PanelMoreMenu`, and the
  /// pre-harvest 插件 / 自动化任务 built-ins open the WebUI root.
  final ValueChanged<DshSidebarEntrySpec> onOpenEntry;

  /// The official sidebar entries the harvest read for this remote, in the
  /// official order (e.g. 插件 / 搜索服务 / 自动化任务).
  ///
  /// 更多 is not part of the official panel list (it is DSH's own
  /// `PanelMoreMenu`), so Cuplivo always keeps exactly one built-in 更多 row
  /// after the harvested rows. Empty until a remote page has been opened once,
  /// so the section renders only the 插件 / 自动化任务 / 更多 built-ins — never a
  /// fabricated plugin row and no placeholder text.
  final List<DshSurfaceEntry> harvestedEntries;

  /// The shared search field's current text.
  final String query;

  @override
  State<DshSideBar> createState() => _DshSideBarState();
}

class _DshSideBarState extends State<DshSideBar> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.catalog,
      builder: (context, _) {
        final catalog = widget.catalog;
        final query = widget.query.trim().toLowerCase();
        final matchingGroups =
            <
              ({
                HarnessWorkspaceGroup group,
                List<HarnessSessionSummary> sessions,
              })
            >[];
        for (final group in catalog.workspaces) {
          final sessions = query.isEmpty
              ? group.sessions
              : [
                  for (final session in group.sessions)
                    if ((session.trimmedTitle ?? '').toLowerCase().contains(
                      query,
                    ))
                      session,
                ];
          if (query.isNotEmpty && sessions.isEmpty) continue;
          matchingGroups.add((group: group, sessions: sessions));
        }
        final ungrouped = query.isEmpty
            ? catalog.ungroupedSessions
            : [
                for (final session in catalog.ungroupedSessions)
                  if ((session.trimmedTitle ?? '').toLowerCase().contains(
                    query,
                  ))
                    session,
              ];
        final visibleSessions =
            matchingGroups.fold<int>(
              0,
              (sum, item) => sum + item.sessions.length,
            ) +
            ungrouped.length;
        final noSessionsVisible =
            catalog.isAvailable && visibleSessions == 0 && !catalog.isLoading;

        return ListView(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 16),
          children: [
            _ownerRow(context, l10n, cs, catalog),
            if (!_collapsed) ...[
              const SizedBox(height: 4),
              // The e2e scenario anchors on this section: the three official
              // entries and every workspace section below live inside it.
              KeyedSubtree(
                key: const Key('dsh-drawer-entries'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final entry in _entrySpecs(l10n))
                      _sidebarEntryRow(context, entry, cs),
                    const SizedBox(height: 8),
                    _WorkspaceSections(
                      catalog: catalog,
                      l10n: l10n,
                      query: query,
                      matchingGroups: matchingGroups,
                      ungrouped: ungrouped,
                      selectedSessionId: widget.selectedSessionId,
                      onSelectSession: widget.onSelectSession,
                      onNewSession: widget.onNewSession,
                    ),
                    if (catalog.isLoading && catalog.isEmpty)
                      _statusRow(
                        context,
                        l10n.dshSessionsLoading,
                        leading: true,
                      )
                    else if (!catalog.isAvailable)
                      _statusRow(
                        context,
                        l10n.dshCatalogUnavailable,
                        hint: l10n.dshCatalogUnavailableHint,
                      )
                    else if (catalog.error != null)
                      _statusRow(
                        context,
                        l10n.dshSessionsFailed,
                        action: TextButton(
                          onPressed: () => unawaited(catalog.refresh()),
                          child: Text(l10n.retry),
                        ),
                      )
                    else if (noSessionsVisible && query.isNotEmpty)
                      _statusRow(context, l10n.sideDrawerGlobalSearchNoResults)
                    else if (noSessionsVisible && ungrouped.isEmpty)
                      _newSessionRow(
                        context,
                        l10n,
                        cs,
                        workspaceId: null,
                        emphasized: true,
                        key: const Key('dsh-new-session'),
                      ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// The remote owner row: whale avatar, name and the collapse chevron.
  Widget _ownerRow(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
    HarnessSessionCatalog catalog,
  ) {
    return IosCardPress(
      borderRadius: BorderRadius.circular(16),
      baseColor: Colors.transparent,
      onTap: () => setState(() => _collapsed = !_collapsed),
      padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
      child: Row(
        children: [
          DshWhaleAvatar(size: 32),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              widget.remoteName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: AppFontWeights.medium,
                color: cs.onSurface,
              ),
            ),
          ),
          if (catalog.isLoading)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: _SidebarSpinner(),
            ),
          AnimatedRotation(
            turns: _collapsed ? 0.5 : 0.0,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            child: Icon(
              Lucide.ChevronDown,
              size: 18,
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  /// R5's entry rows: the three DSH built-ins plus whatever the harvest
  /// discovered on this remote's WebUI.
  ///
  /// Discovered rows whose label repeats a built-in are dropped: the official
  /// sidebar lists its built-ins in the same DOM region the harvest reads, so a
  /// harvested row for 插件 / 自动化任务 / 更多 would otherwise render twice.
  List<DshSidebarEntrySpec> _entrySpecs(AppLocalizations l10n) {
    // 更多 is not a panellist row, so it is never in the harvest: exactly one
    // built-in 更多 row stays at the end, in both modes. Pre-harvest the two
    // DSH plugin built-ins come first; afterwards the official rows replace
    // them and only 更多 is Cuplivo's own.
    final more = DshSidebarEntrySpec(
      id: DshSidebarEntryIds.more,
      label: l10n.dshSidebarMore,
      icon: Lucide.LayoutGrid,
    );
    final harvested = widget.harvestedEntries;
    if (harvested.isEmpty) {
      return <DshSidebarEntrySpec>[
        DshSidebarEntrySpec(
          id: DshSidebarEntryIds.plugins,
          label: l10n.dshSidebarPlugins,
          icon: Lucide.Boxes,
        ),
        DshSidebarEntrySpec(
          id: DshSidebarEntryIds.automations,
          label: l10n.dshSidebarAutomations,
          icon: Lucide.clock,
        ),
        more,
      ];
    }
    final rows = dshHarvestedEntries(
      harvested,
      // Defensive: if a future host ever lists 更多 as a row, the built-in row
      // still stays the only one.
      excludedLabels: <String>{l10n.dshSidebarMore},
    );
    return <DshSidebarEntrySpec>[
      for (final row in rows)
        DshSidebarEntrySpec(
          id: row.id,
          label: row.label,
          icon: _iconForHarvestedLabel(row.label, l10n),
          isHarvested: true,
        ),
      more,
    ];
  }

  /// Official rows keep their familiar DSH icon when the harvested label is the
  /// same localized text a built-in uses; a plugin-only row gets the generic
  /// plugin mark. The label itself is never rewritten.
  IconData _iconForHarvestedLabel(String label, AppLocalizations l10n) {
    if (label == l10n.dshSidebarPlugins) return Lucide.Boxes;
    if (label == l10n.dshSidebarAutomations) return Lucide.clock;
    if (label == l10n.dshSidebarMore) return Lucide.LayoutGrid;
    return Lucide.Box;
  }

  Widget _sidebarEntryRow(
    BuildContext context,
    DshSidebarEntrySpec entry,
    ColorScheme cs,
  ) {
    final row = _entryRow(
      context,
      cs,
      key: ValueKey<String>('dsh-sidebar-entry-${entry.id}'),
      icon: entry.icon,
      label: entry.label,
      onTap: () => widget.onOpenEntry(entry),
    );
    if (entry.isHarvested) return row;
    // The e2e scenario's pre-spec anchors stay addressable; the canonical key is
    // on the row itself, this wrapper only forwards a tap to it.
    return KeyedSubtree(key: Key('dsh-entry-${entry.id}'), child: row);
  }

  Widget _entryRow(
    BuildContext context,
    ColorScheme cs, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Key? key,
  }) {
    return IosCardPress(
      key: key,
      borderRadius: BorderRadius.circular(10),
      baseColor: Colors.transparent,
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.onSurface.withValues(alpha: 0.75)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface,
                fontWeight: AppFontWeights.regular,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _newSessionRow(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs, {
    required String? workspaceId,
    bool emphasized = false,
    Key? key,
  }) {
    return IosCardPress(
      key: key,
      borderRadius: BorderRadius.circular(10),
      baseColor: emphasized
          ? cs.primary.withValues(alpha: 0.10)
          : Colors.transparent,
      onTap: () => unawaited(widget.onNewSession(workspaceId: workspaceId)),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Icon(Lucide.MessageCirclePlus, size: 18, color: cs.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l10n.dshNewSession,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: cs.primary,
                fontWeight: AppFontWeights.medium,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusRow(
    BuildContext context,
    String message, {
    String? hint,
    Widget? action,
    bool leading = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          if (leading) ...[const _SidebarSpinner(), const SizedBox(width: 10)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.7),
                  ),
                ),
                if (hint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      hint,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.35,
                        color: cs.onSurface.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (action != null) action,
        ],
      ),
    );
  }
}

/// Workspace sections + their session rows + each section's `新会话` row.
class _WorkspaceSections extends StatelessWidget {
  const _WorkspaceSections({
    required this.catalog,
    required this.l10n,
    required this.query,
    required this.matchingGroups,
    required this.ungrouped,
    required this.selectedSessionId,
    required this.onSelectSession,
    required this.onNewSession,
  });

  final HarnessSessionCatalog catalog;
  final AppLocalizations l10n;
  final String query;
  final List<
    ({HarnessWorkspaceGroup group, List<HarnessSessionSummary> sessions})
  >
  matchingGroups;
  final List<HarnessSessionSummary> ungrouped;
  final String? selectedSessionId;
  final ValueChanged<HarnessSessionSummary> onSelectSession;
  final Future<void> Function({String? workspaceId}) onNewSession;

  @override
  Widget build(BuildContext context) {
    if (matchingGroups.isEmpty && ungrouped.isEmpty) {
      return const SizedBox.shrink();
    }
    // The e2e scenario addresses `dsh-session-row` / `dsh-new-session`; only the
    // first row of each kind carries the exact key so no two siblings share a
    // LocalKey (Flutter debug-asserts duplicate keys among siblings).
    var sessionKeyAssigned = false;
    var newSessionKeyAssigned = false;
    final children = <Widget>[];
    for (final entry in matchingGroups) {
      final group = entry.group;
      children.add(
        _workspaceHeader(
          context,
          group.displayTitle.isEmpty
              ? l10n.dshDefaultWorkspace
              : group.displayTitle,
        ),
      );
      for (final session in entry.sessions) {
        children.add(
          _sessionRow(
            session,
            workspaceId: group.workspaceId,
            key: sessionKeyAssigned ? null : const Key('dsh-session-row'),
          ),
        );
        sessionKeyAssigned = true;
      }
      children.add(
        _newSessionRow(
          context,
          workspaceId: group.workspaceId,
          key: newSessionKeyAssigned ? null : const Key('dsh-new-session'),
        ),
      );
      newSessionKeyAssigned = true;
    }
    if (ungrouped.isNotEmpty) {
      children.add(_workspaceHeader(context, l10n.dshDefaultWorkspace));
      for (final session in ungrouped) {
        children.add(
          _sessionRow(
            session,
            workspaceId: null,
            key: sessionKeyAssigned ? null : const Key('dsh-session-row'),
          ),
        );
        sessionKeyAssigned = true;
      }
      children.add(
        _newSessionRow(
          context,
          workspaceId: null,
          key: newSessionKeyAssigned ? null : const Key('dsh-new-session'),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _workspaceHeader(BuildContext context, String title) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Icon(
            Lucide.Folder,
            size: 15,
            color: cs.onSurface.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: AppFontWeights.medium,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sessionRow(
    HarnessSessionSummary session, {
    required String? workspaceId,
    Key? key,
  }) {
    final selected = session.sessionId == selectedSessionId;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: _DshSessionRow(
        key: key,
        session: session,
        workspaceId: workspaceId,
        selected: selected,
        label: session.trimmedTitle ?? l10n.dshNewSession,
        onTap: () => onSelectSession(session),
        catalog: catalog,
        onNewSession: onNewSession,
      ),
    );
  }

  Widget _newSessionRow(
    BuildContext context, {
    required String? workspaceId,
    Key? key,
  }) {
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      key: key,
      borderRadius: BorderRadius.circular(10),
      baseColor: Colors.transparent,
      onTap: () => unawaited(onNewSession(workspaceId: workspaceId)),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Icon(Lucide.MessageCirclePlus, size: 18, color: cs.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l10n.dshNewSession,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: cs.primary,
                fontWeight: AppFontWeights.medium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One session row with the selected-row treatment and its capability-gated
/// action menu (rename/pin/archive/fork/delete only when the Host serves them).
class _DshSessionRow extends StatelessWidget {
  const _DshSessionRow({
    super.key,
    required this.session,
    required this.workspaceId,
    required this.selected,
    required this.label,
    required this.onTap,
    required this.catalog,
    required this.onNewSession,
  });

  final HarnessSessionSummary session;
  final String? workspaceId;
  final bool selected;
  final String label;
  final VoidCallback onTap;
  final HarnessSessionCatalog catalog;
  final Future<void> Function({String? workspaceId}) onNewSession;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final caps = catalog.capabilities;
    final hasMenu = caps.hasAnySessionAction;
    final row = IosCardPress(
      baseColor: selected
          ? cs.primary.withValues(alpha: 0.14)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      onLongPress: hasMenu ? () => _showMenu(context) : null,
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected
                    ? AppFontWeights.medium
                    : AppFontWeights.regular,
                color: cs.onSurface,
              ),
            ),
          ),
          if (session.running) ...[
            const SizedBox(width: 8),
            const _SidebarSpinner(size: 12),
          ],
          if (session.pinned) ...[
            const SizedBox(width: 8),
            Icon(
              Lucide.Pin,
              size: 13,
              color: cs.onSurface.withValues(alpha: 0.45),
            ),
          ],
          if (hasMenu)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(
                Lucide.Ellipsis,
                size: 16,
                color: cs.onSurface.withValues(alpha: 0.45),
              ),
            ),
        ],
      ),
    );
    if (!hasMenu) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (details) =>
          _showMenu(context, anchor: details.globalPosition),
      child: row,
    );
  }

  Future<void> _showMenu(BuildContext context, {Offset? anchor}) async {
    final l10n = AppLocalizations.of(context)!;
    final caps = catalog.capabilities;
    final items = <ActionSheetItem>[
      if (caps.rename)
        ActionSheetItem(
          icon: Lucide.Edit,
          label: l10n.sideDrawerMenuRename,
          onTap: () => unawaited(_rename(context)),
        ),
      if (caps.pin)
        ActionSheetItem(
          icon: session.pinned ? Lucide.PinOff : Lucide.Pin,
          label: session.pinned
              ? l10n.sideDrawerMenuUnpin
              : l10n.sideDrawerMenuPin,
          onTap: () => unawaited(
            _run(
              context,
              () => catalog.setPinned(session.sessionId, !session.pinned),
            ),
          ),
        ),
      if (caps.fork)
        ActionSheetItem(
          icon: Lucide.GitFork,
          label: l10n.dshSessionFork,
          onTap: () => unawaited(_fork(context)),
        ),
      if (caps.archive)
        ActionSheetItem(
          icon: Lucide.FileArchive,
          label: l10n.dshSessionArchive,
          onTap: () => unawaited(
            _run(
              context,
              () => catalog.archiveSession(session.sessionId),
              success: l10n.dshSessionArchived,
            ),
          ),
        ),
      if (caps.delete)
        ActionSheetItem(
          icon: Lucide.X,
          label: l10n.sideDrawerMenuDelete,
          destructive: true,
          onTap: () => unawaited(
            _run(
              context,
              () => catalog.deleteSession(session.sessionId),
              success: l10n.dshSessionDeleted,
            ),
          ),
        ),
    ];
    if (items.isEmpty) return;
    await showAdaptiveActionMenu(
      context,
      anchor: anchor,
      title: label,
      items: items,
    );
  }

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: session.trimmedTitle ?? '');
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.dshSessionRenameTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n.sideDrawerRenameHint),
          onSubmitted: (_) => Navigator.of(ctx).pop(true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.sideDrawerCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.sideDrawerOK),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final title = controller.text.trim();
    if (title.isEmpty) return;
    if (!context.mounted) return;
    await _run(context, () => catalog.renameSession(session.sessionId, title));
  }

  Future<void> _fork(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await catalog.forkSession(session.sessionId);
    } on HarnessCatalogException catch (error) {
      if (!context.mounted) return;
      _failed(context, l10n, error);
    }
  }

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action, {
    String? success,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await action();
      if (success != null && context.mounted) {
        showAppSnackBar(
          context,
          message: success,
          type: NotificationType.success,
        );
      }
    } on HarnessCatalogException catch (error) {
      if (!context.mounted) return;
      _failed(context, l10n, error);
    }
  }

  void _failed(
    BuildContext context,
    AppLocalizations l10n,
    HarnessCatalogException error,
  ) {
    showAppSnackBar(
      context,
      message: error.userMessage ?? l10n.dshOperationFailed,
      type: NotificationType.error,
    );
  }
}

class _SidebarSpinner extends StatelessWidget {
  const _SidebarSpinner({this.size = 14});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        strokeWidth: 1.6,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
      ),
    );
  }
}
