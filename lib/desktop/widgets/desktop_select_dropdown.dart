import 'dart:async';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/providers/settings_provider.dart';
import '../../icons/lucide_adapter.dart' as lucide;

class DesktopSelectOption<T> {
  const DesktopSelectOption({
    required this.value,
    required this.label,
    this.leading,
  });

  final T value;
  final String label;

  /// Optional leading glyph rendered before the label (e.g. a flag emoji).
  final String? leading;

  @override
  bool operator ==(Object other) =>
      other is DesktopSelectOption<T> &&
      other.value == value &&
      other.label == label &&
      other.leading == leading;

  @override
  int get hashCode => Object.hash(value, label, leading);
}

class DesktopSelectDropdown<T> extends StatefulWidget {
  const DesktopSelectDropdown({
    super.key,
    required this.value,
    required this.options,
    required this.onSelected,
    this.minWidth = 100,
    this.minHeight = 34,
    this.padding = const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
    this.borderRadius = 10,
    this.maxLabelWidth = 240,
    this.triggerFillColor,
    this.menuBackgroundColor,
    this.footer,
    this.focusable = false,
    this.semanticLabel,
  });

  final T value;
  final List<DesktopSelectOption<T>> options;
  final FutureOr<void> Function(T value) onSelected;

  final double minWidth;
  final double minHeight;
  final EdgeInsets padding;
  final double borderRadius;
  final double maxLabelWidth;
  final Color? triggerFillColor;
  final Color? menuBackgroundColor;

  /// Optional footer widget rendered below the option list (after a divider),
  /// e.g. a "Manage…" action. Tapping it closes the menu before its own action
  /// runs, so it never launches a modal underneath an open menu.
  final Widget? footer;

  /// Whether the trigger joins keyboard tab traversal and shows a focus ring.
  /// Opt-in so the pre-existing call sites do not silently gain a tab stop.
  final bool focusable;

  /// Optional semantics label announced for the trigger.
  final String? semanticLabel;

  @override
  State<DesktopSelectDropdown<T>> createState() =>
      _DesktopSelectDropdownState<T>();
}

class _DesktopSelectDropdownState<T> extends State<DesktopSelectDropdown<T>> {
  bool _hover = false;
  bool _focused = false;
  bool _open = false;
  bool _overlayFocused = false;
  final FocusNode _triggerFocusNode = FocusNode(
    debugLabel: 'DesktopSelectDropdownTrigger',
  );
  final LayerLink _link = LayerLink();
  final GlobalKey _triggerKey = GlobalKey();
  OverlayEntry? _entry;

  @override
  void dispose() {
    _removeEntry();
    _triggerFocusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DesktopSelectDropdown<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The open menu captures the option list once; refresh it when the list or
    // selection changes underneath (e.g. a user-managed list shrinks). Deferred
    // to post-frame: the overlay entry is not a build descendant of this state.
    final entry = _entry;
    if (entry != null &&
        (widget.value != oldWidget.value ||
            !listEquals(widget.options, oldWidget.options))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_entry == entry) entry.markNeedsBuild();
      });
    }
  }

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
  }

  void _toggle() {
    if (_open) {
      _close();
    } else {
      _openMenu();
    }
  }

  void _close() {
    if (!_open && _entry == null) return;
    // Return focus to the trigger before the overlay (and its focus node)
    // leaves the tree, otherwise focus resolution can land on a dead subtree.
    if (_overlayFocused && _triggerFocusNode.canRequestFocus) {
      _triggerFocusNode.requestFocus();
    }
    _overlayFocused = false;
    if (mounted) setState(() => _open = false);
    final entry = _entry;
    _entry = null;
    if (entry != null) {
      // Deferred: let the overlay's focus node unmount this frame before the
      // entry is actually removed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (entry.mounted) entry.remove();
      });
    }
  }

  ({String label, String? leading}) _triggerInfo(T v) {
    for (final opt in widget.options) {
      if (opt.value == v) return (label: opt.label, leading: opt.leading);
    }
    if (widget.options.isNotEmpty) {
      final first = widget.options.first;
      return (label: first.label, leading: first.leading);
    }
    return (label: '', leading: null);
  }

  Color _defaultMenuBackground(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    SettingsProvider? sp;
    try {
      sp = Provider.of<SettingsProvider>(context, listen: false);
    } catch (_) {
      sp = null;
    }
    final usePure = sp?.usePureBackground ?? false;
    if (usePure) return isDark ? Colors.black : Colors.white;
    return context.appColors.surfaceCard;
  }

  KeyEventResult _onTriggerKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      _toggle();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape && _open) {
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _openMenu() {
    if (_open) return;
    final rb = _triggerKey.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null) return;
    final triggerSize = rb.size;
    final triggerWidth = triggerSize.width;
    // Keyboard-opened menus take focus; mouse-opened ones do not steal it.
    final grabFocus = widget.focusable && _triggerFocusNode.hasFocus;

    _entry = OverlayEntry(
      builder: (ctx) {
        final bgColor =
            widget.menuBackgroundColor ?? _defaultMenuBackground(ctx);
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _close,
                child: const SizedBox.expand(),
              ),
            ),
            CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              offset: Offset(0, triggerSize.height + 6),
              child: _DesktopSelectOverlay<T>(
                width: triggerWidth,
                backgroundColor: bgColor,
                options: widget.options,
                selected: widget.value,
                footer: widget.footer,
                autofocus: grabFocus,
                tilesFocusable: widget.focusable,
                onFocusChange: (value) {
                  if (_overlayFocused != value) _overlayFocused = value;
                },
                onClose: _close,
                onSelected: (v) async {
                  _close();
                  await widget.onSelected(v);
                },
              ),
            ),
          ],
        );
      },
    );
    Overlay.of(context).insert(_entry!);
    setState(() => _open = true);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final info = _triggerInfo(widget.value);
    final label = info.label;
    final leading = info.leading;

    final baseBorder = cs.outlineVariant.withValues(alpha: 0.18);
    final hoverBorder = cs.primary;
    final highlight = _open || _hover || (widget.focusable && _focused);
    final borderColor = highlight ? hoverBorder : baseBorder;

    final fillColor = widget.triggerFillColor ?? context.appColors.surfaceCard;

    Widget trigger = CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: _toggle,
          child: AnimatedContainer(
            key: _triggerKey,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            padding: widget.padding,
            constraints: BoxConstraints(
              minWidth: widget.minWidth,
              minHeight: widget.minHeight,
            ),
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(widget.borderRadius),
              border: Border.all(color: borderColor, width: 1),
              boxShadow: _open
                  ? [
                      BoxShadow(
                        color: cs.primary.withValues(alpha: 0.10),
                        blurRadius: 0,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final availableWidth = constraints.hasBoundedWidth
                        ? constraints.maxWidth
                        : widget.maxLabelWidth + 24;
                    final leadingWidth = leading == null ? 0.0 : 24.0;
                    final labelMaxWidth = (availableWidth - 24 - leadingWidth)
                        .clamp(0.0, widget.maxLabelWidth)
                        .toDouble();
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (leading != null) ...[
                          Text(
                            leading,
                            style: const TextStyle(fontSize: 16, height: 1),
                          ),
                          const SizedBox(width: 8),
                        ],
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: labelMaxWidth),
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              color: cs.onSurface.withValues(alpha: 0.88),
                            ),
                          ),
                        ),
                        const SizedBox(width: 24),
                      ],
                    );
                  },
                ),
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: AnimatedRotation(
                      turns: _open ? 0.5 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        lucide.Lucide.ChevronDown,
                        size: 16,
                        color: cs.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    trigger = Focus(
      focusNode: _triggerFocusNode,
      canRequestFocus: widget.focusable,
      skipTraversal: !widget.focusable,
      onKeyEvent: widget.focusable ? _onTriggerKeyEvent : null,
      onFocusChange: widget.focusable
          ? (value) => setState(() => _focused = value)
          : null,
      child: trigger,
    );

    return Semantics(
      button: true,
      expanded: _open,
      label: widget.semanticLabel,
      child: trigger,
    );
  }
}

class _DesktopSelectOverlay<T> extends StatefulWidget {
  const _DesktopSelectOverlay({
    required this.width,
    required this.backgroundColor,
    required this.options,
    required this.selected,
    required this.onSelected,
    required this.onClose,
    required this.autofocus,
    required this.tilesFocusable,
    required this.onFocusChange,
    this.footer,
  });

  final double width;
  final Color backgroundColor;
  final List<DesktopSelectOption<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final VoidCallback onClose;
  final bool autofocus;
  final bool tilesFocusable;
  final ValueChanged<bool> onFocusChange;
  final Widget? footer;

  @override
  State<_DesktopSelectOverlay<T>> createState() =>
      _DesktopSelectOverlayState<T>();
}

class _DesktopSelectOverlayState<T> extends State<_DesktopSelectOverlay<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;
  final FocusNode _focusNode = FocusNode(debugLabel: 'DesktopSelectOverlay');

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ctrl.forward();
      // `autofocus` alone does not take focus inside an OverlayEntry; request
      // it explicitly for keyboard-opened menus.
      if (mounted && widget.autofocus) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = cs.outlineVariant.withValues(alpha: 0.12);

    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _slide,
        child: Material(
          color: Colors.transparent,
          child: Shortcuts(
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
              SingleActivator(LogicalKeyboardKey.arrowUp):
                  PreviousFocusIntent(),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                NextFocusIntent: CallbackAction<NextFocusIntent>(
                  onInvoke: (_) {
                    FocusScope.of(context).nextFocus();
                    return null;
                  },
                ),
                PreviousFocusIntent: CallbackAction<PreviousFocusIntent>(
                  onInvoke: (_) {
                    FocusScope.of(context).previousFocus();
                    return null;
                  },
                ),
              },
              child: Focus(
                focusNode: _focusNode,
                autofocus: widget.autofocus,
                onFocusChange: widget.onFocusChange,
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.escape) {
                    widget.onClose();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Container(
                  constraints: BoxConstraints(
                    minWidth: widget.width,
                    maxWidth: widget.width,
                  ),
                  decoration: BoxDecoration(
                    color: widget.backgroundColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: borderColor, width: 0.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: isDark ? 0.32 : 0.08,
                        ),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 360),
                        child: Scrollbar(
                          thickness: 6,
                          radius: const Radius.circular(3),
                          child: ListView.builder(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: widget.options.length,
                            itemBuilder: (context, index) {
                              final opt = widget.options[index];
                              return _DesktopSelectOptionTile(
                                label: opt.label,
                                leading: opt.leading,
                                selected: widget.selected == opt.value,
                                focusable: widget.tilesFocusable,
                                onTap: () => widget.onSelected(opt.value),
                              );
                            },
                          ),
                        ),
                      ),
                      if (widget.footer != null) ...[
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.all(6),
                          child: Listener(
                            behavior: HitTestBehavior.translucent,
                            // Close before the footer's own action runs so a
                            // launched modal never sits under an open menu.
                            onPointerDown: (_) => widget.onClose(),
                            child: widget.footer!,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopSelectOptionTile extends StatefulWidget {
  const _DesktopSelectOptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.focusable,
    this.leading,
  });

  final String label;
  final String? leading;
  final bool selected;
  final bool focusable;
  final VoidCallback onTap;

  @override
  State<_DesktopSelectOptionTile> createState() =>
      _DesktopSelectOptionTileState();
}

class _DesktopSelectOptionTileState extends State<_DesktopSelectOptionTile> {
  bool _hover = false;
  bool _active = false;
  bool _focused = false;

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      widget.onTap();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onFocusChange(bool value) {
    if (value) {
      // Keep the focused option inside the 360px viewport when arrows move
      // past the visible edge.
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
      );
    }
    setState(() => _focused = value);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = widget.selected
        ? cs.primary.withValues(alpha: 0.12)
        : (_hover || _focused
              ? cs.onSurface.withValues(alpha: isDark ? 0.08 : 0.04)
              : Colors.transparent);
    return Focus(
      canRequestFocus: widget.focusable,
      skipTraversal: !widget.focusable,
      onKeyEvent: widget.focusable ? _onKeyEvent : null,
      onFocusChange: widget.focusable ? _onFocusChange : null,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _active = true),
          onTapCancel: () => setState(() => _active = false),
          onTapUp: (_) => setState(() => _active = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _active ? 0.98 : 1.0,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(8),
                border: _focused
                    ? Border.all(color: cs.primary, width: 1)
                    : null,
              ),
              child: Row(
                children: [
                  if (widget.leading != null) ...[
                    Text(
                      widget.leading!,
                      style: const TextStyle(fontSize: 16, height: 1),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: cs.onSurface.withValues(alpha: 0.88),
                        fontWeight: widget.selected
                            ? AppFontWeights.semibold
                            : AppFontWeights.regular,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Opacity(
                    opacity: widget.selected ? 1 : 0,
                    child: Icon(
                      lucide.Lucide.Check,
                      size: 14,
                      color: cs.primary,
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
