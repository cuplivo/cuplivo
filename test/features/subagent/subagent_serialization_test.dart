import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/core/services/api/message_authorship.dart';
import 'package:Cuplivo/core/services/api/request_image_context.dart';
import 'package:Cuplivo/features/home/services/local_tools_service.dart';
import 'package:Cuplivo/features/subagent/services/subagent_target.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('a subagent notice is not the user’s own words', () {
    test('isUserInputMessage rejects it the way it rejects a peer turn', () {
      final messages = <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': 'look at this',
          imageContextOwnerKey: 'm1',
        },
        <String, dynamic>{
          'role': 'user',
          'content': 'Subagent finished: auth',
          imageContextOwnerKey: 'm2',
          subagentResultKey: true,
        },
      ];

      expect(isUserInputMessage(messages.last, hasOwners: true), isFalse);
      // The human's turn keeps the attachments even though the notice is newer.
      expect(lastUserInputIndex(messages), 0);
    });

    test('a plain user turn is still a user turn', () {
      expect(
        isUserInputMessage(<String, dynamic>{
          'role': 'user',
          'content': 'hi',
        }, hasOwners: false),
        isTrue,
      );
    });
  });

  group('the delegation tool is not offered where it is not allowed', () {
    Assistant assistant() => Assistant(
      id: 'a',
      name: 'A',
      localToolIds: const <String>[
        LocalToolNames.delegate,
        LocalToolNames.awaitJob,
        LocalToolNames.calculate,
      ],
    );

    Iterable<String> names({required bool allowDelegation}) =>
        LocalToolsService.buildToolDefinitions(
          assistant: assistant(),
          supportsTools: true,
          allowDelegation: allowDelegation,
        ).map(
          (definition) => (definition['function'] as Map)['name'] as String,
        );

    test('an ordinary conversation gets it', () {
      expect(names(allowDelegation: true), contains(LocalToolNames.delegate));
    });

    test('a conversation at the limit does not', () {
      final offered = names(allowDelegation: false);
      expect(offered, isNot(contains(LocalToolNames.delegate)));
      // Everything else is untouched: the limit is about delegation only.
      expect(offered, contains(LocalToolNames.calculate));
    });
  });

  group('the two tool contracts', () {
    test('delegate needs a task and a label', () {
      final function = LocalToolsService.delegateDefinition['function'] as Map;
      expect((function['parameters'] as Map)['required'], <String>[
        'task',
        'label',
      ]);
      expect(function['name'], LocalToolNames.delegate);
    });

    test('await_job needs the job id it was given', () {
      final function = LocalToolsService.awaitJobDefinition['function'] as Map;
      expect((function['parameters'] as Map)['required'], <String>['job_id']);
      expect(function['name'], LocalToolNames.awaitJob);
    });

    test('a conversation cannot be told to wait without delegating', () {
      // `await_job` is only useful for a job this process started; the pair is
      // enabled together in the assistant's toolbox, not per platform.
      expect(
        LocalToolsService.definitions.keys,
        containsAll(<String>[LocalToolNames.delegate, LocalToolNames.awaitJob]),
      );
    });
  });

  group('the delegation target', () {
    test('with nothing selected the schema is exactly the one that shipped', () {
      // Not "equivalent" — the same object, so a request from an assistant that
      // has not configured targets pays nothing for the feature.
      expect(
        LocalToolsService.delegateDefinitionFor(const <Assistant>[]),
        same(LocalToolsService.delegateDefinition),
      );
      final function = LocalToolsService.delegateDefinition['function'] as Map;
      final properties = (function['parameters'] as Map)['properties'] as Map;
      expect(properties.keys, isNot(contains('target')));
    });

    test('a selected target adds one required parameter carrying the menu', () {
      final definition = LocalToolsService.delegateDefinitionFor(<Assistant>[
        Assistant(id: 'a-1', name: 'SQL 专家', description: '把需求写成 SQL'),
        Assistant(id: 'a-2', name: '翻译官'),
      ]);
      final parameters = (definition['function'] as Map)['parameters'] as Map;
      expect(parameters['required'], <String>['task', 'label', 'target']);

      final target = (parameters['properties'] as Map)['target'] as Map;
      expect(target['enum'], <String>[
        'general',
        'assistant:a-1',
        'assistant:a-2',
      ]);
      final menu = target['description'] as String;
      expect(menu, contains('${SubagentTargetKeys.general} — a copy of'));
      expect(menu, contains('assistant:a-1 — SQL 专家：把需求写成 SQL'));
      // No description, no colon: the name alone is a menu entry too.
      expect(menu, contains('assistant:a-2 — 翻译官'));
      expect(menu.split('\n').where((line) => line.trim().isEmpty), isEmpty);
    });
  });

  group('the depth setting', () {
    test('is one level for an assistant written before it existed', () {
      final plain = Assistant(id: 'a', name: 'A');
      expect(plain.subagentDepth, kSubagentDepthMin);

      // An assistant stored before the field existed has no key at all.
      final json = plain.toJson()..remove('subagentDepth');
      expect(Assistant.fromJson(json).subagentDepth, kSubagentDepthMin);
    });

    test('survives the assistant JSON', () {
      final deep = Assistant(id: 'a', name: 'A', subagentDepth: 3);
      expect(Assistant.fromJson(deep.toJson()).subagentDepth, 3);
      // And through copyWith, which every write path goes through.
      expect(deep.copyWith(name: 'B').subagentDepth, 3);
    });

    test('is clamped to the range the picker offers', () {
      final json = Assistant(id: 'a', name: 'A').toJson();
      expect(
        Assistant.fromJson({...json, 'subagentDepth': 99}).subagentDepth,
        kSubagentDepthMax,
      );
      expect(
        Assistant.fromJson({...json, 'subagentDepth': 0}).subagentDepth,
        kSubagentDepthMin,
      );
      expect(
        Assistant(id: 'a', name: 'A').copyWith(subagentDepth: -5).subagentDepth,
        kSubagentDepthMin,
      );
    });
  });

  group('mail between the two sides of a delegation', () {
    test('is not the human’s turn, and the human keeps the last one', () {
      final messages = <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': 'look at this',
          imageContextOwnerKey: 'm1',
        },
        <String, dynamic>{
          'role': 'user',
          'content': 'The delegator sent a message: use YAML',
          imageContextOwnerKey: 'm2',
          subagentMailKey: true,
        },
      ];

      expect(isUserInputMessage(messages.last, hasOwners: true), isFalse);
      expect(lastUserInputIndex(messages), 0);
    });

    test('the part round-trips and keeps who sent it', () {
      const part = SubagentMailPart(
        from: SubagentMailSender.delegator,
        senderConversationId: 'parent',
      );
      final decoded = MessagePart.fromRow(part.kind, part.encodePayload());
      expect(decoded, part);
      expect(decoded, isA<SubagentMailPart>());
      expect((decoded as SubagentMailPart).from, SubagentMailSender.delegator);
      expect(decoded.senderConversationId, 'parent');
    });

    test('its row id is stable per sender and tool call', () {
      final first = SubagentMailPart.messageIdFor('parent', 'call-1');
      expect(SubagentMailPart.messageIdFor('parent', 'call-1'), first);
      expect(SubagentMailPart.messageIdFor('parent', 'call-2'), isNot(first));
      // A call with no id must not collapse two sends into one row.
      expect(SubagentMailPart.messageIdFor('parent', ''), isNot(first));
    });
  });

  group('the message tools', () {
    Assistant childAssistant() => Assistant(
      id: 'a',
      name: 'A',
      localToolIds: const <String>[
        LocalToolNames.delegate,
        LocalToolNames.awaitJob,
      ],
    );

    String nameOf(Map<String, dynamic> definition) =>
        (definition['function'] as Map)['name'] as String;

    test('a delegator names the job and the text', () {
      final function =
          LocalToolsService.sendMessageDefinition(subagent: false)['function']
              as Map;
      expect(function['name'], LocalToolNames.sendMessage);
      expect((function['parameters'] as Map)['required'], <String>[
        'job_id',
        'text',
      ]);
    });

    test('a child has only the text to give', () {
      final function =
          LocalToolsService.sendMessageDefinition(subagent: true)['function']
              as Map;
      expect((function['parameters'] as Map)['required'], <String>['text']);
      expect(
        (function['parameters'] as Map)['properties'],
        isNot(contains('job_id')),
      );
    });

    test('interrupt names the job', () {
      final function = LocalToolsService.interruptDefinition['function'] as Map;
      expect(function['name'], LocalToolNames.interrupt);
      expect((function['parameters'] as Map)['required'], <String>['job_id']);
    });

    test('a child gets the child schema and never the delegation pair', () {
      final offered = LocalToolsService.buildToolDefinitions(
        assistant: childAssistant(),
        supportsTools: true,
        allowDelegation: false,
        isSubagent: true,
      );
      final names = offered.map(nameOf);
      expect(names, contains(LocalToolNames.sendMessage));
      expect(names, isNot(contains(LocalToolNames.delegate)));
      expect(names, isNot(contains(LocalToolNames.awaitJob)));
      expect(names, isNot(contains(LocalToolNames.interrupt)));
      final send = offered.firstWhere(
        (definition) => nameOf(definition) == LocalToolNames.sendMessage,
      );
      expect(
        ((send['function'] as Map)['parameters'] as Map)['required'],
        <String>['text'],
      );
    });

    test('a delegator gets the pair and the stop switch', () {
      final names = LocalToolsService.buildToolDefinitions(
        assistant: childAssistant(),
        supportsTools: true,
      ).map(nameOf);
      expect(names, contains(LocalToolNames.sendMessage));
      expect(names, contains(LocalToolNames.interrupt));
    });
  });
}
