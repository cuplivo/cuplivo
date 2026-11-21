import 'dart:async';

import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../services/subagent_coordinator.dart';
import 'subagent_panel.dart';

/// The one place a running subagent shows itself.
///
/// Everything about a delegation that is not a finished result lives here: the
/// tool card says nothing about progress, so this line and this line only answers
/// "is anything still going, and on what". A terminal outcome leaves it — that
/// belongs to the divider in the timeline, and saying it twice would make the
/// user read the same event in two places.
///
/// Nothing animates. The duration ticks because it is a value, not a pulse: a
/// shimmering line above the composer reads as decoration and stops being
/// noticed after the first minute.
class SubagentTaskStrip extends StatefulWidget {
  const SubagentTaskStrip({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<SubagentTaskStrip> createState() => _SubagentTaskStripState();
}

class _SubagentTaskStripState extends State<SubagentTaskStrip> {
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _syncTicker(bool live) {
    if (live && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!live && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = subagentCoordinatorOf(context);
    if (coordinator == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: coordinator,
      builder: (context, _) {
        final live = coordinator.liveFor(widget.conversationId);
        _syncTicker(live.isNotEmpty);
        if (live.isEmpty) return const SizedBox.shrink();
        final l10n = AppLocalizations.of(context)!;
        final cs = Theme.of(context).colorScheme;
        final waiting = live.where((entry) => entry.needsInput).length;
        final text = live.length == 1
            ? (live.first.needsInput
                  ? (live.first.waitReason == SubagentWaitReason.approval
                        ? l10n.subagentStripWaitingApproval(live.first.title)
                        : l10n.subagentStripWaiting(live.first.title))
                  : l10n.subagentStripRunning(
                      _elapsed(DateTime.now().difference(live.first.startedAt)),
                      live.first.title,
                    ))
            : (waiting == 0
                  ? l10n.subagentStripRunningMany(live.length)
                  : l10n.subagentStripCounts(
                      live.length,
                      live.length - waiting,
                    ));
        return InkWell(
          onTap: () =>
              showSubagentPanel(context, conversationId: widget.conversationId),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
            child: Row(
              children: [
                Icon(
                  waiting > 0 ? Lucide.CircleAlert : Lucide.Bot,
                  size: 14,
                  color: waiting > 0
                      ? cs.primary
                      : cs.onSurface.withValues(alpha: .55),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withValues(alpha: .6),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Icon(
                  Lucide.ChevronRight,
                  size: 14,
                  color: cs.onSurface.withValues(alpha: .45),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// `13.3s` — one decimal, because the difference between 3 and 4 seconds is
  /// not what the user is reading this for.
  static String _elapsed(Duration duration) =>
      '${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
}
