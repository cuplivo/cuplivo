import 'dart:convert';

import 'package:Cuplivo/core/services/sync/sync_budget.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/sync_payload.dart';

/// What one push can carry: the byte count the receiver sees, and the
/// conversations a round admits against it.
///
/// The fixtures are bytes, not megabytes: the admission rule takes the budget
/// as an argument, so the state table is the same arithmetic at any scale.
void main() {
  SyncSubtreePayload titled(String id, int titleLength, {String fill = 'x'}) =>
      subtreePayload(conversation: {'id': id, 'title': fill * titleLength});

  test('a CJK string is three bytes per code unit, not one', () {
    const text = '会话标题';
    expect(text.length, 4);
    expect(utf8LengthOf(text), 12);
    expect(utf8LengthOf(text), utf8.encode(text).length);
  });

  test('the counter agrees with utf8.encode for every string shape', () {
    for (final text in <String>[
      '',
      'plain ascii',
      '会话标题',
      'emoji 😀 and 漢字',
      'tab\tnewline\nquote"backslash\\',
      '\u{1F600}\u{1F601}',
      'mixed: a, 会, 😀',
    ]) {
      expect(
        utf8LengthOf(text),
        utf8.encode(text).length,
        reason: 'the counter must equal the bytes the client sends for $text',
      );
    }
  });

  test('a conversation is counted in wire bytes, not Dart characters', () {
    final subtree = titled('conv-cjk', 40, fill: '会');
    expect(
      conversationWireBytes(subtree),
      utf8.encode(jsonEncode(subtree.toJson())).length,
    );
    expect(
      conversationWireBytes(subtree),
      greaterThan(jsonEncode(subtree.toJson()).length),
      reason: 'the title is CJK: 3 bytes per unit on the wire',
    );
  });

  test('an admitted batch serialises inside the budget, by construction', () {
    final planned = [titled('a', 10), titled('b', 20), titled('c', 30)];
    const business = SyncBusinessPayload();
    final envelope = pushEnvelopeBytes(
      business: business,
      assets: const [],
      skillHashes: const {},
      workspaceFiles: const {},
    );
    final budget = envelope + 1000;

    final outbound = admitConversations(
      planned: planned,
      envelopeBytes: envelope,
      budgetBytes: budget,
      perConversationBytes: budget,
    );
    expect(outbound.admitted, hasLength(3), reason: 'all three fit');

    final body = SyncDeltaBatch(outbound.admitted, business: business);
    expect(
      wireBytesOf(body.toJson()),
      lessThanOrEqualTo(budget),
      reason: 'envelope + Σ(size + 1) − 1 is the whole body',
    );
    expect(wireBytesOf(body.toJson()), ledgerSum(outbound.admitted, envelope));
  });

  test('the batch about to be sent is checked against the budget', () {
    // What the engine asserts on the real push: the list measured and the list
    // sent are the same list, and one function answers for both.
    final batch = SyncDeltaBatch([titled('a', 10), titled('b', 20)]);
    final bytes = wireBytesOf(batch.toJson());
    expect(() => assertPushFits(batch, bytes), returnsNormally);
    expect(
      () => assertPushFits(batch, bytes - 1),
      throwsStateError,
      reason: 'one byte over the budget is a refused round on the peer',
    );
  });

  test(
    'a conversation larger than the per-conversation cap rides in no round',
    () {
      final planned = [titled('small', 1), titled('huge', 400)];
      final outbound = admitConversations(
        planned: planned,
        envelopeBytes: 0,
        budgetBytes: 100000,
        perConversationBytes: 300,
      );
      expect(outbound.admitted.map((s) => s.conversation['id']), ['small']);
      expect(outbound.omitted, {'huge'});
    },
  );

  test('an over-budget conversation does not end the walk', () {
    // The huge one comes first, in plan order. The two behind it must still
    // ride: "not this round" is not "not ever", and a list that stopped at the
    // first refusal would starve everything after it, for good.
    final planned = [titled('huge', 900), titled('b', 5), titled('c', 5)];
    final outbound = admitConversations(
      planned: planned,
      envelopeBytes: 0,
      budgetBytes: 900,
      perConversationBytes: 100000,
    );
    expect(outbound.admitted.map((s) => s.conversation['id']), ['b', 'c']);
    expect(outbound.omitted, {'huge'});
  });

  test('the boundary is the byte: one that fits rides, one more does not', () {
    final subtree = titled('c', 20);
    final size = conversationWireBytes(subtree);
    final planned = [subtree];

    final exact = admitConversations(
      planned: planned,
      envelopeBytes: 0,
      budgetBytes: size + 1,
      perConversationBytes: size + 1,
    );
    expect(exact.admitted, hasLength(1), reason: 'size + comma is the cost');

    final oneShort = admitConversations(
      planned: planned,
      envelopeBytes: 0,
      budgetBytes: size,
      perConversationBytes: size + 1,
    );
    expect(oneShort.omitted, {'c'});
  });

  test('CJK bytes decide, not Dart length', () {
    // The conversation's code-unit length fits the budget; its UTF-8 length
    // does not. A budget counted in characters would admit it and the receiver
    // would still answer 413.
    final subtree = subtreePayload(
      conversation: {'id': 'cjk', 'title': '会' * 300},
    );
    final characters = jsonEncode(subtree.toJson()).length;
    final bytes = conversationWireBytes(subtree);
    expect(bytes, greaterThan(characters * 2));

    final outbound = admitConversations(
      planned: [subtree],
      envelopeBytes: 0,
      budgetBytes: characters + 10,
      perConversationBytes: characters + 10,
    );
    expect(outbound.admitted, isEmpty);
    expect(outbound.omitted, {'cjk'});
  });

  test('the envelope carries the business, asset and workspace faces', () {
    final empty = pushEnvelopeBytes(
      business: const SyncBusinessPayload(),
      assets: const [],
      skillHashes: const {},
      workspaceFiles: const {},
    );
    final loaded = pushEnvelopeBytes(
      business: SyncBusinessPayload(
        entities: {
          'assistants': [
            {'id': 'a1', 'name': 'Assistant'},
          ],
        },
        preferences: [
          {'key': 'user_name', 'value': 'Alice'},
        ],
      ),
      assets: const [
        SyncBlobEntry(
          kind: SyncBlobEntry.kindFile,
          key: 'x.png',
          contentHash: 'h',
        ),
      ],
      skillHashes: const {'skill-1': 'abc'},
      workspaceFiles: const {
        'ws-1': {'a.md': WorkspaceFileStamp(size: 10, mtimeMs: 1)},
      },
    );
    expect(loaded, greaterThan(empty));
  });
}

/// The byte count the batch *should* be, from the parts the admission measured:
/// `envelope + Σ(size + 1) − 1`.
int ledgerSum(List<SyncSubtreePayload> subtrees, int envelope) =>
    envelope +
    subtrees.fold<int>(0, (sum, s) => sum + conversationWireBytes(s) + 1) -
    1;
