import 'dart:async';
import 'dart:math' as math;
import 'package:Cuplivo/theme/app_font_weights.dart';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../icons/lucide_adapter.dart' as lucide;
import '../../theme/app_semantic_colors.dart';

class DesktopSelectOption<T> {
  const DesktopSelectOption({
    required this.value,
    required this.label,
    this.subtitle,
    this.leading,
  });

  final T value;
  final String label;
  final String? subtitle;

  /// Optional leading glyph rendered before the label (e.g. a flag emoji).
  final String? leading;

  @override
  bool operator ==(Object other) =>
      other is DesktopSelectOption<T> &&
      other.value == value &&
      other.label == label &&
      other.subtitle == subtitle &&
      other.leading == leading;

  @override
  int get hashCode => Object.hash(value, label, subtitle, leading);
}

bool _optionHasSubtitle<T>(DesktopSelectOption<T> option) {
  final subtitle = option.subtitle;
  return subtitle != null && subtitle.isNotEmpty;
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
    this.triggerForegroundColor,
    this.menuBackgroundColor,
    this.embedded = false,
    this.enabled = true,
    this.focusNode,
    this.placeholder = '',
    this.footer,
    this.focusable = false,
    this.semanticLabel,
    this.semanticHint,
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
  final Color? triggerForegroundColor;
  final Color? menuBackgroundColor;
  final bool enabled;
  final FocusNode? focusNode;
  final String placeholder;
  final String? semanticLabel, semanticHint;

  /// Hide the trigger chrome so a parent field (for example
  /// [InputDecorator]) can supply the border and fill.
  final bool embedded;

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
<<<<<<< HEAD
  bool _focused = false;
  final FocusNode _ownFocus = FocusNode();
  FocusNode get _focus => widget.focusNode ?? _ownFocus;
=======
  bool _overlayFocused = false;
  final FocusNode _triggerFocusNode = FocusNode(
    debugLabel: 'DesktopSelectDropdownTrigger',
  );
>>>>>>> 856aaa70a (feat(translate): user-managed target languages incl. Bengali (#1039))
  final LayerLink _link = LayerLink();
  final GlobalKey _triggerKey = GlobalKey();
  OverlayEntry? _entry;

  @override
  void dispose() {
    _removeEntry();
<<<<<<< HEAD
    _ownFocus.dispose();
=======
    _triggerFocusNode.dispose();
>>>>>>> 856aaa70a (feat(translate): user-managed target languages incl. Bengali (#1039))
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
    _entry?.dispose();
    _entry = null;
  }

  void _toggle() {
    if (!widget.enabled || widget.options.isEmpty) return;
    if (_open) {
      _close();
    } else {
      _openMenu();
    }
  }

  void _close() {
<<<<<<< HEAD
    _removeEntry();
    if (mounted) {
      setState(() => _open = false);
      if (widget.enabled) _focus.requestFocus();
    }
  }

  @override
  void didUpdateWidget(DesktopSelectDropdown<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sameOptions =
        oldWidget.options.length == widget.options.length &&
        List.generate(
          widget.options.length,
          (i) =>
              oldWidget.options[i].value == widget.options[i].value &&
              oldWidget.options[i].label == widget.options[i].label &&
              oldWidget.options[i].subtitle == widget.options[i].subtitle,
        ).every((same) => same);
    if (_open && (!widget.enabled || !sameOptions)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _open) _close();
      });
    } else if (_open &&
        (oldWidget.value != widget.value ||
            oldWidget.menuBackgroundColor != widget.menuBackgroundColor)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _entry?.markNeedsBuild();
=======
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
>>>>>>> 856aaa70a (feat(translate): user-managed target languages incl. Bengali (#1039))
      });
    }
  }

  ({String label, String? leading}) _triggerInfo(T v) {
    for (final opt in widget.options) {
      if (opt.value == v) return (label: opt.label, leading: opt.leading);
    }
<<<<<<< HEAD
    return widget.placeholder;
=======
    if (widget.options.isNotEmpty) {
      final first = widget.options.first;
      return (label: first.label, leading: first.leading);
    }
    return (label: '', leading: null);
>>>>>>> 856aaa70a (feat(translate): user-managed target languages incl. Bengali (#1039))
  }

  Color _defaultMenuBackground(BuildContext context) {
    return context.overlaySurface;
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
    final hasSubtitles = widget.options.any(_optionHasSubtitle);
    var overlayWidth = triggerWidth;
    var overlayDx = 0.0;
    if (hasSubtitles) {
      overlayWidth = triggerWidth < 360 ? 360.0 : triggerWidth;
      if (overlayWidth > 440) overlayWidth = 440.0;
      overlayDx = triggerWidth - overlayWidth;
    }
<<<<<<< HEAD
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject()! as RenderBox;
    final origin = rb.localToGlobal(Offset.zero, ancestor: overlayBox);
    final size = overlayBox.size;
    overlayWidth = overlayWidth.clamp(0, math.max(0, size.width - 16));
    final left = (origin.dx + overlayDx).clamp(
      8.0,
      math.max(8, size.width - overlayWidth - 8),
    );
    overlayDx = left - origin.dx;
    final below = size.height - origin.dy - triggerSize.height - 14;
    final above = origin.dy - 14;
    final upward = below < 180 && above > below;
    final maxHeight = math.min(360.0, math.max(44.0, upward ? above : below));
=======
    // Keyboard-opened menus take focus; mouse-opened ones do not steal it.
    final grabFocus = widget.focusable && _triggerFocusNode.hasFocus;
>>>>>>> 856aaa70a (feat(translate): user-managed target languages incl. Bengali (#1039))

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
              targetAnchor: upward ? Alignment.topLeft : Alignment.bottomLeft,
              followerAnchor: upward ? Alignment.bottomLeft : Alignment.topLeft,
              offset: Offset(overlayDx, upward ? -6 : 6),
              child: _DesktopSelectOverlay<T>(
                width: overlayWidth,
                maxHeight: maxHeight,
                onClose: _close,
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
    overlay.insert(_entry!);
    setState(() => _open = true);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
<<<<<<< HEAD
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final label = _labelForValue(widget.value);
=======
    final info = _triggerInfo(widget.value);
    final label = info.label;
    final leading = info.leading;
>>>>>>> 856aaa70a (feat(translate): user-managed target languages incl. Bengali (#1039))

    final baseBorder = widget.embedded
        ? Colors.transparent
        : cs.outlineVariant.withValues(alpha: 0.18);
    final hoverBorder = widget.embedded ? Colors.transparent : cs.primary;
<<<<<<< HEAD
    final borderColor = _open || _hover || _focused ? hoverBorder : baseBorder;
=======
    final highlight = _open || _hover || (widget.focusable && _focused);
    final borderColor = highlight ? hoverBorder : baseBorder;
>>>>>>> 856aaa70a (feat(translate): user-managed target languages incl. Bengali (#1039))

    final fillColor =
        widget.triggerFillColor ??
        (widget.embedded
            ? Colors.transparent
            : Theme.of(context).colorScheme.surfaceContainerHigh);

<<<<<<< HEAD
    return FocusableActionDetector(
      focusNode: _focus,
      enabled: widget.enabled,
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.arrowDown): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _toggle();
            return null;
          },
        ),
      },
      child: Semantics(
        button: true,
        enabled: widget.enabled,
        expanded: _open,
        label: widget.semanticLabel ?? label,
        value: widget.semanticLabel == null ? null : label,
        hint: widget.semanticHint,
        onTap: widget.enabled ? _toggle : null,
        child: ExcludeSemantics(
          child: CompositedTransformTarget(
            link: _link,
            child: MouseRegion(
              cursor: widget.enabled
                  ? SystemMouseCursors.click
                  : MouseCursor.defer,
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: GestureDetector(
                onTap: widget.enabled ? _toggle : null,
                child: AnimatedContainer(
                  key: _triggerKey,
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 160),
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
                    boxShadow: !widget.embedded && _open
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
                    alignment: AlignmentDirectional.centerStart,
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final availableWidth = constraints.hasBoundedWidth
                              ? constraints.maxWidth
                              : widget.maxLabelWidth + 24;
                          final labelMaxWidth = (availableWidth - 24)
                              .clamp(0.0, widget.maxLabelWidth)
                              .toDouble();
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: labelMaxWidth,
                                ),
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color:
                                        (widget.triggerForegroundColor ??
                                                cs.onSurface)
                                            .withValues(alpha: 0.88),
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
                          alignment: AlignmentDirectional.centerEnd,
                          child: AnimatedRotation(
                            turns: _open ? 0.5 : 0.0,
                            duration: reduceMotion
                                ? Duration.zero
                                : const Duration(milliseconds: 200),
                            curve: Curves.easeOutCubic,
                            child: Icon(
                              lucide.Lucide.ChevronDown,
                              size: 16,
                              color:
                                  (widget.triggerForegroundColor ??
                                          cs.onSurface)
                                      .withValues(alpha: 0.7),
=======
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
              boxShadow: !widget.embedded && _open
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
>>>>>>> 856aaa70a (feat(translate): user-managed target languages incl. Bengali (#1039))
                            ),
                          ),
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
    required this.maxHeight,
    required this.onClose,
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
  final double maxHeight;
  final VoidCallback onClose;
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
<<<<<<< HEAD
  late final List<FocusNode> _focus;
  late final List<GlobalKey> _keys;
  late int _active;
=======
  final FocusNode _focusNode = FocusNode(debugLabel: 'DesktopSelectOverlay');
  final ScrollController _scrollController = ScrollController();
>>>>>>> 856aaa70a (feat(translate): user-managed target languages incl. Bengali (#1039))

  @override
  void initState() {
    super.initState();
    _focus = List.generate(widget.options.length, (_) => FocusNode());
    _keys = List.generate(widget.options.length, (_) => GlobalKey());
    _active = math.max(
      0,
      widget.options.indexWhere((o) => o.value == widget.selected),
    );
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
<<<<<<< HEAD
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _ctrl.value = 1;
      } else {
        _ctrl.forward();
      }
      _move(_active);
    });
  }

  void _move(int index) {
    if (_focus.isEmpty) return;
    _active = index % _focus.length;
    _focus[_active].requestFocus();
    final target = _keys[_active].currentContext;
    if (target != null) Scrollable.ensureVisible(target, alignment: .5);
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        widget.onClose();
      case LogicalKeyboardKey.arrowDown:
        _move(_active + 1);
      case LogicalKeyboardKey.arrowUp:
        _move(_active - 1);
      case LogicalKeyboardKey.home:
        _move(0);
      case LogicalKeyboardKey.end:
        _move(_focus.length - 1);
      case LogicalKeyboardKey.tab:
        _move(_active + (HardwareKeyboard.instance.isShiftPressed ? -1 : 1));
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
=======
      _ctrl.forward();
      // `autofocus` alone does not take focus inside an OverlayEntry; request
      // it explicitly for keyboard-opened menus.
      if (mounted && widget.autofocus) _focusNode.requestFocus();
    });
>>>>>>> 856aaa70a (feat(translate): user-managed target languages incl. Bengali (#1039))
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _focusNode.dispose();
    _ctrl.dispose();
    for (final node in _focus) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = cs.outlineVariant.withValues(alpha: 0.12);

<<<<<<< HEAD
    final content = FocusScope(
      onKeyEvent: _key,
      child: Material(
        color: Colors.transparent,
        child: Container(
          constraints: BoxConstraints(
            minWidth: widget.width,
            maxWidth: widget.width,
            maxHeight: widget.maxHeight,
          ),
          decoration: BoxDecoration(
            color: widget.backgroundColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: 0.5),
            boxShadow: [
              BoxShadow(
                color: cs.shadow.withValues(alpha: isDark ? 0.32 : 0.08),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < widget.options.length; i++)
                  _DesktopSelectOptionTile(
                    key: _keys[i],
                    focusNode: _focus[i],
                    onFocused: () => _active = i,
                    label: widget.options[i].label,
                    subtitle: widget.options[i].subtitle,
                    selected: widget.selected == widget.options[i].value,
                    onTap: () => widget.onSelected(widget.options[i].value),
=======
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
>>>>>>> 856aaa70a (feat(translate): user-managed target languages incl. Bengali (#1039))
                  ),
                  decoration: BoxDecoration(
                    color: widget.backgroundColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: borderColor, width: 0.5),
                    boxShadow: [
                      BoxShadow(
                        color: cs.shadow.withValues(
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
                          controller: _scrollController,
                          thickness: 6,
                          radius: const Radius.circular(3),
                          child: ListView.builder(
                            controller: _scrollController,
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: widget.options.length,
                            itemBuilder: (context, index) {
                              final opt = widget.options[index];
                              return _DesktopSelectOptionTile(
                                label: opt.label,
                                subtitle: opt.subtitle,
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
    if (MediaQuery.disableAnimationsOf(context)) return content;
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _slide, child: content),
    );
  }
}

class _DesktopSelectOptionTile extends StatefulWidget {
  const _DesktopSelectOptionTile({
    super.key,
    required this.focusNode,
    required this.onFocused,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.focusable,
    this.subtitle,
    this.leading,
  });

  final String label;
  final String? subtitle;
  final String? leading;
  final bool selected;
  final bool focusable;
  final VoidCallback onTap;
  final FocusNode focusNode;
  final VoidCallback onFocused;

  @override
  State<_DesktopSelectOptionTile> createState() =>
      _DesktopSelectOptionTileState();
}

class _DesktopSelectOptionTileState extends State<_DesktopSelectOptionTile> {
  bool _hover = false;
  bool _active = false;
  bool _focused = false;
<<<<<<< HEAD
=======

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
      // Keep the focused option inside the bounded viewport when arrows move
      // past the visible edge.
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
      );
    }
    setState(() => _focused = value);
  }
>>>>>>> 856aaa70a (feat(translate): user-managed target languages incl. Bengali (#1039))

  Widget _labelColumn(ColorScheme cs) {
    final label = Text(
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
    );
    final subtitle = widget.subtitle;
    if (subtitle == null || subtitle.isEmpty) return label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        label,
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.3,
            color: cs.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final bg = widget.selected
        ? cs.primary.withValues(alpha: 0.12)
        : (_hover || _focused
              ? (cs.onSurface.withValues(alpha: isDark ? 0.08 : 0.04))
              : Colors.transparent);
<<<<<<< HEAD
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      onFocusChange: (value) {
        if (value) widget.onFocused();
      },
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: Semantics(
        button: true,
        selected: widget.selected,
        label: widget.label,
        hint: widget.subtitle,
        onTap: widget.onTap,
        child: ExcludeSemantics(
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
                duration: reducedMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                child: AnimatedContainer(
                  duration: reducedMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 160),
                  constraints: const BoxConstraints(minHeight: 32),
                  curve: Curves.easeOutCubic,
                  margin: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(child: _labelColumn(cs)),
                      const SizedBox(width: 8),
                      Icon(
                        lucide.Lucide.Check,
                        size: 14,
                        color: cs.primary.withValues(
                          alpha: widget.selected ? 1 : 0,
                        ),
                      ),
                    ],
                  ),
                ),
=======
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
                  Expanded(child: _labelColumn(cs)),
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
>>>>>>> 856aaa70a (feat(translate): user-managed target languages incl. Bengali (#1039))
              ),
            ),
          ),
        ),
      ),
    );
  }
}
