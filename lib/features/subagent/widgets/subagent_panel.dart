import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/message_part.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../utils/platform_utils.dart';
import '../services/subagent_coordinator.dart';
import '../services/subagent_rules.dart' show SubagentExtrasKeys;

/// Opens the list of this conversation's subagents.
///
/// A dialog on desktop and a sheet on a phone, decided by the platform rather
/// than by the window width: the repo forbids a bottom sheet on desktop, and a
/// narrow desktop window is still a desktop (the image-job panel does this the
/// same way).
Future<void> showSubagentPanel(
  BuildContext context, {
  required String conversationId,
}) {
  final child = _SubagentPanel(conversationId: conversationId);
  if (PlatformUtils.isDesktop) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
          child: child,
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => SafeArea(child: child),
  );
}

/// One row, whichever side it came from: a live delegation this process started,
/// or a result message that survived a restart.
final class _PanelRow {
  _PanelRow({
    required this.childConversationId,
    required this.title,
    required this.startedAt,
    required this.elapsed,
    required this.phase,
    required this.waitReason,
    this.assistantName,
  });

  factory _PanelRow.fromEntry(SubagentEntry entry) => _PanelRow(
    childConversationId: entry.childConversationId,
    title: entry.title,
    startedAt: entry.startedAt,
    elapsed: entry.elapsed,
    phase: entry.phase,
    waitReason: entry.waitReason,
    // Only a named target has one: `general` is this assistant, and saying so
    // on every other row would be noise.
    assistantName: entry.targetName,
  );

  factory _PanelRow.fromPart(SubagentResultPart part, DateTime sentAt) =>
      _PanelRow(
        childConversationId: part.childConversationId,
        title: (part.label ?? '').trim(),
        startedAt: sentAt,
        elapsed: part.elapsedMs == null
            ? null
            : Duration(milliseconds: part.elapsedMs!),
        phase: switch (part.outcome) {
          'failed' => SubagentPhase.failed,
          'cancelled' => SubagentPhase.cancelled,
          'interrupted' => SubagentPhase.interrupted,
          _ => SubagentPhase.completed,
        },
        waitReason: null,
        // The result part records who the child was by id, not by name; a row
        // read back after a restart therefore shows the job alone.
      );

  final String childConversationId;
  final String title;

  /// Who ran the task, when the delegation named somebody. Null for `general`
  /// and for every row reconstructed from a result message.
  final String? assistantName;

  /// How many conversations this subagent started itself.
  ///
  /// The list stays 直系 — a grandchild is reached by opening the child — but a
  /// row that has one says so, or a delegation that spent three contexts would
  /// look exactly like one that spent two.
  int descendants = 0;

  /// When the delegation started, which is also what orders the list.
  final DateTime startedAt;

  /// Known only once the run ended; a live row measures from [startedAt].
  final Duration? elapsed;
  final SubagentPhase phase;
  final SubagentWaitReason? waitReason;

  bool get needsInput => phase == SubagentPhase.waitingForInput;
  bool get isLive =>
      phase == SubagentPhase.running || phase == SubagentPhase.waitingForInput;

  /// What the row shows under the title: a finished row shows how long it ran, a
  /// live one how long it has been running.
  Duration? get shownDuration =>
      elapsed ?? (isLive ? DateTime.now().difference(startedAt) : null);
}

class _SubagentPanel extends StatefulWidget {
  const _SubagentPanel({required this.conversationId});

  final String conversationId;

  @override
  State<_SubagentPanel> createState() => _SubagentPanelState();
}

class _SubagentPanelState extends State<_SubagentPanel> {
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// A running row shows a duration, and a duration that stops moving reads as
  /// a hang. The ticker only exists while something is actually running.
  void _syncTicker(bool anyLive) {
    if (anyLive && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!anyLive && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = subagentCoordinatorOf(context);
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: coordinator ?? const _NeverNotifies(),
      builder: (context, _) {
        final rows = _collect(context, coordinator);
        _syncTicker(rows.any((row) => row.isLive));
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Text(
                l10n.subagentPanelTitle,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                child: Text(
                  l10n.subagentPanelEmpty,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: .6),
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    return _SubagentRow(
                      row: row,
                      onTap: () {
                        Navigator.of(context).maybePop();
                        coordinator?.openChild(row.childConversationId);
                      },
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }

  /// Live delegations plus the results this conversation has kept, newest
  /// delegation first.
  ///
  /// A finished delegation outlives this process only as its result message, so
  /// the registry alone would answer "nothing here" beside a divider the user can
  /// see. Order comes from the delegation's start time, not from its state: the
  /// four states are told apart by the icon and the word, not by where the row
  /// sits, and a list that reshuffles under a tap is worse than one that does not.
  List<_PanelRow> _collect(
    BuildContext context,
    SubagentCoordinator? coordinator,
  ) {
    final known = <String>{};
    final rows = <_PanelRow>[];
    final chat = context.read<ChatService?>();
    final grandchildren = _childCountByParent(chat);
    for (final entry in coordinator?.entries ?? const <SubagentEntry>[]) {
      if (entry.parentConversationId != widget.conversationId) continue;
      known.add(entry.childConversationId);
      rows.add(
        _PanelRow.fromEntry(entry)
          ..descendants = grandchildren[entry.childConversationId] ?? 0,
      );
    }
    // One delegation can write several result rows now (one per turn). The panel
    // shows the delegation, so the newest row is the one that describes it; the
    // old rows are the earlier turns of the same child.
    final persisted = <String, _PanelRow>{};
    for (final message
        in chat?.getMessages(widget.conversationId) ?? const <ChatMessage>[]) {
      for (final part in subagentResultsIn(<ChatMessage>[message])) {
        persisted[part.childConversationId] = _PanelRow.fromPart(
          part,
          message.timestamp,
        )..descendants = grandchildren[part.childConversationId] ?? 0;
      }
    }
    for (final row in persisted.values) {
      if (!known.add(row.childConversationId)) continue;
      rows.add(row);
    }
    rows.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return rows;
  }

  /// How many conversations each parent started, from the extras every child
  /// carries. One pass over the conversation list, not a query per row.
  static Map<String, int> _childCountByParent(ChatService? chat) {
    final counts = <String, int>{};
    for (final conversation
        in chat?.getAllConversations() ?? const <Conversation>[]) {
      final parent = conversation.extras[SubagentExtrasKeys.parent];
      if (parent is String && parent.isNotEmpty) {
        counts.update(parent, (value) => value + 1, ifAbsent: () => 1);
      }
    }
    return counts;
  }
}

/// A listenable that never fires, so one builder serves both "no coordinator"
/// and "coordinator".
final class _NeverNotifies implements Listenable {
  const _NeverNotifies();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

class _SubagentRow extends StatelessWidget {
  const _SubagentRow({required this.row, required this.onTap});

  final _PanelRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final needsYou = row.needsInput;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
        child: Row(
          children: [
            Icon(
              needsYou ? Lucide.CircleAlert : Lucide.Bot,
              size: 18,
              color: needsYou
                  ? cs.primary
                  : cs.onSurface.withValues(alpha: .55),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.title.isEmpty ? l10n.subagentPanelTitle : row.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _elapsedText(l10n, row),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurface.withValues(alpha: .55),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _stateOf(l10n, row),
              style: TextStyle(fontSize: 11.5, color: _stateColor(cs, row)),
            ),
          ],
        ),
      ),
    );
  }

  static String _stateOf(AppLocalizations l10n, _PanelRow row) {
    if (row.phase == SubagentPhase.waitingForInput) {
      return row.waitReason == SubagentWaitReason.approval
          ? l10n.subagentPanelWaitingApproval
          : l10n.subagentPanelWaitingAnswer;
    }
    return switch (row.phase) {
      SubagentPhase.running => l10n.subagentPanelRunning,
      SubagentPhase.completed => l10n.subagentPanelCompleted,
      SubagentPhase.failed => l10n.subagentPanelFailed,
      // The delegator's model asked it to stop; it can be continued, but the
      // panel has no word of its own for that yet.
      SubagentPhase.stopped => l10n.subagentPanelCancelled,
      SubagentPhase.cancelled => l10n.subagentPanelCancelled,
      SubagentPhase.interrupted => l10n.subagentPanelInterrupted,
      // Handled above, kept for the exhaustive switch.
      SubagentPhase.waitingForInput => l10n.subagentPanelWaitingAnswer,
    };
  }

  static Color _stateColor(ColorScheme cs, _PanelRow row) {
    if (row.needsInput) return cs.primary;
    if (row.phase == SubagentPhase.failed) return cs.error;
    return cs.onSurface.withValues(alpha: .6);
  }

  static String _elapsedText(AppLocalizations l10n, _PanelRow row) {
    final shown = row.shownDuration;
    final parts = <String>[
      if ((row.assistantName?.trim() ?? '').isNotEmpty)
        row.assistantName!.trim(),
      if (shown != null)
        l10n.subagentPanelElapsed(shown.inMinutes, shown.inSeconds % 60),
      // 直系 rows only, but a row that started its own subagents says so: the
      // list would otherwise read as the whole chain.
      if (row.descendants > 0) '+${row.descendants}',
    ];
    // `<assistant> · <duration> · +N`: the same order as the card, so a named
    // delegation reads the same in both places.
    return parts.join(' · ');
  }
}

/// The result parts a conversation has kept, oldest first.
List<SubagentResultPart> subagentResultsIn(Iterable<ChatMessage> messages) => [
  for (final message in messages)
    for (final part in message.parts)
      if (part is SubagentResultPart) part,
];
