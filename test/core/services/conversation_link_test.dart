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
    });

    test('round-trips every id it builds', () {
      for (final link in const [
        ConversationLink(conversationId: 'chat-1'),
        ConversationLink(conversationId: 'chat-1', messageId: 'msg-2'),
        // Ids are UUIDs today, but nothing here may depend on that.
        ConversationLink(conversationId: '会话-1', messageId: 'run:2'),
        ConversationLink(conversationId: 'a%20b', messageId: 'x+y?z&w#v'),
      ]) {
        final parsed = ConversationLink.tryParse(link.url);
        expect(parsed, isNotNull, reason: link.url);
        expect(parsed!.conversationId, link.conversationId);
        expect(parsed.messageId, link.messageId);
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
        'cuplivo://conversation/%2Fetc%2Fpasswd',
        'cuplivo://conversation/%20',
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
