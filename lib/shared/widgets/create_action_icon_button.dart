import 'package:flutter/material.dart';

import '../../core/services/haptics.dart';
import '../../icons/lucide_adapter.dart';

/// Icon button with a small "+" badge in the top-right corner, used for
/// "create" actions (new assistant, new group chat, ...). Shared by the
/// desktop and mobile settings pages.
class CreateActionIconButton extends StatefulWidget {
  const CreateActionIconButton({
    super.key,
    required this.baseIcon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  final IconData baseIcon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  @override
  State<CreateActionIconButton> createState() => _CreateActionIconButtonState();
}

class _CreateActionIconButtonState extends State<CreateActionIconButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final color = _pressed
        ? widget.color.withValues(alpha: 0.7)
        : widget.color;
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: () {
            Haptics.light();
            widget.onTap();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
            child: SizedBox(
              width: 24,
              height: 24,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.center,
                      child: Icon(widget.baseIcon, size: 20, color: color),
                    ),
                  ),
                  Positioned(
                    right: -1,
                    top: -1,
                    child: Container(
                      width: 11,
                      height: 11,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Icon(Lucide.Plus, size: 9, color: color),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
