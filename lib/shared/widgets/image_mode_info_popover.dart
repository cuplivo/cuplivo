import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'ios_tactile.dart';

/// Anchored info popover explaining the two image-sending routes (images API
/// vs chat API / completions). Follows the established popover pattern
/// (the shared desktop popover pattern): anchor-rect positioning, opens
/// upward above the anchor, glass panel, fade+slide, outside-tap dismiss.
/// One shared implementation for desktop and mobile — the LivePanel pills sit
/// right above the input bar, so the panel always has message area to open
/// into and never covers the composer.
Future<void> showImageModeInfoPopover(
  BuildContext context, {
  required GlobalKey anchorKey,
}) async {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;
  final keyContext = anchorKey.currentContext;
  if (keyContext == null) return;
  final box = keyContext.findRenderObject() as RenderBox?;
  if (box == null) return;
  final offset = box.localToGlobal(Offset.zero);
  final size = box.size;
  final anchorRect = Rect.fromLTWH(
    offset.dx,
    offset.dy,
    size.width,
    size.height,
  );

  final completer = Completer<void>();
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _ImageModeInfoPopover(
      anchorRect: anchorRect,
      anchorWidth: size.width,
      onClose: () {
        try {
          entry.remove();
        } catch (_) {}
        if (!completer.isCompleted) completer.complete();
      },
    ),
  );
  overlay.insert(entry);
  await completer.future;
}

class _ImageModeInfoPopover extends StatefulWidget {
  const _ImageModeInfoPopover({
    required this.anchorRect,
    required this.anchorWidth,
    required this.onClose,
  });

  final Rect anchorRect;
  final double anchorWidth;
  final VoidCallback onClose;

  @override
  State<_ImageModeInfoPopover> createState() => _ImageModeInfoPopoverState();
}

class _ImageModeInfoPopoverState extends State<_ImageModeInfoPopover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeIn;
  Offset _offset = const Offset(0, 0.12);
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _fadeIn = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      setState(() => _offset = Offset.zero);
      try {
        await _controller.forward();
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    setState(() => _offset = const Offset(0, 1.0));
    try {
      await _controller.reverse();
    } catch (_) {}
    if (mounted) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    // Also clamp against the screen: on very narrow devices (≤336 logical px,
    // e.g. 320pt-class) the 320 floor would push the panel past the right
    // edge and clip its border.
    final maxWidth = math.max(200.0, screen.width - 16);
    final width = math.min(
      (widget.anchorWidth - 16).clamp(320.0, 720.0),
      maxWidth,
    );
    // On screens narrower than width + 16 the naive upper bound goes
    // negative, which would make clamp() throw (lowerLimit > upperLimit).
    final maxLeft = math.max(8.0, screen.width - width - 8.0);
    final left =
        (widget.anchorRect.left + (widget.anchorRect.width - width) / 2).clamp(
          8.0,
          maxLeft,
        );
    final clipHeight = widget.anchorRect.top.clamp(0.0, screen.height);
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _close,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: clipHeight,
          child: ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: left,
                  width: width,
                  bottom: 0,
                  child: FadeTransition(
                    opacity: _fadeIn,
                    child: AnimatedSlide(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      offset: _offset,
                      child: _GlassPanel(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(14),
                        ),
                        // The panel grows upward from the pill; when the pill
                        // sits close to the screen top (tall LivePanel:
                        // keyboard + expanded options card + live entries) the
                        // headroom [clipHeight] shrinks below the content
                        // height. Cap the panel there and let the content
                        // scroll instead of clipping it unreachably.
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: clipHeight),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        l10n.chatInputBarImageModeInfoTitle,
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                          color: cs.onSurface,
                                        ),
                                      ),
                                    ),
                                    IosIconButton(
                                      icon: Icons.close,
                                      size: 16,
                                      color: cs.onSurfaceVariant,
                                      semanticLabel: l10n
                                          .chatInputBarImageModeInfoDismissTooltip,
                                      onTap: _close,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  l10n.chatInputBarImageModeInfoBody,
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.5,
                                    color: cs.onSurface.withValues(alpha: 0.82),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.child, this.borderRadius});

  final Widget child;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: (isDark ? Colors.black : Colors.white).withValues(
              alpha: isDark ? 0.28 : 0.56,
            ),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: isDark ? 0.06 : 0.18),
                width: 0.7,
              ),
              left: BorderSide(
                color: Colors.white.withValues(alpha: isDark ? 0.04 : 0.12),
                width: 0.6,
              ),
              right: BorderSide(
                color: Colors.white.withValues(alpha: isDark ? 0.04 : 0.12),
                width: 0.6,
              ),
            ),
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}
