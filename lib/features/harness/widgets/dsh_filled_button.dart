import 'package:flutter/material.dart';

import 'package:Cuplivo/core/services/haptics.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

/// The full-width filled action used by the DSH connection card (`确认`).
///
/// Cuplivo has no shared filled iOS button: each settings page keeps a private
/// one. The DSH surfaces share this copy so the creation form and the assistant
/// settings page cannot drift, and it carries the E2E hook key.
class DshFilledButton extends StatefulWidget {
  const DshFilledButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.enabled = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final bool enabled;

  @override
  State<DshFilledButton> createState() => _DshFilledButtonState();
}

class _DshFilledButtonState extends State<DshFilledButton> {
  bool _pressed = false;

  void _set(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = widget.enabled && !widget.busy && widget.onPressed != null;
    final background = active
        ? cs.primary
        : cs.onSurface.withValues(alpha: 0.12);
    final foreground = active
        ? cs.onPrimary
        : cs.onSurface.withValues(alpha: 0.45);

    return Semantics(
      button: true,
      enabled: active,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: active ? (_) => _set(true) : null,
        onTapUp: active ? (_) => _set(false) : null,
        onTapCancel: () => _set(false),
        onTap: active
            ? () {
                Haptics.soft();
                widget.onPressed!.call();
              }
            : null,
        child: AnimatedScale(
          scale: _pressed ? 0.98 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(12),
            ),
            child: widget.busy
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  )
                : Text(
                    widget.label,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 15,
                      fontWeight: AppFontWeights.semibold,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
