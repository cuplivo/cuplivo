import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/providers/asr_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../desktop/message_edit_dialog.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../chat/models/message_edit_result.dart';
import '../../chat/widgets/message_edit_sheet.dart';
import '../../chat/widgets/message_more_sheet.dart';
import '../../home/controllers/chat_actions.dart';
import '../../home/controllers/chat_controller.dart';
import '../../home/controllers/generation_controller.dart';
import '../../home/controllers/home_view_model.dart';
import '../../home/controllers/stream_controller.dart' as stream_ctrl;
import '../../home/services/file_upload_service.dart';
import '../../home/services/message_builder_service.dart';
import '../../home/services/message_generation_service.dart';
import '../../home/services/ocr_service.dart';
import '../../home/widgets/chat_input_bar.dart';
import '../../home/widgets/message_list_view.dart';
import '../controllers/group_chat_orchestrator.dart';
import '../services/director_context_builder.dart';
import '../services/director_runner.dart';

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
  final _processingFilesMessageId = ValueNotifier<String?>(null);
  final _translations = <String, TranslationUiState>{};

  FocusNode get _inputFocus => widget.inputFocusNode ?? _ownInputFocus!;

  late ListController _listController;
  late ChatService _chatService;
  late stream_ctrl.StreamController _streamController;
  late ChatController _chatController;
  late MessageBuilderService _messageBuilderService;
  late GenerationController _generationController;
  late MessageGenerationService _messageGenerationService;
  late HomeViewModel _viewModel;
  late ChatActions _chatActions;
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
    _ocrService = OcrService(
      resolveContentHashes: (paths) =>
          _chatService.resolveImageContentHashes(paths),
      loadArtifacts: (revisionIds) =>
          _chatService.getImageOcrArtifacts(revisionIds),
      persistArtifact: (revisionId, items) =>
          _chatService.upsertImageOcrArtifactItems(revisionId, items),
      onError: (error) => _onUiFeedback('groupChatDirectorError'),
    );
    _fileUploadService = FileUploadService(
      getContext: () => context,
      mediaController: _mediaController,
      isImageCropperEnabled: () =>
          context.read<SettingsProvider>().imageCropperEnabled,
      getImageCompressConfig: () =>
          context.read<SettingsProvider>().resolveImageCompressConfig(),
      hasWorkspace: () => false,
    );
    _streamController = stream_ctrl.StreamController(
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
      ocrHandler: (imagePaths, {revisionId, session, requestId}) =>
          _ocrService.getOcrTextForImages(
            imagePaths,
            context,
            revisionId: revisionId,
            session: session,
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
    // The group surface hosts its own ChatActions (via HomeViewModel, the
    // sanctioned construction path) — member turns stream through it via
    // ChatActionsGroupChatTurnDriver. NOTE: ChatActions registers itself as
    // the process-wide "current" instance; while a group view is alive, the
    // home surface's delete-stops-generation invariant therefore consults the
    // group instance. Accepted for v1: the group page covers the home surface
    // for its lifetime.
    _viewModel = HomeViewModel(
      chatService: _chatService,
      messageBuilderService: _messageBuilderService,
      messageGenerationService: _messageGenerationService,
      generationController: _generationController,
      streamController: _streamController,
      chatController: _chatController,
      contextProvider: context,
      getTitleForLocale: (ctx) =>
          AppLocalizations.of(ctx)!.groupChatDefaultName,
    );
    _viewModel.addListener(() {
      if (mounted) setState(() {});
    });
    _chatActions = _viewModel.chatActions;
    _orchestrator = GroupChatOrchestrator(
      chatService: _chatService,
      groupChatProvider: context.read<GroupChatProvider>(),
      assistantProvider: context.read<AssistantProvider>(),
      settingsProvider: context.read<SettingsProvider>(),
      userProvider: context.read<UserProvider>(),
      directorRunner: DirectorRunner(
        chatService: _chatService,
        contextBuilder: DirectorContextBuilder(chatService: _chatService),
      ),
      chatActions: _chatActions,
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

  Future<void> _bindConversation() async {
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return;
    final convo = _chatService.getConversation(g.conversationId);
    if (convo != null) {
      await _chatController.setCurrentConversationAndLoad(convo);
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
        );
      }
      if (m.translation != null && m.translation!.isNotEmpty) {
        _translations[m.id] = const TranslationUiState(expanded: false);
      }
    }
  }

  void _refreshList() {
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return;
    final convo = _chatService.getConversation(g.conversationId);
    if (convo != null) {
      _chatController.updateCurrentConversation(convo);
    }
    _chatController.loadVersionSelections();
    // Re-pull the tail window: the orchestrator persists messages directly,
    // so the in-memory window must be re-anchored after every round event.
    unawaited(_chatController.loadEndWindow());
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
    _processingFilesMessageId.dispose();
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

  String? _resolveSpeakerName(String senderId) {
    if (senderId.isEmpty) return null;
    return context.read<AssistantProvider>().getById(senderId)?.name;
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

    // WT's appendMessageVersion keeps the original timestamp by design; the
    // fork's user-message timestamp refresh is not upstream behavior.
    final newMsg = await _chatService.appendMessageVersion(
      messageId: message.id,
      content: result.content,
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
                  renderModels: _chatController.messageRenderModels,
                  byGroup: byGroup,
                  versionSelections: _chatController.versionSelections,
                  reasoning: _streamController.reasoning,
                  reasoningSegments: _streamController.reasoningSegments,
                  contentSplits: _streamController.contentSplits,
                  toolParts: _streamController.toolParts,
                  translations: _translations,
                  selecting: false,
                  selectedItems: const <String>{},
                  dividerPadding: EdgeInsets.zero,
                  processingFilesMessageId: _processingFilesMessageId,
                  chatFontScale: settings.chatFontScale,
                  showModelIcon: settings.showModelIcon,
                  showUserAvatar: settings.showUserAvatar,
                  showTokenStats: settings.showTokenStats,
                  assistant: currentAssistant,
                  streamingContentNotifier:
                      _streamController.streamingContentNotifier,
                  resolveSpeaker: _resolveSpeakerName,
                  hideMoreActions: () => {
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
                    setState(() {});
                  },
                  onToggleReasoningSegment: (id, index) {
                    final segs = _streamController.reasoningSegments[id];
                    if (segs == null || index < 0 || index >= segs.length) {
                      return;
                    }
                    segs[index].expanded = !segs[index].expanded;
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
            // Group mode chrome: no model picker, search, reasoning or tools —
            // the director assigns speakers and models per turn.
            supportsReasoning: false,
            showMoreButton: false,
            showQuickPhraseButton: false,
            asrProvider: context.read<AsrProvider>(),
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
