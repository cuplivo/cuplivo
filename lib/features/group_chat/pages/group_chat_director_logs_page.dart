import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/models/group_chat_director_log.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../../desktop/group_chat_dialog_shell.dart';
import '../services/director_log_builder.dart';

class GroupChatDirectorLogsPage extends StatefulWidget {
  const GroupChatDirectorLogsPage({
    super.key,
    required this.groupChatId,
    this.embedded = false,
  });

  final String groupChatId;

  /// When true the page renders its body only (no Scaffold/AppBar) so it can
  /// be hosted inside the desktop dialog (see
  /// [showGroupChatDirectorLogsDialog]).
  final bool embedded;

  @override
  State<GroupChatDirectorLogsPage> createState() =>
      _GroupChatDirectorLogsPageState();
}

/// Desktop dialog host for the director logs body. Stacks on top of the
/// group settings dialog when opened from there (embedded mode).
Future<void> showGroupChatDirectorLogsDialog(
  BuildContext context, {
  required String groupChatId,
}) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => Dialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: GroupChatDialogShell(
          title: l10n.groupChatDirectorLogs,
          child: GroupChatDirectorLogsPage(
            groupChatId: groupChatId,
            embedded: true,
          ),
        ),
      ),
    ),
  );
}

class _GroupChatDirectorLogsPageState extends State<GroupChatDirectorLogsPage> {
  String _entriesSignature = '';
  List<DirectorLogEntry> _entries = const [];

  /// Rebuilds the reconstructed timeline only when its inputs actually
  /// change. The page watches several providers that notify frequently during
  /// active group rounds; without this guard every notification recomputed
  /// the whole timeline from scratch.
  List<DirectorLogEntry> _entriesFor({
    required ChatService chatService,
    required GroupChat group,
    required List<ChatMessage> publicMessages,
    required Conversation? conversation,
    required List<Assistant> roster,
    required String userName,
    required Map<String, Assistant> assistantsById,
    required String fallbackAssistantName,
    required List<GroupChatDirectorRuntimeLog> runtimeLogs,
  }) {
    final signature = _signature(
      group: group,
      publicMessages: publicMessages,
      conversation: conversation,
      roster: roster,
      userName: userName,
      assistantsById: assistantsById,
      fallbackAssistantName: fallbackAssistantName,
      runtimeLogs: runtimeLogs,
    );
    if (signature == _entriesSignature) return _entries;
    _entriesSignature = signature;
    _entries = DirectorLogBuilder(chatService: chatService).build(
      group: group,
      publicMessages: publicMessages,
      conversation: conversation,
      rosterAssistants: roster,
      userName: userName,
      assistantsById: assistantsById,
      fallbackAssistantName: fallbackAssistantName,
      runtimeLogs: runtimeLogs,
    );
    return _entries;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final groupProvider = context.watch<GroupChatProvider>();
    final group = groupProvider.getById(widget.groupChatId);

    if (group == null) {
      if (widget.embedded) {
        // The group vanished while the dialog was open (e.g. deleted via
        // restore/backup somewhere else). Close the dialog instead of
        // leaving a dead not-found body, mirroring the assistant desktop
        // dialog.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).maybePop();
        });
        return Center(child: Text(l10n.groupChatNotFound));
      }
      return Scaffold(
        appBar: AppBar(title: Text(l10n.groupChatDirectorLogs)),
        body: Center(child: Text(l10n.groupChatNotFound)),
      );
    }

    final chatService = context.watch<ChatService>();
    final assistants = context.watch<AssistantProvider>().assistants;
    final memberIds = groupProvider.assistantIdsOf(group.id).toSet();
    final roster = assistants.where((a) => memberIds.contains(a.id)).toList();
    final assistantsById = {
      for (final assistant in assistants) assistant.id: assistant,
    };
    final user = context.watch<UserProvider>();
    final userName = user.name.trim().isEmpty
        ? l10n.groupChatUserLabel
        : user.name.trim();
    final publicMessages = chatService.getMessages(group.conversationId);
    final entries = _entriesFor(
      chatService: chatService,
      group: group,
      publicMessages: publicMessages,
      conversation: chatService.getConversation(group.conversationId),
      roster: roster,
      userName: userName,
      assistantsById: assistantsById,
      fallbackAssistantName: l10n.groupChatDirectorLogsUnknownSpeaker,
      runtimeLogs: groupProvider.directorRuntimeLogs(group.id),
    );
    final emptyMessage = roster.isEmpty
        ? l10n.groupChatNoAssistants
        : l10n.groupChatDirectorLogsEmpty;

    final body = entries.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                emptyMessage,
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
              ),
            ),
          )
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
            itemCount: entries.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              if (index == 0) {
                return _LogInfoBanner(
                  text: l10n.groupChatDirectorLogsEphemeral,
                );
              }
              return _DirectorLogCard(
                entry: entries[index - 1],
                assistantsById: assistantsById,
              );
            },
          );

    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          color: cs.onSurface,
          size: 22,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.groupChatDirectorLogs),
      ),
      body: body,
    );
  }

  /// Cheap, deterministic fingerprint of every input the timeline build reads.
  /// Message content is included because the chat cache mutates messages in
  /// place (streaming updates), so list identity alone is not a safe key.
  static String _signature({
    required GroupChat group,
    required List<ChatMessage> publicMessages,
    required Conversation? conversation,
    required List<Assistant> roster,
    required String userName,
    required Map<String, Assistant> assistantsById,
    required String fallbackAssistantName,
    required List<GroupChatDirectorRuntimeLog> runtimeLogs,
  }) {
    final buf = StringBuffer();
    buf.write(group.id);
    buf.write('|cap=');
    buf.write(group.maxAssistantMessagesPerRound);
    buf.write('|inject=');
    buf.write(group.assistantDetailInjectionMode.name);
    buf.write(':');
    buf.write(group.assistantDetailInjectionN);
    buf.write('|pending=');
    buf.write(group.pendingCapAssistantMessageId);
    buf.write('|prompt=');
    buf.write(group.directorSystemPrompt);
    buf.write('|name=');
    buf.write(group.name);
    buf.write('|user=');
    buf.write(userName);
    buf.write('|fallback=');
    buf.write(fallbackAssistantName);
    buf.write('|truncate=');
    buf.write(conversation?.truncateIndex);
    final selections = conversation?.versionSelections ?? const <String, int>{};
    final sortedKeys = selections.keys.toList()..sort();
    for (final key in sortedKeys) {
      buf.write('|sel=');
      buf.write(key);
      buf.write(':');
      buf.write(selections[key]);
    }
    for (final message in publicMessages) {
      buf.write('|');
      buf.write(message.id);
      buf.write('@');
      buf.write(message.groupId);
      buf.write(':');
      buf.write(message.version);
      buf.write(':');
      buf.write(message.role);
      buf.write(':');
      buf.write(message.content);
    }
    for (final assistant in roster) {
      buf.write('|a=');
      buf.write(assistant.id);
      buf.write(':');
      buf.write(assistant.name);
      buf.write(':');
      buf.write(assistant.systemPrompt);
    }
    // Assistant names feed the reconstructed E2 context; sort for stability.
    final names = assistantsById.values.map((a) => '${a.id}:${a.name}').toList()
      ..sort();
    for (final name in names) {
      buf.write('|n=');
      buf.write(name);
    }
    for (final log in runtimeLogs) {
      buf.write('|r=');
      buf.write(log.sourceMessageId);
      buf.write(':');
      buf.write(log.finishedAt.microsecondsSinceEpoch);
    }
    return buf.toString();
  }
}

class _LogInfoBanner extends StatelessWidget {
  const _LogInfoBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: cs.primary.withValues(alpha: 0.10),
        border: Border.all(color: cs.primary.withValues(alpha: 0.20)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Lucide.info, size: 18, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.78)),
            ),
          ),
        ],
      ),
    );
  }
}

class _DirectorLogCard extends StatefulWidget {
  const _DirectorLogCard({required this.entry, required this.assistantsById});

  final DirectorLogEntry entry;
  final Map<String, Assistant> assistantsById;

  @override
  State<_DirectorLogCard> createState() => _DirectorLogCardState();
}

class _DirectorLogCardState extends State<_DirectorLogCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final entry = widget.entry;
    final materialL10n = MaterialLocalizations.of(context);
    final timestamp =
        '${materialL10n.formatMediumDate(entry.timestamp)} '
        '${materialL10n.formatTimeOfDay(TimeOfDay.fromDateTime(entry.timestamp))}';
    final outcome = _outcomeLabel(l10n, entry);
    final outcomeColor = entry.outcome == DirectorLogOutcome.observedSpeaker
        ? cs.primary
        : cs.onSurface.withValues(alpha: 0.68);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IosCardPress(
            haptics: false,
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _OutcomeIcon(entry: entry, color: outcomeColor),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.groupChatDirectorLogsEntryTitle(entry.order + 1),
                          style: TextStyle(
                            fontWeight: AppFontWeights.emphasis,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          timestamp,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurface.withValues(alpha: 0.52),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _triggerLabel(l10n, entry.trigger),
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withValues(alpha: 0.62),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          outcome,
                          style: TextStyle(
                            fontSize: 13,
                            color: outcomeColor,
                            fontWeight: AppFontWeights.emphasis,
                          ),
                        ),
                        if (entry.triggerContent.trim().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            _clip(entry.triggerContent, 160),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.3,
                              color: cs.onSurface.withValues(alpha: 0.62),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(
                    _expanded ? Lucide.ChevronUp : Lucide.ChevronDown,
                    size: 18,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
              child: _details(context, l10n),
            ),
        ],
      ),
    );
  }

  Widget _details(BuildContext context, AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    final entry = widget.entry;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(color: cs.outlineVariant.withValues(alpha: 0.45)),
        Text(
          l10n.groupChatDirectorLogsReconstructedContext,
          style: TextStyle(
            fontWeight: AppFontWeights.emphasis,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        if (entry.contextMessages.isEmpty)
          Text(
            l10n.groupChatDirectorLogsNoContext,
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.62)),
          )
        else
          ...entry.contextMessages.asMap().entries.map(
            (item) => _ContextMessage(index: item.key + 1, message: item.value),
          ),
        if (entry.runtime != null) ...[
          const SizedBox(height: 14),
          Text(
            l10n.groupChatDirectorLogsRuntimeDetails,
            style: TextStyle(
              fontWeight: AppFontWeights.emphasis,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          _RuntimeDetails(log: entry.runtime!),
        ] else if (entry.outcome != DirectorLogOutcome.roundCapReached) ...[
          const SizedBox(height: 14),
          Text(
            l10n.groupChatDirectorLogsRuntimeUnavailable,
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.62)),
          ),
        ],
      ],
    );
  }

  String _triggerLabel(
    AppLocalizations l10n,
    GroupChatDirectorLogTrigger trigger,
  ) {
    return switch (trigger) {
      GroupChatDirectorLogTrigger.user => l10n.groupChatDirectorLogsTriggerUser,
      GroupChatDirectorLogTrigger.assistant =>
        l10n.groupChatDirectorLogsTriggerAssistant,
      GroupChatDirectorLogTrigger.capMerge =>
        l10n.groupChatDirectorLogsTriggerCapMerge,
    };
  }

  String _outcomeLabel(AppLocalizations l10n, DirectorLogEntry entry) {
    return switch (entry.outcome) {
      DirectorLogOutcome.observedSpeaker =>
        l10n.groupChatDirectorLogsObservedSpeaker(
          _assistantName(l10n, entry.observedAssistantId),
        ),
      DirectorLogOutcome.noObservedFollowUp =>
        l10n.groupChatDirectorLogsNoObservedFollowUp,
      DirectorLogOutcome.roundCapReached =>
        l10n.groupChatDirectorLogsRoundCapReached,
    };
  }

  String _assistantName(AppLocalizations l10n, String? id) {
    if (id == null || id.isEmpty) {
      return l10n.groupChatDirectorLogsUnknownSpeaker;
    }
    return widget.assistantsById[id]?.name ?? id;
  }

  static String _clip(String value, int max) {
    final text = value.trim();
    if (text.length <= max) return text;
    return '${text.substring(0, max)}…';
  }
}

class _OutcomeIcon extends StatelessWidget {
  const _OutcomeIcon({required this.entry, required this.color});

  final DirectorLogEntry entry;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final icon = switch (entry.outcome) {
      DirectorLogOutcome.observedSpeaker => Lucide.ArrowRight,
      DirectorLogOutcome.noObservedFollowUp => Lucide.MessageSquare,
      DirectorLogOutcome.roundCapReached => Lucide.CircleStop,
    };
    return Icon(icon, size: 20, color: color);
  }
}

class _ContextMessage extends StatelessWidget {
  const _ContextMessage({required this.index, required this.message});

  final int index;
  final DirectorLogContextMessage message;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: cs.surface.withValues(alpha: 0.55),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_roleLabel(l10n, message.role)}  #$index',
            style: TextStyle(
              fontSize: 12,
              fontWeight: AppFontWeights.emphasis,
              color: cs.primary,
            ),
          ),
          const SizedBox(height: 5),
          SelectableText(
            message.content,
            style: TextStyle(fontSize: 13, height: 1.35, color: cs.onSurface),
          ),
        ],
      ),
    );
  }

  String _roleLabel(AppLocalizations l10n, String role) {
    return switch (role) {
      'system' => l10n.groupChatDirectorLogsRoleSystem,
      'user' => l10n.groupChatDirectorLogsRoleUser,
      'assistant' => l10n.groupChatDirectorLogsRoleAssistant,
      'tool' => l10n.groupChatDirectorLogsRoleTool,
      _ => role,
    };
  }
}

class _RuntimeDetails extends StatelessWidget {
  const _RuntimeDetails({required this.log});

  final GroupChatDirectorRuntimeLog log;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    final model = [
      log.providerKey,
      log.modelId,
    ].whereType<String>().where((value) => value.trim().isNotEmpty).join(' / ');
    if (model.isNotEmpty) {
      rows.add(
        _RuntimeRow(
          label: l10n.groupChatDirectorLogsRuntimeModel,
          value: model,
        ),
      );
    }
    rows.add(
      _RuntimeRow(
        label: l10n.groupChatDirectorLogsRuntimeAttempts,
        value: log.attemptCount.toString(),
      ),
    );
    rows.add(
      _RuntimeRow(
        label: l10n.groupChatDirectorLogsRuntimeRequestMessages,
        value: log.requestMessageCount.toString(),
      ),
    );
    if (log.decisionKind != null) {
      rows.add(
        _RuntimeRow(
          label: l10n.groupChatDirectorLogsRuntimeDecision,
          value: _decisionLabel(l10n, log.decisionKind!),
        ),
      );
    }
    if (log.reason?.trim().isNotEmpty ?? false) {
      rows.add(
        _RuntimeRow(
          label: l10n.groupChatDirectorLogsRuntimeReason,
          value: log.reason!.trim(),
        ),
      );
    }
    if (log.fallback) {
      rows.add(
        _RuntimeRow(
          label: l10n.groupChatDirectorLogsRuntimeFallback,
          value: l10n.groupChatDirectorLogsRuntimeFallbackValue,
        ),
      );
    }
    for (final error in log.attemptErrors) {
      rows.add(
        _RuntimeRow(
          label: l10n.groupChatDirectorLogsRuntimeError,
          value: error,
          valueColor: cs.error,
        ),
      );
    }
    if (log.failure != null && log.failure!.trim().isNotEmpty) {
      rows.add(
        _RuntimeRow(
          label: l10n.groupChatDirectorLogsRuntimeFailure,
          value: _failureLabel(l10n, log.failure!),
          valueColor: cs.error,
        ),
      );
    }
    if (log.freeText != null && log.freeText!.trim().isNotEmpty) {
      rows.add(
        _RuntimeRow(
          label: l10n.groupChatDirectorLogsRuntimeFreeText,
          value: log.freeText!.trim(),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows.isEmpty
          ? [Text(l10n.groupChatDirectorLogsRuntimeEmpty)]
          : rows,
    );
  }

  String _decisionLabel(AppLocalizations l10n, String kind) {
    return switch (kind) {
      'selectSpeaker' => l10n.groupChatDirectorLogsDecisionSelectSpeaker,
      'endTurn' => l10n.groupChatDirectorLogsDecisionEndTurn,
      _ => kind,
    };
  }

  String _failureLabel(AppLocalizations l10n, String failure) {
    return switch (failure) {
      'no_model' => l10n.groupChatNoDirectorModel,
      'no_tools' => l10n.groupChatDirectorModelNoTools,
      _ => failure,
    };
  }
}

class _RuntimeRow extends StatelessWidget {
  const _RuntimeRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SelectableText.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: TextStyle(
                fontWeight: AppFontWeights.emphasis,
                color: cs.onSurface.withValues(alpha: 0.72),
              ),
            ),
            TextSpan(
              text: value,
              style: TextStyle(color: valueColor ?? cs.onSurface),
            ),
          ],
        ),
        style: const TextStyle(fontSize: 13, height: 1.35),
      ),
    );
  }
}
