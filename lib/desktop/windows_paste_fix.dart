import 'dart:io';
import 'dart:ui';

class WindowsPasteFix {
  WindowsPasteFix._();

  static final WindowsPasteFix instance = WindowsPasteFix._();

  // Constants verified against real Win+V output on Flutter 3.44.2 / Win11
  static const int _junkPhysical = 0x1600000000;
  static const int _cleanPhysicalCtrl = 0x700e0;
  static const int _cleanPhysicalV = 0x70019;
  static const int _logicalCtrl = 0x200000100;
  static const int _logicalV = 0x76;

  int _step = 0;

  void inject() {
    if (!Platform.isWindows) return;
    // Delay to ensure Flutter's framework handler is already installed.
    Future.delayed(const Duration(seconds: 1), _install);
  }

  void _install() {
    final original = PlatformDispatcher.instance.onKeyData;
    PlatformDispatcher.instance.onKeyData = (KeyData data) {
      final rewritten = _rewrite(data);
      if (rewritten == null) return true;
      if (original != null) return original(rewritten);
      return false;
    };
  }

  KeyData _copyWith(
    KeyData data, {
    required KeyEventType type,
    required int physical,
    required int logical,
  }) {
    return KeyData(
      timeStamp: data.timeStamp,
      type: type,
      physical: physical,
      logical: logical,
      character: null,
      synthesized: false,
      deviceType: data.deviceType,
    );
  }

  KeyData? _rewrite(KeyData data) {
    // Swallow all-zero garbage events that occur during focus transitions.
    if (data.physical == 0 && data.logical == 0) return null;

    // Normal hardware keys: pass through, reset state machine.
    if (data.physical != _junkPhysical) {
      _step = 0;
      return data;
    }

    final down = data.type == KeyEventType.down;
    final up = data.type == KeyEventType.up;
    final isCtrl = data.logical == _logicalCtrl;
    final isV = data.logical == _logicalV;

    switch (_step) {
      case 0:
        // Expect Ctrl↓ (synth=false) → emit clean Ctrl↓
        if (isCtrl && down && !data.synthesized) {
          _step = 1;
          return _copyWith(
            data,
            type: KeyEventType.down,
            physical: _cleanPhysicalCtrl,
            logical: _logicalCtrl,
          );
        }
      case 1:
        // Expect Ctrl↑ (synth=true) → swallow (keep Ctrl logically pressed)
        if (isCtrl && up && data.synthesized) {
          _step = 2;
          return null;
        }
      case 2:
        // Expect V↓ → emit clean V↓
        if (isV && down) {
          _step = 3;
          return _copyWith(
            data,
            type: KeyEventType.down,
            physical: _cleanPhysicalV,
            logical: _logicalV,
          );
        }
      case 3:
        // Expect V↑ → emit clean V↑
        if (isV && up) {
          _step = 4;
          return _copyWith(
            data,
            type: KeyEventType.up,
            physical: _cleanPhysicalV,
            logical: _logicalV,
          );
        }
      case 4:
        // Expect Ctrl↓ (synth=true) → swallow (duplicate from Windows)
        if (isCtrl && down && data.synthesized) {
          _step = 5;
          return null;
        }
      case 5:
        // Expect Ctrl↑ (synth=true) → emit clean Ctrl↑
        if (isCtrl && up && data.synthesized) {
          _step = 0;
          return _copyWith(
            data,
            type: KeyEventType.up,
            physical: _cleanPhysicalCtrl,
            logical: _logicalCtrl,
          );
        }
    }

    // Sequence broken: reset and pass through.
    _step = 0;
    return data;
  }
}
