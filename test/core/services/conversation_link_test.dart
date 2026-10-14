import 'dart:io';

import 'package:Cuplivo/core/services/conversation_link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConversationLink', () {
    test('builds the canonical link', () {
      expect(
        const ConversationLink(conversationId: 'chat-1').url,
        'cuplivo://conversation/chat-1',
      );
      expect(
        const ConversationLink(
          conversationId: 'chat-1',
          messageId: 'msg-2',
        ).url,
        'cuplivo://conversation/chat-1?message=msg-2',
      );
      // An id is encoded, never rejected: a space survives the round trip.
      expect(
        const ConversationLink(conversationId: 'my chat').url,
        'cuplivo://conversation/my%20chat',
      );
    });

    test('round-trips every id it builds', () {
      // Ids are opaque row keys, so the grammar has to carry whatever the
      // importer stored — whitespace, separators and control characters
      // included — for the conversation and for the message anchor alike.
      final ids = <String>[
        'chat-1',
        '会话-1',
        'my chat',
        'a\tb',
        'a\nb',
        'a\u007fb',
        'a/b',
        r'a\b',
        'a%b',
        'x+y?z&w#v',
        'x' * 200,
      ];
      for (final id in ids) {
        final conversationOnly = ConversationLink(conversationId: id);
        expect(
          ConversationLink.tryParse(conversationOnly.url)?.conversationId,
          id,
          reason: conversationOnly.url,
        );

        final anchored = ConversationLink(conversationId: id, messageId: id);
        final parsed = ConversationLink.tryParse(anchored.url);
        expect(parsed, isNotNull, reason: anchored.url);
        expect(parsed!.conversationId, id);
        expect(parsed.messageId, id);
      }
    });

    test('accepts the forms the OS hands over', () {
      expect(
        ConversationLink.tryParse(
          '  cuplivo://conversation/chat-1  ',
        )?.conversationId,
        'chat-1',
      );
      expect(
        ConversationLink.tryParse(
          'CUPLIVO://CONVERSATION/chat-1',
        )?.conversationId,
        'chat-1',
      );
      expect(
        ConversationLink.tryParse(
          'cuplivo://conversation/%E4%BC%9A%E8%AF%9D-1',
        )?.conversationId,
        '会话-1',
      );
      // What the Live Activity widget writes around an id it encodes.
      expect(
        ConversationLink.tryParse(
          'cuplivo://conversation/my%20chat',
        )?.conversationId,
        'my chat',
      );
      expect(
        ConversationLink.tryParse(
          'cuplivo://conversation/chat-1?message=m-1',
        )?.messageId,
        'm-1',
      );
    });

    test('rejects anything that is not one conversation link', () {
      for (final raw in [
        '',
        'cuplivo://',
        'cuplivo://conversation',
        'cuplivo://conversation/',
        // The content namespace never opens the app, and is not a link.
        'kelivo://conversation/chat-1',
        'https://conversation/chat-1',
        'cuplivo://other/chat-1',
        'cuplivo://conversation/chat-1/msg-2',
        'cuplivo://user@conversation/chat-1',
        'cuplivo://conversation:9/chat-1',
        'cuplivo://conversation/chat-1#fragment',
        'cuplivo://conversation/chat-1?message=',
        'cuplivo://conversation/chat-1?message',
        'cuplivo://conversation/chat-1?other=1',
        'cuplivo://conversation/chat-1?message=a&message=b',
        'cuplivo://conversation/chat-1?message=a&other=b',
        'cuplivo://conversation/%ZZ',
        'cuplivo://conversation/${'x' * 201}',
      ]) {
        expect(ConversationLink.tryParse(raw), isNull, reason: raw);
      }
    });

    test('an over-long id is rejected at the boundary', () {
      expect(
        ConversationLink.tryParse('cuplivo://conversation/${'x' * 200}'),
        isNotNull,
      );
      expect(
        ConversationLink.tryParse('cuplivo://conversation/${'x' * 201}'),
        isNull,
      );
    });

    test('an encoded id decodes to a row key, not a path', () {
      // The id is only ever handed to a lookup, so an encoded separator is an
      // id character like any other — the grammar guards *structure* instead:
      // the raw `cuplivo://conversation/a/b` above stays rejected.
      expect(
        ConversationLink.tryParse(
          'cuplivo://conversation/%2Fetc%2Fpasswd',
        )?.conversationId,
        '/etc/passwd',
      );
      expect(
        ConversationLink.tryParse('cuplivo://conversation/%20')?.conversationId,
        ' ',
      );
    });

    test('the builder writes only what the parser accepts', () {
      // One predicate, both directions: the copy entries are hidden where it is
      // false (a stored id longer than the cap), so no link is ever handed out
      // that `tryParse` would refuse.
      final ids = <String>[
        '',
        'chat-1',
        'my chat',
        'a/b',
        r'a\b',
        'a\u007fb',
        '会话',
        'x' * 200,
        'x' * 201,
      ];
      for (final id in ids) {
        if (!ConversationLink.supportsId(id)) {
          expect(
            () => ConversationLink(conversationId: id).url,
            throwsA(isA<AssertionError>()),
            reason: id,
          );
          continue;
        }
        final url = ConversationLink(conversationId: id).url;
        expect(ConversationLink.tryParse(url)?.conversationId, id, reason: url);
      }
      expect(ConversationLink.supportsId(''), isFalse);
      expect(ConversationLink.supportsId('x' * 200), isTrue);
      expect(ConversationLink.supportsId('x' * 201), isFalse);
    });

    test('the entry point is gated on the platform that registers it', () {
      // iOS registers `cuplivo` in ios/Runner/Info.plist; the other platforms
      // have no registration yet, so offering the copy action there would
      // promise a link their own device cannot open.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        expect(ConversationLink.osRegistered, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          expect(ConversationLink.osRegistered, isFalse, reason: '$platform');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });
  });

  test('the iOS bundle declares the scheme the links are written with', () {
    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
    final start = infoPlist.indexOf('<key>CFBundleURLTypes</key>');
    expect(start, isNonNegative, reason: 'no CFBundleURLTypes in Info.plist');
    final end = infoPlist.indexOf('</array>', start);
    expect(end, greaterThan(start));

    expect(
      infoPlist.substring(start, end),
      contains('<string>${ConversationLink.scheme}</string>'),
    );
  });
}
