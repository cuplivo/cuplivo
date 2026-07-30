import 'package:flutter/foundation.dart';

enum DesktopChatPaneKind {
  groupList,
  groupChat,
  groupSettings,
  groupAdvancedSettings,
  groupDirectorLog,
}

class DesktopChatPaneDestination {
  const DesktopChatPaneDestination(this.kind, {this.groupId});

  final DesktopChatPaneKind kind;
  final String? groupId;

  String get key => '${kind.name}:${groupId ?? ''}';
}

/// Owns the page stack inside the desktop chat content pane.
///
/// The regular chat page is the implicit root and remains mounted while group
/// chat pages are shown on top of it.
class DesktopChatPaneController extends ChangeNotifier {
  final List<DesktopChatPaneDestination> _stack = [];

  List<DesktopChatPaneDestination> get stack => List.unmodifiable(_stack);

  bool get isAtRoot => _stack.isEmpty;

  void push(DesktopChatPaneDestination destination) {
    _stack.add(destination);
    notifyListeners();
  }

  void pop([int count = 1]) {
    if (count < 1 || _stack.isEmpty) return;
    final removeCount = count.clamp(1, _stack.length);
    _stack.removeRange(_stack.length - removeCount, _stack.length);
    notifyListeners();
  }

  void reset() {
    if (_stack.isEmpty) return;
    _stack.clear();
    notifyListeners();
  }
}
