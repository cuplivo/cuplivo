import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart'
    show StartupAssistantMode;
import 'package:Cuplivo/features/home/controllers/home_page_controller.dart'
    show resolveStartupAssistantId, selectStartupConversation;

Conversation _conv(String id, String? assistantId) => Conversation(
  id: id,
  title: id,
  assistantId: assistantId,
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  group('resolveStartupAssistantId', () {
    test('mostRecent mode never pins', () {
      expect(
        resolveStartupAssistantId(StartupAssistantMode.mostRecent, 'a1', const {
          'a1',
        }),
        isNull,
      );
    });

    test('pinned mode resolves only live assistants', () {
      expect(
        resolveStartupAssistantId(StartupAssistantMode.pinned, 'a1', const {
          'a1',
          'a2',
        }),
        'a1',
      );
      expect(
        resolveStartupAssistantId(StartupAssistantMode.pinned, 'gone', const {
          'a1',
        }),
        isNull,
      );
      expect(
        resolveStartupAssistantId(StartupAssistantMode.pinned, null, const {}),
        isNull,
      );
    });
  });

  group('selectStartupConversation', () {
    final conversations = [
      _conv('c1', 'a2'),
      _conv('c2', 'a1'),
      _conv('c3', 'a1'),
    ];

    test('mostRecent takes the globally most-recent', () {
      expect(
        selectStartupConversation(conversations, pinnedAssistantId: null)?.id,
        'c1',
      );
    });

    test('pinned takes the pinned assistant\'s most-recent', () {
      expect(
        selectStartupConversation(conversations, pinnedAssistantId: 'a1')?.id,
        'c2',
      );
    });

    test('pinned assistant with no conversations yields null', () {
      expect(
        selectStartupConversation(conversations, pinnedAssistantId: 'a3'),
        isNull,
      );
    });

    test('empty list yields null', () {
      expect(
        selectStartupConversation(const [], pinnedAssistantId: null),
        isNull,
      );
    });
  });
}
