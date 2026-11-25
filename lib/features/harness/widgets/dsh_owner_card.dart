import 'package:flutter/material.dart';

import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

import '../../../l10n/app_localizations.dart';
import '../models/dsh_remote.dart';
import '../state/dsh_gateway.dart';
import 'dsh_link_status_dot.dart';
import 'dsh_whale_mark.dart';

/// One remote DeepSeek Harness as a list card: whale avatar, name, the
/// purpose-built subtitle and the live-link dot.
///
/// The assistant settings list and the desktop 助手与群聊 pane both render
/// owners, and they share one card so a remote row cannot look like two
/// different things depending on the window width. [dense] is the desktop
/// variant (18 dp radius, 16 dp padding, 48 dp avatar); the default matches the
/// mobile assistant card.
///
/// The card is the tap target that opens the DSH assistant settings page; call
/// sites pass the E2E hook key (`dsh-owner-card`) here.
class DshOwnerCard extends StatefulWidget {
  const DshOwnerCard({
    super.key,
    required this.remote,
    required this.subtitle,
    required this.onTap,
    this.status = const DshLinkStatus.idle(),
    this.dense = false,
    this.onLongPress,
  });

  final DshRemote remote;
  final String subtitle;
  final VoidCallback onTap;
  final DshLinkStatus status;
  final bool dense;
  final VoidCallback? onLongPress;

  @override
  State<DshOwnerCard> createState() => _DshOwnerCardState();
}

class _DshOwnerCardState extends State<DshOwnerCard> {
  bool _pressed = false;
  bool _hovered = false;

  bool get _isDesktop =>
      Theme.of(context).platform == TargetPlatform.macOS ||
      Theme.of(context).platform == TargetPlatform.windows ||
      Theme.of(context).platform == TargetPlatform.linux;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final overlay = _pressed
        ? cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.04)
        : Colors.transparent;
    final baseBg = context.appColors.surfaceCard;
    final radius = widget.dense ? 18.0 : 14.0;
    final borderColor = widget.dense && _hovered
        ? cs.primary.withValues(alpha: isDark ? 0.35 : 0.45)
        : cs.outlineVariant.withValues(alpha: isDark ? 0.12 : 0.08);
    final avatarSize = widget.dense ? 48.0 : 44.0;

    final card = Container(
      decoration: BoxDecoration(
        color: Color.alphaBlend(overlay, baseBg),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor, width: widget.dense ? 1.0 : 0.8),
      ),
      padding: EdgeInsets.all(widget.dense ? 16 : 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          DshWhaleAvatar(size: avatarSize),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.remote.name.trim().isEmpty
                            ? AppLocalizations.of(context)!.dshProductName
                            : widget.remote.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: AppFontWeights.emphasis,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    DshLinkStatusDot(status: widget.status),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  widget.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.7),
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final interactive = MouseRegion(
      cursor: _isDesktop ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (_isDesktop && widget.dense && !_hovered) {
          setState(() => _hovered = true);
        }
      },
      onExit: (_) {
        if (_isDesktop && widget.dense && _hovered) {
          setState(() => _hovered = false);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _pressed ? 0.98 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            child: card,
          ),
        ),
      ),
    );
    return interactive;
  }
}
