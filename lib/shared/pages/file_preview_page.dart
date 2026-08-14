import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;

import '../../core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';
import '../widgets/ios_tactile.dart';

/// File content preview. Read RULES are shared with `kelivo_read`
/// (32 MB size cap, binary rejection, truncation note) but the preview's
/// char budget is its own (256 KB vs the model's 32 KB paginated window) —
/// the two surfaces deliberately diverge on budget (see CONTEXT.md).
class FilePreviewPage extends StatefulWidget {
  const FilePreviewPage({
    super.key,
    required this.hostPath,
    required this.displayName,
  });

  final String hostPath;
  final String displayName;

  @override
  State<FilePreviewPage> createState() => _FilePreviewPageState();
}

enum _PreviewState { loading, text, image, error }

class _FilePreviewPageState extends State<FilePreviewPage> {
  _PreviewState _state = _PreviewState.loading;
  List<String> _textLines = const [];
  bool _truncated = false;
  int _totalLines = 0;
  Uint8List? _imageBytes;
  bool _isSvg = false;
  String? _errorMessage;

  /// Preview char budget: 8x the model-facing `kelivo_read` window.
  /// User preview is not token-bound, so it may show more of the file.
  static const int _previewCharBudget = 256 * 1024;

  /// Byte cap for the bounded text read: 4x the char budget so multibyte
  /// encodings (CJK ≈ 3 bytes/char) still fill the whole preview window
  /// without ever materializing the full (up to 32 MB) file in memory.
  static const int _readCapBytes = _previewCharBudget * 4;

  static const Set<String> _imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.svg',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  AppLocalizations get l10n => AppLocalizations.of(context)!;

  /// Same binary probe as the filesystem server (null byte within the first
  /// 8 KB) — one rule set, two surfaces.
  bool _looksBinary(Uint8List bytes) {
    final n = math.min(bytes.length, 8 * 1024);
    for (var i = 0; i < n; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }

  Future<void> _load() async {
    try {
      final f = File(widget.hostPath);
      final stat = await f.stat();
      if (!mounted) return;
      if (stat.size > KelivoFilesystemMcpServerEngine.readWindowBytes) {
        _fail(l10n.mountFilesPreviewTooLarge(widget.displayName));
        return;
      }
      final ext = p.extension(widget.hostPath).toLowerCase();
      final isImage = _imageExtensions.contains(ext) && stat.size > 0;
      if (isImage && ext == '.svg') {
        // SVG renders straight from disk via SvgPicture.file — reading the
        // bytes here would only duplicate I/O and memory.
        if (!mounted) return;
        setState(() {
          _isSvg = true;
          _state = _PreviewState.image;
        });
        return;
      }
      if (isImage) {
        final bytes = await f.readAsBytes();
        if (!mounted) return;
        setState(() {
          _imageBytes = bytes;
          _state = _PreviewState.image;
        });
        return;
      }
      final raf = await f.open();
      try {
        // Bounded read: only the pilot window is ever decoded; the rest of
        // the file counts as truncated (mount_files_preview_truncated bar).
        final readLen = stat.size > _readCapBytes ? _readCapBytes : stat.size;
        final bytes = await raf.read(readLen);
        if (!mounted) return;
        if (_looksBinary(bytes)) {
          _fail(l10n.mountFilesPreviewBinary(widget.displayName));
          return;
        }
        final rawLines = utf8.decode(bytes, allowMalformed: true).split('\n');
        // A trailing newline produces a phantom empty element; drop it so
        // the gutter count and the budget loop are not off by one.
        if (rawLines.isNotEmpty && rawLines.last.isEmpty) {
          rawLines.removeLast();
        }
        final lines = <String>[];
        var chars = 0;
        var lineCut = false;
        for (var i = 0; i < rawLines.length; i++) {
          var content = rawLines[i];
          // A single line can exceed the whole budget (minified files): cut
          // it so the preview stays bounded instead of feeding a ~30 MB
          // string to SelectableText (mirrors the server's read budget).
          if (content.length > _previewCharBudget) {
            content = content.substring(0, _previewCharBudget);
            lineCut = true;
          }
          final next = chars + content.length + 1;
          if (next > _previewCharBudget && lines.isNotEmpty) break;
          lines.add(content);
          chars = next;
        }
        if (!mounted) return;
        setState(() {
          _textLines = lines;
          _truncated =
              lines.length < rawLines.length || lineCut || readLen < stat.size;
          _totalLines = rawLines.length;
          _state = _PreviewState.text;
        });
      } finally {
        await raf.close();
      }
    } catch (e) {
      if (!mounted) return;
      _fail(l10n.mountFilesPreviewReadFailed(widget.displayName, '$e'));
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _errorMessage = message;
      _state = _PreviewState.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = this.l10n;
    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          color: cs.onSurface,
          size: 22,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(widget.displayName),
      ),
      body: switch (_state) {
        _PreviewState.loading => const Center(
          child: CircularProgressIndicator(),
        ),
        _PreviewState.error => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _errorMessage ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        ),
        _PreviewState.image => Center(
          child: _isSvg
              ? SvgPicture.file(
                  File(widget.hostPath),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Text(
                    l10n.mountFilesPreviewReadFailed(
                      widget.displayName,
                      'decode failed',
                    ),
                  ),
                )
              : Image.memory(
                  _imageBytes!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Text(
                    l10n.mountFilesPreviewReadFailed(
                      widget.displayName,
                      'decode failed',
                    ),
                  ),
                ),
        ),
        _PreviewState.text => Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Line-number gutter: chrome, not content. Right-
                      // aligned, dimmed, excluded from selection/copy and
                      // screen readers. Long lines scroll horizontally
                      // instead of wrapping, so gutter numbers never drift
                      // away from their lines.
                      SizedBox(
                        width: _gutterWidth,
                        child: ExcludeSemantics(
                          child: Text(
                            _gutterNumbers,
                            textAlign: TextAlign.right,
                            style: _lineStyle.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.4),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SelectableText(_textLines.join('\n'), style: _lineStyle),
                    ],
                  ),
                ),
              ),
            ),
            if (_truncated)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                color: cs.primary.withValues(alpha: 0.08),
                child: Text(
                  l10n.mountFilesPreviewTruncated(_totalLines),
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ),
          ],
        ),
      },
    );
  }

  /// Shared metrics so the gutter never drifts from the content column.
  static final TextStyle _lineStyle = TextStyle(
    fontSize: 13,
    fontFamily: 'monospace',
    height: 1.5,
  );

  /// "1\n2\n..." for the visible lines.
  String get _gutterNumbers {
    final sb = StringBuffer();
    for (var i = 1; i <= _textLines.length; i++) {
      if (i > 1) sb.write('\n');
      sb.write(i);
    }
    return sb.toString();
  }

  /// Fixed width from the TOTAL line count (truncation bar state included),
  /// so the gutter never jumps while the preview loads more.
  double get _gutterWidth {
    final digits = '$_totalLines'.length;
    return digits * 8.0 + 4.0;
  }
}
