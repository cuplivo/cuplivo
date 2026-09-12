import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/models/message_quote.dart';
import 'package:Cuplivo/core/models/quick_instruction.dart';
import 'package:Cuplivo/core/services/inbound_share.dart';
import 'package:Cuplivo/core/services/inbound_share_importer.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

void main() {
  group('InboundSharePayload.fromMap', () {
    test('parses text, images, files and stagingDir', () {
      final payload = InboundSharePayload.fromMap({
        'text': 'hello world',
        'images': ['/tmp/a.jpg', 42, ''],
        'files': [
          {
            'path': '/tmp/doc.pdf',
            'name': 'doc.pdf',
            'mime': 'application/pdf',
          },
          {'path': '', 'name': 'ghost', 'mime': 'x'},
          {'noPath': true},
        ],
        'stagingDir': '/tmp/inbox/uuid',
      });

      expect(payload, isNotNull);
      expect(payload!.text, 'hello world');
      expect(payload.imagePaths, ['/tmp/a.jpg']);
      expect(payload.files, hasLength(1));
      expect(payload.files.single.path, '/tmp/doc.pdf');
      expect(payload.files.single.mime, 'application/pdf');
      expect(payload.stagingDir, '/tmp/inbox/uuid');
      expect(payload.failedCount, 0);
    });

    test('parses the native failure count and rejects junk values', () {
      expect(
        InboundSharePayload.fromMap({'text': 'hi', 'failed': 2})!.failedCount,
        2,
      );
      expect(
        InboundSharePayload.fromMap({
          'text': 'hi',
          'failed': 'many',
        })!.failedCount,
        0,
      );
      expect(
        InboundSharePayload.fromMap({'text': 'hi', 'failed': -1})!.failedCount,
        0,
      );
    });

    test('derives a file name from the path when name is absent', () {
      final payload = InboundSharePayload.fromMap({
        'files': [
          {'path': '/tmp/report.pdf', 'mime': 'application/pdf'},
        ],
      });

      expect(payload!.files.single.name, 'report.pdf');
    });

    test('drops whitespace-only text', () {
      final payload = InboundSharePayload.fromMap({
        'text': '   ',
        'images': ['/tmp/a.png'],
      });

      expect(payload!.text, isNull);
    });

    test('returns null for empty, null and malformed payloads', () {
      expect(InboundSharePayload.fromMap(null), isNull);
      expect(InboundSharePayload.fromMap('nope'), isNull);
      expect(InboundSharePayload.fromMap(<String, Object?>{}), isNull);
      expect(InboundSharePayload.fromMap({'images': <Object?>[]}), isNull);
    });

    test('keeps an all-failed share so the error can be surfaced', () {
      final payload = InboundSharePayload.fromMap({'failed': 3});

      expect(payload, isNotNull);
      expect(payload!.isEmpty, isFalse);
      expect(payload.failedCount, 3);
    });
  });

  group('decideInboundShareLanding', () {
    test(
      'non-empty composer always merges, even on a pristine conversation',
      () {
        expect(
          decideInboundShareLanding(
            composerHasContent: true,
            conversationIsPristine: true,
          ),
          InboundShareLanding.mergeIntoCurrent,
        );
        expect(
          decideInboundShareLanding(
            composerHasContent: true,
            conversationIsPristine: false,
          ),
          InboundShareLanding.mergeIntoCurrent,
        );
      },
    );

    test('empty composer + pristine conversation populates in place', () {
      expect(
        decideInboundShareLanding(
          composerHasContent: false,
          conversationIsPristine: true,
        ),
        InboundShareLanding.populateCurrentDraft,
      );
    });

    test('empty composer + conversation with messages creates a new chat', () {
      expect(
        decideInboundShareLanding(
          composerHasContent: false,
          conversationIsPristine: false,
        ),
        InboundShareLanding.newConversation,
      );
    });
  });

  group('mergeInboundShareText', () {
    test('appends incoming text on a new line', () {
      expect(mergeInboundShareText('draft', 'shared'), 'draft\nshared');
    });

    test('returns incoming when existing is empty or whitespace', () {
      expect(mergeInboundShareText('', 'shared'), 'shared');
      expect(mergeInboundShareText('   ', 'shared'), 'shared');
    });

    test('returns existing when incoming is empty', () {
      expect(mergeInboundShareText('draft', null), 'draft');
      expect(mergeInboundShareText('draft', '   '), 'draft');
    });
  });

  group('mergeInboundShareIntoInput', () {
    test('keeps the draft and appends text and media', () {
      final merged = mergeInboundShareIntoInput(
        const ChatInputData(
          text: 'typed draft',
          imagePaths: ['/uploads/typed.png'],
          allowImagesApiRouting: false,
          extraBody: {'foo': 'bar'},
        ),
        const ChatInputData(
          text: 'shared text',
          imagePaths: ['/uploads/shared.png'],
          documents: [
            DocumentAttachment(
              path: '/uploads/shared.pdf',
              fileName: 'shared.pdf',
              mime: 'application/pdf',
            ),
          ],
        ),
      );

      expect(merged.text, 'typed draft\nshared text');
      expect(merged.imagePaths, ['/uploads/typed.png', '/uploads/shared.png']);
      expect(merged.documents.single.fileName, 'shared.pdf');
      expect(merged.allowImagesApiRouting, isFalse);
      expect(merged.extraBody, {'foo': 'bar'});
    });

    test('propagates an empty draft as-is', () {
      final merged = mergeInboundShareIntoInput(
        const ChatInputData(text: ''),
        const ChatInputData(text: 'shared text'),
      );

      expect(merged.text, 'shared text');
      expect(merged.imagePaths, isEmpty);
      expect(merged.documents, isEmpty);
    });
  });

  group('composerDraftHasContent', () {
    test('is false only for a fully empty draft', () {
      expect(composerDraftHasContent(const ChatInputData(text: '')), isFalse);
      expect(
        composerDraftHasContent(const ChatInputData(text: '   ')),
        isFalse,
      );
    });

    test('counts text, media, quote and quick instructions', () {
      expect(composerDraftHasContent(const ChatInputData(text: 'hi')), isTrue);
      expect(
        composerDraftHasContent(
          const ChatInputData(text: '', imagePaths: ['/uploads/a.png']),
        ),
        isTrue,
      );
      expect(
        composerDraftHasContent(
          const ChatInputData(
            text: '',
            documents: [
              DocumentAttachment(
                path: '/uploads/a.pdf',
                fileName: 'a.pdf',
                mime: 'application/pdf',
              ),
            ],
          ),
        ),
        isTrue,
      );
      expect(
        composerDraftHasContent(
          const ChatInputData(
            text: '',
            quote: MessageQuote(id: 'm1'),
          ),
        ),
        isTrue,
      );
      expect(
        composerDraftHasContent(
          ChatInputData(
            text: '',
            quickInstructions: [
              QuickInstructionInvocationSnapshot(
                instructionId: 'q1',
                title: 'Q',
                prompt: 'p',
                placement: QuickInstructionPlacement.beforeUserMessage,
                triggerMode: QuickInstructionTriggerMode.oneShot,
                retainInHistory: false,
                toolPolicy: QuickInstructionToolPolicy(),
                order: 0,
              ),
            ],
          ),
        ),
        isTrue,
      );
    });
  });

  group('InboundShareImporter.import', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('inbound_share_test_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    Future<File> writeStaged(String name, String content) async {
      final dir = Directory('${root.path}/share_inbox/uuid');
      await dir.create(recursive: true);
      final file = File('${dir.path}/$name');
      await file.writeAsString(content);
      return file;
    }

    test(
      'copies staged files into the upload dir and cleans staging',
      () async {
        final image = await writeStaged('photo.jpg', 'image-bytes');
        final doc = await writeStaged('report.pdf', 'pdf-bytes');

        final outcome = await InboundShareImporter.import(
          InboundSharePayload(
            text: 'look at this',
            imagePaths: [image.path],
            files: [
              InboundSharedFile(
                path: doc.path,
                name: 'report.pdf',
                mime: 'application/pdf',
              ),
            ],
            stagingDir: '${root.path}/share_inbox/uuid',
          ),
        );

        expect(outcome.failedCount, 0);
        expect(outcome.input.text, 'look at this');
        expect(outcome.input.imagePaths, hasLength(1));
        expect(File(outcome.input.imagePaths.single).existsSync(), isTrue);
        expect(outcome.input.documents.single.mime, 'application/pdf');
        expect(File(outcome.input.documents.single.path).existsSync(), isTrue);
        expect(
          Directory('${root.path}/share_inbox/uuid').existsSync(),
          isFalse,
        );
      },
    );

    test('dedupes a colliding file name instead of overwriting', () async {
      final upload = Directory('${root.path}/upload');
      await upload.create(recursive: true);
      File('${upload.path}/photo.jpg').writeAsStringSync('existing');

      final image = await writeStaged('photo.jpg', 'new-bytes');

      final outcome = await InboundShareImporter.import(
        InboundSharePayload(imagePaths: [image.path]),
      );

      expect(outcome.failedCount, 0);
      expect(outcome.input.imagePaths.single, endsWith('photo(1).jpg'));
      expect(File('${upload.path}/photo.jpg').readAsStringSync(), 'existing');
    });

    test('counts missing staged files as failures', () async {
      final outcome = await InboundShareImporter.import(
        InboundSharePayload(
          text: 'still lands',
          imagePaths: ['${root.path}/does-not-exist.jpg'],
        ),
      );

      expect(outcome.failedCount, 1);
      expect(outcome.input.imagePaths, isEmpty);
      expect(outcome.input.text, 'still lands');
    });

    test('folds native copy failures into the outcome count', () async {
      final image = await writeStaged('ok.jpg', 'bytes');

      final outcome = await InboundShareImporter.import(
        InboundSharePayload(
          text: 'partial',
          imagePaths: [image.path],
          failedCount: 2,
        ),
      );

      expect(outcome.failedCount, 2);
      expect(outcome.input.imagePaths, hasLength(1));
    });

    test('sanitizes a traversal file name into the upload dir', () async {
      final doc = await writeStaged('evil.txt', 'payload');

      final outcome = await InboundShareImporter.import(
        InboundSharePayload(
          files: [
            InboundSharedFile(
              path: doc.path,
              name: '../../escaped.txt',
              mime: 'text/plain',
            ),
          ],
        ),
      );

      expect(outcome.input.documents.single.fileName, 'escaped.txt');
      expect(File('${root.path}/escaped.txt').existsSync(), isFalse);
    });

    test('strips marker-hostile brackets from the file name', () async {
      final doc = await writeStaged('a]b.pdf', 'payload');

      final outcome = await InboundShareImporter.import(
        InboundSharePayload(
          files: [
            InboundSharedFile(
              path: doc.path,
              name: 'a]b[c.pdf',
              mime: 'application/pdf',
            ),
          ],
        ),
      );

      expect(outcome.input.documents.single.fileName, 'a_b_c.pdf');
    });

    test('refuses to delete an ancestor staging path', () async {
      final outcome = await InboundShareImporter.import(
        InboundSharePayload(text: 'hi', stagingDir: root.path),
      );

      expect(outcome.input.text, 'hi');
      expect(root.existsSync(), isTrue);
    });

    test('refuses to delete a directory outside share_inbox', () async {
      final other = Directory('${root.path}/other/uuid');
      await other.create(recursive: true);

      await InboundShareImporter.import(
        InboundSharePayload(text: 'hi', stagingDir: other.path),
      );

      expect(other.existsSync(), isTrue);
    });
  });
}
