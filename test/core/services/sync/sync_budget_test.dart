import 'dart:convert';

import 'package:Cuplivo/core/services/sync/sync_budget.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/sync_payload.dart';

/// What one page can carry: the byte count the receiver sees, and how many rows
/// a page's budget leaves room for.
///
/// The fixtures are bytes, not megabytes: the budget is an argument, so the
/// state table is the same arithmetic at any scale.
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

  test('a page built from its row budget serialises inside it', () {
    // The identity the page builder rests on: a body holding `k` subtrees is
    // `envelope + Σ(size + 1) − 1`. A push page carries one subtree, so the
    // arithmetic is the same at any page size.
    const business = SyncBusinessPayload();
    final envelope = pushEnvelopeBytes(
      business: business,
      assets: const [],
      skillHashes: const {},
      workspaceFiles: const {},
    );
    const pageBytes = 4096;
    final room = pageRowBudget(pageBytes: pageBytes, envelopeBytes: envelope);
    expect(room, pageBytes - envelope);

    final page = [titled('a', 10), titled('b', 20)];
    final body = SyncDeltaBatch(page, business: business);
    expect(wireBytesOf(body.toJson()), lessThanOrEqualTo(pageBytes));
    expect(wireBytesOf(body.toJson()), ledgerSum(page, envelope));
  });

  test(
    'a fixed part larger than the page leaves no room, and is not clipped',
    () {
      // ADR-0003: the fixed part is measured, not capped. A page whose envelope
      // alone is past the page size carries the envelope alone — only the
      // receiving side's body cap may refuse it — so the answer goes non-positive
      // rather than pretending there is room.
      expect(pageRowBudget(pageBytes: 100, envelopeBytes: 100), 0);
      expect(pageRowBudget(pageBytes: 100, envelopeBytes: 300), -200);
    },
  );

  test('the page about to be sent is checked against the page budget', () {
    // What the engine asserts on the real push: the rows measured and the rows
    // sent are the same rows, and one function answers for both.
    final batch = SyncDeltaBatch([titled('a', 10), titled('b', 20)]);
    final bytes = wireBytesOf(batch.toJson());
    expect(() => assertPushFits(batch, bytes), returnsNormally);
    expect(
      () => assertPushFits(batch, bytes - 1),
      throwsStateError,
      reason: 'one byte over the page is a refused beat on the peer',
    );
    // The documented edge: the fixed part alone is past the page, so the page
    // carries nothing but that part. A debug build must not fail a beat release
    // would have let the peer answer.
    expect(
      () => assertPushFits(batch, 1, envelopeBytes: bytes + 1),
      returnsNormally,
      reason:
          'a body no larger than its own envelope cannot be the sender\'s '
          'fault',
    );
    expect(
      () => assertPushFits(batch, 1, envelopeBytes: bytes - 1),
      throwsStateError,
      reason: 'and once the envelope fits, the page budget is the bound again',
    );
  });

  test('CJK bytes decide, not Dart length', () {
    // The page's code-unit length fits the budget; its UTF-8 length does not. A
    // budget counted in characters would pack it and the receiver would still
    // answer 413.
    final subtree = subtreePayload(
      conversation: {'id': 'cjk', 'title': '会' * 300},
    );
    final characters = jsonEncode(subtree.toJson()).length;
    final bytes = conversationWireBytes(subtree);
    expect(bytes, greaterThan(characters * 2));

    final room = pageRowBudget(pageBytes: characters + 10, envelopeBytes: 0);
    expect(
      bytes + 1,
      greaterThan(room),
      reason: 'a character-counted page would pack a body the peer refuses',
    );
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

  test('a page says whether it is the last one, and the last names its ids', () {
    // An intermediate page proves what it carries and nothing about absence, so
    // it must not carry an id set at all: a reader that found an empty one would
    // conclude the sender holds nothing and delete the conversation.
    final first = SyncSubtreePayload(
      conversation: const {'id': 'c'},
      more: true,
    );
    final firstJson = first.toJson();
    expect(firstJson['more'], isTrue);
    expect(firstJson.containsKey('ids'), isFalse);

    final last = SyncSubtreePayload(
      conversation: const {'id': 'c'},
      ids: const ['m1', 'm2'],
    );
    final lastJson = last.toJson();
    expect(lastJson.containsKey('more'), isFalse);
    expect(lastJson['ids'], ['m1', 'm2']);

    final round = SyncSubtreePayload.fromJson(
      (jsonDecode(jsonEncode(lastJson)) as Map).cast<String, dynamic>(),
    );
    expect(round.more, isFalse);
    expect(round.ids, ['m1', 'm2']);
  });
}

/// The byte count the page *should* be, from the parts it was assembled out of:
/// `envelope + Σ(size + 1) − 1`.
int ledgerSum(List<SyncSubtreePayload> subtrees, int envelope) =>
    envelope +
    subtrees.fold<int>(0, (sum, s) => sum + conversationWireBytes(s) + 1) -
    1;
