import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/features/home/controllers/chat_actions.dart';

void main() {
  test(
    'mergeStreamingToolEventRecord keeps non-empty args and server flag',
    () {
      final merged = ChatActions.mergeStreamingToolEventRecord(
        {
          'id': 'code_1',
          'name': 'code_execution',
          'arguments': {'language': 'python', 'code': 'print(1)'},
          'content': 'ok',
          'server': true,
          'metadata': {'round': 1},
        },
        {
          'id': 'code_1',
          'name': 'code_execution',
          'arguments': <String, dynamic>{},
          'content': null,
          'metadata': {'source': 'server'},
        },
      );

      expect(merged['arguments'], {'language': 'python', 'code': 'print(1)'});
      expect(merged['content'], 'ok');
      expect(merged['server'], isTrue);
      expect(merged['metadata'], {'round': 1, 'source': 'server'});
    },
  );
}
