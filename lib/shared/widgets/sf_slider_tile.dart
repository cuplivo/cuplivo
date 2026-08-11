import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_core/theme.dart';
import 'package:syncfusion_flutter_sliders/sliders.dart';

import '../../theme/app_font_weights.dart';

/// Shared slider built on Syncfusion [SfSlider].
///
/// Syncfusion's slider draws its track, thumb and tooltip entirely inside its
/// own widget tree (it never creates an [OverlayPortal]), so it is safe on
/// Windows where Material [Slider]'s OverlayPortal can serialize orphan
/// semantics nodes and corrupt the accessibility tree
/// (https://github.com/flutter/flutter/issues/190357).
///
/// Visual style follows the assistant settings sliders
/// ([SfSliderTheme] + waterdrop tooltip), while keyboard access and the
/// screen-reader value/increase/decrease actions are provided by [SfSlider]
/// itself.
class SfSliderTile extends StatelessWidget {
  const SfSliderTile({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.label,
    required this.onChanged,
    this.onChangeEnd,
    this.semanticLabel,
    this.semanticFormatterCallback,
    this.showTicks = false,
    this.showLabels = false,
    this.interval,
  }) : assert(min < max),
       assert(divisions == null || divisions > 0);

  /// The current value, clamped to [min]..[max] before rendering.
  final double value;

  final double min;

  final double max;

  /// Number of equal steps the range is divided into, mirroring Material's
  /// `divisions` semantics: `step = (max - min) / divisions`.
  ///
  /// When null the slider moves continuously.
  final int? divisions;

  /// Text shown in the waterdrop tooltip while interacting.
  final String label;

  final ValueChanged<double> onChanged;

  final ValueChanged<double>? onChangeEnd;

  /// Screen-reader label for the slider node.
  final String? semanticLabel;

  /// Formats the screen-reader value (e.g. `1024px`, `80%`).
  final String Function(double value)? semanticFormatterCallback;

  final bool showTicks;

  final bool showLabels;

  /// Label/ticks interval, computed like the assistant settings slider when
  /// null.
  final double? interval;

  double? get _stepSize => divisions == null ? null : (max - min) / divisions!;

  double _toDouble(dynamic v) => v is num ? v.toDouble() : (v as double);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final active = cs.primary;
    final inactive = cs.onSurface.withValues(alpha: isDark ? 0.25 : 0.20);
    final clamped = value.clamp(min, max).toDouble();
    final total = (max - min).abs();
    final step = _stepSize;

    // Compute a readable major interval and minor tick count, matching the
    // assistant settings slider.
    double resolvedInterval;
    if (interval != null) {
      resolvedInterval = interval!;
    } else if (total <= 0) {
      resolvedInterval = 1;
    } else if ((divisions ?? 0) <= 20) {
      resolvedInterval = total / 4; // up to 5 major ticks inc endpoints
    } else if ((divisions ?? 0) <= 50) {
      resolvedInterval = total / 5;
    } else {
      resolvedInterval = total / 8;
    }
    if (resolvedInterval <= 0) resolvedInterval = 1;
    int minor = 0;
    if (step != null && step > 0) {
      minor = ((resolvedInterval / step) - 1).round();
      if (minor < 0) minor = 0;
      if (minor > 8) minor = 8;
    }

    final slider = SfSliderTheme(
      data: SfSliderThemeData(
        activeTrackHeight: 8,
        inactiveTrackHeight: 8,
        overlayRadius: 14,
        activeTrackColor: active,
        inactiveTrackColor: inactive,
        // Waterdrop tooltip uses theme primary background with onPrimary text
        tooltipBackgroundColor: cs.primary,
        tooltipTextStyle: TextStyle(
          color: cs.onPrimary,
          fontWeight: AppFontWeights.semibold,
        ),
        thumbStrokeColor: Colors.transparent,
        thumbStrokeWidth: 0,
        activeTickColor: cs.onSurface.withValues(alpha: isDark ? 0.45 : 0.35),
        inactiveTickColor: cs.onSurface.withValues(alpha: isDark ? 0.30 : 0.25),
        activeMinorTickColor: cs.onSurface.withValues(
          alpha: isDark ? 0.34 : 0.28,
        ),
        inactiveMinorTickColor: cs.onSurface.withValues(
          alpha: isDark ? 0.24 : 0.20,
        ),
      ),
      child: SfSlider(
        value: clamped,
        min: min,
        max: max,
        stepSize: step,
        enableTooltip: true,
        // Show the paddle tooltip only while interacting
        shouldAlwaysShowTooltip: false,
        showTicks: showTicks,
        showLabels: showLabels,
        interval: resolvedInterval,
        minorTicksPerInterval: minor,
        activeColor: active,
        inactiveColor: inactive,
        tooltipTextFormatterCallback: (actual, text) => label,
        tooltipShape: const SfPaddleTooltipShape(),
        labelFormatterCallback: (actual, formattedText) {
          // Prefer integers for wide ranges, keep 2 decimals for 0..1
          if (total <= 2.0) return actual.toStringAsFixed(2);
          if (actual == actual.roundToDouble()) {
            return actual.toStringAsFixed(0);
          }
          return actual.toStringAsFixed(1);
        },
        semanticFormatterCallback: semanticFormatterCallback == null
            ? null
            : (v) => semanticFormatterCallback!(_toDouble(v)),
        thumbIcon: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: cs.primary,
            shape: BoxShape.circle,
            boxShadow: isDark
                ? const []
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
          ),
        ),
        onChanged: (v) => onChanged(_toDouble(v)),
        onChangeEnd: onChangeEnd == null
            ? null
            : (v) => onChangeEnd!(_toDouble(v)),
      ),
    );
    final accessibilityLabel = semanticLabel;
    // SfSlider exposes its value and increase/decrease actions on its own
    // semantic node but no label, so attach the label on a wrapping node.
    return accessibilityLabel == null
        ? slider
        : Semantics(label: accessibilityLabel, child: slider);
  }
}
