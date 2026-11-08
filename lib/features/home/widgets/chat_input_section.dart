import 'package:Cuplivo/features/chat/utils/prompt_injection_selection.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/chat_input_data.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/conversation_mcp_settings.dart';
import '../../../core/models/conversation.dart';
import '../../../core/services/api/reasoning/reasoning_level_options.dart';
import '../../../core/services/api/reasoning/reasoning_dialects.dart';
import '../../../core/services/api/reasoning/reasoning_selection.dart';
import '../../../core/services/model_spec/model_spec_resolver.dart';
import '../../../core/models/workspace_binding.dart';
import '../../../core/models/skills_binding.dart';
import '../../../core/providers/asr_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/quick_phrase_provider.dart';
import '../../../core/providers/world_book_provider.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/skills/skills_service.dart';
import '../../../features/workspace/widgets/environment/environment_status_chip.dart';
import '../../../features/workspace/workspace_navigation.dart';
import '../../../theme/design_tokens.dart';
import 'chat_input_bar.dart';
import 'model_icon.dart';
import '../../../core/models/group_chat.dart';
import '../../group_chat/widgets/group_member_cluster.dart';
import '../../group_chat/models/group_quick_entries.dart';
import '../../../l10n/app_localizations.dart';

/// Callback for checking if a model supports tool calling.
typedef IsToolModelCallback = bool Function(String providerKey, String modelId);

/// Callback for checking if a model supports reasoning.
typedef IsReasoningModelCallback =
    bool Function(String providerKey, String modelId);

/// Callback for checking if reasoning is enabled.
typedef IsReasoningEnabledCallback = bool Function(ReasoningRequest request);

/// Widget that wraps ChatInputBar with all the necessary logic and callbacks.
///
/// This widget extracts the _buildChatInputBar logic from HomePageState
/// to reduce coupling and improve maintainability.
class ChatInputSection extends StatelessWidget {
  const ChatInputSection({
    super.key,
    required this.inputBarKey,
    this.chatModelProviderKey,
    this.chatModelId,
    this.chatModelIsConversationOverride = false,
    required this.inputFocus,
    required this.inputController,
    required this.mediaController,
    required this.isTablet,
    required this.isLoading,
    required this.isToolModel,
    required this.isReasoningModel,
    required this.isReasoningEnabled,
    this.onMore,
    this.onSelectModel,
    this.onLongPressSelectModel,
    this.onOpenTools,
    this.onLongPressTools,
    this.onOpenWorkspace,
    this.onOpenSkills,
    this.onOpenSearch,
    this.onConfigureReasoning,
    this.onOpenContextUsage,
    this.onSend,
    this.onStop,
    this.hasQueuedInput = false,
    this.queuedPreviewText,
    this.queuedStatusLabel,
    this.queuedSubtitle,
    this.queuedPaused = false,
    this.onCancelQueuedInput,
    this.onExpandedChanged,
    this.onQuickPhrase,
    this.onLongPressQuickPhrase,
    this.onToggleOcr,
    this.onOpenMiniMap,
    this.onPickCamera,
    this.onPickPhotos,
    this.onUploadFiles,
    this.onOpenBrowser,
    this.onToggleLearningMode,
    this.onOpenWorldBook, // 新增世界书支持桌面端
    this.onLongPressLearning,
    this.onClearContext,
    this.onCompressContext,
    this.conversationId,
    this.sendButtonTooltip,
    this.group,
    this.onOpenGroupMembers,
    this.backgroundImageActive = false,
  });

  final GlobalKey inputBarKey;
  final FocusNode inputFocus;
  final TextEditingController inputController;
  final ChatInputBarController mediaController;
  final bool isTablet;
  final bool isLoading;

  // Model capability checkers
  final IsToolModelCallback isToolModel;
  final IsReasoningModelCallback isReasoningModel;
  final IsReasoningEnabledCallback isReasoningEnabled;

  // Callbacks
  final VoidCallback? onMore;
  final VoidCallback? onSelectModel;
  final VoidCallback? onLongPressSelectModel;
  final VoidCallback? onOpenTools;
  final VoidCallback? onLongPressTools;
  final VoidCallback? onOpenWorkspace;
  final VoidCallback? onOpenSkills;
  final VoidCallback? onOpenSearch;
  final VoidCallback? onConfigureReasoning;
  final VoidCallback? onOpenContextUsage;
  final Future<ChatInputSubmissionResult> Function(ChatInputData)? onSend;
  final VoidCallback? onStop;
  final bool hasQueuedInput;
  final String? queuedPreviewText;
  final String? queuedStatusLabel;
  final String? queuedSubtitle;
  final bool queuedPaused;
  final VoidCallback? onCancelQueuedInput;
  final ValueChanged<bool>? onExpandedChanged;
  final VoidCallback? onQuickPhrase;
  final VoidCallback? onLongPressQuickPhrase;
  final VoidCallback? onToggleOcr;
  final VoidCallback? onOpenMiniMap;
  final VoidCallback? onPickCamera;
  final VoidCallback? onPickPhotos;
  final VoidCallback? onUploadFiles;
  final VoidCallback? onOpenBrowser;
  final VoidCallback? onToggleLearningMode;
  final VoidCallback? onOpenWorldBook;
  final VoidCallback? onLongPressLearning;
  final VoidCallback? onClearContext;
  final VoidCallback? onCompressContext;
  final String? conversationId;

  /// The model this conversation sends with, already resolved through
  /// conversation override -> assistant -> global default. Resolved by the
  /// caller because only it holds the Conversation; watching ChatService here
  /// would rebuild the composer on every streaming notification.
  final String? chatModelProviderKey;
  final String? chatModelId;

  /// Whether the resolved model above comes from this conversation's own
  /// override rather than from the assistant.
  ///
  /// Gates the capability enforcement below, which writes to the ASSISTANT: a
  /// model picked for one conversation must not wipe the MCP selection or the
  /// thinking budget shared by every other conversation under that assistant.
  final bool chatModelIsConversationOverride;
  final String? sendButtonTooltip;

  /// Non-null when this conversation belongs to a group chat.
  ///
  /// A group has no single model, no single assistant prompt and no per-chat
  /// search switch: the composer keeps what belongs to the *conversation*
  /// (attachments, browser, mini map, context management and its ring) and drops
  /// what belongs to one assistant. This field decides what a group *has*, never
  /// where it goes: every action a group keeps is offered in the same place the
  /// 1:1 composer offers it.
  ///
  /// The search and reasoning entries are the exception that keeps the 1:1
  /// rule instead of the group one: both already belong to the assistant the
  /// composer is *on* rather than to the conversation, so a group offers them
  /// and they read and write that assistant — the same one a 1:1 chat would.
  /// A group's reply is sent by its speaker, so the button states what the
  /// composer's assistant has, not what the round will do for every member.
  final GroupChat? group;
  final VoidCallback? onOpenGroupMembers;

  final bool backgroundImageActive;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final asr = context.watch<AsrProvider>();
    final ap = context.watch<AssistantProvider>();
    final a = ap.currentAssistant;
    final group = this.group;
    final isGroup = group != null;
    final groupMembers = <Assistant>[
      if (group != null)
        for (final id in group.memberIds)
          if (ap.getById(id) case final assistant?) assistant,
    ];
    // A group has no single model, so the two composed entries report the
    // roster instead of one assistant's value: uniform members show their own
    // value, disagreeing members show the neutral glyph.
    final groupSearch = isGroup
        ? resolveGroupSearch(settings: settings, members: groupMembers)
        : null;
    final groupReasoning = isGroup
        ? resolveGroupReasoning(
            settings: settings,
            members: groupMembers,
            supportsReasoning: isReasoningModel,
          )
        : null;

    // A group sends each reply with its speaker's own model, so there is no
    // single model to report or to reason about here.
    final pk = isGroup ? null : chatModelProviderKey;
    final mid = isGroup ? null : chatModelId;
    // The model the search and reasoning entries speak for. Those two belong to
    // the composer's current assistant in both layouts, so they resolve through
    // the model a 1:1 chat would use — a group included.
    final entryProviderKey = chatModelProviderKey;
    final entryModelId = chatModelId;
    final supportsModelTools =
        pk != null && mid != null && isToolModel(pk, mid);
    final selectedReasoning = _selectedReasoning(
      settings,
      a,
      entryProviderKey,
      entryModelId,
    );
    final reasoningSpec = (entryProviderKey != null && entryModelId != null)
        ? ModelSpecResolver.instance.spec(
            settings.getProviderConfig(entryProviderKey),
            entryModelId,
          )
        : null;
    final effectiveReasoning = reasoningSpec == null
        ? selectedReasoning
        : ReasoningRequest(
            resolveReasoning(reasoningSpec, selectedReasoning).effective,
            budgetTokens: selectedReasoning.budgetTokens,
          );

    // Enforce model capabilities: disable MCP selection if model doesn't
    // support tools. Skip this when model or MCP selection can be scoped to
    // a conversation: these writes would affect the shared assistant defaults.
    if (!chatModelIsConversationOverride && a?.allowConversationMcp != true) {
      _enforceModelCapabilities(context, settings, ap, a, pk, mid);
    }

    final isDesktop = _isDesktopPlatform(context);
    final hasWorldBooks =
        isTablet && context.watch<WorldBookProvider>().books.isNotEmpty;
    final showWorkspaceButton = isDesktop && onOpenWorkspace != null;
    final showEnvChip = !isDesktop && (Platform.isAndroid || Platform.isIOS);
    var workspaceBound = false;
    if (showWorkspaceButton || showEnvChip) {
      workspaceBound = _isWorkspaceBound(context);
    }
    // Where the conversation's tools go. The wide layouts have room for them in
    // the left action bar; a phone does not, so it offers them in the composer's
    // + panel instead, and keeps the mini map in the top bar where it always
    // was. This decision covers these tools and nothing else: search, reasoning,
    // the tools button and quick phrases stay in that bar on every layout.
    // A group used to force the tools into the phone's bar as well, which pushed
    // the row past its width and made the bar's overflow button sit beside the
    // panel's own "+".
    final leftBarTools = isTablet;

    final bar = ChatInputBar(
      key: inputBarKey,
      chatModelProviderKey: pk,
      chatModelId: mid,
      onMore: onMore,
      onSelectModel: isGroup ? null : onSelectModel,
      onLongPressSelectModel: isGroup ? null : onLongPressSelectModel,
      conversationId: conversationId,
      onOpenTools: onOpenTools,
      onLongPressTools: onLongPressTools,
      onOpenWorkspace: onOpenWorkspace,
      showWorkspaceButton: showWorkspaceButton,
      workspaceActive: workspaceBound,
      onOpenSkills: isDesktop && !isGroup ? onOpenSkills : null,
      skillsActive:
          isDesktop && onOpenSkills != null && _isSkillsActive(context, a),
      onStop: onStop,
      leading: isGroup
          ? GroupMemberCluster(members: groupMembers, onTap: onOpenGroupMembers)
          : null,
      onTapLeading: onOpenGroupMembers,
      leadingTooltip: AppLocalizations.of(context)!.groupChatMembers,
      leadingExtent: isGroup
          ? GroupMemberCluster.extentFor(groupMembers.length)
          : 30,
      modelIcon: (pk != null && mid != null)
          ? CurrentModelIcon(
              providerKey: pk,
              modelId: mid,
              size: 40,
              withBackground: true,
              backgroundColor: Colors.transparent,
            )
          : null,
      focusNode: inputFocus,
      controller: inputController,
      mediaController: mediaController,
      asrProvider: asr,
      onConfigureReasoning: onConfigureReasoning,
      onOpenContextUsage: onOpenContextUsage,
      reasoningActive:
          groupReasoning?.anyActive ?? isReasoningEnabled(effectiveReasoning),
      reasoning: groupReasoning != null
          ? groupReasoning.request
          : effectiveReasoning,
      reasoningCustomBudget: groupReasoning != null
          ? false
          : reasoningSpec != null
          ? isCustomBudgetSelection(reasoningSpec, selectedReasoning)
          : false,
      supportsReasoning: groupReasoning != null
          ? groupReasoning.anySupported
          : (entryProviderKey != null && entryModelId != null)
          ? isReasoningModel(entryProviderKey, entryModelId)
          : false,
      groupSearch: groupSearch,
      groupReasoning: groupReasoning,
      onOpenSearch: onOpenSearch,
      onSend: onSend,
      loading: isLoading,
      sendButtonTooltip: sendButtonTooltip,
      hasQueuedInput: hasQueuedInput,
      queuedPreviewText: queuedPreviewText,
      queuedStatusLabel: queuedStatusLabel,
      queuedSubtitle: queuedSubtitle,
      queuedPaused: queuedPaused,
      onCancelQueuedInput: onCancelQueuedInput,
      onExpandedChanged: onExpandedChanged,
      showToolsButton: isGroup ? true : supportsModelTools,
      toolsActive: isGroup
          ? _groupToolsActive(context, groupMembers, workspaceBound)
          : supportsModelTools && _isToolsActive(context, a, workspaceBound),
      // The quick-phrase list is a union, so a group offers the entry as soon as
      // any member has a phrase — and never in a "lit" state, exactly as the
      // 1:1 entry behaves.
      showQuickPhraseButton: isGroup
          ? _groupHasQuickPhrases(context, groupMembers)
          : _hasQuickPhrases(context, a),
      onQuickPhrase: onQuickPhrase,
      onLongPressQuickPhrase: onLongPressQuickPhrase,
      // OCR button: show on desktop for mobile layout, always check settings for tablet layout
      showOcrButton: isGroup
          ? false
          : isTablet
          ? (settings.ocrModelProvider != null && settings.ocrModelId != null)
          : (isDesktop &&
                settings.ocrModelProvider != null &&
                settings.ocrModelId != null),
      ocrActive: settings.ocrEnabled,
      onToggleOcr: isGroup ? null : onToggleOcr,
      showMiniMapButton: leftBarTools,
      onOpenMiniMap: leftBarTools ? onOpenMiniMap : null,
      onPickCamera: leftBarTools ? (isDesktop ? null : onPickCamera) : null,
      onPickPhotos: leftBarTools ? (isDesktop ? null : onPickPhotos) : null,
      onUploadFiles: leftBarTools ? onUploadFiles : null,
      onOpenBrowser: leftBarTools ? onOpenBrowser : null,
      onToggleLearningMode: isGroup || !isTablet ? null : onToggleLearningMode,
      onOpenWorldBook: hasWorldBooks && !isGroup ? onOpenWorldBook : null,
      onLongPressLearning: isGroup || !isTablet ? null : onLongPressLearning,
      learningModeActive:
          !isGroup &&
          isTablet &&
          _isPromptSelectionActive(context, a, PromptSelectionKind.instruction),
      worldBookActive:
          !isGroup &&
          isTablet &&
          _isPromptSelectionActive(context, a, PromptSelectionKind.worldBook),
      showMoreButton: !isTablet,
      onClearContext: leftBarTools ? onClearContext : null,
      onCompressContext: leftBarTools ? onCompressContext : null,
      backgroundImageActive: backgroundImageActive,
      inputBackgroundOpacityLight: settings.chatInputBackgroundOpacityLight,
      inputBackgroundOpacityDark: settings.chatInputBackgroundOpacityDark,
    );

    if (!showEnvChip || !workspaceBound) return bar;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showEnvChip && workspaceBound)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.sm,
              AppSpacing.xxs,
              AppSpacing.sm,
              0,
            ),
            child: EnvironmentStatusChip(
              onTap: () => WorkspaceNavigation.openEnvironmentPage(context),
            ),
          ),
        Flexible(child: bar),
      ],
    );
  }

  bool _isPromptSelectionActive(
    BuildContext context,
    Assistant? assistant,
    PromptSelectionKind kind,
  ) {
    final scoped = assistant?.allowConversationPromptInjection == true;
    if (scoped && conversationId == null) return false;
    final ids = promptSelectionIds(
      context,
      kind: kind,
      assistantId: assistant?.id,
      conversationId: scoped ? conversationId : null,
    ).toSet();
    return kind == PromptSelectionKind.worldBook
        ? context.watch<WorldBookProvider>().books.any(
            (book) => book.enabled && ids.contains(book.id),
          )
        : context.watch<InstructionInjectionProvider>().items.any(
            (item) => ids.contains(item.id),
          );
  }

  bool _isSkillsActive(BuildContext context, Assistant? assistant) {
    final skillIds = context.select<ChatService?, List<String>?>((chat) {
      final extras = chat?.getConversation(conversationId ?? '')?.extras;
      return SkillsBinding.fromExtras(extras ?? const {}).skillIds;
    });
    return context.select<SkillsService?, bool>(
      (skills) =>
          skills
              ?.resolveForAssistant(assistant, conversationOverride: skillIds)
              .isNotEmpty ??
          false,
    );
  }

  bool _isWorkspaceBound(BuildContext context) {
    try {
      return context.select<ChatService, bool>((chat) {
        final id = conversationId;
        if (id == null) return false;
        final conversation = chat.getConversation(id);
        if (conversation == null) return false;
        return WorkspaceBinding.fromExtras(conversation.extras).isBound;
      });
    } catch (_) {
      return false;
    }
  }

  bool _isDesktopPlatform(BuildContext context) {
    final platform = Theme.of(context).platform;
    return platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux;
  }

  void _enforceModelCapabilities(
    BuildContext context,
    SettingsProvider settings,
    AssistantProvider ap,
    Assistant? a,
    String? pk,
    String? mid,
  ) {
    if (pk == null || mid == null) return;

    final supportsTools = isToolModel(pk, mid);
    if (!supportsTools && (a?.mcpServerIds.isNotEmpty ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final aa = ap.currentAssistant;
        if (aa != null && aa.mcpServerIds.isNotEmpty) {
          ap.updateAssistant(aa.copyWith(mcpServerIds: const <String>[]));
        }
      });
    }
  }

  ReasoningRequest _selectedReasoning(
    SettingsProvider settings,
    Assistant? assistant,
    String? providerKey,
    String? modelId,
  ) {
    if (providerKey == null || modelId == null) {
      return assistant?.reasoning ?? ReasoningRequest.auto;
    }
    return selectReasoningRequest(
      settings: settings,
      config: settings.getProviderConfig(providerKey),
      modelId: modelId,
      assistant: assistant,
    );
  }

  bool _isToolsActive(BuildContext context, Assistant? a, bool workspaceBound) {
    if (workspaceBound) return true;
    if ((a?.localToolIds ?? const <String>[]).isNotEmpty) return true;
    final connected = context.watch<McpProvider>().connectedServers;
    final selected = a?.allowConversationMcp == true && conversationId != null
        ? context.select<ChatService, List<String>>(
            (chat) => ConversationMcpSettings.effectiveServerIds(
              a,
              chat.getConversation(conversationId!),
            ),
          )
        : a?.mcpServerIds ?? const <String>[];
    if (selected.isEmpty || connected.isEmpty) return false;
    return connected.any((s) => selected.contains(s.id));
  }

  bool _hasQuickPhrases(BuildContext context, Assistant? a) {
    final quickPhraseProvider = context.watch<QuickPhraseProvider>();
    final globalCount = quickPhraseProvider.globalPhrases.length;
    final assistantCount = a != null
        ? quickPhraseProvider.getForAssistant(a.id).length
        : 0;
    return (globalCount + assistantCount) > 0;
  }

  /// Union over the roster: the quick-phrase entry exists when any member
  /// offers one, global phrases included.
  bool _groupHasQuickPhrases(BuildContext context, List<Assistant> members) {
    final quickPhraseProvider = context.watch<QuickPhraseProvider>();
    if (quickPhraseProvider.globalPhrases.isNotEmpty) return true;
    return members.any(
      (member) => quickPhraseProvider.getForAssistant(member.id).isNotEmpty,
    );
  }

  /// Any member that brings tools of its own: local tools, or an MCP server
  /// that is actually connected. The conversation's own MCP override counts for
  /// every member that allows it (a group panel can set it), so this reads the
  /// same rule [\_isToolsActive] reads rather than only the member's defaults.
  bool _groupToolsActive(
    BuildContext context,
    List<Assistant> members,
    bool workspaceBound,
  ) {
    if (workspaceBound) return true;
    final connected = context.watch<McpProvider>().connectedServers;
    final conversation = conversationId == null
        ? null
        : context.select<ChatService?, Conversation?>(
            (chat) => chat?.getConversation(conversationId!),
          );
    for (final member in members) {
      if (member.localToolIds.isNotEmpty) return true;
      final selected = ConversationMcpSettings.effectiveServerIds(
        member,
        conversation,
      );
      if (selected.isNotEmpty &&
          connected.any((s) => selected.contains(s.id))) {
        return true;
      }
    }
    return false;
  }
}
