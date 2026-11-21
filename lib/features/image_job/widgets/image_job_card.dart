import 'dart:async';

import 'package:flutter/material.dart';

import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

/// The in-message card for an image that has been promised but not written.
///
/// It replaces the ordinary image block for a part whose [ImagePart.state] is
/// set: one header line (`生成插图 (12.6s) ⋯`) and either a fixed-ratio skeleton
/// or the failure row, so the reply keeps its height and the position never
/// jumps when the bytes land.
class ImageJobCard extends StatelessWidget {
  const ImageJobCard({
    super.key,
    required this.part,
    this.elapsed,
    this.startedAt,
    this.requestedAspect,
    this.onOpen,
    this.child,
  });

  final ImagePart part;

  /// Time spent so far; the header omits the suffix when the caller has none.
  final Duration? elapsed;

  /// When the job started. With a pending part and no [elapsed] yet, the header
  /// counts up from here, so generating shows progress instead of a bare title
  /// that suddenly acquires `(14.5s)` at the end.
  final DateTime? startedAt;

  /// The proportions the request asked for, if it asked for any.
  ///
  /// The skeleton reserves this shape, so "I asked for 16:9" is visible the
  /// moment the call is made instead of only when the picture lands. `null` —
  /// `auto`, or no job left to ask — falls back to a neutral 3:2: nobody knows
  /// the size before the model picks it.
  final double? requestedAspect;

  final VoidCallback? onOpen;

  /// The picture itself, once there is one. The card owns the frame, the header
  /// and the skeleton; the caller owns how an image is drawn, so there is one
  /// image renderer in the app, not two.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;
    final rawState = part.state;
    final isPending = rawState == ImagePartState.pending;
    final hasPicture = rawState == null && child != null;

    final title = switch (rawState) {
      null => l10n.imageJobTitle,
      ImagePartState.pending => l10n.imageJobTitle,
      ImagePartState.failed => l10n.imageJobFailed,
      ImagePartState.interrupted => l10n.imageJobInterrupted,
    };

    final headerColor = cs.onSurface.withValues(alpha: 0.87);
    final metaColor = cs.onSurface.withValues(alpha: 0.55);

    return Container(
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: isDark ? 0.25 : 0.30),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                Icon(Lucide.Image, size: 18, color: headerColor),
                const SizedBox(width: 8),
                // Everything between the icon and the ⋯ takes the slack, so the
                // ⋯ sits on the right edge however long the title or the model
                // name is. A bare Spacer next to a Flexible split the free space
                // between them and left ⋯ floating mid-row.
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: AppFontWeights.semibold,
                            color: headerColor,
                          ),
                        ),
                      ),
                      if (elapsed != null ||
                          (isPending && startedAt != null)) ...[
                        const SizedBox(width: 8),
                        _ElapsedLabel(
                          elapsed: elapsed,
                          startedAt: startedAt,
                          running: isPending,
                          style: TextStyle(
                            fontSize: 13,
                            color: metaColor,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (onOpen != null)
                  Semantics(
                    button: true,
                    // The action, not the status: a reader should hear "show
                    // menu", not "Illustration failed" twice.
                    label: MaterialLocalizations.of(context).showMenuTooltip,
                    child: InkResponse(
                      onTap: onOpen,
                      radius: 16,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Lucide.Ellipsis,
                          size: 18,
                          color: headerColor,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (hasPicture)
            child!
          else if (isPending)
            _ImageJobSkeleton(aspect: requestedAspect ?? 3 / 2)
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // A failure says why. "生成失败" alone left the user with
                  // nothing to fix — the reason is the whole point of the row.
                  if (part.failureReason != null &&
                      part.failureReason!.trim().isNotEmpty)
                    Expanded(
                      child: Text(
                        part.failureReason!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.45,
                          color: metaColor,
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String _formatElapsed(Duration elapsed) {
  final seconds = elapsed.inMilliseconds / 1000;
  return '(${seconds.toStringAsFixed(1)}s)';
}

/// The `(12.6s)` in the header: a fixed value once the job is over, a count-up
/// while it runs.
class _ElapsedLabel extends StatefulWidget {
  const _ElapsedLabel({
    required this.elapsed,
    required this.startedAt,
    required this.running,
    required this.style,
  });

  final Duration? elapsed;
  final DateTime? startedAt;
  final bool running;
  final TextStyle style;

  @override
  State<_ElapsedLabel> createState() => _ElapsedLabelState();
}

class _ElapsedLabelState extends State<_ElapsedLabel> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _ElapsedLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.running != widget.running ||
        oldWidget.startedAt != widget.startedAt) {
      _syncTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    if (widget.running && widget.elapsed == null && widget.startedAt != null) {
      _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  Duration get _shown {
    final fixed = widget.elapsed;
    if (fixed != null) return fixed;
    final start = widget.startedAt;
    if (start == null) return Duration.zero;
    final d = DateTime.now().difference(start);
    return d.isNegative ? Duration.zero : d;
  }

  @override
  Widget build(BuildContext context) {
    return Text(_formatElapsed(_shown), style: widget.style);
  }
}

/// Fixed-ratio placeholder: the reply's height must not change when the bytes
/// land, so the skeleton is drawn at the ratio the request asked for (3:2 when
/// it asked for nothing — `auto` means nobody knows yet).
class _ImageJobSkeleton extends StatelessWidget {
  const _ImageJobSkeleton({required this.aspect});

  final double aspect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: aspect,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              cs.primaryContainer.withValues(alpha: 0.35),
              cs.surfaceContainerHighest.withValues(alpha: 0.55),
            ],
          ),
        ),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: cs.onSurface.withValues(alpha: 0.30),
            ),
          ),
        ),
      ),
    );
  }
}
