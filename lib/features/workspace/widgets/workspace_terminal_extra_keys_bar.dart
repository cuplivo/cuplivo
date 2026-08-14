import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/services/haptics.dart';
import '../../../core/services/workspace/terminal_extra_keys.dart';

class WorkspaceTerminalExtraKeysBar extends StatelessWidget {
  const WorkspaceTerminalExtraKeysBar({
    super.key,
    required this.controller,
    required this.onEmit,
  });

  final TerminalExtraKeysController controller;
  final void Function(ExtraKeyBinding key, {required bool popup}) onEmit;

  static const double rowHeight = 37.5;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return ColoredBox(
          color: const Color(0xFF000000),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final row in TerminalExtraKeys.defaultLayout)
                SizedBox(
                  height: rowHeight,
                  child: Row(
                    children: [
                      for (final key in row)
                        Expanded(
                          child: _ExtraKeyCell(
                            key: ValueKey<String>(
                              'workspace-terminal-key-${key.id}',
                            ),
                            binding: key,
                            controller: controller,
                            onEmit: onEmit,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ExtraKeyCell extends StatefulWidget {
  const _ExtraKeyCell({
    super.key,
    required this.binding,
    required this.controller,
    required this.onEmit,
  });

  final ExtraKeyBinding binding;
  final TerminalExtraKeysController controller;
  final void Function(ExtraKeyBinding key, {required bool popup}) onEmit;

  @override
  State<_ExtraKeyCell> createState() => _ExtraKeyCellState();
}

class _ExtraKeyCellState extends State<_ExtraKeyCell> {
  bool _pressed = false;
  bool _popupArmed = false;
  bool _lockFired = false;
  Timer? _repeatDelay;
  Timer? _repeatTick;
  Timer? _lockTimer;

  ExtraKeyBinding get _key => widget.binding;

  bool get _modifierActive {
    if (_key.modifier == 'ctrl') return widget.controller.ctrlActive;
    if (_key.modifier == 'alt') return widget.controller.altActive;
    return false;
  }

  @override
  void dispose() {
    _cancelRepeat();
    _lockTimer?.cancel();
    super.dispose();
  }

  void _cancelRepeat() {
    _repeatDelay?.cancel();
    _repeatDelay = null;
    _repeatTick?.cancel();
    _repeatTick = null;
  }

  void _emit({required bool popup}) {
    Haptics.light();
    widget.onEmit(_key, popup: popup);
  }

  void _onDown(PointerDownEvent event) {
    if (!mounted || _pressed) return;
    setState(() {
      _pressed = true;
      _popupArmed = false;
      _lockFired = false;
    });
    if (_key.modifier != null) {
      _lockTimer?.cancel();
      _lockTimer = Timer(const Duration(milliseconds: 400), () {
        _lockFired = true;
        widget.controller.lockModifier(_key.modifier!);
        Haptics.medium();
      });
      return;
    }
    if (_key.popupText != null) {
      return;
    }
    _emit(popup: false);
    if (_key.repeatable) {
      _repeatDelay = Timer(const Duration(milliseconds: 400), () {
        _repeatTick = Timer.periodic(const Duration(milliseconds: 80), (_) {
          _emit(popup: false);
        });
      });
    }
  }

  void _onUp(PointerUpEvent event) {
    _lockTimer?.cancel();
    _lockTimer = null;
    _cancelRepeat();
    if (_key.modifier != null && _pressed && !_lockFired) {
      widget.controller.tapModifier(_key.modifier!);
    } else if (_key.popupText != null && _pressed) {
      _emit(popup: _popupArmed);
    }
    if (mounted) {
      setState(() {
        _pressed = false;
        _popupArmed = false;
      });
    }
  }

  void _onCancel(PointerCancelEvent event) {
    _lockTimer?.cancel();
    _lockTimer = null;
    _cancelRepeat();
    if (mounted) {
      setState(() {
        _pressed = false;
        _popupArmed = false;
      });
    }
  }

  void _onMove(PointerMoveEvent event) {
    if (!mounted || _key.popupText == null) return;
    if (event.localPosition.dy < -8) {
      if (!_popupArmed) {
        setState(() => _popupArmed = true);
        _cancelRepeat();
      }
    } else if (_popupArmed) {
      setState(() => _popupArmed = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _modifierActive;
    final fill = _pressed ? const Color(0xFF9E9E9E) : const Color(0xFF000000);
    final labelColor = active
        ? const Color(0xFFFF0000)
        : const Color(0xFFFFFFFF);
    return Semantics(
      label: _key.display,
      button: true,
      selected: active,
      child: Listener(
        onPointerDown: _onDown,
        onPointerUp: _onUp,
        onPointerCancel: _onCancel,
        onPointerMove: _onMove,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ColoredBox(
              color: fill,
              child: Center(
                child: ExcludeSemantics(
                  child: Text(
                    _key.display.toUpperCase(),
                    style: TextStyle(
                      color: labelColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
            if (_popupArmed && _key.popupText != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: WorkspaceTerminalExtraKeysBar.rowHeight,
                height: WorkspaceTerminalExtraKeysBar.rowHeight,
                child: ColoredBox(
                  color: const Color(0xFF9E9E9E),
                  child: Center(
                    child: Text(
                      _key.popupText!,
                      style: const TextStyle(
                        color: Color(0xFFFFFFFF),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
