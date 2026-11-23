import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/core/services/api/message_authorship.dart';
import 'package:Cuplivo/core/services/api/request_image_context.dart';
import 'package:Cuplivo/features/home/services/local_tools_service.dart';
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
