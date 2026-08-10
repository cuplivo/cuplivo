import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/headless_generation_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../services/ask_user_interaction_service.dart';
import '../services/tool_approval_service.dart';

/// 子代理面板 (subagent panel): transient live-status widget pinned above the
/// parent conversation's input bar while a wait-mode sub-agent runs.
///
/// Collapsed pill ↔ expanded card. Shows phase (思考中/输出中/等待批准), the
/// child's last step, elapsed time, and [查看子对话]. Auto-expands into an
/// interactive approval card when the child raises a pending approval/ask_user
/// request. The ✕ button cancels the sub-agent after a confirmation dialog.
class SubagentPanel extends StatefulWidget {
  const SubagentPanel({super.key, this.onOpenChild});

  /// Called with the child conversation id when the user taps 查看子对话 /
  /// 去回答.
  final ValueChanged<String>? onOpenChild;

  @override
  State<SubagentPanel> createState() => _SubagentPanelState();
}

class _SubagentPanelState extends State<SubagentPanel> {
  Timer? _ticker;
  final _expandedIds = <String>{};

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_activeJobs().isEmpty) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// All running wait-mode jobs spawned by the current conversation.
  /// Concurrent `kelivo_handoff_sync` calls produce multiple jobs — every one
  /// gets its own pill/expanded card.
  List<SubagentJob> _activeJobs() {
    final chatService = context.read<ChatService>();
    final parentId = chatService.currentConversationId;
    if (parentId == null) return const <SubagentJob>[];
    final headlessGen = context.read<HeadlessGenerationService>();
    return headlessGen
        .waitJobsFor(parentId)
        .where((job) => job.status == SubagentJobStatus.running)
        .toList();
  }

  ToolApprovalRequest? _pendingApproval(SubagentJob job) {
    final service = context.watch<ToolApprovalService>();
    for (final req in service.pendingRequests.values) {
      if (req.conversationId == job.conversationId) return req;
    }
    return null;
  }

  AskUserRequest? _pendingAskUser(SubagentJob job) {
    final service = context.watch<AskUserInteractionService>();
    for (final req in service.pendingRequests.values) {
      if (req.conversationId == job.conversationId) return req;
    }
    return null;
  }

  Future<void> _confirmCancel(SubagentJob job) async {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: cs.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.subagentPanelCancelConfirmTitle),
        content: Text(l10n.subagentPanelCancelConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(l10n.subagentPanelCancelConfirmKeep),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(l10n.subagentPanelCancelConfirmAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // Release any pending approval/ask_user the child is suspended on FIRST:
    // the child's generator is awaiting that completer with no in-flight
    // HTTP request, so token cancellation alone cannot unwind it.
    context.read<ToolApprovalService>().cancelForConversation(
      job.conversationId,
    );
    context.read<AskUserInteractionService>().cancelForConversation(
      job.conversationId,
    );
    context.read<HeadlessGenerationService>().cancel(job.conversationId);
  }

  @override
  Widget build(BuildContext context) {
    final jobs = _activeJobs();
    if (jobs.isEmpty) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? cs.surfaceContainerHighest : cs.surface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final job in jobs) ...[
            _buildJobCard(context, job, base, cs, l10n),
            if (job != jobs.last) const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  Widget _buildJobCard(
    BuildContext context,
    SubagentJob job,
    Color base,
    ColorScheme cs,
    AppLocalizations l10n,
  ) {
    final approval = _pendingApproval(job);
    final askUser = _pendingAskUser(job);
    final waitingInteraction = approval != null || askUser != null;
    final forceExpanded = waitingInteraction;
    final showExpanded =
        forceExpanded || _expandedIds.contains(job.conversationId);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IosCardPress(
          borderRadius: BorderRadius.circular(12),
          baseColor: base,
          pressedScale: 0.99,
          onTap: waitingInteraction
              ? null
              : () => setState(() {
                  if (!_expandedIds.add(job.conversationId)) {
                    _expandedIds.remove(job.conversationId);
                  }
                }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CupertinoActivityIndicator(),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    // {assistant name} · {elapsed} — no phase, no arrow
                    '${job.targetName ?? job.conversationId} · '
                    '${_formatElapsed(job)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                if (!waitingInteraction)
                  Icon(
                    showExpanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                const SizedBox(width: 4),
                IosIconButton(
                  icon: Icons.close,
                  size: 16,
                  color: cs.onSurfaceVariant,
                  semanticLabel: l10n.subagentPanelCancelTooltip,
                  onTap: () => _confirmCancel(job),
                ),
              ],
            ),
          ),
        ),
        if (showExpanded)
          Container(
            decoration: BoxDecoration(
              color: base,
              borderRadius: BorderRadius.circular(12),
            ),
            child: _buildExpandedBody(context, job, approval, askUser),
          ),
      ],
    );
  }

  Widget _buildExpandedBody(
    BuildContext context,
    SubagentJob job,
    ToolApprovalRequest? approval,
    AskUserRequest? askUser,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    final children = <Widget>[];
    if (approval != null) {
      children.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              approval.toolName,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _argsSummary(approval.arguments),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: IosCardPress(
                    borderRadius: BorderRadius.circular(10),
                    baseColor: cs.primaryContainer,
                    onTap: () => context.read<ToolApprovalService>().approve(
                      approval.toolCallId,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        l10n.subagentPanelApprove,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: IosCardPress(
                    borderRadius: BorderRadius.circular(10),
                    baseColor: cs.surfaceContainerHighest,
                    onTap: () => context.read<ToolApprovalService>().deny(
                      approval.toolCallId,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        l10n.subagentPanelDeny,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    } else if (askUser != null) {
      children.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.subagentPanelAskUserPending,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            IosCardPress(
              borderRadius: BorderRadius.circular(10),
              baseColor: cs.primaryContainer,
              onTap: () => widget.onOpenChild?.call(job.conversationId),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  l10n.subagentPanelAnswerNow,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      // One row: {N} tool calls · last step, tap anywhere to open the child.
      children.add(
        IosCardPress(
          borderRadius: BorderRadius.circular(10),
          baseColor: cs.surfaceContainerHighest,
          pressedScale: 0.98,
          onTap: () => widget.onOpenChild?.call(job.conversationId),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.hub_outlined, size: 15, color: cs.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.subagentPanelToolCalls(job.toolCallCount),
                    style: TextStyle(fontSize: 13, color: cs.onSurface),
                  ),
                ),
                if (job.lastStep != null)
                  Expanded(
                    child: Text(
                      job.lastStep!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_forward_ios,
                  size: 14,
                  color: cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  static String _argsSummary(Map<String, dynamic> args) {
    final entries = args.entries.map((e) => '${e.key}: ${e.value}').toList();
    return entries.isEmpty ? '{}' : entries.join('\n');
  }

  static String _formatElapsed(SubagentJob job) {
    final d = DateTime.now().difference(job.startedAt);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}
