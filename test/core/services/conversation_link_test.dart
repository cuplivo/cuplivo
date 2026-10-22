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
      for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          expect(ConversationLink.osRegistered, isTrue, reason: '$platform');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
      for (final platform in [
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

  test('the Android manifest resolves cuplivo links from a browsable filter', () {
    // The Kotlin suite resolves a cuplivo:// BROWSABLE intent against the merged
    // manifest, but CI runs only flutter test, so the declaration is pinned here.
    // Scoping to the filter is the point: a scheme that merely appears somewhere
    // in the file resolves nothing, and dropping a category or moving <data>
    // into another filter silently breaks the tap without changing the scheme.
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final data = manifest.indexOf(
      '<data android:scheme="${ConversationLink.scheme}"',
    );
    expect(data, isNonNegative, reason: 'no cuplivo <data> declaration');
    final start = manifest.lastIndexOf('<intent-filter', data);
    final end = manifest.indexOf('</intent-filter>', data);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));

    final filter = manifest.substring(start, end);
    expect(filter, contains('android.intent.action.VIEW'));
    expect(filter, contains('android.intent.category.DEFAULT'));
    expect(filter, contains('android.intent.category.BROWSABLE'));

    // Deep links stay on app.mobile_background, not Flutter's router: without
    // this the URL would become the initial route (deeplinking defaults to on).
    final meta = manifest.indexOf('android:name="flutter_deeplinking_enabled"');
    expect(meta, isNonNegative);
    expect(
      manifest.substring(
        manifest.lastIndexOf('<meta-data', meta),
        manifest.indexOf('>', meta),
      ),
      contains('android:value="false"'),
    );
  });
}
