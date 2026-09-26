import 'dart:async';
import 'dart:math' as math;

import 'package:downsize/downsize.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/providers/settings_provider.dart';
import '../../../../icons/lucide_adapter.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/responsive/screen_type_helper.dart';
import '../../../../shared/utils/format_bytes.dart';
import '../../../../shared/widgets/ios_tactile.dart';
import '../../../../shared/widgets/segmented_tabs.dart';
import '../../../../theme/app_font_weights.dart';
import '../../../../theme/app_semantic_colors.dart';
import '../../../../utils/image_compressor.dart';
import 'compress_editor_controller.dart';
import 'compress_editor_preview.dart';

/// What the editor decided to do with the parameters the user confirmed.
sealed class CompressEditorResult {
  const CompressEditorResult(this.params);

  final ManualCompressParams params;
}

/// Apply the parameters to the image the editor was opened for.
final class CompressEditorApply extends CompressEditorResult {
  const CompressEditorApply(super.params);
}

/// Apply the parameters to every image currently attached to the draft.
final class CompressEditorApplyAll extends CompressEditorResult {
  const CompressEditorApplyAll(super.params);
}

/// Opens the manual compress editor: a full-screen page on mobile, a dialog on
/// desktop. Returns null when the user closes without confirming.
Future<CompressEditorResult?> showImageCompressEditor(
  BuildContext context, {
  required String imagePath,
  required int totalImageCount,
}) {
  final platform = Theme.of(context).platform;
  final desktop =
      ResponsiveHelper.isDesktop(context) ||
      platform == TargetPlatform.macOS ||
      platform == TargetPlatform.windows ||
      platform == TargetPlatform.linux;
  if (desktop) {
    return showDialog<CompressEditorResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: ctx.overlaySurface,
        insetPadding: const EdgeInsets.all(28),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 1000,
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.9,
          ),
          child: CompressEditorPage(
            imagePath: imagePath,
            totalImageCount: totalImageCount,
            desktop: true,
          ),
        ),
      ),
    );
  }
  return Navigator.of(context).push<CompressEditorResult>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => CompressEditorPage(
        imagePath: imagePath,
        totalImageCount: totalImageCount,
      ),
    ),
  );
}

class CompressEditorPage extends StatefulWidget {
  const CompressEditorPage({
    super.key,
    required this.imagePath,
    required this.totalImageCount,
    this.desktop = false,
  });

  final String imagePath;
  final int totalImageCount;
  final bool desktop;

  @override
  State<CompressEditorPage> createState() => _CompressEditorPageState();
}

class _CompressEditorPageState extends State<CompressEditorPage> {
  late final CompressEditorController _controller;

  ManualCompressParams get _params => _controller.params;

  @override
  void initState() {
    super.initState();
    _controller = CompressEditorController(
      imagePath: widget.imagePath,
      initialParams: context.read<SettingsProvider>().manualCompressParams,
    );
    unawaited(_controller.prepare());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setParams(ManualCompressParams next) => _controller.setParams(next);

  void _apply({required bool toAll}) {
    if (_params.isNoOp) {
      Navigator.of(context).pop();
      return;
    }
    // Remembered as the starting point of the next session.
    unawaited(
      context.read<SettingsProvider>().setManualCompressParams(_params),
    );
    Navigator.of(context).pop(
      toAll ? CompressEditorApplyAll(_params) : CompressEditorApply(_params),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        return Scaffold(
          backgroundColor:
              Colors.black, // color-gate: ignore (photo editing backdrop)
          body: SafeArea(
            child: Column(
              children: [
                Expanded(child: _previewArea(l10n)),
                _paramsPanel(context, l10n),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _previewArea(AppLocalizations l10n) {
    if (_controller.preparing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_controller.decodeFailed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Lucide.ImageOff,
                size: 32,
                color: Colors.white, // color-gate: ignore (on photo backdrop)
              ),
              const SizedBox(height: 12),
              Text(
                l10n.compressEditorDecodeFailed,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.white, // color-gate: ignore (on photo backdrop)
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.all(widget.desktop ? 12 : 0),
      child: CompressPreview(
        controller: _controller,
        formatLabel: _previewLabel(l10n),
      ),
    );
  }

  String? _previewLabel(AppLocalizations l10n) {
    return switch (_params.format) {
      DownsizeFormat.jpeg => 'JPEG ${_params.quality}',
      DownsizeFormat.png => 'PNG',
      null => null,
    };
  }

  Widget _paramsPanel(BuildContext context, AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: widget.desktop
            ? BorderRadius.zero
            : const BorderRadius.vertical(top: Radius.circular(18)),
      ),
      padding: EdgeInsets.fromLTRB(
        widget.desktop ? 18 : 16,
        12,
        widget.desktop ? 18 : 16,
        12,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.compressEditorTitle,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: AppFontWeights.semibold,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                IosIconButton(
                  icon: Lucide.X,
                  size: 18,
                  tooltip: l10n.compressEditorCancel,
                  color: cs.onSurfaceVariant,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SegmentedTabs(
              height: 38,
              tabs: [
                SegmentedTab(label: l10n.compressEditorFormatJpeg),
                SegmentedTab(label: l10n.compressEditorFormatPng),
                SegmentedTab(label: l10n.compressEditorFormatOriginal),
              ],
              index: switch (_params.format) {
                DownsizeFormat.jpeg => 0,
                DownsizeFormat.png => 1,
                null => 2,
              },
              onChanged: (index) => _setParams(
                ManualCompressParams(
                  format: switch (index) {
                    0 => DownsizeFormat.jpeg,
                    1 => DownsizeFormat.png,
                    _ => null,
                  },
                  quality: _params.quality,
                  maxLongEdge: _params.maxLongEdge,
                ),
              ),
            ),
            if (!_params.isNoOp) ...[
              const SizedBox(height: 14),
              _edgeRow(context, l10n),
              if (_params.format == DownsizeFormat.jpeg) ...[
                const SizedBox(height: 6),
                _qualityRow(context, l10n),
              ],
            ],
            const SizedBox(height: 10),
            _estimateRow(context, l10n),
            const SizedBox(height: 12),
            _actions(context, l10n),
          ],
        ),
      ),
    );
  }

  Widget _edgeRow(BuildContext context, AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    final original = _controller.sourceLongEdge;
    if (original <= 0) return const SizedBox.shrink();
    final minEdge = math.min(256, original).toDouble();
    final maxEdge = original.toDouble();
    final value = (_params.maxLongEdge ?? original)
        .clamp(minEdge, maxEdge)
        .toDouble();
    final divisions = ((maxEdge - minEdge) / 64).ceil().clamp(1, 512);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              l10n.compressEditorLongEdgeLabel,
              style: TextStyle(
                fontSize: 13,
                fontWeight: AppFontWeights.medium,
                color: cs.onSurface,
              ),
            ),
            const Spacer(),
            Text(
              '${value.round()} px',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        ),
        Slider(
          value: value,
          min: minEdge,
          max: maxEdge,
          divisions: divisions,
          onChanged: (next) => _setParams(
            ManualCompressParams(
              format: _params.format,
              quality: _params.quality,
              maxLongEdge: next.round(),
            ),
          ),
        ),
        Row(
          children: [
            _EdgePreset(
              label: l10n.compressEditorLongEdgeFull,
              selected: _params.maxLongEdge == null,
              onTap: () => _setParams(
                ManualCompressParams(
                  format: _params.format,
                  quality: _params.quality,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _EdgePreset(
              label: l10n.compressEditorLongEdgeHalf,
              selected: _params.maxLongEdge == (original / 2).round(),
              onTap: () => _setParams(
                ManualCompressParams(
                  format: _params.format,
                  quality: _params.quality,
                  maxLongEdge: (original / 2).round(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _EdgePreset(
              label: l10n.compressEditorLongEdgeQuarter,
              selected: _params.maxLongEdge == (original / 4).round(),
              onTap: () => _setParams(
                ManualCompressParams(
                  format: _params.format,
                  quality: _params.quality,
                  maxLongEdge: (original / 4).round(),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _qualityRow(BuildContext context, AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              l10n.compressEditorQualityLabel,
              style: TextStyle(
                fontSize: 13,
                fontWeight: AppFontWeights.medium,
                color: cs.onSurface,
              ),
            ),
            const Spacer(),
            Text(
              '${_params.quality}',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        ),
        Slider(
          value: _params.quality.toDouble().clamp(30, 100),
          min: 30,
          max: 100,
          divisions: 14,
          onChanged: (next) => _setParams(
            ManualCompressParams(
              format: _params.format,
              quality: next.round(),
              maxLongEdge: _params.maxLongEdge,
            ),
          ),
        ),
      ],
    );
  }

  Widget _estimateRow(BuildContext context, AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    final sourceBytes = _controller.sourceBytes;
    if (sourceBytes == null) return const SizedBox.shrink();
    final String detail;
    if (_params.isNoOp) {
      detail = l10n.compressEditorEstimateOriginal(
        formatBytes(sourceBytes),
        '${_controller.sourceWidth}×${_controller.sourceHeight}',
      );
    } else if (_controller.estimating) {
      detail = l10n.compressEditorEstimating;
    } else if (_controller.estimateFailed ||
        _controller.estimatedBytes == null) {
      detail = l10n.compressEditorEstimateFailed;
    } else {
      final estimated = _controller.estimatedBytes!;
      final longEdge = _params.maxLongEdge ?? _controller.sourceLongEdge;
      final factor = math.min(1.0, longEdge / _controller.sourceLongEdge);
      final outWidth = math.max(1, (_controller.sourceWidth * factor).round());
      final outHeight = math.max(
        1,
        (_controller.sourceHeight * factor).round(),
      );
      final saved = sourceBytes <= 0
          ? 0
          : ((sourceBytes - estimated) / sourceBytes * 100).round();
      detail = l10n.compressEditorEstimate(
        '${_controller.sourceWidth}×${_controller.sourceHeight} · ${formatBytes(sourceBytes)}',
        '$outWidth×$outHeight · ${formatBytes(estimated)}',
        saved > 0 ? l10n.compressEditorSavings(saved) : '',
      );
    }
    return Row(
      children: [
        Icon(Lucide.info, size: 13, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            detail,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _actions(BuildContext context, AppLocalizations l10n) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.compressEditorCancel),
        ),
        if (widget.totalImageCount > 1 && !_params.isNoOp) ...[
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => _apply(toAll: true),
            child: Text(l10n.compressEditorApplyAll),
          ),
        ],
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _params.isNoOp
              ? () => Navigator.of(context).pop()
              : () => _apply(toAll: false),
          child: Text(
            _params.isNoOp ? l10n.compressEditorDone : l10n.compressEditorApply,
          ),
        ),
      ],
    );
  }
}

class _EdgePreset extends StatelessWidget {
  const _EdgePreset({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      baseColor: selected
          ? cs.primary.withValues(alpha: 0.14)
          : cs.onSurface.withValues(alpha: 0.05),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: AppFontWeights.medium,
          color: selected ? cs.primary : cs.onSurfaceVariant,
        ),
      ),
    );
  }
}
