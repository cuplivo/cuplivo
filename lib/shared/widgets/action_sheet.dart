import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:Cuplivo/core/services/haptics.dart';
import 'package:Cuplivo/desktop/desktop_context_menu.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/shared/widgets/section_card.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// One row in [showMobileActionSheet] / [showAdaptiveActionMenu].
///
/// Mirrors `message_more_sheet.dart` `_actionItem`.
class ActionSheetItem {
  const ActionSheetItem({
    this.icon,
    this.svgAsset,
    required this.label,
    required this.onTap,
    this.destructive = false,
    this.checked = false,
    this.key,
  });

  final IconData? icon;

  /// Branded glyph used instead of [icon] (for example a vendor mark).
  final String? svgAsset;
  final String label;
  final VoidCallback onTap;
  final bool destructive;
  final bool checked;
  final Key? key;
}

bool _isDesktopPlatform() {
  return defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
}

/// Mobile ⋯ menu matching `showMessageMoreSheet` (overlaySurface, top
/// radius 20, handle, h48 r14 tiles).
///
/// Pops the sheet before invoking [ActionSheetItem.onTap].
Future<void> showMobileActionSheet(
  BuildContext context, {
  String? title,
  required List<ActionSheetItem> items,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.overlaySurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _MobileActionSheet(title: title, items: items),
  );
}

/// Desktop: a context menu at [anchor] (or anchored to [anchorKey] when the
/// menu belongs to a widget rather than a pointer), with `danger:` from
/// [ActionSheetItem.destructive]. Mobile: [showMobileActionSheet].
///
/// Platform branch matches `message_more_sheet.dart`.
Future<void> showAdaptiveActionMenu(
  BuildContext context, {
  Offset? anchor,
  GlobalKey? anchorKey,
  String? title,
  required List<ActionSheetItem> items,
}) {
  if (_isDesktopPlatform()) {
    final desktopItems = [
      for (final item in items)
        DesktopContextMenuItem(
          icon: item.icon,
          svgAsset: item.svgAsset,
          label: item.label,
          danger: item.destructive,
          checked: item.checked,
          onTap: item.onTap,
        ),
    ];
    if (anchorKey != null) {
      return showDesktopAnchoredMenu(
        context,
        anchorKey: anchorKey,
        items: desktopItems,
      );
    }
    if (anchor == null) return Future<void>.value();
    return showDesktopContextMenuAt(
      context,
      globalPosition: anchor,
      items: desktopItems,
    );
  }
  return showMobileActionSheet(context, title: title, items: items);
}

class _MobileActionSheet extends StatelessWidget {
  const _MobileActionSheet({this.title, required this.items});

  final String? title;
  final List<ActionSheetItem> items;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 6),
                child: Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (title != null) ...[
                      Text(
                        title!,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: AppFontWeights.semibold,
                          color: cs.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    for (final item in items) _ActionTile(item: item),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.item});

  final ActionSheetItem item;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = item.destructive ? cs.error : cs.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SizedBox(
        height: 48,
        child: IosCardPress(
          key: item.key,
          borderRadius: BorderRadius.circular(14),
          baseColor: sheetTileColor(context),
          duration: const Duration(milliseconds: 260),
          onTap: () {
            Haptics.light();
            final action = item.onTap;
            Navigator.of(context).pop();
            action();
          },
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (item.svgAsset != null)
                SvgPicture.asset(
                  item.svgAsset!,
                  width: 20,
                  height: 20,
                  colorFilter: ColorFilter.mode(fg, BlendMode.srcIn),
                )
              else if (item.icon != null)
                Icon(item.icon, size: 20, color: fg),
              if (item.svgAsset != null || item.icon != null)
                const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.medium,
                    color: fg,
                  ),
                ),
              ),
              if (item.checked) Icon(Lucide.Check, size: 18, color: cs.primary),
            ],
          ),
        ),
      ),
    );
  }
}
