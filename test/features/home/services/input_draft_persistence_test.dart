import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/features/home/services/input_draft_persistence.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  InputDraftPersistence? service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() {
    service?.disposeInternal();
    service = null;
  });

  InputDraftPersistence buildService() {
    service = InputDraftPersistence(prefs);
    return service!;
  }

  String encodeDraft({
    String text = '',
    List<String> images = const [],
    List<Map<String, String>> documents = const [],
  }) {
    return jsonEncode({
      'text': text,
      'images': images,
      'documents': [
        for (final d in documents)
          {'path': d['path'], 'fileName': d['fileName'], 'mime': d['mime']},
      ],
    });
  }

  group('save / flush / clear', () {
    test(
      'save is debounced: nothing persisted before the debounce window',
      () async {
        final service = buildService();
        service.save(ChatInputData(text: 'hello', imagePaths: ['/tmp/a.png']));
        expect(prefs.getString(InputDraftPersistence.key), isNull);
        await Future<void>.delayed(
          InputDraftPersistence.debounceDuration +
              const Duration(milliseconds: 100),
        );
        final raw = prefs.getString(InputDraftPersistence.key);
        expect(raw, isNotNull);
        final decoded = jsonDecode(raw!) as Map<String, dynamic>;
        expect(decoded['text'], 'hello');
        expect(decoded['images'], ['/tmp/a.png']);
      },
    );

    test('empty content removes the persisted key instead of storing an '
        'empty blob', () async {
      prefs.setString(InputDraftPersistence.key, encodeDraft(text: 'old'));
      final service = buildService();
      service.save(ChatInputData(text: '   ', imagePaths: ['/tmp/gone.png']));
      service.clearNow();
      expect(prefs.getString(InputDraftPersistence.key), isNull);

      service.save(
        ChatInputData(
          text: 'x',
          imagePaths: ['/tmp/a.png'],
          documents: [
            DocumentAttachment(
              path: '/tmp/d.pdf',
              fileName: 'd.pdf',
              mime: 'application/pdf',
            ),
          ],
        ),
      );
      await Future<void>.delayed(
        InputDraftPersistence.debounceDuration +
            const Duration(milliseconds: 100),
      );
      final decoded =
          jsonDecode(prefs.getString(InputDraftPersistence.key)!)
              as Map<String, dynamic>;
      expect(decoded['documents'], [
        {'path': '/tmp/d.pdf', 'fileName': 'd.pdf', 'mime': 'application/pdf'},
      ]);
      // Whitespace-only text must clear again.
      service.save(ChatInputData(text: '   '));
      await Future<void>.delayed(
        InputDraftPersistence.debounceDuration +
            const Duration(milliseconds: 100),
      );
      expect(prefs.getString(InputDraftPersistence.key), isNull);
    });

    test('flushNow writes pending content immediately', () async {
      final service = buildService();
      service.save(ChatInputData(text: 'urgent'));
      service.flushNow();
      expect(
        (jsonDecode(prefs.getString(InputDraftPersistence.key)!)
            as Map<String, dynamic>)['text'],
        'urgent',
      );
    });

    test('clearNow cancels a pending debounce and removes the key', () async {
      final service = buildService();
      service.save(ChatInputData(text: 'doomed'));
      service.clearNow();
      expect(prefs.getString(InputDraftPersistence.key), isNull);
      await Future<void>.delayed(
        InputDraftPersistence.debounceDuration +
            const Duration(milliseconds: 100),
      );
      expect(prefs.getString(InputDraftPersistence.key), isNull);
    });

    test('app lifecycle flush writes pending content immediately', () async {
      final service = buildService();
      service.save(ChatInputData(text: 'lifecycle'));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(
        (jsonDecode(prefs.getString(InputDraftPersistence.key)!)
            as Map<String, dynamic>)['text'],
        'lifecycle',
      );
    });
  });

  group('preload / restore', () {
    test('degraded instance (null prefs) no-ops without crashing', () {
      final service = InputDraftPersistence(null);
      expect(service.takeDraftForRestore(), isNull);
      service.save(ChatInputData(text: 'x'));
      service.flushNow();
      service.clearNow();
      expect(service.draftReferencedFiles(), isEmpty);
    });

    test(
      'takeDraftForRestore returns the preloaded draft exactly once',
      () async {
        prefs.setString(
          InputDraftPersistence.key,
          encodeDraft(
            text: 'draft text',
            images: ['/tmp/a.png'],
            documents: [
              {
                'path': '/tmp/d.pdf',
                'fileName': 'd.pdf',
                'mime': 'application/pdf',
              },
            ],
          ),
        );
        final service = buildService();
        final first = service.takeDraftForRestore();
        expect(first?.text, 'draft text');
        expect(first?.imagePaths, ['/tmp/a.png']);
        expect(first?.documents.single.path, '/tmp/d.pdf');
        expect(service.takeDraftForRestore(), isNull);
      },
    );

    test('no persisted draft: takeDraftForRestore returns null', () async {
      final service = buildService();
      expect(service.takeDraftForRestore(), isNull);
    });

    test('corrupt draft is removed and never restored', () async {
      prefs.setString(InputDraftPersistence.key, '{not json!!');
      final service = buildService();
      expect(service.takeDraftForRestore(), isNull);
      expect(prefs.getString(InputDraftPersistence.key), isNull);
    });

    test('draft with wrong JSON shapes is decoded defensively', () async {
      prefs.setString(InputDraftPersistence.key, '{"text": 42}');
      final service = buildService();
      final draft = service.takeDraftForRestore();
      expect(draft?.text, '');
      expect(draft?.imagePaths, isEmpty);
    });
  });

  group('draftReferencedFiles', () {
    test('unions pending and persisted file references', () async {
      prefs.setString(
        InputDraftPersistence.key,
        encodeDraft(images: ['/persisted/a.png']),
      );
      final service = buildService();
      // Pending content (not yet flushed).
      service.save(
        ChatInputData(
          text: 'x',
          imagePaths: ['/pending/b.png'],
          documents: [
            DocumentAttachment(
              path: '/pending/c.pdf',
              fileName: 'c.pdf',
              mime: 'application/pdf',
            ),
          ],
        ),
      );
      expect(service.draftReferencedFiles(), {
        '/persisted/a.png',
        '/pending/b.png',
        '/pending/c.pdf',
      });
    });
  });
}
