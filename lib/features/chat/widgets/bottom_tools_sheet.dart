import '../utils/prompt_injection_selection.dart';
import '../../group_chat/widgets/group_member_strip.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/skills_binding.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/haptics.dart';
import '../../../core/services/proactive_care_alarm_service.dart';
import '../../../core/services/skills/skills_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/world_book_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../home/widgets/conversation_proactive_care_sheet.dart';
import '../../home/widgets/instruction_injection_sheet.dart';
import '../../home/widgets/world_book_sheet.dart';
import '../../instruction_injection/pages/instruction_injection_page.dart';
import '../../world_book/pages/world_book_page.dart';
import '../../model/widgets/ocr_prompt_sheet.dart';
import '../../workspace/pages/skills_page.dart';
import '../../workspace/widgets/skills/conversation_skills_sheet.dart';
import '../utils/ensure_conversation.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../theme/app_font_weights.dart';
import 'tools_sheet_row.dart';
import '../../browser/browser_navigation.dart';

/// Row that opens the session skills picker, and pushes the skills library on
/// a long press.
const Key sessionSkillsKey = ValueKey<String>('bottom-tools-session-skills');

class BottomToolsSheet extends StatelessWidget {
  const BottomToolsSheet({
    super.key,
    this.onCamera,
    this.onPhotos,
    this.onUpload,
    this.onClear,
    this.clearLabel,
    this.assistantId,
    this.conversationId,
    this.onClose,
    this.members,
  });

  final VoidCallback? onCamera;
  final VoidCallback? onPhotos;
  final VoidCallback? onUpload;
  final VoidCallback? onClear;
  final String? clearLabel;
  final String? assistantId;
  final String? conversationId;
  final VoidCallback? onClose;

  /// Non-null in a group chat: the roster the panel's assistant-scoped rows
  /// (skills, instruction injection, world book) edit. Without it those rows
  /// keep following [assistantId], which is what a 1:1 chat means.
  final List<Assistant>? members;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final bg = context.overlaySurface;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;

    Widget roundedAction({
      required IconData icon,
      required String label,
      VoidCallback? onTap,
    }) {
      final cardColor = sheetTileColor(context);
      return Expanded(
        child: SizedBox(
          height: 72,
          child: IosCardPress(
            baseColor: cardColor,
            borderRadius: BorderRadius.circular(14),
            pressedScale: 0.98,
            duration: const Duration(milliseconds: 260),
            onTap: () {
              Haptics.light();
              onTap?.call();
            },
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 24,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  const SizedBox(height: 6),
                  Text(label, style: const TextStyle(fontSize: 13)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
          ),
          boxShadow: [
            BoxShadow(
              color: Theme.of(
                context,
              ).colorScheme.shadow.withValues(alpha: 0.06),
              blurRadius: 20,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ..._attachmentActions(
                      l10n: l10n,
                      roundedAction: roundedAction,
                    ),
                    ToolsSheetRow(
                      key: const ValueKey('bottom-tools-browser'),
                      icon: Lucide.AppWindow,
                      label: l10n.browserTitle,
                      onTap: () {
                        final navigatorContext = Navigator.of(context).context;
                        onClose?.call();
                        unawaited(
                          openBrowserPage(
                            navigatorContext,
                            conversationId: conversationId,
                            assistantId: assistantId,
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    _LearningAndClearSection(
                      clearLabel: clearLabel,
                      onClear: onClear,
                      assistantId: assistantId,
                      conversationId: conversationId,
                      onClose: onClose,
                      members: members,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _attachmentActions({
    required AppLocalizations l10n,
    required Widget Function({
      required IconData icon,
      required String label,
      VoidCallback? onTap,
    })
    roundedAction,
  }) {
    final actions = <Widget>[
      if (onCamera != null)
        roundedAction(
          icon: Lucide.Camera,
          label: l10n.bottomToolsSheetCamera,
          onTap: onCamera,
        ),
      if (onPhotos != null)
        roundedAction(
          icon: Lucide.Image,
          label: l10n.bottomToolsSheetPhotos,
          onTap: onPhotos,
        ),
      if (onUpload != null)
        roundedAction(
          icon: Lucide.Paperclip,
          label: l10n.bottomToolsSheetUpload,
          onTap: onUpload,
        ),
    ];
    if (actions.isEmpty) return const [];
    return [
      Row(
        children: [
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            actions[i],
          ],
        ],
      ),
      const SizedBox(height: 12),
    ];
  }
}

class _LearningAndClearSection extends StatefulWidget {
  const _LearningAndClearSection({
    this.onClear,
    this.clearLabel,
    this.assistantId,
    this.conversationId,
    this.onClose,
    this.members,
  });
  final VoidCallback? onClear;
  final String? clearLabel;
  final String? assistantId;
  final String? conversationId;
  final VoidCallback? onClose;
  final List<Assistant>? members;

  @override
  State<_LearningAndClearSection> createState() =>
      _LearningAndClearSectionState();
}

class _LearningAndClearSectionState extends State<_LearningAndClearSection> {
  String? _promptConversationId;
  String? _selectedAssistantId;

  Future<String?> _promptScopeId() async {
    if (_assistant()?.allowConversationPromptInjection != true) return null;
    return _promptConversationId ??= await ensureConversationId(
      context,
      conversationId: widget.conversationId,
      assistantId: widget.assistantId,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await Future.wait([
        context.read<WorldBookProvider>().initialize(),
        context.read<InstructionInjectionProvider>().initialize(),
      ]);
    });
  }

  /// The member the strip starts on: the composer's own assistant when it is one
  /// of them, so the counts the panel opens with belong to whoever the user is
  /// on rather than to whoever happens to be first in the roster.
  String? get _initialMemberId {
    final members = widget.members;
    if (members == null || members.isEmpty) return null;
    final preferred = widget.assistantId;
    if (preferred != null && members.any((member) => member.id == preferred)) {
      return preferred;
    }
    return members.first.id;
  }

  Assistant? _assistant({bool listen = false}) {
    try {
      final provider = Provider.of<AssistantProvider>(context, listen: listen);
      final members = widget.members;
      if (members != null && members.isNotEmpty) {
        final id = _selectedAssistantId ?? _initialMemberId;
        return provider.getById(id!) ?? members.first;
      }
      final id = widget.assistantId;
      if (id != null) return provider.getById(id);
      return provider.currentAssistant;
    } catch (_) {
      return null;
    }
  }

  /// The assistant the three assistant-scoped rows write to: the member the
  /// strip selects in a group, and [widget.assistantId] otherwise.
  String? get _targetAssistantId {
    final members = widget.members;
    if (members != null && members.isNotEmpty) {
      return _selectedAssistantId ?? _initialMemberId;
    }
    return widget.assistantId;
  }

  Future<void> _openSessionSkills() async {
    Haptics.light();
    final id = await ensureConversationId(
      context,
      conversationId: _promptConversationId ?? widget.conversationId,
      assistantId: widget.assistantId,
    );
    if (id == null || !mounted) return;
    _promptConversationId = id;
    await showConversationSkillsSheet(
      context,
      conversationId: id,
      assistant: _assistant(),
      // The member strip above the row makes it that member's list, not the
      // roster's shared conversation override.
      scopeToAssistant: widget.members != null,
    );
  }

  /// Proactive care is arranged for the conversation's own assistant, which a
  /// group topic does not carry — the row would open nothing there. A
  /// conversation that does not exist yet is created on tap, so it still counts
  /// as available.
  bool _careSpeaksForTheConversation() {
    final id = _promptConversationId ?? widget.conversationId;
    if (id == null) return true;
    try {
      final conversation = context.read<ChatService>().getConversation(id);
      return conversation != null && conversation.assistantId != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openProactiveCare() async {
    Haptics.light();
    final assistant = _assistant();
    if (assistant == null) return;
    final id = await ensureConversationId(
      context,
      conversationId: _promptConversationId ?? widget.conversationId,
      assistantId: widget.assistantId,
    );
    if (id == null || !mounted) return;
    _promptConversationId = id;
    final chat = context.read<ChatService>();
    final conversation = chat.getConversation(id);
    if (conversation == null || conversation.assistantId == null) return;
    await showConversationProactiveCare(
      context,
      conversation: conversation,
      assistant: assistant,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    final worldBookProvider = context.watch<WorldBookProvider>();
    final injections = context.watch<InstructionInjectionProvider>();
    final skills = context.watch<SkillsService>();
    final chat = context.watch<ChatService>();
    final assistant = _assistant(listen: true);
    final hasOcrModel =
        settings.ocrModelProvider != null && settings.ocrModelId != null;
    final hasWorldBooks = worldBookProvider.books.isNotEmpty;
    final scoped = assistant?.allowConversationPromptInjection == true;
    final scopeId = _promptConversationId ?? widget.conversationId;
    Set<String> activeIds(PromptSelectionKind kind) => scoped && scopeId == null
        ? <String>{}
        : promptSelectionIds(
            context,
            kind: kind,
            assistantId: _targetAssistantId,
            conversationId: scoped ? scopeId : null,
          ).toSet();
    final activeWorldBookIds = activeIds(PromptSelectionKind.worldBook);
    final enabledWorldBookCount = worldBookProvider.books
        .where((book) => book.enabled && activeWorldBookIds.contains(book.id))
        .length;
    final activeInstructionIds = activeIds(PromptSelectionKind.instruction);
    final enabledInstructionCount = injections.items
        .where((item) => activeInstructionIds.contains(item.id))
        .length;
    final skillBinding = SkillsBinding.fromExtras(
      scopeId == null
          ? const {}
          : chat.getConversation(scopeId)?.extras ?? const {},
    );
    final enabledSkillCount = skills
        .resolveForAssistant(
          assistant,
          conversationOverride: skillBinding.skillIds,
        )
        .length;
    final chevron = ToolsSheetRow.chevron(context);
    Widget selectionTrailing(int enabled, int total) => enabled == 0
        ? chevron
        : Text(
            '$enabled/$total',
            style: TextStyle(
              fontSize: 13,
              fontWeight: AppFontWeights.medium,
              color: Theme.of(context).colorScheme.primary,
            ),
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.members case final members? when members.length > 1) ...[
          // No value on these chips: this strip scopes three rows with three
          // different numbers, and one chip cannot carry all three. The panels
          // that scope a single capability carry its count instead.
          GroupMemberStrip(
            members: members,
            selectedId: _targetAssistantId ?? members.first.id,
            onSelect: (member) =>
                setState(() => _selectedAssistantId = member.id),
          ),
          const SizedBox(height: 10),
        ],
        ToolsSheetRow(
          key: sessionSkillsKey,
          icon: Lucide.WandSparkles,
          label: l10n.workspaceEntrySessionSkills,
          onTap: () => unawaited(_openSessionSkills()),
          onLongPress: () {
            Haptics.light();
            final rootNav = Navigator.of(context, rootNavigator: true);
            Navigator.of(context).maybePop();
            Future.microtask(() {
              if (!rootNav.mounted) return;
              unawaited(openSkillsPage(rootNav.context));
            });
          },
          trailing: selectionTrailing(enabledSkillCount, skills.skills.length),
        ),
        const SizedBox(height: 8),
        ToolsSheetRow(
          icon: Lucide.Layers,
          label: l10n.instructionInjectionTitle,
          onTap: () async {
            Haptics.light();
            final scoped =
                _assistant()?.allowConversationPromptInjection == true;
            final scopeId = await _promptScopeId();
            if (!context.mounted || (scoped && scopeId == null)) return;
            await showInstructionInjectionSheet(
              context,
              assistantId: _targetAssistantId,
              conversationId: scopeId,
            );
          },
          onLongPress: () {
            Haptics.light();
            final rootNav = Navigator.of(context, rootNavigator: true);
            Navigator.of(context).maybePop();
            Future.microtask(() {
              rootNav.push(
                MaterialPageRoute(
                  builder: (_) => const InstructionInjectionPage(),
                ),
              );
            });
          },
          trailing: selectionTrailing(
            enabledInstructionCount,
            injections.items.length,
          ),
        ),
        if (hasWorldBooks) ...[
          const SizedBox(height: 8),
          ToolsSheetRow(
            icon: Lucide.BookOpen,
            label: l10n.worldBookTitle,
            onTap: () async {
              Haptics.light();
              final scoped =
                  _assistant()?.allowConversationPromptInjection == true;
              final scopeId = await _promptScopeId();
              if (!context.mounted || (scoped && scopeId == null)) return;
              await showWorldBookSheet(
                context,
                assistantId: _targetAssistantId,
                conversationId: scopeId,
              );
            },
            onLongPress: () {
              Haptics.light();
              final rootNav = Navigator.of(context, rootNavigator: true);
              Navigator.of(context).maybePop();
              Future.microtask(() {
                rootNav.push(
                  MaterialPageRoute(builder: (_) => const WorldBookPage()),
                );
              });
            },
            trailing: selectionTrailing(
              enabledWorldBookCount,
              worldBookProvider.books.length,
            ),
          ),
        ],
        // The strip scopes the three rows above it and nothing else: below this
        // line the rows belong to the conversation, not to the selected member.
        if (widget.members case final members? when members.length > 1) ...[
          const SizedBox(height: 10),
          Divider(
            height: 1,
            thickness: 1,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.08),
          ),
          const SizedBox(height: 2),
        ],
        if (hasOcrModel) ...[
          const SizedBox(height: 8),
          ToolsSheetRow(
            icon: Lucide.Eye,
            label: l10n.bottomToolsSheetOcr,
            selected: settings.ocrEnabled,
            onTap: () async {
              Haptics.light();
              final sp = context.read<SettingsProvider>();
              await sp.setOcrEnabled(!sp.ocrEnabled);
              if (!context.mounted) return;
              Navigator.of(context).maybePop();
            },
            onLongPress: () => showOcrPromptSheet(context),
          ),
        ],
        const SizedBox(height: 8),
        ToolsSheetRow(
          icon: Lucide.workflow,
          label: l10n.contextManagement,
          onTap: () {
            Haptics.light();
            widget.onClear?.call();
          },
          trailing: chevron,
        ),
        if (ProactiveCareAlarmService.isSupported &&
            _assistant(listen: true) != null &&
            _careSpeaksForTheConversation()) ...[
          const SizedBox(height: 8),
          ToolsSheetRow(
            key: const ValueKey<String>('bottom-tools-proactive-care'),
            icon: Lucide.HeartPulse,
            label: l10n.conversationProactiveCareTitle,
            onTap: () => unawaited(_openProactiveCare()),
            trailing: chevron,
          ),
        ],
      ],
    );
  }
}
