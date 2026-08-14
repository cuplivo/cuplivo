import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:math' as math;
import '../../../theme/design_tokens.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../icons/reasoning_icons.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import '../../../l10n/app_localizations.dart';
import 'package:image_picker/image_picker.dart';
import '../../../utils/file_import_helper.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../../../shared/responsive/breakpoints.dart';
import 'dart:async';
import 'dart:io';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/services/model_override_payload_parser.dart';
import 'image_generation_options.dart';
import '../../../utils/clipboard_images.dart';
import '../../../core/providers/asr_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/input_status_provider.dart';
import '../../../core/services/search/search_service.dart';
import '../../../core/services/api/builtin_tools.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../services/input_draft_persistence.dart';
import '../../../core/utils/multimodal_input_utils.dart';
import '../../model/utils/ocr_model_capability.dart';
import '../../../utils/brand_assets.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/app_directories.dart';
import '../../../utils/image_compressor.dart';
import '../../../utils/format.dart';
import 'package:image/image.dart' as img;
import '../../../shared/dialogs/image_compression_dialog.dart';
import 'package:super_clipboard/super_clipboard.dart';
import '../../../desktop/desktop_context_menu.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import '../../group_chat/models/chat_input_mode.dart';

class ChatInputBarController {
  _ChatInputBarState? _state;
  void _bind(_ChatInputBarState s) => _state = s;
  void _unbind(_ChatInputBarState s) {
    if (identical(_state, s)) _state = null;
  }

  bool get allowImagesApiRouting => _state?._allowImagesApiRouting ?? true;
  bool get hasDraftMedia => _state?._hasDraftMedia ?? false;

  void addImages(List<String> paths) => _state?._addImages(paths);
  void clearImages() => _state?._clearImages();
  void addFiles(List<DocumentAttachment> docs) => _state?._addFiles(docs);
  void clearFiles() => _state?._clearFiles();
  void restoreInput(ChatInputData input) => _state?._restoreInput(input);
  ChatInputData snapshotInput(String text) =>
      _state?._snapshotInput(text) ?? ChatInputData(text: text.trim());
  void clearDraft() => _state?._clearDraft();

  /// Re-syncs the persisted draft with programmatic text changes made
  /// outside the bar (suggestion insert, quick phrase, quote, synthesize
  /// prompt). Text set via the controller does not fire `onChanged`.
  void syncDraft() => _state?._scheduleDraftSave();
}

class ChatInputBar extends StatefulWidget {
  const ChatInputBar({
    super.key,
    this.onSend,
    this.onStop,
    this.onSelectModel,
    this.onLongPressSelectModel,
    this.onOpenMcp,
    this.onLongPressMcp,
    this.onOpenSearch,
    this.onMore,
    this.onConfigureReasoning,
    this.moreOpen = false,
    this.focusNode,
    this.modelIcon,
    this.controller,
    this.mediaController,
    this.asrProvider,
    this.loading = false,
    this.hasQueuedInput = false,
    this.queuedPreviewText,
    this.onCancelQueuedInput,
    this.reasoningActive = false,
    this.reasoningBudget,
    this.supportsReasoning = true,
    this.showMcpButton = false,
    this.mcpActive = false,
    this.showMiniMapButton = false,
    this.onOpenMiniMap,
    this.onPickCamera,
    this.onPickPhotos,
    this.onUploadFiles,
    this.onToggleLearningMode,
    this.onOpenWorldBook,
    this.onOpenSkills,
    this.onClearContext,
    this.onCompressContext,
    this.onLongPressLearning,
    this.learningModeActive = false,
    this.worldBookActive = false,
    this.skillsActive = false,
    this.showMoreButton = true,
    this.showQuickPhraseButton = false,
    this.onQuickPhrase,
    this.onLongPressQuickPhrase,
    this.showDocumentProcessingButton = false,
    this.onDocumentProcessing,
    this.conversationId,
    this.sendButtonTooltip,
    this.backgroundImageActive = false,
    this.inputBackgroundOpacityLight =
        SettingsProvider.defaultChatInputBackgroundOpacityLight,
    this.inputBackgroundOpacityDark =
        SettingsProvider.defaultChatInputBackgroundOpacityDark,
    this.multiAIModelCount,
    this.onMultiSelectModel,
    this.mode = ChatInputMode.normal,
  });

  /// When [ChatInputMode.groupChat], hide model/search/reasoning/MCP/multi-AI.
  final ChatInputMode mode;

  final Future<ChatInputSubmissionResult> Function(ChatInputData)? onSend;
  final VoidCallback? onStop;
  final VoidCallback? onSelectModel;
  final VoidCallback? onLongPressSelectModel;
  final int? multiAIModelCount;
  final VoidCallback? onMultiSelectModel;
  final VoidCallback? onOpenMcp;
  final VoidCallback? onLongPressMcp;
  final VoidCallback? onOpenSearch;
  final VoidCallback? onMore;
  final VoidCallback? onConfigureReasoning;
  final bool moreOpen;
  final FocusNode? focusNode;
  final Widget? modelIcon;
  final TextEditingController? controller;
  final ChatInputBarController? mediaController;
  final AsrProvider? asrProvider;
  final bool loading;
  final bool hasQueuedInput;
  final String? queuedPreviewText;
  final VoidCallback? onCancelQueuedInput;
  final bool reasoningActive;
  final int? reasoningBudget;
  final bool supportsReasoning;
  final bool showMcpButton;
  final bool mcpActive;
  final bool showMiniMapButton;
  final VoidCallback? onOpenMiniMap;
  final VoidCallback? onPickCamera;
  final VoidCallback? onPickPhotos;
  final VoidCallback? onUploadFiles;
  final VoidCallback? onToggleLearningMode;
  final VoidCallback? onOpenWorldBook;
  final VoidCallback? onOpenSkills;
  final VoidCallback? onClearContext;
  final VoidCallback? onCompressContext;
  final VoidCallback? onLongPressLearning;
  final bool learningModeActive;
  final bool worldBookActive;
  final bool skillsActive;
  final bool showMoreButton;
  final bool showQuickPhraseButton;
  final VoidCallback? onQuickPhrase;
  final VoidCallback? onLongPressQuickPhrase;
  final bool showDocumentProcessingButton;
  final VoidCallback? onDocumentProcessing;
  final String? conversationId;
  final String? sendButtonTooltip;
  final bool backgroundImageActive;
  final double inputBackgroundOpacityLight;
  final double inputBackgroundOpacityDark;

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar>
    with WidgetsBindingObserver {
  late TextEditingController _controller;
  late InputDraftPersistence _draftPersistence;
  bool _isExpanded = false; // Track expand/collapse state for input field
  // The ASR provider owns microphone capture. This widget only owns the
  // composer presentation and an exact snapshot used by Cancel.
  final List<double> _voiceLevels = <double>[];
  static const int _maxVoiceLevels = 400;
  Timer? _voiceLevelTimer;
  TextEditingValue? _voiceBaseValue;
  bool _ownsVoiceSession = false;
  bool _finishingVoice = false;
  String? _lastReportedVoiceError;
  final List<String> _images = <String>[]; // local file paths
  final Map<String, int> _imageSizes = <String, int>{}; // path -> bytes
  final List<DocumentAttachment> _docs =
      <DocumentAttachment>[]; // files to upload
  final Map<LogicalKeyboardKey, Timer?> _repeatTimers = {};
  static const Duration _repeatInitialDelay = Duration(milliseconds: 300);
  static const Duration _repeatPeriod = Duration(milliseconds: 35);
  // Anchor for the responsive overflow menu on the left action bar
  final GlobalKey _leftOverflowAnchorKey = GlobalKey(
    debugLabel: 'left-overflow-anchor',
  );
  final GlobalKey _contextMgmtAnchorKey = GlobalKey(
    debugLabel: 'context-mgmt-anchor',
  );
  static const double _documentPreviewHeight = 48;
  static const double _imagePreviewHeight = 64;
  static const double _imageRemoveButtonSize = 18;
  // Suppress context menu briefly after app resume to avoid flickering
  bool _suppressContextMenu = false;
  bool _isSubmitting = false;
  bool _oneClickCompressing = false;
  bool _oneClickCompressDone = false;
  bool _oneClickConfirming = false;
  Timer? _confirmTimer;
  String? _lastImageDefaultsSignature;
  final _imageGenController = ImageGenerationOptionsController();

  bool get _composerLocked => widget.hasQueuedInput;

  InputStatusProvider get _inputStatus => context.read<InputStatusProvider>();

  Map<String, dynamic> _filterImageOptionBody(Map<String, dynamic> body) {
    const allowedKeys = <String>{
      'quality',
      'size',
      'output_format',
      'output_compression',
      'n',
    };
    return <String, dynamic>{
      for (final entry in body.entries)
        if (allowedKeys.contains(entry.key) && entry.value != null)
          entry.key: entry.value,
    };
  }

  Map<String, dynamic> _assistantImageOptionDefaults(Assistant? assistant) {
    if (assistant == null || assistant.customBody.isEmpty) {
      return const <String, dynamic>{};
    }
    final body = <String, dynamic>{
      for (final entry in assistant.customBody)
        if ((entry['key'] ?? '').trim().isNotEmpty)
          (entry['key']!.trim()): ModelOverridePayloadParser.parseOverrideValue(
            (entry['value'] ?? '').trim(),
          ),
    };
    return _filterImageOptionBody(body);
  }

  Map<String, dynamic> _effectiveImageOptionDefaults(
    ProviderConfig? cfg,
    String modelId,
    Assistant? assistant,
  ) {
    if (cfg == null) return const <String, dynamic>{};
    final ov = ModelOverridePayloadParser.modelOverride(
      cfg.modelOverrides,
      modelId,
    );
    final rawApiModelId = (ov['apiModelId'] ?? ov['api_model_id'])
        ?.toString()
        .trim();
    final upstreamModelId = rawApiModelId == null || rawApiModelId.isEmpty
        ? modelId
        : rawApiModelId;

    final body = <String, dynamic>{};
    final normalized = upstreamModelId.toLowerCase();
    if (normalized.startsWith('gpt-image-') ||
        normalized.startsWith('chatgpt-image-')) {
      body['quality'] = 'high';
      body['output_format'] = 'png';
    }
    body.addAll(
      _filterImageOptionBody(ModelOverridePayloadParser.customBody(ov)),
    );
    body.addAll(_assistantImageOptionDefaults(assistant));
    return body;
  }

  void _syncImageGenerationDefaults(
    ProviderConfig? cfg,
    String modelId,
    Assistant? assistant,
  ) {
    final defaults = _effectiveImageOptionDefaults(cfg, modelId, assistant);
    final signature = jsonEncode(defaults);
    if (signature == _lastImageDefaultsSignature) return;
    _lastImageDefaultsSignature = signature;
    _imageGenController.applyDefaultsFromBody(defaults);
  }

  Color _inputFillColor({
    required ThemeData theme,
    required bool backgroundImageActive,
    required double lightOpacity,
    required double darkOpacity,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    final configuredOpacity = (isDark ? darkOpacity : lightOpacity)
        .clamp(0.0, 1.0)
        .toDouble();
    final backgroundRatio = isDark
        ? 0.545 / SettingsProvider.defaultChatInputBackgroundOpacityDark
        : 0.5296 / SettingsProvider.defaultChatInputBackgroundOpacityLight;
    final targetOpacity = backgroundImageActive
        ? configuredOpacity * backgroundRatio
        : configuredOpacity;
    final overlayAlpha = isDark ? (backgroundImageActive ? 0.09 : 0.07) : 0.02;
    final overlayTint = isDark
        ? Colors.white.withValues(alpha: overlayAlpha)
        : theme.colorScheme.primary.withValues(alpha: overlayAlpha);
    final baseAlpha = ((targetOpacity - overlayAlpha) / (1.0 - overlayAlpha))
        .clamp(0.0, 1.0)
        .toDouble();
    final base = theme.colorScheme.surface.withValues(alpha: baseAlpha);
    return Color.alphaBlend(overlayTint, base).withValues(alpha: targetOpacity);
  }

  bool _supportsImagesApiRouting(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final ap = context.watch<AssistantProvider>();
    final a = ap.currentAssistant;
    final providerKey = a?.chatModelProvider ?? settings.currentModelProvider;
    final modelId = a?.chatModelId ?? settings.currentModelId;
    if (providerKey == null || modelId == null) {
      _inputStatus.updateImageModeKey(
        null,
        conversationId: widget.conversationId,
      );
      return false;
    }
    final cfg = settings.getProviderConfig(providerKey);
    final supported = ChatApiService.supportsOpenAIImagesApiRouting(
      cfg,
      modelId,
    );
    final nextKey = supported
        ? '${widget.conversationId ?? ''}::$providerKey::$modelId'
        : null;
    _inputStatus.updateImageModeKey(
      nextKey,
      conversationId: widget.conversationId,
    );
    if (supported) {
      _inputStatus.clearRestoredUnsupportedImagesApiRouting(
        widget.conversationId,
      );
      _syncImageGenerationDefaults(cfg, modelId, a);
    }
    return supported;
  }

  void _checkImageWarning(BuildContext context) {
    if (_images.isEmpty) {
      _inputStatus.updateImageWarningKey(null);
      return;
    }
    final settings = context.watch<SettingsProvider>();
    final ap = context.watch<AssistantProvider>();
    final a = ap.currentAssistant;
    final providerKey = a?.chatModelProvider ?? settings.currentModelProvider;
    final modelId = a?.chatModelId ?? settings.currentModelId;
    if (providerKey == null || modelId == null) {
      _inputStatus.updateImageWarningKey(null);
      return;
    }
    // OCR-active sends never need the warning: images are OCR-processed
    // instead of being sent to the vision model.
    final ocrActive = resolveOcrActive(
      settings: settings,
      assistant: a,
      providerKey: providerKey,
      modelId: modelId,
    );
    if (ocrActive) {
      _inputStatus.updateImageWarningKey(null);
      return;
    }
    final cfg = settings.getProviderConfig(providerKey);
    final supported = ChatApiService.supportsImageInput(cfg, modelId);
    final nextKey = supported
        ? null
        : '${widget.conversationId ?? ''}::$providerKey::$modelId';
    _inputStatus.updateImageWarningKey(nextKey);
  }

  bool get _imageModeActive => _inputStatus.imageModeActive;

  bool get _allowImagesApiRouting =>
      _inputStatus.allowImagesApiRoutingFor(widget.conversationId);

  bool get _imageParamsCustomized => _imageGenController.customized;

  String get _imageParamsSummary =>
      _imageGenController.summary(AppLocalizations.of(context)!);

  Map<String, dynamic> _imageGenerationExtraBody() {
    if (!_imageModeActive ||
        !_allowImagesApiRouting ||
        !_imageParamsCustomized) {
      return const <String, dynamic>{};
    }
    return _imageGenController.toExtraBody();
  }

  bool get _hasDraftMedia => _images.isNotEmpty || _docs.isNotEmpty;

  // Instance method for onChanged to avoid recreating the callback on every build
  void _onTextChanged(String _) {
    // User typing = a NEW input: the restored queued input's "must not route"
    // flag no longer applies to unrelated later sends.
    _inputStatus.clearRestoredUnsupportedImagesApiRouting(
      widget.conversationId,
    );
    setState(() {});
    _scheduleDraftSave();
  }

  /// Restores the cold-start draft into the input bar. Runs synchronously in
  /// [initState], before any user input can be delivered. Fires once per
  /// process — `takeDraftForRestore()` consumes the preloaded draft.
  void _restoreDraft() {
    if (widget.mode == ChatInputMode.groupChat) return;
    final draft = _draftPersistence.takeDraftForRestore();
    if (draft == null) return;
    final images = <String>[];
    for (final path in draft.imagePaths) {
      if (path.startsWith('data:') || File(path).existsSync()) {
        images.add(path);
      }
    }
    final documents = <DocumentAttachment>[];
    for (final doc in draft.documents) {
      if (File(doc.path).existsSync()) documents.add(doc);
    }
    if (draft.text.trim().isEmpty && images.isEmpty && documents.isEmpty) {
      // Everything was filtered out (whitespace-only text, media files
      // deleted on disk) — drop the stale draft instead of leaving it to
      // nag the storage guardrail forever.
      _clearPersistedDraft();
      return;
    }
    _controller.text = draft.text;
    _images.addAll(images);
    for (final p in images) {
      _imageSizes[p] = _fileSize(p);
    }
    _docs.addAll(documents);
    // Re-persist the filtered content so storage stays in sync with the bar.
    _scheduleDraftSave();
  }

  /// Feeds the current bar content into the debounced draft writer. No-op for
  /// group-chat bars (group composer stays draft-free).
  void _scheduleDraftSave() {
    if (widget.mode == ChatInputMode.groupChat) return;
    _draftPersistence.save(
      ChatInputData(
        text: _controller.text,
        imagePaths: List<String>.of(_images),
        documents: List<DocumentAttachment>.of(_docs),
      ),
    );
  }

  void _addImages(List<String> paths) {
    if (paths.isEmpty) return;
    _inputStatus.clearRestoredUnsupportedImagesApiRouting(
      widget.conversationId,
    );
    setState(() {
      _oneClickCompressDone = false;
      _confirmTimer?.cancel();
      _oneClickConfirming = false;
      for (final p in paths) {
        if (_images.contains(p)) continue;
        _images.add(p);
        _imageSizes[p] = _fileSize(p);
      }
    });
    _scheduleDraftSave();
  }

  int _fileSize(String path) {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  /// Reset media fields. MUST be called inside a [setState] callback.
  void _resetMedia({bool images = false, bool docs = false}) {
    if (images) {
      _images.clear();
      _imageSizes.clear();
    }
    if (docs) {
      _docs.clear();
    }
  }

  void _clearImages() {
    setState(() => _resetMedia(images: true));
    _scheduleDraftSave();
  }

  void _addFiles(List<DocumentAttachment> docs) {
    if (docs.isEmpty) return;
    setState(() => _docs.addAll(docs));
    _scheduleDraftSave();
  }

  void _clearFiles() {
    setState(() => _resetMedia(docs: true));
    _scheduleDraftSave();
  }

  void _restoreInput(ChatInputData input) {
    setState(() {
      _images
        ..clear()
        ..addAll(input.imagePaths);
      _imageSizes.clear();
      for (final p in _images) {
        _imageSizes[p] = _fileSize(p);
      }
      _docs
        ..clear()
        ..addAll(input.documents);
      _inputStatus.restoreAllowImagesApiRouting(
        allow: input.allowImagesApiRouting,
        conversationId: widget.conversationId,
      );
      _imageGenController.restoreFromBody(input.extraBody);
    });
    _scheduleDraftSave();
  }

  ChatInputData _snapshotInput(String text) {
    return ChatInputData(
      text: text.trim(),
      imagePaths: List<String>.of(_images),
      documents: List<DocumentAttachment>.of(_docs),
      allowImagesApiRouting: _allowImagesApiRouting,
      extraBody: _imageGenerationExtraBody(),
    );
  }

  void _clearDraft() {
    setState(() {
      _controller.clear();
      _resetMedia(images: true, docs: true);
    });
    _clearPersistedDraft();
  }

  /// Immediate draft removal, gated so a group-chat bar never touches the
  /// normal-chat draft.
  void _clearPersistedDraft() {
    if (widget.mode == ChatInputMode.groupChat) return;
    _draftPersistence.clearNow();
  }

  void _removeImageAt(int index) {
    final path = _images[index];
    setState(() {
      _images.removeAt(index);
      _imageSizes.remove(path);
    });
    _scheduleDraftSave();
  }

  void _removeDocumentAt(int index) {
    setState(() => _docs.removeAt(index));
    _scheduleDraftSave();
  }

  Future<void> _openCompressionDialog(int idx) async {
    if (idx >= _images.length) return;
    final path = _images[idx];
    if (path.isEmpty) return;
    int w = 0, h = 0;
    bool hasRealAlpha = false;
    try {
      final file = File(path);
      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return;
      w = decoded.width;
      h = decoded.height;
      hasRealAlpha =
          decoded.hasAlpha &&
          decoded.any((px) => px.a < decoded.maxChannelValue);
    } catch (_) {}
    if (!mounted || w == 0 || h == 0) return;
    if (MediaQuery.of(context).size.width < AppBreakpoints.tablet) {
      await ImageCompressionDialog.showSheet(
        context,
        imagePath: path,
        totalImageCount: _images.length,
        originalWidth: w,
        originalHeight: h,
        hasRealAlpha: hasRealAlpha,
        onCompress: (config) async {
          if (config.compressAll) {
            await _compressAll(config);
          } else {
            await _compressSingle(idx, config);
          }
        },
      );
    } else {
      await ImageCompressionDialog.show(
        context,
        imagePath: path,
        totalImageCount: _images.length,
        originalWidth: w,
        originalHeight: h,
        hasRealAlpha: hasRealAlpha,
        onCompress: (config) async {
          if (config.compressAll) {
            await _compressAll(config);
          } else {
            await _compressSingle(idx, config);
          }
        },
      );
    }
  }

  /// Apply a compression result to the image list and evict cache.
  /// Returns the new file size (0 if the image was removed concurrently).
  /// MUST be called inside a [setState] callback.
  int _applyCompressionResult(String oldPath, String newPath) {
    if (newPath == oldPath) {
      final size = _fileSize(oldPath);
      _imageSizes[oldPath] = size;
      imageCache.evict(FileImage(File(oldPath)));
      return size;
    }
    final idx = _images.indexOf(oldPath);
    if (idx == -1) return 0;
    final size = _fileSize(newPath);
    _images[idx] = newPath;
    _imageSizes[newPath] = size;
    _imageSizes.remove(oldPath);
    imageCache.evict(FileImage(File(oldPath)));
    _scheduleDraftSave();
    return size;
  }

  Future<void> _compressSingle(int idx, CompressionConfig config) async {
    if (idx >= _images.length) return;
    final oldPath = _images[idx];
    final origBytes = _imageSizes[oldPath] ?? 0;
    final newPath = await ImageCompressor.compressIfNeeded(
      oldPath,
      enabled: true,
      quality: config.quality,
      maxDimension: config.maxDimension,
      keepPng: config.keepPng,
    );
    if (!mounted) return;
    final currentIdx = _images.indexOf(oldPath);
    if (currentIdx == -1 || currentIdx != idx) return;
    setState(() {
      _applyCompressionResult(oldPath, newPath);
    });
    _maybeShowCompressionResult(context, origBytes, _imageSizes[newPath] ?? 0);
  }

  /// Shared iteration: snapshot images, call [compressFile] per image, apply
  /// results in setState, return aggregate stats. Handles !mounted guards.
  Future<({int saved, int totalOrig, int compressedCount})> _compressImages({
    required Future<String> Function(String oldPath) compressFile,
  }) async {
    final results = <({String oldPath, String newPath, int origBytes})>[];
    final snapshot = List<String>.of(_images);
    for (final oldPath in snapshot) {
      if (!_images.contains(oldPath)) continue;
      final origBytes = _imageSizes[oldPath] ?? 0;
      final newPath = await compressFile(oldPath);
      if (!mounted) return (saved: 0, totalOrig: 0, compressedCount: 0);
      results.add((oldPath: oldPath, newPath: newPath, origBytes: origBytes));
    }
    if (!mounted) return (saved: 0, totalOrig: 0, compressedCount: 0);
    int totalOrig = 0, totalNew = 0, compressedCount = 0;
    setState(() {
      for (final r in results) {
        final newBytes = _applyCompressionResult(r.oldPath, r.newPath);
        totalOrig += r.origBytes;
        totalNew += newBytes;
        if (r.origBytes > 0 && newBytes < r.origBytes) compressedCount++;
      }
    });
    final saved = totalOrig - totalNew;
    return (
      saved: saved > 0 ? saved : 0,
      totalOrig: totalOrig,
      compressedCount: compressedCount,
    );
  }

  Future<void> _compressAll(CompressionConfig config) async {
    final r = await _compressImages(
      compressFile: (oldPath) => ImageCompressor.compressIfNeeded(
        oldPath,
        enabled: true,
        quality: config.quality,
        maxDimension: config.maxDimension,
        keepPng: config.keepPng,
      ),
    );
    if (!mounted) return;
    if (r.saved > 0 && r.totalOrig > 0) {
      final pct = (r.saved * 100 / r.totalOrig).round();
      final l10n = AppLocalizations.of(context);
      if (l10n != null) {
        showAppSnackBar(
          context,
          message: l10n.imageCompressionBatchResult(
            formatBytes(r.saved),
            '$pct',
          ),
          type: NotificationType.success,
        );
      }
    }
  }

  Future<void> _oneClickCompressAll() async {
    setState(() => _oneClickCompressDone = false);
    final sp = context.read<SettingsProvider>();
    final quality = sp.oneClickCompressQuality;
    final maxDimension = sp.oneClickCompressMaxLongEdge;
    final alwaysJpg = sp.oneClickCompressAlwaysJpg;

    final r = await _compressImages(
      compressFile: (oldPath) async {
        bool keepPng = false;
        final ext = p.extension(oldPath).toLowerCase();
        if (!alwaysJpg && ext == '.png' && await _pngHasAlpha(oldPath)) {
          keepPng = true;
        }
        return ImageCompressor.compressIfNeeded(
          oldPath,
          enabled: true,
          quality: quality,
          maxDimension: maxDimension,
          keepPng: keepPng,
        );
      },
    );
    if (!mounted) return;
    setState(() {
      _oneClickCompressing = false;
      _oneClickCompressDone = true;
      _oneClickConfirming = false;
    });
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return;
    if (r.saved > 0) {
      final pct = r.totalOrig > 0 ? (r.saved * 100 / r.totalOrig).round() : 0;
      showAppSnackBar(
        context,
        message: l10n.oneClickCompressResult(
          r.compressedCount,
          formatBytes(r.saved),
          '$pct',
        ),
        type: NotificationType.success,
      );
    } else {
      showAppSnackBar(
        context,
        message: l10n.oneClickCompressNone,
        type: NotificationType.info,
      );
    }
  }

  void _maybeShowCompressionResult(
    BuildContext context,
    int origBytes,
    int newBytes,
  ) {
    if (origBytes <= 0 || newBytes <= 0 || origBytes <= newBytes) return;
    final saved = origBytes - newBytes;
    final pct = (saved * 100 / origBytes).round();
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return;
    showAppSnackBar(
      context,
      message: l10n.imageCompressionSingleResult(
        formatBytes(origBytes),
        formatBytes(newBytes),
        '$pct',
      ),
      type: NotificationType.success,
    );
  }

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TextEditingController();
    widget.mediaController?._bind(this);
    widget.asrProvider?.addListener(_handleAsrChanged);
    WidgetsBinding.instance.addObserver(this);
    _draftPersistence = context.read<InputDraftPersistence>();
    _restoreDraft();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // When app resumes from background, suppress context menu briefly to avoid flickering
    if (state == AppLifecycleState.resumed) {
      _suppressContextMenu = true;
      // Also unfocus to reset any stuck toolbar state (iOS only)
      if (Platform.isIOS) {
        widget.focusNode?.unfocus();
      }
      // Re-enable context menu after a short delay
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          setState(() => _suppressContextMenu = false);
        }
      });
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // When going to background, hide any open toolbar
      _suppressContextMenu = true;
      if (Platform.isIOS) {
        widget.focusNode?.unfocus();
      }
      if (_ownsVoiceSession) unawaited(_cancelVoiceInput());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopVoiceLevelSampling();
    final asr = widget.asrProvider;
    asr?.removeListener(_handleAsrChanged);
    if (_ownsVoiceSession && asr != null) unawaited(asr.cancel());
    for (final timer in _repeatTimers.values) {
      try {
        timer?.cancel();
      } catch (_) {}
    }
    _repeatTimers.clear();
    widget.mediaController?._unbind(this);
    if (widget.controller == null) {
      _controller.dispose();
    }
    // Flush any pending debounced write so the draft survives the bar being
    // torn down.
    _draftPersistence.flushNow();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ChatInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.asrProvider, widget.asrProvider)) {
      _stopVoiceLevelSampling();
      oldWidget.asrProvider?.removeListener(_handleAsrChanged);
      if (_ownsVoiceSession && oldWidget.asrProvider != null) {
        unawaited(oldWidget.asrProvider!.cancel());
        final original = _voiceBaseValue;
        if (original != null) _controller.value = original;
        _voiceBaseValue = null;
        _ownsVoiceSession = false;
        _finishingVoice = false;
        _voiceLevels.clear();
      }
      widget.asrProvider?.addListener(_handleAsrChanged);
    }
  }

  String _hint(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return l10n.chatInputBarHint;
  }

  /// Returns the number of lines in the input text (minimum 1).
  int get _lineCount {
    final text = _controller.text;
    if (text.isEmpty) return 1;
    return text.split('\n').length;
  }

  /// Whether to show the expand/collapse button (when text has 3+ lines).
  bool get _showExpandButton => _lineCount >= 3;

  // ---------------------------------------------------------------------------
  // Voice input
  // ---------------------------------------------------------------------------

  Future<void> _startVoiceInput() async {
    final asr = widget.asrProvider;
    final selected = context.read<SettingsProvider>().selectedAsrService;
    if (_composerLocked ||
        widget.loading ||
        _ownsVoiceSession ||
        asr == null ||
        asr.isActive ||
        selected == null ||
        !asr.canUse(selected)) {
      return;
    }

    _voiceBaseValue = _controller.value;
    _ownsVoiceSession = true;
    _finishingVoice = false;
    _lastReportedVoiceError = null;
    _voiceLevels.clear();
    setState(() {});
    widget.focusNode?.unfocus();

    try {
      await asr.start(selected);
      if (mounted && _ownsVoiceSession && asr.isListening) {
        _startVoiceLevelSampling();
      }
    } catch (error) {
      _stopVoiceLevelSampling();
      if (!mounted) return;
      // Provider failures normally arrive through its listener first. This is
      // the fallback for errors raised before the provider can publish state.
      if (_ownsVoiceSession) {
        final original = _voiceBaseValue;
        if (original != null) _controller.value = original;
        _voiceBaseValue = null;
        _ownsVoiceSession = false;
        _finishingVoice = false;
        _voiceLevels.clear();
        setState(() {});
      }
      if (_lastReportedVoiceError == null) _reportVoiceFailure(error);
    }
  }

  void _handleAsrChanged() {
    if (!mounted || !_ownsVoiceSession) return;
    final asr = widget.asrProvider;
    if (asr == null) return;

    _applyVoiceTranscript(asr.transcript);
    final error = asr.error;
    if (error != null && error.trim().isNotEmpty) {
      _stopVoiceLevelSampling();
      _voiceBaseValue = null;
      _ownsVoiceSession = false;
      _finishingVoice = false;
      _voiceLevels.clear();
      _reportVoiceFailure(error);
      scheduleMicrotask(asr.clearError);
    } else if (!asr.isActive && !_finishingVoice) {
      // Some system recognizers publish a final result and stop on their own.
      _stopVoiceLevelSampling();
      final detectedSpeech = asr.transcript.trim().isNotEmpty;
      _voiceBaseValue = null;
      _ownsVoiceSession = false;
      _voiceLevels.clear();
      if (!detectedSpeech) _reportNoSpeech();
    }
    setState(() {});
    _ensureCaretVisible();
  }

  void _startVoiceLevelSampling() {
    _voiceLevelTimer?.cancel();
    _voiceLevelTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (!mounted || !_ownsVoiceSession || _finishingVoice) return;
      final asr = widget.asrProvider;
      if (asr?.isListening != true) return;
      final level = asr!.soundLevel.clamp(0.0, 1.0).toDouble();
      final previous = _voiceLevels.isEmpty ? 0.03 : _voiceLevels.last;
      _voiceLevels.add(previous + (level - previous) * 0.55);
      if (_voiceLevels.length > _maxVoiceLevels) _voiceLevels.removeAt(0);
      setState(() {});
    });
  }

  void _stopVoiceLevelSampling() {
    _voiceLevelTimer?.cancel();
    _voiceLevelTimer = null;
  }

  void _applyVoiceTranscript(String transcript) {
    final baseValue = _voiceBaseValue;
    if (baseValue == null) return;
    final text = _joinVoiceText(baseValue.text, transcript);
    if (_controller.text == text) return;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: TextRange.empty,
    );
  }

  String _joinVoiceText(String base, String transcript) {
    final spoken = transcript.trim();
    if (spoken.isEmpty) return base;
    if (base.isEmpty || RegExp(r'\s$').hasMatch(base)) return '$base$spoken';

    final first = spoken.substring(0, 1);
    final last = base.substring(base.length - 1);
    final punctuation = RegExp(r'^[,.;:!?，。！？、；：)\]}>》」』】…]');
    final cjk = RegExp(r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]');
    final separator =
        punctuation.hasMatch(first) || cjk.hasMatch(first) || cjk.hasMatch(last)
        ? ''
        : ' ';
    return '$base$separator$spoken';
  }

  Future<void> _cancelVoiceInput() async {
    if (!_ownsVoiceSession) return;
    _stopVoiceLevelSampling();
    final asr = widget.asrProvider;
    final original = _voiceBaseValue;
    _voiceBaseValue = null;
    _ownsVoiceSession = false;
    _finishingVoice = false;
    _voiceLevels.clear();
    if (original != null) _controller.value = original;
    if (mounted) setState(() {});
    try {
      await asr?.cancel();
    } catch (error) {
      if (mounted) _reportVoiceFailure(error);
    }
  }

  Future<void> _finishVoiceInput({required bool sendAfter}) async {
    final asr = widget.asrProvider;
    if (!_ownsVoiceSession || _finishingVoice || asr == null) return;
    _stopVoiceLevelSampling();
    _finishingVoice = true;
    setState(() {});

    try {
      final transcript = await asr.finish();
      if (!mounted) return;
      _applyVoiceTranscript(transcript);
      final detectedSpeech = transcript.trim().isNotEmpty;
      _voiceBaseValue = null;
      _ownsVoiceSession = false;
      _finishingVoice = false;
      _voiceLevels.clear();
      setState(() {});
      _ensureCaretVisible();
      if (!detectedSpeech) {
        _reportNoSpeech();
      } else if (sendAfter && _controller.text.trim().isNotEmpty) {
        await _handleSend();
      }
    } catch (error) {
      if (!mounted) return;
      if (_ownsVoiceSession) {
        _voiceBaseValue = null;
        _ownsVoiceSession = false;
        _voiceLevels.clear();
        setState(() {});
      }
      if (_lastReportedVoiceError == null) _reportVoiceFailure(error);
    } finally {
      _finishingVoice = false;
      if (mounted) setState(() {});
    }
  }

  void _reportNoSpeech() {
    if (!mounted) return;
    showAppSnackBar(
      context,
      message: AppLocalizations.of(context)!.asrServicesNoSpeechDetected,
      type: NotificationType.warning,
    );
  }

  void _reportVoiceFailure(Object error) {
    if (!mounted) return;
    final raw = error
        .toString()
        .replaceFirst(RegExp(r'^\w+(?:<[^>]+>)?:\s*'), '')
        .trim();
    if (_lastReportedVoiceError == raw) return;
    _lastReportedVoiceError = raw;
    final lower = raw.toLowerCase();
    final l10n = AppLocalizations.of(context)!;
    final message =
        lower.contains('microphone') &&
            (lower.contains('permission') ||
                lower.contains('denied') ||
                lower.contains('not granted'))
        ? l10n.asrServicesMicrophonePermissionDenied
        : lower.contains('no speech') || lower.contains('silence')
        ? l10n.asrServicesNoSpeechDetected
        : lower.contains('system') && lower.contains('unavailable')
        ? l10n.asrServicesSystemCheckFailed
        : l10n.asrServicesRecognitionFailed(raw);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showAppSnackBar(context, message: message, type: NotificationType.error);
    });
  }

  /// Bottom row shown while recording: cancel (X) — waveform — stop — send.
  Widget _buildVoiceRecordingRow(BuildContext context, ThemeData theme) {
    final l10n = AppLocalizations.of(context)!;
    final canFinish =
        widget.asrProvider?.isListening == true && !_finishingVoice;
    return Row(
      key: const ValueKey('voice'),
      children: [
        _CompactIconButton(
          tooltip: l10n.chatInputBarVoiceCancelTooltip,
          icon: Lucide.X,
          onTap: _finishingVoice ? null : () => unawaited(_cancelVoiceInput()),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 8, right: 2),
            // Match the normal action row height (32) so the input bar
            // doesn't jump when switching in/out of recording state
            child: SizedBox(
              height: 32,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  fit: StackFit.expand,
                  alignment: Alignment.center,
                  children: <Widget>[
                    ...previousChildren,
                    if (currentChild != null) currentChild,
                  ],
                ),
                child: _finishingVoice
                    ? _VoiceTranscribingIndicator(
                        key: const ValueKey('voice-transcribing-indicator'),
                        label: l10n.chatInputBarVoiceTranscribing,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.72,
                        ),
                      )
                    : _VoiceWaveform(
                        key: const ValueKey('voice-waveform'),
                        levels: _voiceLevels,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.85,
                        ),
                      ),
              ),
            ),
          ),
        ),
        // Stop: finish recording and transcribe into the input field
        _CompactIconButton(
          tooltip: l10n.chatInputBarVoiceStopTooltip,
          icon: Lucide.Square,
          onTap: canFinish
              ? () => unawaited(_finishVoiceInput(sendAfter: false))
              : null,
          childBuilder: (c) => Center(
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: c,
                borderRadius: BorderRadius.circular(3.5),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Send: transcribe and send the message right away
        _CompactSendButton(
          enabled: canFinish,
          onSend: () => unawaited(_finishVoiceInput(sendAfter: true)),
          color: theme.colorScheme.primary,
          icon: Lucide.Check,
          tooltip: l10n.chatInputBarVoiceSendTooltip,
        ),
      ],
    );
  }

  Future<void> _handleSend() async {
    if (_isSubmitting) return;
    if (_oneClickCompressing) return;
    if (_ownsVoiceSession || _finishingVoice) return;
    final text = _controller.text.trim();
    if (text.isEmpty && _images.isEmpty && _docs.isEmpty) return;
    _isSubmitting = true;
    try {
      final result =
          await widget.onSend?.call(
            ChatInputData(
              text: text,
              imagePaths: List.of(_images),
              documents: List.of(_docs),
              allowImagesApiRouting: _allowImagesApiRouting,
              extraBody: _imageGenerationExtraBody(),
            ),
          ) ??
          ChatInputSubmissionResult.rejected;
      if (!mounted) return;
      if (result == ChatInputSubmissionResult.sent ||
          result == ChatInputSubmissionResult.queued) {
        setState(() {
          _controller.clear();
          _resetMedia(images: true, docs: true);
          // The restored queued input has been consumed by this send — the
          // "restored input must not route" flag must not stick to unrelated
          // later sends on the same (non-image) model.
          _inputStatus.clearRestoredUnsupportedImagesApiRouting(
            widget.conversationId,
          );
        });
        // The content has moved into the conversation or the queue — clear
        // the draft immediately so a process death right after sending
        // cannot resurrect it (best-effort: the underlying prefs write is
        // itself async fire-and-forget).
        _clearPersistedDraft();
        // Keep focus on desktop so user can continue typing
        try {
          if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
            widget.focusNode?.requestFocus();
          }
        } catch (_) {}
      }
    } finally {
      _isSubmitting = false;
    }
  }

  Future<void> _showImageGenerationOptions() async {
    if (_composerLocked) return;
    final controller = _imageGenController;
    void onChanged() {
      if (!mounted) return;
      setState(() {});
    }

    if (MediaQuery.of(context).size.width >= AppBreakpoints.tablet) {
      await ImageGenerationOptionsSheet.show(
        context,
        controller: controller,
        onChanged: onChanged,
      );
    } else {
      await ImageGenerationOptionsSheet.showSheet(
        context,
        controller: controller,
        onChanged: onChanged,
      );
    }
  }

  void _insertNewlineAtCursor() {
    final value = _controller.value;
    final selection = value.selection;
    final text = value.text;
    if (!selection.isValid) {
      _controller.text = '$text\n';
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    } else {
      final start = selection.start;
      final end = selection.end;
      final newText = text.replaceRange(start, end, '\n');
      _controller.value = value.copyWith(
        text: newText,
        selection: TextSelection.collapsed(offset: start + 1),
        composing: TextRange.empty,
      );
    }
    setState(() {});
    _scheduleDraftSave();
    _ensureCaretVisible();
  }

  // Keep the caret visible after programmatic edits (e.g., Shift+Enter insert)
  void _ensureCaretVisible() {
    try {
      final selection = _controller.selection;
      if (!selection.isValid) return;
      final focusNode = widget.focusNode ?? Focus.maybeOf(context);
      final focusContext = focusNode?.context;
      if (focusContext == null) return;
      final editable = focusContext
          .findAncestorStateOfType<EditableTextState>();
      if (editable == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        try {
          editable.bringIntoView(selection.extent);
        } catch (_) {}
      });
    } catch (_) {}
  }

  // Instance method for contextMenuBuilder to avoid flickering caused by recreating
  // the callback on every build. See: https://github.com/flutter/flutter/issues/150551
  Widget _buildContextMenu(BuildContext context, EditableTextState state) {
    // Suppress context menu during app lifecycle transitions to avoid flickering
    if (_suppressContextMenu) {
      return const SizedBox.shrink();
    }
    if (Platform.isIOS) {
      final items = <ContextMenuButtonItem>[];
      try {
        final appL10n = AppLocalizations.of(context)!;
        final materialL10n = MaterialLocalizations.of(context);
        final value = _controller.value;
        final selection = value.selection;
        final hasSelection = selection.isValid && !selection.isCollapsed;
        final hasText = value.text.isNotEmpty;

        // Cut
        if (hasSelection) {
          items.add(
            ContextMenuButtonItem(
              onPressed: () async {
                try {
                  final start = selection.start;
                  final end = selection.end;
                  final text = value.text.substring(start, end);
                  await Clipboard.setData(ClipboardData(text: text));
                  final newText = value.text.replaceRange(start, end, '');
                  _controller.value = value.copyWith(
                    text: newText,
                    selection: TextSelection.collapsed(offset: start),
                  );
                  _scheduleDraftSave();
                } catch (_) {}
                state.hideToolbar();
              },
              label: materialL10n.cutButtonLabel,
            ),
          );
        }

        // Copy
        if (hasSelection) {
          items.add(
            ContextMenuButtonItem(
              onPressed: () async {
                try {
                  final start = selection.start;
                  final end = selection.end;
                  final text = value.text.substring(start, end);
                  await Clipboard.setData(ClipboardData(text: text));
                } catch (_) {}
                state.hideToolbar();
              },
              label: materialL10n.copyButtonLabel,
            ),
          );
        }

        // Paste (text or image via _handlePasteFromClipboard)
        items.add(
          ContextMenuButtonItem(
            onPressed: () {
              _handlePasteFromClipboard();
              state.hideToolbar();
            },
            label: materialL10n.pasteButtonLabel,
          ),
        );

        // Insert newline
        items.add(
          ContextMenuButtonItem(
            onPressed: () {
              _insertNewlineAtCursor();
              state.hideToolbar();
            },
            label: appL10n.chatInputBarInsertNewline,
          ),
        );

        // Select all
        if (hasText) {
          items.add(
            ContextMenuButtonItem(
              onPressed: () {
                try {
                  _controller.selection = TextSelection(
                    baseOffset: 0,
                    extentOffset: value.text.length,
                  );
                } catch (_) {}
                state.hideToolbar();
              },
              label: materialL10n.selectAllButtonLabel,
            ),
          );
        }
      } catch (_) {}
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: state.contextMenuAnchors,
        buttonItems: items,
      );
    }

    // Other platforms: keep default behavior.
    final items = <ContextMenuButtonItem>[...state.contextMenuButtonItems];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: items,
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // Enhance hardware keyboard behavior
    final w = MediaQuery.sizeOf(node.context!).width;
    final isTabletOrDesktop = w >= AppBreakpoints.tablet;
    final isIosTablet = Platform.isIOS && isTabletOrDesktop;

    final isDown = event is KeyDownEvent;
    final key = event.logicalKey;
    final isEnter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    final isArrow =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    final isPasteV = key == LogicalKeyboardKey.keyV;

    // Enter handling on tablet/desktop: configurable shortcut
    if (isEnter && isTabletOrDesktop) {
      if (!isDown) return KeyEventResult.handled; // ignore key up
      // Respect IME composition (e.g., Chinese Pinyin). If composing, let IME handle Enter.
      final composing = _controller.value.composing;
      final composingActive = composing.isValid && !composing.isCollapsed;
      if (composingActive) return KeyEventResult.ignored;
      final keys = HardwareKeyboard.instance.logicalKeysPressed;
      final shift =
          keys.contains(LogicalKeyboardKey.shiftLeft) ||
          keys.contains(LogicalKeyboardKey.shiftRight);
      final ctrl =
          keys.contains(LogicalKeyboardKey.controlLeft) ||
          keys.contains(LogicalKeyboardKey.controlRight);
      final meta =
          keys.contains(LogicalKeyboardKey.metaLeft) ||
          keys.contains(LogicalKeyboardKey.metaRight);
      final ctrlOrMeta = ctrl || meta;
      // Get send shortcut setting
      final sendShortcut = Provider.of<SettingsProvider>(
        node.context!,
        listen: false,
      ).desktopSendShortcut;
      if (sendShortcut == DesktopSendShortcut.ctrlEnter) {
        // Ctrl/Cmd+Enter to send, Enter to newline
        if (ctrlOrMeta) {
          unawaited(_handleSend());
        } else if (!shift) {
          _insertNewlineAtCursor();
        } else {
          // Shift+Enter also newline
          _insertNewlineAtCursor();
        }
      } else {
        // Enter to send, Shift+Enter or Ctrl/Cmd+Enter to newline (default)
        if (shift || ctrlOrMeta) {
          _insertNewlineAtCursor();
        } else {
          unawaited(_handleSend());
        }
      }
      return KeyEventResult.handled;
    }

    // Paste handling for images on iOS/macOS (tablet/desktop)
    if (isDown && isPasteV) {
      final keys = HardwareKeyboard.instance.logicalKeysPressed;
      final meta =
          keys.contains(LogicalKeyboardKey.metaLeft) ||
          keys.contains(LogicalKeyboardKey.metaRight);
      final ctrl =
          keys.contains(LogicalKeyboardKey.controlLeft) ||
          keys.contains(LogicalKeyboardKey.controlRight);
      if (meta || ctrl) {
        _handlePasteFromClipboard();
        return KeyEventResult.handled;
      }
    }

    // Arrow repeat fix only needed on iOS tablets
    if (!isIosTablet || !isArrow) return KeyEventResult.ignored;

    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final shift =
        keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
    final alt =
        keys.contains(LogicalKeyboardKey.altLeft) ||
        keys.contains(LogicalKeyboardKey.altRight) ||
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight) ||
        keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight);

    void moveOnce() {
      if (key == LogicalKeyboardKey.arrowLeft) {
        _moveCaret(-1, extend: shift, byWord: alt);
      } else if (key == LogicalKeyboardKey.arrowRight) {
        _moveCaret(1, extend: shift, byWord: alt);
      }
    }

    if (event is KeyDownEvent) {
      // Initial move
      moveOnce();
      // Start repeat timer if not already
      if (!_repeatTimers.containsKey(key)) {
        Timer? periodic;
        final starter = Timer(_repeatInitialDelay, () {
          periodic = Timer.periodic(_repeatPeriod, (_) => moveOnce());
          _repeatTimers[key] = periodic!;
        });
        // Store starter temporarily; replace when periodic begins
        _repeatTimers[key] = starter;
      }
      return KeyEventResult.handled;
    }

    if (event is KeyUpEvent) {
      // Key up -> cancel repeat
      final t = _repeatTimers.remove(key);
      try {
        t?.cancel();
      } catch (_) {}
      return KeyEventResult.handled;
    }

    return KeyEventResult.handled;
  }

  Future<void> _handlePasteFromClipboard() async {
    // 1) Prefer reading via super_clipboard for better Windows support
    try {
      final clipboard = SystemClipboard.instance;
      if (clipboard != null) {
        final reader = await clipboard.read();

        // Helper: read bytes for a given file format from DataReader (ClipboardReader or item)
        Future<Uint8List?> readFileBytes(
          DataReader dataReader,
          FileFormat format,
        ) async {
          try {
            final completer = Completer<Uint8List?>();
            final progress = dataReader.getFile(
              format,
              (file) async {
                try {
                  final bytes = await file.readAll();
                  if (!completer.isCompleted) completer.complete(bytes);
                } catch (e) {
                  if (!completer.isCompleted) completer.completeError(e);
                }
              },
              onError: (e) {
                if (!completer.isCompleted) completer.completeError(e);
              },
            );
            if (progress == null) {
              if (!completer.isCompleted) completer.complete(null);
            }
            return await completer.future;
          } catch (_) {
            return null;
          }
        }

        // Helper: persist bytes as a file under upload directory
        Future<String?> saveImageBytes(String format, Uint8List bytes) async {
          try {
            final dir = await AppDirectories.getUploadDirectory();
            if (!await dir.exists()) {
              await dir.create(recursive: true);
            }
            final ts = DateTime.now().millisecondsSinceEpoch;
            final ext = format.toLowerCase();
            final fileExt = ext == 'jpeg' ? 'jpg' : ext;
            String name = 'paste_$ts.$fileExt';
            String destPath = p.join(dir.path, name);
            if (await File(destPath).exists()) {
              name =
                  'paste_${ts}_${DateTime.now().microsecondsSinceEpoch}.$fileExt';
              destPath = p.join(dir.path, name);
            }
            await File(destPath).writeAsBytes(bytes, flush: true);
            return destPath;
          } catch (_) {
            return null;
          }
        }

        // Try aggregated formats in priority: png > jpeg > gif > webp
        Uint8List? bytes;
        String? fmt;
        if (reader.canProvide(Formats.png)) {
          bytes = await readFileBytes(reader, Formats.png);
          fmt = 'png';
        }
        bytes ??= reader.canProvide(Formats.jpeg)
            ? await readFileBytes(reader, Formats.jpeg)
            : null;
        fmt = (bytes != null && fmt == null) ? 'jpeg' : fmt;
        if (bytes == null && reader.canProvide(Formats.gif)) {
          bytes = await readFileBytes(reader, Formats.gif);
          fmt = 'gif';
        }
        if (bytes == null && reader.canProvide(Formats.webp)) {
          bytes = await readFileBytes(reader, Formats.webp);
          fmt = 'webp';
        }

        if (bytes == null) {
          // Try per-item formats
          for (final item in reader.items) {
            if (bytes == null && item.canProvide(Formats.png)) {
              bytes = await readFileBytes(item, Formats.png);
              fmt = 'png';
            }
            if (bytes == null && item.canProvide(Formats.jpeg)) {
              bytes = await readFileBytes(item, Formats.jpeg);
              fmt = 'jpeg';
            }
            if (bytes == null && item.canProvide(Formats.gif)) {
              bytes = await readFileBytes(item, Formats.gif);
              fmt = 'gif';
            }
            if (bytes == null && item.canProvide(Formats.webp)) {
              bytes = await readFileBytes(item, Formats.webp);
              fmt = 'webp';
            }
            if (bytes != null) break;
          }
        }

        if (bytes != null && bytes.isNotEmpty && fmt != null) {
          final savedPath = await saveImageBytes(fmt, bytes);
          if (savedPath != null) {
            _addImages([savedPath]);
            return;
          }
        }

        // If clipboard has plain text via super_clipboard, paste it
        if (reader.canProvide(Formats.plainText)) {
          try {
            final String? text = await reader.readValue(Formats.plainText);
            if (text != null && text.isNotEmpty) {
              final value = _controller.value;
              final sel = value.selection;
              if (!sel.isValid) {
                _controller.text = value.text + text;
                _controller.selection = TextSelection.collapsed(
                  offset: _controller.text.length,
                );
              } else {
                final start = sel.start;
                final end = sel.end;
                final newText = value.text.replaceRange(start, end, text);
                _controller.value = value.copyWith(
                  text: newText,
                  selection: TextSelection.collapsed(
                    offset: start + text.length,
                  ),
                  composing: TextRange.empty,
                );
              }
              setState(() {});
              _scheduleDraftSave();
              return;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}

    // 2) Fallback: legacy platform channel image handling
    final imageTempPaths = await ClipboardImages.getImagePaths();
    if (imageTempPaths.isNotEmpty) {
      final persisted = await _persistClipboardImages(imageTempPaths);
      if (persisted.isNotEmpty) {
        _addImages(persisted);
      }
      return;
    }

    // 3) Try files via platform channel on desktop (Finder/Explorer copies)
    bool handledFiles = false;
    try {
      if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
        final filePaths = await ClipboardImages.getFilePaths();
        if (filePaths.isNotEmpty) {
          final saved = await _copyFilesToUpload(filePaths);
          if (saved.images.isNotEmpty) _addImages(saved.images);
          if (saved.docs.isNotEmpty) _addFiles(saved.docs);
          handledFiles = saved.images.isNotEmpty || saved.docs.isNotEmpty;
        }
      }
    } catch (_) {}
    if (handledFiles) return;

    // 4) Last resort: paste text via Flutter Clipboard API
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (text.isEmpty) return;
      final value = _controller.value;
      final sel = value.selection;
      if (!sel.isValid) {
        _controller.text = value.text + text;
        _controller.selection = TextSelection.collapsed(
          offset: _controller.text.length,
        );
      } else {
        final start = sel.start;
        final end = sel.end;
        final newText = value.text.replaceRange(start, end, text);
        _controller.value = value.copyWith(
          text: newText,
          selection: TextSelection.collapsed(offset: start + text.length),
          composing: TextRange.empty,
        );
      }
      setState(() {});
      _scheduleDraftSave();
    } catch (_) {}
  }

  // Copy arbitrary files to upload directory (without deleting the source),
  // split into images and document attachments.
  Future<({List<String> images, List<DocumentAttachment> docs})>
  _copyFilesToUpload(List<String> srcPaths) async {
    final images = <String>[];
    final docs = <DocumentAttachment>[];
    try {
      final dir = await AppDirectories.getUploadDirectory();
      for (final raw in srcPaths) {
        if (!mounted) {
          return (images: images, docs: docs);
        }
        final src = raw.startsWith('file://') ? raw.substring(7) : raw;
        final savedPath = await FileImportHelper.copyXFile(
          XFile(src),
          dir,
          context,
        );
        if (savedPath != null) {
          final savedName = p.basename(savedPath);
          if (_isImageExtension(savedName)) {
            images.add(savedPath);
          } else {
            final mime = _inferMimeByExtension(savedName);
            docs.add(
              DocumentAttachment(
                path: savedPath,
                fileName: savedName,
                mime: mime,
              ),
            );
          }
        }
      }
    } catch (_) {}
    return (images: images, docs: docs);
  }

  Widget _buildMultiAIBadge(BuildContext context, int count) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: widget.onMultiSelectModel,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: cs.primaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.primary.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Lucide.Boxes, size: 14, color: cs.onPrimaryContainer),
            const SizedBox(width: 4),
            Text(
              l10n.multiAIModelsBadge(count),
              style: TextStyle(
                fontSize: 12,
                fontWeight: AppFontWeights.semibold,
                color: cs.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Build a responsive left action bar that hides overflowing actions
  // into an anchored "+" menu using DesktopContextMenu style.
  Widget _buildResponsiveLeftActions(BuildContext context) {
    const double spacing = 8;
    const double normalButtonW = 32; // 20 + padding(6*2)
    const double modelButtonW = 30; // 28 + padding(1*2)
    const double plusButtonW = 32;

    final l10n = AppLocalizations.of(context)!;
    VoidCallback? lockTap(VoidCallback? callback) {
      if (_composerLocked) return null;
      return callback;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final List<_OverflowAction> actions = [];

        final isGroupChat = widget.mode == ChatInputMode.groupChat;

        // Model select (hidden in group chat)
        final modelCount = widget.multiAIModelCount;
        final isMultiAILocked = modelCount != null && modelCount >= 2;
        if (!isGroupChat) {
          actions.add(
            _OverflowAction(
              width: isMultiAILocked
                  ? modelButtonW + 32
                  : (widget.modelIcon != null)
                  ? modelButtonW
                  : normalButtonW,
              builder: () => isMultiAILocked
                  ? _buildMultiAIBadge(context, modelCount)
                  : _CompactIconButton(
                      tooltip: l10n.chatInputBarSelectModelTooltip,
                      icon: Lucide.Boxes,
                      modelIcon: true,
                      onTap: lockTap(widget.onSelectModel),
                      onLongPress: lockTap(widget.onLongPressSelectModel),
                      child: widget.modelIcon,
                    ),
              menu: isMultiAILocked
                  ? DesktopContextMenuItem(
                      icon: Lucide.Boxes,
                      label: l10n.multiAIModelsBadge(modelCount),
                      onTap: widget.onMultiSelectModel,
                    )
                  : DesktopContextMenuItem(
                      icon: Lucide.Boxes,
                      label: l10n.chatInputBarSelectModelTooltip,
                      onTap: lockTap(widget.onSelectModel),
                    ),
            ),
          );
        }

        // Search button (stateful icon depending on provider config)
        final settings = context.watch<SettingsProvider>();
        final ap = context.watch<AssistantProvider>();
        final a = ap.currentAssistant;
        final currentProviderKey =
            a?.chatModelProvider ?? settings.currentModelProvider;
        final currentModelId = a?.chatModelId ?? settings.currentModelId;
        final cfg = (currentProviderKey != null)
            ? settings.getProviderConfig(currentProviderKey)
            : null;
        // Check built-in tools state using helper
        final toolsState = BuiltInToolsHelper.getActiveTools(
          cfg: cfg,
          modelId: currentModelId,
        );
        final builtinSearchActive = toolsState.searchActive;
        final appSearchEnabled = ap.currentSearchEnabled;
        final brandAsset = (() {
          if (!appSearchEnabled || builtinSearchActive) return null;
          final services = settings.searchServices;
          final sel = settings.searchServiceSelected.clamp(
            0,
            services.isNotEmpty ? services.length - 1 : 0,
          );
          final options = services.isNotEmpty
              ? services[sel]
              : SearchServiceOptions.defaultOption;
          final svc = SearchService.getService(options);
          return BrandAssets.assetForName(svc.name);
        })();

        // Search button (hidden in group chat)
        if (!isGroupChat) {
          actions.add(
            _OverflowAction(
              width: normalButtonW,
              builder: () {
                // Not enabled at all -> default globe
                if (!appSearchEnabled && !builtinSearchActive) {
                  return _CompactIconButton(
                    tooltip: l10n.chatInputBarOnlineSearchTooltip,
                    icon: Lucide.Globe,
                    active: false,
                    onTap: lockTap(widget.onOpenSearch),
                  );
                }
                // Built-in search -> magnifier icon in theme color
                if (builtinSearchActive) {
                  return _CompactIconButton(
                    tooltip: l10n.chatInputBarOnlineSearchTooltip,
                    icon: Lucide.Search,
                    active: true,
                    onTap: lockTap(widget.onOpenSearch),
                  );
                }
                // External provider search -> brand icon
                return _CompactIconButton(
                  tooltip: l10n.chatInputBarOnlineSearchTooltip,
                  icon: Lucide.Globe,
                  active: true,
                  onTap: lockTap(widget.onOpenSearch),
                  childBuilder: (c) {
                    final asset = brandAsset;
                    if (asset != null) {
                      if (asset.endsWith('.svg')) {
                        return SvgPicture.asset(
                          asset,
                          width: 20,
                          height: 20,
                          colorFilter: ColorFilter.mode(c, BlendMode.srcIn),
                        );
                      } else {
                        return Image.asset(
                          asset,
                          width: 20,
                          height: 20,
                          color: c,
                          colorBlendMode: BlendMode.srcIn,
                        );
                      }
                    } else {
                      return Icon(Lucide.Globe, size: 20, color: c);
                    }
                  },
                );
              },
              menu: () {
                // Prefer vector icon if brandAsset is svg, otherwise pick reasonable default
                if (!appSearchEnabled && !builtinSearchActive) {
                  return DesktopContextMenuItem(
                    icon: Lucide.Globe,
                    label: l10n.chatInputBarOnlineSearchTooltip,
                    onTap: lockTap(widget.onOpenSearch),
                  );
                }
                if (builtinSearchActive) {
                  return DesktopContextMenuItem(
                    icon: Lucide.Search,
                    label: l10n.chatInputBarOnlineSearchTooltip,
                    onTap: lockTap(widget.onOpenSearch),
                  );
                }
                if (brandAsset != null && brandAsset.endsWith('.svg')) {
                  return DesktopContextMenuItem(
                    svgAsset: brandAsset,
                    label: l10n.chatInputBarOnlineSearchTooltip,
                    onTap: lockTap(widget.onOpenSearch),
                  );
                }
                return DesktopContextMenuItem(
                  icon: Lucide.Globe,
                  label: l10n.chatInputBarOnlineSearchTooltip,
                  onTap: lockTap(widget.onOpenSearch),
                );
              }(),
            ),
          );
        }

        // Group chat never consumes image generation options (member streams
        // build requests from message content only) — hide the palette there.
        if (_imageModeActive && !isGroupChat) {
          actions.add(
            _OverflowAction(
              width: normalButtonW,
              builder: () => _CompactIconButton(
                tooltip: l10n.imageGenPaletteTooltip(_imageParamsSummary),
                icon: Lucide.Palette,
                active: _imageParamsCustomized,
                onTap: lockTap(() => unawaited(_showImageGenerationOptions())),
              ),
              menu: DesktopContextMenuItem(
                icon: Lucide.Palette,
                label: l10n.imageGenPaletteTooltip(_imageParamsSummary),
                onTap: lockTap(() => unawaited(_showImageGenerationOptions())),
              ),
            ),
          );
        }

        if (widget.supportsReasoning && !isGroupChat) {
          actions.add(
            _OverflowAction(
              width: normalButtonW,
              builder: () => _CompactIconButton(
                tooltip: l10n.chatInputBarReasoningStrengthTooltip,
                icon: Lucide.Brain,
                active: widget.reasoningActive,
                onTap: lockTap(widget.onConfigureReasoning),
                childBuilder: (c) => ReasoningIcons.budgetIcon(
                  widget.reasoningBudget,
                  size: 20,
                  color: c,
                ),
              ),
              menu: DesktopContextMenuItem(
                svgAsset: ReasoningIcons.assetForBudget(widget.reasoningBudget),
                label: l10n.chatInputBarReasoningStrengthTooltip,
                onTap: lockTap(widget.onConfigureReasoning),
              ),
            ),
          );
        }

        // MCP button
        if (widget.showMcpButton) {
          actions.add(
            _OverflowAction(
              width: normalButtonW,
              builder: () => _CompactIconButton(
                tooltip: l10n.chatInputBarMcpServersTooltip,
                icon: Lucide.Hammer,
                active: widget.mcpActive,
                onTap: lockTap(widget.onOpenMcp),
                onLongPress: lockTap(widget.onLongPressMcp),
              ),
              menu: DesktopContextMenuItem(
                icon: Lucide.Hammer,
                label: l10n.chatInputBarMcpServersTooltip,
                onTap: lockTap(widget.onOpenMcp),
              ),
            ),
          );
        }

        if (widget.showQuickPhraseButton && widget.onQuickPhrase != null) {
          actions.add(
            _OverflowAction(
              width: normalButtonW,
              builder: () => _CompactIconButton(
                tooltip: l10n.chatInputBarQuickPhraseTooltip,
                icon: Lucide.Zap,
                onTap: lockTap(widget.onQuickPhrase),
                onLongPress: lockTap(widget.onLongPressQuickPhrase),
              ),
              menu: DesktopContextMenuItem(
                icon: Lucide.Zap,
                label: l10n.chatInputBarQuickPhraseTooltip,
                onTap: lockTap(widget.onQuickPhrase),
              ),
            ),
          );
        }

        if (widget.onPickCamera != null) {
          actions.add(
            _OverflowAction(
              width: normalButtonW,
              builder: () => _CompactIconButton(
                tooltip: l10n.bottomToolsSheetCamera,
                icon: Lucide.Camera,
                onTap: lockTap(widget.onPickCamera),
              ),
              menu: DesktopContextMenuItem(
                icon: Lucide.Camera,
                label: l10n.bottomToolsSheetCamera,
                onTap: lockTap(widget.onPickCamera),
              ),
            ),
          );
        }

        if (widget.onPickPhotos != null) {
          actions.add(
            _OverflowAction(
              width: normalButtonW,
              builder: () => _CompactIconButton(
                tooltip: l10n.bottomToolsSheetPhotos,
                icon: Lucide.Image,
                onTap: lockTap(widget.onPickPhotos),
              ),
              menu: DesktopContextMenuItem(
                icon: Lucide.Image,
                label: l10n.bottomToolsSheetPhotos,
                onTap: lockTap(widget.onPickPhotos),
              ),
            ),
          );
        }

        if (widget.onUploadFiles != null) {
          actions.add(
            _OverflowAction(
              width: normalButtonW,
              builder: () => _CompactIconButton(
                tooltip: l10n.bottomToolsSheetUpload,
                icon: Lucide.Paperclip,
                onTap: lockTap(widget.onUploadFiles),
              ),
              menu: DesktopContextMenuItem(
                icon: Lucide.Paperclip,
                label: l10n.bottomToolsSheetUpload,
                onTap: lockTap(widget.onUploadFiles),
              ),
            ),
          );
        }

        if (widget.onToggleLearningMode != null) {
          actions.add(
            _OverflowAction(
              width: normalButtonW,
              builder: () => _CompactIconButton(
                tooltip: l10n.instructionInjectionTitle,
                icon: Lucide.Layers,
                active: widget.learningModeActive,
                onTap: lockTap(widget.onToggleLearningMode),
                onLongPress: lockTap(widget.onLongPressLearning),
              ),
              menu: DesktopContextMenuItem(
                icon: Lucide.Layers,
                label: l10n.instructionInjectionTitle,
                onTap: lockTap(widget.onToggleLearningMode),
              ),
            ),
          );
        }

        if (widget.onOpenWorldBook != null) {
          actions.add(
            _OverflowAction(
              width: normalButtonW,
              builder: () => _CompactIconButton(
                tooltip: l10n.worldBookTitle,
                icon: Lucide.BookOpen,
                active: widget.worldBookActive,
                onTap: lockTap(widget.onOpenWorldBook),
              ),
              menu: DesktopContextMenuItem(
                icon: Lucide.BookOpen,
                label: l10n.worldBookTitle,
                onTap: lockTap(widget.onOpenWorldBook),
              ),
            ),
          );
        }

        if (widget.onOpenSkills != null) {
          actions.add(
            _OverflowAction(
              width: normalButtonW,
              builder: () => _CompactIconButton(
                tooltip: l10n.skillsTitle,
                icon: Lucide.Sparkles,
                active: widget.skillsActive,
                onTap: lockTap(widget.onOpenSkills),
              ),
              menu: DesktopContextMenuItem(
                icon: Lucide.Sparkles,
                label: l10n.skillsTitle,
                onTap: lockTap(widget.onOpenSkills),
              ),
            ),
          );
        }

        if (widget.onClearContext != null) {
          void showContextMenu() {
            showDesktopAnchoredMenu(
              context,
              anchorKey: _contextMgmtAnchorKey,
              items: [
                if (widget.onCompressContext != null)
                  DesktopContextMenuItem(
                    icon: Lucide.package2,
                    label: l10n.compressContext,
                    onTap: lockTap(widget.onCompressContext),
                  ),
                DesktopContextMenuItem(
                  icon: Lucide.Eraser,
                  label: l10n.bottomToolsSheetClearContext,
                  onTap: lockTap(widget.onClearContext),
                ),
              ],
            );
          }

          actions.add(
            _OverflowAction(
              width: normalButtonW,
              builder: () => Container(
                key: _contextMgmtAnchorKey,
                child: _CompactIconButton(
                  tooltip: l10n.contextManagement,
                  icon: Lucide.Eraser,
                  onTap: _composerLocked ? null : showContextMenu,
                ),
              ),
              menu: DesktopContextMenuItem(
                icon: Lucide.Eraser,
                label: l10n.contextManagement,
                onTap: _composerLocked ? null : showContextMenu,
              ),
            ),
          );
        }

        if (widget.showMiniMapButton) {
          actions.add(
            _OverflowAction(
              width: normalButtonW,
              builder: () => _CompactIconButton(
                tooltip: l10n.miniMapTooltip,
                icon: Lucide.Map,
                onTap: lockTap(widget.onOpenMiniMap),
              ),
              menu: DesktopContextMenuItem(
                icon: Lucide.Map,
                label: l10n.miniMapTooltip,
                onTap: lockTap(widget.onOpenMiniMap),
              ),
            ),
          );
        }

        if (widget.showDocumentProcessingButton &&
            widget.onDocumentProcessing != null) {
          actions.add(
            _OverflowAction(
              width: normalButtonW,
              builder: () => _CompactIconButton(
                tooltip: l10n.documentProcessingTitle,
                icon: Lucide.FileText,
                active: false,
                onTap: lockTap(widget.onDocumentProcessing),
              ),
              menu: DesktopContextMenuItem(
                icon: Lucide.FileText,
                label: l10n.documentProcessingTitle,
                onTap: lockTap(widget.onDocumentProcessing),
              ),
            ),
          );
        }

        // Compute total width with spacing to see if overflow is needed
        double full = 0;
        for (var i = 0; i < actions.length; i++) {
          if (i > 0) full += spacing;
          full += actions[i].width;
        }

        final maxW = constraints.maxWidth;
        int visibleCount = actions.length;
        if (full > maxW) {
          // First pass: include as many as possible ignoring the +
          double used = 0;
          visibleCount = 0;
          for (var i = 0; i < actions.length; i++) {
            final add = (visibleCount > 0 ? spacing : 0) + actions[i].width;
            if (used + add <= maxW) {
              used += add;
              visibleCount++;
            } else {
              break;
            }
          }
          // Ensure + button fits; remove items until it does
          while (visibleCount > 0 && used + spacing + plusButtonW > maxW) {
            // remove last
            used -= actions[visibleCount - 1].width;
            if (visibleCount - 1 > 0) used -= spacing;
            visibleCount--;
          }
        }

        final overflowItems = actions.sublist(visibleCount);

        final children = <Widget>[];
        for (var i = 0; i < visibleCount; i++) {
          if (i > 0) children.add(const SizedBox(width: spacing));
          children.add(actions[i].builder());
        }

        if (overflowItems.isNotEmpty) {
          if (children.isNotEmpty) children.add(const SizedBox(width: spacing));
          final menuItems = overflowItems
              .map((e) => e.menu)
              .toList(growable: false);
          children.add(
            Container(
              key: _leftOverflowAnchorKey,
              child: _CompactIconButton(
                tooltip: l10n.chatInputBarMoreTooltip,
                icon: Lucide.Plus,
                onTap: () {
                  showDesktopAnchoredMenu(
                    context,
                    anchorKey: _leftOverflowAnchorKey,
                    items: menuItems,
                  );
                },
              ),
            ),
          );
        }

        return Row(children: children);
      },
    );
  }

  String _inferMimeByExtension(String name) {
    final mediaMime = inferMediaMimeFromSource(name);
    if (mediaMime.isNotEmpty) return mediaMime;
    final lower = name.toLowerCase();
    // Documents / text
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.docx')) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.js')) return 'application/javascript';
    if (lower.endsWith('.txt') ||
        lower.endsWith('.md') ||
        lower.endsWith('.markdown') ||
        lower.endsWith('.mdx')) {
      return 'text/plain';
    }
    if (lower.endsWith('.html') || lower.endsWith('.htm')) return 'text/html';
    if (lower.endsWith('.xml')) return 'application/xml';
    if (lower.endsWith('.yml') || lower.endsWith('.yaml')) {
      return 'application/x-yaml';
    }
    if (lower.endsWith('.py')) return 'text/x-python';
    if (lower.endsWith('.java')) return 'text/x-java-source';
    if (lower.endsWith('.kt') || lower.endsWith('.kts')) return 'text/x-kotlin';
    if (lower.endsWith('.dart')) return 'text/x-dart';
    if (lower.endsWith('.ts')) return 'text/typescript';
    if (lower.endsWith('.tsx')) return 'text/tsx';
    return 'application/octet-stream';
  }

  bool _isImageExtension(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.heic') ||
        lower.endsWith('.heif');
  }

  Future<List<String>> _persistClipboardImages(List<String> srcPaths) async {
    try {
      final dir = await AppDirectories.getUploadDirectory();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final out = <String>[];
      int i = 0;
      for (var raw in srcPaths) {
        try {
          // Normalize path (strip file:// if present)
          final src = raw.startsWith('file://') ? raw.substring(7) : raw;
          // If already under upload directory, just keep it
          if (src.contains('/upload/') || src.contains('\\upload\\')) {
            out.add(src);
            continue;
          }
          final ext = p.extension(src).isNotEmpty ? p.extension(src) : '.png';
          final name =
              'paste_${DateTime.now().millisecondsSinceEpoch}_${i++}$ext';
          final destPath = p.join(dir.path, name);
          final from = File(src);
          if (await from.exists()) {
            await File(destPath).writeAsBytes(await from.readAsBytes());
            // Best-effort cleanup of the temporary source
            try {
              await from.delete();
            } catch (_) {}
            out.add(destPath);
          }
        } catch (_) {
          // skip single file errors
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  void _moveCaret(int dir, {bool extend = false, bool byWord = false}) {
    final text = _controller.text;
    if (text.isEmpty) return;
    TextSelection sel = _controller.selection;
    if (!sel.isValid) {
      final off = dir < 0 ? text.length : 0;
      _controller.selection = TextSelection.collapsed(offset: off);
      return;
    }

    int nextOffset(int from, int direction) {
      if (!byWord) return (from + direction).clamp(0, text.length);
      // Move by simple word boundary: skip whitespace; then skip non-whitespace
      int i = from;
      if (direction < 0) {
        // Move left
        while (i > 0 && text[i - 1].trim().isEmpty) {
          i--;
        }
        while (i > 0 && text[i - 1].trim().isNotEmpty) {
          i--;
        }
      } else {
        // Move right
        while (i < text.length && text[i].trim().isEmpty) {
          i++;
        }
        while (i < text.length && text[i].trim().isNotEmpty) {
          i++;
        }
      }
      return i.clamp(0, text.length);
    }

    if (extend) {
      final newExtent = nextOffset(sel.extentOffset, dir);
      _controller.selection = sel.copyWith(extentOffset: newExtent);
    } else {
      final base = dir < 0 ? sel.start : sel.end;
      final collapsed = nextOffset(base, dir);
      _controller.selection = TextSelection.collapsed(offset: collapsed);
    }
    setState(() {});
  }

  Widget _buildInlineAttachmentPreviews(BuildContext context, bool isDark) {
    final theme = Theme.of(context);
    final previewFill = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : theme.colorScheme.onSurface.withValues(alpha: 0.045);
    final previewBorder = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : theme.colorScheme.outline.withValues(alpha: 0.13);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.xxs,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_images.isNotEmpty)
            SizedBox(
              key: const ValueKey('chat-input-image-previews'),
              height: _imagePreviewHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount:
                    _images.length +
                    (!_oneClickCompressDone &&
                            context
                                .read<SettingsProvider>()
                                .oneClickCompressEnabled
                        ? 1
                        : 0),
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, idx) {
                  if (idx == _images.length) {
                    return _buildOneClickCompressTrailing(isDark);
                  }
                  final path = _images[idx];
                  final size = _imageSizes[path] ?? 0;
                  return IgnorePointer(
                    ignoring: _oneClickCompressing,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: previewBorder, width: 1),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(9),
                            child: Image.file(
                              File(path),
                              width: 64,
                              height: 64,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                width: 64,
                                height: 64,
                                color: previewFill,
                                child: Icon(
                                  Icons.broken_image,
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.45,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        // File size overlay — tappable to open compression dialog
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: GestureDetector(
                            onTap: () => _openCompressionDialog(idx),
                            child: Container(
                              height: 18,
                              decoration: BoxDecoration(
                                borderRadius: const BorderRadius.only(
                                  bottomLeft: Radius.circular(9),
                                  bottomRight: Radius.circular(9),
                                ),
                                gradient: LinearGradient(
                                  begin: Alignment.bottomCenter,
                                  end: Alignment.topCenter,
                                  colors: [
                                    Colors.black.withValues(alpha: 0.55),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Lucide.ImageDown,
                                    size: 10,
                                    color: Colors.white.withValues(alpha: 0.85),
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    formatBytes(size),
                                    style: const TextStyle(
                                      fontSize: 9,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 4,
                          top: 4,
                          child: IosCardPress(
                            key: ValueKey('chat-input-image-remove:$idx'),
                            haptics: false,
                            baseColor: isDark
                                ? Colors.black.withValues(alpha: 0.50)
                                : Colors.black.withValues(alpha: 0.46),
                            pressedScale: 0.94,
                            borderRadius: BorderRadius.circular(
                              _imageRemoveButtonSize / 2,
                            ),
                            padding: EdgeInsets.zero,
                            duration: const Duration(milliseconds: 140),
                            onTap: () => _removeImageAt(idx),
                            child: const SizedBox(
                              width: _imageRemoveButtonSize,
                              height: _imageRemoveButtonSize,
                              child: Icon(
                                Icons.close,
                                size: 11,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          if (_images.isNotEmpty && _docs.isNotEmpty)
            const SizedBox(height: AppSpacing.xs),
          if (_docs.isNotEmpty)
            SizedBox(
              key: const ValueKey('chat-input-document-previews'),
              height: _documentPreviewHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _docs.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, idx) {
                  final d = _docs[idx];
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: previewFill,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: previewBorder, width: 1),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.insert_drive_file,
                          size: 18,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.72,
                          ),
                        ),
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 180),
                          child: Text(
                            d.fileName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: theme.colorScheme.onSurface,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(width: 3),
                        IosIconButton(
                          key: ValueKey('chat-input-document-remove:$idx'),
                          icon: Icons.close,
                          size: 16,
                          padding: const EdgeInsets.all(3),
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.58,
                          ),
                          onTap: () => _removeDocumentAt(idx),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  /// Cheap PNG alpha detection via IHDR color type byte (offset 25).
  /// Returns true for color types 4 (grayscale+alpha) and 6 (RGBA).
  /// Avoids a full image decode just to check transparency.
  Future<bool> _pngHasAlpha(String path) async {
    try {
      final file = await File(path).open(mode: FileMode.read);
      try {
        await file.setPosition(25);
        final colorType = await file.readByte();
        return colorType == 4 || colorType == 6;
      } finally {
        await file.close();
      }
    } catch (_) {
      return false;
    }
  }

  void _onOneClickTap() {
    if (_oneClickConfirming) {
      _confirmTimer?.cancel();
      _oneClickConfirming = false;
      setState(() => _oneClickCompressing = true);
      unawaited(_oneClickCompressAll());
    } else {
      setState(() => _oneClickConfirming = true);
      _confirmTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _oneClickConfirming = false);
      });
    }
  }

  Widget _buildOneClickCompressTrailing(bool isDark) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    if (_oneClickCompressing) {
      return Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.10)
                : theme.colorScheme.outline.withValues(alpha: 0.13),
            width: 1,
          ),
        ),
        child: const Center(child: CupertinoActivityIndicator(radius: 10)),
      );
    }
    if (_oneClickConfirming) {
      return GestureDetector(
        onTap: _onOneClickTap,
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.10)
                  : theme.colorScheme.outline.withValues(alpha: 0.13),
              width: 1,
            ),
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Text(
                l10n.oneClickCompressConfirmPrompt,
                style: TextStyle(
                  fontSize: 10,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      );
    }
    return Tooltip(
      message: l10n.oneClickCompressTooltip,
      child: IosCardPress(
        haptics: false,
        borderRadius: BorderRadius.circular(10),
        baseColor: Colors.transparent,
        pressedScale: 0.94,
        duration: const Duration(milliseconds: 140),
        onTap: _onOneClickTap,
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.10)
                  : theme.colorScheme.outline.withValues(alpha: 0.13),
              width: 1,
            ),
          ),
          child: Icon(
            Lucide.Zap,
            size: 22,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = context.watch<SettingsProvider>();
    final selectedAsrService = settings.selectedAsrService;
    final asr = widget.asrProvider;
    final showVoiceInput =
        asr != null &&
        selectedAsrService != null &&
        asr.canUse(selectedAsrService) &&
        !asr.isActive;
    final isDark = theme.brightness == Brightness.dark;
    final inputFillColor = _inputFillColor(
      theme: theme,
      backgroundImageActive: widget.backgroundImageActive,
      lightOpacity: widget.inputBackgroundOpacityLight,
      darkOpacity: widget.inputBackgroundOpacityDark,
    );
    final hasText = _controller.text.trim().isNotEmpty;
    final hasImages = _images.isNotEmpty;
    final hasDocs = _docs.isNotEmpty;
    _supportsImagesApiRouting(context);
    _checkImageWarning(context);
    final size = MediaQuery.sizeOf(context);
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final bool isMobileLayout = size.width < AppBreakpoints.tablet;
    final double visibleHeight = size.height - viewInsets.bottom;
    final double attachmentPreviewHeight = (hasDocs || hasImages)
        ? AppSpacing.sm +
              (hasImages ? _imagePreviewHeight : 0) +
              (hasImages && hasDocs ? AppSpacing.xs : 0) +
              (hasDocs ? _documentPreviewHeight : 0) +
              AppSpacing.xxs
        : 0;
    const double baseChromeHeight = 120; // padding + action row + chrome buffer
    double maxInputHeight = double.infinity;
    if (isMobileLayout) {
      final double available =
          visibleHeight - attachmentPreviewHeight - baseChromeHeight;
      final double softCap = visibleHeight * 0.45;
      if (available > 0) {
        maxInputHeight = math.min(softCap, available);
        maxInputHeight = math.min(available, math.max(80.0, maxInputHeight));
      } else {
        maxInputHeight = math.max(80.0, softCap);
      }
    }
    // Cap text field height on mobile so expanded input stays above the keyboard.
    final BoxConstraints textFieldConstraints =
        (isMobileLayout && maxInputHeight.isFinite && maxInputHeight > 0)
        ? BoxConstraints(maxHeight: maxInputHeight)
        : const BoxConstraints();

    return SafeArea(
      top: false,
      left: false,
      right: false,
      bottom: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.sm,
          AppSpacing.xxs,
          AppSpacing.sm,
          AppSpacing.xs,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.hasQueuedInput) ...[
              _QueuedInputBanner(
                label: AppLocalizations.of(context)!.chatInputBarQueuedPending,
                previewText: widget.queuedPreviewText,
                cancelLabel: AppLocalizations.of(
                  context,
                )!.chatInputBarQueuedCancel,
                onCancel: widget.onCancelQueuedInput,
              ),
              const SizedBox(height: AppSpacing.xs),
            ],
            Stack(
              clipBehavior: Clip.none,
              children: [
                // Main input container with iOS-like frosted glass effect
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    child: Container(
                      decoration: BoxDecoration(
                        // Translucent background over blurred content
                        color: inputFillColor,
                        borderRadius: BorderRadius.circular(20),
                        // Use previous gray border for better contrast on white
                        border: Border.all(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.10)
                              : theme.colorScheme.outline.withValues(
                                  alpha: 0.20,
                                ),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        children: [
                          if (hasDocs || hasImages)
                            _buildInlineAttachmentPreviews(context, isDark),
                          // Input field with expand/collapse button
                          Stack(
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  AppSpacing.md,
                                  AppSpacing.xxs,
                                  AppSpacing.md,
                                  AppSpacing.xs,
                                ),
                                child: ConstrainedBox(
                                  constraints: textFieldConstraints,
                                  child: Focus(
                                    onKeyEvent: _handleKeyEvent,
                                    child: Builder(
                                      builder: (ctx) {
                                        // Desktop: show a right-click context menu with paste/cut/copy/select all
                                        // Future<void> _showDesktopContextMenu(Offset globalPos) async {
                                        //   bool isDesktop = false;
                                        //   try { isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux; } catch (_) {}
                                        //   if (!isDesktop) return;
                                        //   // Ensure input has focus so operations apply correctly
                                        //   try { widget.focusNode?.requestFocus(); } catch (_) {}
                                        //
                                        //   final sel = _controller.selection;
                                        //   final hasSelection = sel.isValid && !sel.isCollapsed;
                                        //   final hasText = _controller.text.isNotEmpty;
                                        //
                                        //   final l10n = MaterialLocalizations.of(ctx);
                                        //   await showDesktopContextMenuAt(
                                        //     ctx,
                                        //     globalPosition: globalPos,
                                        //     items: [
                                        //       DesktopContextMenuItem(
                                        //         icon: Lucide.Clipboard,
                                        //         label: l10n.pasteButtonLabel,
                                        //         onTap: () async {
                                        //           await _handlePasteFromClipboard();
                                        //         },
                                        //       ),
                                        //       DesktopContextMenuItem(
                                        //         icon: Lucide.Cut,
                                        //         label: l10n.cutButtonLabel,
                                        //         onTap: () async {
                                        //           final s = _controller.selection;
                                        //           if (s.isValid && !s.isCollapsed) {
                                        //             final text = _controller.text.substring(s.start, s.end);
                                        //             try { await Clipboard.setData(ClipboardData(text: text)); } catch (_) {}
                                        //             final newText = _controller.text.replaceRange(s.start, s.end, '');
                                        //             _controller.value = TextEditingValue(
                                        //               text: newText,
                                        //               selection: TextSelection.collapsed(offset: s.start),
                                        //             );
                                        //             setState(() {});
                                        //           }
                                        //         },
                                        //       ),
                                        //       DesktopContextMenuItem(
                                        //         icon: Lucide.Copy,
                                        //         label: l10n.copyButtonLabel,
                                        //         onTap: () async {
                                        //           final s2 = _controller.selection;
                                        //           if (s2.isValid && !s2.isCollapsed) {
                                        //             final text = _controller.text.substring(s2.start, s2.end);
                                        //             try { await Clipboard.setData(ClipboardData(text: text)); } catch (_) {}
                                        //           }
                                        //         },
                                        //       ),
                                        //       // DesktopContextMenuItem(
                                        //       //   // icon: Lucide.TextSelect,
                                        //       //   label: l10n.selectAllButtonLabel,
                                        //       //   onTap: () {
                                        //       //     if (hasText) {
                                        //       //       _controller.selection = TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
                                        //       //       setState(() {});
                                        //       //     }
                                        //       //   },
                                        //       // ),
                                        //     ],
                                        //   );
                                        // }

                                        final enterToSend = context
                                            .watch<SettingsProvider>()
                                            .enterToSendOnMobile;
                                        return GestureDetector(
                                          behavior:
                                              HitTestBehavior.deferToChild,
                                          // onSecondaryTapDown: (details) {
                                          //   // _showDesktopContextMenu(details.globalPosition);
                                          // },
                                          child: TextField(
                                            controller: _controller,
                                            focusNode: widget.focusNode,
                                            onChanged: _onTextChanged,
                                            readOnly: _composerLocked,
                                            minLines: 1,
                                            maxLines: _isExpanded ? 25 : 5,
                                            // On mobile, optionally show "Send" on the return key and submit on tap.
                                            // Still keep multiline so pasted text preserves line breaks.
                                            keyboardType:
                                                TextInputType.multiline,
                                            textInputAction: enterToSend
                                                ? TextInputAction.send
                                                : TextInputAction.newline,
                                            onSubmitted: enterToSend
                                                ? (_) =>
                                                      unawaited(_handleSend())
                                                : null,
                                            // Custom context menu: use instance method to avoid flickering
                                            // caused by recreating the callback on every build.
                                            // See: https://github.com/flutter/flutter/issues/150551
                                            contextMenuBuilder:
                                                _buildContextMenu,
                                            autofocus: false,
                                            decoration: InputDecoration(
                                              hintText: _hint(context),
                                              hintStyle: TextStyle(
                                                color: theme
                                                    .colorScheme
                                                    .onSurface
                                                    .withValues(alpha: 0.45),
                                              ),
                                              border: InputBorder.none,
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 2,
                                                  ),
                                            ),
                                            style: TextStyle(
                                              color:
                                                  theme.colorScheme.onSurface,
                                              fontSize:
                                                  (Platform.isWindows ||
                                                      Platform.isLinux ||
                                                      Platform.isMacOS)
                                                  ? 14
                                                  : 15,
                                            ),
                                            cursorColor:
                                                theme.colorScheme.primary,
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ),
                              // Expand/Collapse icon button (only shown when 3+ lines)
                              if (_showExpandButton)
                                Positioned(
                                  top: 10,
                                  right: 12,
                                  child: GestureDetector(
                                    onTap: () {
                                      setState(
                                        () => _isExpanded = !_isExpanded,
                                      );
                                      _ensureCaretVisible();
                                    },
                                    child: Icon(
                                      _isExpanded
                                          ? Lucide.ChevronsDownUp
                                          : Lucide.ChevronsUpDown,
                                      size: 16,
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.45),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          // Bottom buttons row (no divider)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              AppSpacing.xs,
                              0,
                              AppSpacing.xs,
                              AppSpacing.xs,
                            ),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 260),
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeInCubic,
                              transitionBuilder: (child, anim) =>
                                  FadeTransition(
                                    opacity: anim,
                                    child: SlideTransition(
                                      position: Tween<Offset>(
                                        begin: const Offset(0, 0.35),
                                        end: Offset.zero,
                                      ).animate(anim),
                                      child: child,
                                    ),
                                  ),
                              child: _ownsVoiceSession
                                  ? _buildVoiceRecordingRow(context, theme)
                                  : Row(
                                      key: const ValueKey('actions'),
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        // Responsive left action bar that overflows into a + menu on desktop
                                        Expanded(
                                          child: _buildResponsiveLeftActions(
                                            context,
                                          ),
                                        ),
                                        Row(
                                          children: [
                                            if (widget.showMoreButton) ...[
                                              _CompactIconButton(
                                                tooltip: AppLocalizations.of(
                                                  context,
                                                )!.chatInputBarMoreTooltip,
                                                icon: Lucide.Plus,
                                                active: widget.moreOpen,
                                                onTap: _composerLocked
                                                    ? null
                                                    : widget.onMore,
                                                childBuilder: (c) =>
                                                    AnimatedSwitcher(
                                                      duration: const Duration(
                                                        milliseconds: 200,
                                                      ),
                                                      transitionBuilder:
                                                          (
                                                            child,
                                                            anim,
                                                          ) => RotationTransition(
                                                            turns:
                                                                Tween<double>(
                                                                  begin: 0.85,
                                                                  end: 1,
                                                                ).animate(anim),
                                                            child:
                                                                FadeTransition(
                                                                  opacity: anim,
                                                                  child: child,
                                                                ),
                                                          ),
                                                      child: Icon(
                                                        widget.moreOpen
                                                            ? Lucide.X
                                                            : Lucide.Plus,
                                                        key: ValueKey(
                                                          widget.moreOpen
                                                              ? 'close'
                                                              : 'add',
                                                        ),
                                                        size: 20,
                                                        color: c,
                                                      ),
                                                    ),
                                              ),
                                              const SizedBox(width: 8),
                                            ],
                                            if (showVoiceInput) ...[
                                              _CompactIconButton(
                                                tooltip: AppLocalizations.of(
                                                  context,
                                                )!.chatInputBarVoiceInputTooltip,
                                                icon: Lucide.Mic,
                                                onTap:
                                                    _composerLocked ||
                                                        widget.loading
                                                    ? null
                                                    : () => unawaited(
                                                        _startVoiceInput(),
                                                      ),
                                              ),
                                              const SizedBox(width: 8),
                                            ],
                                            _CompactSendButton(
                                              enabled:
                                                  (hasText ||
                                                      hasImages ||
                                                      hasDocs) &&
                                                  !widget.loading &&
                                                  !_oneClickCompressing,
                                              loading: widget.loading,
                                              onSend: _handleSend,
                                              onStop: widget.loading
                                                  ? widget.onStop
                                                  : null,
                                              color: theme.colorScheme.primary,
                                              icon: Lucide.ArrowUp,
                                              tooltip: widget.sendButtonTooltip,
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QueuedInputBanner extends StatelessWidget {
  const _QueuedInputBanner({
    required this.label,
    required this.cancelLabel,
    this.previewText,
    this.onCancel,
  });

  final String label;
  final String cancelLabel;
  final String? previewText;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final preview = previewText?.trim();
    final hasPreview = preview != null && preview.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.84),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.16),
        ),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.schedule_rounded,
              size: 16,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: AppFontWeights.semibold,
                  ),
                ),
                if (hasPreview) ...[
                  const SizedBox(height: 2),
                  Text(
                    preview,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.72,
                      ),
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          IosCardPress(
            onTap: onCancel,
            borderRadius: BorderRadius.circular(10),
            baseColor: Colors.transparent,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            child: Text(
              cancelLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: AppFontWeights.semibold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Internal data model for responsive overflow actions on desktop
class _OverflowAction {
  final double width;
  final Widget Function() builder;
  final DesktopContextMenuItem menu;
  const _OverflowAction({
    required this.width,
    required this.builder,
    required this.menu,
  });
}

// New compact button for the integrated input bar
class _CompactIconButton extends StatelessWidget {
  const _CompactIconButton({
    required this.icon,
    this.onTap,
    this.onLongPress,
    this.tooltip,
    this.active = false,
    this.child,
    this.childBuilder,
    this.modelIcon = false,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? tooltip;
  final bool active;
  final Widget? child;
  final Widget Function(Color color)? childBuilder;
  final bool modelIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final fgColor = active
        ? theme.colorScheme.primary
        : (isDark ? Colors.white70 : Colors.black54);
    final bool isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;

    // Keep overall button size constant. For model icon with child, enlarge child slightly
    // and reduce padding so (2*padding + childSize) stays unchanged.
    final bool isModelChild = modelIcon && child != null;
    final double iconSize = 20.0; // default glyph size
    final double childSize = isModelChild
        ? 28.0
        : iconSize; // enlarge circle a bit more
    final double padding = isModelChild
        ? 1.0
        : 6.0; // keep total ~30px (2*1 + 28)

    final button = IosIconButton(
      size: isModelChild ? childSize : 20,
      padding: EdgeInsets.all(padding),
      onTap: onTap,
      // Disable long press on desktop platforms
      onLongPress: isDesktop ? null : onLongPress,
      color: fgColor,
      builder: childBuilder != null
          ? (c) => SizedBox(
              width: childSize,
              height: childSize,
              child: childBuilder!(c),
            )
          : (child != null
                ? (_) => SizedBox(
                    width: childSize,
                    height: childSize,
                    child: child,
                  )
                : null),
      icon: child == null && childBuilder == null ? icon : null,
    );

    if (tooltip == null) {
      return button;
    }

    return Tooltip(
      message: tooltip!,
      waitDuration: const Duration(milliseconds: 350),
      child: Semantics(tooltip: tooltip!, child: button),
    );
  }
}

// New compact send button for the integrated input bar
class _CompactSendButton extends StatelessWidget {
  const _CompactSendButton({
    required this.enabled,
    required this.onSend,
    required this.color,
    required this.icon,
    this.loading = false,
    this.onStop,
    this.tooltip,
  });

  final bool enabled;
  final bool loading;
  final VoidCallback onSend;
  final VoidCallback? onStop;
  final Color color;
  final IconData icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = (enabled || loading)
        ? color
        : (isDark
              ? Colors.white12
              : Colors.grey.shade300.withValues(alpha: 0.84));
    final fg = (enabled || loading)
        ? (isDark ? Colors.black : Colors.white)
        : (isDark ? Colors.white70 : Colors.grey.shade600);

    final button = Material(
      color: bg,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: loading ? onStop : (enabled ? onSend : null),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, anim) => ScaleTransition(
              scale: anim,
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: loading
                ? SvgPicture.asset(
                    key: const ValueKey('stop'),
                    'assets/icons/stop.svg',
                    width: 18,
                    height: 18,
                    colorFilter: ColorFilter.mode(fg, BlendMode.srcIn),
                  )
                : Icon(icon, key: const ValueKey('send'), size: 18, color: fg),
          ),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(
      message: tooltip!,
      waitDuration: const Duration(milliseconds: 350),
      child: Semantics(tooltip: tooltip!, child: button),
    );
  }
}

// Scrolling waveform driven by real mic amplitude samples (newest on the right).
class _VoiceWaveform extends StatelessWidget {
  const _VoiceWaveform({super.key, required this.levels, required this.color});

  final List<double> levels;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _VoiceWaveformPainter(levels: levels, color: color),
    );
  }
}

class _VoiceTranscribingIndicator extends StatefulWidget {
  const _VoiceTranscribingIndicator({
    super.key,
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  State<_VoiceTranscribingIndicator> createState() =>
      _VoiceTranscribingIndicatorState();
}

class _VoiceTranscribingIndicatorState
    extends State<_VoiceTranscribingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RotationTransition(
            turns: _controller,
            child: Icon(Lucide.Loader, size: 15, color: widget.color),
          ),
          const SizedBox(width: 7),
          Text(
            widget.label,
            style: TextStyle(fontSize: 12, color: widget.color),
          ),
        ],
      ),
    );
  }
}

class _VoiceWaveformPainter extends CustomPainter {
  _VoiceWaveformPainter({required this.levels, required this.color});

  /// Normalized mic levels in [0, 1]; the last entry is the newest sample.
  final List<double> levels;
  final Color color;

  static const double _barWidth = 3;
  static const double _barGap = 3.5;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const step = _barWidth + _barGap;
    final count = ((size.width + _barGap) / step).floor();
    if (count <= 0) return;
    final centerY = size.height / 2;
    final maxH = size.height * 0.92;
    // Center the bar row so both ends get the same inset — the capsule
    // caps are then symmetric regardless of the exact width.
    final leftInset = (size.width - (count * step - _barGap)) / 2;
    // Samples are right-aligned onto the bar slots: the newest sample sits
    // at the right edge and older samples scroll left, like a real recorder.
    final visible = math.min(count, levels.length);
    final first = levels.length - visible;
    for (var i = 0; i < visible; i++) {
      final level = levels[first + i].clamp(0.0, 1.0);
      final slot = count - visible + i;
      final x = leftInset + slot * step;
      // True capsule silhouette: a rectangle with fully-rounded ends, i.e.
      // the corner radius equals half the max bar height. Bars inside the
      // cap are shortened along the semicircle but still follow the volume.
      final radius = maxH / 2;
      final dCenter =
          math.min(x, size.width - (x + _barWidth)) +
          _barWidth / 2; // bar center distance to the nearest edge
      double envelope = 1.0;
      if (dCenter < radius) {
        envelope =
            math.sqrt(
              math.max(
                0.0,
                radius * radius - (radius - dCenter) * (radius - dCenter),
              ),
            ) /
            radius;
      }
      final h = math.max(2.0, maxH * level * envelope);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, centerY - h / 2, _barWidth, h),
          const Radius.circular(_barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_VoiceWaveformPainter oldDelegate) => true;
}
