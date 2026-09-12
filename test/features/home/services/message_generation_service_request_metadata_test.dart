import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/features/home/services/message_generation_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MessageGenerationService.resolveRequestOptionsFromMessages', () {
    ChatMessage userMessage({
      String id = 'u1',
      bool? requestAllowImagesApiRouting,
      String? requestExtraBodyJson,
    }) {
      return ChatMessage(
        id: id,
        role: 'user',
        content: 'draw a cat',
        conversationId: 'c1',
        requestAllowImagesApiRouting: requestAllowImagesApiRouting,
        requestExtraBodyJson: requestExtraBodyJson,
      );
    }

    test('falls back when no user message carries metadata', () {
      final options =
          MessageGenerationService.resolveRequestOptionsFromMessages([
            userMessage(),
            ChatMessage(role: 'assistant', content: 'ok', conversationId: 'c1'),
          ], fallbackAllowImagesApiRouting: true);

      expect(options.allowImagesApiRouting, isTrue);
      expect(options.requestExtraBody, isNull);
    });

    test('replays routing and options of the last user message', () {
      final options =
          MessageGenerationService.resolveRequestOptionsFromMessages([
            userMessage(
              id: 'old',
              requestAllowImagesApiRouting: true,
              requestExtraBodyJson: '{"quality":"low"}',
            ),
            userMessage(
              id: 'latest',
              requestAllowImagesApiRouting: false,
              requestExtraBodyJson:
                  '{"quality":"high","size":"3840x2160","n":2}',
            ),
          ], fallbackAllowImagesApiRouting: true);

      expect(options.allowImagesApiRouting, isFalse);
      expect(options.requestExtraBody, {
        'quality': 'high',
        'size': '3840x2160',
        'n': 2,
      });
    });

    test('persisted routing=false overrides the fallback', () {
      final options =
          MessageGenerationService.resolveRequestOptionsFromMessages([
            userMessage(requestAllowImagesApiRouting: false),
          ], fallbackAllowImagesApiRouting: true);

      expect(options.allowImagesApiRouting, isFalse);
      expect(options.requestExtraBody, isNull);
    });

    test('empty extra body yields null requestExtraBody', () {
      final options =
          MessageGenerationService.resolveRequestOptionsFromMessages([
            userMessage(
              requestAllowImagesApiRouting: true,
              requestExtraBodyJson: '{}',
            ),
          ], fallbackAllowImagesApiRouting: true);

      expect(options.allowImagesApiRouting, isTrue);
      expect(options.requestExtraBody, isNull);
    });

    test('malformed extra body JSON is treated as absent', () {
      final options =
          MessageGenerationService.resolveRequestOptionsFromMessages([
            userMessage(
              requestAllowImagesApiRouting: true,
              requestExtraBodyJson: '{not json',
            ),
          ], fallbackAllowImagesApiRouting: false);

      expect(options.allowImagesApiRouting, isTrue);
      expect(options.requestExtraBody, isNull);
    });

    test(
      'group resend: [User]: prefixed anchor message replays routing=false and body',
      () {
        final anchor = userMessage(
          id: 'anchor',
          requestAllowImagesApiRouting: false,
          requestExtraBodyJson: '{"quality":"high"}',
        ).copyWith(content: '[User]: 看图 [image:C:/tmp/photo.png]');
        final options =
            MessageGenerationService.resolveRequestOptionsFromMessages([
              ChatMessage(
                role: 'assistant',
                content: '[Alice]: 好的',
                conversationId: 'c1',
                speakerAssistantId: 'a1',
              ),
              anchor,
            ], fallbackAllowImagesApiRouting: true);

        expect(options.allowImagesApiRouting, isFalse);
        expect(options.requestExtraBody, {'quality': 'high'});
      },
    );

    test(
      'group regenerate: prefix-truncated history replays the anchor metadata',
      () {
        final options =
            MessageGenerationService.resolveRequestOptionsFromMessages([
              userMessage(),
              ChatMessage(
                role: 'assistant',
                content: '旧回答',
                conversationId: 'c1',
                speakerAssistantId: 'a1',
              ),
              userMessage(
                id: 'anchor',
                requestAllowImagesApiRouting: false,
                requestExtraBodyJson: '{"size":"1024x1024"}',
              ).copyWith(content: '[User]: 再来一张'),
            ], fallbackAllowImagesApiRouting: true);

        expect(options.allowImagesApiRouting, isFalse);
        expect(options.requestExtraBody, {'size': '1024x1024'});
      },
    );

    test('anchor bound ignores a newer user turn after the anchor', () {
      final options =
          MessageGenerationService.resolveRequestOptionsFromMessages(
            [
              userMessage(
                id: 'anchor',
                requestAllowImagesApiRouting: false,
                requestExtraBodyJson: '{"size":"1024x1024"}',
              ),
              ChatMessage(
                id: 'a1',
                role: 'assistant',
                content: 'ok',
                conversationId: 'c1',
              ),
              userMessage(
                id: 'newer',
                requestAllowImagesApiRouting: true,
                requestExtraBodyJson: '{"size":"3840x2160"}',
              ),
            ],
            fallbackAllowImagesApiRouting: true,
            anchorMessageId: 'a1',
          );

      expect(options.allowImagesApiRouting, isFalse);
      expect(options.requestExtraBody, {'size': '1024x1024'});
    });

    test('absent anchor scans the whole list', () {
      final options =
          MessageGenerationService.resolveRequestOptionsFromMessages(
            [
              userMessage(id: 'old', requestAllowImagesApiRouting: false),
              userMessage(
                id: 'newest',
                requestAllowImagesApiRouting: true,
                requestExtraBodyJson: '{"size":"3840x2160"}',
              ),
            ],
            fallbackAllowImagesApiRouting: true,
            anchorMessageId: 'missing',
          );

      expect(options.allowImagesApiRouting, isTrue);
      expect(options.requestExtraBody, {'size': '3840x2160'});
    });

    test('anchor at the head yields the fallback', () {
      final options =
          MessageGenerationService.resolveRequestOptionsFromMessages(
            [
              ChatMessage(
                id: 'a0',
                role: 'assistant',
                content: 'ok',
                conversationId: 'c1',
              ),
              userMessage(id: 'later', requestAllowImagesApiRouting: false),
            ],
            fallbackAllowImagesApiRouting: true,
            anchorMessageId: 'a0',
          );

      expect(options.allowImagesApiRouting, isTrue);
      expect(options.requestExtraBody, isNull);
    });

    test('inclusive anchor replays the anchor and ignores newer turns', () {
      final options =
          MessageGenerationService.resolveRequestOptionsFromMessages(
            [
              userMessage(
                id: 'anchor',
                requestAllowImagesApiRouting: false,
                requestExtraBodyJson: '{"size":"1024x1024"}',
              ),
              userMessage(
                id: 'newer',
                requestAllowImagesApiRouting: true,
                requestExtraBodyJson: '{"size":"3840x2160"}',
              ),
            ],
            fallbackAllowImagesApiRouting: true,
            anchorMessageId: 'anchor',
            anchorInclusive: true,
          );

      expect(options.allowImagesApiRouting, isFalse);
      expect(options.requestExtraBody, {'size': '1024x1024'});
    });

    test('inclusive anchor at the tail scans the whole list', () {
      final options =
          MessageGenerationService.resolveRequestOptionsFromMessages(
            [
              userMessage(id: 'old', requestAllowImagesApiRouting: false),
              userMessage(
                id: 'anchor',
                requestAllowImagesApiRouting: true,
                requestExtraBodyJson: '{"size":"1024x1024"}',
              ),
            ],
            fallbackAllowImagesApiRouting: true,
            anchorMessageId: 'anchor',
            anchorInclusive: true,
          );

      expect(options.allowImagesApiRouting, isTrue);
      expect(options.requestExtraBody, {'size': '1024x1024'});
    });

    test('absent inclusive anchor still scans the whole list', () {
      final options =
          MessageGenerationService.resolveRequestOptionsFromMessages(
            [
              userMessage(
                id: 'newest',
                requestAllowImagesApiRouting: false,
                requestExtraBodyJson: '{"size":"1024x1024"}',
              ),
            ],
            fallbackAllowImagesApiRouting: true,
            anchorMessageId: 'missing',
            anchorInclusive: true,
          );

      expect(options.allowImagesApiRouting, isFalse);
      expect(options.requestExtraBody, {'size': '1024x1024'});
    });
  });
}
