import 'package:Cuplivo/core/services/streaming_content_notifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('updates only the selected message translation notifier', () {
    final streaming = StreamingContentNotifier();
    addTearDown(streaming.dispose);
    final notifier = streaming.getNotifier('message-1');
    streaming.updateContent('message-1', 'source', 4);

    var notifications = 0;
    notifier.addListener(() => notifications++);
    streaming.updateTranslation('message-1', 'translated');

    expect(notifier.value.content, 'source');
    expect(notifier.value.totalTokens, 4);
    expect(notifier.value.translation, 'translated');
    expect(notifications, 1);
  });

  test('ignores translation updates for messages without a live notifier', () {
    final streaming = StreamingContentNotifier();
    addTearDown(streaming.dispose);

    streaming.updateTranslation('missing', 'translated');

    expect(streaming.hasNotifier('missing'), isFalse);
  });

  test('updateRetryStatus sets and clears the countdown', () {
    final streaming = StreamingContentNotifier();
    addTearDown(streaming.dispose);
    final notifier = streaming.getNotifier('m1');
    streaming.updateContent('m1', 'text', 4);
    final status = RetryStatus(
      attempt: 1,
      maxRetries: 2,
      retryAt: DateTime.now().add(const Duration(seconds: 5)),
    );

    streaming.updateRetryStatus('m1', status);
    expect(notifier.value.retryStatus, status);

    streaming.updateRetryStatus('m1', null);
    expect(notifier.value.retryStatus, isNull);
    // Other fields survive the retry update.
    expect(notifier.value.content, 'text');
    expect(notifier.value.totalTokens, 4);
  });

  test('retryStatus survives content updates and re-creation after clear', () {
    final streaming = StreamingContentNotifier();
    addTearDown(streaming.dispose);
    final status = RetryStatus(
      attempt: 2,
      maxRetries: 3,
      retryAt: DateTime.now().add(const Duration(seconds: 3)),
    );
    final notifier = streaming.getNotifier('m2');
    streaming.updateRetryStatus('m2', status);
    streaming.updateContent('m2', 'hello', 7);
    expect(notifier.value.retryStatus, status);

    streaming.clear();
    var fresh = streaming.getNotifier('m2');
    expect(fresh.value.retryStatus, isNull);
    streaming.updateRetryStatus('m2', status);
    fresh = streaming.getNotifier('m2');
    expect(fresh.value.retryStatus, status);
  });
}
