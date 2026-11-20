import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/harness/controllers/dsh_chat_controllers_provider.dart';
import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/harness/controllers/dsh_composer_e2e.dart';
import 'package:Cuplivo/features/harness/controllers/dsh_composer_submission.dart';
import 'package:Cuplivo/features/harness/controllers/dsh_transcript_fold.dart';
import 'package:Cuplivo/features/harness/services/dsh_attachment_upload_service.dart';
import 'package:Cuplivo/features/harness/services/dsh_context_usage.dart';
import 'package:Cuplivo/features/harness/state/dsh_gateway.dart'
    show DshGatewayException;
import 'package:Cuplivo/features/harness/models/dsh_remote.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_approval_cards.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_agent_preset_picker.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_context_usage_sheet.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_model_picker.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_permission_picker.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_plus_sheet.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_reasoning_picker.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_slash_commands_sheet.dart';
import 'package:Cuplivo/features/harness/widgets/dsh_whale_mark.dart';
import 'package:Cuplivo/features/home/services/file_upload_service.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/features/home/widgets/message_list_view.dart';
import 'package:Cuplivo/features/home/widgets/model_icon.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/action_sheet.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// The remote-chat half of a Cuplivo ⇄ DeepSeek Harness session.
///
/// The host (home slice) embeds this view where a local conversation would be:
/// it fills its parent, renders no app bar, and resolves its controller from
/// (remote, sessionId) through [DshChatControllersProvider] — the app bar and
/// the chat therefore read the same [DshChatViewState].
///
/// Rendering is Cuplivo's own: [MessageListView]/[ChatMessageWidget] consume the
/// folded transcript, so markdown, code blocks, thinking cards, tool cards and
/// every appearance setting behave exactly as they do for local chats.
class HarnessConversationView extends StatefulWidget {
  const HarnessConversationView({
    super.key,
    required this.remote,
    required this.sessionId,
    this.onRequestModelPicker,
    this.onOpenWorkspace,
    this.onOpenRightRail,
    this.onOpenAssistantSettings,
  });

  final DshRemote remote;
  final String sessionId;

  /// Lets the host own the model picker presentation (its app-bar capsule and
  /// this composer's pill then open the same surface). When null the composer
  /// opens the picker itself.
  final VoidCallback? onRequestModelPicker;

  /// Host entry point retained for the app-bar/drawer chrome. The v2 plus menu
  /// mirrors the remote composer's 添加/指令 structure, which has no workspace
  /// row; the host's own surfaces still pass these through.
  final VoidCallback? onOpenWorkspace;

  /// Host entry point retained for the app-bar/drawer chrome (no v2 plus row).
  final VoidCallback? onOpenRightRail;

  /// Host entry point retained for the app-bar/drawer chrome (no v2 plus row).
  final VoidCallback? onOpenAssistantSettings;

  @override
  State<HarnessConversationView> createState() =>
      _HarnessConversationViewState();
}

class _HarnessConversationViewState extends State<HarnessConversationView> {
  final ScrollController _scrollController = ScrollController();
  final ListController _listController = ListController();
  final TextEditingController _draftController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ValueNotifier<String?> _processingFiles = ValueNotifier<String?>(null);
  final GlobalKey _composerBarKey = GlobalKey();
  final ChatInputBarController _mediaController = ChatInputBarController();
  FileUploadService? _fileUploadService;
  bool _slashMenuOpen = false;

  DshChatControllersProvider? _provider;
  DshChatSession? _session;
  bool _creatingSession = false;

  /// The owner identity the transcript rows render with. A harness owner is a
  /// remote, not a local assistant, so its replies must not fall back to the
  /// local "assistant" name/robot icon: the row carries the remote's display
  /// name and the DSH whale mark, matching the drawer's owner row. Cached so
  /// [MessageListView]'s identity guard does not invalidate every extent on
  /// each rebuild.
  Assistant? _ownerAssistant;

  @override
  void initState() {
    super.initState();
    _draftController.addListener(_onDraftChanged);
    DshComposerE2e.attach(_stageAttachmentsFromE2e);
  }

  /// Integration-test seam: stages picker-equivalent attachments into the
  /// composer so the upload/prompt/transcript path can be driven without a
  /// native dialog. See [DshComposerE2e].
  void _stageAttachmentsFromE2e(
    List<String> images,
    List<DocumentAttachment> documents,
  ) {
    if (!mounted) return;
    if (images.isNotEmpty) {
      _mediaController.enqueueImages(
        images,
        context.read<SettingsProvider>().resolveImageCompressConfig(),
      );
    }
    if (documents.isNotEmpty) _mediaController.addFiles(documents);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureFileUploadService();
    _resolveSession();
  }

  /// The native picker pipeline is shared with local chats: it stages images
  /// and documents into the composer controller, and the send path turns them
  /// into DSH prompt parts. Built once because it captures the app settings.
  void _ensureFileUploadService() {
    if (_fileUploadService != null) return;
    _fileUploadService = FileUploadService(
      getContext: () => context,
      mediaController: _mediaController,
      isImageCropperEnabled: () =>
          context.read<SettingsProvider>().imageCropperEnabled,
      getImageCompressConfig: () =>
          context.read<SettingsProvider>().resolveImageCompressConfig(),
      hasWorkspace: () => false,
    );
  }

  @override
  void didUpdateWidget(covariant HarnessConversationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.remote.id != widget.remote.id) {
      _draftController.clear();
      _resolveSession();
    }
  }

  /// Resolves (and, when absent, requests creation of) this session's
  /// controller.
  ///
  /// Creation is deferred to the next frame when the provider has not seen this
  /// session yet: `sessionFor` notifies the provider, and notifying during
  /// build would rebuild another listener mid-build (the host's app bar watches
  /// the same provider).
  Assistant _ownerAssistantFor() {
    final name = widget.remote.name.trim();
    final displayName = name.isEmpty ? 'DeepSeek Harness' : name;
    final id = 'dsh-owner:${widget.remote.id}';
    final cached = _ownerAssistant;
    if (cached != null && cached.id == id && cached.name == displayName) {
      return cached;
    }
    return _ownerAssistant = Assistant(
      id: id,
      name: displayName,
      avatar: DshWhaleMark.assetPath,
      useAssistantAvatar: true,
      useAssistantName: true,
    );
  }

  void _resolveSession() {
    DshChatControllersProvider? provider;
    try {
      provider = context.read<DshChatControllersProvider>();
    } catch (_) {
      provider = null;
    }
    if (provider == null) {
      _provider = null;
      _detach();
      return;
    }
    _provider = provider;
    final existing = provider.peek(widget.remote, widget.sessionId);
    if (existing != null) {
      _attach(existing);
      return;
    }
    _detach();
    if (_creatingSession) return;
    _creatingSession = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _creatingSession = false;
      if (!mounted) return;
      final created = provider!.sessionFor(widget.remote, widget.sessionId);
      if (!mounted) return;
      setState(() => _attach(created));
    });
  }

  void _attach(DshChatSession session) {
    if (identical(_session, session)) return;
    _session?.removeListener(_handleSessionChanged);
    _session = session;
    session.addListener(_handleSessionChanged);
  }

  void _detach() {
    _session?.removeListener(_handleSessionChanged);
    _session = null;
  }

  void _handleSessionChanged() {
    if (!mounted) return;
    setState(() {});
    _followBottomIfAtBottom();
  }

  bool get _nearBottom {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels < 160;
  }

  void _followBottomIfAtBottom() {
    final follow = _nearBottom;
    if (!follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (position.maxScrollExtent <= 0) return;
      if (position.maxScrollExtent - position.pixels < 1) return;
      _scrollController.jumpTo(position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _draftController.removeListener(_onDraftChanged);
    DshComposerE2e.detach();
    _detach();
    _scrollController.dispose();
    _listController.dispose();
    _draftController.dispose();
    _focusNode.dispose();
    _processingFiles.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session == null) {
      return _DshConversationPlaceholder(
        message: _provider == null
            ? AppLocalizations.of(context)!.dshControllerUnavailable
            : null,
      );
    }
    final state = session.state;
    final settings = context.watch<SettingsProvider>();
    final l10n = AppLocalizations.of(context)!;
    final folded = foldDshTranscript(
      conversationId: 'dsh:${widget.remote.id}:${widget.sessionId}',
      state: state,
    );
    final grouping = groupDshTranscript(folded.messages);
    final model = state.currentModel;
    final effort = state.currentReasoningEffort;
    final permissions = state.permissions;
    final agentPresets = state.agentPresets;
    final notice = folded.notices.isEmpty ? null : folded.notices.last;
    final contextUsage = dshContextUsageSnapshot(
      pressure: state.contextPressure,
      remoteId: widget.remote.id,
      sessionId: widget.sessionId,
      providerKey: state.modelSelection?.providerId,
      modelId: state.modelSelection?.modelId ?? state.currentModel?.id,
    );

    // Both home scaffolds mount the harness body as the `Scaffold.body` of a
    // scaffold with `extendBodyBehindAppBar: true`, so the transcript has to
    // clear the chrome app bar itself (the local chat body receives the same
    // inset from the page).
    final transcriptTopPadding =
        MediaQuery.paddingOf(context).top + kToolbarHeight + 12;

    // This view is the host's full-height body, but a Column hands its non-flex
    // children unbounded height — `ChatInputBar`'s expanding composer asserts on
    // exactly that. Bound the composer (and the pending-request stack) to a
    // share of the host height instead of using Expanded/Flexible, which would
    // take transcript space away permanently; the local home page bounds the
    // same bar the same way through its overlay slot.
    return LayoutBuilder(
      builder: (context, constraints) {
        final composerMaxHeight = constraints.maxHeight * 0.55;
        final pendingMaxHeight = constraints.maxHeight * 0.30;
        return Column(
          children: [
            Expanded(
              child: KeyedSubtree(
                key: const ValueKey<String>('dsh-transcript'),
                child: folded.messages.isEmpty
                    ? _DshEmptyTranscript(
                        title: l10n.dshChatEmptyTitle,
                        body: l10n.dshChatEmptyBody,
                        busy: state.busy,
                      )
                    : MessageListView(
                        key: const ValueKey<String>('dsh-transcript-list'),
                        scrollController: _scrollController,
                        listController: _listController,
                        messages: folded.messages,
                        byGroup: grouping.byGroup,
                        versionSelections: grouping.versionSelections,
                        reasoning: folded.reasoning,
                        reasoningSegments: folded.reasoningSegments,
                        contentSplits: folded.contentSplits,
                        toolParts: folded.toolParts,
                        translations: const {},
                        assistant: _ownerAssistantFor(),
                        selecting: false,
                        selectedItems: const <String>{},
                        dividerPadding: EdgeInsets.zero,
                        topContentPadding: transcriptTopPadding,
                        bottomContentPadding: 12,
                        processingFilesMessageId: _processingFiles,
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
                        wrapCodeBlocks:
                            Platform.isMacOS ||
                            Platform.isWindows ||
                            Platform.isLinux ||
                            settings.mobileCodeBlockWrap,
                        showModelIcon: settings.showModelIcon,
                        showUserAvatar: settings.showUserAvatar,
                        showTokenStats: settings.showTokenStats,
                      ),
              ),
            ),
            _buildStatusBanners(context, state, notice),
            if (state.approvals.isNotEmpty || state.questions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: pendingMaxHeight),
                  child: SingleChildScrollView(
                    child: DshPendingRequestPanel(
                      approvals: state.approvals,
                      questions: state.questions,
                      onAnswerApproval: (approval, allow) =>
                          unawaited(_answerApproval(approval, allow)),
                      onAnswerQuestions: (request, answers) =>
                          unawaited(_answerQuestions(request, answers)),
                      onRejectQuestions: (request) =>
                          unawaited(_rejectQuestions(request)),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Row(
                children: [
                  if (agentPresets != null)
                    DshAgentPresetChip(
                      agentPresets: agentPresets,
                      onTap: () => unawaited(_openAgentPresetPicker()),
                    ),
                  if (agentPresets != null && permissions != null)
                    const SizedBox(width: 8),
                  if (permissions != null)
                    DshPermissionChip(
                      permissions: permissions,
                      enabled: !state.isSending,
                      onTap: () => unawaited(_openPermissionPicker()),
                    ),
                  const Spacer(),
                  if (state.queuedPromptCount > 0)
                    _DshQueuePill(count: state.queuedPromptCount),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: composerMaxHeight),
              child: ChatInputBar(
                key: _composerBarKey,
                composerFieldKey: const Key('dsh-composer'),
                sendButtonKey: const Key('dsh-send'),
                controller: _draftController,
                mediaController: _mediaController,
                focusNode: _focusNode,
                conversationId: null,
                contextUsageOverride: contextUsage,
                onOpenContextUsage: contextUsage == null
                    ? null
                    : () => unawaited(
                        showDshContextUsageSheet(
                          context,
                          snapshot: contextUsage,
                        ),
                      ),
                onPickCamera: _fileUploadService == null
                    ? null
                    : () => unawaited(_pickCamera()),
                onPickPhotos: _fileUploadService == null
                    ? null
                    : () => unawaited(_pickImages()),
                onUploadFiles: _fileUploadService == null
                    ? null
                    : () => unawaited(_pickFiles()),
                // The remote model is not a local provider: passing its ids would
                // make ChatInputBar resolve Cuplivo's own provider config (image
                // routing, local tools) for a model it does not own. The pill and the
                // reasoning button carry the remote state explicitly instead.
                leading: _DshComposerModelPill(
                  model: model,
                  selection: state.modelSelection,
                  fallbackLabel: l10n.dshModelPickerTitle,
                ),
                leadingExtent: _leadingExtent(model?.displayName),
                leadingTooltip: l10n.dshModelPickerTitle,
                onTapLeading: () => unawaited(_requestModelPicker()),
                supportsReasoning: model?.supportsReasoning ?? false,
                reasoning: dshReasoningRequestForEffort(effort?.id),
                reasoningActive: effort != null && effort.id != 'off',
                onConfigureReasoning: model?.supportsReasoning == true
                    ? () => unawaited(_openReasoningPicker())
                    : null,
                loading: state.busy,
                onStop: state.running ? () => unawaited(_cancelTurn()) : null,
                onSend: _handleSend,
                showWorkspaceButton: false,
                showToolsButton: false,
                showQuickPhraseButton: false,
                hasQueuedInput: false,
                showMoreButton: true,
                onMore: () => unawaited(_openPlusSheet()),
              ),
            ),
          ],
        );
      },
    );
  }

  double _leadingExtent(String? label) {
    final length = (label ?? '').runes.length;
    final width = 46.0 + length * 7.2;
    return width.clamp(96.0, 208.0).toDouble();
  }

  Widget _buildStatusBanners(
    BuildContext context,
    DshChatViewState state,
    DshTranscriptNotice? notice,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final problem = state.connectionProblem;
    if (problem != null) {
      return _DshStatusBanner(
        text: _connectionProblemText(l10n, problem),
        tone: _DshBannerTone.error,
        onRetry: () => unawaited(_reload()),
        retryLabel: l10n.retry,
      );
    }
    final connectionError = (state.connectionError ?? '').trim();
    if (connectionError.isNotEmpty) {
      return _DshStatusBanner(
        text: connectionError,
        tone: _DshBannerTone.error,
        onRetry: () => unawaited(_reload()),
        retryLabel: l10n.retry,
      );
    }
    if (state.stale) {
      return _DshStatusBanner(
        text: l10n.dshStaleBanner,
        tone: _DshBannerTone.warning,
        onRetry: () => unawaited(_reload()),
        retryLabel: l10n.retry,
      );
    }
    if (notice != null) {
      return _DshStatusBanner(
        text: notice.text,
        tone: notice.kind == DshNoticeKind.error
            ? _DshBannerTone.error
            : _DshBannerTone.neutral,
      );
    }
    return const SizedBox.shrink();
  }

  /// Localized sentence for the link failure the gateway reported.
  String _connectionProblemText(
    AppLocalizations l10n,
    DshConnectionProblem problem,
  ) {
    return switch (problem) {
      DshConnectionProblem.notConfigured => l10n.dshErrorNotConfigured,
      DshConnectionProblem.unreachable => l10n.dshErrorUnreachable,
      DshConnectionProblem.auth => l10n.dshErrorAuth,
      DshConnectionProblem.protocol => l10n.dshErrorProtocol,
      DshConnectionProblem.unsupported => l10n.dshErrorUnsupported,
      DshConnectionProblem.unknown => l10n.dshErrorUnknown,
    };
  }

  Future<void> _reload() async {
    final session = _session;
    if (session == null) return;
    try {
      await session.reload();
    } catch (_) {
      if (!mounted) return;
      _showSnack(AppLocalizations.of(context)!.dshOperationFailed);
    }
  }

  Future<void> _requestModelPicker() async {
    final hostPicker = widget.onRequestModelPicker;
    if (hostPicker != null) {
      hostPicker();
      return;
    }
    await _openModelPicker();
  }

  Future<void> _openModelPicker() async {
    final session = _session;
    if (session == null) return;
    var state = session.state;
    if (state.modelCatalog.isEmpty && !state.modelCatalog.isLoading) {
      unawaited(session.refreshModelCatalog());
    }
    final picked = await showDshModelPicker(
      context,
      catalog: state.modelCatalog,
      current: state.modelSelection ?? state.modelCatalog.defaultSelection,
    );
    if (!mounted || picked == null) return;
    state = session.state;
    if (picked == state.modelSelection) return;
    try {
      await session.selectModel(picked);
    } catch (_) {
      if (!mounted) return;
      _showSnack(AppLocalizations.of(context)!.dshModelChangeFailed);
    }
  }

  Future<void> _openReasoningPicker() async {
    final session = _session;
    if (session == null) return;
    final state = session.state;
    final model = state.currentModel;
    if (model == null || !model.supportsReasoning) return;
    final picked = await showDshReasoningPicker(
      context,
      model: model,
      current: state.modelSelection,
    );
    if (!mounted || picked == null) return;
    final base = state.modelSelection ?? state.modelCatalog.defaultSelection;
    if (base == null || base.reasoningEffortId == picked) return;
    try {
      await session.selectModel(base.copyWith(reasoningEffortId: picked));
    } catch (_) {
      if (!mounted) return;
      _showSnack(AppLocalizations.of(context)!.dshReasoningChangeFailed);
    }
  }

  Future<void> _openPermissionPicker() async {
    final session = _session;
    if (session == null) return;
    final permissions = session.state.permissions;
    if (permissions == null) return;
    final picked = await showDshPermissionPicker(context, state: permissions);
    if (!mounted || picked == null) return;
    if (picked == session.state.permissions?.currentValue) return;
    try {
      await session.setPermission(picked);
    } catch (_) {
      if (!mounted) return;
      _showSnack(AppLocalizations.of(context)!.dshPermissionChangeFailed);
    }
  }

  Future<void> _openAgentPresetPicker() async {
    final session = _session;
    if (session == null) return;
    final agentPresets = session.state.agentPresets;
    if (agentPresets == null || !agentPresets.canSelect) return;
    final picked = await showDshAgentPresetPicker(context, state: agentPresets);
    if (!mounted || picked == null) return;
    if (picked == session.state.agentPresets?.currentId) return;
    try {
      await session.selectAgentPreset(picked);
    } on DshGatewayException catch (error) {
      if (!mounted) return;
      _showSnack(
        AppLocalizations.of(
          context,
        )!.dshPresetSelectFailed(error.detail ?? error.failure.name),
      );
    } catch (_) {
      if (!mounted) return;
      _showSnack(AppLocalizations.of(context)!.dshPresetSelectFailedUnknown);
    }
  }

  Future<void> _openPlusSheet() async {
    final session = _session;
    if (session == null) return;
    final state = session.state;
    // 压缩 is only offered when the Host's command catalog advertises it: the
    // wire path is a real `/compact` command, and a guessed name would be a dead
    // tap. The other disabled rows have no endpoint at all (see the sheet).
    final compactAvailable = state.commands.any(
      (command) => command.name.toLowerCase() == 'compact',
    );
    await showDshPlusSheet(
      context,
      state: DshPlusMenuState(
        permissionLabel: state.permissionPreset,
        modelLabel: state.modelDisplay,
        connectionProblem: state.connectionError,
        compactCommandAvailable: compactAvailable,
      ),
      onOpenPermission: () => unawaited(_openPermissionPicker()),
      onOpenModel: () => unawaited(_requestModelPicker()),
      onPickAttachment: () => unawaited(_openAttachmentPicker()),
      onCompress: compactAvailable
          ? () => unawaited(_runCommandLine('/compact'))
          : null,
    );
  }

  /// Lets the user choose between the image picker and the document picker
  /// before the native pipeline stages files into the composer.
  Future<void> _openAttachmentPicker() async {
    final l10n = AppLocalizations.of(context)!;
    final items = <ActionSheetItem>[
      ActionSheetItem(
        icon: Lucide.Image,
        label: l10n.dshPlusPickPhoto,
        onTap: () => unawaited(_pickImages()),
      ),
      ActionSheetItem(
        icon: Lucide.File,
        label: l10n.dshPlusPickFile,
        onTap: () => unawaited(_pickFiles()),
      ),
    ];
    final isDesktop =
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
    if (isDesktop) {
      await showAdaptiveActionMenu(
        context,
        title: l10n.dshPlusAttachFile,
        items: items,
      );
      return;
    }
    await showMobileActionSheet(
      context,
      title: l10n.dshPlusAttachFile,
      items: items,
    );
  }

  Future<void> _pickCamera() async {
    final service = _fileUploadService;
    if (service == null || !mounted) return;
    await service.onPickCamera(context);
  }

  Future<void> _pickImages() async {
    await _fileUploadService?.onPickPhotos();
  }

  Future<void> _pickFiles() async {
    await _fileUploadService?.onPickFiles();
  }

  /// Runs one slash command through the Host's command path and reports the
  /// in-band outcome; anything else would be a fake success.
  Future<void> _runCommandLine(String line) async {
    final session = _session;
    if (session == null) return;
    final result = await session.runCommand(line);
    if (!mounted) return;
    final text = (result.text ?? '').trim();
    if (text.isNotEmpty) {
      _showSnack(text);
      return;
    }
    if (!result.success) {
      _showSnack(AppLocalizations.of(context)!.dshOperationFailed);
    }
  }

  /// Watches the draft for a leading `/` and offers the Host's command list.
  ///
  /// The menu opens only while the user is typing the command name (before the
  /// first argument), which keeps it from popping up for a prompt that merely
  /// starts with a slash.
  void _onDraftChanged() {
    if (!mounted) return;
    final session = _session;
    if (session == null) return;
    final commands = session.state.commands;
    if (commands.isEmpty) return;
    final text = _draftController.text;
    final trimmed = text.trimLeft();
    if (!trimmed.startsWith('/')) return;
    final rest = trimmed.substring(1);
    if (rest.contains(RegExp(r'\s'))) return;
    if (_slashMenuOpen) return;
    if (rest.isNotEmpty &&
        !commands.any(
          (command) =>
              command.name.toLowerCase().startsWith(rest.toLowerCase()),
        )) {
      return;
    }
    unawaited(_openSlashSheet());
  }

  Future<void> _openSlashSheet() async {
    final session = _session;
    if (session == null || _slashMenuOpen) return;
    _slashMenuOpen = true;
    try {
      final picked = await showDshSlashCommandsSheet(
        context,
        commands: session.state.commands,
      );
      if (!mounted || picked == null) return;
      _draftController.text = '/${picked.name} ';
      _draftController.selection = TextSelection.collapsed(
        offset: _draftController.text.length,
      );
      if (!picked.takesInput) {
        _draftController.clear();
        await _runCommandLine('/${picked.name}');
      }
    } finally {
      _slashMenuOpen = false;
    }
  }

  /// The slash command a send would execute, or null for a normal prompt.
  ///
  /// Only catalog commands count: an unknown `/word` stays a prompt, exactly as
  /// the user typed it.
  DshSlashCommand? _commandForSend(String text) {
    final session = _session;
    if (session == null) return null;
    final trimmed = text.trim();
    if (!trimmed.startsWith('/')) return null;
    final token = trimmed.substring(1).split(RegExp(r'\s')).first;
    if (token.isEmpty) return null;
    for (final command in session.state.commands) {
      if (command.name.toLowerCase() == token.toLowerCase()) return command;
    }
    return null;
  }

  String _attachmentFailureText(DshAttachmentFailure failure) {
    final l10n = AppLocalizations.of(context)!;
    return switch (failure.kind) {
      DshAttachmentFailureKind.tooManyImages => l10n.dshAttachmentTooManyImages,
      DshAttachmentFailureKind.imageTooLarge => l10n.dshAttachmentImageTooLarge,
      DshAttachmentFailureKind.imagesTooLarge =>
        l10n.dshAttachmentImagesTooLarge,
      DshAttachmentFailureKind.unsupportedImageType =>
        l10n.dshAttachmentUnsupportedType,
      DshAttachmentFailureKind.readFailed => l10n.dshAttachmentReadFailed,
      DshAttachmentFailureKind.uploadFailed => l10n.dshAttachmentUploadFailed,
    };
  }

  Future<void> _cancelTurn() async {
    final session = _session;
    if (session == null) return;
    try {
      await session.cancelTurn();
    } catch (_) {
      if (!mounted) return;
      _showSnack(AppLocalizations.of(context)!.dshOperationFailed);
    }
  }

  Future<void> _answerApproval(DshPendingApproval approval, bool allow) async {
    final session = _session;
    if (session == null) return;
    try {
      await session.answerApproval(approval.id, allow: allow);
    } catch (_) {
      if (!mounted) return;
      _showSnack(AppLocalizations.of(context)!.dshOperationFailed);
    }
  }

  Future<void> _answerQuestions(
    DshPendingQuestion request,
    List<DshQuestionAnswer> answers,
  ) async {
    final session = _session;
    if (session == null) return;
    try {
      await session.answerQuestions(request.id, answers);
    } catch (_) {
      if (!mounted) return;
      _showSnack(AppLocalizations.of(context)!.dshOperationFailed);
    }
  }

  Future<void> _rejectQuestions(DshPendingQuestion request) async {
    final session = _session;
    if (session == null) return;
    try {
      await session.rejectQuestions(request.id);
    } catch (_) {
      if (!mounted) return;
      _showSnack(AppLocalizations.of(context)!.dshOperationFailed);
    }
  }

  Future<ChatInputSubmissionResult> _handleSend(ChatInputData input) async {
    final session = _session;
    if (session == null) return ChatInputSubmissionResult.rejected;
    // A slash-command line is executed through `commands/execute`, not sent as
    // a chat prompt. Attachments only ride prompts, so a command-with-files send
    // stays a prompt below (the invocation line would otherwise be swallowed).
    final command = _commandForSend(input.text);
    final hasAttachments =
        input.imagePaths.isNotEmpty || input.documents.isNotEmpty;
    if (command != null && !hasAttachments) {
      final result = await session.runCommand(input.text.trim());
      if (!mounted) {
        return result.success
            ? ChatInputSubmissionResult.sent
            : ChatInputSubmissionResult.rejected;
      }
      final text = (result.text ?? '').trim();
      if (!result.success) {
        _showSnack(
          text.isEmpty
              ? AppLocalizations.of(context)!.dshOperationFailed
              : text,
        );
        // Keep the draft: the command did not run.
        return ChatInputSubmissionResult.rejected;
      }
      if (text.isNotEmpty) _showSnack(text);
      return ChatInputSubmissionResult.sent;
    }
    final result = await DshComposerSubmission(
      session,
      attachmentPreparer: _prepareAttachments,
    ).submitWithReason(input);
    if (result.rejected && mounted) {
      final l10n = AppLocalizations.of(context)!;
      final attachmentFailure = result.attachmentFailure;
      if (attachmentFailure != null) {
        final fileName = (attachmentFailure.fileName ?? '').trim();
        final detail = fileName.isEmpty ? '' : ' — $fileName';
        _showSnack('${_attachmentFailureText(attachmentFailure)}$detail');
        return result.result;
      }
      final message = (result.message ?? '').trim();
      _showSnack(
        message.isEmpty
            ? l10n.dshSendFailedTitle
            : '${l10n.dshSendFailedTitle} — $message',
      );
    }
    return result.result;
  }

  /// Reads the composer's staged paths and turns them into DSH prompt parts:
  /// images travel inline (base64), documents are uploaded for a receipt.
  Future<List<DshPromptAttachment>> _prepareAttachments(
    ChatInputData input,
  ) async {
    final session = _session;
    if (session == null) return const <DshPromptAttachment>[];
    final service = DshAttachmentUploadService(
      readFile: (path) => File(path).readAsBytes(),
      uploadFile: (bytes, {required name, mediaType}) =>
          session.uploadAttachment(bytes, name: name, mediaType: mediaType),
      imageLimits: () => session.state.imageLimits,
    );
    return service.prepare(input);
  }

  void _showSnack(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

// ---------------------------------------------------------------------------
// Composer + transcript sub-widgets
// ---------------------------------------------------------------------------

class _DshComposerModelPill extends StatelessWidget {
  const _DshComposerModelPill({
    required this.model,
    required this.selection,
    required this.fallbackLabel,
  });

  final DshModelOption? model;
  final DshModelSelection? selection;
  final String fallbackLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = model?.displayName ?? fallbackLabel;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CurrentModelIcon(
          providerKey: selection?.providerId,
          modelId: selection?.modelId ?? model?.id,
          size: 22,
          iconScale: 0.62,
        ),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 118),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: AppFontWeights.medium,
              color: cs.onSurface.withValues(alpha: 0.82),
            ),
          ),
        ),
        const SizedBox(width: 2),
        Icon(
          Lucide.ChevronDown,
          size: 13,
          color: cs.onSurface.withValues(alpha: 0.45),
        ),
      ],
    );
  }
}

class _DshQueuePill extends StatelessWidget {
  const _DshQueuePill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        AppLocalizations.of(context)!.dshQueuedCount(count),
        style: TextStyle(
          fontSize: 11,
          color: cs.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

enum _DshBannerTone { neutral, warning, error }

class _DshStatusBanner extends StatelessWidget {
  const _DshStatusBanner({
    required this.text,
    required this.tone,
    this.onRetry,
    this.retryLabel,
  });

  final String text;
  final _DshBannerTone tone;
  final VoidCallback? onRetry;
  final String? retryLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color) = switch (tone) {
      _DshBannerTone.error => (Lucide.TriangleAlert, cs.error),
      _DshBannerTone.warning => (Lucide.CircleAlert, context.appColors.warning),
      _DshBannerTone.neutral => (
        Lucide.BadgeInfo,
        cs.onSurface.withValues(alpha: 0.6),
      ),
    };
    return Container(
      key: const ValueKey<String>('dsh-status-banner'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      color: Color.alphaBlend(color.withValues(alpha: 0.08), cs.surface),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: cs.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
              ),
              child: Text(
                retryLabel ?? 'Retry',
                style: TextStyle(fontSize: 12, color: color),
              ),
            ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _DshEmptyTranscript extends StatelessWidget {
  const _DshEmptyTranscript({
    required this.title,
    required this.body,
    required this.busy,
  });

  final String title;
  final String body;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const DshWhaleAvatar(size: 52),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: AppFontWeights.semibold,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
            if (busy) ...[
              const SizedBox(height: 18),
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: cs.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DshConversationPlaceholder extends StatelessWidget {
  const _DshConversationPlaceholder({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (message != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      );
    }
    return Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2.2, color: cs.primary),
      ),
    );
  }
}
