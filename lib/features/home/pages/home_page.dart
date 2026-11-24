import '../../chat/controllers/conversation_find_controller.dart';
import '../../chat/models/conversation_find_candidate.dart';
import '../../chat/services/conversation_find_service.dart';
import '../../chat/widgets/conversation_find_bar.dart';
import '../../../shared/widgets/app_selection_area.dart';
import '../../../shared/widgets/source_rect_scroll.dart';
import '../../../shared/markdown/kelivo_markdown_extensions.dart';
import 'package:Cuplivo/features/intelligent_ui/host/ui_search_navigation.dart';
import '../../intelligent_ui/host/ui_host_scope.dart';
import '../../chat/widgets/context_dialog.dart';
import '../../chat/widgets/image_context_panel.dart';
import '../../../core/models/context_compression_task.dart';
import '../../../core/models/context_operation.dart';
import '../services/tool_approval_service.dart';
import '../../chat/widgets/compress_context_options_dialog.dart';
import '../../chat/widgets/context_operation_actions.dart';
import '../../chat/widgets/context_compression_status.dart';
import '../../browser/browser_navigation.dart';
import 'package:Cuplivo/shared/text_input/message_editing_controller.dart';
import '../../chat/controllers/quote_editing_controller.dart';
import '../../chat/widgets/quote_interaction_scope.dart';
import '../../../core/models/quote_ref.dart';
import '../../../core/services/chat/chat_service.dart';
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart'
    show kIsWeb, mapEquals, ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MissingPluginException, Clipboard, ClipboardData, LogicalKeyboardKey;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:provider/provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../desktop/desktop_tab.dart';
import '../../../main.dart';
import '../../../shared/widgets/interactive_drawer.dart';
import '../../../shared/widgets/visible_route_theme.dart';
import '../../../shared/widgets/selection_back_scope.dart';
import '../../../shared/responsive/breakpoints.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/design_tokens.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/hotkey_provider.dart';
import '../../../core/services/model_spec/model_spec_resolver.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../group_chat/group_navigation.dart';
import '../../../core/providers/quick_phrase_provider.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/providers/world_book_provider.dart';
import '../../../core/models/quick_phrase.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/compress_context_options.dart';
import '../../../core/services/android_process_text.dart';
import '../../../core/services/incoming_share_service.dart';
import '../../../utils/platform_utils.dart';
import '../../../desktop/search_provider_popover.dart';
import '../../../desktop/reasoning_level_popover.dart';
import '../../../desktop/context_usage_popover.dart';
import '../../../desktop/tools_popover.dart';
import '../../../desktop/workspace_dialog.dart';
import '../../../desktop/skills_popover.dart';
import '../../../desktop/mini_map_popover.dart';
import '../../../desktop/quick_phrase_popover.dart';
import '../../../desktop/instruction_injection_popover.dart';
import '../../../desktop/world_book_popover.dart';
import '../../../icons/lucide_adapter.dart';
import '../../chat/widgets/bottom_tools_sheet.dart';
import '../../chat/widgets/chat_tools_sheet.dart';
import '../../chat/utils/ensure_conversation.dart';
import '../../chat/widgets/context_management_sheet.dart';
import '../../chat/widgets/reasoning_level_sheet.dart';
import '../../search/widgets/search_settings_sheet.dart';
import '../../group_chat/widgets/group_reasoning_sheet.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/group_chat.dart';
import '../../chat/widgets/frosted/chat_frosted_backdrop.dart';
import '../../chat/widgets/chat_assistant_background.dart';
import '../../model/widgets/model_select_sheet.dart';
import '../../mcp/pages/mcp_page.dart';
import '../../provider/pages/providers_page.dart';
import '../../quick_phrase/pages/quick_phrases_page.dart';
import '../../quick_phrase/widgets/quick_phrase_menu.dart';
import '../../workspace/widgets/skills/conversation_skills_sheet.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/mini_map_sheet.dart';
import '../widgets/instruction_injection_sheet.dart';
import '../widgets/world_book_sheet.dart';
import '../widgets/learning_prompt_sheet.dart';
import '../widgets/scroll_nav_buttons.dart';
import '../widgets/message_list_view.dart';
import '../widgets/chat_input_section.dart';
import '../widgets/conversation_system_prompt_button.dart';
import '../widgets/chat_input_overlay_layout.dart';
import '../widgets/chat_selection_app_bar.dart';
import '../widgets/chat_selection_action_bar.dart';
import '../widgets/user_message_edit_overlay.dart';
import '../utils/model_display_helper.dart';
import '../utils/chat_layout_constants.dart';
import '../../../core/models/chat_owner.dart';
import '../../harness/harness_navigation.dart';
import '../controllers/home_page_controller.dart';
import '../controllers/scroll_controller.dart' as scroll_ctrl;
import '../../subagent/services/subagent_coordinator.dart';
import '../../../core/models/conversation.dart';
import '../../subagent/services/subagent_rules.dart' show SubagentExtrasKeys;
import '../../subagent/widgets/subagent_parent_link.dart';
import 'home_mobile_layout.dart';
import 'home_desktop_layout.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _TemporaryConversationEmptyState extends StatelessWidget {
  const _TemporaryConversationEmptyState({
    required this.topContentPadding,
    required this.bottomContentPadding,
    this.footer,
  });

  final double topContentPadding;
  final double bottomContentPadding;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          32,
          topContentPadding + 24,
          32,
          bottomContentPadding + 24,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Lucide.HatGlasses,
                size: 72,
                color: cs.onSurface.withValues(alpha: 0.42),
              ),
              const SizedBox(height: 18),
              Text(
                l10n.temporaryChatEmptyMessage,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.45,
                  color: cs.onSurface.withValues(alpha: 0.68),
                  fontWeight: AppFontWeights.medium,
                ),
              ),
              if (footer != null) ...[
                const SizedBox(height: 16),
                SizedBox(height: 48, child: footer),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _HomePageState extends State<HomePage>
    with TickerProviderStateMixin, RouteAware, WidgetsBindingObserver {
  // ============================================================================
  // UI Controllers (owned by State for lifecycle management)
  // ============================================================================

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final InteractiveDrawerController _drawerController =
      InteractiveDrawerController();
  final ValueNotifier<int> _assistantPickerCloseTick = ValueNotifier<int>(0);
  final FocusNode _inputFocus = FocusNode();
  final QuoteEditingController _inputController = QuoteEditingController();
  final ChatInputBarController _mediaController = ChatInputBarController();
  scroll_ctrl.ChatAutoFollowScrollController _scrollController =
      scroll_ctrl.ChatAutoFollowScrollController();
  String? _scrollConversationId;
  final GlobalKey _inputBarKey = GlobalKey();
  final GlobalKey _reasoningButtonKey = GlobalKey();
  final GlobalKey _selectionMiniMapKey = GlobalKey();
  final GlobalKey _selectionActionBarKey = GlobalKey();
  bool _scrollNavHovering = false;
  double _lastViewInsetBottom = 0;
  StreamSubscription<String>? _processTextSub;
  IncomingShareService? _incomingShares;
  late final Future<void> _chatReady;
  bool _readingIncomingShares = false;
  bool _incomingShareChanged = false;

  // ============================================================================
  // Page Controller (manages all business logic and state)
  // ============================================================================

  late HomePageController _controller;

  /// Read once in `initState`: the page attaches itself as the coordinator's
  /// host and detaches again in `dispose`.
  SubagentCoordinator? _subagentCoordinator;
  SubagentHost? _subagentHost;
  late final QuoteInteractionController _quoteInteractions;
  bool _quoteSyncScheduled = false;
  (String?, int)? _quoteSourceVersion;
  int _quoteJumpSerial = 0;
  late final ConversationFindController _find;
  final _findField = TextEditingController();
  final _findFocus = FocusNode();
  final _chatFocus = FocusNode(debugLabel: 'Conversation');
  bool _returnToComposer = false;
  String? _findConversation;
  Map<String, int> _findVersions = const {};
  ValueListenable<int>? _findRevision;
  final _liveFindRows = <String, ConversationFindCandidate>{};
  ConversationFindService? _findPresentation;

  ConversationFindService _findService() {
    final settings = context.read<SettingsProvider>();
    final id = _controller.currentConversation?.assistantId;
    return ConversationFindService(
      assistant: id == null
          ? null
          : context.read<AssistantProvider>().getById(id),
      userMarkdown: settings.enableUserMarkdown,
      assistantMarkdown: settings.enableAssistantMarkdown,
      splitAssistantParagraphs: settings.assistantBubbleSplitParagraphs,
      reasoningMarkdown: settings.enableReasoningMarkdown,
      parserOptions: markdownParserOptions(settings),
      translationPlaceholder: AppLocalizations.of(
        context,
      )!.chatMessageWidgetTranslating,
    );
  }

  ConversationFindCandidate _findSnapshot(ConversationFindCandidate row) {
    if (!row.streaming ||
        !_controller.streamingContentNotifier.hasNotifier(row.id)) {
      return row;
    }
    return ConversationFindCandidate(
      _controller.conversationFindStreamSnapshot(row.toMessage()),
      surfaces: row.surfaces,
    );
  }

  Future<Map<String, List<ConversationFindHit>>> _searchConversation(
    String query,
    FindOptions options,
    bool Function() current,
  ) async {
    final id = _controller.currentConversation?.id;
    if (id == null) return {};
    final service = _findPresentation = _findService();
    return service.search(
      context.read<ChatService>().conversationFindCandidates(id),
      query,
      options,
      isCurrent: current,
      liveCandidate: (row) {
        if (row.streaming) _liveFindRows[row.id] = row;
        return _findSnapshot(row);
      },
    );
  }

  void _onFindTextChanged(String id) {
    _find.streamChanged(id, () async {
      final stored = _liveFindRows[id];
      final message = _controller.messages.where((m) => m.id == id).firstOrNull;
      final row = message == null
          ? stored
          : ConversationFindCandidate(
              message,
              surfaces: stored?.surfaces ?? const {},
            );
      if (row == null) return const [];
      final result = await _findService().search(
        Stream.value([_findSnapshot(row)]),
        _find.query,
        _find.options,
      );
      return result[id] ?? const [];
    });
  }

  Future<void> _revealFind(
    ConversationFindHit hit,
    bool Function() valid,
  ) async {
    bool current() =>
        mounted &&
        valid() &&
        _controller.currentConversation?.id == _findConversation;
    final conversationId = _findConversation;
    if (conversationId == null || !current()) return;
    await _controller.scrollToMessageId(
      hit.messageId,
      stillCurrent: current,
      beforeScroll: () {
        if (hit.part == FindPart.translation) {
          _controller.ensureTranslationExpanded(hit.messageId);
        }
        if (hit.part == FindPart.reasoning) {
          _controller.ensureReasoningExpanded(hit.messageId);
          if (hit.segment case final index?) {
            _controller.ensureReasoningSegmentExpanded(hit.messageId, index);
          }
        }
      },
      revealMatch: (isCurrent, {required waitForMount}) {
        if (hit.surfaceKey case final key?) {
          return _controller.uiSearchNavigation.revealMatch(
            conversationId,
            hit.messageId,
            key,
            isCurrent,
          );
        }
        return scrollToSourceGeometry(
          locate: () => _quoteInteractions.findRect(hit),
          scrollToRect: _controller.scrollToSourceRect,
          isCurrent: isCurrent,
          waitForMount: waitForMount,
        );
      },
    );
  }

  void _onFindChanged() {
    if (!_find.opened || _find.searching || _find.current == null) {
      _controller.cancelFindJump();
    }
  }

  void _onFindHistoryChanged() => _find.refresh();

  void _syncFindSession() {
    final id = _controller.currentConversation?.id;
    if (id != _findConversation) {
      _findRevision?.removeListener(_onFindHistoryChanged);
      _findRevision = null;
      _findConversation = id;
      _findPresentation = null;
      _findVersions = const {};
      _liveFindRows.clear();
      _find.setConversation(id);
      _findField.clear();
    } else if (_find.opened &&
        !mapEquals(_findVersions, _controller.versionSelections)) {
      _findVersions = Map.of(_controller.versionSelections);
      _find.refresh(preserve: false);
    }
  }

  void _openConversationFind() {
    if (!mounted) return;
    _syncFindSession();
    if (!_find.opened) {
      _returnToComposer =
          _inputFocus.hasFocus || _controller.userMessageEditState != null;
      final id = _findConversation;
      _findVersions = Map.of(_controller.versionSelections);
      if (id != null) {
        _findRevision =
            context.read<ChatService>().compressionHistoryRevisionListenable(id)
              ..addListener(_onFindHistoryChanged);
      }
    }
    final selected =
        _inputFocus.hasFocus &&
            _inputController.selection.isValid &&
            !_inputController.selection.isCollapsed
        ? _inputController.selection.textInside(_inputController.text)
        : AppSelectionArea.focusedSelection;
    final wasOpen = _find.opened;
    _find.open(selection: selected?.trim().isEmpty == true ? null : selected);
    if (!wasOpen && !PlatformUtils.isDesktop) setState(() {});
    _findField.value = TextEditingValue(
      text: _find.query,
      selection: TextSelection(baseOffset: 0, extentOffset: _find.query.length),
    );
    _findFocus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _find.opened) _findFocus.requestFocus();
    });
  }

  void _closeConversationFind() {
    _find.close();
    if (!PlatformUtils.isDesktop) setState(() {});
    _controller.uiSearchNavigation.clear();
    _findRevision?.removeListener(_onFindHistoryChanged);
    _findRevision = null;
    _liveFindRows.clear();
    if (_returnToComposer) {
      _inputFocus.requestFocus();
    } else {
      _chatFocus.requestFocus();
    }
  }

  Widget _findKeyBinding(Widget child) {
    final apple = PlatformUtils.isMacOS || PlatformUtils.isIOS;
    final shortcut = SingleActivator(
      LogicalKeyboardKey.keyF,
      meta: apple,
      control: !apple,
    );
    final claimed =
        PlatformUtils.isDesktop &&
        context.select<HotkeyProvider?, bool>(
          (provider) => provider?.handlesShortcut(shortcut) ?? false,
        );
    return CallbackShortcuts(
      bindings: {if (!claimed) shortcut: _openConversationFind},
      child: child,
    );
  }

  Widget _chatFindShortcuts(Widget body) => _findKeyBinding(
    Focus(
      focusNode: _chatFocus,
      autofocus: true,
      skipTraversal: true,
      child: body,
    ),
  );

  PreferredSizeWidget _mobileFindHeader() => PreferredSize(
    preferredSize: const Size.fromHeight(kToolbarHeight),
    child: _findKeyBinding(
      SafeArea(
        bottom: false,
        child: SizedBox(
          height: kToolbarHeight,
          child: _conversationFindBar(desktop: false),
        ),
      ),
    ),
  );

  ConversationFindBar _conversationFindBar({required bool desktop}) =>
      ConversationFindBar(
        find: _find,
        field: _findField,
        focusNode: _findFocus,
        compact: desktop,
        onClose: _closeConversationFind,
      );

  void _syncQuoteHighlights() {
    if (_quoteSyncScheduled) return;
    _quoteSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _quoteSyncScheduled = false;
      if (mounted) _quoteInteractions.setDraftQuotes(_inputController.quotes);
    });
  }

  Future<void> _insertSelectionQuote(QuoteRef quote) async {
    final conversationId = _controller.currentConversation?.id;
    await _inputController.retireMessageInput();
    if (!mounted) return;
    try {
      if (_controller.currentConversation?.id != conversationId) return;
      final result = _inputController.insertQuote(quote);
      final l10n = AppLocalizations.of(context)!;
      if (result == QuoteInsertion.duplicate ||
          result == QuoteInsertion.limit) {
        showAppSnackBar(
          context,
          message: result == QuoteInsertion.duplicate
              ? l10n.quoteDuplicate
              : l10n.quoteLimit,
        );
      }
    } finally {
      _inputController.resumeInput();
    }
    _inputFocus.requestFocus();
  }

  Future<bool> _jumpToQuote(QuoteRef quote) async {
    if (!quote.hasSourceRange) return false;
    final serial = ++_quoteJumpSerial;
    final previousConversation = _controller.currentConversation?.id;
    final source = (await context.read<ChatService>().loadMessagesByIds([
      quote.messageId,
    ])).firstOrNull;
    if (!mounted ||
        serial != _quoteJumpSerial ||
        _controller.currentConversation?.id != previousConversation) {
      return false;
    }
    final labels = AppLocalizations.of(context)!;
    if (source == null) {
      showAppSnackBar(context, message: labels.quoteSourceMissing);
      return false;
    }
    if (_controller.currentConversation?.id != source.conversationId) {
      await _controller.switchConversationAnimated(source.conversationId);
    }
    bool isCurrent() =>
        mounted &&
        serial == _quoteJumpSerial &&
        _controller.currentConversation?.id == source.conversationId;
    if (!isCurrent()) return false;
    await _controller.setSelectedVersion(
      source.groupId ?? source.id,
      source.version,
    );
    if (!isCurrent()) return false;
    await _controller.scrollToMessageId(source.id);
    if (!isCurrent()) return false;
    await _quoteInteractions.scrollToSource(
      quote,
      scrollToRect: _controller.scrollToSourceRect,
      isCurrent: isCurrent,
    );
    if (!mounted || !isCurrent()) return false;
    _quoteInteractions.reveal(quote);
    showAppSnackBar(context, message: labels.quoteLocated);
    return true;
  }

  // ============================================================================
  // Lifecycle
  // ============================================================================

  @override
  void initState() {
    super.initState();
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}

    _controller = HomePageController(
      context: context,
      vsync: this,
      scaffoldKey: _scaffoldKey,
      inputBarKey: _inputBarKey,
      inputFocus: _inputFocus,
      inputController: _inputController,
      mediaController: _mediaController,
      scrollController: _scrollController,
    );
    // The coordinator is provided above this page so the tool handler can read
    // it from its own context; only the page can start a turn, so it attaches
    // itself here and detaches in `dispose`. A page mounted without one (a
    // widget test, an embedding) simply has no delegation.
    _subagentCoordinator = subagentCoordinatorOf(context);
    _subagentHost = _controller.buildSubagentHost();
    _subagentCoordinator?.attachHost(_subagentHost!);

    _find = ConversationFindController(
      search: _searchConversation,
      onReveal: _revealFind,
    )..addListener(_onFindChanged);
    _controller.onFindTextChanged = _onFindTextChanged;
    _controller.onFindGenerationFinished = (id) {
      if (id == _findConversation) {
        _liveFindRows.clear();
        _find.refresh();
      }
    };
    _quoteInteractions = QuoteInteractionController(
      onQuote: _insertSelectionQuote,
      onJump: _jumpToQuote,
      sourceExists: (id) => context.read<ChatService>().messageExists(id),
    );
    _inputController.addListener(_syncQuoteHighlights);
    _controller.onRevealConversation = () => _drawerController.jumpTo(0);
    _controller.addListener(_onControllerChanged);
    _drawerController.addListener(_onDrawerValueChanged);

    _chatReady = _controller.initChat();
    _initProcessText();
    _initIncomingShares();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _lastViewInsetBottom = View.of(context).viewInsets.bottom;
      }
      _controller.measureInputBar();
      if (!mounted) return;
      context.read<WorldBookProvider>().initialize();
      // Proactive care catch-up: providers are up post-frame; alarms trigger
      // on-time delivery, this covers anything they missed.
      unawaited(_controller.deliverDueProactiveCare());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Modal routes disable tickers only after an opaque route covers us.
    // Keep streaming visible behind translucent dialogs and bottom sheets.
    _controller.onHomeVisibilityChanged(TickerMode.valuesOf(context).enabled);
    final route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.onAppLifecycleStateChanged(state);
    if (state == AppLifecycleState.resumed) _readIncomingShares();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final nextInset = View.of(context).viewInsets.bottom;
    final keyboardOpening = nextInset > _lastViewInsetBottom + 0.5;
    _lastViewInsetBottom = nextInset;
    if (!keyboardOpening || !PlatformUtils.isMobileTarget) return;
    _controller.scrollCtrl.pinBottomDuringViewportResizeIfNeeded();
  }

  @override
  void didPushNext() {
    _controller.onDidPushNext();
  }

  @override
  void didPopNext() {
    _controller.onDidPopNext();
  }

  @override
  void dispose() {
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _processTextSub?.cancel();
    _incomingShares?.dispose();
    _findRevision?.removeListener(_onFindHistoryChanged);
    _controller.onFindTextChanged = null;
    _controller.onFindGenerationFinished = null;
    _find.dispose();
    _findFocus.dispose();
    _findField.dispose();
    _chatFocus.dispose();
    _controller.removeListener(_onControllerChanged);
    // Only the host this page attached: another page may be stacked on top of
    // this one, and taking its host away would leave it unable to delegate.
    final host = _subagentHost;
    if (host != null) _subagentCoordinator?.detachHost(host);
    _drawerController.removeListener(_onDrawerValueChanged);
    _controller.dispose();
    _inputController.removeListener(_syncQuoteHighlights);
    _quoteInteractions.dispose();
    _inputFocus.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  final Map<String, String> _compressionNotices = {};

  void _observeCompression() {
    final chat = context.read<ChatService>();
    for (final task in chat.contextCompression.tasks.toList()) {
      final state = '${task.id}:${task.phase.name}:${task.error}';
      if (_compressionNotices[task.conversationId] == state) continue;
      _compressionNotices[task.conversationId] = state;
      final phase = task.phase;
      if (task.conversationId != _controller.currentConversation?.id ||
          (task.active && phase != CompressionPhase.review)) {
        continue;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            task.phase != phase ||
            chat.contextCompression.taskFor(task.conversationId)?.id !=
                task.id ||
            _controller.currentConversation?.id != task.conversationId) {
          return;
        }
        final l10n = AppLocalizations.of(context)!;
        void retry() => _controller.compressContext(
          options: task.options,
          targetConversationId: task.conversationId,
          beforeMessageId: task.protectedMessageId,
          effectiveMessageIds: task.effectiveMessageIds,
        );
        void options() => _showCompressContextOptions(
          targetConversationId: task.conversationId,
          initialOptions: task.options,
          initialError: task.error,
          reviewPending: false,
        );
        switch (phase) {
          case CompressionPhase.completed:
            final node = chat
                .contextOperationsFor(task.conversationId)
                .where((op) => op.id == task.id)
                .firstOrNull;
            showAppSnackBar(
              context,
              message: l10n.compressSuccessSnack(
                task.previousBudget == null
                    ? '—'
                    : contextTokenValue(task.previousBudget!.usedTokens),
                task.budget == null
                    ? '—'
                    : contextTokenValue(task.budget!.usedTokens),
              ),
              actionLabel: task.resultConversationId != null
                  ? l10n.contextOpenNewChat
                  : l10n.contextDetailTitle,
              onAction: () {
                if (task.resultConversationId != null) {
                  _controller.switchConversationAnimated(
                    task.resultConversationId!,
                  );
                } else if (node != null) {
                  showContextOperationDetails(
                    context,
                    chat: chat,
                    conversationId: task.conversationId,
                    operation: node,
                    onViewOriginal: _controller.scrollToMessageId,
                    onRecompress: options,
                  );
                }
              },
            );
          case CompressionPhase.cancelled:
            if (task.error != 'context_cleared') {
              showAppSnackBar(context, message: l10n.compressCancelledSnack);
            }
          case CompressionPhase.review:
            showAppSnackBar(
              context,
              message: task.error == null
                  ? l10n.compressionPreviewOnly
                  : compressionErrorLabel(l10n, task.error!),
              type: NotificationType.warning,
              actionLabel: l10n.contextViewGenerated,
              onAction: () => showCompressionReview(
                context,
                chat: chat,
                task: task,
                onRecompress: options,
              ),
            );
          case CompressionPhase.failed:
          case CompressionPhase.interrupted:
            final action = compressionRecoveryActions(
              l10n,
              error: task.error,
              native: task.options.native,
              onRetry: retry,
              onAdjust: options,
            ).first;
            showAppSnackBar(
              context,
              message: task.error == null
                  ? compressionStatusLabel(l10n, task)
                  : compressionErrorLabel(l10n, task.error!),
              type: NotificationType.warning,
              actionLabel: action.label,
              onAction: action.onTap,
            );
          default:
            break;
        }
      });
    }
  }

  String _queuedPauseReason() {
    final l10n = AppLocalizations.of(context)!;
    final task = context.read<ChatService>().contextCompression.taskFor(
      _controller.currentConversation?.id ?? '',
    );
    if (task?.error == 'context_changed') {
      return l10n.compressStaleSnack;
    }
    if (task?.phase == CompressionPhase.review) {
      return compressionErrorLabel(l10n, task!.error ?? '');
    }
    if (task?.phase == CompressionPhase.failed ||
        task?.phase == CompressionPhase.interrupted) {
      return l10n.chatInputBarQueuedCompressionFailed;
    }
    if (task?.phase == CompressionPhase.cancelled) {
      return l10n.chatInputBarQueuedCompressionCancelled;
    }
    return l10n.chatInputBarQueuedPausedHold;
  }

  Future<void> _clearContextWithNotice() async {
    final id = _controller.currentConversation?.id;
    if (id == null) return;
    final task = context.read<ChatService>().contextCompression.taskFor(id);
    final discarded = task?.active ?? false;
    await _controller.clearContext();
    if (mounted && discarded) {
      final l10n = AppLocalizations.of(context)!;
      showAppSnackBar(
        context,
        message: l10n.compressDiscardedSnack,
        actionLabel: task!.summary.isEmpty ? null : l10n.compressCopyResult,
        onAction: task.summary.isEmpty
            ? null
            : () => Clipboard.setData(ClipboardData(text: task.summary)),
      );
    }
  }

  void _onControllerChanged() {
    _syncFindSession();
    _observeCompression();
    final conversationId = _controller.currentConversation?.id;
    final quoteVersion = (
      conversationId,
      conversationId == null
          ? 0
          : context.read<ChatService>().getMessageCount(conversationId),
    );
    if (quoteVersion != _quoteSourceVersion) {
      _quoteSourceVersion = quoteVersion;
      _quoteInteractions.refreshSources();
    }
    if (conversationId != null && conversationId != _scrollConversationId) {
      _scrollConversationId = conversationId;
      final previous = _scrollController;
      final replacement = scroll_ctrl.ChatAutoFollowScrollController();
      _scrollController = replacement;
      _controller.replaceScrollController(replacement);
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
    if (mounted) setState(() {});
  }

  void _onDrawerValueChanged() {
    _controller.onDrawerValueChanged(_drawerController.value);
    // Close assistant picker when drawer closes
    if (_drawerController.value < 0.95) {
      final sp = context.read<SettingsProvider>();
      if (!sp.keepAssistantListExpandedOnSidebarClose) {
        _assistantPickerCloseTick.value++;
      }
    }
  }

  void _initProcessText() {
    if (!PlatformUtils.isAndroid) return;
    AndroidProcessText.ensureInitialized();
    _processTextSub = AndroidProcessText.stream.listen(_handleProcessText);
    AndroidProcessText.getInitialText().then((text) {
      if (text != null) {
        _handleProcessText(text);
      }
    });
  }

  void _initIncomingShares() {
    if (!PlatformUtils.isMobile) return;
    _incomingShares = IncomingShareService()
      ..listen(
        onChanged: _readIncomingShares,
        onFailed: _showIncomingShareFailure,
      );
    _incomingShares!.progress.addListener(() {
      _mediaController.shareImport.value = _incomingShares!.progress.value;
    });
    _mediaController.cancelShareImport = () =>
        unawaited(_incomingShares!.cancelImport());
    WidgetsBinding.instance.addPostFrameCallback((_) => _readIncomingShares());
  }

  void _showIncomingShareFailure() {
    if (!mounted) return;
    showAppSnackBar(
      context,
      message: AppLocalizations.of(context)!.incomingShareFailed,
      type: NotificationType.error,
    );
  }

  Future<void> _readIncomingShares() async {
    final service = _incomingShares;
    if (service == null || !mounted) return;
    _incomingShareChanged = true;
    if (_readingIncomingShares) return;
    _readingIncomingShares = true;
    try {
      await _chatReady;
      if (!mounted) return;
      final drafts = context.read<ChatService>().composerDrafts;
      while (mounted && _incomingShareChanged) {
        _incomingShareChanged = false;
        final pendingShares = await service.pending();
        final shares = <IncomingShare>[];
        for (final share in pendingShares) {
          if (await drafts?.hasShareReceipt(share.id) == true) {
            await service.acknowledge([share]);
            await drafts?.acknowledgeShares([share.id]);
          } else {
            shares.add(share);
          }
        }
        if (!mounted || shares.isEmpty) continue;
        final hasContent = shares.any(
          (share) => share.text.trim().isNotEmpty || share.files.isNotEmpty,
        );
        if (hasContent) {
          final homeRoute = ModalRoute.of(context);
          Navigator.of(
            context,
          ).popUntil((route) => route == homeRoute || route.isFirst);
          _drawerController.close();
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted) return;
          final ChatInputData input;
          try {
            input = await service.prepare(
              shares,
              uploadDirectory: await drafts?.directoryFor('share-import'),
            );
          } on ShareImportCancelled {
            await service.acknowledge(shares);
            continue;
          }
          var accepted = false;
          var completed = false;
          try {
            if (!mounted) return;
            // Check the current draft at delivery time: preparing a large
            // attachment may take long enough for the user to keep typing.
            accepted = await _controller.acceptIncomingShareDraft(
              input,
              shareIds: shares.map((share) => share.id),
            );
            completed = true;
          } finally {
            // The durable store owns a separate copy; native delivery remains
            // unacknowledged if persistence failed.
            if ((completed && drafts != null) ||
                (drafts == null && !accepted)) {
              await service.discardPrepared(input);
            }
          }
        }
        if (shares.any((share) => share.failedFiles > 0)) {
          _showIncomingShareFailure();
        }
        await service.acknowledge(shares);
        await drafts?.acknowledgeShares(shares.map((share) => share.id));
      }
    } on MissingPluginException {
      // The desktop/test host does not have a mobile incoming-share inbox.
    } catch (_) {
      _showIncomingShareFailure();
    } finally {
      _readingIncomingShares = false;
    }
  }

  void _handleProcessText(String text) {
    if (!mounted) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final current = _inputController.text;
    final selection = _inputController.selection;
    final start = (selection.start >= 0 && selection.start <= current.length)
        ? selection.start
        : current.length;
    final end =
        (selection.end >= 0 &&
            selection.end <= current.length &&
            selection.end >= start)
        ? selection.end
        : start;
    final next = current.replaceRange(start, end, trimmed);
    _inputController.value = _inputController.value.copyWith(
      text: next,
      selection: TextSelection.collapsed(offset: start + trimmed.length),
      composing: TextRange.empty,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.forceScrollToBottomSoon(animate: false);
      _inputFocus.requestFocus();
    });
  }

  // ============================================================================
  // Build Methods
  // ============================================================================

  @override
  Widget build(BuildContext context) =>
      // Keep action callbacks on the page's live context. Dialogs must not
      // capture the deferred theme intended only for this page's contents.
      SelectionBackScope(
        selecting: _controller.selecting,
        onCancel: () {
          // Only the mobile drawer takes this back first. Its controller keeps
          // its last value after switching to the wide layout without a drawer.
          if (MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet ||
              _drawerController.isClosed) {
            _controller.cancelSelection();
          }
        },
        child: VisibleRouteTheme(
          child: UiActionsScope(
            onDraft: _controller.stageUiDraft,
            child: UiSearchNavigationScope(
              navigation: _controller.uiSearchNavigation,
              child: QuoteInteractionScope(
                controller: _quoteInteractions,
                child: _buildPage(context),
              ),
            ),
          ),
        ),
      );

  /// A sidebar row tap. A local assistant or a group opens its conversation; a
  /// DeepSeek Harness is a remote application, so it opens its own page instead
  /// — its connection settings first when no link was saved yet.
  Future<void> _handleOpenOwner(ChatOwner owner) async {
    if (!owner.isGroup) {
      final assistant = context.read<AssistantProvider>().getById(owner.id);
      if (assistant != null && assistant.isDeepSeekHarness) {
        // The remote page is an opaque route, and the sidebar below it stops
        // animating the moment the page covers it. Let the sidebar finish
        // closing first: otherwise it is left half-open under the page and
        // slides away again the moment the user comes back.
        if (_drawerController.isAttached && !_drawerController.isClosed) {
          await _drawerController.close();
          if (!mounted) return;
        }
        await openHarnessForAssistant(context, assistant);
        return;
      }
    }
    await _controller.openOwner(owner);
  }

  Widget _buildPage(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final desktop = !kIsWeb && _controller.isDesktopPlatform;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final assistant = context.watch<AssistantProvider>().currentAssistant;
    final previous = _findPresentation;
    if (_find.opened && previous != null) {
      final next = _findService();
      if (!previous.usesSamePresentation(next)) {
        _findPresentation = next;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _find.opened && identical(_findPresentation, next)) {
            _find.refresh();
          }
        });
      }
    }

    final modelInfo = getModelDisplayInfo(
      settings,
      conversation: _controller.currentConversation,
      assistant: assistant,
    );

    final title = _controller.isTemporaryConversation
        ? AppLocalizations.of(context)!.temporaryChatTitle
        : ((_controller.currentConversation?.title ?? '').trim().isNotEmpty)
        ? _controller.currentConversation!.title
        : _controller.titleForLocale();

    _controller.setCompactDesktopLayout(
      desktop && width < AppBreakpoints.tablet,
    );
    // A group topic has no single model to name, so the header carries only the
    // topic title — on every layout. The capsule is the desktop/tablet model
    // picker, and picking one there would pin a topic whose replies come from
    // the roster.
    final isGroup =
        context.watch<GroupChatProvider>().forConversation(
          _controller.currentConversation,
        ) !=
        null;
    if (desktop || width >= AppBreakpoints.tablet) {
      return _buildTabletLayout(
        context,
        title: title,
        providerName: isGroup ? null : modelInfo.providerName,
        modelDisplay: isGroup ? null : modelInfo.modelDisplay,
        cs: cs,
      );
    }

    return _buildMobileLayout(
      context,
      title: title,
      providerName: isGroup ? null : modelInfo.providerName,
      modelDisplay: isGroup ? null : modelInfo.modelDisplay,
      cs: cs,
    );
  }

  Widget _buildMobileLayout(
    BuildContext context, {
    required String title,
    required String? providerName,
    required String? modelDisplay,
    required ColorScheme cs,
  }) {
    final allSelected = _controller.allSelectableMessagesSelected;

    return HomeMobileScaffold(
      scaffoldKey: _scaffoldKey,
      drawerController: _drawerController,
      assistantPickerCloseTick: _assistantPickerCloseTick,
      loadingConversationIds: _controller.loadingConversationIds,
      title: title,
      providerName: providerName,
      modelDisplay: modelDisplay,
      onToggleDrawer: () => _drawerController.toggle(),
      onDismissKeyboard: _controller.dismissKeyboard,
      onSelectConversation: (id) {
        _controller.switchConversationAnimated(id);
      },
      onNewConversation: () async {
        await _controller.createNewConversationAnimated();
      },
      onOpenOwner: _handleOpenOwner,
      onOpenMiniMap: _openMiniMap,
      onCreateNewConversation: () async {
        await _controller.createNewConversationAnimated();
        if (mounted) {
          _controller.forceScrollToBottomSoon(animate: false);
        }
      },
      onToggleTemporaryConversation: () async {
        await _controller.toggleTemporaryConversation();
        if (mounted) {
          _controller.forceScrollToBottomSoon(animate: false);
        }
      },
      canToggleTemporaryConversation:
          _controller.canToggleTemporaryConversation,
      temporaryConversationEnabled: _controller.isTemporaryConversation,
      onSelectModel: () =>
          showModelSelectSheet(context, controller: _controller),
      globalSearchMode: _controller.isGlobalSearchMode,
      globalSearchQuery: _controller.globalSearchQuery,
      onGlobalSearchQueryChanged: _controller.setGlobalSearchQuery,
      onEnterGlobalSearch: () =>
          _controller.enterGlobalSearchMode(preserveQuery: false),
      onExitGlobalSearch: () =>
          _controller.exitGlobalSearchMode(clearQuery: true),
      onOpenGlobalSearchResult: (convId, msgId, surfaceKey) =>
          _controller.openGlobalSearchResult(
            conversationId: convId,
            messageId: msgId,
            surfaceKey: surfaceKey,
          ),
      appBarOverride: _find.opened
          ? _mobileFindHeader()
          : _controller.selecting
          ? ChatSelectionAppBar(
              selectedCount: _controller.selectedCount,
              allSelected: allSelected,
              onClose: _controller.cancelSelection,
              onOpenMiniMap: () {
                unawaited(_openSelectionMiniMap());
              },
              miniMapKey: _selectionMiniMapKey,
              onToggleSelectAll: _controller.toggleSelectAll,
              onInvertSelection: _controller.invertSelection,
            )
          : null,
      body: _chatFindShortcuts(
        _wrapWithDropTarget(_buildMobileBody(context, cs)),
      ),
    );
  }

  Widget _buildMobileBody(BuildContext context, ColorScheme cs) {
    final bottomContentPadding = _controller.inputBarHeight + 16;
    final topContentPadding = _chatTopOverlayInset(context) + 8;
    final backgroundImageActive = _assistantBackgroundActive(context);

    return ChatInputOverlayLayout(
      topInset: _chatTopOverlayInset(context),
      // The full-window artwork already sits behind the Scaffold
      // (MobileBackgroundLayer); painting it again inside the body would only
      // duplicate it in a box that shrinks with the keyboard.
      topBackground: backgroundImageActive
          ? const ChatAssistantBackground(expand: false, pinnedToBackdrop: true)
          : null,
      backgroundImageActive: backgroundImageActive,
      content: Builder(
        builder: (context) {
          final content = KeyedSubtree(
            key: ValueKey<String>(
              _controller.currentConversation?.id ?? 'none',
            ),
            child: _buildMessageListView(
              context,
              topContentPadding: topContentPadding,
              bottomContentPadding: bottomContentPadding,
              dividerPadding: const EdgeInsets.symmetric(
                vertical: 10,
                horizontal: AppSpacing.md,
              ),
            ),
          );
          return FadeTransition(
            opacity: _controller.convoFade,
            child: _wrapMessageJumpTransition(content),
          );
        },
      ),
      bottomOverlay: _controller.selecting
          ? _buildSelectionActionBar(context)
          : NotificationListener<SizeChangedLayoutNotification>(
              onNotification: (n) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _controller.measureInputBar(),
                );
                return false;
              },
              child: SizeChangedLayoutNotifier(
                child: Builder(
                  builder: (context) =>
                      _buildChatInputBar(context, isTablet: false),
                ),
              ),
            ),
      foreground: _buildForegroundOverlay(context),
    );
  }

  Widget _buildTabletLayout(
    BuildContext context, {
    required String title,
    required String? providerName,
    required String? modelDisplay,
    required ColorScheme cs,
  }) {
    _controller.initDesktopUi();

    final allSelected = _controller.allSelectableMessagesSelected;

    return HomeDesktopScaffold(
      scaffoldKey: _scaffoldKey,
      assistantPickerCloseTick: _assistantPickerCloseTick,
      loadingConversationIds: _controller.loadingConversationIds,
      title: title,
      providerName: providerName,
      modelDisplay: modelDisplay,
      modelProviderKey: _resolvedChatModel().providerKey,
      modelId: _resolvedChatModel().modelId,
      compact:
          _controller.isDesktopPlatform &&
          MediaQuery.sizeOf(context).width < AppBreakpoints.tablet,
      tabletSidebarOpen: _controller.tabletSidebarOpen,
      embeddedSidebarWidth: _controller.embeddedSidebarWidth,
      sidebarMinWidth: HomePageController.sidebarMinWidth,
      sidebarMaxWidth: HomePageController.sidebarMaxWidth,
      onToggleSidebar: _controller.toggleTabletSidebar,
      onSelectConversation: (id) {
        _controller.closeCompactSidebar();
        _controller.switchConversationAnimated(id);
      },
      onNewConversation: () async {
        _controller.closeCompactSidebar();
        await _controller.createNewConversationAnimated();
      },
      onOpenOwner: _handleOpenOwner,
      onRevealTopics: _controller.revealTopics,
      onCreateNewConversation: () async {
        await _controller.createNewConversationAnimated();
        if (mounted) _controller.forceScrollToBottomSoon(animate: false);
      },
      onToggleTemporaryConversation: () async {
        await _controller.toggleTemporaryConversation();
        if (mounted) _controller.forceScrollToBottomSoon(animate: false);
      },
      canToggleTemporaryConversation:
          _controller.canToggleTemporaryConversation,
      temporaryConversationEnabled: _controller.isTemporaryConversation,
      globalSearchMode: _controller.isGlobalSearchMode,
      globalSearchQuery: _controller.globalSearchQuery,
      onGlobalSearchQueryChanged: _controller.setGlobalSearchQuery,
      onOpenGlobalSearchResult: (convId, msgId, surfaceKey) {
        _controller.closeCompactSidebar();
        return _controller.openGlobalSearchResult(
          conversationId: convId,
          messageId: msgId,
          surfaceKey: surfaceKey,
        );
      },
      onSelectModel: () =>
          showModelSelectSheet(context, controller: _controller),
      onSidebarWidthChanged: _controller.updateSidebarWidth,
      onSidebarWidthChangeEnd: _controller.saveSidebarWidth,
      buildAssistantBackground: _buildAssistantBackground,
      appBarOverride: !PlatformUtils.isDesktop && _find.opened
          ? _mobileFindHeader()
          : _controller.selecting
          ? ChatSelectionAppBar(
              selectedCount: _controller.selectedCount,
              allSelected: allSelected,
              onClose: _controller.cancelSelection,
              onOpenMiniMap: () {
                unawaited(_openSelectionMiniMap());
              },
              miniMapKey: _selectionMiniMapKey,
              onToggleSelectAll: _controller.toggleSelectAll,
              onInvertSelection: _controller.invertSelection,
            )
          : null,
      body: _chatFindShortcuts(
        _wrapWithDropTarget(_buildTabletBody(context, cs)),
      ),
    );
  }

  Future<void> _openSelectionMiniMap() async {
    final collapsed = await _controller
        .loadAllCollapsedMessagesForCurrentConversation();
    if (!mounted) return;
    if (collapsed.isEmpty) return;

    if (PlatformUtils.isDesktop &&
        _selectionActionBarKey.currentContext != null) {
      await showDesktopMiniMapPopover(
        context,
        anchorKey: _selectionActionBarKey,
        messages: collapsed,
        selecting: true,
        selectedMessageIds: _controller.selectedItems,
        selectionListenable: _controller,
        onToggleSelection: (id) => _controller.toggleSelection(
          id,
          !_controller.selectedItems.contains(id),
        ),
      );
      return;
    }

    await showMiniMapSheet(
      context,
      collapsed,
      selecting: true,
      selectedMessageIds: _controller.selectedItems,
      selectionListenable: _controller,
      onToggleSelection: (id) => _controller.toggleSelection(
        id,
        !_controller.selectedItems.contains(id),
      ),
    );
  }

  Widget _buildSelectionActionBar(BuildContext context) {
    return ChatSelectionActionBar(
      key: _selectionActionBarKey,
      hasSelection: _controller.selectedCount > 0,
      hasMultiVersionSelection:
          _controller.selectedMessagesIncludeMultipleVersions,
      onShare: _controller.exportSelectedMessages,
      onExportPdf: _controller.exportSelectedAsPdf,
      onDeleteCurrentVersions: () {
        unawaited(
          _handleDeleteSelectedMessages(context, deleteAllVersions: false),
        );
      },
      onDeleteAllVersions: () {
        unawaited(
          _handleDeleteSelectedMessages(context, deleteAllVersions: true),
        );
      },
    );
  }

  Widget _buildTabletBody(BuildContext context, ColorScheme cs) {
    final bottomContentPadding = _controller.inputBarHeight + 16;
    final topContentPadding = _chatTopOverlayInset(context) + 8;
    final backgroundImageActive = _assistantBackgroundActive(context);

    return ChatInputOverlayLayout(
      topInset: _chatTopOverlayInset(context),
      topBackground: backgroundImageActive
          ? const ChatAssistantBackground(
              desktop: true,
              includeSurfaceFill: true,
              pinnedToBackdrop: true,
            )
          : null,
      backgroundImageActive: backgroundImageActive,
      content: FadeTransition(
        opacity: _controller.convoFade,
        child: _wrapMessageJumpTransition(
          KeyedSubtree(
            key: ValueKey<String>(
              _controller.currentConversation?.id ?? 'none',
            ),
            child: _buildMessageListView(
              context,
              topContentPadding: topContentPadding,
              bottomContentPadding: bottomContentPadding,
              dividerPadding: const EdgeInsets.symmetric(
                vertical: 8,
                horizontal: 12,
              ),
            ),
          ),
        ),
      ),
      bottomOverlay: _controller.selecting
          ? ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: ChatLayoutConstants.maxInputWidth,
              ),
              child: _buildSelectionActionBar(context),
            )
          : NotificationListener<SizeChangedLayoutNotification>(
              onNotification: (n) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _controller.measureInputBar(),
                );
                return false;
              },
              child: SizeChangedLayoutNotifier(
                child: Builder(
                  builder: (context) {
                    Widget input = _buildChatInputBar(context, isTablet: true);
                    input = Align(
                      alignment: Alignment.bottomCenter,
                      heightFactor: 1,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: ChatLayoutConstants.maxInputWidth,
                        ),
                        child: input,
                      ),
                    );
                    return input;
                  },
                ),
              ),
            ),
      foreground: _buildForegroundOverlay(context),
    );
  }

  // ============================================================================
  // UI Component Builders
  // ============================================================================

  Widget _buildAssistantBackground(BuildContext context) {
    return const ChatAssistantBackground(
      desktop: true,
      includeSurfaceFill: true,
    );
  }

  bool _assistantBackgroundActive(BuildContext context) {
    return ChatBackdropSpec.resolve(context).active;
  }

  double _chatTopOverlayInset(BuildContext context) {
    return kToolbarHeight + MediaQuery.paddingOf(context).top;
  }

  /// The two `查看主对话` links a delegated conversation carries, top and bottom.
  ///
  /// Only a child has a parent, so every other conversation gets null and its
  /// timeline is untouched. The label names the parent instead of saying "back",
  /// because a nested delegation has exactly one parent and the user may have
  /// three of these open.
  Widget? _buildSubagentParentLink(
    BuildContext context,
    Conversation? conversation,
  ) {
    final parentId = conversation?.extras[SubagentExtrasKeys.parent] as String?;
    if (parentId == null || parentId.isEmpty) return null;
    final parent = context.select<ChatService, Conversation?>(
      (chat) => chat.getConversation(parentId),
    );
    if (parent == null) return null;
    final l10n = AppLocalizations.of(context)!;
    return SubagentParentLink(
      label: l10n.subagentViewParent(parent.title),
      onTap: () => _controller.switchConversationAnimated(parent.id),
    );
  }

  Widget _buildMessageListView(
    BuildContext context, {
    required double topContentPadding,
    required double bottomContentPadding,
    required EdgeInsetsGeometry dividerPadding,
  }) {
    final assistant = context.watch<AssistantProvider>().currentAssistant;
    final promptFooter =
        assistant?.allowConversationSystemPrompt == true &&
            !_controller.isCurrentConversationLoading &&
            !_controller.selecting
        ? ConversationSystemPromptButton(
            assistantId: assistant!.id,
            conversationId: _controller.currentConversation?.id,
            backgroundImageActive: _assistantBackgroundActive(context),
          )
        : null;
    final conversationId = _controller.currentConversation?.id;
    // Tasks mutate in place, so retain the fields that affect timeline layout
    // as values rather than selecting only the task's identity.
    final (compression, _, _, _) = context
        .select<
          ChatService,
          (ContextCompressionTask?, CompressionPhase?, String?, String?)
        >((chat) {
          final task = conversationId == null
              ? null
              : chat.contextCompression.taskFor(conversationId);
          return (task, task?.phase, task?.anchorGroupId, task?.error);
        });
    final contextOperations = context
        .select<ChatService, List<ContextOperation>>(
          (chat) => conversationId == null
              ? const []
              : chat.contextOperationsFor(conversationId),
        );
    final chat = context.read<ChatService>();
    final footer = promptFooter;
    if (_controller.isTemporaryConversation &&
        _controller.chatController.collapsedMessages.isEmpty) {
      return _TemporaryConversationEmptyState(
        topContentPadding: topContentPadding,
        bottomContentPadding: bottomContentPadding,
        footer: footer,
      );
    }

    final settings = context.watch<SettingsProvider>();
    final suggestionConversation = conversationId == null
        ? null
        : chat.getConversation(conversationId);
    final suggestionAssistant = context
        .watch<AssistantProvider>()
        .resolveConversationAssistant(suggestionConversation?.assistantId);
    final suggestionsEnabled = settings.isSuggestionGenerationAllowedFor(
      suggestionAssistant,
    );
    final suggestions = context.select<ChatService, List<String>>(
      (chat) => suggestionsEnabled && conversationId != null
          ? (chat.getConversation(conversationId)?.chatSuggestions ?? const [])
          : const [],
    );
    return MessageListView(
      subagentParentLink: _buildSubagentParentLink(
        context,
        suggestionConversation,
      ),
      contextTask: compression,
      contextTaskRevision: compression == null
          ? null
          : '${compression.id}:${compression.phase.name}:${compression.anchorGroupId}:${compression.error}',
      contextTaskWaitingForApproval:
          compression?.phase == CompressionPhase.waiting &&
          context.watch<ToolApprovalService>().pendingRequests.any(
            (request) => request.conversationId == conversationId,
          ),
      onOpenContextTask: (task, anchor) => showContextCompressionMenu(
        context,
        chat: chat,
        task: task,
        anchor: anchor,
        onRetry: () => _controller.compressContext(
          options: task.options,
          targetConversationId: task.conversationId,
          beforeMessageId: task.protectedMessageId,
          effectiveMessageIds: task.effectiveMessageIds,
        ),
        onAdjust: () => _showCompressContextOptions(
          targetConversationId: task.conversationId,
          initialOptions: task.options,
          initialError: task.error,
          reviewPending: false,
        ),
      ),
      contextOperations: contextOperations,
      onOpenContextOperation: (operation) => showContextOperationDetails(
        context,
        chat: chat,
        conversationId: conversationId!,
        operation: operation,
        onViewOriginal: _controller.scrollToMessageId,
        onRecompress: () =>
            _showCompressContextOptions(targetConversationId: conversationId),
        onOpenConversation: _controller.switchConversationAnimated,
      ),
      onUndoContextOperation: (operation) =>
          changeContextOperationWithConfirmation(
            context,
            chat: chat,
            conversationId: conversationId!,
            operation: operation,
          ),
      footer: footer,
      processingFilesMessageId: _controller.processingFilesMessageId,
      scrollController: _scrollController,
      listController: _controller.scrollCtrl.messageListController,
      messages: _controller.chatController.collapsedMessages,
      renderModels: _controller.chatController.messageRenderModels,
      byGroup: _controller.chatController.groupedMessages,
      versionSelections: _controller.versionSelections,
      reasoning: _controller.reasoning,
      reasoningSegments: _controller.reasoningSegments,
      contentSplits: _controller.contentSplits,
      toolParts: _controller.toolParts,
      translations: _buildTranslationUiStates(),
      selecting: _controller.selecting,
      selectedItems: _controller.selectedItems,
      suggestions: suggestions,
      topContentPadding: topContentPadding,
      bottomContentPadding: bottomContentPadding,
      dividerPadding: dividerPadding,
      streamingContentNotifier: _controller.streamingContentNotifier,
      conversationFind: _find,
      spotlightMessageId: _controller.spotlightMessageId,
      spotlightToken: _controller.spotlightToken,
      removingSlotIds: _controller.removingSlotIds,
      hasMoreBefore: _controller.chatController.hasMoreBefore,
      isLoadingWindow: _controller.isLoadingWindow,
      onLoadMoreBefore: _controller.loadMoreBefore,
      hasMoreAfter: _controller.chatController.hasMoreAfter,
      onLoadMoreAfter: _controller.loadMoreAfter,
      onUserScrollIntent: () {
        _controller.cancelFindJump();
        _controller.scrollCtrl.handleUserScrollIntent();
      },
      chatFontScale: settings.chatFontScale,
      collapseThinking: settings.autoCollapseThinking,
      collapseThinkingSteps: settings.collapseThinkingSteps,
      showThinkingCards: settings.showThinkingCards,
      showToolCards: settings.showToolCards,
      showProducedFiles: settings.showProducedFiles,
      showToolResultSummary: settings.showToolResultSummary,
      hideToolResultImages: settings.hideToolResultImages,
      showBrowserPageCards: settings.showBrowserPageCards,
      collapsedCodeLines: settings.autoCollapseCodeBlock
          ? settings.autoCollapseCodeBlockLines
          : null,
      // Mirrors the wrap decision in the code block renderer.
      wrapCodeBlocks:
          Platform.isMacOS ||
          Platform.isWindows ||
          Platform.isLinux ||
          settings.mobileCodeBlockWrap,
      showModelIcon: settings.showModelIcon,
      showUserAvatar: settings.showUserAvatar,
      showTokenStats: settings.showTokenStats,
      assistant: assistant,
      // Who wrote each reply: a group topic names its speaker on every message,
      // and without the roster the list resolves no author and labels every
      // member reply "deleted assistant".
      assistants: context.watch<AssistantProvider>(),
      onVersionChange: (groupId, version) async {
        await _controller.setSelectedVersion(groupId, version);
      },
      // Inside a group the round, not a reply, is what gets regenerated: the
      // member replies carry no regenerate of their own.
      onRegenerateMessage: _currentGroup() == null
          ? (message) => _controller.regenerateAtMessage(message)
          : null,
      onRetryWithoutImages: (message) =>
          _controller.regenerateAtMessage(message, omitImages: true),
      onSetContextStart: (message) async {
        try {
          await chat.setConversationContextStart(
            message.conversationId,
            message.id,
          );
        } catch (error) {
          if (!context.mounted) return;
          showAppSnackBar(
            context,
            message: error.toString(),
            type: NotificationType.error,
          );
        }
      },
      onResendMessage: (message) => _controller.regenerateAtMessage(message),
      onTranslateMessage: (message) => _controller.translateMessage(message),
      onEditMessage: (message) => _controller.editMessage(message),
      onDeleteMessage: _controller.deleteMessageVersions,
      onForkConversation: _controller.isTemporaryConversation
          ? null
          : (message) => _controller.forkConversation(message),
      onSelectMessages: (index, messages) => _controller.startMessageSelection(
        messageIndex: index,
        messageList: messages,
      ),
      onSpeakMessage: (message) => _controller.speakMessage(message),
      onSuggestionTap: (suggestion) => _controller.sendSuggestion(suggestion),
      onRecoveredAskUserAnswer: (message, part, result) =>
          _controller.submitRecoveredAskUserAnswer(message, part, result),
      onToggleSelection: (messageId, selected) {
        _controller.toggleSelection(messageId, selected);
      },
      onToggleReasoning: (messageId) {
        _controller.toggleReasoning(messageId);
      },
      onToggleTranslation: (messageId) {
        _controller.toggleTranslation(messageId);
      },
      onToggleReasoningSegment: (messageId, segmentIndex) {
        _controller.toggleReasoningSegment(messageId, segmentIndex);
      },
    );
  }

  Widget _buildChatInputBar(BuildContext context, {required bool isTablet}) {
    final conversation = _controller.currentConversation;
    final settings = context.watch<SettingsProvider>();
    final chatModel = resolveChatModel(
      settings,
      conversation: conversation,
      assistant: context.watch<AssistantProvider>().currentAssistant,
    );
    final group = context.watch<GroupChatProvider>().forConversation(
      conversation,
    );
    return ChatInputSection(
      group: group,
      onOpenGroupMembers: group == null
          ? null
          : () => showGroupMembers(context, group.id),
      inputBarKey: _inputBarKey,
      chatModelProviderKey: chatModel.providerKey,
      chatModelId: chatModel.modelId,
      chatModelIsConversationOverride:
          settings.perChatModelEnabled &&
          conversation?.chatModelProvider != null &&
          conversation?.chatModelId != null,
      inputFocus: _inputFocus,
      inputController: _inputController,
      mediaController: _mediaController,
      isTablet: isTablet,
      isLoading: _controller.isCurrentConversationLoading,
      isToolModel: _controller.isToolModel,
      isReasoningModel: _controller.isReasoningModel,
      isReasoningEnabled: _controller.isReasoningEnabled,
      conversationId: _controller.currentConversation?.id,
      sendButtonTooltip: _controller.isUserMessageEditActive
          ? AppLocalizations.of(context)!.messageEditPageSaveAndSend
          : null,
      onMore: _toggleTools,
      onSelectModel: () =>
          showModelSelectSheet(context, controller: _controller),
      onLongPressSelectModel: () {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const ProvidersPage()));
      },
      onOpenWorkspace: () {
        final a = context.read<AssistantProvider>().currentAssistant;
        if (PlatformUtils.isDesktop) {
          showDesktopWorkspaceDialog(
            context,
            conversationListenable: _controller,
            conversationId: () => _controller.currentConversation?.id,
            assistantId: a?.id,
          );
        } else {
          _toggleTools();
        }
      },
      onOpenSkills: () async {
        final assistant = context.read<AssistantProvider>().currentAssistant;
        final id = await ensureConversationId(
          context,
          conversationId: _controller.currentConversation?.id,
          assistantId: assistant?.id,
        );
        if (id == null || !context.mounted) return;
        if (_controller.isDesktopPlatform) {
          await showDesktopSkillsPopover(
            context,
            anchorKey: _inputBarKey,
            conversationId: id,
            assistant: assistant,
            members: _panelMembers(),
          );
        } else {
          _controller.dismissKeyboard();
          await showConversationSkillsSheet(
            context,
            conversationId: id,
            assistant: assistant,
            members: _panelMembers(),
          );
        }
      },
      onOpenTools: () {
        final a = context.read<AssistantProvider>().currentAssistant;
        if (a == null) return;
        final toolsGroup = _currentGroup();
        final toolsMembers = toolsGroup == null
            ? null
            : _membersOfGroup(toolsGroup);
        if (PlatformUtils.isDesktop) {
          showDesktopToolsPopover(
            context,
            anchorKey: _inputBarKey,
            assistantId: a.id,
            conversationId: _controller.currentConversation?.id,
            supportsModelTools:
                chatModel.providerKey != null &&
                chatModel.modelId != null &&
                _controller.isToolModel(
                  chatModel.providerKey!,
                  chatModel.modelId!,
                ),
            // A group judges capability per member, through the same check the
            // composer uses; a 1:1 chat has only the model above.
            modelSupportsTools: toolsMembers == null
                ? null
                : _controller.isToolModel,
            members: toolsMembers,
          );
        } else {
          _controller.dismissKeyboard();
          showChatToolsSheet(
            context,
            assistantId: a.id,
            conversationId: _controller.currentConversation?.id,
            modelSupportsTools: toolsMembers == null
                ? null
                : _controller.isToolModel,
            members: toolsMembers,
          );
        }
      },
      onLongPressTools: () {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const McpPage()));
      },
      onOpenSearch: _openSearchSettings,
      reasoningButtonKey: _reasoningButtonKey,
      onConfigureReasoning: () async {
        await _openReasoningSettings();
      },
      onOpenContextUsage: () async {
        await _openContextUsagePopover();
      },
      onSend: (text) async {
        final result = await _controller.sendMessage(text);
        if (!mounted) return result;
        if (PlatformUtils.isMobile &&
            result == ChatInputSubmissionResult.sent) {
          _controller.dismissKeyboard();
        }
        return result;
      },
      onStop: _controller.cancelStreaming,
      hasQueuedInput: _controller.currentQueuedInput != null,
      queuedPreviewText: _controller.currentQueuedInput?.input.text,
      queuedStatusLabel: _controller.currentQueuedInputPaused
          ? AppLocalizations.of(context)!.chatInputBarQueuedPaused
          : null,
      queuedPaused: _controller.currentQueuedInputPaused,
      queuedSubtitle: _controller.currentQueuedInputPaused
          ? _queuedPauseReason()
          : _controller.isCurrentConversationCompressing
          ? AppLocalizations.of(context)!.chatInputBarQueuedAfterCompress
          : null,
      onCancelQueuedInput: _controller.cancelQueuedMessage,
      onExpandedChanged: _controller.setInputBarExpanded,
      onQuickPhrase: _showQuickPhraseMenu,
      onLongPressQuickPhrase: () {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const QuickPhrasesPage()));
      },
      onToggleOcr: () async {
        final sp = context.read<SettingsProvider>();
        await sp.setOcrEnabled(!sp.ocrEnabled);
      },
      onOpenMiniMap: _openMiniMap,
      onPickCamera: _controller.onPickCamera,
      onPickPhotos: _controller.onPickPhotos,
      onUploadFiles: _controller.onPickFiles,
      onOpenBrowser: () => openBrowserPage(
        context,
        conversationId: _controller.currentConversation?.id,
        assistantId: context.read<AssistantProvider>().currentAssistantId,
      ),
      onToggleLearningMode: _openInstructionInjectionPopover,
      onOpenWorldBook: _openWorldBookPopover,
      onLongPressLearning: _showLearningPromptSheet,
      onClearContext: _clearContextWithNotice,
      onCompressContext: _handleDesktopCompressContext,
      onContextOperations: _showContextOperations,
      backgroundImageActive: _assistantBackgroundActive(context),
    );
  }

  Widget _buildScrollButtons() {
    return Builder(
      builder: (context) {
        final settings = context.watch<SettingsProvider>();
        if (_controller.selecting) return const SizedBox.shrink();
        if (_controller.messages.isEmpty) {
          return const SizedBox.shrink();
        }
        var visible = _controller.scrollCtrl.showNavButtons;
        var hoverEnabled = false;
        if (_controller.isDesktopPlatform) {
          switch (settings.desktopMessageNavButtonsMode) {
            case DesktopMessageNavButtonsMode.always:
              visible = true;
              break;
            case DesktopMessageNavButtonsMode.scroll:
              visible = _controller.scrollCtrl.showNavButtons;
              break;
            case DesktopMessageNavButtonsMode.hover:
              visible = _scrollNavHovering;
              hoverEnabled = true;
              break;
            case DesktopMessageNavButtonsMode.scrollAndHover:
              visible =
                  _controller.scrollCtrl.showNavButtons || _scrollNavHovering;
              hoverEnabled = true;
              break;
            case DesktopMessageNavButtonsMode.never:
              return const SizedBox.shrink();
          }
        } else {
          switch (settings.mobileMessageNavButtonsMode) {
            case MobileMessageNavButtonsMode.always:
              visible = true;
              break;
            case MobileMessageNavButtonsMode.scroll:
              visible = _controller.scrollCtrl.showNavButtons;
              break;
            case MobileMessageNavButtonsMode.never:
              return const SizedBox.shrink();
          }
        }
        return ScrollNavButtonsPanel(
          visible: visible,
          hoverEnabled: hoverEnabled,
          onHoverChanged: hoverEnabled
              ? (hovering) {
                  if (_scrollNavHovering == hovering) return;
                  setState(() => _scrollNavHovering = hovering);
                }
              : null,
          bottomOffset: _controller.inputBarHeight + 12,
          onScrollToTop: () => _controller.scrollToTop(animate: false),
          onPreviousMessage: _controller.jumpToPreviousQuestion,
          onNextMessage: _controller.jumpToNextQuestion,
          onScrollToBottom: _controller.forceScrollToBottom,
        );
      },
    );
  }

  Widget _buildForegroundOverlay(BuildContext context) {
    final editState = _controller.userMessageEditState;
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildScrollButtons(),
        ListenableBuilder(
          listenable: _find,
          builder: (_, _) => UserMessageEditOverlay(
            visible:
                editState != null && !_controller.selecting && !_find.opened,
            previewText: editState?.previewText ?? '',
            topInset: _chatTopOverlayInset(context),
            bottomInset: _controller.inputBarHeight,
            onCancel: _controller.cancelUserMessageEdit,
            onSaveOnly: () {
              unawaited(_controller.saveUserMessageEditOnly());
            },
            onPreviewTap: _controller.focusUserMessageEditInput,
          ),
        ),
        if (PlatformUtils.isDesktop)
          Positioned(
            top: _chatTopOverlayInset(context) + 4,
            left: 8,
            right: 8,
            child: ListenableBuilder(
              listenable: _find,
              child: _conversationFindBar(desktop: true),
              builder: (_, bar) => _find.opened
                  ? Align(
                      alignment: AlignmentDirectional.topEnd,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: bar,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }

  Future<void> _openMiniMap() async {
    final conversation = _controller.currentConversation?.id;
    final collapsed = await _controller
        .loadAllCollapsedMessagesForCurrentConversation();
    if (!mounted || _controller.currentConversation?.id != conversation) return;
    void openFind() {
      if (mounted && _controller.currentConversation?.id == conversation) {
        _openConversationFind();
      }
    }

    String? selectedId;
    if (PlatformUtils.isDesktop) {
      selectedId = await showDesktopMiniMapPopover(
        context,
        anchorKey: _inputBarKey,
        messages: collapsed,
        onOpenConversationFind: openFind,
      );
    } else {
      selectedId = await showMiniMapSheet(
        context,
        collapsed,
        onOpenConversationFind: openFind,
      );
    }
    if (!mounted || _controller.currentConversation?.id != conversation) return;
    if (selectedId != null && selectedId.isNotEmpty) {
      await _controller.scrollToMessageId(selectedId, useRikkaTransition: true);
    }
  }

  Widget _wrapMessageJumpTransition(Widget child) {
    return FadeTransition(
      opacity: _controller.messageJumpOpacity,
      child: SnapshotWidget(
        controller: _controller.findViewportSnapshot,
        mode: SnapshotMode.permissive,
        child: child,
      ),
    );
  }

  Widget _wrapWithDropTarget(Widget child) {
    if (!_controller.isDesktopPlatform) return child;
    // The target stays mounted while another desktop tab is on screen: taking
    // it out of the tree would rebuild this page around it, and desktop_drop
    // hands every drop to every registered target anyway. What it must not do
    // is act — the flag is read per event, never as a build dependency.
    bool onScreen() => DesktopTabVisibility.read(context);
    return DropTarget(
      onDragEntered: (_) {
        if (onScreen()) _controller.setDragHovering(true);
      },
      onDragExited: (_) {
        _controller.setDragHovering(false);
      },
      onDragDone: (details) async {
        _controller.setDragHovering(false);
        if (!onScreen()) return;
        try {
          final files = details.files;
          await _controller.onFilesDroppedDesktop(files);
        } catch (_) {}
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          if (_controller.isDragHovering)
            IgnorePointer(
              child: Container(
                color: Theme.of(
                  context,
                ).colorScheme.scrim.withValues(alpha: 0.12),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surface.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.4),
                        width: 2,
                      ),
                    ),
                    child: Text(
                      AppLocalizations.of(context)!.homePageDropToUpload,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: AppFontWeights.semibold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ============================================================================
  // Action Handlers (UI-specific, not in controller)
  // ============================================================================

  /// The model this chat sends with: the conversation's own override first,
  /// then the assistant's model, then the global default.
  ({String? providerKey, String? modelId}) _resolvedChatModel() =>
      resolveChatModel(
        context.read<SettingsProvider>(),
        conversation: _controller.currentConversation,
        assistant: context.read<AssistantProvider>().currentAssistant,
      );

  /// The roster of [group], resolved to live assistants. Members whose
  /// assistant was deleted are skipped, exactly as the composer skips them.
  List<Assistant> _membersOfGroup(GroupChat group) {
    final ap = context.read<AssistantProvider>();
    return [
      for (final id in group.memberIds)
        if (ap.getById(id) case final assistant?) assistant,
    ];
  }

  GroupChat? _currentGroup() => context
      .read<GroupChatProvider>()
      .forConversation(_controller.currentConversation);

  /// The roster for a panel that edits one member at a time, or null in a 1:1
  /// chat, where the panel keeps its single-assistant shape.
  List<Assistant>? _panelMembers() {
    final group = _currentGroup();
    if (group == null) return null;
    final members = _membersOfGroup(group);
    return members.isEmpty ? null : members;
  }

  void _openSearchSettings() {
    final group = _currentGroup();
    if (group != null) {
      final members = _membersOfGroup(group);
      if (members.isEmpty) return;
      if (PlatformUtils.isDesktop) {
        // The popover resolves each member's own model once it has the roster;
        // the composer's model keys are deliberately left out for a group.
        showDesktopSearchProviderPopover(
          context,
          anchorKey: _inputBarKey,
          members: members,
          initialAssistantId: context
              .read<AssistantProvider>()
              .currentAssistantId,
        );
      } else {
        showSearchSettingsSheet(
          context,
          members: members,
          initialAssistantId: context
              .read<AssistantProvider>()
              .currentAssistantId,
        );
      }
      return;
    }
    final model = _resolvedChatModel();
    if (PlatformUtils.isDesktop) {
      showDesktopSearchProviderPopover(
        context,
        anchorKey: _inputBarKey,
        chatModelProviderKey: model.providerKey,
        chatModelId: model.modelId,
      );
    } else {
      showSearchSettingsSheet(
        context,
        chatModelProviderKey: model.providerKey,
        chatModelId: model.modelId,
      );
    }
  }

  Future<void> _openContextUsagePopover() async {
    final conversationId = _controller.currentConversation?.id;
    if (conversationId == null || conversationId.isEmpty) return;
    final imageTarget = _mediaController.capture();
    await showContextUsagePopover(
      context,
      onAttachImage: (path) {
        if (imageTarget.isValid) imageTarget.addImages([path]);
      },
      anchorKey: _inputBarKey,
      conversationId: conversationId,
      draftText: formatQuotedMessage(
        _inputController.text,
        _inputController.quotes,
        quoteMarker: AppLocalizations.of(context)!.selectionQuoteMarker,
      ),
      onOperations: () =>
          _showContextOperations(targetConversationId: conversationId),
    );
  }

  Future<void> _openReasoningSettings() async {
    final group = _currentGroup();
    if (group != null) {
      final members = _membersOfGroup(group);
      if (members.isEmpty) return;
      final current = context.read<AssistantProvider>().currentAssistant;
      if (PlatformUtils.isDesktop) {
        // No model check here: the popover names no model of its own, it reads
        // each member's once the strip selects one. A group whose members all
        // have models therefore opens even when the composer's own assistant
        // has none — the mobile sheet has always behaved that way.
        await showDesktopGroupReasoningPopover(
          context,
          anchorKey: _inputBarKey,
          members: members,
          initialAssistantId: current?.id,
        );
      } else {
        await showGroupReasoningSheet(
          context,
          members: members,
          supportsReasoning: _controller.isReasoningModel,
          initialAssistantId: current?.id,
        );
      }
      return;
    }
    final model = _resolvedChatModel();
    final providerKey = model.providerKey;
    final modelId = model.modelId;
    if (providerKey == null || modelId == null) return;
    final settings = context.read<SettingsProvider>();
    final config = settings.getProviderConfig(providerKey);
    if (!ModelSpecResolver.instance.spec(config, modelId).supportsReasoning) {
      return;
    }
    final assistant = context.read<AssistantProvider>().currentAssistant;
    final conversationId = await ensureConversationId(
      context,
      conversationId: _controller.currentConversation?.id,
      assistantId: assistant?.id,
    );
    if (!mounted) return;
    if (PlatformUtils.isDesktop) {
      await showDesktopReasoningLevelPopover(
        context,
        anchorKey: _reasoningButtonKey,
        config: config,
        modelId: modelId,
        assistant: assistant,
        conversationId: conversationId,
      );
    } else {
      await showReasoningLevelSheet(
        context,
        config: config,
        modelId: modelId,
        assistant: assistant,
        conversationId: conversationId,
      );
    }
  }

  Future<void> _openInstructionInjectionPopover() async {
    final isDesktop = PlatformUtils.isDesktop;
    final assistantId = context.read<AssistantProvider>().currentAssistantId;
    final provider = context.read<InstructionInjectionProvider>();
    await provider.initialize();
    if (!mounted) return;
    final items = provider.items;
    if (items.isEmpty) return;

    final members = _panelMembers();
    // A group decides the scope per member inside the panel, so the conversation
    // has to exist either way.
    final scoped =
        members != null ||
        (context
                .read<AssistantProvider>()
                .currentAssistant
                ?.allowConversationPromptInjection ??
            false);
    final scopeId = scoped
        ? await ensureConversationId(
            context,
            conversationId: _controller.currentConversation?.id,
            assistantId: assistantId,
          )
        : null;
    if (!mounted || (scoped && scopeId == null)) return;
    if (isDesktop) {
      await showDesktopInstructionInjectionPopover(
        context,
        anchorKey: _inputBarKey,
        items: items,
        assistantId: assistantId,
        conversationId: scopeId,
        members: members,
      );
    } else {
      await showInstructionInjectionSheet(
        context,
        assistantId: assistantId,
        conversationId: scopeId,
      );
    }
  }

  Future<void> _openWorldBookPopover() async {
    final isDesktop = PlatformUtils.isDesktop;
    final assistantId = context.read<AssistantProvider>().currentAssistantId;
    final provider = context.read<WorldBookProvider>();
    await provider.initialize();
    if (!mounted) return;
    final books = provider.books;
    if (books.isEmpty) return;

    final members = _panelMembers();
    final scoped =
        members != null ||
        (context
                .read<AssistantProvider>()
                .currentAssistant
                ?.allowConversationPromptInjection ??
            false);
    final scopeId = scoped
        ? await ensureConversationId(
            context,
            conversationId: _controller.currentConversation?.id,
            assistantId: assistantId,
          )
        : null;
    if (!mounted || (scoped && scopeId == null)) return;
    if (isDesktop) {
      await showDesktopWorldBookPopover(
        context,
        anchorKey: _inputBarKey,
        books: books,
        assistantId: assistantId,
        conversationId: scopeId,
        members: members,
      );
    } else {
      await showWorldBookSheet(
        context,
        assistantId: assistantId,
        conversationId: scopeId,
      );
    }
  }

  Future<void> _showLearningPromptSheet() async {
    await showLearningPromptSheet(context);
  }

  void _toggleTools() async {
    _controller.dismissKeyboard();
    final assistantId = context.read<AssistantProvider>().currentAssistantId;
    final group = _currentGroup();
    final members = group == null ? null : _membersOfGroup(group);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.overlaySurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            return SafeArea(
              top: false,
              child: BottomToolsSheet(
                onPhotos: () {
                  Navigator.of(ctx).maybePop();
                  _controller.onPickPhotos();
                },
                onCamera: () {
                  Navigator.of(ctx).maybePop();
                  _controller.onPickCamera();
                },
                onUpload: () {
                  Navigator.of(ctx).maybePop();
                  _controller.onPickFiles();
                },
                onClear: () async {
                  await Navigator.of(ctx).maybePop();
                  _showContextManagementSheet();
                },
                assistantId: assistantId,
                conversationId: _controller.currentConversation?.id,
                members: members,
                onClose: () => Navigator.of(ctx).maybePop(),
              ),
            );
          },
        );
      },
    );
  }

  void _showContextManagementSheet() async {
    final imageTarget = _mediaController.capture();
    final imageConversationId = _controller.currentConversation?.id;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.overlaySurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: ContextManagementSheet(
            onOperations: imageConversationId == null
                ? null
                : () async {
                    await Navigator.of(ctx).maybePop();
                    if (mounted) {
                      await _showContextOperations(
                        targetConversationId: imageConversationId,
                      );
                    }
                  },
            onImages: imageConversationId == null
                ? null
                : () async {
                    await Navigator.of(ctx).maybePop();
                    if (!mounted) return;
                    await showImageContextPanel(
                      context,
                      imageConversationId,
                      onAttach: (path) {
                        if (imageTarget.isValid) imageTarget.addImages([path]);
                      },
                    );
                  },
            conversationId: _controller.currentConversation?.id,
            draftText: formatQuotedMessage(
              _inputController.text,
              _inputController.quotes,
              quoteMarker: AppLocalizations.of(context)!.selectionQuoteMarker,
            ),
            onCompress: () async {
              await Navigator.of(ctx).maybePop();
              if (!mounted) return;
              await _showCompressContextOptions();
            },
            onClear: () async {
              Navigator.of(ctx).maybePop();
              await _clearContextWithNotice();
            },
          ),
        );
      },
    );
  }

  void _handleDesktopCompressContext() async {
    await _showCompressContextOptions();
  }

  Future<void> _showContextOperations({String? targetConversationId}) async {
    final id = targetConversationId ?? _controller.currentConversation?.id;
    if (id == null) return;
    final chat = context.read<ChatService>();
    final conversation = chat.getConversation(id);
    if (conversation == null) return;
    final assistant = context
        .read<AssistantProvider>()
        .resolveConversationAssistant(conversation.assistantId);
    await showContextOperations(
      context,
      chat: chat,
      conversationId: id,
      messageLimit: assistant?.limitContextMessages == true
          ? assistant!.contextMessageSize
          : 0x7fffffff,
      onOpenOperation: (operation) => showContextOperationDetails(
        context,
        chat: chat,
        conversationId: id,
        operation: operation,
        onViewOriginal: (messageId) async {
          if (_controller.currentConversation?.id == id) {
            await _controller.scrollToMessageId(messageId);
          }
        },
        onRecompress: () =>
            _showCompressContextOptions(targetConversationId: id),
        onOpenConversation: _controller.switchConversationAnimated,
      ),
      onRetry: (task) => _controller.compressContext(
        options: task.options,
        targetConversationId: id,
        beforeMessageId: task.protectedMessageId,
        effectiveMessageIds: task.effectiveMessageIds,
      ),
      onAdjust: (task) => _showCompressContextOptions(
        targetConversationId: id,
        initialOptions: task.options,
        initialError: task.error,
        reviewPending: false,
      ),
      onOpenConversation: _controller.switchConversationAnimated,
    );
  }

  Future<void> _showCompressContextOptions({
    String? targetConversationId,
    CompressContextOptions? initialOptions,
    String? initialError,
    bool reviewPending = true,
  }) async {
    final chat = context.read<ChatService>();
    final conversation = targetConversationId == null
        ? _controller.currentConversation
        : chat.getConversation(targetConversationId);
    if (conversation == null) return;
    final pending = chat.contextCompression.taskFor(conversation.id);
    if (reviewPending && pending?.phase == CompressionPhase.review) {
      await showCompressionReview(
        context,
        chat: chat,
        task: pending!,
        onRecompress: () => _showCompressContextOptions(
          targetConversationId: conversation.id,
          initialOptions: pending.options,
          initialError: pending.error,
          reviewPending: false,
        ),
      );
      return;
    }
    final assistant = context
        .read<AssistantProvider>()
        .resolveConversationAssistant(conversation.assistantId);
    final messageWindow = assistant?.limitContextMessages == true
        ? assistant!.contextMessageSize
        : null;
    Future<ConversationContextHistory>? previewHistory;
    var previewRevision = -1;
    final options = await showCompressContextOptions(
      context: context,
      builder: (sheet) => CompressContextOptionsDialog(
        sheet: sheet,
        conversationId: conversation.id,
        loadHistory: () => chat.loadCompressionHistory(conversation.id),
        historyRevision: chat.compressionHistoryRevisionListenable(
          conversation.id,
        ),
        previewCarried: (options, config) async {
          return _controller.previewCarriedMessages(
            conversation.id,
            options,
            config,
          );
        },
        previewRequest: (options, config) {
          final revision = chat.compressionHistoryRevision(conversation.id);
          if (previewHistory == null || previewRevision != revision) {
            previewRevision = revision;
            previewHistory = chat.loadContextHistory(conversation.id);
          }
          final history = previewHistory!;
          return _controller
              .previewCompressionRequest(
                conversation.id,
                options,
                config,
                history: history,
              )
              .catchError((Object error, StackTrace stack) {
                if (identical(previewHistory, history)) previewHistory = null;
                Error.throwWithStackTrace(error, stack);
              });
        },
        messageWindow: messageWindow,
        initialOptions: initialOptions,
        initialError: initialError,
      ),
    );
    if (options == null || !mounted) return;
    final error = await _controller.compressContext(
      options: options,
      targetConversationId: conversation.id,
    );
    if (error != null && mounted) {
      final l10n = AppLocalizations.of(context)!;
      final target = compressionRecoveryTarget(error, native: options.native);
      showAppSnackBar(
        context,
        message: compressionErrorLabel(l10n, error),
        type: NotificationType.warning,
        actionLabel: target?.label(l10n) ?? l10n.ttsServicesDialogErrorTitle,
        onAction: () => target == null
            ? showCompressionErrorDetails(context, error)
            : _showCompressContextOptions(
                targetConversationId: conversation.id,
                initialOptions: options,
                initialError: error,
                reviewPending: false,
              ),
      );
    }
  }

  Future<void> _showQuickPhraseMenu() async {
    final assistant = context.read<AssistantProvider>().currentAssistant;
    final quickPhraseProvider = context.read<QuickPhraseProvider>();
    // In a group the entry exists because any member has a phrase, so the menu
    // must be built from that same union: the composer's "current assistant" is
    // not necessarily a member, and it is not who the button speaks for.
    final group = _currentGroup();
    final owners = <Assistant>[
      if (group != null)
        ..._membersOfGroup(group)
      else if (assistant != null)
        assistant,
    ];

    final seen = <String>{};
    final allAvailable = <QuickPhrase>[
      for (final phrase in [
        ...quickPhraseProvider.globalPhrases,
        for (final owner in owners)
          ...quickPhraseProvider.getForAssistant(owner.id),
      ])
        if (seen.add(phrase.content)) phrase,
    ];
    if (allAvailable.isEmpty) return;

    final RenderBox? inputBox =
        _inputBarKey.currentContext?.findRenderObject() as RenderBox?;
    if (inputBox == null) return;

    final inputBarHeight = inputBox.size.height;
    final topLeft = inputBox.localToGlobal(Offset.zero);
    final position = Offset(topLeft.dx, inputBarHeight);

    _controller.dismissKeyboard();

    QuickPhrase? selected;
    if (PlatformUtils.isDesktop) {
      selected = await showDesktopQuickPhrasePopover(
        context,
        anchorKey: _inputBarKey,
        phrases: allAvailable,
      );
    } else {
      selected = await showQuickPhraseMenu(
        context: context,
        phrases: allAvailable,
        position: position,
      );
    }

    if (selected != null && mounted) {
      await _controller.handleQuickPhraseSelection(selected);
    }
  }

  Future<void> _handleDeleteSelectedMessages(
    BuildContext context, {
    required bool deleteAllVersions,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    if (_controller.selectedItems.isEmpty) {
      showAppSnackBar(
        context,
        message: l10n.chatSelectionSelectMessagesToDelete,
        type: NotificationType.info,
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          deleteAllVersions
              ? l10n.homePageDeleteAllVersions
              : l10n.chatSelectionDeleteSelected,
        ),
        content: Text(
          deleteAllVersions
              ? l10n.chatSelectionDeleteSelectedAllVersionsConfirm(
                  _controller.selectedItems.length,
                )
              : l10n.chatSelectionDeleteSelectedConfirm(
                  _controller.selectedItems.length,
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.homePageCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              l10n.homePageDelete,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    await _controller.deleteSelectedMessages(
      deleteAllVersions: deleteAllVersions,
    );
  }

  Map<String, TranslationUiState> _buildTranslationUiStates() {
    final result = <String, TranslationUiState>{};
    for (final entry in _controller.translations.entries) {
      result[entry.key] = TranslationUiState(
        expanded: entry.value.expanded,
        onToggle: () {
          _controller.toggleTranslation(entry.key);
        },
      );
    }
    return result;
  }
}
