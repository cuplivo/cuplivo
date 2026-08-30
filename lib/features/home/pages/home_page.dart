import 'dart:async';
import 'dart:io' show File, Platform;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../l10n/app_localizations.dart';
import '../../../main.dart';
import '../../../shared/widgets/interactive_drawer.dart';
import '../../../shared/responsive/breakpoints.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/loading_dialog_card.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/design_tokens.dart';
import '../../../theme/app_semantic_colors.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/tts_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/providers/quick_phrase_provider.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/providers/world_book_provider.dart';
import '../../../core/services/trash_restore_coordinator.dart';
import '../../../core/services/streaming_content_notifier.dart';
import '../../settings/pages/trash_detail_page.dart';
import '../widgets/live_panel.dart';
import '../widgets/image_generation_options.dart';
import '../../../core/models/quick_phrase.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/services/chat/external_chat_draft_handoff.dart';
import '../../../core/services/android_process_text.dart';
import '../../../core/services/network/dio_http_client.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../utils/platform_utils.dart';
import '../../../desktop/search_provider_popover.dart';
import '../../../desktop/reasoning_budget_popover.dart';
import '../../../desktop/tools_hub_popover.dart';
import '../../../desktop/mini_map_popover.dart';
import '../../../desktop/quick_phrase_popover.dart';
import '../../../desktop/instruction_injection_popover.dart';
import '../../../desktop/skills_popover.dart';
import '../../../desktop/world_book_popover.dart';
import '../../../desktop/document_processing_popover.dart';
import '../../../desktop/html_preview_dialog.dart';
import '../../../icons/lucide_adapter.dart';
import '../../chat/widgets/bottom_tools_sheet.dart';
import '../../chat/widgets/context_management_sheet.dart';
import '../../chat/widgets/message_more_sheet.dart';
import '../../chat/widgets/reasoning_budget_sheet.dart';
import '../../chat/pages/reading_mode_page.dart';
import '../../chat/pages/image_viewer_page.dart';
import '../../chat/pages/html_preview_page.dart';
import '../../chat/models/tool_ui_part.dart';
import '../../chat/utils/message_visual_content.dart';
import '../../chat/widgets/citation_sources_sheet.dart';
import '../../search/widgets/search_settings_sheet.dart';
import '../../model/widgets/model_select_sheet.dart';
import '../../mcp/pages/mcp_page.dart';
import '../../provider/pages/providers_page.dart';
import '../../home/widgets/tools_hub_sheet.dart';
import '../../quick_phrase/pages/quick_phrases_page.dart';
import '../../quick_phrase/widgets/quick_phrase_menu.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/mini_map_sheet.dart';
import '../widgets/instruction_injection_sheet.dart';
import '../../skills/pages/skills_page.dart';
import '../../skills/skill_manager.dart';
import '../../skills/widgets/skills_sheet.dart';
import '../widgets/world_book_sheet.dart';
import '../widgets/document_processing_sheet.dart';
import '../widgets/learning_prompt_sheet.dart';
import '../widgets/scroll_nav_buttons.dart';
import '../widgets/message_list_view.dart';
import '../widgets/multi_ai_comparison_view.dart';
import '../services/multi_ai_engine.dart' show MultiAIMode;
import '../services/ask_user_interaction_service.dart';
import '../services/tool_approval_service.dart';
import '../widgets/chat_input_section.dart';
import '../widgets/chat_input_overlay_layout.dart';
import '../widgets/chat_selection_action_bar.dart';
import '../widgets/chat_selection_app_bar.dart';
import '../widgets/chat_selection_delete_dialog.dart';
import '../widgets/user_message_edit_overlay.dart';
import '../utils/model_display_helper.dart';
import '../utils/chat_layout_constants.dart';
import '../utils/input_bar_button_layout.dart';
import 'input_bar_buttons_customization_page.dart';
import '../controllers/home_page_controller.dart';
import '../controllers/home_view_model.dart';
import '../controllers/conversation_viewport_port.dart';
import '../controllers/scroll_controller.dart' as scroll_ctrl;
import '../webview/web_chat_protocol.dart';
import '../webview/web_chat_platform.dart';
import '../webview/web_chat_snapshot.dart';
import '../webview/web_conversation_viewport.dart';
import 'home_mobile_layout.dart';
import 'home_desktop_layout.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _TemporaryConversationEmptyState extends StatelessWidget {
  const _TemporaryConversationEmptyState({
    required this.topContentPadding,
    required this.bottomContentPadding,
  });

  final double topContentPadding;
  final double bottomContentPadding;

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
            ],
          ),
        ),
      ),
    );
  }
}

String _compressContextErrorMessage(AppLocalizations l10n, String error) {
  return switch (error) {
    'no_messages' => l10n.compressContextNoMessages,
    'no_conversation' => l10n.compressContextNoConversation,
    'no_model' => l10n.compressContextNoModel,
    'empty_summary' => l10n.compressContextEmptySummary,
    _ => '${l10n.compressContextFailed}: $error',
  };
}

class _CompressContextOptionsDialog extends StatefulWidget {
  const _CompressContextOptionsDialog({required this.collapsedMessages});

  final List<ChatMessage> collapsedMessages;

  @override
  State<_CompressContextOptionsDialog> createState() =>
      _CompressContextOptionsDialogState();
}

class _CompressContextOptionsDialogState
    extends State<_CompressContextOptionsDialog> {
  CompressContextLimitMode _mode = CompressContextLimitMode.start;
  late final TextEditingController _maxCharsController;
  late final String _totalTextForEstimate;
  String? _error;
  late int _keepCount;

  int get _userMessageCount => countUserMessages(widget.collapsedMessages);

  bool get _keepCoversAll =>
      _userMessageCount == 0 || _keepCount >= _userMessageCount;

  @override
  void initState() {
    super.initState();
    _maxCharsController = TextEditingController(
      text: CompressContextOptions.defaultMaxChars.toString(),
    );
    _totalTextForEstimate = buildConversationTextForCompression(
      widget.collapsedMessages,
    );
    _keepCount = defaultKeepUserMessageCountFor(_userMessageCount);
  }

  @override
  void dispose() {
    _maxCharsController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_mode == CompressContextLimitMode.keepRecent) {
      if (_keepCoversAll) {
        // The keep-all hint is already shown inline in the preview area.
        return;
      }
      Navigator.of(
        context,
      ).pop(CompressContextOptions(mode: _mode, keepUserMessages: _keepCount));
      return;
    }

    int? maxChars;
    if (_mode != CompressContextLimitMode.unlimited) {
      maxChars = int.tryParse(_maxCharsController.text.trim());
      if (maxChars == null || maxChars <= 0) {
        setState(() {
          _error = AppLocalizations.of(context)!.compressContextInvalidLimit;
        });
        return;
      }
    }

    Navigator.of(
      context,
    ).pop(CompressContextOptions(mode: _mode, maxChars: maxChars));
  }

  String _keepEstimateText(AppLocalizations l10n) {
    final keptText = buildConversationTextForCompression(
      selectKeepRecentMessages(widget.collapsedMessages, _keepCount),
    );
    final summarizedChars = (_totalTextForEstimate.length - keptText.length)
        .clamp(0, _totalTextForEstimate.length)
        .toInt();
    final est = estimateCompressionTokens(
      totalText: _totalTextForEstimate,
      keptText: keptText,
    );
    return l10n.compressContextEstimatePreview(
      summarizedChars,
      keptText.length,
      est.minResultTokens,
      est.maxResultTokens,
      est.totalTokens,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final panelColor = context.appColors.surfaceCard;
    final constrainedWidth = MediaQuery.of(
      context,
    ).size.width.clamp(0.0, 420.0).toDouble();

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: constrainedWidth),
        child: Material(
          color: panelColor,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Lucide.package2, size: 20, color: cs.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l10n.compressContextOptionsTitle,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: AppFontWeights.emphasis,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.compressContextOptionsDesc,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: cs.onSurface.withValues(alpha: 0.62),
                  ),
                ),
                const SizedBox(height: 16),
                _CompressModeSegmented(
                  mode: _mode,
                  keepRecentDisabled: _userMessageCount <= 1,
                  onChanged: (mode) {
                    setState(() {
                      _mode = mode;
                      _error = null;
                    });
                  },
                ),
                if (_mode == CompressContextLimitMode.start ||
                    _mode == CompressContextLimitMode.recent) ...[
                  const SizedBox(height: 10),
                  IosFormTextField(
                    label: l10n.compressContextMaxCharsLabel,
                    controller: _maxCharsController,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    selectAllOnFocus: true,
                    fieldWidth: 120,
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                  ),
                ],
                if (_mode == CompressContextLimitMode.keepRecent) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _KeepCountButton(
                        icon: Lucide.Minus,
                        onTap: _keepCount > 1
                            ? () {
                                setState(() {
                                  _keepCount--;
                                  _error = null;
                                });
                              }
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          l10n.compressContextKeepCountLabel(_keepCount),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.onSurface.withValues(alpha: 0.78),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      _KeepCountButton(
                        icon: Lucide.Plus,
                        onTap: !_keepCoversAll
                            ? () {
                                setState(() {
                                  _keepCount++;
                                  _error = null;
                                });
                              }
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _keepCoversAll
                        ? l10n.compressContextKeepAllMessages
                        : _keepEstimateText(l10n),
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: _keepCoversAll
                          ? cs.error
                          : cs.onSurface.withValues(alpha: 0.62),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.error,
                      fontWeight: AppFontWeights.medium,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: _DialogActionButton(
                        label: l10n.homePageCancel,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _DialogActionButton(
                        label: l10n.compressContextStartButton,
                        primary: true,
                        onTap: _submit,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompressModeSegmented extends StatelessWidget {
  const _CompressModeSegmented({
    required this.mode,
    required this.onChanged,
    this.keepRecentDisabled = false,
  });

  final CompressContextLimitMode mode;
  final ValueChanged<CompressContextLimitMode> onChanged;
  final bool keepRecentDisabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        Expanded(
          child: _SegmentButton(
            label: l10n.compressContextKeepStart,
            selected: mode == CompressContextLimitMode.start,
            onTap: () => onChanged(CompressContextLimitMode.start),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _SegmentButton(
            label: l10n.compressContextKeepRecent,
            selected: mode == CompressContextLimitMode.recent,
            onTap: () => onChanged(CompressContextLimitMode.recent),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _SegmentButton(
            label: l10n.compressContextUnlimited,
            selected: mode == CompressContextLimitMode.unlimited,
            onTap: () => onChanged(CompressContextLimitMode.unlimited),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _SegmentButton(
            label: l10n.compressContextKeepRecentMessages,
            selected: mode == CompressContextLimitMode.keepRecent,
            enabled: !keepRecentDisabled,
            onTap: () => onChanged(CompressContextLimitMode.keepRecent),
          ),
        ),
      ],
    );
  }
}

class _KeepCountButton extends StatelessWidget {
  const _KeepCountButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return IosCardPress(
      baseColor: context.appColors.surfaceFill,
      borderRadius: BorderRadius.circular(10),
      pressedScale: 0.98,
      onTap: onTap,
      haptics: false,
      padding: const EdgeInsets.all(8),
      child: Icon(
        icon,
        size: 16,
        color: enabled
            ? cs.onSurface.withValues(alpha: 0.78)
            : cs.onSurface.withValues(alpha: 0.25),
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    required this.label,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedBg = isDark
        ? cs.primary.withValues(alpha: 0.22)
        : cs.primary.withValues(alpha: 0.12);
    final baseBg = context.appColors.surfaceFill;

    return IosCardPress(
      baseColor: selected ? selectedBg : baseBg,
      borderRadius: BorderRadius.circular(10),
      pressedScale: 0.98,
      onTap: enabled ? onTap : null,
      haptics: false,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Center(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: AppFontWeights.emphasis,
            color: !enabled
                ? cs.onSurface.withValues(alpha: 0.3)
                : selected
                ? cs.primary
                : cs.onSurface.withValues(alpha: 0.78),
          ),
        ),
      ),
    );
  }
}

class _DialogActionButton extends StatelessWidget {
  const _DialogActionButton({
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = primary ? cs.primary : context.appColors.surfaceFill;

    return IosCardPress(
      baseColor: base,
      borderRadius: BorderRadius.circular(11),
      pressedScale: 0.98,
      onTap: onTap,
      haptics: false,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            fontWeight: AppFontWeights.emphasis,
            color: primary ? cs.onPrimary : cs.onSurface,
          ),
        ),
      ),
    );
  }
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin, RouteAware, WidgetsBindingObserver {
  // ============================================================================
  // UI Controllers (owned by State for lifecycle management)
  // ============================================================================

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final InteractiveDrawerController _drawerController =
      InteractiveDrawerController();
  final ValueNotifier<int> _assistantPickerCloseTick = ValueNotifier<int>(0);
  final FocusNode _inputFocus = FocusNode();
  final TextEditingController _inputController = TextEditingController();
  final ChatInputBarController _mediaController = ChatInputBarController();
  final ImageGenerationOptionsController _imageGenController =
      ImageGenerationOptionsController();
  scroll_ctrl.ChatAutoFollowScrollController _scrollController =
      scroll_ctrl.ChatAutoFollowScrollController();
  final BackdropKey _messageListBackdropKey = BackdropKey();
  final GlobalKey _inputBarKey = GlobalKey();
  final GlobalKey _selectionMiniMapKey = GlobalKey();
  final GlobalKey _selectionActionBarKey = GlobalKey();
  bool _scrollNavHovering = false;
  bool _presetsExpanded = false;
  String? _scrollConversationId;
  final Set<String> _webFlutterConversationOverrides = <String>{};
  final Set<String> _webMultiAIPromptedConversations = <String>{};
  final WebConversationViewportPort _webViewportPort =
      WebConversationViewportPort();
  final Map<String, WebChatMediaSource> _webMediaRegistry =
      <String, WebChatMediaSource>{};
  String? _webRenderConversationId;
  String _webRenderSessionId = '';
  int _webActionEpoch = 0;
  double _lastViewInsetBottom = 0;
  StreamSubscription<String>? _processTextSub;

  // ============================================================================
  // Page Controller (manages all business logic and state)
  // ============================================================================

  late HomePageController _controller;

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

    _controller.addListener(_onControllerChanged);
    _drawerController.addListener(_onDrawerValueChanged);

    _controller.initChat();
    _initProcessText();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _lastViewInsetBottom = View.of(context).viewInsets.bottom;
      _controller.measureInputBar();
      if (!mounted) return;
      context.read<WorldBookProvider>().initialize();
      _checkConflicts();
    });
  }

  Future<void> _checkConflicts() async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return;
    final coordinator = context.read<TrashRestoreCoordinator>();
    final count = await coordinator.countConflicts();
    if (!mounted || count == 0) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.trashConflictSnackBar(count)),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: l10n.trashConflictSnackBarAction,
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const TrashDetailPage(initialTab: 1),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.onAppLifecycleStateChanged(state);
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final nextInset = View.of(context).viewInsets.bottom;
    final keyboardOpening = nextInset > _lastViewInsetBottom + 0.5;
    _lastViewInsetBottom = nextInset;
    if (!keyboardOpening) return;
    _controller.pinBottomDuringViewportResizeIfNeeded();
  }

  @override
  void didPushNext() {
    _controller.onDidPushNext();
  }

  @override
  void didPopNext() {
    _controller.onDidPopNext();
    unawaited(_consumeExternalChatDraft());
  }

  Future<void> _consumeExternalChatDraft() async {
    if (!mounted) return;
    final draft = ExternalChatDraftHandoff.take();
    if (draft == null) return;
    await _controller.createNewConversationWithDraft(draft);
  }

  @override
  void dispose() {
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _processTextSub?.cancel();
    _controller.removeListener(_onControllerChanged);
    _drawerController.removeListener(_onDrawerValueChanged);
    _inputFocus.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    _controller.dispose();
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  void _onControllerChanged() {
    final conversationId = _controller.currentConversation?.id;
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
    _mediaController.syncDraft();
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
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final ap = context.watch<AssistantProvider>();
    final assistant = ap.currentAssistant;

    final modelInfo = getModelDisplayInfo(settings, assistant: assistant);

    final title = _controller.isTemporaryConversation
        ? AppLocalizations.of(context)!.temporaryChatTitle
        : ((_controller.currentConversation?.title ?? '').trim().isNotEmpty)
        ? _controller.currentConversation!.title
        : _controller.titleForLocale();

    if (width >= AppBreakpoints.tablet) {
      return _buildTabletLayout(
        context,
        title: title,
        providerName: modelInfo.providerName,
        modelDisplay: modelInfo.modelDisplay,
        cs: cs,
      );
    }

    return _buildMobileLayout(
      context,
      title: title,
      providerName: modelInfo.providerName,
      modelDisplay: modelInfo.modelDisplay,
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
    final collapsed = _controller.collapseVersions(_controller.messages);
    final selectable = collapsed
        .where((m) => m.role == 'user' || m.role == 'assistant')
        .toList();
    final allSelected =
        selectable.isNotEmpty &&
        selectable.every((m) => _controller.selectedItems.contains(m.id));

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
      onSelectModel: () => showModelSelectSheet(
        context,
        onMultiSelectConfirm: _controller.enterMultiAIMode,
      ),
      globalSearchMode: _controller.isGlobalSearchMode,
      globalSearchQuery: _controller.globalSearchQuery,
      onGlobalSearchQueryChanged: _controller.setGlobalSearchQuery,
      onEnterGlobalSearch: () =>
          _controller.enterGlobalSearchMode(preserveQuery: false),
      onExitGlobalSearch: () =>
          _controller.exitGlobalSearchMode(clearQuery: true),
      onOpenGlobalSearchResult: (convId, msgId) => _controller
          .openGlobalSearchResult(conversationId: convId, messageId: msgId),
      appBarOverride: _controller.selecting
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
      body: _wrapWithDropTarget(_buildMobileBody(context, cs)),
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
          ? _buildChatBackground(context, cs)
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
          final isAndroid =
              Theme.of(context).platform == TargetPlatform.android;
          Widget w = content;
          if (!isAndroid) {
            w = w
                .animate(
                  key: ValueKey(
                    'mob_body_${_controller.currentConversation?.id ?? 'none'}',
                  ),
                )
                .fadeIn(duration: 200.ms, curve: Curves.easeOutCubic);
            w = FadeTransition(opacity: _controller.convoFade, child: w);
          }
          return w;
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
    unawaited(_controller.initDesktopUi());

    final collapsed = _controller.collapseVersions(_controller.messages);
    final selectable = collapsed
        .where((m) => m.role == 'user' || m.role == 'assistant')
        .toList();
    final allSelected =
        selectable.isNotEmpty &&
        selectable.every((m) => _controller.selectedItems.contains(m.id));

    return HomeDesktopScaffold(
      scaffoldKey: _scaffoldKey,
      assistantPickerCloseTick: _assistantPickerCloseTick,
      loadingConversationIds: _controller.loadingConversationIds,
      title: title,
      providerName: providerName,
      modelDisplay: modelDisplay,
      tabletSidebarOpen: _controller.tabletSidebarOpen,
      rightSidebarOpen: _controller.rightSidebarOpen,
      embeddedSidebarWidth: _controller.embeddedSidebarWidth,
      rightSidebarWidth: _controller.rightSidebarWidth,
      sidebarMinWidth: HomePageController.sidebarMinWidth,
      sidebarMaxWidth: HomePageController.sidebarMaxWidth,
      onToggleSidebar: _controller.toggleTabletSidebar,
      onToggleRightSidebar: _controller.toggleRightSidebar,
      onSelectConversation: (id) {
        _controller.switchConversationAnimated(id);
      },
      onNewConversation: () async {
        await _controller.createNewConversationAnimated();
      },
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
      onOpenGlobalSearchResult: (convId, msgId) => _controller
          .openGlobalSearchResult(conversationId: convId, messageId: msgId),
      onSelectModel: () => showModelSelectSheet(
        context,
        onMultiSelectConfirm: _controller.enterMultiAIMode,
      ),
      onSidebarWidthChanged: _controller.updateSidebarWidth,
      onSidebarWidthChangeEnd: _controller.saveSidebarWidth,
      onRightSidebarWidthChanged: _controller.updateRightSidebarWidth,
      onRightSidebarWidthChangeEnd: _controller.saveRightSidebarWidth,
      buildAssistantBackground: _buildAssistantBackground,
      appBarOverride: _controller.selecting
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
      body: _wrapWithDropTarget(_buildTabletBody(context, cs)),
    );
  }

  Future<void> _openSelectionMiniMap() async {
    final collapsed = _controller.allCollapsedMessagesForCurrentConversation();
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
      onExportMarkdown: _controller.exportSelectedAsMarkdown,
      onExportTxt: _controller.exportSelectedAsTxt,
      onExportImage: _controller.exportSelectedAsImage,
      onExportPdf: _controller.exportSelectedAsPdf,
      onDelete: () {
        unawaited(_handleDeleteSelectedMessages(context));
      },
      showThinkingTools: _controller.showThinkingTools,
      showThinkingContent: _controller.showThinkingContent,
      onToggleThinkingTools: _controller.toggleThinkingTools,
      onToggleThinkingContent: _controller.toggleThinkingContent,
    );
  }

  Widget _buildTabletBody(BuildContext context, ColorScheme cs) {
    final bottomContentPadding = _controller.inputBarHeight + 16;
    final topContentPadding = _chatTopOverlayInset(context) + 8;
    final backgroundImageActive = _assistantBackgroundActive(context);

    return ChatInputOverlayLayout(
      topInset: _chatTopOverlayInset(context),
      topBackground: backgroundImageActive
          ? _buildAssistantBackground(context)
          : null,
      backgroundImageActive: backgroundImageActive,
      content: FadeTransition(
        opacity: _controller.convoFade,
        child:
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
                )
                .animate(
                  key: ValueKey(
                    'tab_body_${_controller.currentConversation?.id ?? 'none'}',
                  ),
                )
                .fadeIn(duration: 200.ms, curve: Curves.easeOutCubic),
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
                    input = Center(
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

  Widget _buildChatBackground(BuildContext context, ColorScheme cs) {
    return Builder(
      builder: (context) {
        final bg = context
            .watch<AssistantProvider>()
            .currentAssistant
            ?.background;
        final maskStrength = context
            .watch<SettingsProvider>()
            .chatBackgroundMaskStrength;
        if (bg == null || bg.trim().isEmpty) return const SizedBox.shrink();
        ImageProvider provider;
        if (bg.startsWith('http')) {
          provider = NetworkImage(bg);
        } else {
          final localPath = SandboxPathResolver.fix(bg);
          final file = File(localPath);
          if (!file.existsSync()) return const SizedBox.shrink();
          provider = FileImage(file);
        }
        return Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  image: DecorationImage(
                    image: provider,
                    fit: BoxFit.cover,
                    colorFilter: ColorFilter.mode(
                      Colors.black.withValues(alpha: 0.04),
                      BlendMode.srcATop,
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: () {
                        final top = (0.20 * maskStrength).clamp(0.0, 1.0);
                        final bottom = (0.50 * maskStrength).clamp(0.0, 1.0);
                        return [
                          cs.surface.withValues(alpha: top),
                          cs.surface.withValues(alpha: bottom),
                        ];
                      }(),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildAssistantBackground(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final assistant = context.watch<AssistantProvider>().currentAssistant;
    final bgRaw = (assistant?.background ?? '').trim();
    Widget? bg;
    if (bgRaw.isNotEmpty) {
      if (bgRaw.startsWith('http')) {
        bg = Image.network(
          bgRaw,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        );
      } else {
        try {
          final fixed = SandboxPathResolver.fix(bgRaw);
          final f = File(fixed);
          if (f.existsSync()) {
            bg = Image(image: FileImage(f), fit: BoxFit.cover);
          }
        } catch (_) {}
      }
    }
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: cs.surface),
          if (bg != null) Opacity(opacity: 0.9, child: bg),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  cs.surface.withValues(alpha: 0.08),
                  cs.surface.withValues(alpha: 0.36),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _assistantBackgroundActive(BuildContext context) {
    final bgRaw =
        (context.watch<AssistantProvider>().currentAssistant?.background ?? '')
            .trim();
    if (bgRaw.isEmpty) return false;
    if (bgRaw.startsWith('http')) return true;
    try {
      final fixed = SandboxPathResolver.fix(bgRaw);
      return File(fixed).existsSync();
    } catch (_) {
      return false;
    }
  }

  double _chatTopOverlayInset(BuildContext context) {
    return kToolbarHeight + MediaQuery.paddingOf(context).top;
  }

  /// Map persisted truncateIndex (raw message count) to collapsed index.
  int _computeTruncCollapsedIndex() {
    final truncRaw = _controller.chatController.loadedWindowTruncateIndex();
    return HomeViewModel.computeTruncCollapsedIndex(
      truncRaw: truncRaw,
      rawMessages: _controller.messages,
    );
  }

  Widget _buildPresetToggleBar(
    BuildContext context, {
    required int presetCount,
    required bool isExpanded,
    required VoidCallback onToggle,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: IosCardPress(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(10),
        baseColor: Colors.transparent,
        pressedBlendStrength: 0.05,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Divider(
                color: cs.outlineVariant.withValues(alpha: 0.5),
                height: 1,
                thickness: 1,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isExpanded ? Lucide.ChevronDown : Lucide.ChevronRight,
                    size: 16,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    l10n.homePagePresetMessagesCount(presetCount),
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Divider(
                color: cs.outlineVariant.withValues(alpha: 0.5),
                height: 1,
                thickness: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageListView(
    BuildContext context, {
    required double topContentPadding,
    required double bottomContentPadding,
    required EdgeInsetsGeometry dividerPadding,
  }) {
    final settings = context.watch<SettingsProvider>();
    final assistant = context.watch<AssistantProvider>().currentAssistant;
    final conversationId =
        _controller.currentConversation?.id ??
        'temporary:${assistant?.id ?? 'unbound'}';
    var useWebViewport = _webViewportRequested(settings, conversationId);

    if (_controller.isTemporaryConversation &&
        _controller.chatController.collapsedMessages.isEmpty &&
        !useWebViewport) {
      _controller.attachConversationViewportPort(null);
      return _TemporaryConversationEmptyState(
        topContentPadding: topContentPadding,
        bottomContentPadding: bottomContentPadding,
      );
    }

    final suggestionsEnabled =
        settings.suggestionModelProvider != null &&
        settings.suggestionModelId != null;

    // Filter preset messages and build collapse toggle
    final allMessages = _controller.chatController.collapsedMessages;
    final presetCount = allMessages.takeWhile((m) => m.isPreset).length;
    final showPresetToggle = presetCount > 0;
    final messages = !_presetsExpanded && showPresetToggle
        ? allMessages.skip(presetCount).toList()
        : allMessages;

    Widget? presetHeaderWidget;
    if (showPresetToggle) {
      presetHeaderWidget = _buildPresetToggleBar(
        context,
        presetCount: presetCount,
        isExpanded: _presetsExpanded,
        onToggle: () => setState(() => _presetsExpanded = !_presetsExpanded),
      );
    }

    // Build inline multi-AI card widgets keyed by anchor user message ID
    final afterMessageWidgets = <String, Widget>{};
    for (final anchorId in _controller.multiAIEngine.anchorMessageIds) {
      final subgrouped = _controller.multiAIEngine.getMessagesForAnchor(
        anchorId,
      );
      if (subgrouped.isEmpty) continue;
      afterMessageWidgets[anchorId] = MultiAICardGroup(
        key: ValueKey('multi-ai-anchor-$anchorId'),
        anchorUserMessageId: anchorId,
        subgroupedMessages: subgrouped,
        controller: _controller,
        isLatestRound: _controller.multiAIEngine.latestAnchorId == anchorId,
      );
    }

    if (useWebViewport && afterMessageWidgets.isNotEmpty) {
      useWebViewport = false;
      _scheduleMultiAIFallbackPrompt(conversationId);
    }

    final truncIndex = HomeViewModel.adjustTruncIndexForPresetFolding(
      truncIndex: _computeTruncCollapsedIndex(),
      presetCount: presetCount,
      showPresetToggle: showPresetToggle,
      presetsExpanded: _presetsExpanded,
    );

    final suggestions = suggestionsEnabled
        ? (_controller.currentConversation?.chatSuggestions ?? const <String>[])
        : const <String>[];

    if (useWebViewport) {
      context.watch<ToolApprovalService>();
      context.watch<AskUserInteractionService>();
      final user = context.watch<UserProvider>();
      final ttsActive = context.select<TtsProvider, bool>(
        (provider) => provider.playbackState.isActive,
      );
      _webViewportPort.activateConversation(conversationId);
      _controller.attachConversationViewportPort(_webViewportPort);
      _ensureWebRenderSession(conversationId);
      final activeLiveMessageIds = <String>{
        for (final message in messages)
          if (_controller.streamingContentNotifier.hasNotifier(message.id))
            message.id,
      };
      final snapshotMediaRegistry = buildWebChatMediaRegistry(
        messages,
        assistant: assistant,
        userAvatarType: user.avatarType,
        userAvatarValue: user.avatarValue,
        toolParts: _controller.toolParts,
      );
      final retainedLiveMedia = <String, WebChatMediaSource>{
        for (final entry in _webMediaRegistry.entries)
          if (entry.value.messageIds.any(activeLiveMessageIds.contains))
            entry.key: WebChatMediaSource(
              kind: entry.value.kind,
              value: entry.value.value,
              messageIds: entry.value.messageIds
                  .where(activeLiveMessageIds.contains)
                  .toSet(),
            ),
      };
      _webMediaRegistry
        ..clear()
        ..addAll(snapshotMediaRegistry);
      for (final entry in retainedLiveMedia.entries) {
        final current = _webMediaRegistry[entry.key];
        _webMediaRegistry[entry.key] = WebChatMediaSource(
          kind: entry.value.kind,
          value: entry.value.value,
          messageIds: <String>{
            ...?current?.messageIds,
            ...entry.value.messageIds,
          },
        );
      }
      final mediaRegistry = _webMediaRegistry;
      final snapshot = _buildWebChatSnapshot(
        context: context,
        conversationId: conversationId,
        messages: messages,
        assistant: assistant,
        settings: settings,
        truncIndex: truncIndex,
        suggestions: suggestions,
        presetCount: presetCount,
        showPresetToggle: showPresetToggle,
        user: user,
        ttsActive: ttsActive,
        topContentPadding: topContentPadding,
        bottomContentPadding: bottomContentPadding,
        activeLiveMessageIds: activeLiveMessageIds,
        remoteMediaHandles: <String, String>{
          for (final entry in mediaRegistry.entries)
            if (entry.value.kind == WebChatMediaSourceKind.remoteImage)
              entry.value.value: entry.key,
        },
      );
      final htmlPreviewRegistry = buildWebChatHtmlPreviewRegistry(snapshot);
      final htmlPreviewMessages = <String, Map<String, dynamic>>{};
      for (final raw
          in snapshot['messages'] as List<dynamic>? ?? const <dynamic>[]) {
        if (raw is! Map) continue;
        final message = raw.map(
          (key, value) => MapEntry(key.toString(), value),
        );
        final messageId = message['id']?.toString() ?? '';
        if (messageId.isNotEmpty) htmlPreviewMessages[messageId] = message;
      }
      return WebConversationViewport(
        key: const ValueKey<String>('web-conversation-viewport'),
        snapshot: snapshot,
        mediaRegistry: mediaRegistry,
        viewportPort: _webViewportPort,
        streamingContentNotifier: _controller.streamingContentNotifier,
        buildStreamingPatch: (messageId, data) {
          final patch = _buildWebStreamingPatch(messageId, data, assistant);
          if (patch != null) {
            _registerWebPatchMedia(messageId, patch, mediaRegistry);
            final current = htmlPreviewMessages[messageId];
            if (current != null) {
              current.addAll(patch);
              if (patch['isStreaming'] == true) {
                htmlPreviewRegistry.removeWhere(
                  (_, entry) => entry.messageId == messageId,
                );
              } else {
                replaceWebChatHtmlPreviews(
                  messageId: messageId,
                  serialized: current,
                  registry: htmlPreviewRegistry,
                );
              }
            }
          }
          return patch;
        },
        onAction: (request) => _handleWebChatAction(
          request,
          visibleMessages: messages,
          mediaRegistry: mediaRegistry,
          htmlPreviewRegistry: htmlPreviewRegistry,
        ),
        onUseFlutter: () {
          setState(() {
            _webFlutterConversationOverrides.add(conversationId);
          });
        },
        onUserScrollIntent: _controller.scrollCtrl.revealNavButtons,
        remoteMediaClientFactory: () => _webChatHttpClient(settings),
      );
    }

    _controller.attachConversationViewportPort(null);

    final messageList = MessageListView(
      isProcessingFiles: _controller.isProcessingFiles,
      scrollController: _scrollController,
      listController: _controller.scrollCtrl.messageListController,
      onUserScrollIntent: _controller.scrollCtrl.handleUserScrollIntent,
      messages: messages,
      headerWidget: presetHeaderWidget,
      byGroup: _controller.chatController.groupedMessages,
      versionSelections: _controller.versionSelections,
      truncCollapsedIndex: truncIndex,
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
      chatFontScale: settings.chatFontScale,
      collapseThinking: settings.autoCollapseThinking,
      collapsedCodeLines: settings.autoCollapseCodeBlock
          ? settings.autoCollapseCodeBlockLines
          : null,
      wrapCodeBlocks:
          Platform.isMacOS ||
          Platform.isWindows ||
          Platform.isLinux ||
          settings.mobileCodeBlockWrap,
      showModelIcon: settings.showModelIcon,
      showUserAvatar: settings.showUserAvatar,
      showTokenStats: settings.showTokenStats,
      assistant: assistant,
      streamingContentNotifier: _controller.streamingContentNotifier,
      spotlightMessageId: _controller.spotlightMessageId,
      spotlightToken: _controller.spotlightToken,
      afterMessageWidgets: afterMessageWidgets,
      hasMoreBefore: _controller.chatController.hasMoreBefore,
      onLoadMoreBefore: _controller.loadMoreBefore,
      hasMoreAfter: _controller.chatController.hasMoreAfter,
      onLoadMoreAfter: _controller.loadMoreAfter,
      hideMoreActions: () {
        final hide = <MessageMoreAction>{};
        if (!_controller.canStartMultiAIComparison) {
          hide.add(MessageMoreAction.multiAI);
        }
        return hide;
      },
      onVersionChange: (groupId, version) async {
        await _controller.setSelectedVersion(groupId, version);
      },
      onRegenerateMessage: (message) =>
          _controller.regenerateAtMessage(message),
      onResendMessage: (message) => _controller.regenerateAtMessage(message),
      onTranslateMessage: (message) => _controller.translateMessage(message),
      onEditMessage: (message) => _controller.editMessage(message),
      onDeleteMessage: (message, byGroup) =>
          _handleDeleteMessage(context, message, byGroup),
      onDeleteAllVersions: (message, byGroup) => _handleDeleteMessage(
        context,
        message,
        byGroup,
        deleteAllVersions: true,
      ),
      onMultiAI: (message) => _controller.handleMultiAIAction(message),
      onForkConversation: (message) => _controller.forkConversation(message),
      onSelectMessages: (index, messages) => _controller.startMessageSelection(
        messageIndex: index,
        messageList: messages,
      ),
      onSpeakMessage: (message) => _controller.speakMessage(message),
      onSuggestionTap: (suggestion) => _controller.sendSuggestion(suggestion),
      onQuoteSelection: (text) => _controller.insertQuote(text),
      onReplyMessage: (message) => _controller.startReplyTo(message),
      onReplySelectionMessage: (message, selected) =>
          _controller.startReplyToSelection(message, selected),
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

    return BackdropGroup(
      backdropKey: _messageListBackdropKey,
      child: messageList,
    );
  }

  bool _webViewportRequested(SettingsProvider settings, String conversationId) {
    if (!settings.experimentalWebViewRendering) {
      _webFlutterConversationOverrides.clear();
      _webMultiAIPromptedConversations.clear();
      _webMediaRegistry.clear();
      return false;
    }
    return supportsWebConversationViewport(
          isWeb: kIsWeb,
          platform: defaultTargetPlatform,
        ) &&
        !_webFlutterConversationOverrides.contains(conversationId);
  }

  DioHttpClient _webChatHttpClient(SettingsProvider settings) {
    final host = settings.globalProxyHost.trim();
    final port = settings.globalProxyPort.trim();
    if (!settings.globalProxyEnabled || host.isEmpty || port.isEmpty) {
      return DioHttpClient(forceCloseOnDispose: true);
    }
    return DioHttpClient(
      forceCloseOnDispose: true,
      proxy: NetworkProxyConfig(
        enabled: true,
        type: settings.globalProxyType,
        host: host,
        port: int.tryParse(port) ?? 8080,
        username: settings.globalProxyUsername.trim().isEmpty
            ? null
            : settings.globalProxyUsername.trim(),
        password: settings.globalProxyPassword.isEmpty
            ? null
            : settings.globalProxyPassword,
      ),
    );
  }

  void _ensureWebRenderSession(String conversationId) {
    if (_webRenderConversationId == conversationId) return;
    _webRenderConversationId = conversationId;
    _webMediaRegistry.clear();
    _webRenderSessionId =
        '$conversationId:${DateTime.now().microsecondsSinceEpoch}';
    _webActionEpoch++;
  }

  Map<String, dynamic> _buildWebChatSnapshot({
    required BuildContext context,
    required String conversationId,
    required List<ChatMessage> messages,
    required Assistant? assistant,
    required SettingsProvider settings,
    required int truncIndex,
    required List<String> suggestions,
    required int presetCount,
    required bool showPresetToggle,
    required UserProvider user,
    required bool ttsActive,
    required double topContentPadding,
    required double bottomContentPadding,
    required Set<String> activeLiveMessageIds,
    required Map<String, String> remoteMediaHandles,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final semantic = context.appColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final display = webChatDisplay(
      settings,
      wrapCode:
          Platform.isMacOS ||
          Platform.isWindows ||
          Platform.isLinux ||
          settings.mobileCodeBlockWrap,
      isDark: isDark,
      ttsActive: ttsActive,
    );
    final snapshot = const WebChatSnapshotBuilder().build(
      renderSessionId: _webRenderSessionId,
      conversationId: conversationId,
      // The viewport assigns a revision only after semantic deduplication.
      renderRevision: 0,
      actionEpoch: _webActionEpoch,
      messages: messages,
      byGroup: _controller.chatController.groupedMessages,
      versionSelections: _controller.versionSelections,
      reasoning: _controller.reasoning,
      reasoningSegments: _controller.reasoningSegments,
      contentSplits: _controller.contentSplits,
      toolParts: _controller.toolParts,
      selectedItems: _controller.selectedItems,
      selecting: _controller.selecting,
      truncCollapsedIndex: truncIndex,
      suggestions: suggestions,
      hasMoreBefore: _controller.chatController.hasMoreBefore,
      hasMoreAfter: _controller.chatController.hasMoreAfter,
      strings: webChatUiStrings(l10n),
      theme: webChatThemeColors(
        colors: colors,
        semantic: semantic,
        isDark: isDark,
        backgroundMaskStrength: settings.chatBackgroundMaskStrength,
      ),
      appearance:
          settings.activeWebConversationStyle?.resolveAppearance(
            isDark: isDark,
          ) ??
          const <String, dynamic>{},
      user: buildWebChatUserSnapshot(
        name: user.name,
        avatarType: user.avatarType,
        avatarValue: user.avatarValue,
      ),
      display: display,
      topContentPadding: topContentPadding,
      bottomContentPadding: bottomContentPadding,
      assistant: assistant,
      fontScale: settings.chatFontScale,
      canStartMultiAI: _controller.canStartMultiAIComparison,
      autoCollapseThinking: settings.autoCollapseThinking,
      initialViewportAnchor: _webViewportPort
          .savedAnchorForConversation(conversationId)
          ?.toJson(),
      locale: Localizations.localeOf(context).toLanguageTag(),
      textDirection: Directionality.of(context) == TextDirection.rtl
          ? 'rtl'
          : 'ltr',
      remoteMediaHandles: remoteMediaHandles,
      liveTranslationMessageIds: <String>{
        for (final message in messages)
          if (!message.isStreaming && activeLiveMessageIds.contains(message.id))
            message.id,
      },
    );
    if (showPresetToggle) {
      snapshot['preset'] = <String, dynamic>{
        'count': presetCount,
        'expanded': _presetsExpanded,
        'label': l10n.homePagePresetMessagesCount(presetCount),
      };
    }
    final approvalService = context.read<ToolApprovalService>();
    final askUserService = context.read<AskUserInteractionService>();
    for (final message in snapshot['messages'] as List<dynamic>) {
      final map = message as Map<String, dynamic>;
      final tools = map['tools'] as List<dynamic>;
      for (final tool in tools) {
        final toolMap = tool as Map<String, dynamic>;
        final toolId = toolMap['id']?.toString() ?? '';
        final arguments = Map<String, dynamic>.of(
          (toolMap['arguments'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{},
        );
        if (approvalService.isPending(toolId)) {
          arguments['approvalRequired'] = true;
        }
        if (askUserService.isPending(toolId)) {
          arguments['askUserActive'] = true;
        }
        toolMap['arguments'] = arguments;
      }
    }
    return snapshot;
  }

  Map<String, dynamic>? _buildWebStreamingPatch(
    String messageId,
    StreamingContentData data,
    Assistant? assistant,
  ) {
    ChatMessage? message;
    for (final candidate in _controller.chatController.collapsedMessages) {
      if (candidate.id == messageId) {
        message = candidate;
        break;
      }
    }
    if (message == null) return null;
    if (!message.isStreaming) {
      if (data.translation == null) return null;
      return <String, dynamic>{
        'id': messageId,
        'patchKind': 'translation',
        'translation': stripWebChatAttachmentMarkers(data.translation!),
      };
    }
    final visual = messageVisualContent(
      message.copyWith(content: data.content),
      assistant: assistant,
    );
    final reasoning = _webStreamingReasoning(messageId, data);
    final tools = _webStreamingToolParts(messageId);
    return <String, dynamic>{
      'id': messageId,
      'content': stripWebChatAttachmentMarkers(visual),
      'isStreaming': message.isStreaming,
      'tokens': data.totalTokens,
      'reasoning': reasoning,
      'contentSplits': <String, dynamic>{
        'offsets': data.contentSplitOffsets ?? const <int>[],
        'reasoningCounts': data.reasoningCountAtSplit ?? const <int>[],
        'toolCounts': data.toolCountAtSplit ?? const <int>[],
      },
      'tools': tools,
      'translation': data.translation == null
          ? null
          : stripWebChatAttachmentMarkers(data.translation!),
    };
  }

  void _registerWebPatchMedia(
    String messageId,
    Map<String, dynamic> patch,
    Map<String, WebChatMediaSource> registry,
  ) {
    final content = <String>[
      if (patch['content'] case final String value) value,
      if (patch['translation'] case final String value) value,
      for (final reasoning in patch['reasoning'] as List<dynamic>? ?? const [])
        if (reasoning is Map && reasoning['text'] is String)
          reasoning['text'] as String,
      for (final tool in patch['tools'] as List<dynamic>? ?? const [])
        if (tool is Map && tool['content'] is String) tool['content'] as String,
    ];
    final handles = <String, String>{};
    for (final text in content) {
      for (final url in webChatRemoteImageReferences(text)) {
        final handle = webChatRemoteMediaHandle(url);
        registry[handle] = WebChatMediaSource(
          kind: WebChatMediaSourceKind.remoteImage,
          value: url,
          messageIds: <String>{...?registry[handle]?.messageIds, messageId},
        );
        handles[url] = handle;
      }
    }
    if (handles.isNotEmpty) patch['remoteMediaHandles'] = handles;
  }

  List<Map<String, dynamic>> _webStreamingToolParts(String messageId) {
    final approvalService = context.read<ToolApprovalService>();
    final askUserService = context.read<AskUserInteractionService>();
    return (_controller.toolParts[messageId] ?? const <ToolUIPart>[])
        .map((part) {
          final json = part.toJson();
          if (json['content'] case final String content) {
            json['content'] = stripWebChatAttachmentMarkers(content);
          }
          final arguments = Map<String, dynamic>.of(part.arguments);
          if (approvalService.isPending(part.id)) {
            arguments['approvalRequired'] = true;
          }
          if (askUserService.isPending(part.id)) {
            arguments['askUserActive'] = true;
          }
          json['arguments'] = arguments;
          return json;
        })
        .toList(growable: false);
  }

  List<Map<String, dynamic>> _webStreamingReasoning(
    String messageId,
    StreamingContentData data,
  ) {
    final segments = _controller.reasoningSegments[messageId];
    if (segments != null && segments.isNotEmpty) {
      return segments
          .asMap()
          .entries
          .map(
            (entry) => <String, dynamic>{
              'kind': 'segment',
              'index': entry.key,
              'key': '$messageId:reasoning:segment:${entry.key}',
              'text': stripWebChatAttachmentMarkers(entry.value.text),
              'expanded': entry.value.expanded,
              'loading': entry.value.finishedAt == null,
              'startAt': entry.value.startAt?.toIso8601String(),
              'finishedAt': entry.value.finishedAt?.toIso8601String(),
              'toolStartIndex': entry.value.toolStartIndex,
            },
          )
          .toList(growable: false);
    }
    if (data.reasoningText?.isNotEmpty != true) {
      return const <Map<String, dynamic>>[];
    }
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'kind': 'single',
        'index': 0,
        'key': '$messageId:reasoning:single:0',
        'text': stripWebChatAttachmentMarkers(data.reasoningText!),
        'expanded':
            _controller.reasoning[messageId]?.expanded ??
            !context.read<SettingsProvider>().autoCollapseThinking,
        'loading': data.reasoningFinishedAt == null,
        'startAt': data.reasoningStartAt?.toIso8601String(),
        'finishedAt': data.reasoningFinishedAt?.toIso8601String(),
        'toolStartIndex': 0,
      },
    ];
  }

  Future<void> _handleWebChatAction(
    WebChatActionRequest request, {
    required List<ChatMessage> visibleMessages,
    required Map<String, WebChatMediaSource> mediaRegistry,
    required Map<String, WebChatHtmlPreviewSource> htmlPreviewRegistry,
  }) async {
    final message = request.messageId == null
        ? null
        : _findWebActionMessage(request.messageId!, visibleMessages);
    switch (request.action) {
      case 'loadMoreBefore':
        _controller.loadMoreBefore();
        return;
      case 'loadMoreAfter':
        _controller.loadMoreAfter();
        return;
      case 'suggestion':
        await _controller.sendSuggestion(
          request.payload['text']?.toString() ?? '',
        );
        return;
      case 'togglePresets':
        setState(() => _presetsExpanded = !_presetsExpanded);
        return;
      case 'copyText':
        final text = request.payload['text']?.toString() ?? '';
        if (text.length > 1024 * 1024) {
          throw const WebChatProtocolException(
            'copy payload exceeds size limit',
          );
        }
        await Clipboard.setData(ClipboardData(text: text));
        return;
    }
    if (message == null) {
      throw const WebChatProtocolException('message target is not active');
    }
    if (!_webMessageActionAllowed(request.action, message)) {
      throw const WebChatProtocolException('message action is not allowed');
    }
    switch (request.action) {
      case 'copy':
        await Clipboard.setData(
          ClipboardData(text: messageVisualContent(message)),
        );
        return;
      case 'edit':
        await _controller.editMessage(message);
        return;
      case 'resend':
      case 'regenerate':
        await _controller.regenerateAtMessage(message);
        return;
      case 'quote':
        _controller.insertQuote(messageVisualContent(message));
        return;
      case 'translate':
        await _controller.translateMessage(message);
        return;
      case 'speak':
        await _controller.speakMessage(message);
        return;
      case 'more':
        await _showWebMessageMore(message, visibleMessages);
        return;
      case 'share':
      case 'select':
        if (_controller.selecting) {
          _controller.toggleSelection(
            message.id,
            !_controller.selectedItems.contains(message.id),
          );
          return;
        }
        _controller.startMessageSelection(
          messageIndex: visibleMessages.indexOf(message),
          messageList: visibleMessages,
        );
        return;
      case 'fork':
        await _controller.forkConversation(message);
        return;
      case 'delete':
        if (!mounted) return;
        await _handleDeleteMessage(
          context,
          message,
          _controller.chatController.groupedMessages,
        );
        return;
      case 'version':
        final versions = List<ChatMessage>.of(
          _controller.chatController.groupedMessages[message.groupId] ??
              <ChatMessage>[message],
        )..sort((a, b) => a.version.compareTo(b.version));
        final current = versions.indexWhere(
          (item) =>
              item.version ==
              (_controller.versionSelections[message.groupId] ??
                  message.version),
        );
        final delta = (request.payload['delta'] as num?)?.toInt() ?? 0;
        final next = (current + delta).clamp(0, versions.length - 1);
        await _controller.setSelectedVersion(
          message.groupId ?? message.id,
          versions[next].version,
        );
        return;
      case 'previewImage':
        await _previewWebImage(message, request.payload, mediaRegistry);
        return;
      case 'openAttachment':
        await _openWebAttachment(message, request.payload, mediaRegistry);
        return;
      case 'openCitation':
        await _openWebCitation(message, request.payload);
        return;
      case 'showCitations':
        _showWebCitations(message);
        return;
      case 'openHtmlPreview':
        await _openWebHtmlPreview(
          message,
          request.payload,
          htmlPreviewRegistry,
        );
        return;
      case 'setReasoningExpanded':
        final target = WebChatReasoningTarget.fromPayload(request.payload);
        final updated = switch (target.kind) {
          WebChatReasoningKind.single => _controller.setReasoningExpanded(
            message.id,
            target.expanded,
          ),
          WebChatReasoningKind.segment =>
            _controller.setReasoningSegmentExpanded(
              message.id,
              target.index,
              target.expanded,
            ),
        };
        if (!updated) {
          throw const WebChatProtocolException('reasoning target is stale');
        }
        return;
      case 'approveTool':
        if (!mounted) return;
        final toolId = request.payload['toolId']?.toString() ?? '';
        final service = context.read<ToolApprovalService>();
        if (!service.isPending(toolId) ||
            !_webMessageHasTool(message.id, toolId)) {
          throw const WebChatProtocolException('tool approval is stale');
        }
        service.approve(toolId);
        return;
      case 'denyTool':
        if (!mounted) return;
        final toolId = request.payload['toolId']?.toString() ?? '';
        final service = context.read<ToolApprovalService>();
        if (!service.isPending(toolId) ||
            !_webMessageHasTool(message.id, toolId)) {
          throw const WebChatProtocolException('tool approval is stale');
        }
        service.deny(toolId);
        return;
      case 'answerTool':
        _submitWebAskUserAnswer(message, request.payload);
        return;
      case 'multiAI':
        await _startWebMultiAI(message);
        return;
      default:
        throw WebChatProtocolException('unsupported action ${request.action}');
    }
  }

  Future<void> _showWebMessageMore(
    ChatMessage message,
    List<ChatMessage> visibleMessages,
  ) async {
    if (!mounted) return;
    final versions =
        _controller.chatController.groupedMessages[message.groupId] ??
        <ChatMessage>[message];
    final hide = <MessageMoreAction>{};
    if (!_controller.canStartMultiAIComparison) {
      hide.add(MessageMoreAction.multiAI);
    }
    final action = await showMessageMoreSheet(
      context,
      message,
      canDeleteAllVersions: versions.length > 1,
      hideActions: hide,
    );
    if (!mounted || action == null) return;
    switch (action) {
      case MessageMoreAction.deleteCurrentVersion:
        await _handleDeleteMessage(
          context,
          message,
          _controller.chatController.groupedMessages,
        );
        return;
      case MessageMoreAction.deleteAllVersions:
        await _handleDeleteMessage(
          context,
          message,
          _controller.chatController.groupedMessages,
          deleteAllVersions: true,
        );
        return;
      case MessageMoreAction.edit:
        await _controller.editMessage(message);
        return;
      case MessageMoreAction.fork:
        await _controller.forkConversation(message);
        return;
      case MessageMoreAction.selectMessages:
        _controller.startMessageSelection(
          messageIndex: visibleMessages.indexOf(message),
          messageList: visibleMessages,
        );
        return;
      case MessageMoreAction.multiAI:
        await _startWebMultiAI(message);
        return;
      case MessageMoreAction.readingMode:
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ReadingModePage(
              message: message,
              assistantName: context
                  .read<AssistantProvider>()
                  .currentAssistant
                  ?.name,
            ),
          ),
        );
        return;
      case MessageMoreAction.reply:
        _controller.startReplyTo(message);
        return;
    }
  }

  Future<void> _previewWebImage(
    ChatMessage message,
    Map<String, dynamic> payload,
    Map<String, WebChatMediaSource> mediaRegistry,
  ) async {
    final handle = payload['handle']?.toString() ?? '';
    final source = mediaRegistry[handle];
    if (source == null || source.kind == WebChatMediaSourceKind.bundledAsset) {
      throw const WebChatProtocolException('image handle is not active');
    }
    final imageAttachments = parseWebChatAttachments(
      message.content,
    ).where((item) => item['kind'] == 'image').toList(growable: false);
    final allowed =
        imageAttachments.any(
          (item) => _webMediaReferenceMatches(
            item['reference']?.toString(),
            handle,
            source,
          ),
        ) ||
        source.messageIds.contains(message.id);
    if (!allowed) {
      throw const WebChatProtocolException('image handle is not in message');
    }
    final images = <String>[
      for (final attachment in imageAttachments)
        if (_resolveWebMediaValue(
              attachment['reference']?.toString(),
              mediaRegistry,
            )
            case final value?)
          value,
    ];
    if (!images.contains(source.value)) images.add(source.value);
    if (!mounted || images.isEmpty) return;
    final initialIndex = images
        .indexOf(source.value)
        .clamp(0, images.length - 1);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            ImageViewerPage(images: images, initialIndex: initialIndex),
      ),
    );
  }

  Future<void> _openWebAttachment(
    ChatMessage message,
    Map<String, dynamic> payload,
    Map<String, WebChatMediaSource> mediaRegistry,
  ) async {
    final handle = payload['handle']?.toString() ?? '';
    final source = mediaRegistry[handle];
    if (source == null || source.kind != WebChatMediaSourceKind.localFile) {
      throw const WebChatProtocolException('file handle is not active');
    }
    Map<String, dynamic>? attachment;
    for (final candidate in parseWebChatAttachments(message.content)) {
      if (candidate['kind'] == 'file' &&
          _webMediaReferenceMatches(
            candidate['reference']?.toString(),
            handle,
            source,
          )) {
        attachment = candidate;
        break;
      }
    }
    if (attachment == null) {
      throw const WebChatProtocolException('file handle is not in message');
    }
    final l10n = AppLocalizations.of(context)!;
    final name = attachment['name']?.toString() ?? '';
    try {
      final path = SandboxPathResolver.fix(source.value);
      final file = File(path);
      if (!await file.exists()) {
        if (!mounted) return;
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetFileNotFound(name),
          type: NotificationType.error,
        );
        return;
      }
      final result = await OpenFilex.open(
        path,
        type: attachment['mime']?.toString(),
      );
      if (result.type != ResultType.done && mounted) {
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetCannotOpenFile(
            result.message.isNotEmpty ? result.message : result.type.toString(),
          ),
          type: NotificationType.error,
        );
      }
    } catch (error) {
      debugPrint('HomePage: Web attachment open failed ($error)');
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.chatMessageWidgetOpenFileError(error.toString()),
        type: NotificationType.error,
      );
    }
  }

  bool _webMediaReferenceMatches(
    String? reference,
    String handle,
    WebChatMediaSource source,
  ) => reference == handle || reference == source.value;

  String? _resolveWebMediaValue(
    String? reference,
    Map<String, WebChatMediaSource> registry,
  ) {
    if (reference == null || reference.isEmpty) return null;
    final direct = registry[reference];
    if (direct != null) return direct.value;
    for (final source in registry.values) {
      if (source.value == reference) return source.value;
    }
    if (reference.startsWith('https://')) return reference;
    return null;
  }

  Future<void> _openWebCitation(
    ChatMessage message,
    Map<String, dynamic> payload,
  ) async {
    final citationId = payload['citationId']?.toString() ?? '';
    final requestedIndex = payload['index']?.toString() ?? '';
    final sources = buildWebChatCitationSources(
      _controller.toolParts[message.id] ?? const <ToolUIPart>[],
    );
    Map<String, dynamic>? match;
    for (final source in sources) {
      if ((source['id']?.toString() ?? '') == citationId) {
        match = source;
        break;
      }
    }
    final fallbackIndex = int.tryParse(
      citationId.isEmpty ? requestedIndex : citationId.trim(),
    );
    if (match == null && fallbackIndex != null) {
      for (final source in sources) {
        if (source['index']?.toString() == fallbackIndex.toString()) {
          match = source;
          break;
        }
      }
    }
    var url = match?['url']?.toString() ?? '';
    if (url.isEmpty && (citationId.contains('/') || citationId.contains('.'))) {
      url = citationId;
    }
    if (url.isEmpty) {
      if (mounted) {
        showAppSnackBar(
          context,
          message: AppLocalizations.of(
            context,
          )!.chatMessageWidgetCitationNotFound,
          type: NotificationType.warning,
        );
      }
      return;
    }
    await _openWebCitationUrl(url);
  }

  void _showWebCitations(ChatMessage message) {
    final items = buildWebChatCitationSources(
      _controller.toolParts[message.id] ?? const <ToolUIPart>[],
    );
    if (items.isEmpty || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final sources = <CitationSourceItem>[
      for (var index = 0; index < items.length; index++)
        CitationSourceItem.fromMap(items[index], fallbackIndex: index + 1),
    ];
    unawaited(
      showCitationSourcesBottomSheet(
        context: context,
        title: l10n.chatMessageWidgetSearchResultsTitle,
        closeSemanticLabel: l10n.mcpPageClose,
        items: sources,
        onOpen: (item) => unawaited(_openWebCitationUrl(item.url)),
      ),
    );
  }

  Future<void> _openWebCitationUrl(String raw) async {
    final l10n = AppLocalizations.of(context)!;
    var value = raw.trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1).trim();
    }
    if (value.startsWith('//')) {
      value = 'https:$value';
    } else if (!RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:').hasMatch(value)) {
      value = 'https://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      if (mounted) {
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetOpenLinkError,
          type: NotificationType.error,
        );
      }
      return;
    }
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetCannotOpenUrl(uri.toString()),
          type: NotificationType.error,
        );
      }
    } catch (error) {
      debugPrint('HomePage: Web citation open failed ($error)');
      if (mounted) {
        showAppSnackBar(
          context,
          message: l10n.chatMessageWidgetOpenLinkError,
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _startWebMultiAI(ChatMessage message) async {
    if (!await _confirmWebMultiAIFallback() || !mounted) return;
    final conversationId =
        _controller.currentConversation?.id ?? message.conversationId;
    setState(() {
      _webFlutterConversationOverrides.add(conversationId);
    });
    await _controller.handleMultiAIAction(message);
  }

  Future<void> _openWebHtmlPreview(
    ChatMessage message,
    Map<String, dynamic> payload,
    Map<String, WebChatHtmlPreviewSource> registry,
  ) async {
    final registered = resolveWebChatHtmlPreviewSource(
      messageId: message.id,
      rawSource: payload['source'],
      registry: registry,
    );
    if (!mounted) return;
    if (Platform.isAndroid || Platform.isIOS) {
      await Navigator.of(context).push<void>(
        PageRouteBuilder<void>(
          pageBuilder: (_, _, _) =>
              HtmlPreviewPage(html: registered.source, isolated: true),
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 240),
          transitionsBuilder: (context, animation, _, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return FadeTransition(opacity: curved, child: child);
          },
        ),
      );
      return;
    }
    if (Platform.isMacOS || Platform.isWindows) {
      await showHtmlPreviewDesktopDialog(
        context,
        html: registered.source,
        isolated: true,
      );
      return;
    }
    throw const WebChatProtocolException(
      'HTML preview is unsupported on this platform',
    );
  }

  ChatMessage? _findWebActionMessage(
    String messageId,
    List<ChatMessage> visibleMessages,
  ) {
    for (final message in visibleMessages) {
      if (message.id == messageId) return message;
    }
    return null;
  }

  bool _webMessageActionAllowed(String action, ChatMessage message) {
    if (message.isStreaming &&
        const <String>{
          'copy',
          'more',
          'regenerate',
          'translate',
          'speak',
        }.contains(action)) {
      return false;
    }
    const common = <String>{
      'copy',
      'more',
      'quote',
      'share',
      'fork',
      'select',
      'delete',
      'version',
      'previewImage',
      'openAttachment',
      'openCitation',
      'showCitations',
      'openHtmlPreview',
    };
    if (common.contains(action)) return true;
    if (action == 'edit' || action == 'resend') return message.role == 'user';
    const assistantOnly = <String>{
      'regenerate',
      'translate',
      'speak',
      'setReasoningExpanded',
      'approveTool',
      'denyTool',
      'answerTool',
    };
    if (assistantOnly.contains(action)) return message.role == 'assistant';
    if (action == 'multiAI') {
      return message.role == 'assistant' &&
          _controller.canStartMultiAIComparison;
    }
    return false;
  }

  bool _webMessageHasTool(String messageId, String toolId) {
    return (_controller.toolParts[messageId] ?? const []).any(
      (part) => part.id == toolId,
    );
  }

  void _submitWebAskUserAnswer(
    ChatMessage message,
    Map<String, dynamic> payload,
  ) {
    final toolId = payload['toolId']?.toString() ?? '';
    final service = context.read<AskUserInteractionService>();
    final request = service.pendingRequests[toolId];
    if (request == null || !_webMessageHasTool(message.id, toolId)) {
      throw const WebChatProtocolException(
        'ask user request is no longer active',
      );
    }
    final rawAnswers = payload['answers'] is Map
        ? (payload['answers'] as Map).map(
            (key, value) => MapEntry(
              key.toString(),
              value is List
                  ? value.map((item) => item.toString()).toList()
                  : <String>[value.toString()],
            ),
          )
        : const <String, List<String>>{};
    final skipped = (payload['skipped'] as List? ?? const <dynamic>[])
        .map((value) => value.toString())
        .toSet();
    final custom = (payload['custom'] as List? ?? const <dynamic>[])
        .map((value) => value.toString())
        .toSet();
    final answers = <String, AskUserAnswerValue>{};
    for (final question in request.questions) {
      if (skipped.contains(question.id)) {
        answers[question.id] = AskUserAnswerValue.skipped(kind: question.kind);
        continue;
      }
      final values = rawAnswers[question.id] ?? const <String>[];
      if (values.isEmpty ||
          values.length > 50 ||
          values.any((value) => value.trim().isEmpty || value.length > 4000) ||
          (question.kind == AskUserQuestionKind.single && values.length != 1) ||
          (!custom.contains(question.id) &&
              question.options.isNotEmpty &&
              values.any((value) => !question.options.contains(value)))) {
        throw const WebChatProtocolException('invalid ask user answer');
      }
      answers[question.id] = question.kind == AskUserQuestionKind.multi
          ? AskUserAnswerValue.multi(
              value: values,
              custom: custom.contains(question.id),
            )
          : AskUserAnswerValue.single(
              value: values.isEmpty ? '' : values.first,
              custom: custom.contains(question.id),
            );
    }
    service.answer(toolId, answers);
  }

  void _scheduleMultiAIFallbackPrompt(String conversationId) {
    if (!_webMultiAIPromptedConversations.add(conversationId)) return;
    _webFlutterConversationOverrides.add(conversationId);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _showWebMultiAIFallbackNotice();
      if (mounted) setState(() {});
    });
  }

  Future<void> _showWebMultiAIFallbackNotice() async {
    final l10n = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(l10n.webChatMultiAIFallbackNoticeTitle),
          content: Text(l10n.webChatMultiAIFallbackNoticeBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.webChatMultiAIFallbackNoticeAcknowledge),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmWebMultiAIFallback() async {
    final l10n = AppLocalizations.of(context)!;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(l10n.webChatMultiAIFallbackTitle),
            content: Text(l10n.webChatMultiAIFallbackBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.homePageCancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(l10n.webChatMultiAIFallbackConfirm),
              ),
            ],
          ),
        ) ??
        false;
  }

  Widget _buildChatInputBar(BuildContext context, {required bool isTablet}) {
    return ChatInputSection(
      inputBarKey: _inputBarKey,
      inputFocus: _inputFocus,
      inputController: _inputController,
      mediaController: _mediaController,
      imageGenController: _imageGenController,
      livePanel: LivePanel(
        onOpenChild: (childId) =>
            _controller.switchConversationAnimated(childId),
        imageGenController: _imageGenController,
      ),
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
      onSelectModel: () => showModelSelectSheet(
        context,
        onMultiSelectConfirm:
            _controller.multiAIEngine.mode == MultiAIMode.synthesize
            ? null
            : _controller.enterMultiAIMode,
      ),
      onLongPressSelectModel: () {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const ProvidersPage()));
      },
      onOpenToolsHub: () {
        final a = context.read<AssistantProvider>().currentAssistant;
        if (a != null) {
          if (PlatformUtils.isDesktop) {
            showDesktopToolsHubPopover(
              context,
              anchorKey: _inputBarKey,
              assistantId: a.id,
              conversationId: _controller.currentConversation?.id,
            );
          } else {
            showToolsHubSheet(
              context,
              assistantId: a.id,
              conversationId: _controller.currentConversation?.id,
            );
          }
        }
      },
      onLongPressMcp: () {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const McpPage()));
      },
      onOpenSearch: _openSearchSettings,
      onConfigureReasoning: () => _configureReasoning(),
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
      onCancelQueuedInput: _controller.cancelQueuedMessage,
      onQuickPhrase: _showQuickPhraseMenu,
      onLongPressQuickPhrase: () {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const QuickPhrasesPage()));
      },
      onDocumentProcessing: () => _openDocumentProcessingPopover(),
      onOpenMiniMap: _openMiniMap,
      onPickCamera: _controller.onPickCamera,
      onPickPhotos: _controller.onPickPhotos,
      onUploadFiles: _controller.onPickFiles,
      onToggleLearningMode: _openInstructionInjectionPopover,
      onOpenWorldBook: _openWorldBookPopover,
      onOpenSkills: _openSkillsPopover,
      onLongPressLearning: _showLearningPromptSheet,
      onClearContext: _controller.clearContext,
      onCompressContext: _handleDesktopCompressContext,
      backgroundImageActive: _assistantBackgroundActive(context),
      multiAIModelCount:
          _controller.multiAIEngine.isActive &&
              _controller.multiAIEngine.mode == MultiAIMode.continue_
          ? _controller.multiAIEngine.models.length
          : null,
      onMultiSelectModel: () {
        final engine = _controller.multiAIEngine;
        if (engine.roundCount == 0) {
          _controller.editMultiAIModels();
        }
      },
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
          onScrollToTop: _controller.scrollToTop,
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
        UserMessageEditOverlay(
          visible: editState != null && !_controller.selecting,
          previewText: editState?.previewText ?? '',
          topInset: _chatTopOverlayInset(context),
          bottomInset: _controller.inputBarHeight,
          onCancel: _controller.cancelUserMessageEdit,
          onSaveOnly: () {
            unawaited(_controller.saveUserMessageEditOnly());
          },
          onPreviewTap: _controller.focusUserMessageEditInput,
        ),
      ],
    );
  }

  Future<void> _openMiniMap() async {
    final collapsed = _controller.allCollapsedMessagesForCurrentConversation();
    if (collapsed.isEmpty) return;

    String? selectedId;
    if (PlatformUtils.isDesktop) {
      selectedId = await showDesktopMiniMapPopover(
        context,
        anchorKey: _inputBarKey,
        messages: collapsed,
      );
    } else {
      selectedId = await showMiniMapSheet(context, collapsed);
    }
    if (!mounted) return;
    if (selectedId != null && selectedId.isNotEmpty) {
      await _controller.scrollToMessageId(selectedId);
    }
  }

  Widget _wrapWithDropTarget(Widget child) {
    if (!_controller.isDesktopPlatform) return child;
    return DropTarget(
      onDragEntered: (_) {
        _controller.setDragHovering(true);
      },
      onDragExited: (_) {
        _controller.setDragHovering(false);
      },
      onDragDone: (details) async {
        _controller.setDragHovering(false);
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
                color: Colors.black.withValues(alpha: 0.12),
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

  void _openSearchSettings() {
    if (PlatformUtils.isDesktop) {
      showDesktopSearchProviderPopover(context, anchorKey: _inputBarKey);
    } else {
      showSearchSettingsSheet(context);
    }
  }

  Future<void> _configureReasoning() async {
    final assistantProvider = context.read<AssistantProvider>();
    final settingsProvider = context.read<SettingsProvider>();
    final assistant = assistantProvider.currentAssistant;
    if (assistant == null) return;
    if (assistant.thinkingBudget != null) {
      settingsProvider.setThinkingBudget(assistant.thinkingBudget);
    }
    await _openReasoningSettings();
    if (!mounted) return;
    final chosen = settingsProvider.thinkingBudget;
    await assistantProvider.updateAssistant(
      assistant.copyWith(thinkingBudget: chosen),
    );
  }

  Future<void> _openReasoningSettings() async {
    if (PlatformUtils.isDesktop) {
      await showDesktopReasoningBudgetPopover(context, anchorKey: _inputBarKey);
    } else {
      await showReasoningBudgetSheet(context);
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

    if (isDesktop) {
      await showDesktopInstructionInjectionPopover(
        context,
        anchorKey: _inputBarKey,
        items: items,
        assistantId: assistantId,
      );
    } else {
      await showInstructionInjectionSheet(context, assistantId: assistantId);
    }
  }

  Future<void> _openSkillsPopover() async {
    final isDesktop = PlatformUtils.isDesktop;
    final assistantId = context.read<AssistantProvider>().currentAssistantId;
    final skills = await SkillManager.listSkills();
    if (!mounted) return;

    if (isDesktop) {
      await showDesktopSkillsPopover(
        context,
        anchorKey: _inputBarKey,
        skills: skills,
        assistantId: assistantId,
        onManageSkills: () {
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const SkillsPage()));
        },
      );
    } else {
      await showSkillsSheet(context, assistantId: assistantId);
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

    if (isDesktop) {
      await showDesktopWorldBookPopover(
        context,
        anchorKey: _inputBarKey,
        books: books,
        assistantId: assistantId,
      );
    } else {
      await showWorldBookSheet(context, assistantId: assistantId);
    }
  }

  Future<void> _openDocumentProcessingPopover() async {
    final isDesktop = PlatformUtils.isDesktop;
    final assistantId = context.read<AssistantProvider>().currentAssistantId;

    if (isDesktop) {
      await showDesktopDocumentProcessingPopover(
        context,
        anchorKey: _inputBarKey,
        assistantId: assistantId,
      );
    } else {
      await showDocumentProcessingSheet(context, assistantId: assistantId);
    }
  }

  Future<void> _showLearningPromptSheet() async {
    await showLearningPromptSheet(context);
  }

  void _toggleTools() async {
    _controller.dismissKeyboard();
    final cs = Theme.of(context).colorScheme;
    final assistantId = context.read<AssistantProvider>().currentAssistantId;
    final settings = context.read<SettingsProvider>();
    final ap = context.read<AssistantProvider>();
    final a = ap.currentAssistant;
    final layout = resolveInputBarButtonLayout(
      savedOrder: settings.chatInputButtonOrder,
      savedMoreIds: settings.chatInputMoreButtonIds,
      tabletLayout: false,
    );
    // Phone bucket = configured in-more ids (in config order) + row overflow.
    final bucket = <String>[
      for (final id in layout.orderedIds)
        if (layout.moreIds.contains(id)) id,
      ..._mediaController.nonFittedDirectIds,
    ];
    // Capability gates mirror ChatInputSection: rows are only offered when
    // the current model/assistant actually supports them.
    final modelIds = getActiveModelIds(settings, assistant: a);
    final pk = modelIds.providerKey;
    final mid = modelIds.modelId;
    final supportsReasoning = pk != null && mid != null;
    final toolsGate = _toolsHubAvailable(pk, mid);
    final quickPhraseGate = _hasQuickPhrases(a);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: BottomToolsSheet(
            moreIds: bucket,
            onCustomize: () {
              Navigator.of(ctx).maybePop();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const InputBarButtonsCustomizationPage(),
                ),
              );
            },
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
            onDocumentProcessing: () {
              Navigator.of(ctx).maybePop();
              _openDocumentProcessingPopover();
            },
            onOpenSkills: () {
              Navigator.of(ctx).maybePop();
              _openSkillsPopover();
            },
            onSelectModel: () async {
              Navigator.of(ctx).maybePop();
              showModelSelectSheet(
                context,
                onMultiSelectConfirm:
                    _controller.multiAIEngine.mode == MultiAIMode.synthesize
                    ? null
                    : _controller.enterMultiAIMode,
              );
            },
            onOpenSearch: () {
              Navigator.of(ctx).maybePop();
              _openSearchSettings();
            },
            onConfigureReasoning: !supportsReasoning
                ? null
                : () async {
                    Navigator.of(ctx).maybePop();
                    await _configureReasoning();
                  },
            onQuickPhrase: !quickPhraseGate
                ? null
                : () {
                    Navigator.of(ctx).maybePop();
                    _showQuickPhraseMenu();
                  },
            onOpenToolsHub: !toolsGate
                ? null
                : () {
                    Navigator.of(ctx).maybePop();
                    if (a != null) {
                      showToolsHubSheet(
                        context,
                        assistantId: a.id,
                        conversationId: _controller.currentConversation?.id,
                      );
                    }
                  },
          ),
        );
      },
    );
  }

  bool _toolsHubAvailable(String? pk, String? mid) {
    if (pk == null || mid == null) return false;
    return _controller.isToolModel(pk, mid);
  }

  bool _hasQuickPhrases(Assistant? a) {
    final quickPhraseProvider = context.read<QuickPhraseProvider>();
    if (quickPhraseProvider.globalPhrases.isNotEmpty) return true;
    if (a == null) return false;
    return quickPhraseProvider.getForAssistant(a.id).isNotEmpty;
  }

  void _showContextManagementSheet() async {
    final cs = Theme.of(context).colorScheme;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: ContextManagementSheet(
            clearLabel: _controller.clearContextLabel(),
            onCompress: () async {
              await Navigator.of(ctx).maybePop();
              if (!mounted) return;
              await _showCompressContextOptions();
            },
            onClear: () async {
              Navigator.of(ctx).maybePop();
              await _controller.clearContext();
            },
          ),
        );
      },
    );
  }

  void _handleDesktopCompressContext() async {
    await _showCompressContextOptions();
  }

  Future<void> _showCompressContextOptions() async {
    final allMsgs = _controller.allMessagesForCurrentConversationContext();
    final collapsed = _controller.collapseVersions(allMsgs);
    final options = await showDialog<CompressContextOptions>(
      context: context,
      barrierDismissible: true,
      builder: (_) =>
          _CompressContextOptionsDialog(collapsedMessages: collapsed),
    );
    if (options == null || !mounted) return;

    final l10n = AppLocalizations.of(context)!;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => LoadingDialogCard(label: l10n.compressingContext),
      ),
    );

    String? error;
    try {
      error = await _controller.compressContext(options: options);
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).maybePop();
      }
    }
    if (error != null && mounted) {
      showAppSnackBar(
        context,
        message: _compressContextErrorMessage(l10n, error),
        type: NotificationType.error,
        duration: const Duration(seconds: 6),
      );
    }
  }

  Future<void> _showQuickPhraseMenu() async {
    final assistant = context.read<AssistantProvider>().currentAssistant;
    final quickPhraseProvider = context.read<QuickPhraseProvider>();
    final globalPhrases = quickPhraseProvider.globalPhrases;
    final assistantPhrases = assistant != null
        ? quickPhraseProvider.getForAssistant(assistant.id)
        : <QuickPhrase>[];

    final allAvailable = [...globalPhrases, ...assistantPhrases];
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

  Future<void> _handleDeleteMessage(
    BuildContext context,
    ChatMessage message,
    Map<String, List<ChatMessage>> byGroup, {
    bool deleteAllVersions = false,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          deleteAllVersions
              ? l10n.homePageDeleteAllVersions
              : l10n.homePageDeleteMessage,
        ),
        content: Text(
          deleteAllVersions
              ? l10n.homePageDeleteAllVersionsConfirm
              : l10n.homePageDeleteMessageConfirm,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.homePageCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.homePageDelete, style: TextStyle(color: cs.error)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    if (deleteAllVersions) {
      await _controller.deleteAllMessageVersions(
        message: message,
        byGroup: byGroup,
      );
      return;
    }

    await _controller.deleteMessage(message: message, byGroup: byGroup);
  }

  Future<void> _handleDeleteSelectedMessages(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    if (_controller.selectedItems.isEmpty) {
      showAppSnackBar(
        context,
        message: l10n.chatSelectionSelectMessagesToDelete,
        type: NotificationType.info,
      );
      return;
    }

    final count = _controller.selectedItems.length;
    final deleteAllVersions = await showChatSelectionDeleteDialog(
      context,
      count: count,
      hasMultiVersionSelection:
          _controller.selectedMessagesIncludeMultipleVersions,
    );
    if (deleteAllVersions == null) return;

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
