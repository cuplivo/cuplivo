import 'package:flutter/foundation.dart';

enum ExtraKeyModifierState { idle, armed, locked }

class ExtraKeyBinding {
  const ExtraKeyBinding({
    required this.id,
    required this.display,
    this.terminalKey,
    this.text,
    this.popupText,
    this.modifier,
    this.repeatable = false,
  });

  final String id;
  final String display;
  final String? terminalKey;
  final String? text;
  final String? popupText;
  final String? modifier;
  final bool repeatable;
}

class TerminalExtraKeys {
  const TerminalExtraKeys._();

  static const List<List<ExtraKeyBinding>> defaultLayout = [
    [
      ExtraKeyBinding(id: 'ESC', display: 'ESC', terminalKey: 'escape'),
      ExtraKeyBinding(id: '/', display: '/', text: '/'),
      ExtraKeyBinding(id: '-', display: '―', text: '-', popupText: '|'),
      ExtraKeyBinding(id: 'HOME', display: 'HOME', terminalKey: 'home'),
      ExtraKeyBinding(
        id: 'UP',
        display: '↑',
        terminalKey: 'arrowUp',
        repeatable: true,
      ),
      ExtraKeyBinding(id: 'END', display: 'END', terminalKey: 'end'),
      ExtraKeyBinding(
        id: 'PGUP',
        display: 'PGUP',
        terminalKey: 'pageUp',
        repeatable: true,
      ),
    ],
    [
      ExtraKeyBinding(id: 'TAB', display: '↹', terminalKey: 'tab'),
      ExtraKeyBinding(id: 'CTRL', display: 'CTRL', modifier: 'ctrl'),
      ExtraKeyBinding(id: 'ALT', display: 'ALT', modifier: 'alt'),
      ExtraKeyBinding(
        id: 'LEFT',
        display: '←',
        terminalKey: 'arrowLeft',
        repeatable: true,
      ),
      ExtraKeyBinding(
        id: 'DOWN',
        display: '↓',
        terminalKey: 'arrowDown',
        repeatable: true,
      ),
      ExtraKeyBinding(
        id: 'RIGHT',
        display: '→',
        terminalKey: 'arrowRight',
        repeatable: true,
      ),
      ExtraKeyBinding(
        id: 'PGDN',
        display: 'PGDN',
        terminalKey: 'pageDown',
        repeatable: true,
      ),
    ],
  ];

  static String applyCtrl(String text) {
    if (text.isEmpty) return text;
    final unit = text.codeUnitAt(0);
    final String mapped;
    if (unit >= 64 && unit <= 95) {
      mapped = String.fromCharCode(unit - 64);
    } else if (unit >= 97 && unit <= 122) {
      mapped = String.fromCharCode(unit - 96);
    } else {
      mapped = text.substring(0, 1);
    }
    return mapped + text.substring(1);
  }
}

class TerminalExtraKeysController extends ChangeNotifier {
  ExtraKeyModifierState ctrl = ExtraKeyModifierState.idle;
  ExtraKeyModifierState alt = ExtraKeyModifierState.idle;
  bool volumeCtrlHeld = false;
  bool _disposed = false;

  bool get ctrlActive => volumeCtrlHeld || ctrl != ExtraKeyModifierState.idle;

  bool get altActive => alt != ExtraKeyModifierState.idle;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void tapModifier(String name) {
    if (_disposed) return;
    if (name == 'ctrl') {
      ctrl = _toggle(ctrl);
    } else if (name == 'alt') {
      alt = _toggle(alt);
    } else {
      return;
    }
    notifyListeners();
  }

  void lockModifier(String name) {
    if (_disposed) return;
    if (name == 'ctrl') {
      ctrl = ExtraKeyModifierState.locked;
    } else if (name == 'alt') {
      alt = ExtraKeyModifierState.locked;
    } else {
      return;
    }
    notifyListeners();
  }

  void setVolumeCtrlHeld(bool held) {
    if (_disposed) return;
    if (volumeCtrlHeld == held) return;
    volumeCtrlHeld = held;
    notifyListeners();
  }

  void resetSessionModifiers() {
    if (_disposed) return;
    ctrl = ExtraKeyModifierState.idle;
    alt = ExtraKeyModifierState.idle;
    notifyListeners();
  }

  void consumeOneShot() {
    if (_disposed) return;
    var changed = false;
    if (ctrl == ExtraKeyModifierState.armed) {
      ctrl = ExtraKeyModifierState.idle;
      changed = true;
    }
    if (alt == ExtraKeyModifierState.armed) {
      alt = ExtraKeyModifierState.idle;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  ExtraKeyModifierState _toggle(ExtraKeyModifierState current) {
    switch (current) {
      case ExtraKeyModifierState.idle:
        return ExtraKeyModifierState.armed;
      case ExtraKeyModifierState.armed:
      case ExtraKeyModifierState.locked:
        return ExtraKeyModifierState.idle;
    }
  }
}
