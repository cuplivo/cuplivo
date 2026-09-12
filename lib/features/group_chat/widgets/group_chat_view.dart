import 'package:Cuplivo/core/database/business_preferences.dart';
import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/providers/asr_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../../core/providers/quick_instruction_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/generation_engine.dart';
import '../../../desktop/message_edit_dialog.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../chat/models/message_edit_result.dart';
import '../../chat/widgets/message_edit_sheet.dart';
import '../../chat/widgets/message_more_sheet.dart';
import '../../home/controllers/chat_controller.dart';
import '../../home/controllers/generation_controller.dart';
import '../../home/controllers/home_view_model.dart';
import '../../home/controllers/stream_controller.dart' as stream_ctrl;
import '../../home/services/ask_user_interaction_service.dart';
import '../../home/services/file_upload_service.dart';
import '../../home/services/message_builder_service.dart';
import '../../home/services/message_generation_service.dart';
import '../../home/services/ocr_service.dart';
import '../../home/services/tool_approval_service.dart';
import '../../home/widgets/chat_input_bar.dart';
import '../../home/widgets/instruction_injection_sheet.dart';
import '../../home/widgets/message_list_view.dart';
import '../../instruction_injection/pages/instruction_injection_page.dart';
import '../controllers/group_chat_orchestrator.dart';
import '../models/chat_input_mode.dart';
import '../services/group_chat_slot_runner.dart';

/// Shell-agnostic group chat content: message list + input bar + the
/// orchestrator state that drives a group round.
///
/// Hosts:
/// - Mobile: [GroupChatPage] wraps it in a Scaffold + AppBar.
/// - Desktop: embedded into the Chat tab content slot (see
///   HomePage._buildTabletLayout) instead of pushing a full-window route,
///   so the desktop shell (nav rail / window title bar) stays consistent.
class GroupChatView extends StatefulWidget {
  const GroupChatView({
    super.key,
    required this.groupChatId,
    this.inputFocusNode,
  });

  final String groupChatId;

  /// Optional externally-owned focus node for the composer. The desktop
  /// Chat slot passes the controller-owned node so hotkeys (focusInput) can
  /// target the composer of the hidden-but-mounted group view. When null an
  /// internal node is created (mobile route usage).
  final FocusNode? inputFocusNode;

  @override
  State<GroupChatView> createState() => _GroupChatViewState();
}

class _GroupChatViewState extends State<GroupChatView> {
  final _inputController = TextEditingController();
  final _mediaController = ChatInputBarController();
  final _inputBarKey = GlobalKey();
  final _scrollController = ScrollController();
  FocusNode? _ownInputFocus;
  final _isProcessingFiles = ValueNotifier<bool>(false);
  final _translations = <String, TranslationUiState>{};

  FocusNode get _inputFocus => widget.inputFocusNode ?? _ownInputFocus!;

  late ListController _listController;
  late ChatService _chatService;
  late stream_ctrl.StreamController _streamController;
  late ChatController _chatController;
  late MessageBuilderService _messageBuilderService;
  late GenerationController _generationController;
  late MessageGenerationService _messageGenerationService;
  late GroupChatSlotRunner _slotRunner;
  late GroupChatOrchestrator _orchestrator;
  late FileUploadService _fileUploadService;
  late OcrService _ocrService;
  late GroupChatProvider _groupChatProvider;

  bool _loading = false;
  bool _initialized = false;

  /// One-slot pending send while a round is running (mirrors single-chat
  /// per-conversation queue semantics — see queueIfCurrentConversationBusy).
  /// Drained by [_maybeDrainQueue] when the round ends.
  ChatInputData? _queuedInput;

  /// Coalesces provider notifications into one post-frame stash pickup.
  bool _stashPickupScheduled = false;

  bool get _isDesktop =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  @override
  void initState() {
    super.initState();
    if (widget.inputFocusNode == null) {
      _ownInputFocus = FocusNode();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _groupChatProvider = context.read<GroupChatProvider>();
    _listController = ListController();
    _chatService = context.read<ChatService>();
    _ocrService = OcrService(chatService: _chatService);
    _fileUploadService = FileUploadService(
      getContext: () => context,
      mediaController: _mediaController,
      preferences: context.read<BusinessPreferences>(),
    );
    _streamController = stream_ctrl.StreamController(
      chatService: _chatService,
      onStateChanged: () {
        if (mounted) {
          _refreshList();
          setState(() {});
        }
      },
      getSettingsProvider: () => context.read<SettingsProvider>(),
      getCurrentConversationId: () {
        final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
        return g?.conversationId;
      },
    );
    _chatController = ChatController(chatService: _chatService);
    _chatController.addListener(_onChatControllerChanged);
    _messageBuilderService = MessageBuilderService(
      chatService: _chatService,
      contextProvider: context,
      preferences: context.read<BusinessPreferences>(),
      ocrHandler: (imagePaths, {requestId}) => _ocrService.getOcrTextForImages(
        imagePaths,
        context,
        requestId: requestId,
      ),
    );
    _messageBuilderService.ocrTextWrapper = _ocrService.wrapOcrBlock;
    _generationController = GenerationController(
      chatService: _chatService,
      chatController: _chatController,
      streamController: _streamController,
      messageBuilderService: _messageBuilderService,
      contextProvider: context,
      onStateChanged: () {
        if (mounted) setState(() {});
      },
      getTitleForLocale: (ctx) =>
          AppLocalizations.of(ctx)!.groupChatDefaultName,
    );
    _messageGenerationService = MessageGenerationService(
      chatService: _chatService,
      messageBuilderService: _messageBuilderService,
      generationController: _generationController,
      streamController: _streamController,
      contextProvider: context,
    );
    _slotRunner = GroupChatSlotRunner(
      engine: context.read<GenerationEngine>(),
      streamController: _streamController,
      onTruncationWarning: (reason) {
        if (!mounted) return;
        final l10n = AppLocalizations.of(context)!;
        final reasonText = reason == 'max_tokens'
            ? l10n.truncationReasonMaxTokens
            : l10n.truncationReasonContextExceeded;
        showAppSnackBar(
          context,
          message: l10n.responseTruncated(reasonText),
          type: NotificationType.warning,
          duration: const Duration(seconds: 30),
        );
      },
    );
    _orchestrator = GroupChatOrchestrator(
      chatService: _chatService,
      groupChatProvider: context.read<GroupChatProvider>(),
      assistantProvider: context.read<AssistantProvider>(),
      settingsProvider: context.read<SettingsProvider>(),
      userProvider: context.read<UserProvider>(),
      streamController: _streamController,
      generationController: _generationController,
      messageGenerationService: _messageGenerationService,
      slotRunner: _slotRunner,
      approvalService: context.read<ToolApprovalService>(),
      askUserService: context.read<AskUserInteractionService>(),
      onUiFeedback: _onUiFeedback,
      onMessagesChanged: () {
        if (mounted) {
          _refreshList();
          setState(() {});
        }
      },
    );
    _bindConversation();
    _takeStashedQueuedInput();
    _groupChatProvider.addListener(_onGroupChatProviderChanged);
  }

  void _onChatControllerChanged() {
    if (mounted) setState(() {});
  }

  void _bindConversation() {
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return;
    final convo = _chatService.getConversation(g.conversationId);
    if (convo != null) {
      _chatController.setCurrentConversation(convo);
    }
    // Restore per-message UI state (reasoning panels, tool events, content
    // splits, Gemini thought signatures, translation markers) exactly like
    // normal chat does via home_view_model._restoreMessageUiState. This hook
    // is _bindConversation (NOT _refreshList; the latter must not clobber
    // live streaming state after send/regenerate).
    _restoreMessageUiState();
  }

  void _restoreMessageUiState() {
    final messages = _chatController.messages;
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (m.role == 'assistant') {
        _streamController.restoreMessageUiState(
          m,
          getToolEventsFromDb: (id) => _chatService.getToolEvents(id),
          getGeminiThoughtSigFromDb: (id) =>
              _chatService.getGeminiThoughtSignature(id),
        );
        final cleanedContent = _streamController.captureGeminiThoughtSignature(
          m.content,
          m.id,
        );
        if (cleanedContent != m.content) {
          final updated = m.copyWith(content: cleanedContent);
          messages[i] = updated;
          unawaited(_chatService.updateMessage(m.id, content: cleanedContent));
        }
      }
      if (m.translation != null && m.translation!.isNotEmpty) {
        _translations[m.id] = const TranslationUiState(expanded: false);
      }
    }
  }

  /// Persist a manual expand/collapse of a thinking step so it survives
  /// reload/switch/sync (parity with HomePageController). Only settled
  /// (non-streaming) messages are written — the engine owns live segment state.
  void _persistReasoningToggle(String messageId) {
    final index = _chatController.messages.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    if (_chatController.messages[index].isStreaming) return;
    final payload = _streamController.buildReasoningSegmentsJson(messageId);
    if (payload == null) return;
    _chatController.replaceMessage(
      _chatController.messages[index].copyWith(reasoningSegmentsJson: payload),
    );
    unawaited(_streamController.persistReasoningSegments(messageId, payload));
  }

  void _refreshList() {
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return;
    final convo = _chatService.getConversation(g.conversationId);
    if (convo != null) {
      _chatController.updateCurrentConversation(convo);
    }
    _chatController.loadVersionSelections();
    _chatController.reloadMessages();
  }

  void _onUiFeedback(String key) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final map = <String, String>{
      'groupChatNoAssistants': l10n.groupChatNoAssistants,
      'groupChatNoDirectorModel': l10n.groupChatNoDirectorModel,
      'groupChatDirectorModelNoTools': l10n.groupChatDirectorModelNoTools,
      'groupChatDirectorTimeout': l10n.groupChatDirectorTimeout,
      'groupChatDirectorError': l10n.groupChatDirectorError,
      'groupChatAssistantNoModel': l10n.groupChatAssistantNoModel,
    };
    showAppSnackBar(context, message: map[key] ?? key);
  }

  @override
  void dispose() {
    // Session-level queue handoff: a queued send must not die with the page.
    // Stash it for the next GroupChatView instance of this group (mobile
    // route pop; a mounted successor picks it up via the provider
    // notification). The getById guard is the actual protection: desktop
    // keep-alive views dispose only when their group is deleted, and by then
    // getById is null, so nothing is re-stashed for a dead group.
    // (deleteGroup only clears entries stashed before the deletion.)
    _groupChatProvider.removeListener(_onGroupChatProviderChanged);
    if (_queuedInput != null &&
        _groupChatProvider.getById(widget.groupChatId) != null) {
      _groupChatProvider.stashQueuedInput(widget.groupChatId, _queuedInput!);
    }
    _orchestrator.requestStop();
    _streamController.dispose();
    _chatController.removeListener(_onChatControllerChanged);
    _chatController.dispose();
    _isProcessingFiles.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    _listController.dispose();
    _ownInputFocus?.dispose();
    super.dispose();
  }

  Future<void> _send(ChatInputData data) async {
    final text = data.text.trim();
    if (text.isEmpty && data.imagePaths.isEmpty && data.documents.isEmpty) {
      return;
    }
    final gp = context.read<GroupChatProvider>();
    final group = gp.getById(widget.groupChatId);
    if (group == null) return;

    setState(() => _loading = true);
    try {
      final userMsg = await _messageGenerationService.createUserMessage(
        conversationId: group.conversationId,
        input: data,
        assistant: null,
      );
      await gp.touchUpdatedAt(group.id);
      _refreshList();
      setState(() {});
      await _orchestrator.handleUserMessage(
        group: group,
        userMessage: userMsg,
        inputData: data,
      );
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
        _refreshList();
      }
      _maybeDrainQueue();
    }
  }

  /// Fires the queued send (if any) once the current round has fully ended.
  /// Mirrors the single-chat drain hook (_onLoadingChanged). Calls [_send]
  /// which re-set [_loading] synchronously, so the queue slot can never
  /// double-drain.
  void _maybeDrainQueue() {
    if (!mounted) return;
    if (_loading || _orchestrator.isBusy) return;
    final q = _queuedInput;
    if (q == null) {
      // Idle with an empty local slot: a session-level stash may have
      // arrived after mount (the previous view's dispose can land after
      // this one mounted during the pop animation) — pick it up. Called
      // from a post-frame phase or an async continuation, so draining
      // directly is safe.
      _takeStashedQueuedInput(deferSend: false);
      return;
    }
    _queuedInput = null;
    setState(() {});
    unawaited(_send(q));
  }

  /// Picks up a session-level stash that lands after this view mounted (see
  /// [GroupChatProvider.stashQueuedInput]). One post-frame check per
  /// notification burst, deferred because the notification can fire inside
  /// another widget's unmount/build; the frame is requested explicitly
  /// because a provider notification alone does not schedule one.
  void _onGroupChatProviderChanged() {
    if (_stashPickupScheduled) return;
    if (!_groupChatProvider.hasQueuedInput(widget.groupChatId)) return;
    _stashPickupScheduled = true;
    WidgetsBinding.instance.scheduleFrame();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stashPickupScheduled = false;
      if (!mounted) return;
      _maybeDrainQueue();
    });
  }

  /// Restores a cancelled queued send back into the composer (text + media),
  /// mirroring single-chat cancelQueuedMessage.
  void _cancelQueuedInput() {
    final q = _queuedInput;
    if (q == null) return;
    _queuedInput = null;
    _inputController.value = TextEditingValue(
      text: q.text,
      selection: TextSelection.collapsed(offset: q.text.length),
      composing: TextRange.empty,
    );
    _mediaController.restoreInput(q);
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocus.requestFocus();
    });
  }

  /// Session-level queue handoff: pops the stash a previous GroupChatView
  /// instance of this group left on dispose (mobile route pop while a round
  /// was busy) and auto-drains it, mirroring the single-chat queue that
  /// drains when the conversation becomes current and free. The round was
  /// stopped by the old page's dispose, so a fresh mount is normally idle;
  /// if it is somehow busy, the stashed send falls back into the one-slot
  /// pending input and drains via [_maybeDrainQueue]. A local slot always
  /// wins (it is newer); the stash stays for the next drain check.
  ///
  /// [deferSend] is for the mount path: it runs inside
  /// `didChangeDependencies` (build phase), where starting the send would
  /// `setState` illegally, so it defers to the end of the frame. Callers
  /// running after the build phase (post-frame, async continuations) pass
  /// `false` and drain immediately.
  void _takeStashedQueuedInput({bool deferSend = true}) {
    if (_queuedInput != null) return;
    final stashed = _groupChatProvider.takeQueuedInput(widget.groupChatId);
    if (stashed == null) return;

    void drain() {
      if (!mounted) return;
      if (_loading || _orchestrator.isBusy) {
        _queuedInput = stashed;
        setState(() {});
        return;
      }
      unawaited(_send(stashed));
    }

    if (deferSend) {
      WidgetsBinding.instance.addPostFrameCallback((_) => drain());
    } else {
      drain();
    }
  }

  Future<void> _showQuickInstructionMenu() async {
    final provider = context.read<QuickInstructionProvider>();
    await provider.initialize();
    if (!mounted) return;
    _inputFocus.unfocus();
    final selected = await showInstructionInjectionSheet(
      context,
      assistantId: null,
      conversationId: null,
      selectedInvocationIds: const <String>{},
      onToggleInvocation: (_) {},
      inputBoxOnly: true,
    );
    if (selected == null || !mounted) return;

    final text = _inputController.text;
    final sel = _inputController.selection;
    final start = (sel.start >= 0 && sel.start <= text.length)
        ? sel.start
        : text.length;
    final end = (sel.end >= 0 && sel.end <= text.length && sel.end >= start)
        ? sel.end
        : start;
    final newText = text.replaceRange(start, end, selected.prompt);
    _inputController.value = _inputController.value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(
        offset: start + selected.prompt.length,
      ),
      composing: TextRange.empty,
    );
  }

  Assistant? _resolveSpeaker(ChatMessage m) {
    if (m.role != 'assistant') return null;
    final id = m.speakerAssistantId;
    if (id == null || id.isEmpty) return null;
    return context.read<AssistantProvider>().getById(id);
  }

  Future<void> _onVersionChange(String groupId, int version) async {
    await _chatController.setSelectedVersion(groupId, version);
    _refreshList();
  }

  Future<void> _onRegenerate(ChatMessage message) async {
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return;
    setState(() => _loading = true);
    try {
      await _orchestrator.regenerateAssistantMessage(
        group: g,
        message: message,
      );
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _refreshList();
      }
      _maybeDrainQueue();
    }
  }

  Future<void> _onResend(ChatMessage message) async {
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return;
    setState(() => _loading = true);
    try {
      await _orchestrator.resendUserMessage(group: g, userMessage: message);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _refreshList();
      }
      _maybeDrainQueue();
    }
  }

  Future<void> _onEdit(ChatMessage message) async {
    if (!mounted) return;
    final Future<MessageEditResult?> future = _isDesktop
        ? showMessageEditDesktopDialog(context, message: message)
        : showMessageEditSheet(context, message: message);
    final result = await future;
    if (result == null || !mounted) return;

    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return;

    final keepOriginalTimestamp =
        message.role == 'assistant' || !result.shouldSend;
    final newMsg = await _chatService.appendMessageVersion(
      messageId: message.id,
      content: result.content,
      timestamp: keepOriginalTimestamp ? message.timestamp : null,
    );
    if (newMsg == null) return;
    final gid = newMsg.groupId ?? newMsg.id;
    await _chatService.setSelectedVersion(
      g.conversationId,
      gid,
      newMsg.version,
    );
    _refreshList();

    if (!result.shouldSend) {
      setState(() {});
      return;
    }

    setState(() => _loading = true);
    try {
      if (newMsg.role == 'assistant') {
        await _orchestrator.regenerateAssistantMessage(
          group: g,
          message: newMsg,
        );
      } else if (newMsg.role == 'user') {
        await _orchestrator.resendUserMessage(group: g, userMessage: newMsg);
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _refreshList();
      }
      _maybeDrainQueue();
    }
  }

  Future<void> _onDelete(
    ChatMessage message,
    Map<String, List<ChatMessage>> byGroup, {
    required bool allVersions,
  }) async {
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return;
    await _orchestrator.deleteMessageVersions(
      group: g,
      message: message,
      allVersions: allVersions,
      byGroup: byGroup,
    );
    _refreshList();
    setState(() {});
  }

  Future<void> _clearContext() async {
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return;
    final updated = await _chatService.toggleTruncateAtTail(g.conversationId);
    if (updated != null && mounted) {
      _refreshList();
      setState(() {});
    }
  }

  /// Maps the persisted raw-space truncation index (set by "clear context")
  /// to a collapsed message index for the context boundary divider. Reuses
  /// the canonical single-chat mapping; group chat has no preset folding or
  /// paged window, so those adjustments do not apply.
  int _computeTruncCollapsedIndex() {
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return -1;
    final convo = _chatService.getConversation(g.conversationId);
    if (convo == null || convo.truncateIndex <= 0) return -1;
    return HomeViewModel.computeTruncCollapsedIndex(
      truncRaw: convo.truncateIndex,
      rawMessages: _chatService.getMessages(g.conversationId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final gp = context.watch<GroupChatProvider>();
    final group = gp.getById(widget.groupChatId);

    if (group == null) {
      return Center(
        child: Text(
          l10n.groupChatNotFound,
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.55)),
        ),
      );
    }

    final messages = _chatController.collapsedMessages;
    final byGroup = _chatController.groupedMessages;
    final settings = context.watch<SettingsProvider>();
    final currentAssistant = context
        .watch<AssistantProvider>()
        .currentAssistant;

    return Column(
      children: [
        Expanded(
          child: messages.isEmpty
              ? Center(
                  child: Text(
                    l10n.groupChatEmptyConversation,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                )
              : MessageListView(
                  scrollController: _scrollController,
                  listController: _listController,
                  messages: messages,
                  byGroup: byGroup,
                  versionSelections: _chatController.versionSelections,
                  truncCollapsedIndex: _computeTruncCollapsedIndex(),
                  reasoning: _streamController.reasoning,
                  reasoningSegments: _streamController.reasoningSegments,
                  contentSplits: _streamController.contentSplits,
                  toolParts: _streamController.toolParts,
                  translations: _translations,
                  selecting: false,
                  selectedItems: const <String>{},
                  dividerPadding: EdgeInsets.zero,
                  isProcessingFiles: _isProcessingFiles,
                  chatFontScale: settings.chatFontScale,
                  collapseThinking: settings.autoCollapseThinking,
                  collapsedCodeLines: settings.autoCollapseCodeBlock
                      ? settings.autoCollapseCodeBlockLines
                      : null,
                  showModelIcon: settings.showModelIcon,
                  showUserAvatar: settings.showUserAvatar,
                  showTokenStats: settings.showTokenStats,
                  assistant: currentAssistant,
                  streamingContentNotifier:
                      _streamController.streamingContentNotifier,
                  resolveSpeaker: _resolveSpeaker,
                  hideMoreActions: () => {
                    MessageMoreAction.multiAI,
                    MessageMoreAction.fork,
                    MessageMoreAction.selectMessages,
                  },
                  onVersionChange: _onVersionChange,
                  onRegenerateMessage: (m) {
                    unawaited(_onRegenerate(m));
                  },
                  onResendMessage: (m) {
                    unawaited(_onResend(m));
                  },
                  onEditMessage: (m) {
                    unawaited(_onEdit(m));
                  },
                  onDeleteMessage: (m, bg) =>
                      _onDelete(m, bg, allVersions: false),
                  onDeleteAllVersions: (m, bg) =>
                      _onDelete(m, bg, allVersions: true),
                  onToggleReasoning: (id) {
                    final r = _streamController.reasoning[id];
                    if (r == null) return;
                    r.expanded = !r.expanded;
                    _persistReasoningToggle(id);
                    setState(() {});
                  },
                  onToggleReasoningSegment: (id, index) {
                    final segs = _streamController.reasoningSegments[id];
                    if (segs == null || index < 0 || index >= segs.length) {
                      return;
                    }
                    segs[index].expanded = !segs[index].expanded;
                    _persistReasoningToggle(id);
                    setState(() {});
                  },
                ),
        ),
        SafeArea(
          top: false,
          child: ChatInputBar(
            key: _inputBarKey,
            controller: _inputController,
            mediaController: _mediaController,
            focusNode: _inputFocus,
            loading: _loading || _orchestrator.isBusy,
            mode: ChatInputMode.groupChat,
            showToolsHubButton: false,
            supportsReasoning: false,
            showMoreButton: false,
            showQuickPhraseButton: true,
            asrProvider: context.read<AsrProvider>(),
            onQuickPhrase: () => unawaited(_showQuickInstructionMenu()),
            onLongPressQuickPhrase: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const InstructionInjectionPage(),
                ),
              );
            },
            onPickCamera: _isDesktop
                ? null
                : () => _fileUploadService.onPickCamera(context),
            onPickPhotos: _isDesktop
                ? null
                : () => _fileUploadService.onPickPhotos(),
            onUploadFiles: () => _fileUploadService.onPickFiles(),
            hasQueuedInput: _queuedInput != null,
            queuedPreviewText: _queuedInput?.text,
            onCancelQueuedInput: _cancelQueuedInput,
            onStop: () {
              _orchestrator.requestStop();
              setState(() => _loading = false);
            },
            onClearContext: () {
              unawaited(_clearContext());
            },
            onSend: (data) async {
              if (_loading || _orchestrator.isBusy) {
                if (_queuedInput != null) {
                  return ChatInputSubmissionResult.rejected;
                }
                _queuedInput = data;
                if (mounted) setState(() {});
                return ChatInputSubmissionResult.queued;
              }
              unawaited(_send(data));
              return ChatInputSubmissionResult.sent;
            },
          ),
        ),
      ],
    );
  }
}
