import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

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
import '../../../../utils/manual_compress_pipeline.dart';
import 'compress_editor_controller.dart';
import 'compress_editor_preview.dart';

/// What the editor decided to do with the parameters the user confirmed.
sealed class CompressEditorResult {
  const CompressEditorResult(this.params);

  final ManualCompressParams params;
}

/// Apply the parameters to the image the editor was opened for.
///
/// [artifact] is the exact byte sequence the editor already produced and showed
/// the size of, so the caller stores it without re-encoding. It is null only when
/// the user confirmed before the debounced pass for these parameters finished,
/// in which case the caller runs the pipeline itself.
final class CompressEditorApply extends CompressEditorResult {
  const CompressEditorApply(super.params, this.artifact);

  final Uint8List? artifact;
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
    this.budgetPixels,
    this.budgetBytes,
  });

  final String imagePath;
  final int totalImageCount;
  final bool desktop;

  /// Overrides for the working-image budgets, used by tests to exercise the
  /// clamp and the gate without multi-hundred-megapixel fixtures. Production
  /// callers leave them null and get the platform budgets.
  final int? budgetPixels;
  final int? budgetBytes;

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
      desktop: widget.desktop ? true : null,
      budgetPixels: widget.budgetPixels,
      budgetBytes: widget.budgetBytes,
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
    _remember();
    if (_params.isNoOp) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop(
      toAll
          ? CompressEditorApplyAll(_params)
          : CompressEditorApply(_params, _controller.readyArtifact),
    );
  }

  /// Remembers the current parameters as the starting point of the next popup
  /// session, 原图 included: the last choice is what the next session opens on.
  void _remember() {
    unawaited(
      context.read<SettingsProvider>().setManualCompressParams(_params),
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
    if (_controller.decodeFailed || _controller.tooLarge) {
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
                _controller.tooLarge
                    ? l10n.compressEditorTooLarge
                    : l10n.compressEditorDecodeFailed,
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
    final min = minEditorLongEdge(original);
    final minEdge = min.toDouble();
    // The slider stops at the resolution the pipeline will actually produce: a
    // source beyond the working budget is worked at a reduced long edge, and
    // offering the source's own edge would promise a result that never appears.
    final maxEdge = _controller.reachableLongEdge.toDouble().clamp(
      minEdge,
      original.toDouble(),
    );
    final value = (_params.maxLongEdge ?? maxEdge)
        .clamp(minEdge, maxEdge)
        .toDouble();
    final divisions = ((maxEdge - minEdge) / 64).ceil().clamp(1, 512);
    // Each preset is clamped into the slider's own range, so the number the
    // panel shows is always the number that will be applied.
    int edgeFor(double fraction) =>
        (original * fraction).round().clamp(min, maxEdge.round());
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
              selected: _params.maxLongEdge == edgeFor(0.5),
              onTap: () => _setParams(
                ManualCompressParams(
                  format: _params.format,
                  quality: _params.quality,
                  maxLongEdge: edgeFor(0.5),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _EdgePreset(
              label: l10n.compressEditorLongEdgeQuarter,
              selected: _params.maxLongEdge == edgeFor(0.25),
              onTap: () => _setParams(
                ManualCompressParams(
                  format: _params.format,
                  quality: _params.quality,
                  maxLongEdge: edgeFor(0.25),
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
    if (sourceBytes <= 0) return const SizedBox.shrink();
    final sourceDimensions =
        '${_controller.sourceWidth}×${_controller.sourceHeight}';
    final sourceSize = formatBytes(sourceBytes);

    Widget message(String text) =>
        Text(text, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant));

    final Widget content;
    if (_params.isNoOp) {
      // 原图 has no result to compare against, so the note takes the middle
      // column instead of an arrow.
      content = Row(
        children: [
          Expanded(
            child: _EstimateSide(
              dimensions: sourceDimensions,
              size: sourceSize,
              alignEnd: true,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          message(l10n.compressEditorNoReencode),
          const SizedBox(width: 10),
          const Expanded(child: SizedBox.shrink()),
        ],
      );
    } else if (_controller.encoding) {
      content = message(l10n.compressEditorEstimating);
    } else if (_controller.artifactBytes == null) {
      content = message(l10n.compressEditorEstimateFailed);
    } else {
      // The artifact has already been encoded at the working resolution, so its
      // size and its dimensions are facts, not projections: the number below is
      // the number of bytes the apply writes.
      final result = _controller.artifactBytes!;
      final saved = sourceBytes <= 0
          ? 0
          : ((sourceBytes - result) / sourceBytes * 100).round();
      content = Row(
        children: [
          Expanded(
            child: _EstimateSide(
              dimensions: sourceDimensions,
              size: sourceSize,
              alignEnd: true,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          _EstimateArrow(
            label: switch (saved) {
              > 0 => l10n.compressEditorSavings(saved),
              < 0 => l10n.compressEditorGrowth(-saved),
              _ => null,
            },
            grew: saved < 0,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _EstimateSide(
              dimensions:
                  '${_controller.workingWidth}×${_controller.workingHeight}',
              size: formatBytes(result),
              alignEnd: false,
              color: cs.onSurface,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Lucide.info, size: 13, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(child: content),
          ],
        ),
        if (_controller.workingIsReduced) ...[
          const SizedBox(height: 4),
          Text(
            l10n.compressEditorWorkingScale(
              sourceDimensions,
              (_controller.workingLongEdge /
                      math.max(1, _controller.sourceLongEdge) *
                      100)
                  .round(),
            ),
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _actions(BuildContext context, AppLocalizations l10n) {
    if (_controller.decodeFailed || _controller.tooLarge) {
      // The copy above already says the image cannot be re-compressed, so
      // the panel must not offer an action that tries anyway: the apply
      // would fail, drop the attachment from the message and lock sending.
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.compressEditorCancel),
          ),
        ],
      );
    }
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
          onPressed: () => _apply(toAll: false),
          child: Text(
            _params.isNoOp ? l10n.compressEditorDone : l10n.compressEditorApply,
          ),
        ),
      ],
    );
  }
}

/// One side of the estimate row: the resolution above, the size below.
class _EstimateSide extends StatelessWidget {
  const _EstimateSide({
    required this.dimensions,
    required this.size,
    required this.alignEnd,
    required this.color,
  });

  final String dimensions;
  final String size;
  final bool alignEnd;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          dimensions,
          style: TextStyle(
            fontSize: 12,
            fontWeight: AppFontWeights.medium,
            color: color,
          ),
        ),
        Text(
          size,
          style: TextStyle(fontSize: 12, color: color.withValues(alpha: 0.75)),
        ),
      ],
    );
  }
}

/// The arrow between the two estimate sides, with the size change above it.
class _EstimateArrow extends StatelessWidget {
  const _EstimateArrow({this.label, this.grew = false});

  /// "−85%" for a smaller result, "+12%" for a larger one, null when the size
  /// does not change.
  final String? label;
  final bool grew;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final delta = label;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (delta != null)
          Text(
            delta,
            style: TextStyle(
              fontSize: 11,
              fontWeight: AppFontWeights.semibold,
              color: grew
                  ? context.appColors.warning
                  : context.appColors.success,
            ),
          ),
        Icon(
          Directionality.of(context) == TextDirection.rtl
              ? Lucide.ArrowLeft
              : Lucide.ArrowRight,
          size: 16,
          color: cs.onSurfaceVariant,
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
