import 'package:Cuplivo/core/services/workspace/terminal_extra_keys.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default layout is two rows of seven', () {
    expect(TerminalExtraKeys.defaultLayout, hasLength(2));
    expect(TerminalExtraKeys.defaultLayout[0], hasLength(7));
    expect(TerminalExtraKeys.defaultLayout[1], hasLength(7));
  });

  test('named keys and minus popup', () {
    ExtraKeyBinding find(String id) {
      return TerminalExtraKeys.defaultLayout
          .expand((row) => row)
          .firstWhere(
            (key) => key.id == id,
            orElse: () => throw StateError('missing extra key id=$id'),
          );
    }

    expect(find('ESC').terminalKey, 'escape');
    expect(find('TAB').terminalKey, 'tab');
    expect(find('UP').terminalKey, 'arrowUp');
    expect(find('DOWN').terminalKey, 'arrowDown');
    expect(find('LEFT').terminalKey, 'arrowLeft');
    expect(find('RIGHT').terminalKey, 'arrowRight');
    expect(find('HOME').terminalKey, 'home');
    expect(find('END').terminalKey, 'end');
    expect(find('PGUP').terminalKey, 'pageUp');
    expect(find('PGDN').terminalKey, 'pageDown');
    expect(find('-').text, '-');
    expect(find('-').popupText, '|');
    expect(find('CTRL').modifier, 'ctrl');
    expect(find('ALT').modifier, 'alt');
  });

  test('applyCtrl maps letters to control bytes', () {
    expect(TerminalExtraKeys.applyCtrl('c'), '\u0003');
    expect(TerminalExtraKeys.applyCtrl('C'), '\u0003');
    expect(TerminalExtraKeys.applyCtrl('a'), '\u0001');
    expect(TerminalExtraKeys.applyCtrl('z'), '\u001a');
    expect(TerminalExtraKeys.applyCtrl('@'), '\u0000');
    expect(TerminalExtraKeys.applyCtrl('['), '\u001b');
    expect(TerminalExtraKeys.applyCtrl('5'), '5');
    expect(TerminalExtraKeys.applyCtrl(''), '');
    expect(TerminalExtraKeys.applyCtrl('cxyz'), '\u0003xyz');
  });

  test('tap arms and consume clears; lock survives', () {
    final controller = TerminalExtraKeysController();
    controller.tapModifier('ctrl');
    expect(controller.ctrl, ExtraKeyModifierState.armed);
    expect(controller.ctrlActive, isTrue);
    controller.consumeOneShot();
    expect(controller.ctrl, ExtraKeyModifierState.idle);

    controller.lockModifier('alt');
    expect(controller.alt, ExtraKeyModifierState.locked);
    controller.consumeOneShot();
    expect(controller.alt, ExtraKeyModifierState.locked);
    expect(controller.altActive, isTrue);
  });

  test('volume-down is momentary ctrl', () {
    final controller = TerminalExtraKeysController();
    controller.setVolumeCtrlHeld(true);
    expect(controller.ctrlActive, isTrue);
    controller.setVolumeCtrlHeld(false);
    expect(controller.ctrlActive, isFalse);
  });

  test('tap locked modifier returns to idle', () {
    final controller = TerminalExtraKeysController();
    controller.lockModifier('ctrl');
    controller.tapModifier('ctrl');
    expect(controller.ctrl, ExtraKeyModifierState.idle);
  });

  test('double tap arms then clears', () {
    final controller = TerminalExtraKeysController();
    controller.tapModifier('alt');
    controller.tapModifier('alt');
    expect(controller.alt, ExtraKeyModifierState.idle);
  });

  test('volume held keeps ctrlActive after consumeOneShot', () {
    final controller = TerminalExtraKeysController();
    controller.tapModifier('ctrl');
    controller.setVolumeCtrlHeld(true);
    controller.consumeOneShot();
    expect(controller.ctrl, ExtraKeyModifierState.idle);
    expect(controller.ctrlActive, isTrue);
  });

  test('resetSessionModifiers clears armed lock and keeps volume', () {
    final controller = TerminalExtraKeysController();
    controller.lockModifier('ctrl');
    controller.tapModifier('alt');
    controller.setVolumeCtrlHeld(true);
    controller.resetSessionModifiers();
    expect(controller.ctrl, ExtraKeyModifierState.idle);
    expect(controller.alt, ExtraKeyModifierState.idle);
    expect(controller.volumeCtrlHeld, isTrue);
    expect(controller.ctrlActive, isTrue);
  });

  test('consumeOneShot clears armed alt', () {
    final controller = TerminalExtraKeysController();
    controller.tapModifier('alt');
    controller.consumeOneShot();
    expect(controller.alt, ExtraKeyModifierState.idle);
    expect(controller.altActive, isFalse);
  });
}
