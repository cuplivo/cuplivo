import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/chat_input_data.dart';
import '../../../core/models/assistant.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/asr_provider.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/quick_phrase_provider.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/providers/world_book_provider.dart';
import '../utils/model_display_helper.dart';
import '../utils/input_bar_button_layout.dart';
import 'chat_input_bar.dart';
import 'image_generation_options.dart';
import 'model_icon.dart';

/// Callback for checking if a model supports tool calling.
typedef IsToolModelCallback = bool Function(String providerKey, String modelId);

/// Callback for checking if a model supports reasoning.
typedef IsReasoningModelCallback =
    bool Function(String providerKey, String modelId);

/// Callback for checking if reasoning is enabled.
typedef IsReasoningEnabledCallback = bool Function(int? budget);

/// Widget that wraps ChatInputBar with all the necessary logic and callbacks.
///
/// This widget extracts the _buildChatInputBar logic from HomePageState
/// to reduce coupling and improve maintainability.
class ChatInputSection extends StatelessWidget {
  const ChatInputSection({
    super.key,
    required this.inputBarKey,
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
    this.onOpenToolsHub,
    this.onLongPressMcp,
    this.onOpenSearch,
    this.onConfigureReasoning,
    this.onSend,
    this.onStop,
    this.hasQueuedInput = false,
    this.queuedPreviewText,
    this.onCancelQueuedInput,
    this.onQuickPhrase,
    this.onLongPressQuickPhrase,
    this.onDocumentProcessing,
    this.onConversationProactiveCare,
    this.onOpenMiniMap,
    this.onPickCamera,
    this.onPickPhotos,
    this.onUploadFiles,
    this.onToggleLearningMode,
    this.onOpenWorldBook, // 新增世界书支持桌面端
    this.onOpenSkills,
    this.onLongPressLearning,
    this.onClearContext,
    this.onCompressContext,
    this.conversationId,
    this.sendButtonTooltip,
    this.backgroundImageActive = false,
    this.multiAIModelCount,
    this.onMultiSelectModel,
    this.imageGenController,
    this.livePanel,
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
  final int? multiAIModelCount;
  final VoidCallback? onMultiSelectModel;
  final VoidCallback? onOpenToolsHub;
  final VoidCallback? onLongPressMcp;
  final VoidCallback? onOpenSearch;
  final VoidCallback? onConfigureReasoning;
  final Future<ChatInputSubmissionResult> Function(ChatInputData)? onSend;
  final VoidCallback? onStop;
  final bool hasQueuedInput;
  final String? queuedPreviewText;
  final VoidCallback? onCancelQueuedInput;
  final VoidCallback? onQuickPhrase;
  final VoidCallback? onLongPressQuickPhrase;
  final VoidCallback? onDocumentProcessing;
  final VoidCallback? onConversationProactiveCare;
  final VoidCallback? onOpenMiniMap;
  final VoidCallback? onPickCamera;
  final VoidCallback? onPickPhotos;
  final VoidCallback? onUploadFiles;
  final VoidCallback? onToggleLearningMode;
  final VoidCallback? onOpenWorldBook;
  final VoidCallback? onOpenSkills;
  final VoidCallback? onLongPressLearning;
  final VoidCallback? onClearContext;
  final VoidCallback? onCompressContext;
  final String? conversationId;
  final String? sendButtonTooltip;
  final bool backgroundImageActive;

  /// Shared image-generation options controller (home page owned), forwarded
  /// to the bar so the LivePanel inline card and the bar snapshot one
  /// controller.
  final ImageGenerationOptionsController? imageGenController;

  /// Transient status surface (LivePanel) rendered inside the bar's card.
  final Widget? livePanel;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final ap = context.watch<AssistantProvider>();
    final asr = context.watch<AsrProvider>();
    final a = ap.currentAssistant;
    final assistantId = a?.id;

    // Use unified helper to get model identifiers
    final modelIds = getActiveModelIds(settings, assistant: a);
    final pk = modelIds.providerKey;
    final mid = modelIds.modelId;

    // Enforce model capabilities: disable MCP selection if model doesn't support tools
    _enforceModelCapabilities(context, settings, ap, a, pk, mid);

    final isDesktop = _isDesktopPlatform(context);
    final hasWorldBooks = context.watch<WorldBookProvider>().books.isNotEmpty;
    final buttonLayout = resolveInputBarButtonLayout(
      savedOrder: settings.chatInputButtonOrder,
      savedMoreIds: settings.chatInputMoreButtonIds,
      tabletLayout: isTablet,
    );
    final customized = settings.chatInputButtonsCustomized;
    // Tablet-only icons may leak onto the narrow row once the user explicitly
    // customized AND marked the item directly shown (sentinel-unset keeps the
    // legacy per-platform split — see resolveInputBarButtonLayout).
    bool unlocked(String id) =>
        customized && !buttonLayout.moreIds.contains(id);

    return ChatInputBar(
      key: inputBarKey,
      onMore: onMore,
      onSelectModel: onSelectModel,
      onLongPressSelectModel: onLongPressSelectModel,
      conversationId: conversationId,
      onOpenToolsHub: onOpenToolsHub,
      onLongPressMcp: onLongPressMcp,
      onStop: onStop,
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
      reasoningActive: isReasoningEnabled(
        (context.watch<AssistantProvider>().currentAssistant?.thinkingBudget) ??
            settings.thinkingBudget,
      ),
      reasoningBudget:
          (context
              .watch<AssistantProvider>()
              .currentAssistant
              ?.thinkingBudget) ??
          settings.thinkingBudget,
      supportsReasoning: (pk != null && mid != null)
          ? isReasoningModel(pk, mid)
          : false,
      onOpenSearch: onOpenSearch,
      onSend: onSend,
      loading: isLoading,
      sendButtonTooltip: sendButtonTooltip,
      hasQueuedInput: hasQueuedInput,
      queuedPreviewText: queuedPreviewText,
      onCancelQueuedInput: onCancelQueuedInput,
      showToolsHubButton: _shouldShowToolsHubButton(settings, a, pk, mid),
      toolsHubActive: _isToolsActive(context, a),
      showQuickPhraseButton: _hasQuickPhrases(context, a),
      onQuickPhrase: onQuickPhrase,
      onLongPressQuickPhrase: onLongPressQuickPhrase,
      inputBarButtonOrder: buttonLayout.orderedIds,
      inputBarMoreIds: buttonLayout.moreIds,
      inputBarCustomized: customized,
      // Document processing button: always visible on tablet/desktop, navigates to config panel
      showDocumentProcessingButton:
          isTablet ||
          isDesktop ||
          (unlocked(inputBarButtonDocument) && onDocumentProcessing != null),
      onDocumentProcessing: onDocumentProcessing,
      onConversationProactiveCare: onConversationProactiveCare,
      // Tablet-specific parameters
      showMiniMapButton: isTablet,
      onOpenMiniMap: isTablet ? onOpenMiniMap : null,
      onPickCamera: !isDesktop && (isTablet || unlocked(inputBarButtonCamera))
          ? onPickCamera
          : null,
      onPickPhotos: !isDesktop && (isTablet || unlocked(inputBarButtonPhotos))
          ? onPickPhotos
          : null,
      onUploadFiles: isTablet || unlocked(inputBarButtonUpload)
          ? onUploadFiles
          : null,
      onToggleLearningMode: isTablet || unlocked(inputBarButtonLearning)
          ? onToggleLearningMode
          : null,
      onOpenWorldBook:
          hasWorldBooks && (isTablet || unlocked(inputBarButtonWorldBook))
          ? onOpenWorldBook
          : null,
      onOpenSkills: isTablet || unlocked(inputBarButtonSkills)
          ? onOpenSkills
          : null,
      onLongPressLearning: isTablet || unlocked(inputBarButtonLearning)
          ? onLongPressLearning
          : null,
      learningModeActive: isTablet || unlocked(inputBarButtonLearning)
          ? context
                .watch<InstructionInjectionProvider>()
                .activeIdsFor(assistantId)
                .isNotEmpty
          : false,
      worldBookActive: isTablet || unlocked(inputBarButtonWorldBook)
          ? context
                .watch<WorldBookProvider>()
                .activeBookIdsFor(assistantId)
                .isNotEmpty
          : false,
      skillsActive: isTablet || unlocked(inputBarButtonSkills)
          ? (context
                    .watch<AssistantProvider>()
                    .currentAssistant
                    ?.skillIds
                    .isNotEmpty ??
                false)
          : false,
      showMoreButton: !isTablet,
      onClearContext: isTablet || unlocked(inputBarButtonContext)
          ? onClearContext
          : null,
      onCompressContext: isTablet || unlocked(inputBarButtonContext)
          ? onCompressContext
          : null,
      backgroundImageActive: backgroundImageActive,
      inputBackgroundOpacityLight: settings.chatInputBackgroundOpacityLight,
      inputBackgroundOpacityDark: settings.chatInputBackgroundOpacityDark,
      multiAIModelCount: multiAIModelCount,
      onMultiSelectModel: onMultiSelectModel,
      imageGenController: imageGenController,
      livePanel: livePanel,
    );
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

    final supportsReasoning = isReasoningModel(pk, mid);
    if (!supportsReasoning && a != null) {
      final enabledNow = isReasoningEnabled(
        a.thinkingBudget ?? settings.thinkingBudget,
      );
      if (enabledNow) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final aa = ap.currentAssistant;
          if (aa != null) {
            await ap.updateAssistant(aa.copyWith(thinkingBudget: 0));
          }
        });
      }
    }
  }

  bool _shouldShowToolsHubButton(
    SettingsProvider settings,
    Assistant? a,
    String? pk,
    String? mid,
  ) {
    final pk2 = a?.chatModelProvider ?? settings.currentModelProvider;
    final mid3 = a?.chatModelId ?? settings.currentModelId;
    if (pk2 == null || mid3 == null) return false;
    return isToolModel(pk2, mid3);
  }

  bool _isToolsActive(BuildContext context, Assistant? a) {
    final connected = context.watch<McpProvider>().connectedServers;
    final selected = a?.mcpServerIds ?? const <String>[];
    if (selected.isNotEmpty && connected.any((s) => selected.contains(s.id))) {
      return true;
    }
    if (a == null) return false;
    return a.localToolIds.isNotEmpty || a.workspaceEnabled;
  }

  bool _hasQuickPhrases(BuildContext context, Assistant? a) {
    final quickPhraseProvider = context.watch<QuickPhraseProvider>();
    final globalCount = quickPhraseProvider.globalPhrases.length;
    final assistantCount = a != null
        ? quickPhraseProvider.getForAssistant(a.id).length
        : 0;
    return (globalCount + assistantCount) > 0;
  }
}
