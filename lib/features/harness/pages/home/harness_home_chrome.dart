import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:Cuplivo/features/home/widgets/side_drawer.dart';
import 'package:Cuplivo/features/side_panel/widgets/side_panel_geometry.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/interactive_drawer.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

/// The harness-mode bundle the existing home scaffolds render instead of the
/// local chat surface.
///
/// Both `HomeMobileScaffold` and `HomeDesktopScaffold` take this additively: a
/// null bundle is byte-identical to the local path, a non-null one replaces the
/// app bar, the chat body, the drawer's list source and (on desktop) the
/// right-hand panel. The harness page builds it once per remote; no layout
/// learns a DSH concept beyond "render this".
@immutable
class HarnessHomeChrome {
  const HarnessHomeChrome({
    required this.body,
    required this.appBar,
    required this.sidebarSource,
    required this.rail,
    required this.railController,
    required this.railOpen,
    required this.railExpanded,
  });

  /// The chat surface: `HarnessConversationView` for the open session, or an
  /// honest empty/offline state when there is none.
  final Widget body;

  /// R6 app bar: hamburger, session title + `model (provider)` subtitle, the
  /// new-session action and the right-rail toggle to its right.
  final PreferredSizeWidget appBar;

  /// Drawer data source in remote mode.
  final RemoteSidebarSource sidebarSource;

  /// The rail content (header + pages).
  final Widget rail;

  /// Right drawer controller for the mobile layout.
  final InteractiveDrawerController railController;

  /// Whether the rail is open (drives the desktop push and the drawer).
  final bool railOpen;

  /// Whether the rail asked for the whole width (desktop push-off; mobile
  /// drawer width).
  final bool railExpanded;
}

/// R6 app bar for the DeepSeek Harness home surface.
///
/// The local app bar's minimap, multi-select, find and temporary-chat actions
/// are local-chat concepts; harness mode replaces the whole bar instead of
/// leaving dead controls on it. Order on the right follows R6: the
/// new-conversation action first, then the right-rail button to its right.
class HarnessAppBar extends StatelessWidget implements PreferredSizeWidget {
  const HarnessAppBar({
    super.key,
    required this.title,
    this.subtitle,
    required this.onToggleSidebar,
    required this.onNewSession,
    required this.onToggleRail,
    required this.railOpen,
    this.onSelectModel,
    this.isDesktop = false,
  });

  final String title;

  /// `model (provider)`, or null when the host has no model selection yet.
  final String? subtitle;

  final VoidCallback onToggleSidebar;
  final VoidCallback onNewSession;
  final VoidCallback onToggleRail;
  final bool railOpen;

  /// Desktop/tablet: tapping the model subtitle opens the DSH model picker
  /// (the chat slice supplies the callback; null hides the affordance).
  final VoidCallback? onSelectModel;

  final bool isDesktop;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final subtitle = this.subtitle;
    return AppBar(
      systemOverlayStyle: dark
          ? const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.light,
              statusBarBrightness: Brightness.dark,
            )
          : const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.dark,
              statusBarBrightness: Brightness.light,
            ),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      // The harness body scrolls behind this bar (`extendBodyBehindAppBar`), so
      // the bar paints a frosted scrim: without it the transcript legibly runs
      // through the title. Same treatment as DSH's floating session header.
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: ColoredBox(
            color: cs.surface.withValues(alpha: dark ? 0.7 : 0.78),
          ),
        ),
      ),
      leading: IosIconButton(
        size: 20,
        padding: const EdgeInsets.all(8),
        minSize: 40,
        builder: (color) => SvgPicture.asset(
          'assets/icons/list.svg',
          width: 14,
          height: 14,
          colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        ),
        onTap: onToggleSidebar,
        semanticLabel: l10n.dshRailToggle,
      ),
      titleSpacing: 2,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: isDesktop ? 14 : 16,
              fontWeight: AppFontWeights.medium,
            ),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: IosCardPress(
                borderRadius: BorderRadius.circular(6),
                baseColor: Colors.transparent,
                padding: EdgeInsets.zero,
                onTap: onSelectModel,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurface.withValues(alpha: 0.6),
                          fontWeight: AppFontWeights.medium,
                        ),
                      ),
                    ),
                    if (onSelectModel != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 2),
                        child: Icon(
                          Lucide.ChevronDown,
                          size: 12,
                          color: cs.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
      actions: [
        IosIconButton(
          key: const Key('dsh-new-session'),
          size: 21,
          minSize: 44,
          icon: Lucide.MessageCirclePlus,
          onTap: onNewSession,
          semanticLabel: l10n.dshNewSessionTooltip,
          tooltip: l10n.dshNewSessionTooltip,
        ),
        IosIconButton(
          key: const Key('dsh-right-rail-button'),
          size: 20,
          minSize: 44,
          icon: Lucide.panelRight,
          color: railOpen ? cs.primary : null,
          onTap: onToggleRail,
          semanticLabel: l10n.dshRailToggle,
          tooltip: l10n.dshRailToggle,
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// Places the right rail next to the conversation on desktop/tablet.
///
/// It uses the one shared geometry decision (`SidePanelGeometry`): a wide
/// surface docks the rail as a column and the conversation keeps the rest; a
/// narrow one gives the rail the whole width so the conversation is pushed
/// off-screen rather than stacked underneath a floating panel (R7's rule).
class HarnessRightRailHost extends StatelessWidget {
  const HarnessRightRailHost({
    super.key,
    required this.open,
    required this.expanded,
    required this.rail,
    required this.child,
    this.preferredWidth = SidePanelGeometry.defaultWidth,
  });

  final bool open;
  final bool expanded;
  final Widget rail;
  final Widget child;
  final double preferredWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        final presentation = SidePanelGeometry.presentationFor(
          open: open,
          expanded: expanded,
          availableWidth: available,
        );
        // Only the `docked` presentation keeps the conversation on screen; the
        // overlay decision means the surface is too narrow to dock, and the
        // rail takes it all so nothing is stacked on the conversation.
        final targetWidth = switch (presentation) {
          SidePanelPresentation.hidden => 0.0,
          SidePanelPresentation.docked => SidePanelGeometry.widthFor(
            presentation: presentation,
            preferredWidth: preferredWidth,
            availableWidth: available,
          ),
          SidePanelPresentation.overlay ||
          SidePanelPresentation.expanded => available,
        };
        final chatVisible =
            presentation == SidePanelPresentation.hidden ||
            presentation == SidePanelPresentation.docked;
        final reduceMotion = MediaQuery.disableAnimationsOf(context);
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: targetWidth),
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          builder: (context, width, _) {
            return Row(
              children: [
                Expanded(
                  child: Offstage(offstage: !chatVisible, child: child),
                ),
                ClipRect(
                  child: SizedBox(
                    width: width,
                    child: width <= 0 || !open
                        ? const SizedBox.shrink()
                        : OverflowBox(
                            alignment: Alignment.centerLeft,
                            minWidth: targetWidth,
                            maxWidth: targetWidth,
                            child: rail,
                          ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
