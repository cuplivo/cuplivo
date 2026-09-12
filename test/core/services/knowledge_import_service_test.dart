import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/knowledge.dart';
import 'package:Cuplivo/core/services/knowledge/knowledge_import_service.dart';
import 'package:Cuplivo/core/services/knowledge/knowledge_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late KnowledgeStore store;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    store = KnowledgeStore(db, BusinessPreferences.memoryForTests());
    final now = DateTime(2026, 9, 10, 12);
    await store.upsertBase(
      KnowledgeBase(id: 'kb1', name: 'One', createdAt: now, updatedAt: now),
    );
    await store.upsertBase(
      KnowledgeBase(id: 'kb2', name: 'Two', createdAt: now, updatedAt: now),
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('extension mapping accepts documents and rejects the rest', () {
    expect(KnowledgeImportService.mimeForFileName('a.txt'), 'text/plain');
    expect(KnowledgeImportService.mimeForFileName('a.md'), 'text/markdown');
    expect(
      KnowledgeImportService.mimeForFileName('a.markdown'),
      'text/markdown',
    );
    expect(KnowledgeImportService.mimeForFileName('a.pdf'), 'application/pdf');
    expect(KnowledgeImportService.mimeForFileName('a.docx'), isNotNull);
    expect(KnowledgeImportService.mimeForFileName('a.PNG'), isNull);
    expect(KnowledgeImportService.mimeForFileName('noext'), isNull);
    expect(KnowledgeImportService.mimeForFileName('trailing.'), isNull);

    expect(KnowledgeImportService.sourceTypeForFileName('a.markdown'), 'md');
    expect(KnowledgeImportService.sourceTypeForFileName('a.txt'), 'txt');
  });

  test('imports extracted text with chunks and FTS rows', () async {
    final base = (await store.getBase('kb1'))!;
    final body = List.generate(
      20,
      (i) => 'paragraph $i keyword body',
    ).join('\n');
    var calls = 0;
    final service = KnowledgeImportService(
      store: store,
      extractor: ({required path, required mime}) async {
        calls++;
        expect(mime, 'text/plain');
        return body;
      },
    );

    final result = await service.importPath(
      base: base,
      path: '/tmp/a.txt',
      fileName: 'a.txt',
    );

    expect(result.status, KnowledgeImportStatus.imported);
    expect(result.chunkCount, greaterThan(0));
    expect(calls, 1);
    expect(await store.countDocuments('kb1'), 1);
    expect(await store.countChunks('kb1'), result.chunkCount);
    final document = (await store.getDocuments('kb1')).single;
    expect(document.name, 'a.txt');
    expect(document.sourceType, 'txt');
    expect(document.charCount, body.length);
    expect(document.chunkTotal, result.chunkCount);
  });

  test('same content is skipped as a duplicate within one base', () async {
    final base = (await store.getBase('kb1'))!;
    final service = KnowledgeImportService(
      store: store,
      extractor: ({required path, required mime}) async => 'identical body',
    );

    final first = await service.importPath(
      base: base,
      path: '/tmp/a.txt',
      fileName: 'a.txt',
    );
    final second = await service.importPath(
      base: base,
      path: '/tmp/b.txt',
      fileName: 'b.txt',
    );

    expect(first.status, KnowledgeImportStatus.imported);
    expect(second.status, KnowledgeImportStatus.duplicate);
    expect(await store.countDocuments('kb1'), 1);
  });

  test('the same content imports into a different base', () async {
    final service = KnowledgeImportService(
      store: store,
      extractor: ({required path, required mime}) async => 'shared body',
    );

    final one = await service.importPath(
      base: (await store.getBase('kb1'))!,
      path: '/tmp/a.txt',
      fileName: 'a.txt',
    );
    final two = await service.importPath(
      base: (await store.getBase('kb2'))!,
      path: '/tmp/a.txt',
      fileName: 'a.txt',
    );

    expect(one.status, KnowledgeImportStatus.imported);
    expect(two.status, KnowledgeImportStatus.imported);
    expect(await store.countDocuments('kb1'), 1);
    expect(await store.countDocuments('kb2'), 1);
  });

  test('extractor failure markers are rejected, not imported', () async {
    final base = (await store.getBase('kb1'))!;
    final service = KnowledgeImportService(
      store: store,
      extractor: ({required path, required mime}) async =>
          '[[Failed to read PDF: boom]]',
    );

    final result = await service.importPath(
      base: base,
      path: '/tmp/a.pdf',
      fileName: 'a.pdf',
    );

    expect(result.status, KnowledgeImportStatus.failed);
    expect(await store.countDocuments('kb1'), 0);
    expect(await store.countChunks('kb1'), 0);
  });

  test('empty extracted text is a failure, not a document', () async {
    final base = (await store.getBase('kb1'))!;
    final service = KnowledgeImportService(
      store: store,
      extractor: ({required path, required mime}) async => '   \n  ',
    );

    final result = await service.importPath(
      base: base,
      path: '/tmp/a.txt',
      fileName: 'a.txt',
    );

    expect(result.status, KnowledgeImportStatus.failed);
    expect(await store.countDocuments('kb1'), 0);
  });

  test('unsupported extensions never reach the extractor', () async {
    final base = (await store.getBase('kb1'))!;
    var calls = 0;
    final service = KnowledgeImportService(
      store: store,
      extractor: ({required path, required mime}) async {
        calls++;
        return 'body';
      },
    );

    final result = await service.importPath(
      base: base,
      path: '/tmp/image.png',
      fileName: 'image.png',
    );

    expect(result.status, KnowledgeImportStatus.unsupported);
    expect(calls, 0);
    expect(await store.countDocuments('kb1'), 0);
  });
}
