import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/desktop/desktop_chat_pane_controller.dart';

void main() {
  test('desktop group chat destinations form an in-shell back stack', () {
    final controller = DesktopChatPaneController();
    addTearDown(controller.dispose);

    expect(controller.isAtRoot, isTrue);
    controller.push(
      const DesktopChatPaneDestination(DesktopChatPaneKind.groupList),
    );
    controller.push(
      const DesktopChatPaneDestination(
        DesktopChatPaneKind.groupChat,
        groupId: 'g1',
      ),
    );
    controller.push(
      const DesktopChatPaneDestination(
        DesktopChatPaneKind.groupSettings,
        groupId: 'g1',
      ),
    );

    expect(controller.stack.map((entry) => entry.kind), [
      DesktopChatPaneKind.groupList,
      DesktopChatPaneKind.groupChat,
      DesktopChatPaneKind.groupSettings,
    ]);

    controller.pop();
    expect(controller.stack.last.kind, DesktopChatPaneKind.groupChat);
    controller.pop(2);
    expect(controller.isAtRoot, isTrue);
  });
}
