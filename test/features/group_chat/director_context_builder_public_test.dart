import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/assistant_detail_injection.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/group_chat/services/director_context_builder.dart';

/// Offline service: no database, so the tool-event lookup returns nothing and
/// `getContextStartIndex` reports "no boundary" for every conversation.
class _FakeChatService extends ChatService {
  @override
  List<Map<String, dynamic>> getToolEvents(String assistantMessageId) =>
      const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = _FakeChatService();
  final builder = DirectorContextBuilder(chatService: service);

  GroupChat chatGroup({String prompt = 'You are the director.', int cap = 3}) {
    return GroupChat(
      id: 'g1',
      name: 'Room',
      conversationId: 'c1',
      directorSystemPrompt: prompt,
      maxAssistantMessagesPerRound: cap,
    );
  }

  ChatMessage user(String id, String content) =>
      ChatMessage(id: id, role: 'user', content: content, conversationId: 'c1');

  ChatMessage assistant(String id, String content, {String? senderId}) =>
      ChatMessage(
        id: id,
        role: 'assistant',
        content: content,
        conversationId: 'c1',
        senderId: senderId,
      );

  group('turn templates', () {
    test('E1 asks whether anyone should speak after a human message', () {
      final e1 = builder.buildUserTurnE1(
        userName: 'User',
        userMessageText: 'Hi',
      );
      expect(e1, startsWith('[User]: Hi\n\n'));
      expect(e1, contains('请选择是否由助手发送下条消息'));
      expect(e1, endsWith(DirectorContextBuilder.toolOnlyReminder));
    });

    test('E2 only asks who speaks next after an assistant message', () {
      final e2 = builder.buildAssistantTurnE2(
        assistantName: 'Alice',
        assistantContent: 'Hello',
      );
      expect(e2, startsWith('[Alice]: Hello\n\n'));
      expect(e2, contains('请选择由哪个助手发送下一条消息'));
      expect(e2, isNot(contains('是否')));
      expect(e2, endsWith(DirectorContextBuilder.toolOnlyReminder));
    });

    test('E3 merges the capped assistant turn with the new human turn', () {
      final e3 = builder.buildCapMergeE3(
        assistantName: 'Alice',
        pendingAssistantContent: 'At the cap',
        userName: 'User',
        newUserMessageText: 'Next',
      );
      expect(e3, startsWith('[Alice]: At the cap\n[User]: Next\n\n'));
      expect(e3, contains('请选择是否由助手发送下条消息'));
    });
  });

  group('buildRosterBlock', () {
    test('renders id, name and indented persona per assistant', () {
      final block = builder.buildRosterBlock([
        const Assistant(id: 'a1', name: 'Alice', systemPrompt: 'Senior dev'),
        const Assistant(
          id: 'a2',
          name: 'Bob',
          systemPrompt: 'Line one\nLine two',
        ),
      ]);

      expect(block, startsWith('<assistant_roster>\n'));
      expect(block, endsWith('</assistant_roster>'));
      expect(
        block,
        contains('- id: a1\n  name: Alice\n  persona: |\n    Senior dev'),
      );
      expect(block, contains('    Line one\n    Line two'));
    });

    test('truncates a persona past 4000 runes', () {
      final block = builder.buildRosterBlock([
        Assistant(id: 'a1', name: 'Alice', systemPrompt: '啊' * 4001),
      ]);
      expect(block, contains('…[truncated]'));
      final personaLines = block
          .split('\n')
          .where((line) => line.trim().startsWith('啊'));
      // The kept slice is emitted as one long indented line.
      expect(personaLines.single.length, lessThan(4005));
    });
  });

  group('substituteVariables', () {
    test('fills every documented director prompt variable', () {
      final out = builder.substituteVariables(
        '{group_name}|{member_names}|{max_assistant_messages_per_round}|{user_name}',
        group: chatGroup(cap: 7),
        userName: 'Ada',
        memberNames: const ['Alice', 'Bob'],
      );
      expect(out, 'Room|Alice, Bob|7|Ada');
    });

    test('date variables share one padded format and stay in order', () {
      final out = builder.substituteVariables(
        '{current_date} {current_datetime}',
        group: chatGroup(),
        userName: 'Ada',
        memberNames: const <String>[],
      );
      // "{current_date} {current_datetime}" collapses to "<date> <date> <time>".
      final match = RegExp(
        r'^(\d{4}-\d{2}-\d{2}) (\d{4}-\d{2}-\d{2} \d{2}:\d{2})$',
      ).firstMatch(out);
      expect(match, isNotNull, reason: out);
      expect(match!.group(1), match.group(2)!.split(' ').first);
    });

    test('the default director prompt keeps no unresolved variables', () {
      final out = builder.substituteVariables(
        GroupChat.defaultDirectorSystemPrompt,
        group: chatGroup(),
        userName: 'Ada',
        memberNames: const ['Alice'],
      );
      for (final variable in GroupChat.directorPromptVariables) {
        expect(out, isNot(contains(variable)));
      }
      expect(out, contains('Current group: Room'));
    });
  });

  group('contentForDirector', () {
    test('keeps text body and drops attachments entirely', () {
      final message = ChatMessage(
        role: 'user',
        conversationId: 'c1',
        parts: [
          TextPart('看图 '),
          ImagePart(uri: 'C:/tmp/photo.png', mime: 'image/png'),
          FilePart(uri: '/tmp/r.pdf', name: 'r.pdf', mime: 'application/pdf'),
        ],
      );
      expect(builder.contentForDirector(message), '看图');
    });

    test('lists tool card titles from the message parts', () {
      final message = ChatMessage(
        role: 'assistant',
        conversationId: 'c1',
        parts: [
          TextPart('done'),
          ToolCallPart(jsonEncode({'id': 'c1', 'name': 'search_web'})),
          ToolCallPart(jsonEncode({'id': 'c2', 'name': 'read_file'})),
        ],
      );
      expect(
        builder.contentForDirector(message),
        'done\n[tool: search_web]\n[tool: read_file]',
      );
    });

    test('falls back to persisted tool events when no cards are inline', () {
      final message = ChatMessage(
        id: 'm-tools',
        role: 'assistant',
        content: 'body',
        conversationId: 'c1',
      );
      final serviceWithEvents = _ToolEventChatService(
        events: const [
          {'name': 'web_search'},
          {'toolName': 'legacy_tool'},
          {'name': ''},
        ],
      );
      final scoped = DirectorContextBuilder(chatService: serviceWithEvents);
      expect(
        scoped.contentForDirector(message),
        'body\n[tool: web_search]\n[tool: legacy_tool]',
      );
    });
  });

  group('buildApiMessagesFromPublic', () {
    final alice = const Assistant(id: 'a1', name: 'Alice', systemPrompt: 'A');

    test('emits E1/E2 history plus the live tip', () {
      final u1 = user('u1', 'Hello');
      final a1 = assistant('a1-message', 'Hi', senderId: 'a1');
      final u2 = user('u2', 'Again');
      final tip = builder.buildUserTurnE1(
        userName: 'User',
        userMessageText: 'Again',
      );

      final api = builder.buildApiMessagesFromPublic(
        group: chatGroup(),
        publicMessages: [u1, a1, u2],
        versionSelections: const {},
        newUserContent: tip,
        rosterAssistants: [alice],
        userName: 'User',
        memberNames: const ['User', 'Alice'],
        assistantsById: {'a1': alice},
        excludeTrailingUserMessageId: u2.id,
      );

      expect(api.first['role'], 'system');
      expect(api.first['content'], 'You are the director.');
      expect(api.last['content'], tip);
      final userContents = api
          .where((m) => m['role'] == 'user')
          .map((m) => m['content'] as String)
          .toList();
      expect(userContents.length, 3); // E1 history, E2, tip
      expect(userContents[0], contains('[User]: Hello'));
      expect(userContents[1], contains('[Alice]: Hi'));
    });

    test('unknown speaker falls back to the given name', () {
      final api = builder.buildApiMessagesFromPublic(
        group: chatGroup(),
        publicMessages: [
          user('u1', 'Q'),
          assistant('m1', 'A', senderId: 'gone'),
        ],
        versionSelections: const {},
        newUserContent: 'tip',
        rosterAssistants: [alice],
        userName: 'User',
        memberNames: const ['User', 'Alice'],
        assistantsById: const {},
        fallbackAssistantName: 'Member',
      );
      expect(api[2]['content'], contains('[gone]: A'));

      final anonymous = builder.buildApiMessagesFromPublic(
        group: chatGroup(),
        publicMessages: [assistant('m1', 'A')],
        versionSelections: const {},
        newUserContent: 'tip',
        rosterAssistants: [alice],
        userName: 'User',
        memberNames: const ['User', 'Alice'],
        assistantsById: const {},
        fallbackAssistantName: 'Member',
      );
      expect(anonymous[1]['content'], contains('[Member]: A'));
    });

    test('beforeSystemPrompt puts the roster in its own system message', () {
      final g = chatGroup().copyWith(
        assistantDetailInjectionMode:
            AssistantDetailInjectionMode.beforeSystemPrompt,
      );
      final api = builder.buildApiMessagesFromPublic(
        group: g,
        publicMessages: const [],
        versionSelections: const {},
        newUserContent: 'tip',
        rosterAssistants: [alice],
        userName: 'User',
        memberNames: const ['User', 'Alice'],
        assistantsById: {'a1': alice},
      );
      expect(api, hasLength(3));
      expect(api[0]['content'], startsWith('<assistant_roster>'));
      expect(api[1]['content'], 'You are the director.');
    });

    test('appendIntoSystemPrompt merges the roster into the prompt', () {
      final g = chatGroup().copyWith(
        assistantDetailInjectionMode:
            AssistantDetailInjectionMode.appendIntoSystemPrompt,
      );
      final api = builder.buildApiMessagesFromPublic(
        group: g,
        publicMessages: const [],
        versionSelections: const {},
        newUserContent: 'tip',
        rosterAssistants: [alice],
        userName: 'User',
        memberNames: const ['User', 'Alice'],
        assistantsById: {'a1': alice},
      );
      // The tip rides on the same single system message in this mode.
      final system =
          api.where((m) => m['role'] == 'system').single['content'] as String;
      expect(
        system.indexOf('You are the director.'),
        lessThan(system.indexOf('<assistant_roster>')),
      );
    });

    test(
      'skipPendingCapMessageId drops the merged assistant turn from history',
      () {
        final capped = assistant('cap', 'At the cap', senderId: 'a1');
        final api = builder.buildApiMessagesFromPublic(
          group: chatGroup(),
          publicMessages: [user('u1', 'Q'), capped],
          versionSelections: const {},
          newUserContent: 'tip',
          rosterAssistants: [alice],
          userName: 'User',
          memberNames: const ['User', 'Alice'],
          assistantsById: {'a1': alice},
          skipPendingCapMessageId: capped.id,
        );
        final contents = api
            .where((m) => m['role'] == 'user')
            .map((m) => m['content'] as String)
            .toList();
        expect(contents, hasLength(2)); // E1 history + tip
        expect(contents.first, isNot(contains('At the cap')));
        expect(api.last['content'], 'tip');
      },
    );

    test('collapsePublicVersions defaults to the last version by index', () {
      final v0 = assistant('m0', 'v0', senderId: 'a1');
      final v1 = assistant('m1', 'v1', senderId: 'a1');
      final grouped = [
        v0.copyWith(groupId: 'g', version: 0),
        v1.copyWith(groupId: 'g', version: 1),
      ];
      expect(
        builder.collapsePublicVersions(grouped, const {}).single.content,
        'v1',
      );
      expect(
        builder.collapsePublicVersions(grouped, {'g': 0}).single.content,
        'v0',
      );
    });

    test('truncateIndex slices collapsed space, not raw rows', () {
      final old = user('u0', 'Old start');
      final v0 = assistant('v0', 'old version', senderId: 'a1');
      final v1 = assistant('v1', 'new version', senderId: 'a1');
      final messages = [
        old,
        v0.copyWith(groupId: 'ag', version: 0),
        v1.copyWith(groupId: 'ag', version: 1),
      ];
      // Logical slots: [u0, ag]. Boundary at slot 1 keeps only the group.
      final api = builder.buildApiMessagesFromPublic(
        group: chatGroup(),
        publicMessages: messages,
        versionSelections: const {},
        newUserContent: 'tip',
        rosterAssistants: [alice],
        userName: 'User',
        memberNames: const ['User', 'Alice'],
        assistantsById: {'a1': alice},
        truncateIndexOverride: 1,
      );
      final contents = api
          .where((m) => m['role'] == 'user')
          .map((m) => m['content'] as String)
          .toList();
      expect(contents.length, 2);
      expect(contents.first, contains('[Alice]: new version'));
      expect(contents.first, isNot(contains('Old start')));
    });

    test(
      'historical user turns never leak attachment paths to the director',
      () {
        final u0 = ChatMessage(
          id: 'u0',
          role: 'user',
          conversationId: 'c1',
          parts: [
            TextPart('看图 '),
            ImagePart(uri: 'C:/tmp/photo.png', mime: 'image/png'),
            FilePart(uri: '/tmp/r.pdf', name: 'r.pdf', mime: 'application/pdf'),
          ],
        );
        final api = builder.buildApiMessagesFromPublic(
          group: chatGroup(),
          publicMessages: [
            u0,
            assistant('a0', '好的', senderId: 'a1'),
          ],
          versionSelections: const {},
          newUserContent: 'tip',
          rosterAssistants: [alice],
          userName: 'User',
          memberNames: const ['User', 'Alice'],
          assistantsById: {'a1': alice},
        );
        final first = api[1]['content'] as String;
        expect(first, isNot(contains('C:/tmp/photo.png')));
        expect(first, isNot(contains('r.pdf')));
        expect(first, contains('看图'));
      },
    );

    test('legacy marker-bearing rows collapse to bare placeholders', () {
      final u0 = user(
        'u0',
        '看图 [image:C:/tmp/photo.png] 附件 [file:/tmp/r.pdf|r.pdf|x]',
      );
      final api = builder.buildApiMessagesFromPublic(
        group: chatGroup(),
        publicMessages: [u0],
        versionSelections: const {},
        newUserContent: 'tip',
        rosterAssistants: [alice],
        userName: 'User',
        memberNames: const ['User', 'Alice'],
        assistantsById: {'a1': alice},
      );
      final first = api[1]['content'] as String;
      expect(first, contains('[image]'));
      expect(first, contains('[file]'));
      expect(first, isNot(contains('photo.png')));
    });
  });

  group('maybeAppendRoster', () {
    test('system-prompt modes never append to a turn', () {
      for (final mode in [
        AssistantDetailInjectionMode.beforeSystemPrompt,
        AssistantDetailInjectionMode.appendIntoSystemPrompt,
      ]) {
        expect(
          builder.maybeAppendRoster(
            mode: mode,
            n: 1,
            isHumanUserTurn: true,
            isFirstHumanUser: true,
            userTurnCount: 1,
            directorUserMsgCount: 1,
          ),
          isFalse,
        );
      }
    });

    test('endOfFirstUserMessage only fires on the first human turn', () {
      bool call({required bool first, required bool human}) =>
          builder.maybeAppendRoster(
            mode: AssistantDetailInjectionMode.endOfFirstUserMessage,
            n: 5,
            isHumanUserTurn: human,
            isFirstHumanUser: first,
            userTurnCount: 2,
            directorUserMsgCount: 2,
          );
      expect(call(first: true, human: true), isTrue);
      expect(call(first: false, human: true), isFalse);
      expect(call(first: true, human: false), isFalse);
    });

    test('everyN modes respect n and turn parity', () {
      expect(
        builder.maybeAppendRoster(
          mode: AssistantDetailInjectionMode.everyNUserMessages,
          n: 2,
          isHumanUserTurn: true,
          isFirstHumanUser: false,
          userTurnCount: 4,
          directorUserMsgCount: 4,
        ),
        isTrue,
      );
      expect(
        builder.maybeAppendRoster(
          mode: AssistantDetailInjectionMode.everyNUserMessages,
          n: 0,
          isHumanUserTurn: true,
          isFirstHumanUser: false,
          userTurnCount: 4,
          directorUserMsgCount: 4,
        ),
        isFalse,
      );
      expect(
        builder.maybeAppendRoster(
          mode: AssistantDetailInjectionMode.everyNUserAndAssistantMessages,
          n: 3,
          isHumanUserTurn: false,
          isFirstHumanUser: false,
          userTurnCount: 9,
          directorUserMsgCount: 3,
        ),
        isTrue,
      );
    });

    test('endOfEveryUserAndAssistantMessage always appends', () {
      expect(
        builder.maybeAppendRoster(
          mode: AssistantDetailInjectionMode.endOfEveryUserAndAssistantMessage,
          n: 5,
          isHumanUserTurn: false,
          isFirstHumanUser: false,
          userTurnCount: 0,
          directorUserMsgCount: 0,
        ),
        isTrue,
      );
    });
  });

  group('turn counters', () {
    test('count only the roles each budget cares about', () {
      final messages = [
        user('u1', 'a'),
        assistant('a1', 'b', senderId: 'a1'),
        ChatMessage(role: 'system', content: 'c', conversationId: 'c1'),
      ];
      expect(builder.countHumanUserTurnsFromPublic(messages), 1);
      expect(builder.countDirectorUserMessagesFromPublic(messages), 2);
    });
  });
}

class _ToolEventChatService extends ChatService {
  _ToolEventChatService({required this.events});

  final List<Map<String, dynamic>> events;

  @override
  List<Map<String, dynamic>> getToolEvents(String assistantMessageId) => events;
}
