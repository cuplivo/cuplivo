import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:Cuplivo/core/services/asr/sherpa_model_manager.dart';

void main() {
  group('SherpaModelCatalog', () {
    test('contains the three official downloadable model variants', () {
      expect(SherpaModelCatalog.models, hasLength(3));

      final paraformer = SherpaModelCatalog.byId(
        'paraformer-zh-small-2024-03-09',
      )!;
      expect(paraformer.downloadBytes, 77920048);
      expect(
        paraformer.archiveUri.toString(),
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
        'sherpa-onnx-paraformer-zh-small-2024-03-09.tar.bz2',
      );
      expect(paraformer.requiredFiles, ['model.int8.onnx', 'tokens.txt']);

      final senseVoice = SherpaModelCatalog.byId(
        'sense-voice-multilingual-int8-2025-09-09',
      )!;
      expect(senseVoice.downloadBytes, 165783878);
      expect(senseVoice.requiredFiles, ['model.int8.onnx', 'tokens.txt']);

      final zipformer = SherpaModelCatalog.byId(
        'zipformer-zh-en-mobile-2023-02-20',
      )!;
      expect(zipformer.downloadBytes, 346965352);
      expect(zipformer.requiredFiles, [
        'encoder-epoch-99-avg-1.int8.onnx',
        'decoder-epoch-99-avg-1.onnx',
        'joiner-epoch-99-avg-1.int8.onnx',
        'tokens.txt',
      ]);
      expect(
        SherpaModelCatalog.models.every(
          (model) =>
              model.archiveUri.host == 'github.com' &&
              model.archiveUri.path.contains('/k2-fsa/sherpa-onnx/'),
        ),
        isTrue,
      );
    });
  });

  group('SherpaModelDownloadProgress', () {
    test('exposes byte counts and a stable integer percentage', () {
      const progress = SherpaModelDownloadProgress(
        modelId: 'fixture-model',
        phase: SherpaModelDownloadPhase.downloading,
        receivedBytes: 579,
        totalBytes: 1000,
      );

      expect(progress.bytesReceived, 579);
      expect(progress.totalBytes, 1000);
      expect(progress.progress, 0.579);
      expect(progress.percent, 57);
      expect(progress.displayPercent, 57);
    });

    test('reports indeterminate totals and clamps out-of-range progress', () {
      const unknown = SherpaModelDownloadProgress(
        modelId: 'fixture-model',
        phase: SherpaModelDownloadPhase.downloading,
        receivedBytes: 50,
        totalBytes: null,
      );
      const overflow = SherpaModelDownloadProgress(
        modelId: 'fixture-model',
        phase: SherpaModelDownloadPhase.downloading,
        receivedBytes: 120,
        totalBytes: 100,
      );

      expect(unknown.progress, isNull);
      expect(unknown.percent, isNull);
      expect(overflow.progress, 1);
      expect(overflow.percent, 100);
    });
  });

  group('SherpaModelManager', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kelivo_asr_models_test_');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('reports, validates, and deletes installed model files', () async {
      final model = _fixtureModel();
      final manager = SherpaModelManager(modelsRoot: root, catalog: [model]);
      addTearDown(manager.dispose);

      expect(
        (await manager.statusFor(model.id)).state,
        SherpaModelInstallState.notInstalled,
      );

      final modelDirectory = await manager.modelDirectory(model.id);
      await modelDirectory.create(recursive: true);
      await File(
        p.join(modelDirectory.path, 'model.int8.onnx'),
      ).writeAsBytes([1]);
      expect(await manager.isInstalled(model.id), isFalse);
      expect(
        (await manager.statusFor(model.id)).state,
        SherpaModelInstallState.failed,
      );

      await File(
        p.join(modelDirectory.path, 'tokens.txt'),
      ).writeAsString('token');
      expect(await manager.isInstalled(model.id), isTrue);
      expect(
        (await manager.statusFor(model.id)).state,
        SherpaModelInstallState.installed,
      );

      await manager.delete(model.id);
      expect(await modelDirectory.exists(), isFalse);
      expect(
        (await manager.statusFor(model.id)).state,
        SherpaModelInstallState.notInstalled,
      );
    });

    test('streams, extracts, validates, and atomically installs', () async {
      final archive = _modelArchive(
        archiveRoot: 'fixture-package',
        files: {
          'model.int8.onnx': [1, 2, 3],
          'tokens.txt': [4, 5],
        },
      );
      final model = _fixtureModel(downloadBytes: archive.length);
      final client = MockClient(
        (_) async => http.Response.bytes(archive, HttpStatus.ok),
      );
      final manager = SherpaModelManager(
        httpClient: client,
        modelsRoot: root,
        catalog: [model],
      );
      addTearDown(manager.dispose);
      final progress = <SherpaModelDownloadProgress>[];

      final installed = await manager.download(
        model.id,
        onProgress: progress.add,
      );

      expect(await manager.isInstalled(model.id), isTrue);
      expect(await File(p.join(installed.path, 'tokens.txt')).readAsBytes(), [
        4,
        5,
      ]);
      expect(
        progress.map((event) => event.phase),
        containsAllInOrder([
          SherpaModelDownloadPhase.downloading,
          SherpaModelDownloadPhase.extracting,
          SherpaModelDownloadPhase.installing,
        ]),
      );
      expect(progress.last.fraction, 1);
      expect(await _temporaryArtifacts(root), isEmpty);
    });

    test(
      'prefers the response total and reports monotonic chunk progress',
      () async {
        final archive = _modelArchive(
          archiveRoot: 'fixture-package',
          files: {
            'model.int8.onnx': [1, 2, 3],
            'tokens.txt': [4, 5],
          },
        );
        final chunks = _splitBytes(archive, 4);
        final model = _fixtureModel(downloadBytes: archive.length * 2);
        final manager = SherpaModelManager(
          httpClient: _StreamingClient(
            (_) async => http.StreamedResponse(
              Stream<List<int>>.fromIterable(chunks),
              HttpStatus.ok,
              contentLength: archive.length,
            ),
          ),
          modelsRoot: root,
          catalog: [model],
        );
        addTearDown(manager.dispose);
        final events = <SherpaModelDownloadProgress>[];

        await manager.download(model.id, onProgress: events.add);

        final downloading = events
            .where(
              (event) => event.phase == SherpaModelDownloadPhase.downloading,
            )
            .toList();
        expect(downloading.first.totalBytes, model.downloadBytes);
        final responseEvents = downloading.skip(1).toList();
        expect(
          responseEvents.every((event) => event.totalBytes == archive.length),
          isTrue,
        );
        expect(responseEvents.map((event) => event.bytesReceived), [
          0,
          for (var index = 1; index <= chunks.length; index++)
            chunks.take(index).fold<int>(0, (sum, chunk) => sum + chunk.length),
        ]);
        expect(
          _isNonDecreasing(
            downloading.map((event) => event.progress!).toList(),
          ),
          isTrue,
        );
        expect(responseEvents.last.progress, 1);
        expect(responseEvents.last.percent, 100);
      },
    );

    test(
      'falls back to the catalog total when the response omits it',
      () async {
        final archive = _modelArchive(
          archiveRoot: 'fixture-package',
          files: {
            'model.int8.onnx': [1, 2, 3],
            'tokens.txt': [4, 5],
          },
        );
        final model = _fixtureModel(downloadBytes: archive.length);
        final manager = SherpaModelManager(
          httpClient: _StreamingClient(
            (_) async => http.StreamedResponse(
              Stream<List<int>>.fromIterable(_splitBytes(archive, 3)),
              HttpStatus.ok,
            ),
          ),
          modelsRoot: root,
          catalog: [model],
        );
        addTearDown(manager.dispose);
        final events = <SherpaModelDownloadProgress>[];

        await manager.download(model.id, onProgress: events.add);

        final downloading = events.where(
          (event) => event.phase == SherpaModelDownloadPhase.downloading,
        );
        expect(
          downloading.every((event) => event.totalBytes == archive.length),
          isTrue,
        );
        expect(downloading.last.progress, 1);
        expect(downloading.last.percent, 100);
      },
    );

    test(
      'rejects an incorrect response total without overflowing progress',
      () async {
        final archive = _modelArchive(
          archiveRoot: 'fixture-package',
          files: {
            'model.int8.onnx': [1, 2, 3],
            'tokens.txt': [4, 5],
          },
        );
        final model = _fixtureModel(downloadBytes: archive.length);
        var requestCount = 0;
        final manager = SherpaModelManager(
          httpClient: _StreamingClient((_) async {
            requestCount++;
            return http.StreamedResponse(
              Stream<List<int>>.fromIterable(_splitBytes(archive, 3)),
              HttpStatus.ok,
              contentLength: requestCount == 1
                  ? archive.length - 1
                  : archive.length,
            );
          }),
          modelsRoot: root,
          catalog: [model],
        );
        addTearDown(manager.dispose);
        final failedEvents = <SherpaModelDownloadProgress>[];

        await expectLater(
          manager.download(model.id, onProgress: failedEvents.add),
          throwsA(isA<HttpException>()),
        );

        expect(
          failedEvents
              .where(
                (event) => event.phase == SherpaModelDownloadPhase.downloading,
              )
              .every(
                (event) =>
                    event.progress == null ||
                    (event.progress! >= 0 && event.progress! <= 1),
              ),
          isTrue,
        );
        expect(
          (await manager.statusFor(model.id)).state,
          SherpaModelInstallState.failed,
        );
        expect(await _temporaryArtifacts(root), isEmpty);

        await manager.download(model.id);

        expect(requestCount, 2);
        expect(await manager.isInstalled(model.id), isTrue);
        expect(
          (await manager.statusFor(model.id)).state,
          SherpaModelInstallState.installed,
        );
      },
    );

    test(
      'keeps an unknown total indeterminate until the archive is complete',
      () async {
        final archive = _modelArchive(
          archiveRoot: 'fixture-package',
          files: {
            'model.int8.onnx': [1, 2, 3],
            'tokens.txt': [4, 5],
          },
        );
        final chunks = _splitBytes(archive, 3);
        final model = _fixtureModel(downloadBytes: 0);
        final manager = SherpaModelManager(
          httpClient: _StreamingClient(
            (_) async => http.StreamedResponse(
              Stream<List<int>>.fromIterable(chunks),
              HttpStatus.ok,
            ),
          ),
          modelsRoot: root,
          catalog: [model],
        );
        addTearDown(manager.dispose);
        final events = <SherpaModelDownloadProgress>[];

        await manager.download(model.id, onProgress: events.add);

        final downloading = events
            .where(
              (event) => event.phase == SherpaModelDownloadPhase.downloading,
            )
            .toList();
        expect(downloading.map((event) => event.bytesReceived), [
          0,
          0,
          chunks[0].length,
          chunks[0].length + chunks[1].length,
          archive.length,
        ]);
        expect(downloading.every((event) => event.totalBytes == null), isTrue);
        expect(downloading.every((event) => event.progress == null), isTrue);

        final completedPhases = events
            .where(
              (event) => event.phase != SherpaModelDownloadPhase.downloading,
            )
            .toList();
        expect(completedPhases.map((event) => event.phase), [
          SherpaModelDownloadPhase.extracting,
          SherpaModelDownloadPhase.installing,
        ]);
        expect(
          completedPhases.every(
            (event) =>
                event.bytesReceived == archive.length &&
                event.totalBytes == archive.length &&
                event.progress == 1 &&
                event.percent == 100,
          ),
          isTrue,
        );
      },
    );

    test('a partial cancellation cleans up and can be retried', () async {
      final archive = _modelArchive(
        archiveRoot: 'fixture-package',
        files: {
          'model.int8.onnx': [1],
          'tokens.txt': [2],
        },
      );
      final model = _fixtureModel(downloadBytes: archive.length);
      final token = SherpaDownloadCancellationToken();
      var requestCount = 0;
      final manager = SherpaModelManager(
        httpClient: _StreamingClient((_) async {
          requestCount++;
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable(_splitBytes(archive, 3)),
            HttpStatus.ok,
            contentLength: archive.length,
          );
        }),
        modelsRoot: root,
        catalog: [model],
      );
      addTearDown(manager.dispose);

      await expectLater(
        manager.download(
          model.id,
          cancellationToken: token,
          onProgress: (progress) {
            if (progress.phase == SherpaModelDownloadPhase.downloading &&
                progress.bytesReceived > 0) {
              token.cancel();
            }
          },
        ),
        throwsA(isA<SherpaDownloadCancelledException>()),
      );

      expect(await manager.isInstalled(model.id), isFalse);
      expect(await _temporaryArtifacts(root), isEmpty);
      expect(
        (await manager.statusFor(model.id)).state,
        SherpaModelInstallState.notInstalled,
      );

      await manager.download(model.id);

      expect(requestCount, 2);
      expect(await manager.isInstalled(model.id), isTrue);
      expect(
        (await manager.statusFor(model.id)).state,
        SherpaModelInstallState.installed,
      );
    });

    test(
      'cancelling extraction stops work, cleans up, and can retry',
      () async {
        final archive = _modelArchive(
          archiveRoot: 'fixture-package',
          files: {
            'model.int8.onnx': List<int>.filled(256 * 1024, 1),
            'tokens.txt': [2],
          },
        );
        final model = _fixtureModel(downloadBytes: archive.length);
        final token = SherpaDownloadCancellationToken();
        var requestCount = 0;
        final manager = SherpaModelManager(
          httpClient: MockClient((_) async {
            requestCount++;
            return http.Response.bytes(archive, HttpStatus.ok);
          }),
          modelsRoot: root,
          catalog: [model],
        );
        addTearDown(manager.dispose);

        await expectLater(
          manager.download(
            model.id,
            cancellationToken: token,
            onProgress: (progress) {
              if (progress.phase == SherpaModelDownloadPhase.extracting) {
                token.cancel();
              }
            },
          ),
          throwsA(isA<SherpaDownloadCancelledException>()),
        );

        expect(await manager.isInstalled(model.id), isFalse);
        expect(await _temporaryArtifacts(root), isEmpty);
        expect(
          (await manager.statusFor(model.id)).state,
          SherpaModelInstallState.notInstalled,
        );

        await manager.download(model.id);

        expect(requestCount, 2);
        expect(await manager.isInstalled(model.id), isTrue);
      },
    );

    test('rejects traversal entries and cleans failed staging', () async {
      final archive = _modelArchive(
        archiveRoot: 'fixture-package',
        files: {
          'model.int8.onnx': [1],
          'tokens.txt': [2],
          '../../escaped.txt': [3],
        },
      );
      final model = _fixtureModel(downloadBytes: archive.length);
      final manager = SherpaModelManager(
        httpClient: MockClient(
          (_) async => http.Response.bytes(archive, HttpStatus.ok),
        ),
        modelsRoot: root,
        catalog: [model],
      );
      addTearDown(manager.dispose);

      await expectLater(
        manager.download(model.id),
        throwsA(isA<FormatException>()),
      );

      expect(
        await File(p.join(root.parent.path, 'escaped.txt')).exists(),
        false,
      );
      expect(await manager.isInstalled(model.id), isFalse);
      expect(await _temporaryArtifacts(root), isEmpty);
      expect(
        (await manager.statusFor(model.id)).state,
        SherpaModelInstallState.failed,
      );
    });

    test('rejects archive files truncated during extraction', () async {
      final destination = Directory(p.join(root.path, 'truncated'));
      final archive = Archive()
        ..add(ArchiveFile.bytes('fixture/model.onnx', [1, 2, 3, 4]));
      final extracted = File(p.join(destination.path, 'fixture', 'model.onnx'));
      await extracted.parent.create(recursive: true);
      await extracted.writeAsBytes([1, 2]);

      expect(
        () => SherpaModelManager.verifyExtractedArchive(archive, destination),
        throwsA(isA<FileSystemException>()),
      );

      await extracted.writeAsBytes([1, 2, 3, 4]);
      expect(
        () => SherpaModelManager.verifyExtractedArchive(archive, destination),
        returnsNormally,
      );
    });

    test('rejects unsafe injected model identifiers', () async {
      final model = _fixtureModel(id: '../outside');
      final manager = SherpaModelManager(modelsRoot: root, catalog: [model]);
      addTearDown(manager.dispose);

      await expectLater(
        manager.modelDirectory(model.id),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

SherpaModelDefinition _fixtureModel({
  String id = 'fixture-model',
  int downloadBytes = 1,
}) {
  return SherpaModelDefinition(
    id: id,
    name: 'Fixture',
    description: 'Fixture',
    architecture: SherpaModelArchitecture.paraformer,
    archiveUri: Uri.parse('https://example.test/fixture.tar.bz2'),
    downloadBytes: downloadBytes,
    archiveRoot: 'fixture-package',
    requiredFiles: const ['model.int8.onnx', 'tokens.txt'],
    modelFile: 'model.int8.onnx',
  );
}

Uint8List _modelArchive({
  required String archiveRoot,
  required Map<String, List<int>> files,
}) {
  final archive = Archive()..add(ArchiveFile.directory('$archiveRoot/'));
  for (final entry in files.entries) {
    final name = entry.key.startsWith('../')
        ? entry.key
        : '$archiveRoot/${entry.key}';
    archive.add(ArchiveFile.bytes(name, entry.value));
  }
  return BZip2Encoder().encodeBytes(TarEncoder().encodeBytes(archive));
}

Future<List<FileSystemEntity>> _temporaryArtifacts(Directory root) async {
  if (!await root.exists()) return const [];
  return root
      .list(recursive: true, followLinks: false)
      .where(
        (entity) =>
            entity.path.endsWith('.part') ||
            p.basename(entity.path).startsWith('.staging-') ||
            p.basename(entity.path).startsWith('.previous-') ||
            entity.path.endsWith('.tar.bz2'),
      )
      .toList();
}

List<List<int>> _splitBytes(Uint8List bytes, int chunkCount) {
  final chunkSize = (bytes.length / chunkCount).ceil();
  return <List<int>>[
    for (var offset = 0; offset < bytes.length; offset += chunkSize)
      bytes.sublist(offset, (offset + chunkSize).clamp(0, bytes.length)),
  ];
}

bool _isNonDecreasing(List<double> values) {
  for (var index = 1; index < values.length; index++) {
    if (values[index] < values[index - 1]) return false;
  }
  return true;
}

final class _StreamingClient extends http.BaseClient {
  _StreamingClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _handler(request);
  }
}
