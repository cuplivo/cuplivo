import 'package:flutter/material.dart';

class HueSlider extends StatefulWidget {
  final double hue;
  final ValueChanged<double> onChanged;
  final double saturation;
  final double brightness;

  const HueSlider({
    super.key,
    required this.hue,
    required this.onChanged,
    this.saturation = 0.85,
    this.brightness = 0.90,
  });

  @override
  State<HueSlider> createState() => _HueSliderState();
}

class _HueSliderState extends State<HueSlider> {
  static const List<Color> _hueColors = [
    Color(0xFFFF0000),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFF00FFFF),
    Color(0xFF0000FF),
    Color(0xFFFF00FF),
    Color(0xFFFF0000),
  ];

  double _getHueFromDx(double dx, double width) {
    return (dx / width).clamp(0.0, 1.0) * 360.0;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            const trackHeight = 32.0;
            const thumbSize = 28.0;
            return GestureDetector(
              onPanDown: (d) {
                final dx = d.localPosition.dx;
                widget.onChanged(_getHueFromDx(dx, width));
              },
              onPanUpdate: (d) {
                final dx = d.localPosition.dx;
                widget.onChanged(_getHueFromDx(dx, width));
              },
              child: SizedBox(
                height: trackHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      height: trackHeight,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(trackHeight / 2),
                        gradient: const LinearGradient(colors: _hueColors),
                      ),
                    ),
                    Positioned(
                      left: (widget.hue / 360.0) * width - thumbSize / 2,
                      top: (trackHeight - thumbSize) / 2,
                      child: Container(
                        width: thumbSize,
                        height: thumbSize,
                        decoration: BoxDecoration(
                          color: HSVColor.fromAHSV(
                            1.0,
                            widget.hue,
                            widget.saturation,
                            widget.brightness,
                          ).toColor(),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.25),
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: HSVColor.fromAHSV(
              1.0,
              widget.hue,
              widget.saturation,
              widget.brightness,
            ).toColor(),
            shape: BoxShape.circle,
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.4),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
