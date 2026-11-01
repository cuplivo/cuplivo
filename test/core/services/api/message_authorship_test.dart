import 'package:Cuplivo/core/services/api/message_authorship.dart';
import 'package:flutter_test/flutter_test.dart';

/// A group chat hands each speaker its peers' turns as `user` messages, so the
/// last user-role message is not necessarily the user's own. Everything that
/// hangs off "the user's turn" — images, the search query, video — asks for
/// this index instead.
void main() {
  Map<String, dynamic> mine(String text) => {'role': 'user', 'content': text};

  Map<String, dynamic> peer(String name, String text) => {
    'role': 'user',
    'content': '<group_message from="$name">\n$text\n</group_message>',
    groupPeerSenderKey: name,
  };

  Map<String, dynamic> reply(String text) => {
    'role': 'assistant',
    'content': text,
  };

  test('points at the user even when peers spoke after them', () {
    final messages = [
      mine('plan the week'),
      reply('mine'),
      peer('Bob', 'I can do Tuesday'),
      peer('Alice', 'Wednesday works'),
    ];
    expect(lastHumanUserIndex(messages), 0);
  });

  test('a later user turn wins over an earlier one', () {
    final messages = [
      mine('first'),
      peer('Bob', 'noted'),
      mine('second'),
      peer('Alice', 'still here'),
    ];
    expect(lastHumanUserIndex(messages), 2);
  });

  test('an assistant turn at the tail never becomes the anchor', () {
    final messages = [mine('ask'), reply('answer')];
    expect(lastHumanUserIndex(messages), 0);
  });

  test('no user turn at all is -1, not 0', () {
    expect(lastHumanUserIndex([reply('only me'), peer('Bob', 'hi')]), -1);
    expect(lastHumanUserIndex(const []), -1);
  });

  test('a turn is a peer only when it carries the marker', () {
    final messages = [
      mine('ask'),
      {'role': 'user', 'content': 'lore, not the user'},
    ];
    expect(lastHumanUserIndex(messages), 1);
  });
}
