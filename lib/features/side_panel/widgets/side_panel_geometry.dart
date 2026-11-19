import 'dart:math' as math;

/// How a right panel is placed next to the conversation surface it belongs to.
///
/// One panel, one decision: the local desktop side panel and the DeepSeek
/// Harness right rail both ask [SidePanelGeometry], so the width a docked panel
/// leaves for the chat can never disagree between the two surfaces.
enum SidePanelPresentation {
  /// Closed; the conversation has the whole available width.
  hidden,

  /// A column on the right; the conversation keeps the remaining width.
  docked,

  /// The available width cannot carry a docked column, so the panel floats.
  overlay,

  /// The panel owns the whole available width; the conversation is off-screen.
  expanded,
}

/// The geometry of a right panel, independent of any controller state.
///
/// Pure functions on purpose: the presentation decision is testable without a
/// [ChangeNotifier], a browser engine or a widget tree. A controller passes its
/// own open/expanded/width state in and stores the answer.
abstract final class SidePanelGeometry {
  /// Width a panel opens with before the user resizes it.
  static const double defaultWidth = 520;

  /// The narrowest a docked panel may be dragged.
  static const double minWidth = 360;

  /// The widest a docked panel may be dragged, before the available width caps
  /// it further.
  static const double maxWidth = 900;

  /// Width the conversation must keep when a panel docks. A panel docks only
  /// when [dockThreshold] is exceeded, so this is the minimum chat column the
  /// `docked` presentation promises.
  static const double chatReserve = 489;

  /// Available width at or above which the panel docks instead of floating.
  ///
  /// Derived, not restated: a docked panel must fit [minWidth] beside the
  /// [chatReserve] the conversation keeps, so the two limits cannot drift apart.
  static const double dockThreshold = minWidth + chatReserve;

  /// Preference key prefix of the local desktop side panel.
  ///
  /// The five keys are spelled out below because they are persisted names: an
  /// external scan of the source (`business_key_registry_sync_test`) has to be
  /// able to name every key the app writes, and an interpolation is not a name.
  static const String prefsPrefix = 'desktop_side_panel_';

  static const String keyOpen = 'desktop_side_panel_open_v1';
  static const String keyWidth = 'desktop_side_panel_width_v1';
  static const String keyLastKind = 'desktop_side_panel_last_kind_v1';
  static const String keyTabs = 'desktop_side_panel_tabs_v1';
  static const String keyMigrated = 'desktop_side_panel_migrated_v1';

  const SidePanelGeometry._();

  /// Where the panel goes for [availableWidth] (the width the conversation
  /// surface has to offer, not the window width).
  static SidePanelPresentation presentationFor({
    required bool open,
    required bool expanded,
    required double availableWidth,
  }) {
    if (!open) return SidePanelPresentation.hidden;
    if (expanded) return SidePanelPresentation.expanded;
    return availableWidth >= dockThreshold
        ? SidePanelPresentation.docked
        : SidePanelPresentation.overlay;
  }

  /// The widest a docked panel may be at [availableWidth].
  ///
  /// Never narrower than [minWidth]: a conversation surface too narrow to host
  /// a usable panel resolves to `overlay`, where this cap is not applied.
  static double maxWidthFor(double availableWidth) =>
      math.max(minWidth, math.min(maxWidth, availableWidth - chatReserve));

  /// The width the panel occupies for its [presentation].
  ///
  /// Hidden and docked share the clamped preferred width, so callers can size
  /// the chat layout from one total function instead of branching on open.
  static double widthFor({
    required SidePanelPresentation presentation,
    required double preferredWidth,
    required double availableWidth,
  }) => switch (presentation) {
    SidePanelPresentation.expanded => availableWidth,
    SidePanelPresentation.overlay => math.min(preferredWidth, availableWidth),
    SidePanelPresentation.hidden || SidePanelPresentation.docked =>
      preferredWidth.clamp(minWidth, maxWidthFor(availableWidth)),
  };
}
