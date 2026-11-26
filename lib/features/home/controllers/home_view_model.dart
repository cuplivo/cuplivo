import '../../../core/models/native_compaction.dart';
import '../../../core/models/provider_oauth.dart';
import '../../../core/models/carried_original.dart';
import '../../../core/services/api/providers/openai/responses_request.dart';
import '../../../core/services/api/request_history_context.dart';
import '../../../core/services/api/native_compaction_context.dart';
import 'package:flutter/foundation.dart' show listEquals;
import '../../../core/models/message_part.dart';
import 'dart:isolate';
import '../../../core/services/chat/compression_planner.dart';
import '../../../core/models/compression_config.dart';
import '../../../core/models/auto_retry_options.dart';
import '../../../core/services/chat/compression_templates.dart';
import '../../../core/models/context_operation.dart';
import '../../../core/services/scheduled_tasks_service.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/reasoning_request.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/models/queued_turn.dart';
import '../../../core/models/compress_context_options.dart';
import '../../../core/models/conversation.dart';
import '../../../core/services/chat/context_compression_service.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/database/business_preferences.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/instruction_injection_store.dart';
import '../../../core/services/memory_store.dart';
import '../../../core/services/logging/flutter_logger.dart';
import '../../../core/services/model_spec/model_spec_resolver.dart';
import '../../../core/services/memory/memory_pipeline.dart';
import '../../../core/services/memory/memory_trace.dart';
import '../../../core/services/mobile_background.dart';
import '../../../core/services/proactive_care_alarm_service.dart';
import '../../../core/services/proactive_care_conversation_policy.dart';
import '../../../core/services/proactive_care_message_flow.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/services/world_book_store.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/widgets/chat_message_widget.dart' show ToolUIPart;
import '../../group_chat/services/group_transcript.dart';
import '../services/context_usage_service.dart';
import '../services/context_assembly.dart';
import '../services/message_builder_service.dart';
import '../services/message_generation_service.dart';
import '../services/chat_suggestion_service.dart';
import '../utils/model_display_helper.dart';
import 'chat_actions.dart';
import 'file_processing_indicator_controller.dart';
import 'chat_controller.dart';
import 'generation_controller.dart';
import 'stream_controller.dart' as stream_ctrl;

export '../../../core/models/compress_context_options.dart';

enum BackgroundTaskKind { ocr, title, summary, suggestions, memory }

class BatchDeleteGroupPlan {
  const BatchDeleteGroupPlan({
    required this.groupId,
    required this.versionsBefore,
    required this.deletedMessageIds,
    required this.nextVersionSelection,
  });

  final String groupId;
  final List<ChatMessage> versionsBefore;
  final Set<String> deletedMessageIds;
  final int? nextVersionSelection;
}

class BatchDeletePlan {
  const BatchDeletePlan({
    required this.groups,
    required this.nextVersionSelections,
    required this.clearedVersionSelectionGroupIds,
  });

  static const empty = BatchDeletePlan(
    groups: <String, BatchDeleteGroupPlan>{},
    nextVersionSelections: <String, int>{},
    clearedVersionSelectionGroupIds: <String>{},
  );

  final Map<String, BatchDeleteGroupPlan> groups;
  final Map<String, int> nextVersionSelections;
  final Set<String> clearedVersionSelectionGroupIds;

  bool get isEmpty => groups.isEmpty;

  Set<String> get deletedMessageIds => {
    for (final group in groups.values) ...group.deletedMessageIds,
  };
}

/// Result of [HomeViewModel.prepareConversationSwitch]: everything needed to
/// commit a conversation switch atomically once the caller is ready.
class PreparedConversationSwitch {
  const PreparedConversationSwitch({
    required this.conversation,
    required this.window,
  });

  final Conversation conversation;
  final FetchedConversationWindow window;
}

/// ViewModel for the home page, combining actions + services.
///
/// This ViewModel:
/// - Holds all page state (conversation, messages, loading, etc.)
/// - Calls ChatActions for business operations
/// - Notifies UI of state changes via ChangeNotifier
/// - Handles conversation switching/creation
///
/// UI layer only needs to:
/// - Listen to this ViewModel
/// - Call simple methods like sendMessage(), regenerate(), etc.
/// - Handle UI-specific concerns (snackbars, scrolling, animations)
class HomeViewModel extends ChangeNotifier {
  HomeViewModel({
    required this._chatService,
    required this._messageBuilderService,
    required this._messageGenerationService,
    required this._generationController,
    required this._streamController,
    required this._chatController,
    required this._contextProvider,
    required this.getTitleForLocale,
    ContextUsageService? contextUsage,
  }) : _contextUsage = contextUsage {
    // Initialize ChatActions
    _chatActions = ChatActions(
      chatService: _chatService,
      chatController: _chatController,
      streamController: _streamController,
      generationController: _generationController,
      messageGenerationService: _messageGenerationService,
      contextProvider: _contextProvider,
      viewModel: this,
      contextUsage: contextUsage,
    );

    // Wire up callbacks
    _chatActions.onMessagesChanged = _onMessagesChanged;
    _chatActions.onSendPairAppended = () => onScrollToBottom?.call();
    _chatActions.onLoadingChanged = _onLoadingChanged;
    // Steer: a message that arrives while the turn runs ends it at the next step
    // boundary and starts the next one, instead of waiting for the reply to end.
    _chatActions.takeHandoff = _hasHandoffReady;
    _chatActions.onHandoffRequested = _startHandoffSegment;
    _chatActions.onContentUpdated = _onContentUpdated;
    _chatActions.onStreamError = _onStreamError;
    _chatActions.onContextOverflow = (message, error, originalParts) {
      if (onContextOverflow != null) {
        onContextOverflow!(message, error, originalParts);
      } else {
        onError?.call(error);
      }
    };
    _chatActions.onMaybeGenerateTitle = _onMaybeGenerateTitle;
    _chatActions.onMaybeGenerateSummary = _onMaybeGenerateSummary;
    _chatActions.onMaybeGenerateSuggestions = _onMaybeGenerateSuggestions;
    _chatActions.onMaybeUpdateProactiveCare = _onMaybeUpdateProactiveCare;
    _chatActions.onStreamFinished = _onStreamFinished;
    _chatActions.onAssistantMessageFinished = _onAssistantMessageFinished;
    _chatActions.onFileProcessingStarted = _onFileProcessingStarted;
    _chatActions.onFileProcessingFinished = _onFileProcessingFinished;
    _chatActions.onGroupRoundFinished = (conversationId) {
      // The round released the loading guard; whatever the user sent while it
      // ran is no longer blocked by it.
      notifyListeners();
      unawaited(_drainQueuedInputIfReady(conversationId));
      // A topic is named once, from what the round actually said. Every later
      // round finds a real title and costs nothing.
      _onMaybeGenerateTitle(conversationId);
    };
    _chatActions.onGroupDirectorFallback = (conversationId) {
      onWarning?.call('group_director_fallback');
    };
    _chatService.contextCompression.isConversationBusy = _isConversationBusy;
    _chatService.contextCompression.isInputPaused =
        _pausedQueuedInputs.contains;
    _chatService.contextCompression.estimateCandidate =
        _estimateCompressedContext;
    _chatService.contextCompression.addListener(_onCompressionChanged);
    _chatService.contextCompression.onContextChangeFinished = (id, applied) {
      if (!applied && _hasQueued(id)) {
        if (_pausedQueuedInputs.add(id)) {
          _chatService.contextCompression.refreshInputStatus();
        }
      }
      notifyListeners();
      if (applied) unawaited(_drainQueuedInputIfReady(id));
    };
    for (final task in _chatService.contextCompression.tasks.toList()) {
      _chatService.contextCompression.resumeIfReady(task.conversationId);
    }
  }

  // ============================================================================
  // Dependencies
  // ============================================================================

  final ChatService _chatService;
  // ignore: unused_field - Reserved for future use (direct message building)
  final MessageBuilderService _messageBuilderService;
  // ignore: unused_field - Reserved for future use (direct generation control)
  final MessageGenerationService _messageGenerationService;
  final GenerationController _generationController;
  final stream_ctrl.StreamController _streamController;
  final ChatController _chatController;
  final BuildContext _contextProvider;
  final ContextUsageService? _contextUsage;
  final ChatSuggestionService _suggestionService =
      const ChatSuggestionService();
  late final ChatActions _chatActions;

  @visibleForTesting
  ChatActions get debugChatActions => _chatActions;

  /// One FIFO per conversation: a message the user queued and a finished
  /// delegation's result wait in the same line, in arrival order.
  final Map<String, List<QueuedTurn>> _queue = {};

  bool _hasQueued(String conversationId) =>
      _queue[conversationId]?.isNotEmpty ?? false;
  final Set<String> _drainingQueuedInputs = {};
  final Set<String> _pausedQueuedInputs = {};

  /// Mail rows a delegation wrote that no turn has read yet, oldest first.
  ///
  /// The row is already persisted when it lands here (the coordinator writes it),
  /// so this is only the delivery side: a turn starts from the row as soon as the
  /// conversation can generate, at a step boundary or at the end of the turn.
  final Map<String, List<ChatMessage>> _mailInbox = {};

  bool _hasPendingMail(String conversationId) =>
      _mailInbox[conversationId]?.isNotEmpty ?? false;

  bool hasPendingMail(String conversationId) => _hasPendingMail(conversationId);

  bool isConversationBusy(String conversationId) =>
      _isConversationBusy(conversationId);

  ChatMessage? _takeMail(String conversationId) {
    final list = _mailInbox[conversationId];
    if (list == null || list.isEmpty) return null;
    final first = list.removeAt(0);
    if (list.isEmpty) _mailInbox.remove(conversationId);
    return first;
  }

  void _putMailBack(String conversationId, ChatMessage message) {
    final list = _mailInbox.putIfAbsent(conversationId, () => []);
    list.insert(0, message);
  }

  /// One mail row from a delegation. The row is already persisted; this only
  /// queues the turn that reads it.
  void enqueueMail({
    required String conversationId,
    required ChatMessage message,
  }) {
    _mailInbox.putIfAbsent(conversationId, () => []).add(message);
    notifyListeners();
    unawaited(refreshTimelineAfterExternalWrite(conversationId));
    unawaited(_drainQueuedInputIfReady(conversationId));
  }

  final Map<String, String> _compressionStates = {};

  /// Conversations whose title request is in flight, so two finishes in a row
  /// produce one rename instead of two.
  final Set<String> _titlesInFlight = {};

  ContextCompressionTask? get currentCompressionTask =>
      currentConversation == null
      ? null
      : _chatService.contextCompression.taskFor(currentConversation!.id);

  bool get currentQueuedInputPaused =>
      _pausedQueuedInputs.contains(currentConversation?.id);

  bool _isConversationBusy(String id) =>
      _chatController.isConversationLoading(id) ||
      _chatActions.isSendInFlight(id) ||
      _chatActions.activeStreamingMessageId(id) != null;

  Future<CompressionBudget> _estimateCompressedContext(
    String id,
    List<ChatMessage> history, {
    bool? fixedContextStart,
  }) async {
    final settings = _contextProvider.read<SettingsProvider>();
    final conversation = _chatService.getConversation(id);
    if (conversation == null) throw StateError('conversation_not_found');
    final assistant = _contextProvider
        .read<AssistantProvider>()
        .resolveConversationAssistant(conversation.assistantId);
    final model = _messageGenerationService.getModelConfig(
      settings,
      assistant,
      conversation: conversation,
    );
    if (model.providerKey == null || model.modelId == null) {
      throw StateError('no_model');
    }
    final config = settings.getProviderConfig(model.providerKey!);
    final messages = List<ChatMessage>.of(history);
    final queued = _queue[id]?.whereType<QueuedUserInput>().firstOrNull;
    if (queued != null) {
      messages.add(
        ChatMessage(
          role: 'user',
          conversationId: id,
          parts: await _messageGenerationService.buildUserMessagePreviewParts(
            queued.input,
            assistant: assistant,
          ),
        ),
      );
    }
    final preview = await _messageGenerationService.previewContextAssembly(
      conversationId: id,
      providerKey: model.providerKey!,
      modelId: model.modelId!,
      assistantId: conversation.assistantId,
      messagesOverride: messages,
      fixedContextStart: fixedContextStart,
    );
    final job = ContextEstimateJob(
      preview: preview,
      kind: ProviderConfig.classify(
        model.providerKey!,
        explicitType: config.providerType,
      ),
    );
    final estimate = await Isolate.run(job.call);
    final window = ModelSpecResolver.instance
        .spec(config, model.modelId!)
        .contextWindow;
    final reserve =
        assistant?.maxTokens ??
        (window == null ? 0 : (window ~/ 10).clamp(1, 4096));
    return (usedTokens: estimate.total + reserve, contextWindow: window);
  }

  void _onCompressionChanged() {
    var queueChanged = false;
    for (final task in _chatService.contextCompression.tasks) {
      if (task.automatic || task.ownsContinuation) continue;
      final state = '${task.id}:${task.phase.name}';
      if (_compressionStates[task.conversationId] == state) continue;
      _compressionStates[task.conversationId] = state;
      if (task.phase == CompressionPhase.completed &&
          task.resultConversationId == null) {
        queueChanged =
            _pausedQueuedInputs.remove(task.conversationId) || queueChanged;
        unawaited(_drainQueuedInputIfReady(task.conversationId));
      } else if ((task.phase == CompressionPhase.review || !task.active) &&
          _hasQueued(task.conversationId)) {
        queueChanged =
            _pausedQueuedInputs.add(task.conversationId) || queueChanged;
      }
    }
    if (queueChanged) _chatService.contextCompression.refreshInputStatus();
    notifyListeners();
  }

  @override
  void dispose() {
    _chatService.contextCompression.removeListener(_onCompressionChanged);
    _chatService.contextCompression.isConversationBusy = null;
    _chatService.contextCompression.isInputPaused = null;
    _chatService.contextCompression.estimateCandidate = null;
    _chatService.contextCompression.onContextChangeFinished = null;
    super.dispose();
  }

  /// Function to get localized title
  final String Function(BuildContext context) getTitleForLocale;

  // ============================================================================
  // Callbacks for UI (set by HomePage)
  // ============================================================================

  /// Called when an error occurs (UI should show snackbar).
  void Function(String error)? onError;
  void Function(
    ChatMessage message,
    String error,
    List<MessagePart> originalParts,
  )?
  onContextOverflow;

  /// Called when a non-blocking background model task fails.
  void Function(BackgroundTaskKind task, Object error)? onBackgroundTaskError;

  /// Called when a warning occurs (UI should show snackbar).
  void Function(String warning)? onWarning;

  /// Called when streaming finishes (UI may show notification).
  void Function(String conversationId)? onStreamFinished;

  /// Completes once downstream work has taken over background execution.
  FutureOr<void> Function(ChatMessage message)? onAssistantMessageFinished;

  /// Called to schedule inline image sanitization.
  void Function(String messageId, String content, {bool immediate})?
  onScheduleImageSanitize;

  /// Called when scrolling to bottom is needed.
  VoidCallback? onScrollToBottom;

  /// Called for haptic feedback.
  VoidCallback? onHapticFeedback;

  /// Called when conversation is successfully switched (for animations).
  VoidCallback? onConversationSwitched;

  // ============================================================================
  // State Getters (delegate to ChatController)
  // ============================================================================

  Conversation? get currentConversation => _chatController.currentConversation;
  List<ChatMessage> get messages => _chatController.messages;
  Map<String, int> get versionSelections => _chatController.versionSelections;
  Set<String> get loadingConversationIds => <String>{
    for (final id in _chatController.loadingConversationIds)
      if (!_chatActions.isStopping(id)) id,
  };

  /// Whether send/regenerate or cancellation teardown owns [conversationId].
  bool isConversationSendInFlight(String conversationId) =>
      _chatActions.isSendInFlight(conversationId);

  /// Whether a whole round owns [conversationId]'s loading flag.
  bool isGroupRoundLoading(String conversationId) =>
      _chatActions.isGroupRoundLoading(conversationId);
  Map<String, StreamSubscription<dynamic>> get conversationStreams =>
      _chatController.conversationStreams;

  /// StreamController state getters
  Map<String, stream_ctrl.ReasoningData> get reasoning =>
      _streamController.reasoning;
  Map<String, List<stream_ctrl.ReasoningSegmentData>> get reasoningSegments =>
      _streamController.reasoningSegments;
  Map<String, stream_ctrl.ContentSplitData> get contentSplits =>
      _streamController.contentSplits;
  Map<String, List<ToolUIPart>> get toolParts => _streamController.toolParts;

  /// Whether the current conversation should show the generating state.
  bool get isCurrentConversationLoading {
    final cid = currentConversation?.id;
    if (cid == null) return false;
    return _chatController.isConversationLoading(cid) &&
        !_chatActions.isStopping(cid);
  }

  /// The head of the queue, when it is the user's own message: the composer
  /// shows that one and can cancel it. A delegation's result is never shown in
  /// the composer — it says so on the strip instead.
  QueuedUserInput? get currentQueuedInput {
    final head = _queue[currentConversation?.id]?.firstOrNull;
    return head is QueuedUserInput ? head : null;
  }

  final FileProcessingIndicatorController _fileProcessingIndicator =
      FileProcessingIndicatorController();

  /// Id of the assistant message whose attachments are being parsed, or null.
  /// Scoped to a single message so the indicator never appears on every reply.
  ValueNotifier<String?> get processingFilesMessageId =>
      _fileProcessingIndicator.messageId;

  // ============================================================================
  // Internal Callbacks
  // ============================================================================

  void _onMessagesChanged() {
    _chatController.invalidateCache();
    notifyListeners();
  }

  void _onLoadingChanged(String conversationId, bool loading) {
    notifyListeners();
    if (!loading) {
      _chatService.contextCompression.resumeIfReady(conversationId);
      unawaited(_drainQueuedInputIfReady(conversationId));
    }
  }

  void _onContentUpdated(String messageId, String content, int totalTokens) {
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index != -1) {
      _chatController.replaceMessageSnapshot(
        messages[index].copyWith(content: content, totalTokens: totalTokens),
      );
      // NOTE: Do NOT call notifyListeners() here!
      // Streaming content updates are now handled by StreamingContentNotifier
      // via ValueListenableBuilder, which only rebuilds the streaming message widget.
      // Calling notifyListeners() here would trigger a full page rebuild and cause lag.
    }
  }

  void _onStreamError(String error) {
    if (error.contains('native_compaction_input_overridden') &&
        _contextProvider.mounted) {
      onError?.call(
        AppLocalizations.of(_contextProvider)!.compressionNativeInputOverride,
      );
      return;
    }
    if (error.contains('native_compaction_scope_changed') &&
        _contextProvider.mounted) {
      onError?.call(
        AppLocalizations.of(_contextProvider)!.compressionNativeScopeChanged,
      );
      return;
    }
    onError?.call(error);
  }

  void _onMaybeGenerateTitle(String conversationId) {
    _runBackgroundTask(
      BackgroundTaskKind.title,
      _maybeGenerateTitleFor(conversationId),
    );
  }

  void _onMaybeGenerateSummary(String conversationId) {
    _runBackgroundTask(
      BackgroundTaskKind.summary,
      _maybeGenerateSummaryFor(conversationId),
    );
  }

  void _onMaybeGenerateSuggestions(String conversationId) {
    _runBackgroundTask(
      BackgroundTaskKind.suggestions,
      _maybeGenerateSuggestionsFor(conversationId),
    );
  }

  void _runBackgroundTask(BackgroundTaskKind task, Future<void> future) {
    unawaited(
      future.onError((error, stackTrace) {
        final reportedError = error ?? 'unknown error';
        FlutterLogger.log(
          '[BackgroundTask:$task] failed: $reportedError\n$stackTrace',
          tag: 'HomeViewModel',
        );
        onBackgroundTaskError?.call(task, reportedError);
      }),
    );
  }

  void _onStreamFinished(String conversationId) {
    onStreamFinished?.call(conversationId);
  }

  Future<void> _onAssistantMessageFinished(ChatMessage message) async {
    await onAssistantMessageFinished?.call(message);
    _onMaybeOrganizeMemory(message.conversationId);
  }

  /// Schedule background memory organize after a successful finalize (§12.1).
  /// Never awaited; failures must not surface as chat errors.
  void _onMaybeOrganizeMemory(String conversationId) {
    try {
      final settings = _contextProvider.read<SettingsProvider>();
      if (settings.legacyMemoryMode) return;
      final convo = _chatService.getConversation(conversationId);
      if (convo == null) return;
      // A group topic has no owner: filing a round's messages as one
      // assistant's memory would replay a whole group in that assistant's 1:1
      // prompts.
      if (convo.isGroupConversation) return;
      final assistantProvider = _contextProvider.read<AssistantProvider>();
      final assistant = assistantProvider.resolveConversationAssistant(
        convo.assistantId,
      );
      if (assistant == null || !assistant.enableMemory) return;
      if (!assistant.autoOrganizeMemory) return;
      final pipeline = _contextProvider.read<MemoryPipelineService>();
      pipeline.scheduleIfNeeded(
        conversationId: conversationId,
        assistantId: assistant.id,
        onError: (error) =>
            onBackgroundTaskError?.call(BackgroundTaskKind.memory, error),
      );
    } catch (e, st) {
      FlutterLogger.log(
        '[MemoryPipeline] schedule failed: $e\n$st',
        tag: 'HomeViewModel',
      );
    }
  }

  /// Drops the indicator immediately, ignoring the minimum-visible hold. Used
  /// when the conversation the indicator belonged to is no longer on screen.
  void resetFileProcessingIndicator() => _fileProcessingIndicator.reset();

  // ============================================================================
  // Proactive care ("Ta的来信")
  // ============================================================================

  /// After a settled reply, silently ask the decision model whether the
  /// conversation's next care time should move. Android-only feature.
  void _onMaybeUpdateProactiveCare(String conversationId) {
    if (!ProactiveCareAlarmService.isSupported) return;
    unawaited(
      _decideProactiveCareFor(conversationId).catchError((Object e, st) {
        FlutterLogger.log(
          '[ProactiveCare] decision failed: $e\n$st',
          tag: 'HomeViewModel',
        );
      }),
    );
  }

  ProactiveCareMessageFlow _proactiveCareFlow() => ProactiveCareMessageFlow(
    chatService: _chatService,
    settings: _contextProvider.read<SettingsProvider>(),
    memoryStore: MemoryStore(_contextProvider.read<BusinessPreferences>()),
    instructionInjectionStore: InstructionInjectionStore(
      _contextProvider.read<BusinessPreferences>(),
    ),
    worldBookStore: WorldBookStore(
      _contextProvider.read<BusinessPreferences>(),
    ),
    // A letter is inserted silently, outside the streaming path: reload the
    // timeline as soon as it is durable, before the next-time decision call.
    // The same moment ends the background task that stood for the letter.
    onLetterPersisted: (conversationId) async {
      await _refreshCurrentConversationAfterCare({conversationId});
      await _finishCareLetterTask(
        conversationId,
        BackgroundTaskOutcome.completed,
      );
    },
  );

  String? _proactiveCareL10n(String? Function(AppLocalizations) pick) {
    final l10n = AppLocalizations.of(_contextProvider);
    if (l10n == null) return null;
    return pick(l10n);
  }

  String get _proactiveCarePromptFallback =>
      _proactiveCareL10n(
        (l10n) => l10n.assistantEditProactiveCarePromptDefault,
      ) ??
      '';

  String get _proactiveCareDecisionPromptFallback =>
      _proactiveCareL10n(
        (l10n) => l10n.assistantEditProactiveCareDecisionPromptDefault,
      ) ??
      '';

  String? get _proactiveCareFailureBody =>
      _proactiveCareL10n((l10n) => l10n.proactiveCareFailedNotificationBody);

  Future<void> _decideProactiveCareFor(String conversationId) async {
    final conversation = _chatService.getConversation(conversationId);
    if (conversation == null) return;
    final assistantId = conversation.assistantId;
    if (assistantId == null) return;
    final assistant = _contextProvider.read<AssistantProvider>().getById(
      assistantId,
    );
    if (assistant == null) return;
    if (!ProactiveCareConversationPolicy.isEligible(conversation, assistant)) {
      debugPrint(
        '[ProactiveCare] decision skipped: not eligible $conversationId',
      );
      return;
    }

    final flow = _proactiveCareFlow();
    final model = flow.resolveDecisionModelConfig(
      assistant,
      conversation: conversation,
    );
    if (model == null) {
      debugPrint('[ProactiveCare] decision skipped: no decision model');
      return;
    }
    final userNickname = _contextProvider.read<UserProvider>().name;
    final history = ProactiveCareMessageFlow.historyFromMessages(
      await _chatService.loadMessages(conversationId),
    );
    if (history.isEmpty) return;
    final nextAt = await flow.decideNextCareTime(
      config: model.config,
      modelId: model.modelId,
      assistant: assistant,
      userNickname: userNickname,
      history: history,
      decisionPrompt: assistant.proactiveCareDecisionPrompt.trim().isNotEmpty
          ? assistant.proactiveCareDecisionPrompt
          : _proactiveCareDecisionPromptFallback,
      conversationId: conversationId,
      currentNextCareTime: conversation.proactiveCareNextMessageAt,
    );
    if (nextAt == null) {
      // decideNextCareTime returns null for keep / declined / failed / invalid
      // alike, so this line must not claim the model decided anything.
      debugPrint(
        '[ProactiveCare] decision left the next time unchanged '
        '(kept/declined/failed)',
      );
      return;
    }
    debugPrint('[ProactiveCare] decision set next time $nextAt');
    // The extras write re-arms the Android alarm (see ChatService's
    // proactive-care hook).
    await _chatService.updateConversationExtras(conversationId, (extras) {
      extras[Conversation.proactiveCareNextMessageAtKey] = nextAt
          .toIso8601String();
      return extras;
    });
  }

  /// Re-arms every pending letter after the app came back to the foreground:
  /// an alarm the system (or our own handoff) lost must not depend on the next
  /// process start to come back. Mirrors the native `ready` re-arm Kelivo's
  /// scheduled tasks do.
  ///
  /// The re-arm is a replace-all, so an unloaded store has to skip instead of
  /// arming: an empty snapshot would cancel every alarm it cannot see. A store
  /// that is genuinely empty has no letter to preserve, and the startup /
  /// restore / sync paths still own cleaning up stale registry entries.
  Future<void> reschedulePendingProactiveCare() async {
    if (!ProactiveCareAlarmService.isSupported) return;
    final conversations = _chatService.getAllConversations();
    final assistantProvider = _contextProvider.read<AssistantProvider>();
    final assistants = assistantProvider.assistants;
    if (conversations.isEmpty || assistants.isEmpty) {
      debugPrint('[ProactiveCare] re-arm skipped: stores not ready');
      return;
    }
    try {
      await ProactiveCareAlarmService.rescheduleAll(
        conversations: conversations,
        assistants: assistants,
        assistantStoreLoaded: assistantProvider.isLoaded,
      );
    } catch (e, st) {
      FlutterLogger.log(
        '[ProactiveCare] resume re-arm failed: $e\n$st',
        tag: 'HomeViewModel',
      );
    }
  }

  /// Delivers every due care letter for all eligible conversations (app
  /// start / resume catch-up; the alarm channel covers on-time delivery).
  /// Returns the number of letters delivered, excluding failed attempts.
  Future<int> deliverDueProactiveCare() async {
    if (!ProactiveCareAlarmService.isSupported) return 0;
    try {
      final flow = _proactiveCareFlow();
      final delivered = await flow.runDueSchedules(
        assistants: _contextProvider.read<AssistantProvider>().assistants,
        userNickname: _contextProvider.read<UserProvider>().name,
        carePromptFallback: _proactiveCarePromptFallback,
        decisionPromptFallback: _proactiveCareDecisionPromptFallback,
        failureNotificationBody: _proactiveCareFailureBody,
      );
      final succeeded = delivered.where((d) => d.successful).length;
      if (delivered.isNotEmpty) {
        debugPrint(
          '[ProactiveCare] catch-up delivered $succeeded/${delivered.length}',
        );
      }
      // Each letter already reloaded the timeline through onLetterPersisted.
      return succeeded;
    } catch (e, st) {
      FlutterLogger.log(
        '[ProactiveCare] due delivery failed: $e\n$st',
        tag: 'HomeViewModel',
      );
      return 0;
    }
  }

  /// Delivers the one schedule an Android alarm selected. Returns true when
  /// a letter was generated and persisted.
  Future<bool> deliverProactiveCareSchedule({
    required String conversationId,
    required DateTime expectedAt,
  }) async {
    if (!ProactiveCareAlarmService.isSupported) return false;
    debugPrint('[ProactiveCare] deliver $conversationId @ $expectedAt');
    // Everything the delivery needs from its context is read before the task
    // start crosses an async gap.
    final flow = _proactiveCareFlow();
    final assistants = _contextProvider.read<AssistantProvider>().assistants;
    final userNickname = _contextProvider.read<UserProvider>().name;
    final carePromptFallback = _proactiveCarePromptFallback;
    final decisionPromptFallback = _proactiveCareDecisionPromptFallback;
    final failureNotificationBody = _proactiveCareFailureBody;
    final notificationId = NotificationService.proactiveCareIdFor(
      conversationId,
    );
    await _startCareLetterTask(conversationId);
    try {
      final outcome = await flow.runSchedule(
        conversationId: conversationId,
        expectedAt: expectedAt,
        assistants: assistants,
        userNickname: userNickname,
        carePromptFallback: carePromptFallback,
        decisionPromptFallback: decisionPromptFallback,
        failureNotificationBody: failureNotificationBody,
        notificationId: notificationId,
      );
      if (outcome == null) {
        debugPrint('[ProactiveCare] nothing to deliver for $conversationId');
        await _finishCareLetterTask(
          conversationId,
          BackgroundTaskOutcome.cancelled,
        );
        return false;
      }
      // A successful letter already ended its background task, and the failure
      // path raises only the failure notification.
      await _finishCareLetterTask(
        conversationId,
        outcome.successful
            ? BackgroundTaskOutcome.completed
            : BackgroundTaskOutcome.failed,
      );
      // A successful letter already reloaded the timeline in the flow.
      return outcome.successful;
    } catch (e, st) {
      await _finishCareLetterTask(conversationId, BackgroundTaskOutcome.failed);
      FlutterLogger.log(
        '[ProactiveCare] alarm delivery failed: $e\n$st',
        tag: 'HomeViewModel',
      );
      return false;
    }
  }

  /// Background tasks standing for letters an alarm is delivering right now,
  /// keyed by conversation. A letter written while the app is backgrounded is
  /// one of the app's background tasks: the foreground-service notification
  /// names the assistant instead of a generic "working", the task counts on
  /// the background page, and it ends when the letter is durable. A foreground
  /// letter takes none: it is visible as it runs and is not background work.
  final Map<String, String> _careLetterTasks = {};

  Future<void> _startCareLetterTask(String conversationId) async {
    final background = MobileBackgroundCoordinator.instance;
    if (background.platform != TargetPlatform.android) return;
    // Everything the task needs from the context is read before the coordinator
    // await: the caller is the delivery itself, and a task that cannot be
    // started must never keep the letter from being written.
    final conversation = _chatService.getConversation(conversationId);
    if (conversation == null) return;
    final assistantId = conversation.assistantId;
    final assistant = assistantId == null
        ? null
        : _contextProvider.read<AssistantProvider>().getById(assistantId);
    if (assistant == null) return;
    if (!ProactiveCareConversationPolicy.isEligible(conversation, assistant)) {
      return;
    }
    final fallbackTitle =
        _proactiveCareL10n((l10n) => l10n.backgroundTaskTitle) ?? 'Cuplivo';
    final detail = _proactiveCareL10n((l10n) => l10n.backgroundCareLetter);
    final name = assistant.name.trim();
    final title = name.isNotEmpty
        ? name
        : (conversation.title.trim().isNotEmpty
              ? conversation.title.trim()
              : fallbackTitle);
    try {
      // The coordinator only learns the process's lifecycle state when it
      // initializes, and its `foreground` flag defaults to true so a pre-init
      // read claims the app is in front. A killed process boots a headless
      // engine whose lifecycle is `detached`, and the letter that woke it is
      // exactly the one that must take a task, so ask before deciding.
      await background.initialize();
      if (background.isForeground) return;
      if (_careLetterTasks.containsKey(conversationId)) return;
      final id =
          'care:$conversationId:${DateTime.now().millisecondsSinceEpoch}';
      _careLetterTasks[conversationId] = id;
      await background.start(
        id: id,
        conversationId: conversationId,
        title: title,
        detail: detail,
        // The stop action already stops the delivery's foreground service and
        // the letter request has no abort handle, so it can only drop the task
        // record; the outcome of the request itself is left to the flow.
        cancel: () => _finishCareLetterTask(
          conversationId,
          BackgroundTaskOutcome.cancelled,
        ),
      );
    } catch (e, st) {
      _careLetterTasks.remove(conversationId);
      FlutterLogger.log(
        '[ProactiveCare] care task skipped: $e\n$st',
        tag: 'HomeViewModel',
      );
    }
  }

  Future<void> _finishCareLetterTask(
    String conversationId,
    BackgroundTaskOutcome outcome,
  ) async {
    final id = _careLetterTasks.remove(conversationId);
    if (id == null) return;
    try {
      // The flow posts the letter (or failure) notification itself; a
      // chat-completion notification here would announce the same event twice.
      await MobileBackgroundCoordinator.instance.finish(
        id,
        outcome,
        resultPersisted: false,
      );
    } catch (e, st) {
      FlutterLogger.log(
        '[ProactiveCare] care task finish failed: $e\n$st',
        tag: 'HomeViewModel',
      );
    }
  }

  Future<void> _refreshCurrentConversationAfterCare(
    Set<String> conversationIds,
  ) async {
    if (conversationIds.isEmpty) return;
    final currentId = _chatService.currentConversationId;
    if (currentId == null || !conversationIds.contains(currentId)) return;
    try {
      await _chatController.refreshTimelineAfterMutation();
    } catch (_) {
      // The next manual navigation re-reads the window anyway.
    }
  }

  void _onFileProcessingStarted(String messageId) =>
      _fileProcessingIndicator.start(messageId);

  void _onFileProcessingFinished(String? messageId) =>
      _fileProcessingIndicator.finish(messageId);

  // ============================================================================
  // Public Methods - Message Actions
  // ============================================================================

  /// Send a new message or queue it if the current conversation is busy.
  Future<ChatActionResult> sendScheduledMessage({
    required ChatInputData input,
    required Conversation conversation,
    required Assistant assistant,
    ({String providerKey, String modelId})? modelOverride,
    ValueChanged<String>? onGenerationStarted,
    bool scheduledNotify = true,
    bool scheduledPreview = true,
  }) {
    if (_chatController.isConversationLoading(conversation.id) ||
        _chatActions.activeStreamingMessageId(conversation.id) != null) {
      return Future.value(ChatActionResult.inFlight());
    }
    return _chatActions.sendMessage(
      input: input,
      conversation: conversation,
      assistantOverride: assistant,
      scheduled: true,
      scheduledNotify: scheduledNotify,
      scheduledPreview: scheduledPreview,
      modelOverride: modelOverride,
      onGenerationStarted: onGenerationStarted,
    );
  }

  Future<ChatActionResult> regenerateScheduledMessage({
    required ChatMessage message,
    required Conversation conversation,
    required Assistant assistant,
    ({String providerKey, String modelId})? modelOverride,
    ValueChanged<String>? onGenerationStarted,
    bool scheduledNotify = true,
    bool scheduledPreview = true,
  }) {
    if (_chatController.isConversationLoading(conversation.id) ||
        _chatActions.activeStreamingMessageId(conversation.id) != null) {
      return Future.value(ChatActionResult.inFlight());
    }
    return _chatActions.regenerateAtMessage(
      message: message,
      conversation: conversation,
      assistantOverride: assistant,
      scheduled: true,
      scheduledNotify: scheduledNotify,
      scheduledPreview: scheduledPreview,
      modelOverride: modelOverride,
      preserveFollowingMessages: true,
      onGenerationStarted: onGenerationStarted,
    );
  }

  Future<ChatInputSubmissionResult> sendMessage(ChatInputData input) async {
    final sourceConversation = input.draftSubmission == null
        ? currentConversation
        : _chatService
              .getConversation(input.draftSubmission!.conversationId)
              ?.copyWith();
    if (input.draftSubmission != null && sourceConversation == null) {
      return ChatInputSubmissionResult.rejected;
    }
    await ScheduledTasksService.instance.reconcileBeforeSend();
    if (input.isEmpty) {
      return ChatInputSubmissionResult.rejected;
    }

    final conversation = currentConversation;
    if (conversation == null) {
      // Create new conversation first
      await createNewConversation();
    }

    if (currentConversation == null) {
      onError?.call('no_conversation');
      return ChatInputSubmissionResult.rejected;
    }

    final activeConversation = sourceConversation ?? currentConversation!;
    _queue.removeWhere((id, _) => _chatService.getConversation(id) == null);
    if (_isConversationBusy(activeConversation.id) ||
        _chatService.contextCompression.blocksSending(activeConversation.id)) {
      // Queue it behind whatever is already waiting: a second message while the
      // conversation is busy is an ordinary thing to do, and it takes its turn
      // after the first rather than replacing it.
      enqueueQueuedTurn(
        QueuedUserInput(activeConversation.id, _cloneInput(input)),
      );
      return ChatInputSubmissionResult.queued;
    }

    final success = await _sendMessageToConversation(input, activeConversation);
    return success
        ? ChatInputSubmissionResult.sent
        : ChatInputSubmissionResult.rejected;
  }

  /// Puts [turn] at the end of its conversation's queue and tries to drain it.
  ///
  /// The only entry point: the user's messages and a delegation's result go
  /// through the same line, so there is one order and one place that decides
  /// when a turn may land.
  void enqueueQueuedTurn(QueuedTurn turn) {
    (_queue[turn.conversationId] ??= <QueuedTurn>[]).add(turn);
    notifyListeners();
    unawaited(_drainQueuedInputIfReady(turn.conversationId));
  }

  /// Whether the turn running in [conversationId] should end at its next step
  /// boundary.
  ///
  /// Mail comes first: a delegation's message is what the turn exists to serve.
  /// A queued user message is the same rule from the composer's side. A finished
  /// delegation's notice is not: it is a result, and a result waits for the turn
  /// to end rather than interrupting it.
  bool _hasHandoffReady(String conversationId) {
    if (_hasPendingMail(conversationId)) return true;
    final head = _queue[conversationId]?.firstOrNull;
    return head is QueuedUserInput;
  }

  /// Starts the turn a handoff ended the previous one for.
  ///
  /// Returns false when nothing could start, in which case the caller clears the
  /// loading flag and the waiting message is picked up by the normal drain at the
  /// end of the turn.
  Future<bool> _startHandoffSegment(String conversationId) async {
    if (_drainingQueuedInputs.contains(conversationId)) return false;
    final conversation = _chatService.getConversation(conversationId);
    if (conversation == null) return false;
    _drainingQueuedInputs.add(conversationId);
    notifyListeners();
    try {
      final mail = _takeMail(conversationId);
      if (mail != null) {
        try {
          final started = await _startMailTurn(conversation, mail);
          if (!started) _putMailBack(conversationId, mail);
          return started;
        } catch (_) {
          // The row is in the transcript either way; the inbox keeps the
          // delivery so the next drain tries again.
          _putMailBack(conversationId, mail);
          return false;
        }
      }
      final queue = _queue[conversationId];
      if (queue == null || queue.isEmpty) return false;
      final head = queue.first;
      if (head is! QueuedUserInput) return false;
      // Take it out before starting: the drain would otherwise see the same head
      // after this turn ends and deliver it a second time.
      queue.removeAt(0);
      if (queue.isEmpty) _queue.remove(conversationId);
      try {
        final delivered = await _sendMessageToConversation(
          head.input,
          conversation,
        );
        if (!delivered) {
          queue.insert(0, head);
          return false;
        }
        return true;
      } catch (_) {
        queue.insert(0, head);
        return false;
      }
    } finally {
      _drainingQueuedInputs.remove(conversationId);
      notifyListeners();
    }
  }

  /// Runs one turn from a mail row that is already in the transcript.
  Future<bool> _startMailTurn(
    Conversation conversation,
    ChatMessage mail,
  ) async {
    final assistant = _contextProvider
        .read<AssistantProvider>()
        .resolveConversationAssistant(conversation.assistantId);
    final outcome = await _chatActions.regenerateAtMessage(
      message: mail,
      conversation: conversation,
      assistantOverride: assistant,
      preserveFollowingMessages: true,
      scheduled: true,
      scheduledNotify: false,
      scheduledPreview: false,
      handoff: true,
    );
    return outcome.success;
  }

  /// Tries to deliver every conversation's queue head.
  ///
  /// Called when the app comes back to the front: a drain that refused while the
  /// app was backgrounded has no other trigger to return to.
  void drainAllQueuedTurns() {
    for (final conversationId in {..._queue.keys, ..._mailInbox.keys}) {
      unawaited(_drainQueuedInputIfReady(conversationId));
    }
  }

  ChatInputData? cancelCurrentQueuedInput() {
    final queued = currentQueuedInput;
    if (queued == null ||
        _drainingQueuedInputs.contains(queued.conversationId)) {
      return null;
    }
    final queue = _queue[queued.conversationId];
    if (queue == null) return null;
    // Only the head: cancelling the chip cancels the message it shows. A second
    // queued message keeps its place — the queue holds several now, and dropping
    // the ones the user never saw would lose them silently.
    queue.remove(queued);
    if (queue.isEmpty) _queue.remove(queued.conversationId);
    _pausedQueuedInputs.remove(queued.conversationId);
    _chatService.contextCompression.refreshInputStatus();
    notifyListeners();
    return _cloneInput(queued.input);
  }

  Future<bool> _sendMessageToConversation(
    ChatInputData input,
    Conversation conversation,
  ) async {
    if (input.isEmpty) {
      return false;
    }

    _chatActions.onScheduleImageSanitize = onScheduleImageSanitize;

    // A topic whose group row is gone is not a group any more: it sends as an
    // ordinary conversation instead of refusing every message.
    if (conversation.isGroupConversation &&
        _groupRowExists(conversation.groupChatId)) {
      return _sendGroupMessageToConversation(input, conversation);
    }

    final sourceAssistant = _contextProvider
        .read<AssistantProvider>()
        .resolveConversationAssistant(conversation.assistantId);
    await _clearSuggestionsFor(conversation.id);

    onHapticFeedback?.call();

    // The indicator is raised by the generation itself, once the assistant
    // message it belongs to exists — nothing to raise or leak here.
    final result = await _chatActions.sendMessage(
      input: input,
      conversation: conversation,
      assistantOverride: sourceAssistant,
    );

    if (input.draftSubmission != null &&
        _chatService.composerDrafts != null &&
        await _chatService.composerDrafts!.wasSubmitted(
          input.draftSubmission!.id,
        )) {
      await _chatService.composerDrafts!.finishSubmission(
        input.draftSubmission!,
      );
      return true;
    }
    if (!result.success) {
      // A concurrent send already owns this conversation; it owns the UI
      // state too, so the loser exits silently.
      if (result.errorMessage == 'in_flight') return false;
      if (result.errorMessage == 'no_model') {
        onWarning?.call('no_model');
      } else if (result.errorMessage != 'empty_input') {
        onError?.call(result.errorMessage ?? 'unknown_error');
      }
      return false;
    }

    return true;
  }

  /// Send into a group conversation: one user turn, then a round of replies.
  ///
  /// Deliberately the same shape as the 1:1 branch above — the same draft
  /// submission bookkeeping, the same queued-send outcome — because from the
  /// composer's side a group send is a send, not a different feature.
  Future<bool> _sendGroupMessageToConversation(
    ChatInputData input,
    Conversation conversation,
  ) async {
    final group = _contextProvider.read<GroupChatProvider>().byId(
      conversation.groupChatId,
    );
    final assistants = _contextProvider.read<AssistantProvider>();
    final members = <Assistant>[];
    if (group != null) {
      for (final id in group.memberIds) {
        final assistant = assistants.getById(id);
        if (assistant != null) members.add(assistant);
      }
    }
    if (group == null || members.isEmpty) {
      // The group row is missing (deleted, or restored without its group) or
      // every member is gone: the conversation is read-only, and a send would
      // create a user message nothing could answer.
      onWarning?.call('group_unavailable');
      return false;
    }
    await _clearSuggestionsFor(conversation.id);
    onHapticFeedback?.call();

    final result = await _chatActions.sendGroupMessage(
      input: input,
      conversation: conversation,
      group: group,
      members: members,
    );

    if (input.draftSubmission != null &&
        _chatService.composerDrafts != null &&
        await _chatService.composerDrafts!.wasSubmitted(
          input.draftSubmission!.id,
        )) {
      await _chatService.composerDrafts!.finishSubmission(
        input.draftSubmission!,
      );
      return true;
    }
    if (!result.success) {
      if (result.errorMessage == 'in_flight') return false;
      if (result.errorMessage == 'group_has_no_members') {
        onWarning?.call('group_unavailable');
      } else if (result.errorMessage != 'empty_input') {
        onError?.call(result.errorMessage ?? 'unknown_error');
      }
      return false;
    }
    return true;
  }

  /// Re-asks the question [userMessage] already asked, in a group topic.
  ///
  /// The user turn re-asks the round (see [ChatActions.restartGroupRound]); a
  /// member's reply re-asks that member alone, which is
  /// [regenerateAtMessage] with the group. A group that lost its row or its
  /// members is read-only here, the same way it is for a send.
  Future<bool> restartGroupRound({
    required Conversation conversation,
    required ChatMessage userMessage,
  }) async {
    final group = _contextProvider.read<GroupChatProvider>().byId(
      conversation.groupChatId,
    );
    final assistants = _contextProvider.read<AssistantProvider>();
    final members = <Assistant>[];
    if (group != null) {
      for (final id in group.memberIds) {
        final assistant = assistants.getById(id);
        if (assistant != null) members.add(assistant);
      }
    }
    if (group == null || members.isEmpty) {
      onWarning?.call('group_unavailable');
      return false;
    }
    onHapticFeedback?.call();
    final result = await _chatActions.restartGroupRound(
      conversation: conversation,
      group: group,
      members: members,
      userMessage: userMessage,
    );
    if (!result.success) {
      if (result.errorMessage == 'in_flight') return false;
      if (result.errorMessage == 'group_has_no_members') {
        onWarning?.call('group_unavailable');
      } else if (result.errorMessage != 'not_a_user_message') {
        onError?.call(result.errorMessage ?? 'unknown_error');
      }
      return false;
    }
    return true;
  }

  /// Whether the group a conversation claims still exists.
  ///
  /// Guarded: reduced trees in tests do not provide the group list, and there
  /// nothing can be a live group.
  bool _groupRowExists(String? groupChatId) {
    if (groupChatId == null) return false;
    try {
      return _contextProvider.read<GroupChatProvider>().byId(groupChatId) !=
          null;
    } catch (_) {
      return false;
    }
  }

  ChatInputData _cloneInput(ChatInputData input) {
    return ChatInputData(
      text: input.text,
      quotes: input.quotes,
      imagePaths: List<String>.of(input.imagePaths),
      documents: List<DocumentAttachment>.of(input.documents),
      allowImagesApiRouting: input.allowImagesApiRouting,
      uiContext: input.uiContext,
      draftSubmission: input.draftSubmission,
    );
  }

  /// Delivers the head of [conversationId]'s queue, if it may land now.
  ///
  /// Only the head: one turn at a time keeps the order, and a user message that
  /// fails stays at the head (paused) instead of being skipped or lost. The
  /// background check belongs here rather than at the delegation: a generation
  /// that starts while the OS holds the isolate frozen is terminalised by the
  /// startup sweep, and the user comes back to an extra interrupted reply.
  Future<void> _drainQueuedInputIfReady(String conversationId) async {
    if (_drainingQueuedInputs.contains(conversationId) ||
        _pausedQueuedInputs.contains(conversationId) ||
        _chatService.contextCompression.blocksSending(conversationId)) {
      return;
    }
    final background = MobileBackgroundCoordinator.instance;
    await background.initialize();
    // Re-read after the await: the registration below is no longer synchronous
    // with the guard, so two dispatches in one turn of the event loop would both
    // take the same head.
    if (_drainingQueuedInputs.contains(conversationId) ||
        _pausedQueuedInputs.contains(conversationId)) {
      return;
    }
    if (!background.isForeground) return;
    final conversation = _chatService.getConversation(conversationId);
    if (conversation == null) return;
    if (_isConversationBusy(conversationId)) return;
    // A delegation's mail goes before the user's queue: it is the message the
    // finished step was waiting on, and the queue head behind it keeps its turn.
    final mail = _takeMail(conversationId);
    if (mail != null) {
      _drainingQueuedInputs.add(conversationId);
      notifyListeners();
      try {
        final started = await _startMailTurn(conversation, mail);
        if (!started) _putMailBack(conversationId, mail);
      } catch (_) {
        _putMailBack(conversationId, mail);
      } finally {
        _drainingQueuedInputs.remove(conversationId);
        notifyListeners();
      }
      return;
    }
    final queue = _queue[conversationId];
    if (queue == null || queue.isEmpty) return;

    final turn = queue.first;
    _drainingQueuedInputs.add(conversationId);
    notifyListeners();

    final drafts = _chatService.composerDrafts;
    // A queued message submits its own draft snapshot; anything else must leave
    // the composer exactly as the user left it.
    if (turn is QueuedUserInput) drafts?.submitting.add(conversationId);
    try {
      final delivered = switch (turn) {
        QueuedUserInput() => await _sendMessageToConversation(
          turn.input,
          conversation,
        ),
        QueuedSubagentResult() => await _deliverSubagentResult(turn),
      };
      // A delegation's result is dequeued even when its follow-up could not
      // start: the row is already written, so keeping it at the head would block
      // every later turn behind something the user cannot see or cancel.
      if (delivered || turn is QueuedSubagentResult) {
        queue.removeAt(0);
        if (queue.isEmpty) _queue.remove(conversationId);
      } else if (turn is QueuedUserInput &&
          _chatService.getConversation(conversationId) != null) {
        // Only the user's own message pauses the queue: it is the one the
        // composer can show and cancel, so a person can unstick it.
        _pausedQueuedInputs.add(conversationId);
      }
    } catch (_) {
      final submission = turn is QueuedUserInput
          ? turn.input.draftSubmission
          : null;
      if (drafts != null &&
          submission != null &&
          await drafts.wasSubmitted(submission.id)) {
        queue.removeAt(0);
        await drafts.finishSubmission(submission);
      } else if (turn is QueuedSubagentResult) {
        // A thrown delivery cannot be resumed by a person: its row is already
        // written and the composer can neither show nor cancel it. Leaving it at
        // the head would strand every message queued behind it, so it leaves and
        // the next turn reads the divider from the context.
        queue.removeAt(0);
        if (queue.isEmpty) _queue.remove(conversationId);
      } else if (_chatService.getConversation(conversationId) != null) {
        _pausedQueuedInputs.add(conversationId);
      }
    } finally {
      if (turn is QueuedUserInput) drafts?.submissionIdle(conversationId);
      _drainingQueuedInputs.remove(conversationId);
      _chatService.contextCompression.refreshInputStatus();
      notifyListeners();
    }
  }

  /// A finished delegation lands as one unit: its notice row, then the turn that
  /// reads it. Half of it would be a divider with no answer, or an answer with no
  /// divider.
  Future<bool> _deliverSubagentResult(QueuedSubagentResult turn) async {
    final notice = turn.notice;
    // Idempotent: the coordinator already wrote it when the child finished, so
    // the row survives a process killed while the app was in the background.
    await _chatService.addMessageDirectly(notice.conversationId, notice);
    // Only the conversation that received the row: reloading whichever one is on
    // screen rebuilds a window that did not change.
    await refreshTimelineAfterExternalWrite(notice.conversationId);
    if (!turn.followUp) return true;
    final conversation = _chatService.getConversation(notice.conversationId);
    if (conversation == null) return true;
    final outcome = await regenerateScheduledMessage(
      message: notice,
      conversation: conversation,
      assistant: turn.assistant,
      scheduledNotify: false,
      scheduledPreview: false,
    );
    if (!outcome.success) {
      // The row stays and the turn leaves the queue, so nothing retries — which
      // leaves the user reading "子代理完成 · X" followed by silence. Say why.
      onWarning?.call('subagent_follow_up_failed');
    }
    return outcome.success;
  }

  /// Regenerate response at a specific message.
  Future<bool> regenerateAtMessage(
    ChatMessage message, {
    bool assistantAsNewReply = false,
    bool allowImagesApiRouting = true,
    bool omitImages = false,
    String? expectedContextState,
    Assistant? assistantOverride,
    GroupChat? group,
    List<Assistant> members = const [],
  }) async {
    final conversation = _chatService
        .getConversation(message.conversationId)
        ?.copyWith();
    if (conversation == null) {
      return false;
    }

    // Set up image sanitization callback before regenerating
    _chatActions.onScheduleImageSanitize = onScheduleImageSanitize;

    onHapticFeedback?.call();
    final assistant =
        assistantOverride ??
        _contextProvider.read<AssistantProvider>().resolveConversationAssistant(
          conversation.assistantId,
        );
    await _clearSuggestionsFor(conversation.id);

    final result = await _chatActions.regenerateAtMessage(
      expectedContextState: expectedContextState,
      omitImages: omitImages,
      message: message,
      conversation: conversation,
      assistantOverride: assistant,
      assistantAsNewReply: assistantAsNewReply,
      allowImagesApiRouting: allowImagesApiRouting,
      group: group,
      members: members,
    );

    if (!result.success) {
      // A concurrent send/regenerate already owns this conversation.
      if (result.errorMessage == 'in_flight') return false;
      if (result.errorMessage == 'no_model') {
        onWarning?.call('no_model');
      } else {
        onError?.call(result.errorMessage ?? 'unknown_error');
      }
      return false;
    }

    return true;
  }

  Future<bool> continueAssistantMessageAfterToolAnswer(
    ChatMessage message, {
    bool allowImagesApiRouting = true,
  }) async {
    final conversation = currentConversation;
    if (conversation == null) {
      return false;
    }

    _chatActions.onScheduleImageSanitize = onScheduleImageSanitize;
    await _clearSuggestionsFor(conversation.id);

    final result = await _chatActions.continueAssistantMessageAfterToolAnswer(
      message: message,
      conversation: conversation,
      allowImagesApiRouting: allowImagesApiRouting,
    );

    if (!result.success) {
      if (result.errorMessage == 'in_flight') return false;
      if (result.errorMessage == 'no_model') {
        onWarning?.call('no_model');
      } else {
        onError?.call(result.errorMessage ?? 'unknown_error');
      }
      return false;
    }

    return true;
  }

  /// Stops the generation running in [conversationId], whichever conversation
  /// that is. Used by the subagent coordinator when the parent's turn — and with
  /// it the work it delegated — is cancelled.
  Future<void> cancelGenerationOf(String conversationId) =>
      _chatActions.cancelStreamingById(conversationId);

  /// Reloads the visible timeline after something outside the chat flow wrote a
  /// row into the open conversation.
  ///
  /// The timeline rebuilds on `externalWriteRevision`, which only the chat flow
  /// bumps; a background writer has to ask for the reload itself. Scheduling
  /// publishing does the same thing for the same reason.
  ///
  /// [conversationId] narrows it to the conversation the row belongs to: a write
  /// to some other chat must not rebuild the window on screen.
  Future<void> refreshTimelineAfterExternalWrite([
    String? conversationId,
  ]) async {
    if (conversationId != null && currentConversation?.id != conversationId) {
      return;
    }
    try {
      await _chatController.refreshTimelineAfterMutation();
    } catch (_) {
      // The next navigation re-reads the window anyway.
    }
  }

  /// Cancel the active streaming.
  Future<void> cancelStreaming() async {
    final conversation = currentConversation;
    final id = conversation?.id;
    if (conversation != null && conversation.isGroupConversation) {
      // Stop the round, not just the speaker: the loop is what would otherwise
      // start the next one.
      await _chatActions.cancelGroupRound(conversation.id);
      _chatService.contextCompression.resumeIfReady(conversation.id);
      unawaited(_drainQueuedInputIfReady(conversation.id));
      return;
    }
    await _chatActions.cancelStreaming(conversation);
    if (id != null) {
      _chatService.contextCompression.resumeIfReady(id);
      unawaited(_drainQueuedInputIfReady(id));
    }
  }

  @visibleForTesting
  static int? computeNextVersionSelection({
    required List<ChatMessage> versionsBefore,
    required Set<String> deletedMessageIds,
    required int? oldSelection,
  }) {
    final sorted = List<ChatMessage>.of(versionsBefore)
      ..sort((a, b) => a.version.compareTo(b.version));
    if (sorted.isEmpty) return null;

    final remainingVersions =
        sorted
            .where((message) => !deletedMessageIds.contains(message.id))
            .map((message) => message.version)
            .toSet()
            .toList()
          ..sort();
    if (remainingVersions.isEmpty) return null;

    final newSelection = oldSelection ?? sorted.last.version;
    final selectedVersionWasDeleted = sorted.any(
      (message) =>
          deletedMessageIds.contains(message.id) &&
          message.version == newSelection,
    );
    if (!selectedVersionWasDeleted) return newSelection;

    for (final version in remainingVersions.reversed) {
      if (version < newSelection) return version;
    }
    return remainingVersions.first;
  }

  @visibleForTesting
  static BatchDeletePlan buildBatchDeletePlan({
    required List<ChatMessage> messages,
    required Set<String> selectedMessageIds,
    required Map<String, int> versionSelections,
    bool deleteAllVersions = false,
  }) {
    if (selectedMessageIds.isEmpty || messages.isEmpty) {
      return BatchDeletePlan.empty;
    }

    final byGroup = <String, List<ChatMessage>>{};
    final deletedByGroup = <String, Set<String>>{};
    for (final message in messages) {
      final groupId = message.groupId ?? message.id;
      byGroup.putIfAbsent(groupId, () => <ChatMessage>[]).add(message);
      if (selectedMessageIds.contains(message.id)) {
        deletedByGroup.putIfAbsent(groupId, () => <String>{});
        if (!deleteAllVersions) {
          deletedByGroup[groupId]!.add(message.id);
        }
      }
    }

    if (deletedByGroup.isEmpty) return BatchDeletePlan.empty;

    final groups = <String, BatchDeleteGroupPlan>{};
    final nextVersionSelections = <String, int>{};
    final clearedVersionSelectionGroupIds = <String>{};

    for (final entry in deletedByGroup.entries) {
      final groupId = entry.key;
      final versionsBefore = List<ChatMessage>.of(
        byGroup[groupId] ?? const <ChatMessage>[],
      )..sort((a, b) => a.version.compareTo(b.version));
      final deletedMessageIds = deleteAllVersions
          ? versionsBefore.map((message) => message.id).toSet()
          : Set<String>.of(entry.value);
      final oldSelection =
          versionSelections[groupId] ??
          (versionsBefore.isNotEmpty ? versionsBefore.last.version : 0);
      final nextVersionSelection = computeNextVersionSelection(
        versionsBefore: versionsBefore,
        deletedMessageIds: deletedMessageIds,
        oldSelection: oldSelection,
      );

      groups[groupId] = BatchDeleteGroupPlan(
        groupId: groupId,
        versionsBefore: versionsBefore,
        deletedMessageIds: deletedMessageIds,
        nextVersionSelection: nextVersionSelection,
      );

      if (nextVersionSelection == null) {
        clearedVersionSelectionGroupIds.add(groupId);
      } else {
        nextVersionSelections[groupId] = nextVersionSelection;
      }
    }

    return BatchDeletePlan(
      groups: groups,
      nextVersionSelections: nextVersionSelections,
      clearedVersionSelectionGroupIds: clearedVersionSelectionGroupIds,
    );
  }

  Future<void> deleteMessages({
    required Set<String> messageIds,
    bool deleteAllVersions = false,
    String? expectedContextState,
  }) async {
    if (messageIds.isEmpty) return;

    // Only the selected groups matter for the plan; resolve their group ids
    // from the selected revisions, then load just those groups' versions.
    final selected = await _chatService.loadMessagesByIds(
      messageIds.toList(growable: false),
    );
    if (selected.isEmpty) return;
    // The confirmation dialog and the projection loads run before this, so
    // the user may have switched conversations since selecting. The loaded
    // revisions know which conversation they belong to; deleting against the
    // current one would silently no-op.
    final conversationId = selected.first.conversationId;
    bool isCurrentConversation() => currentConversation?.id == conversationId;
    final groupIds = selected
        .map((message) => message.groupId ?? message.id)
        .toSet();
    final scopedMessages = await _chatService.loadMessagesForGroups(
      conversationId,
      groupIds,
    );
    Map<String, int> selections = const <String, int>{};
    if (isCurrentConversation()) {
      selections = _chatController.versionSelections;
    } else {
      try {
        selections = _chatService.getVersionSelections(conversationId);
      } catch (_) {}
    }
    final plan = buildBatchDeletePlan(
      messages: scopedMessages,
      selectedMessageIds: messageIds,
      versionSelections: selections,
      deleteAllVersions: deleteAllVersions,
    );
    if (plan.isEmpty) return;

    // Deleting the row an active generation checkpoints into would make the
    // next streaming write hit a foreign key on deleted messages; stop the
    // generation first.
    final streamingMessageId = _chatActions.activeStreamingMessageId(
      conversationId,
    );
    if (streamingMessageId != null &&
        plan.deletedMessageIds.contains(streamingMessageId)) {
      await _chatActions.cancelStreaming(
        _chatService.getConversation(conversationId),
      );
    }

    final deletedMessageIds = await _chatService.deleteMessages(
      expectedContextState: expectedContextState,
      conversationId: conversationId,
      messageIds: plan.deletedMessageIds,
      versionSelectionChanges: {
        for (final groupId in plan.clearedVersionSelectionGroupIds)
          groupId: null,
        ...plan.nextVersionSelections,
      },
    );
    for (final id in deletedMessageIds) {
      _streamController.clearMessageState(id);
    }
    if (isCurrentConversation()) {
      _chatController.loadVersionSelections();
      _chatController.updateCurrentConversation(
        _chatService.getConversation(conversationId),
      );

      // scopedMessages holds every pre-deletion version of every affected
      // group, so the per-group survivors are complete.
      final survivingVersionsByGroup = <String, List<ChatMessage>>{};
      for (final message in scopedMessages) {
        final groupId = message.groupId ?? message.id;
        final survivors = survivingVersionsByGroup.putIfAbsent(
          groupId,
          () => <ChatMessage>[],
        );
        if (!deletedMessageIds.contains(message.id)) survivors.add(message);
      }
      await _chatController.refreshTimelineAfterMutation(
        removedRevisionIds: deletedMessageIds,
        survivingVersionsByGroup: survivingVersionsByGroup,
      );
    }
    notifyListeners();
  }

  /// Applies the exact revisions confirmed for one message group.
  Future<Set<String>> deleteMessageVersions({
    required ChatMessage message,
    required List<ChatMessage> versionsBefore,
    required Set<String> deletedMessageIds,
    String? expectedContextState,
  }) async {
    final gid = message.groupId ?? message.id;
    final conversationId = message.conversationId;
    bool isCurrentConversation() => currentConversation?.id == conversationId;
    final keepingCurrent = !deletedMessageIds.contains(message.id);
    final selections = isCurrentConversation()
        ? versionSelections
        : _chatService.getVersionSelections(conversationId);
    final streamingId = _chatActions.activeStreamingMessageId(conversationId);
    if (streamingId != null && deletedMessageIds.contains(streamingId)) {
      if (keepingCurrent &&
          !await _chatService.canDeleteOtherVersions(
            conversationId,
            message.id,
            deletedMessageIds,
          )) {
        return const {};
      }
      final active = _chatActions.activeStreamingMessageId(conversationId);
      if (active != null) {
        if (active != streamingId) return const {};
        await _chatActions.cancelStreamingById(conversationId);
      }
    }
    final removedIds = await _chatService.deleteMessages(
      conversationId: conversationId,
      messageIds: deletedMessageIds,
      versionSelectionChanges: {
        if (!keepingCurrent)
          gid: computeNextVersionSelection(
            versionsBefore: versionsBefore,
            deletedMessageIds: deletedMessageIds,
            oldSelection: selections[gid],
          ),
      },
      retainedMessageId: keepingCurrent ? message.id : null,
      expectedContextState: expectedContextState,
    );
    if (removedIds.isEmpty) return removedIds;
    for (final id in removedIds) {
      _streamController.clearMessageState(id);
    }
    if (isCurrentConversation()) {
      _chatController.updateCurrentConversation(
        _chatService.getConversation(conversationId),
      );
      _chatController.loadVersionSelections();
      await _chatController.refreshTimelineAfterMutation(
        removedRevisionIds: removedIds,
        survivingVersionsByGroup: {
          gid: [
            for (final candidate in versionsBefore)
              if (!removedIds.contains(candidate.id)) candidate,
          ],
        },
      );
    }
    notifyListeners();
    return removedIds;
  }

  // ============================================================================
  // Public Methods - Conversation Management
  // ============================================================================

  void _syncContextUsageConversation(String? conversationId) {
    _contextUsage?.setActiveConversation(conversationId);
  }

  /// Switch to an existing conversation.
  ///
  /// The caller flushes the current conversation's progress before invoking
  /// this; do not flush here again.
  Future<void> switchConversation(String id) async {
    final assistantProvider = _contextProvider.read<AssistantProvider>();

    // Reset processing state on switch
    resetFileProcessingIndicator();

    if (currentConversation?.id == id) return;

    final convo = _chatService.getCompleteConversation(id);
    if (convo != null) {
      _chatService.setCurrentConversation(id);
      _syncContextUsageConversation(id);
      // Assistant preference persistence runs concurrently with the window
      // load; setCurrentAssistant notifies before its disk write completes.
      final assistantSwitch = _assistantSwitchFor(
        assistantProvider,
        convo.assistantId,
      );
      await Future.wait([
        _chatController.setCurrentConversationAndLoad(convo),
        if (assistantSwitch != null) assistantSwitch,
      ]);
      // Arm the new list's initial position before listeners can paint it with
      // the previous conversation's scroll offset.
      onConversationSwitched?.call();
      restoreRetryUiFromStreamingState();
      notifyListeners();
      unawaited(_drainQueuedInputIfReady(id));
    }
  }

  /// Fetch phase of an animated conversation switch: loads the target
  /// conversation's initial window without committing any state, so the
  /// caller can keep the previous list covered until it is ready to commit
  /// via [commitConversationSwitch]. Returns null when the switch is a no-op
  /// or the conversation is gone.
  Future<PreparedConversationSwitch?> prepareConversationSwitch(
    String id,
  ) async {
    // Reset processing state on switch
    resetFileProcessingIndicator();

    if (currentConversation?.id == id) return null;

    final convo = _chatService.getCompleteConversation(id);
    if (convo == null) return null;

    // The assistant switch is deferred to commitConversationSwitch: it
    // notifies listeners and rewrites the global currentAssistantId, so
    // running it here would leak the side effect when this preparation is
    // superseded and discarded before commit.
    final window = await _chatController.fetchConversationWindow(convo);
    return PreparedConversationSwitch(conversation: convo, window: window);
  }

  /// Commit phase of an animated conversation switch: installs a snapshot
  /// previously fetched by [prepareConversationSwitch].
  void commitConversationSwitch(PreparedConversationSwitch prepared) {
    final id = prepared.conversation.id;
    _chatService.setCurrentConversation(id);
    _syncContextUsageConversation(id);
    _chatController.commitConversationWindow(
      prepared.window,
      onDeferredGroupDataLoaded: notifyListeners,
    );
    // Same concurrency as switchConversation: the assistant change notifies
    // before its disk write completes.
    final assistantProvider = _contextProvider.read<AssistantProvider>();
    final assistantSwitch = _assistantSwitchFor(
      assistantProvider,
      prepared.conversation.assistantId,
    );
    if (assistantSwitch != null) unawaited(assistantSwitch);
    // Arm the new list's initial position before listeners can paint it with
    // the previous conversation's scroll offset.
    onConversationSwitched?.call();
    restoreRetryUiFromStreamingState();
    notifyListeners();
    unawaited(_drainQueuedInputIfReady(id));
  }

  /// Starts persisting the assistant preference for a switch, or null when
  /// the assistant does not change.
  Future<void>? _assistantSwitchFor(
    AssistantProvider assistantProvider,
    String? convoAssistantId,
  ) {
    final assistant = assistantProvider.resolveConversationAssistant(
      convoAssistantId,
    );
    if (assistant == null ||
        assistantProvider.currentAssistantId == assistant.id) {
      return null;
    }
    return assistantProvider.setCurrentAssistant(assistant.id);
  }

  /// Returns this request's new or reused entry even if navigation changes
  /// while its preset messages are being persisted.
  ///
  /// [groupChatId] creates a topic of that group instead of a 1:1 chat; a group
  /// topic has no owning assistant, so preset messages are not injected.
  Future<Conversation?> createNewConversation({
    String? assistantId,
    String? groupChatId,
  }) async {
    // Flush current conversation progress before creating new
    await _chatActions.flushConversationProgress(currentConversation);
    if (!_contextProvider.mounted) return null;

    // Reset processing state on create
    resetFileProcessingIndicator();

    final ap = _contextProvider.read<AssistantProvider>();
    try {
      await ap.loaded;
    } catch (e) {
      onError?.call(e.toString());
      return null;
    }
    if (!_contextProvider.mounted) return null;
    final targetAssistantId = groupChatId == null
        ? (assistantId ?? ap.currentAssistantId)
        : null;
    final a = ap.getById(targetAssistantId ?? '');

    final existingEntryId = _chatService.composerDrafts
        ?.newEntry(targetAssistantId, groupChatId: groupChatId)
        ?.id;
    final conversation = await _chatService.createDraftConversation(
      title: groupChatId == null
          ? getTitleForLocale(_contextProvider)
          : AppLocalizations.of(_contextProvider)!.groupChatNewTopic,
      assistantId: targetAssistantId,
      groupChatId: groupChatId,
      reuseNewEntry: true,
    );

    final restoringEntry = existingEntryId == conversation.id;
    if (restoringEntry) {
      // Presets can already have persisted messages in an unsent new entry.
      await _chatController.setCurrentConversationAndLoad(conversation);
      if (currentConversation?.id != conversation.id) return conversation;
    } else {
      _chatController.setDraftConversation(conversation);
    }
    _syncContextUsageConversation(conversation.id);
    _streamController.clearAllState(
      keepMessageIds: _chatActions.activeStreamingMessageIds,
    );
    notifyListeners();

    if (restoringEntry) return conversation;

    // Inject assistant preset messages into new conversation (ordered)
    try {
      final presets = groupChatId == null
          ? ap.getPresetMessagesForAssistant(a?.id)
          : const <Map<String, dynamic>>[];
      if (presets.isNotEmpty && currentConversation != null) {
        final injected = <ChatMessage>[];
        for (final pm in presets) {
          final role = (pm['role'] == 'assistant') ? 'assistant' : 'user';
          final content = (pm['content'] ?? '').trim();
          if (content.isEmpty) continue;
          injected.add(
            await _chatService.addMessage(
              conversationId: conversation.id,
              role: role,
              content: content,
            ),
          );
        }
        // One batch append publishes the whole preset block with a single
        // notify instead of one per message.
        if (injected.isNotEmpty && currentConversation?.id == conversation.id) {
          await _chatController.appendPersistedTailMessages(injected);
        }
      }
    } catch (_) {}

    if (currentConversation?.id == conversation.id) onScrollToBottom?.call();
    return conversation;
  }

  Future<void> toggleTemporaryConversation() async {
    final convo = currentConversation;
    if (convo == null || messages.isNotEmpty) return;

    await _chatActions.flushConversationProgress(currentConversation);
    if (!_contextProvider.mounted) return;

    resetFileProcessingIndicator();

    if (_chatService.isTemporaryConversation(convo.id)) {
      await createNewConversation();
      return;
    }

    final ap = _contextProvider.read<AssistantProvider>();
    try {
      await ap.loaded;
    } catch (e) {
      onError?.call(e.toString());
      return;
    }
    if (!_contextProvider.mounted) return;
    final conversation = await _chatService.createDraftConversation(
      title: AppLocalizations.of(_contextProvider)!.temporaryChatTitle,
      assistantId: ap.currentAssistantId,
      temporary: true,
    );

    _chatController.setDraftConversation(conversation);
    _syncContextUsageConversation(conversation.id);
    _streamController.clearAllState(
      keepMessageIds: _chatActions.activeStreamingMessageIds,
    );
    notifyListeners();
    onScrollToBottom?.call();
  }

  /// Fork conversation at a specific message.
  Future<void> forkConversation(ChatMessage message) async {
    final sourceConversation = currentConversation;
    if (sourceConversation == null) return;
    final newConvo = await _chatService.forkConversationAtRevision(
      sourceConversationId: sourceConversation.id,
      sourceRevisionId: message.id,
      preserveVersions: _contextProvider
          .read<SettingsProvider>()
          .forkKeepMessageVersions,
    );

    // Navigation during the copy owns the current page. The service activates
    // the fork only while its original owner is still current.
    if (_chatService.currentConversationId != newConvo.id) return;
    // Switch to the new conversation
    _chatService.setCurrentConversation(newConvo.id);
    _syncContextUsageConversation(newConvo.id);
    await _chatController.setCurrentConversationAndLoad(newConvo);
    _restoreMessageUiState();
    onConversationSwitched?.call();
    notifyListeners();
    onScrollToBottom?.call();
  }

  /// Clear context (toggle truncate at tail).
  /// Sets or clears the current conversation's model override.
  ///
  /// Passing null for both makes the conversation follow the assistant again.
  Future<void> setConversationModel({
    String? providerKey,
    String? modelId,
  }) async {
    final convo = currentConversation;
    if (convo == null) return;
    final updated = await _chatService.setConversationModel(
      convo.id,
      providerKey: providerKey,
      modelId: modelId,
    );
    if (updated != null) {
      _chatController.updateCurrentConversation(updated);
      notifyListeners();
    }
  }

  Future<void> clearContext() async {
    final convo = currentConversation;
    if (convo == null) return;
    await _chatService.contextCompression.cancel(
      convo.id,
      reason: 'context_cleared',
    );
    await _clearSuggestionsFor(convo.id);
    await _chatService.clearConversationContext(convo.id);
    notifyListeners();
  }

  /// Dispatches compression with captured configuration; user input remains
  /// in the existing queue and is released only after an in-place commit.
  Future<String?> compressContext({
    required CompressContextOptions options,
    String? targetConversationId,
    String? beforeMessageId,
    Set<String>? effectiveMessageIds,
  }) async {
    final convo = targetConversationId == null
        ? currentConversation
        : _chatService.getConversation(targetConversationId);
    if (convo == null) return 'no_conversation';
    final conversationId = convo.id;
    try {
      final request = await buildCompressionRequest(
        conversationId,
        options: options,
        beforeMessageId: beforeMessageId,
        effectiveMessageIds: effectiveMessageIds,
      );
      await _chatService.contextCompression.start(conversationId, request);
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  Future<CompressionRequest> buildCompressionRequest(
    String conversationId, {
    required CompressContextOptions options,
    bool automatic = false,
    bool ownsContinuation = false,
    String? beforeMessageId,
    Set<String>? effectiveMessageIds,
    bool Function()? isCancelled,
    Future<bool> Function(ContextOperation)? acceptCandidate,
    CompressionConfig? configOverride,
    int? carryBudgetTokens,
    ({String providerKey, String modelId, ProviderConfig config})? nativeModel,
  }) async {
    final conversation = _chatService.getConversation(conversationId);
    if (conversation == null) throw StateError('conversation_not_found');
    final settings = _contextProvider.read<SettingsProvider>();
    final locale = Localizations.localeOf(_contextProvider).toLanguageTag();
    final quoteMarker = AppLocalizations.of(
      _contextProvider,
    )!.selectionQuoteMarker;
    final assistant = _contextProvider
        .read<AssistantProvider>()
        .resolveConversationAssistant(conversation.assistantId);
    final chatModel = _messageGenerationService.getModelConfig(
      settings,
      assistant,
      conversation: conversation,
    );
    final preferences =
        configOverride ??
        await _chatService.compressionConfig(
          conversationId,
          settings.compressionDefaults,
        );
    if (options.native) {
      // A tool loop owns its original connection even if the user selects
      // another model while that turn is still running.
      final provider = nativeModel?.providerKey ?? chatModel.providerKey;
      final model = nativeModel?.modelId ?? chatModel.modelId;
      if (provider == null || model == null) throw StateError('no_model');
      final config =
          nativeModel?.config ?? settings.getProviderConfig(provider);
      final referenceTime = DateTime.now();
      Future<ContextAssemblyPreview> prepare(CompressionSelection selection) =>
          _messageGenerationService.previewContextAssembly(
            conversationId: conversationId,
            providerKey: provider,
            modelId: model,
            assistantId: conversation.assistantId,
            messagesOverride: selection.input,
            // Coverage is recorded from this selection, so never trim it again.
            applyMessageLimit: false,
            forceResponses: true,
            promptTime: referenceTime,
          );
      final scope = nativeCompactionScope(config);
      bool cancelled() =>
          (isCancelled?.call() ?? false) ||
          nativeCompactionScope(settings.getProviderConfig(provider)) != scope;
      return CompressionRequest(
        options: options,
        codex: config.oauthProvider == OAuthProvider.chatgpt,
        carryBudgetTokens: carryBudgetTokens,
        prepareNative: (selection) async {
          final prepared = await prepare(selection);
          final body = await buildOpenAIResponsesBody(
            nativeResponsesConfig(config),
            model,
            RequestHistoryContext.identify(prepared.apiMessages),
            tools: [...prepared.tools, ...prepared.mcpTools],
          );
          return await prepared.imageContext?.project(
                body,
                preserveSources: true,
              ) ??
              body;
        },
        automatic: automatic,
        ownsContinuation: ownsContinuation,
        acceptCandidate: acceptCandidate,
        config: preferences,
        model: '$provider / $model',
        quoteMarker: quoteMarker,
        beforeMessageId: beforeMessageId,
        effectiveMessageIds: effectiveMessageIds,
        locale: locale,
        isCancelled: cancelled,
        loadReference: (selection) async =>
            (await prepare(selection)).referenceText,
        compactNative: (selection, requestId) async {
          final prepared = await prepare(selection);
          return ChatApiService.compactHistory(
            config: config,
            modelId: model,
            messages: prepared.apiMessages,
            tools: [...prepared.tools, ...prepared.mcpTools],
            imageContext: prepared.imageContext,
            requestId: requestId,
            conversationId: conversationId,
            extraHeaders: _generationController.buildCustomHeaders(assistant),
            isCancelled: cancelled,
            requestTimeout: preferences.requestTimeout,
            retention:
                (options.carry ?? preferences.nativeCarryOriginals).mode ==
                    CarryMode.unset
                ? NativeUserRetention.auto
                : NativeUserRetention.none,
          );
        },
      );
    }
    final model = resolveCompressContextModel(
      compressProvider: preferences.providerId,
      compressModelId: preferences.modelId,
      currentProvider: chatModel.providerKey,
      currentModelId: chatModel.modelId,
    );
    final provider = model.providerKey;
    final modelId = model.modelId;
    if (provider == null || modelId == null) throw StateError('no_model');
    final config = settings.getProviderConfig(provider);
    if (!config.enabled || config.disabledModels.contains(modelId)) {
      throw StateError('no_model');
    }
    if (preferences.providerId != null &&
        !settings.providerConfigs.containsKey(provider)) {
      throw StateError('no_model');
    }
    final library = _chatService.chatRepositoryOrNull?.compression;
    if (preferences.templateId == 'original' && library != null) {
      await library.importOriginalPrompt(settings.compressPrompt);
    }
    final template = library == null
        ? builtInCompressionTemplatesForLocale(
            locale,
          ).firstWhere((t) => t.id == preferences.templateId)
        : await library.template(preferences.templateId, locale: locale);
    final reasoning = settings.compressGenerationReasoningFor(assistant);
    // Revalidate live instructions after generation without treating passage of
    // time in prompt placeholders as a user edit.
    final referenceTime = DateTime.now();

    final spec = ModelSpecResolver.instance.spec(config, modelId);
    return CompressionRequest(
      options: options,
      carryBudgetTokens: carryBudgetTokens,
      carryProviderKind: chatModel.providerKey == null
          ? ProviderKind.openai
          : ProviderConfig.classify(
              chatModel.providerKey!,
              explicitType: settings
                  .getProviderConfig(chatModel.providerKey!)
                  .providerType,
            ),
      model: '$provider / $modelId',
      quoteMarker: quoteMarker,
      config: preferences,
      template: template,
      contextWindowTokens: spec.contextWindow,
      maxOutputTokens: spec.maxOutput,
      locale: locale,
      automatic: automatic,
      beforeMessageId: beforeMessageId,
      effectiveMessageIds: effectiveMessageIds,
      ownsContinuation: ownsContinuation,
      isCancelled: isCancelled,
      acceptCandidate: acceptCandidate,
      loadReference:
          !preferences.includeReference ||
              chatModel.providerKey == null ||
              chatModel.modelId == null
          ? null
          : (selection) async =>
                _messageGenerationService.compressionReferenceText(
                  promptTime: referenceTime,
                  conversationId: conversationId,
                  modelId: chatModel.modelId!,
                  assistantId: conversation.assistantId,
                  messages: selection.input,
                ),
      generate: (prompt, requestId, maxTokens, onUsage) =>
          ChatApiService.generateMessage(
            conversationId: conversationId,
            requestId: requestId,
            config: config,
            modelId: modelId,
            reasoning: reasoning,
            textOnly: true,
            maxTokens: maxTokens,
            retryOverride: const AutoRetryOptions.defaults(),
            requestTimeout: preferences.requestTimeout,
            onUsage: (update) => onUsage(update.usage),
            messages: [
              {'role': 'user', 'content': prompt},
            ],
          ),
    );
  }

  Future<void> compressAndRetryContext(
    ChatMessage failed, {
    required List<MessagePart> originalParts,
  }) async {
    final id = failed.conversationId;
    try {
      if (_isConversationBusy(id) || currentConversation?.id != id) {
        throw StateError('context_changed');
      }
      final snapshot = await _chatService.loadContextSnapshot(id);
      if (!_contextProvider.mounted) return;
      if (snapshot.messages.lastOrNull?.id != failed.id ||
          !listEquals(snapshot.messages.last.parts, failed.parts)) {
        throw StateError('context_changed');
      }
      final user = snapshot.messages.where(isCompressionUserMessage).lastOrNull;
      if (user == null) throw StateError('no_messages');
      final settings = _contextProvider.read<SettingsProvider>();
      final config = await _chatService.compressionConfig(
        id,
        settings.compressionDefaults,
      );
      final request = await buildCompressionRequest(
        id,
        options: CompressContextOptions(
          mode: CompressContextLimitMode.keepRecent,
          keepUserMessages: config.keepRecentUserTurns < 1
              ? 1
              : config.keepRecentUserTurns,
        ),
        beforeMessageId: user.id,
        ownsContinuation: true,
      );
      final task = await _chatService.contextCompression.runAtSafePoint(
        id,
        request,
      );
      if (task.phase != CompressionPhase.completed) {
        if (_hasQueued(id) && _pausedQueuedInputs.add(id)) {
          _chatService.contextCompression.refreshInputStatus();
        }
        onError?.call(task.error ?? 'compression_incomplete');
        return;
      }
      final current = await _chatService.loadContextSnapshot(id);
      if (current.messages.lastOrNull?.id != failed.id ||
          !listEquals(current.messages.last.parts, failed.parts) ||
          currentConversation?.id != id) {
        throw StateError('context_changed');
      }
      // The error bubble is presentation, not assistant output. Restore the
      // captured protocol parts before resuming the same response.
      await _chatService.updateMessage(failed.id, parts: originalParts);
      final result = await _chatActions.continueAssistantMessageAfterToolAnswer(
        message: current.messages.last.copyWith(parts: originalParts),
        conversation: _chatService.getConversation(id)!,
      );
      if (!result.success) {
        onError?.call(result.errorMessage ?? 'context_changed');
      }
    } catch (error) {
      onError?.call(error.toString());
    }
  }

  Future<CompressionRequestPreview> previewCompressionRequest(
    String conversationId,
    CompressContextOptions options,
    CompressionConfig config, {
    required Future<ConversationContextHistory> history,
  }) async {
    final snapshot = await history;
    final request = await buildCompressionRequest(
      conversationId,
      options: options,
      configOverride: config,
    );
    final selection = await _selectPreviewHistory(snapshot, options);
    if (selection.missingOriginals) {
      throw StateError('native_compaction_originals_unavailable');
    }
    final messages = await _chatService.messagesForCompression(
      selection.input,
      includeAttachmentsAndTools: options.includeAttachmentsAndTools,
      quoteMarker: request.quoteMarker,
    );
    final background = await request.loadReference?.call(selection) ?? '';
    final planner = CompressionPlanner(
      request: request,
      materials: [],
      previousSummary: '',
      background: background,
    );
    return _previewCompressionMaterials(
      planner,
      messages,
      options,
      request.quoteMarker,
    );
  }

  /// Update current conversation reference.
  void updateCurrentConversation(Conversation? conversation) {
    _chatController.updateCurrentConversation(conversation);
    notifyListeners();
  }

  Future<bool> loadMoreBefore() async {
    final loaded = await _chatController.loadMoreBefore();
    if (!loaded) return false;
    _restoreMessageUiState();
    notifyListeners();
    return true;
  }

  Future<bool> loadMoreAfter() async {
    final loaded = await _chatController.loadMoreAfter();
    if (!loaded) return false;
    _restoreMessageUiState();
    notifyListeners();
    return true;
  }

  Future<bool> loadUntilMessageVisible(String messageId) async {
    final loaded = await _chatController.loadUntilMessageVisible(messageId);
    if (!loaded) return false;
    _restoreMessageUiState();
    notifyListeners();
    return true;
  }

  /// Set selected version for a message group.
  Future<void> setSelectedVersion(String groupId, int version) async {
    final cid = currentConversation?.id;
    if (cid != null) {
      await _clearSuggestionsFor(cid);
    }
    await _chatController.setSelectedVersion(groupId, version);
    notifyListeners();
  }

  // ============================================================================
  // Public Methods - UI State
  // ============================================================================

  /// Restore per-message UI states after switching conversations.
  void restoreMessageUiState() {
    _restoreMessageUiState();
    notifyListeners();
  }

  /// Re-apply auto-retry countdown from still-running background streams.
  void restoreRetryUiFromStreamingState() {
    final cid = currentConversation?.id;
    if (cid != null) _chatActions.restoreRetryUi(cid);
  }

  void _restoreMessageUiState() {
    _streamController.pruneOffWindowState({
      ..._chatActions.activeStreamingMessageIds,
      for (final message in messages) message.id,
    });
    for (int i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (m.role == 'assistant') {
        _streamController.restoreMessageUiState(
          m,
          getToolEventsFromDb: (id) => _chatService.getToolEventsForMessage(m),
        );

        final cleanedContent = _chatService.migrateLegacyGeminiThoughtSignature(
          m.content,
          m.id,
        );
        if (cleanedContent != m.content) {
          final updated = m.copyWith(content: cleanedContent);
          _chatController.replaceMessageSnapshot(updated);
          unawaited(_chatService.updateMessage(m.id, content: cleanedContent));
        }

        // Clean up any inline base64 images persisted from earlier runs
        onScheduleImageSanitize?.call(
          m.id,
          messages[i].content,
          immediate: true,
        );
      }
    }
    restoreRetryUiFromStreamingState();
  }

  /// Serialize reasoning segments to JSON string.
  String serializeReasoningSegments(
    List<stream_ctrl.ReasoningSegmentData> segments,
  ) {
    return _streamController.serializeReasoningSegments(segments);
  }

  /// Collapse message versions to show only selected version per group.
  List<ChatMessage> collapseVersions(List<ChatMessage> items) {
    return _chatController.collapseVersions(items);
  }

  /// Group messages by their groupId.
  Map<String, List<ChatMessage>> groupMessagesByGroup() {
    return _chatController.groupMessagesByGroup();
  }

  /// Test entry for [_maybeGenerateSummaryFor].
  @visibleForTesting
  Future<void> debugMaybeGenerateSummaryFor(String conversationId) =>
      _maybeGenerateSummaryFor(conversationId);

  /// Test entry for [_maybeGenerateTitleFor].
  @visibleForTesting
  Future<void> debugMaybeGenerateTitleFor(
    String conversationId, {
    bool force = false,
  }) => _maybeGenerateTitleFor(conversationId, force: force);

  // ============================================================================
  // Title Generation
  // ============================================================================

  /// Generate title for a conversation if needed.
  Future<void> _maybeGenerateTitleFor(
    String conversationId, {
    bool force = false,
  }) async {
    final convo = _chatService.getConversation(conversationId);
    if (convo == null) return;
    // An untitled conversation and a placeholder-titled one (including a group
    // topic's `新话题`) are both unnamed, and both get named here.
    if (!force && !_chatService.isPlaceholderTitle(convo.title)) return;

    final settings = _contextProvider.read<SettingsProvider>();
    if (!settings.isTitleGenerationEnabled) return;
    // One title request per conversation at a time: two rounds that finish
    // back to back must not race two renames over each other.
    if (!_titlesInFlight.add(conversationId)) return;

    try {
      final assistantProvider = _contextProvider.read<AssistantProvider>();
      // A group topic has no conversation assistant — asking for one would
      // resolve whichever assistant the user happens to have selected.
      final assistant = convo.isGroupConversation
          ? null
          : assistantProvider.resolveConversationAssistant(convo.assistantId);
      final model = resolveTitleModel(
        settings,
        conversation: convo,
        assistant: assistant,
      );
      final provKey = model.providerKey;
      final mdlId = model.modelId;
      if (provKey == null || mdlId == null) return;
      final cfg = settings.getProviderConfig(provKey);
      final reasoning = settings.titleGenerationReasoningFor(assistant);
      final locale = Localizations.localeOf(_contextProvider).toLanguageTag();

      // Build content from messages (shared with the side drawer title path;
      // both cache and paging paths collect the same ~3000-char tail window)
      final content = await _chatService.generateTitleSource(
        convo.id,
        line: convo.isGroupConversation
            ? GroupTranscript.titleLine(
                (id) => id == null ? null : assistantProvider.getById(id),
              )
            : null,
      );

      String prompt = settings.titlePrompt
          .replaceAll('{locale}', locale)
          .replaceAll('{content}', content);

      try {
        final title = (await ChatApiService.generateText(
          conversationId: convo.id,
          config: cfg,
          modelId: mdlId,
          prompt: prompt,
          reasoning: reasoning,
          skipImageParsing: true,
        )).trim();
        if (title.isNotEmpty) {
          await _chatService.renameConversation(convo.id, title);
          if (currentConversation?.id == convo.id) {
            _chatController.updateCurrentConversation(
              _chatService.getConversation(convo.id),
            );
            notifyListeners();
          }
        } else {
          onBackgroundTaskError?.call(
            BackgroundTaskKind.title,
            'empty_response',
          );
        }
      } catch (e) {
        FlutterLogger.log(
          '[TitleGen] Generation failed: $e',
          tag: 'HomeViewModel',
        );
        onBackgroundTaskError?.call(BackgroundTaskKind.title, e);
      }
    } finally {
      _titlesInFlight.remove(conversationId);
    }
  }

  /// Force generate title for the current conversation.
  Future<void> generateTitle({bool force = false}) async {
    final cid = currentConversation?.id;
    if (cid != null) {
      await _maybeGenerateTitleFor(cid, force: force);
    }
  }

  // ============================================================================
  // Summary Generation
  // ============================================================================

  /// Generate summary for a conversation if conditions are met.
  /// Triggers after the configured number of new messages since last summary.
  Future<void> _maybeGenerateSummaryFor(String conversationId) async {
    final convo = _chatService.getConversation(conversationId);
    if (convo == null) return;
    // Summaries only feed past-conversation search; temporary chats are never searchable.
    if (_chatService.isTemporaryConversation(convo.id)) return;
    // Same reason as memory: the summary would be filed under whichever
    // assistant happens to be selected, for a conversation it does not own.
    if (convo.isGroupConversation) return;

    final settings = _contextProvider.read<SettingsProvider>();
    if (!_chatService.isMessageCountKnown(conversationId)) return;
    final msgCount = _chatService.getMessageCount(conversationId);
    final assistantProvider = _contextProvider.read<AssistantProvider>();

    // Get assistant for this conversation
    final assistant = assistantProvider.resolveConversationAssistant(
      convo.assistantId,
    );

    final reasoning = settings.summaryGenerationReasoningFor(assistant);

    final legacy = settings.legacyMemoryMode;
    if (legacy) {
      if (assistant?.allowPastConversationRecall != true) return;
    } else if (!MemoryPipelineService.shouldGenerateConversationSummary(
      allowPastConversationRecall:
          assistant?.allowPastConversationRecall == true,
      generateConversationSummary:
          assistant?.generateConversationSummary == true,
    )) {
      return;
    }

    final triggerMessageCount =
        assistant?.recentChatsSummaryMessageCount ??
        Assistant.defaultRecentChatsSummaryMessageCount;
    if (msgCount == 0 ||
        msgCount - convo.lastSummarizedMessageCount < triggerMessageCount) {
      return;
    }

    // Use summary model if configured, else fall back to title model, then current model
    final provKey =
        settings.summaryModelProvider ??
        settings.titleModelProvider ??
        assistant?.chatModelProvider ??
        settings.currentModelProvider;
    final mdlId =
        settings.summaryModelId ??
        settings.titleModelId ??
        assistant?.chatModelId ??
        settings.currentModelId;
    if (provKey == null || mdlId == null) return;

    final cfg = settings.getProviderConfig(provKey);

    // Get all messages and filter user messages
    final msgs = await _chatService.loadMessages(convo.id);
    final allUserMsgs = msgs
        .where((m) => m.role == 'user' && m.content.trim().isNotEmpty)
        .toList();

    if (allUserMsgs.isEmpty) return;

    // Get previous summary (empty string if first time)
    final previousSummary = (convo.summary ?? '').trim();

    // Get only the recent user messages since last summarization
    // Calculate how many user messages were in the last summarized state
    final lastSummarizedMsgCount = (convo.lastSummarizedMessageCount < 0)
        ? 0
        : convo.lastSummarizedMessageCount;
    final msgsAtLastSummary = msgs.take(lastSummarizedMsgCount).toList();
    final userMsgsAtLastSummary = msgsAtLastSummary
        .where((m) => m.role == 'user' && m.content.trim().isNotEmpty)
        .length;

    // Get new user messages since last summary
    final newUserMsgs = allUserMsgs.skip(userMsgsAtLastSummary).toList();
    if (newUserMsgs.isEmpty) return;

    final recentMessages = newUserMsgs
        .map((m) => m.content.trim())
        .join('\n\n');

    // Truncate if too long
    final content = recentMessages.length > 2000
        ? recentMessages.substring(0, 2000)
        : recentMessages;

    final prompt = settings.summaryPrompt
        .replaceAll('{previous_summary}', previousSummary)
        .replaceAll('{user_messages}', content);

    final traceHandle = legacy ? null : _beginSummaryTrace(convo, assistant);
    final traceStep = traceHandle?.beginStep(
      MemoryTraceStepKind.conversationSummary,
    );
    traceStep?.appendPrompt(prompt);

    try {
      final summary = (await ChatApiService.generateText(
        conversationId: convo.id,
        config: cfg,
        modelId: mdlId,
        prompt: prompt,
        reasoning: reasoning,
        skipImageParsing: true,
      )).trim();
      traceStep?.appendResponse(summary);

      if (summary.isNotEmpty) {
        await _chatService.updateConversationSummary(
          convo.id,
          summary,
          msgCount,
        );
        traceStep?.addMutation(
          MemoryTraceMutation(
            kind: MemoryTraceMutationKind.conversationSummaryWritten,
            targetId: convo.id,
            before: previousSummary.isEmpty ? null : previousSummary,
            after: summary,
          ),
        );
      }
      traceStep?.finish(MemoryTraceStepStatus.success);
      traceHandle?.commit(advanced: summary.isNotEmpty);
      if (summary.isNotEmpty) {
        if (currentConversation?.id == convo.id) {
          _chatController.updateCurrentConversation(
            _chatService.getConversation(convo.id),
          );
          notifyListeners();
        }
      } else {
        onBackgroundTaskError?.call(
          BackgroundTaskKind.summary,
          'empty_response',
        );
      }
    } catch (e) {
      // Keep the old summary when background generation fails.
      traceStep?.finish(MemoryTraceStepStatus.failed, error: e.toString());
      traceHandle?.commit(error: e.toString());
      onBackgroundTaskError?.call(BackgroundTaskKind.summary, e);
    }
  }

  /// Open a trace for background summary generation (feeds past-conversation
  /// recall). Never throws.
  MemoryTraceHandle? _beginSummaryTrace(
    Conversation convo,
    Assistant? assistant,
  ) {
    // Temporary chats are discarded on exit; keep their traces out of the UI.
    if (_chatService.isTemporaryConversation(convo.id)) {
      return null;
    }
    try {
      return MemoryTraceRecorder.instance.begin(
        trigger: MemoryTraceTrigger.conversationSummary,
        scope: assistant == null
            ? MemoryTraceScope.global
            : memoryTraceScopeOf(assistant.memoryWriteScope),
        conversationId: convo.id,
        conversationTitle: convo.title,
        assistantId: assistant?.id,
        assistantName: assistant?.name,
      );
    } catch (_) {
      return null;
    }
  }

  // ============================================================================
  // Chat Suggestions
  // ============================================================================

  final Map<String, Object> _suggestionRequests = {};

  /// The suggestions the composer may show: the current conversation's list,
  /// gated the same way generation is (global master, per-assistant opt-out).
  List<String> get visibleChatSuggestions {
    final conversation = currentConversation;
    if (conversation == null) return const <String>[];
    final settings = _contextProvider.read<SettingsProvider>();
    final assistant = _contextProvider
        .read<AssistantProvider>()
        .resolveConversationAssistant(conversation.assistantId);
    if (!settings.isSuggestionGenerationAllowedFor(assistant)) {
      return const <String>[];
    }
    return conversation.chatSuggestions;
  }

  /// Test entry point: runs one suggestion pass for [conversationId].
  Future<void> debugMaybeGenerateSuggestionsFor(String conversationId) =>
      _maybeGenerateSuggestionsFor(conversationId);

  Future<void> _clearSuggestionsFor(String conversationId) async {
    _suggestionRequests.remove(conversationId);
    final convo = _chatService.getConversation(conversationId);
    if (convo == null || convo.chatSuggestions.isEmpty) return;
    await _chatService.clearConversationSuggestions(conversationId);
    if (currentConversation?.id == conversationId) {
      _chatController.updateCurrentConversation(
        _chatService.getConversation(conversationId),
      );
      notifyListeners();
    }
  }

  Future<void> _maybeGenerateSuggestionsFor(String conversationId) async {
    final convo = _chatService.getConversation(conversationId);
    if (convo == null) return;
    // A group decides who answers, not an assistant-scoped hint: the generator
    // would resolve the selected assistant and write its suggestions into a
    // conversation that assistant does not own.
    if (convo.isGroupConversation) return;

    final settings = _contextProvider.read<SettingsProvider>();

    // Read context-dependent inputs before the async gap below.
    final assistantProvider = _contextProvider.read<AssistantProvider>();
    final assistant = assistantProvider.resolveConversationAssistant(
      convo.assistantId,
    );
    // The global switch is the master; a per-assistant opt-out only narrows it.
    if (!settings.isSuggestionGenerationAllowedFor(assistant)) return;
    final chatModel = resolveChatModel(
      settings,
      conversation: convo,
      assistant: assistant,
    );
    final provKey = settings.suggestionModelProvider ?? chatModel.providerKey;
    final mdlId = settings.suggestionModelId ?? chatModel.modelId;
    if (provKey == null || mdlId == null) return;
    final locale = Localizations.localeOf(_contextProvider).toLanguageTag();
    final reasoning = settings.suggestionGenerationReasoningFor(assistant);

    final request = Object();
    _suggestionRequests[conversationId] = request;
    final truncateIndex = _chatService.getContextStartIndex(conversationId);
    final prompt = settings.suggestionPrompt;
    bool isCurrent() =>
        identical(_suggestionRequests[conversationId], request) &&
        // Re-resolved rather than reusing the snapshot read above: an opt-out
        // that lands while the request is in flight must discard the reply, and
        // the snapshot still says "allowed".
        settings.isSuggestionGenerationAllowedFor(
          assistantProvider.resolveConversationAssistant(convo.assistantId),
        ) &&
        settings.suggestionPrompt == prompt &&
        _chatService.getConversation(conversationId) != null &&
        _chatService.getContextStartIndex(conversationId) == truncateIndex;

    Future<List<ChatMessage>> loadSelectedMessages() async {
      final loaded = await _chatService.loadMessages(conversationId);
      // A background conversation must use its own selected versions, even
      // when a different conversation is now displayed by the controller.
      return _chatController.collapseVersions(
        loaded,
        selections: _chatService.getVersionSelections(conversationId),
      );
    }

    try {
      final msgs = await loadSelectedMessages();
      if (!isCurrent()) return;
      final content = ChatSuggestionService.buildContent(
        msgs,
        truncateIndex: truncateIndex,
      );
      if (content.isEmpty) return;
      final sourceMessageId = msgs.last.id;
      await _chatService.clearConversationSuggestions(conversationId);
      if (!isCurrent()) return;
      final suggestions = await _suggestionService.generate(
        conversationId: conversationId,
        settings: settings,
        providerKey: provKey,
        modelId: mdlId,
        messages: msgs,
        truncateIndex: truncateIndex,
        locale: locale,
        reasoning: reasoning,
      );
      // An empty array is a valid decision to offer no suggestions.
      if (suggestions.isEmpty || !isCurrent()) return;

      final latestMessages = await loadSelectedMessages();
      if (!isCurrent() ||
          latestMessages.isEmpty ||
          latestMessages.last.id != sourceMessageId ||
          ChatSuggestionService.buildContent(
                latestMessages,
                truncateIndex: truncateIndex,
              ) !=
              content) {
        return;
      }

      await _chatService.updateConversationSuggestions(
        conversationId,
        suggestions,
      );
      if (currentConversation?.id == conversationId) {
        _chatController.updateCurrentConversation(
          _chatService.getConversation(conversationId),
        );
        notifyListeners();
      }
    } catch (e) {
      if (!isCurrent()) return;
      FlutterLogger.log(
        '[SuggestionGen] Generation failed: $e',
        tag: 'HomeViewModel',
      );
      onBackgroundTaskError?.call(BackgroundTaskKind.suggestions, e);
    } finally {
      if (identical(_suggestionRequests[conversationId], request)) {
        _suggestionRequests.remove(conversationId);
      }
    }
  }

  // ============================================================================
  // Model Capability Checks
  // ============================================================================

  bool isReasoningModel(String providerKey, String modelId) {
    return _generationController.isReasoningModel(providerKey, modelId);
  }

  bool isToolModel(String providerKey, String modelId) {
    return _generationController.isToolModel(providerKey, modelId);
  }

  bool isReasoningEnabled(ReasoningRequest r) {
    return _generationController.isReasoningEnabled(r);
  }

  // ============================================================================
  // Cleanup
  // ============================================================================

  /// Flush current conversation progress (for switching/creating).
  Future<void> flushCurrentConversationProgress() async {
    await _chatActions.flushConversationProgress(currentConversation);
  }

  /// Clean up message state (reasoning, tools, etc.) for removed messages.
  void cleanupMessageState(List<String> messageIds) {
    for (final id in messageIds) {
      _streamController.clearMessageState(id);
    }
  }
}

Future<CompressionSelection> _selectPreviewHistory(
  ConversationContextHistory history,
  CompressContextOptions options,
) => Isolate.run(
  () => selectCompressionHistory(history.messages, history.operations, options),
);

Future<CompressionRequestPreview> _previewCompressionMaterials(
  CompressionPlanner planner,
  List<ChatMessage> messages,
  CompressContextOptions options,
  String Function(int) quoteMarker,
) => Isolate.run(() {
  planner.materials.addAll(
    buildCompressRequestContents(
      messages.where((m) => !ContextOperation.isSummary(m)).toList(),
      options,
      quoteMarker: quoteMarker,
    ),
  );
  planner.previousSummary = messages
      .where(ContextOperation.isSummary)
      .map((m) => m.content)
      .join('\n\n');
  return planner.preview();
});
