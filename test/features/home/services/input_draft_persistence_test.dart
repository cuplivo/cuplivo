import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/models/message_quote.dart';
import 'package:Cuplivo/features/home/services/input_draft_persistence.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InputDraftPersistence persistence;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    persistence = InputDraftPersistence(null)..disposeInternal();
    persistence = InputDraftPersistence(await SharedPreferences.getInstance());
    addTearDown(persistence.disposeInternal);
  });

  test('round-trips text, images, documents and quote', () async {
    final prefs = await SharedPreferences.getInstance();
    const quote = MessageQuote(id: 'm1', start: 0, end: 5);
    final input = ChatInputData(
      text: 'hello draft',
      imagePaths: const ['data:image/png;base64,AAA'],
      documents: const [
        DocumentAttachment(
          path: '/tmp/a.pdf',
          fileName: 'a.pdf',
          mime: 'application/pdf',
        ),
      ],
      quote: quote,
      quoteSnippet: 'quoted text',
    );

    persistence.save(input);
    await Future<void>.delayed(
      InputDraftPersistence.debounceDuration + const Duration(milliseconds: 50),
    );
    expect(prefs.getString(InputDraftPersistence.key), isNotNull);

    // A fresh instance reads the persisted blob.
    final restored = InputDraftPersistence(prefs);
    final draft = restored.takeDraftForRestore();
    expect(draft, isNotNull);
    expect(draft!.text, 'hello draft');
    expect(draft.imagePaths, ['data:image/png;base64,AAA']);
    expect(draft.documents.single.fileName, 'a.pdf');
    expect(draft.quote!.id, 'm1');
    expect(draft.quoteSnippet, 'quoted text');
    restored.disposeInternal();
  });

  test('empty content removes the key', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(InputDraftPersistence.key, 'stale');
    persistence.save(const ChatInputData(text: '   '));
    await Future<void>.delayed(
      InputDraftPersistence.debounceDuration + const Duration(milliseconds: 50),
    );
    expect(prefs.getString(InputDraftPersistence.key), isNull);
  });

  test('clearNow drops pending and persisted state', () async {
    persistence.save(const ChatInputData(text: 'x'));
    persistence.clearNow();
    expect(persistence.takeDraftForRestore(), isNull);
  });

  test('corrupt blob is removed and degrades to null', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(InputDraftPersistence.key, '{not json');
    final restored = InputDraftPersistence(prefs);
    expect(restored.takeDraftForRestore(), isNull);
    expect(prefs.getString(InputDraftPersistence.key), isNull);
    restored.disposeInternal();
  });

  test('null prefs handle degrades to a no-op instance', () {
    final noop = InputDraftPersistence(null);
    noop.save(const ChatInputData(text: 'x'));
    noop.clearNow();
    expect(noop.takeDraftForRestore(), isNull);
    noop.disposeInternal();
  });
}
