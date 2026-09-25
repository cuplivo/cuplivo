import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/services/logging/context_log_tail_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kelivo_ctx_tail_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  File fileWith(String contents) {
    final file = File('${tempDir.path}/context_logs.txt');
    file.writeAsStringSync(contents);
    return file;
  }

  String line(String id, {String assistant = 'A'}) {
    return jsonEncode({
      'timestamp': '2026-08-13T00:00:00.000Z',
      'conversationId': id,
      'assistantName': assistant,
      'provider': 'p',
      'model': 'm',
      'totalTokens': 1,
      'messages': <Object>[],
    });
  }

  test('missing file is exhausted', () async {
    final page = await ContextLogTailReader.readPage(
      file: File('${tempDir.path}/missing.txt'),
    );
    expect(page.snapshots, isEmpty);
    expect(page.hasMore, isFalse);
  });

  test('empty file is exhausted', () async {
    final page = await ContextLogTailReader.readPage(file: fileWith(''));
    expect(page.snapshots, isEmpty);
    expect(page.hasMore, isFalse);
  });

  test('reads newest snapshots first and paginates backward', () async {
    final file = fileWith(
      '${line('1')}\n${line('2')}\n${line('3')}\n${line('4')}\n${line('5')}\n',
    );

    final first = await ContextLogTailReader.readPage(file: file, limit: 2);
    expect(first.snapshots.map((s) => s.conversationId), ['5', '4']);
    expect(first.hasMore, isTrue);

    final second = await ContextLogTailReader.readPage(
      file: file,
      cursor: first.cursor,
      limit: 2,
    );
    expect(second.snapshots.map((s) => s.conversationId), ['3', '2']);
    expect(second.hasMore, isTrue);

    final third = await ContextLogTailReader.readPage(
      file: file,
      cursor: second.cursor,
      limit: 2,
    );
    expect(third.snapshots.map((s) => s.conversationId), ['1']);
    expect(third.hasMore, isFalse);
  });

  test('parses last line when file has no trailing newline', () async {
    final file = fileWith('${line('1')}\n${line('2')}');
    final page = await ContextLogTailReader.readPage(file: file, limit: 10);
    expect(page.snapshots.map((s) => s.conversationId), ['2', '1']);
    expect(page.hasMore, isFalse);
  });

  test('skips blank and invalid lines', () async {
    final file = fileWith('${line('1')}\n\nnot-json\n${line('2')}\n[]\n');
    final page = await ContextLogTailReader.readPage(file: file, limit: 10);
    expect(page.snapshots.map((s) => s.conversationId), ['2', '1']);
    expect(page.hasMore, isFalse);
  });

  test('reconstructs a line split across tiny chunks including CJK', () async {
    final file = fileWith('${line('中文', assistant: '助手名称')}\n${line('尾')}\n');
    final page = await ContextLogTailReader.readPage(
      file: file,
      limit: 10,
      chunkSize: 7,
    );
    expect(page.snapshots.map((s) => s.conversationId), ['尾', '中文']);
    expect(page.snapshots.last.assistantName, '助手名称');
    expect(page.hasMore, isFalse);
  });

  test('next page still sees newlines left in pending leftover', () async {
    final file = fileWith('${line('1')}\n${line('2')}\n${line('3')}\n');
    final first = await ContextLogTailReader.readPage(file: file, limit: 1);
    expect(first.snapshots.single.conversationId, '3');
    expect(first.cursor.pending, isNotEmpty);
    expect(first.cursor.pending.contains(10), isTrue);
    expect(first.cursor.position, isNot(lessThan(0)));

    final second = await ContextLogTailReader.readPage(
      file: file,
      cursor: first.cursor,
      limit: 10,
    );
    expect(second.snapshots.map((s) => s.conversationId), ['2', '1']);
    expect(second.hasMore, isFalse);
    expect(second.cursor.position, isNot(lessThan(0)));
  });

  test('newline-only file does not produce a negative cursor', () async {
    final page = await ContextLogTailReader.readPage(file: fileWith('\n\n\n'));
    expect(page.snapshots, isEmpty);
    expect(page.hasMore, isFalse);
    expect(page.cursor.position, 0);
    expect(page.cursor.pending, isEmpty);
  });

  test('line larger than chunk size is still parsed', () async {
    final huge = line('big', assistant: 'x' * 200);
    final file = fileWith('${line('small')}\n$huge\n');
    final page = await ContextLogTailReader.readPage(
      file: file,
      limit: 2,
      chunkSize: 32,
    );
    expect(page.snapshots.map((s) => s.conversationId), ['big', 'small']);
    expect(page.snapshots.first.assistantName.length, 200);
    expect(page.hasMore, isFalse);
  });
}
