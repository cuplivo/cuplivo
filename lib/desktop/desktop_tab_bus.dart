import 'package:flutter/foundation.dart';

/// Current top-level desktop shell tab.
///
/// `desktop_drop` dispatches a drop to EVERY [DropTarget] whose render box
/// contains the cursor, regardless of visibility, and `DesktopHomePage` keeps
/// inactive tabs laid out via `IndexedStack`. Without a visibility signal the
/// chat page's full-window drop target swallows drops meant for the settings
/// panes (and vice versa), so each drop target must gate its `enable` flag on
/// the active tab.
class DesktopTabBus extends ChangeNotifier {
  DesktopTabBus._();

  static final DesktopTabBus instance = DesktopTabBus._();

  static const int chat = 0;
  static const int translate = 1;
  static const int storage = 2;
  static const int settings = 3;

  int _index = chat;
  int get index => _index;

  void setIndex(int value) {
    if (value == _index) return;
    _index = value;
    notifyListeners();
  }
}
