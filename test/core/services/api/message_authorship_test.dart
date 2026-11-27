import 'package:Cuplivo/core/models/carried_original.dart';
import 'package:Cuplivo/core/services/api/message_authorship.dart';
import 'package:Cuplivo/core/services/api/request_image_context.dart';
import 'package:flutter_test/flutter_test.dart';

/// A group chat hands each speaker its peers' turns as `user` messages, so the
/// last user-role message is not necessarily the user's own. Everything that
/// hangs off "the user's turn" — images, the search query, video — asks
/// `lastUserInputIndex()`, whose predicate must answer both halves of the
/// question: a peer's turn is not the user's, and neither is injected lore.
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
    expect(lastUserInputIndex(messages), 0);
  });

  test('a later user turn wins over an earlier one', () {
    final messages = [
      mine('first'),
      peer('Bob', 'noted'),
      mine('second'),
      peer('Alice', 'still here'),
    ];
    expect(lastUserInputIndex(messages), 2);
  });

  test('an assistant turn at the tail never becomes the anchor', () {
    final messages = [mine('ask'), reply('answer')];
    expect(lastUserInputIndex(messages), 0);
  });

  test('no user turn at all is -1, not 0', () {
    expect(lastUserInputIndex([reply('only me'), peer('Bob', 'hi')]), -1);
    expect(lastUserInputIndex(const []), -1);
  });

  test('a turn is a peer only when it carries the marker', () {
    final messages = [
      mine('ask'),
      {'role': 'user', 'content': 'lore, not the user'},
    ];
    expect(lastUserInputIndex(messages), 1);
  });

  test('injected lore after the user does not become the anchor either', () {
    // The same predicate that skips a peer's turn skips a carried/summary
    // message, which is what the owner key marks. Both conditions live in
    // `isUserInputMessage` so a call site cannot pick one and lose the other.
    final messages = [
      {'role': 'user', 'content': 'ask', imageContextOwnerKey: 'original-id'},
      {
        'role': 'user',
        'content': 'carried context',
        imageContextOwnerKey: '${carriedPrefix}original-id',
      },
    ];
    expect(lastUserInputIndex(messages), 0);
    expect(isUserInputMessage(messages.first, hasOwners: true), isTrue);
    expect(isUserInputMessage(messages.last, hasOwners: true), isFalse);
  });
}
