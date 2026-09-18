import 'package:flutter_test/flutter_test.dart';

import 'package:drift/native.dart';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/features/stats/models/stats_models.dart';

void main() {
  late AppDatabase db;
  late ChatDatabaseRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = ChatDatabaseRepository(db);
  });

  tearDown(() async {
    await repo.close();
    await db.close();
  });

  Future<void> seed() async {
    final convTs = DateTime(2026, 1, 2).microsecondsSinceEpoch;
    await db.customStatement(
      "INSERT INTO conversation_rows (id, title, created_at, updated_at, "
      "assistant_id) VALUES "
      "('c1', 'topic one', $convTs, $convTs, 'a1'), "
      "('c2', 'topic two', $convTs, $convTs, 'a2')",
    );
    final ts = DateTime(2026, 1, 3, 10).microsecondsSinceEpoch;
    await db.customStatement(
      "INSERT INTO message_rows (id, conversation_id, role, timestamp, "
      "message_order, model_id, provider_id, total_tokens) VALUES "
      "('m1', 'c1', 'user', $ts, 0, 'modelA', 'p1', 10), "
      "('m2', 'c1', 'assistant', $ts, 1, 'modelB', 'p1', 10), "
      "('m3', 'c2', 'user', $ts, 0, 'modelA', 'p2', 10), "
      "('m4', 'c2', 'assistant', $ts, 1, NULL, NULL, 10)",
    );
  }

  Future<ChatStatsAggregate> load({StatsFilter? filter}) =>
      repo.queryStatsAggregate(
        rangeStart: DateTime(2026, 1, 1),
        rangeEndExclusive: DateTime(2026, 2, 1),
        heatmapStart: DateTime(2025, 1, 1),
        trendStart: DateTime(2026, 1, 1),
        trendEndExclusive: DateTime(2026, 2, 1),
        filter: filter,
      );

  test('no filter sees everything', () async {
    await seed();
    final agg = await load();
    expect(agg.totals.messages, 4);
    expect(agg.conversations, 2);
    expect(agg.models.length, 2); // modelA, modelB
  });

  test('model filter is OR within the dimension', () async {
    await seed();
    final agg = await load(filter: const StatsFilter(modelIds: {'modelA'}));
    expect(agg.totals.messages, 2); // m1 + m3
    expect(agg.models.map((m) => m.id), ['modelA']);
  });

  test('assistant filter routes through conversations', () async {
    await seed();
    final agg = await load(filter: const StatsFilter(assistantIds: {'a2'}));
    expect(agg.totals.messages, 2); // m3 + m4
    expect(agg.assistants.map((a) => a.id), ['a2']);
    expect(agg.conversations, 1);
  });

  test('topic filter narrows to one conversation', () async {
    await seed();
    final agg = await load(filter: const StatsFilter(topicIds: {'c1'}));
    expect(agg.totals.messages, 2); // m1 + m2
    expect(agg.topics.length, 1);
    expect(agg.topics.single.id, 'c1');
  });

  test('dimensions combine with AND', () async {
    await seed();
    final agg = await load(
      filter: const StatsFilter(modelIds: {'modelA'}, topicIds: {'c2'}),
    );
    expect(agg.totals.messages, 1); // only m3
  });

  test('default-assistant sentinel matches blank assistant id', () async {
    await seed();
    final convTs = DateTime(2026, 1, 2).microsecondsSinceEpoch;
    await db.customStatement(
      "INSERT INTO conversation_rows (id, title, created_at, updated_at) "
      "VALUES ('c3', 'no assistant', $convTs, $convTs)",
    );
    final ts = DateTime(2026, 1, 3, 11).microsecondsSinceEpoch;
    await db.customStatement(
      "INSERT INTO message_rows (id, conversation_id, role, timestamp, "
      "message_order, total_tokens) VALUES ('m5', 'c3', 'user', $ts, 0, 5)",
    );
    final agg = await load(
      filter: const StatsFilter(assistantIds: {StatsFilter.defaultAssistantId}),
    );
    expect(agg.totals.messages, 1); // m5
    expect(agg.assistants.single.id, StatsFilter.defaultAssistantId);
  });

  test('empty filter sets mean no restriction', () async {
    await seed();
    final agg = await load(
      filter: const StatsFilter(modelIds: {}, assistantIds: {}, topicIds: {}),
    );
    expect(agg.totals.messages, 4);
  });
}
