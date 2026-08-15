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
}
