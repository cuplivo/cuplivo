import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/home/models/chat_input_mode.dart';

void main() {
  test('the input bar has exactly the 1:1 and group chrome modes', () {
    expect(ChatInputMode.values, [
      ChatInputMode.normal,
      ChatInputMode.groupChat,
    ]);
  });

  test('group chat is not the default chrome mode', () {
    expect(ChatInputMode.normal.index, isZero);
  });
}
