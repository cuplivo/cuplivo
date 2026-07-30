import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/assistant_request_options.dart';
import 'package:Cuplivo/core/services/chat/model_capability_service.dart';
import 'package:Cuplivo/features/home/services/message_generation_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shared chat request options', () {
    test(
      'preserves assistant headers/body and conversation header precedence',
      () {
        final assistant = Assistant(
          id: 'assistant-1',
          name: 'Alice',
          customHeaders: const <Map<String, String>>[
            <String, String>{'name': ' X-Custom ', 'value': 'value'},
            <String, String>{'name': ' ', 'value': 'ignored'},
            <String, String>{
              'name': 'x-conversation-id',
              'value': 'must-not-win',
            },
          ],
          customBody: const <Map<String, String>>[
            <String, String>{'key': ' temperature ', 'value': '0.2'},
            <String, String>{'key': '', 'value': 'ignored'},
          ],
        );

        final customHeaders = buildAssistantCustomHeaders(assistant);
        expect(customHeaders, <String, String>{
          'X-Custom': 'value',
          'x-conversation-id': 'must-not-win',
        });
        expect(
          buildConversationRequestHeaders(
            conversationId: 'group-1',
            customHeaders: customHeaders,
          ),
          <String, String>{
            'X-Custom': 'value',
            conversationIdHeaderName: 'group-1',
          },
        );
        expect(buildAssistantCustomBody(assistant), <String, dynamic>{
          'temperature': '0.2',
        });
      },
    );

    test('uses explicit model abilities as the capability source of truth', () {
      final config = ProviderConfig(
        id: 'provider-1',
        enabled: true,
        name: 'Provider',
        apiKey: '',
        baseUrl: '',
        modelOverrides: const <String, dynamic>{
          'model-1': <String, dynamic>{
            'abilities': <String>[' TOOL ', 'reasoning'],
          },
          'model-2': <String, dynamic>{'abilities': <String>[]},
        },
      );

      expect(
        ModelCapabilityService.supportsToolsForConfig(config, 'model-1'),
        isTrue,
      );
      expect(
        ModelCapabilityService.supportsToolsForConfig(config, 'model-2'),
        isFalse,
      );
    });
  });
}
