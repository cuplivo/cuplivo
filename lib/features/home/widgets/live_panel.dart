import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/download_progress_store.dart';
import '../../../core/providers/input_status_provider.dart';
import '../../../core/providers/knowledge_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/generation_engine.dart';
import '../../../core/services/knowledge/knowledge_store.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/image_mode_info_popover.dart';
import '../../../theme/design_tokens.dart';
import '../services/ask_user_interaction_service.dart';
import '../services/tool_approval_service.dart';
import 'image_generation_options.dart';

/// LivePanel (实时面板): unified transient-status surface rendered inside the
/// conversation input bar's card. Hosts heterogeneous live entries — subagent
/// jobs, workspace downloads, and the image-mode / image-warning pills —
/// sharing one pill↔card design language (issue #307, ADR-0036). Entries are
/// transparent rows inside the card separated by hairline rules; the card's
/// single rounded border bounds the section and a trailing rule doubles as
/// the chat input's upper border. The panel's height feeds the message list's
/// bottom padding so the last message is never shaded.
///
/// Entry order: info pill, warning pill, download entries, subagent entries.
/// Every entry is conversation-scoped (keyed off `currentConversationId`);
/// the panel disappears when no entry exists.
///
/// UI inspiration: [Paseo](https://github.com/getpaseo/paseo) — transient
/// agent status hosted inside a unified composer panel.
class LivePanel extends StatefulWidget {
  const LivePanel({super.key, this.onOpenChild, this.imageGenController});

  /// Called with the child conversation id when the user taps 查看子对话 /
  /// 去回答 on a subagent entry.
  final ValueChanged<String>? onOpenChild;

  /// Shared image-generation options controller (home page owned, same
  /// instance as the input bar's). Drives the inline expanded options card;
  /// when null the panel creates its own (tests).
  final ImageGenerationOptionsController? imageGenController;

  @override
  State<LivePanel> createState() => _LivePanelState();
}

class _LivePanelState extends State<LivePanel> {
  static const Duration _expandDuration = Duration(milliseconds: 220);
  static const Curve _expandCurve = Curves.easeOutCubic;

  Timer? _ticker;
  final ScrollController _scrollController = ScrollController();
  Set<String> _lastEntryIds = <String>{};
  final _expandedJobIds = <String>{};
  final _expandedDownloadIds = <String>{};
  bool _expandedImageMode = false;
  bool _expandedKnowledge = false;
  final _imageModeInfoKey = GlobalKey(debugLabel: 'image-mode-info');
  final _chatModeInfoKey = GlobalKey(debugLabel: 'chat-mode-info');
  late final ImageGenerationOptionsController _imageGenController =
      widget.imageGenController ?? ImageGenerationOptionsController();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_activeJobs().isEmpty && _activeDownloads().isEmpty) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  /// All running wait-mode jobs spawned by the current conversation.
  /// Concurrent `kelivo_handoff` calls produce multiple jobs — every one
  /// gets its own pill/expanded card.
  List<GenerationSlot> _activeJobs() {
    final chatService = context.read<ChatService>();
    final parentId = chatService.currentConversationId;
    if (parentId == null) return const <GenerationSlot>[];
    final engine = context.read<GenerationEngine>();
    return engine
        .waitSlotsFor(parentId)
        .where((job) => job.status == SlotStatus.running)
        .toList();
  }

  List<DownloadJob> _activeDownloads() {
    final chatService = context.read<ChatService>();
    final parentId = chatService.currentConversationId;
    if (parentId == null) return const <DownloadJob>[];
    return context.read<DownloadProgressStore>().runningFor(parentId);
  }

  ToolApprovalRequest? _pendingApproval(GenerationSlot job) {
    final service = context.watch<ToolApprovalService>();
    for (final req in service.pendingRequests.values) {
      if (req.conversationId == job.conversationId) return req;
    }
    return null;
  }

  AskUserRequest? _pendingAskUser(GenerationSlot job) {
    final service = context.watch<AskUserInteractionService>();
    for (final req in service.pendingRequests.values) {
      if (req.conversationId == job.conversationId) return req;
    }
    return null;
  }

  Future<void> _confirmCancel(GenerationSlot job) async {
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
    context.read<GenerationEngine>().cancelConversation(job.conversationId);
  }

  @override
  Widget build(BuildContext context) {
    final jobs = _activeJobs();
    final downloads = _activeDownloads();
    // Reveal entries appended below the fold: only when an entry that was
    // not present before arrives AND the view already sits at (or near) the
    // bottom, so a user reading the panel top is not dragged away. Identity
    // tracking (not a count) so that a removal + an addition in the same
    // rebuild still reveals the new entry. Removal of entries scrolls nothing.
    final entryIds = <String>{
      for (final job in jobs) 'job:${job.conversationId}',
      for (final download in downloads) 'dl:${download.id}',
    };
    final hasNewEntry = entryIds.any((id) => !_lastEntryIds.contains(id));
    if (hasNewEntry && _scrollController.hasClients) {
      final position = _scrollController.position;
      final atBottom = position.pixels >= position.maxScrollExtent - 24;
      if (atBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollController.hasClients) return;
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          );
        });
      }
    }
    _lastEntryIds = entryIds;
    final inputStatus = context.watch<InputStatusProvider>();
    final knowledgeHits = context.watch<KnowledgeProvider>().retrievalHitsFor(
      context.read<ChatService>().currentConversationId,
    );
    final hasPills =
        inputStatus.imageModeActive ||
        inputStatus.imageModeDismissed ||
        inputStatus.imageWarningActive ||
        knowledgeHits.isNotEmpty;
    if (jobs.isEmpty && downloads.isEmpty && !hasPills) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    // The expansion flag is only meaningful while the image-mode pill renders.
    // Sync it here so a model switch (pill disappears) collapses the options
    // card instead of silently re-expanding it on the next activation.
    final showImageOptionsExpanded =
        _expandedImageMode && inputStatus.imageModeActive;
    if (showImageOptionsExpanded != _expandedImageMode) {
      _expandedImageMode = showImageOptionsExpanded;
    }

    // One entry = its row plus any expanded body; entries are transparent
    // rows inside the card, separated by hairline rules. The card's own
    // rounded border bounds the section, so the first row has no rule above
    // it, and a trailing rule draws the chat input's upper border.
    final entries = <Widget>[];
    if (inputStatus.imageModeActive) {
      entries.add(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildImageModePill(inputStatus, cs, l10n),
            _expandable(
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [const SizedBox(height: 6), _buildImageOptionsCard()],
              ),
              showImageOptionsExpanded,
            ),
          ],
        ),
      );
    } else if (inputStatus.imageModeDismissed) {
      entries.add(_buildChatModePill(inputStatus, cs, l10n));
    }
    if (inputStatus.imageWarningActive) {
      entries.add(
        _buildPill(
          icon: Lucide.ImageOff,
          label: l10n.chatInputBarImageWarning,
          closeTooltip: l10n.chatInputBarDisableImageWarningTooltip,
          onClose: () => inputStatus.dismissImageWarning(),
          cs: cs,
        ),
      );
    }
    if (knowledgeHits.isNotEmpty) {
      entries.add(_buildKnowledgePill(knowledgeHits, cs, l10n));
    }
    for (final download in downloads) {
      entries.add(_buildDownloadCard(download, cs));
    }
    for (final job in jobs) {
      entries.add(_buildJobCard(context, job, cs, l10n));
    }

    // Cap the panel so many entries or the expanded options card cannot push
    // the input bar off the top of the screen; the entries scroll within it.
    // The cap is keyboard-aware, mirroring the input bar's visibleHeight math.
    final media = MediaQuery.of(context);
    final maxEntriesHeight =
        (media.size.height - media.viewInsets.bottom) * 0.45;
    final children = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      if (i > 0) children.add(_entryRule(cs));
      children.add(entries[i]);
    }
    if (entries.isNotEmpty) children.add(_entryRule(cs));
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxEntriesHeight),
      child: SingleChildScrollView(
        controller: _scrollController,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...children,
            // Breathing room between the last rule and the input bar content
            // below; absent when the panel is empty.
            const SizedBox(height: AppSpacing.xxs),
          ],
        ),
      ),
    );
  }

  /// Full-width hairline separating live entries from each other and the
  /// chat input section. The card's own border bounds the first entry, so
  /// the first row intentionally has no rule above it.
  static Widget _entryRule(ColorScheme cs) {
    return SizedBox(
      height: 1,
      child: ColoredBox(
        color: cs.outline.withValues(
          alpha: cs.brightness == Brightness.dark ? 0.16 : 0.14,
        ),
      ),
    );
  }

  /// Animated show/hide for an entry's expandable section: the height eases
  /// between 0 and full instead of jumping. The collapsed box keeps the
  /// entry's width (only height animates).
  static Widget _expandable(Widget child, bool visible) {
    return AnimatedSize(
      duration: _expandDuration,
      curve: _expandCurve,
      alignment: Alignment.topCenter,
      child: visible ? child : const SizedBox(width: double.infinity),
    );
  }

  /// Rotating expand/collapse chevron: up when collapsed, flipped 180° (i.e.
  /// appearing as down) when expanded.
  static Widget _animatedChevron({
    required bool expanded,
    required Color color,
  }) {
    return AnimatedRotation(
      turns: expanded ? 0.5 : 0.0,
      duration: _expandDuration,
      curve: _expandCurve,
      child: Icon(Icons.keyboard_arrow_up, size: 18, color: color),
    );
  }

  Widget _buildImageModePill(
    InputStatusProvider inputStatus,
    ColorScheme cs,
    AppLocalizations l10n,
  ) {
    return _buildPill(
      icon: Lucide.Brush,
      label: l10n.chatInputBarImageMode,
      cs: cs,
      onTap: () => setState(() => _expandedImageMode = !_expandedImageMode),
      infoButton: IosIconButton(
        key: _imageModeInfoKey,
        icon: Icons.info_outline,
        size: 16,
        color: cs.onSurfaceVariant,
        semanticLabel: l10n.chatInputBarImageModeInfoTooltip,
        onTap: () => unawaited(
          showImageModeInfoPopover(context, anchorKey: _imageModeInfoKey),
        ),
      ),
      trailing: [
        if (_imageGenController.customized)
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: cs.primary,
              shape: BoxShape.circle,
            ),
          ),
        _animatedChevron(
          expanded: _expandedImageMode,
          color: cs.onSurfaceVariant,
        ),
        const SizedBox(width: 2),
        IosIconButton(
          icon: Icons.close,
          size: 16,
          color: cs.onSurfaceVariant,
          semanticLabel: l10n.chatInputBarDisableImageModeTooltip,
          onTap: () {
            setState(() => _expandedImageMode = false);
            inputStatus.dismissImageMode();
          },
        ),
      ],
    );
  }

  Widget _buildChatModePill(
    InputStatusProvider inputStatus,
    ColorScheme cs,
    AppLocalizations l10n,
  ) {
    return _buildPill(
      icon: Lucide.MessageSquare,
      label: l10n.chatInputBarChatMode,
      cs: cs,
      onTap: () {
        inputStatus.restoreImageMode();
        setState(() => _expandedImageMode = true);
      },
      infoButton: IosIconButton(
        key: _chatModeInfoKey,
        icon: Icons.info_outline,
        size: 16,
        color: cs.onSurfaceVariant,
        semanticLabel: l10n.chatInputBarImageModeInfoTooltip,
        onTap: () => unawaited(
          showImageModeInfoPopover(context, anchorKey: _chatModeInfoKey),
        ),
      ),
    );
  }

  Widget _buildImageOptionsCard() {
    // Single scroll layer: the panel's outer scroll view owns all scrolling,
    // so a nested scrollable here would trap the card's tail below the
    // panel's window on clamping platforms. No ConstrainedBox/scroll.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: ImageGenerationOptionsBody(
        controller: _imageGenController,
        onChanged: () => setState(() {}),
      ),
    );
  }

  Widget _buildPill({
    required IconData icon,
    required String label,
    required ColorScheme cs,
    VoidCallback? onTap,
    Widget? infoButton,
    List<Widget> trailing = const <Widget>[],
    String? closeTooltip,
    VoidCallback? onClose,
  }) {
    return IosCardPress(
      borderRadius: BorderRadius.circular(12),
      baseColor: Colors.transparent,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 14, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ),
            if (infoButton != null) ...[infoButton, const SizedBox(width: 2)],
            ...trailing,
            if (onClose != null) ...[
              const SizedBox(width: 2),
              IosIconButton(
                icon: Icons.close,
                size: 16,
                color: cs.onSurfaceVariant,
                semanticLabel: closeTooltip ?? label,
                onTap: onClose,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildKnowledgePill(
    List<KnowledgeSearchHit> hits,
    ColorScheme cs,
    AppLocalizations l10n,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildPill(
          icon: Lucide.BookOpenText,
          label: l10n.knowledgePillHits(hits.length),
          cs: cs,
          onTap: () => setState(() => _expandedKnowledge = !_expandedKnowledge),
          trailing: [
            _animatedChevron(
              expanded: _expandedKnowledge,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(width: 2),
          ],
        ),
        _expandable(
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final hit in hits)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hit.documentName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: cs.primary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          hit.chunk.content,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.35,
                            color: cs.onSurface.withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          _expandedKnowledge,
        ),
      ],
    );
  }

  Widget _buildDownloadCard(DownloadJob job, ColorScheme cs) {
    final showExpanded = _expandedDownloadIds.contains(job.id);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IosCardPress(
          borderRadius: BorderRadius.circular(12),
          baseColor: Colors.transparent,
          onTap: () => setState(() {
            if (!_expandedDownloadIds.add(job.id)) {
              _expandedDownloadIds.remove(job.id);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(Lucide.Download, size: 14, color: cs.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${_basename(job.displayPath)} · '
                    '${_formatElapsed(job.startedAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                _animatedChevron(
                  expanded: showExpanded,
                  color: cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        _expandable(
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: _buildDownloadProgress(job, cs),
          ),
          showExpanded,
        ),
      ],
    );
  }

  Widget _buildDownloadProgress(DownloadJob job, ColorScheme cs) {
    final percent = job.percent;
    final fraction = (job.progress ?? 0).clamp(0.0, 1.0).toDouble();
    final detail = percent != null
        ? '$percent%'
        : _formatBytes(job.receivedBytes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: 4,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: cs.onSurface.withValues(alpha: 0.08)),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: fraction,
                    child: ColoredBox(color: cs.primary),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          detail,
          style: TextStyle(
            fontSize: 11,
            color: cs.onSurface.withValues(alpha: 0.56),
          ),
        ),
      ],
    );
  }

  Widget _buildJobCard(
    BuildContext context,
    GenerationSlot job,
    ColorScheme cs,
    AppLocalizations l10n,
  ) {
    final approval = _pendingApproval(job);
    final askUser = _pendingAskUser(job);
    final waitingInteraction = approval != null || askUser != null;
    final forceExpanded = waitingInteraction;
    final showExpanded =
        forceExpanded || _expandedJobIds.contains(job.conversationId);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IosCardPress(
          borderRadius: BorderRadius.circular(12),
          baseColor: Colors.transparent,
          onTap: waitingInteraction
              ? null
              : () => setState(() {
                  if (!_expandedJobIds.add(job.conversationId)) {
                    _expandedJobIds.remove(job.conversationId);
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
                    '${_formatElapsed(job.startedAt)}',
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
                  _animatedChevron(
                    expanded: showExpanded,
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
        _expandable(
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: _buildExpandedBody(context, job, approval, askUser),
          ),
          showExpanded,
        ),
      ],
    );
  }

  Widget _buildExpandedBody(
    BuildContext context,
    GenerationSlot job,
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

  static String _basename(String path) {
    final idx = path.lastIndexOf('/');
    if (idx < 0) return path;
    final name = path.substring(idx + 1);
    return name.isEmpty ? path : name;
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _formatElapsed(DateTime startedAt) {
    final d = DateTime.now().difference(startedAt);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}
