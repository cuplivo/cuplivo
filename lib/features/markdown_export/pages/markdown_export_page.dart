import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/action_sheet.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/clipboard_images.dart';
import '../../../utils/platform_utils.dart';
import '../../chat/widgets/export_image_capture.dart' show exportRenderConfig;
import '../../chat/widgets/export_progress_overlay.dart';
import '../../chat/widgets/image_preview_sheet.dart';
import '../models/markdown_export_input.dart';
import '../models/markdown_export_mode.dart';
import '../models/markdown_export_text_size.dart';
import '../services/markdown_export_image.dart';
import '../widgets/markdown_export_desktop_layout.dart';
import '../widgets/markdown_export_drop_target.dart';
import '../widgets/markdown_export_mobile_layout.dart';

/// Markdown in, one picture out. Nothing about where the text came from travels
/// into the picture: no conversation title, no model name, no timestamp.
class MarkdownExportPage extends StatefulWidget {
  const MarkdownExportPage({super.key});

  @override
  State<MarkdownExportPage> createState() => _MarkdownExportPageState();
}

class _MarkdownExportPageState extends State<MarkdownExportPage> {
  final _controller = TextEditingController();
  final _textSizeAnchor = GlobalKey();
  MarkdownExportMode _mode = MarkdownExportMode.edit;
  MarkdownExportTextSize _textSize = MarkdownExportTextSize.standard;

  /// Desktop only: the sheet gets the full window once the source steps aside.
  bool _sourceCollapsed = false;
  bool _exporting = false;

  /// What the preview draws, and the text the last notification carried.
  ///
  /// A caret move notifies the controller without changing a character, so the
  /// two have to be compared with [_notifiedText]: comparing against what is on
  /// screen would read every caret move as an edit — while a redraw is pending
  /// it looks different — and push that redraw back each time.
  String _previewSource = '';
  String _notifiedText = '';
  Timer? _previewSettled;

  /// How long typing has to pause before the sheet is redrawn: imperceptible to
  /// a reader, longer than the gap between keystrokes in a burst.
  static const _previewSettleDelay = Duration(milliseconds: 180);

  bool get _isDesktop => PlatformUtils.isDesktopTarget;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onSourceChanged);
  }

  @override
  void dispose() {
    _previewSettled?.cancel();
    _controller.removeListener(_onSourceChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onSourceChanged() {
    // Selection-only changes reach here too, and they are not edits: nothing to
    // schedule, and nothing to postpone.
    final text = _controller.text;
    if (text == _notifiedText) return;
    _notifiedText = text;
    if (text == _previewSource) {
      // Edited back to what is already on screen.
      _previewSettled?.cancel();
      _previewSettled = null;
      return;
    }
    _previewSettled?.cancel();
    _previewSettled = Timer(_previewSettleDelay, _settlePreview);
  }

  void _settlePreview() {
    _previewSettled = null;
    if (!mounted) return;
    setState(() => _previewSource = _controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The export width is fixed by the platform, not by the window: a narrow
    // desktop window still produces the same-size picture.
    final documentWidth = exportRenderConfig(isDesktop: _isDesktop).width;

    if (_isDesktop) {
      final layout = MarkdownExportDesktopLayout(
        controller: _controller,
        previewSource: _previewSource,
        onImport: () => unawaited(_importFile()),
        onPaste: () => unawaited(_paste()),
        onTextSize: () => unawaited(_openTextSizeMenu()),
        textSizeAnchor: _textSizeAnchor,
        sourceCollapsed: _sourceCollapsed,
        onToggleSource: () =>
            setState(() => _sourceCollapsed = !_sourceCollapsed),
        onExport: _startExport,
        busy: _exporting,
        documentWidth: documentWidth,
        textScale: _textSize.scale,
      );
      // The drop target stays mounted even when another desktop tab is on
      // screen: taking it out of the tree would rebuild this page around it,
      // and `desktop_drop` hands a drop to every registered target anyway. It
      // asks the shell whether it is visible when a drop actually arrives.
      return MarkdownExportDropTarget(
        onPaths: (paths) => unawaited(_acceptDrop(paths)),
        child: layout,
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            size: 22,
            padding: const EdgeInsets.all(8),
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.markdownExportTitle),
        actions: [
          Tooltip(
            message: l10n.markdownExportTextSize,
            child: IosIconButton(
              icon: Lucide.CaseSensitive,
              size: 20,
              padding: const EdgeInsets.all(8),
              onTap: () => unawaited(_openTextSizeMenu()),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        top: false,
        child: MarkdownExportMobileLayout(
          controller: _controller,
          previewSource: _previewSource,
          mode: _mode,
          onModeChanged: (mode) => setState(() => _mode = mode),
          onImport: () => unawaited(_importFile()),
          onPaste: () => unawaited(_paste()),
          onExport: _startExport,
          busy: _exporting,
          documentWidth: documentWidth,
          textScale: _textSize.scale,
        ),
      ),
    );
  }

  /// The type size is the picture's, not the screen's: choosing it here is
  /// choosing what the file will look like.
  Future<void> _openTextSizeMenu() {
    final l10n = AppLocalizations.of(context)!;
    String labelOf(MarkdownExportTextSize size) => switch (size) {
      MarkdownExportTextSize.small => l10n.markdownExportTextSizeSmall,
      MarkdownExportTextSize.standard => l10n.markdownExportTextSizeStandard,
      MarkdownExportTextSize.large => l10n.markdownExportTextSizeLarge,
    };
    return showAdaptiveActionMenu(
      context,
      anchorKey: _textSizeAnchor,
      items: [
        for (final size in MarkdownExportTextSize.values)
          ActionSheetItem(
            icon: Lucide.CaseSensitive,
            label: labelOf(size),
            checked: size == _textSize,
            onTap: () => setState(() => _textSize = size),
          ),
      ],
    );
  }

  void _replaceSource(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    // A file or a paste arrives whole, so show it now instead of after the
    // settle window that exists for typing.
    _previewSettled?.cancel();
    _previewSettled = null;
    setState(() => _previewSource = text);
  }

  Future<void> _importFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        for (final extension in markdownExportExtensions)
          extension.substring(1),
      ],
    );
    final path = result?.files.singleOrNull?.path;
    if (path == null) return;
    await _loadFile(File(path));
  }

  /// Reads one file into the editor. Returns whether it was the kind of file
  /// this tool can render, so callers can keep looking through a batch.
  Future<bool> _loadFile(File file) async {
    if (!isMarkdownExportFile(file.path)) {
      _report(AppLocalizations.of(context)!.markdownExportUnsupportedFile);
      return false;
    }
    try {
      // Text files arrive in whatever encoding wrote them; a malformed byte
      // should cost one glyph, not the whole document.
      final bytes = await file.readAsBytes();
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!mounted) return false;
      _replaceSource(text.startsWith('\uFEFF') ? text.substring(1) : text);
      return true;
    } catch (_) {
      if (mounted) {
        _report(AppLocalizations.of(context)!.markdownExportReadFailed);
      }
      return false;
    }
  }

  Future<void> _paste() async {
    final l10n = AppLocalizations.of(context)!;
    // A file copied in Finder or Explorer arrives as a path, not as text.
    if (_isDesktop) {
      for (final raw in await ClipboardImages.getFilePaths()) {
        final path = raw.startsWith('file://')
            ? (Uri.tryParse(raw)?.toFilePath() ?? raw)
            : raw;
        if (isMarkdownExportFile(path) && await _loadFile(File(path))) return;
        if (!mounted) return;
      }
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted) return;
    if (text == null || text.trim().isEmpty) {
      _report(l10n.markdownExportNothingToPaste);
      return;
    }
    _replaceSource(text);
  }

  Future<void> _acceptDrop(List<String> paths) async {
    for (final path in paths) {
      if (isMarkdownExportFile(path) && await _loadFile(File(path))) return;
      if (!mounted) return;
    }
    _report(AppLocalizations.of(context)!.markdownExportUnsupportedFile);
  }

  void _startExport() => unawaited(_export());

  Future<void> _export() async {
    if (_controller.text.trim().isEmpty || _exporting) return;
    final l10n = AppLocalizations.of(context)!;
    final source = _controller.text;
    setState(() => _exporting = true);
    MarkdownExportImage? exported;
    try {
      await runWithExportProgressOverlay(context, (progress) async {
        exported = await renderMarkdownExportImage(
          context,
          source: source,
          isDesktop: _isDesktop,
          textScale: _textSize.scale,
          onProgress: (value) => progress.value = value,
        );
      });
    } catch (error) {
      if (mounted) {
        _report(l10n.messageExportSheetExportFailed('$error'), isError: true);
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
    final result = exported;
    if (result == null || !mounted) return;
    if (result.reducedResolution) {
      _report(l10n.markdownExportReducedResolution);
    }
    await showImagePreviewSheet(
      context,
      file: result.file,
      preparedPreview: result.preview,
    );
  }

  void _report(String message, {bool isError = false}) {
    if (!mounted) return;
    showAppSnackBar(
      context,
      message: message,
      type: isError ? NotificationType.error : NotificationType.info,
    );
  }
}
