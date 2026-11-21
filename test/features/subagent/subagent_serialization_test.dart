import 'package:Cuplivo/core/models/assistant.dart';
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
}
