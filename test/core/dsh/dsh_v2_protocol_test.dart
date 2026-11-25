import 'dart:typed_data';

import 'package:Cuplivo/core/dsh/dsh_client.dart';
import 'package:Cuplivo/core/dsh/dsh_endpoint.dart';
import 'package:Cuplivo/core/dsh/dsh_errors.dart';
import 'package:Cuplivo/core/dsh/dsh_events.dart';
import 'package:Cuplivo/core/dsh/dsh_models.dart';
import 'package:Cuplivo/core/dsh/dsh_projection.dart';
import 'package:Cuplivo/core/dsh/dsh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dsh_fakes.dart';

const _base = 'http://127.0.0.1:3080/?token=t';

DshEndpoint _endpoint() => DshEndpoint.parse(_base);

DshClient _client(FakeDshTransport transport) =>
    DshClient(transport.endpoint, transport: transport);

FakeDshTransport _transport() => FakeDshTransport(endpoint: _endpoint());

void main() {
  group('contextPressure projection', () {
    test('parses the three numbers and the ratio', () {
      final projections = DshSessionProjections.fromJson({
        'asOfSeq': 5,
        'values': {
          'contextPressure': {
            'pressureTokens': 8930,
            'projectedTokens': 8943,
            'contextWindow': 1048576,
          },
        },
      });
      final pressure = projections.contextPressure!;
      expect(pressure.pressureTokens, 8930);
      expect(pressure.projectedTokens, 8943);
      expect(pressure.contextWindow, 1048576);
      expect(pressure.ratio, closeTo(8930 / 1048576, 1e-9));
      expect(pressure.isEmpty, isFalse);
    });

    test('is null when absent, empty or without a window', () {
      expect(
        DshSessionProjections.fromJson({
          'asOfSeq': 0,
          'values': {},
        }).contextPressure,
        isNull,
      );
      expect(
        DshSessionProjections.fromJson({
          'asOfSeq': 0,
          'values': {'contextPressure': <String, Object?>{}},
        }).contextPressure,
        isNull,
      );
      final partial = DshContextPressure.fromJson({'pressureTokens': 10});
      expect(partial.contextWindow, isNull);
      expect(partial.ratio, isNull);
    });

    test('DshTranscript forwards it from snapshot and control frames', () {
      final transcript = DshTranscript()
        ..applySnapshot(
          DshSessionSnapshot.fromJson({
            'header': {'version': 4, 'id': 's1', 'createdAt': 1},
            'cursor': 0,
            'records': const [],
            'hasMore': false,
            'projections': {
              'asOfSeq': 2,
              'values': {
                'contextPressure': {
                  'pressureTokens': 100,
                  'projectedTokens': 110,
                  'contextWindow': 1000,
                },
              },
            },
            'assistantStream': {'revision': 0},
          }),
        );
      expect(transcript.contextPressure!.pressureTokens, 100);
      expect(transcript.contextPressure!.projectedTokens, 110);
      expect(transcript.contextPressure!.contextWindow, 1000);

      transcript.applyProjection('contextPressure', {
        'pressureTokens': 200,
        'projectedTokens': 220,
        'contextWindow': 1000,
      }, 3);
      expect(transcript.contextPressure!.pressureTokens, 200);
      expect(transcript.contextPressure!.ratio, closeTo(0.2, 1e-9));
    });
  });

  group('workspace file bytes', () {
    test('fileUri carries the absolute path and version', () {
      final uri = _endpoint().fileUri('/tmp/a b.png', version: 'v1');
      expect(uri.path, '/api/file');
      expect(uri.queryParameters, {'path': '/tmp/a b.png', 'v': 'v1'});
    });

    test('statWorkspaceFile maps absolutePath, version and bytes', () async {
      final transport = _transport();
      transport.values['workspaceFiles/stat'] = {
        'absolutePath': '/workspace/demo/notes.txt',
        'version': 'v9',
        'bytes': 12,
      };
      final client = _client(transport);
      final stat = await client.statWorkspaceFile('session-1', 'notes.txt');
      expect(stat.absolutePath, '/workspace/demo/notes.txt');
      expect(stat.version, 'v9');
      expect(stat.bytes, 12);
      expect(stat.path, 'notes.txt');
      expect(stat.hasAbsolutePath, isTrue);
      final post = transport.posted.single;
      expect(post['endpoint'], 'workspaceFiles/stat');
      expect(post['payload'], {
        'args': {'workspaceFileScopeId': 'session-1', 'path': 'notes.txt'},
      });
    });

    test(
      'readFileBytes stats then follows the 302 and keeps raw bytes',
      () async {
        final transport = _transport();
        transport.values['workspaceFiles/stat'] = {
          'absolutePath': '/workspace/demo/image.png',
          'version': 'v1',
        };
        var gets = 0;
        transport.onGet = (uri) async {
          gets += 1;
          if (gets == 1) {
            return const DshHttpResponse(
              statusCode: 302,
              headers: {'location': '/api/file?path=%2Fcache&v=v1'},
              setCookie: [],
              body: '',
            );
          }
          return DshHttpResponse(
            statusCode: 200,
            headers: const {'content-type': 'image/png'},
            setCookie: const [],
            body: 'binary-body',
            bytes: Uint8List.fromList([0, 255, 1, 2]),
          );
        };
        final client = _client(transport);
        final bytes = await client.readFileBytes('session-1', 'image.png');
        expect(bytes, [0, 255, 1, 2]);
        expect(transport.getRequests, hasLength(2));
        expect(transport.getRequests.first.queryParameters, {
          'path': '/workspace/demo/image.png',
          'v': 'v1',
        });
        expect(transport.getRequests.last.path, '/api/file');
        expect(transport.getRequests.last.queryParameters['path'], '/cache');
      },
    );

    test('maps 401 to auth and 400/403 to file failures', () async {
      final transport = _transport();
      transport.values['workspaceFiles/stat'] = {
        'absolutePath': '/workspace/demo/dir',
      };
      final client = _client(transport);

      transport.onGet = (_) async => const DshHttpResponse(
        statusCode: 401,
        headers: {},
        setCookie: [],
        body: 'expired',
      );
      await expectLater(
        client.readFileBytes('session-1', 'dir'),
        throwsA(
          isA<DshAuthException>().having((e) => e.statusCode, 'status', 401),
        ),
      );

      transport.onGet = (_) async => const DshHttpResponse(
        statusCode: 403,
        headers: {},
        setCookie: [],
        body: 'directory',
      );
      await expectLater(
        client.readFileBytes('session-1', 'dir'),
        throwsA(
          isA<DshFileException>()
              .having((e) => e.statusCode, 'status', 403)
              .having((e) => e.isDirectoryOrForbidden, 'directory', isTrue),
        ),
      );

      transport.onGet = (_) async => const DshHttpResponse(
        statusCode: 400,
        headers: {},
        setCookie: [],
        body: 'relative',
      );
      await expectLater(
        client.readFileBytes('session-1', 'dir'),
        throwsA(
          isA<DshFileException>()
              .having((e) => e.statusCode, 'status', 400)
              .having((e) => e.isRelativePath, 'relative', isTrue),
        ),
      );
    });
  });

  group('agent presets', () {
    test('listAgentPresets parses id, order and isDefault', () async {
      final transport = _transport();
      transport.values['agentPresets/list'] = {
        'presets': [
          {'id': 'standard', 'order': 0, 'isDefault': true},
          {'id': 'planner', 'order': 2, 'isDefault': false},
        ],
      };
      final client = _client(transport);
      final presets = await client.catalog.listAgentPresets();
      expect(presets, hasLength(2));
      expect(presets.first.id, 'standard');
      expect(presets.first.order, 0);
      expect(presets.first.isDefault, isTrue);
      expect(presets.last.id, 'planner');
      expect(presets.last.order, 2);
      expect(presets.last.isDefault, isFalse);
    });

    test('plugin inventory already exposes agentPresets groups', () {
      final inventory = DshPluginInventory.fromJson({
        'entries': const [],
        'agentPresets': [
          {
            'id': 'planner',
            'name': 'Planner',
            'isDefault': true,
            'rows': [
              {'moduleName': 'dsh-plugin-a', 'enabled': true},
            ],
          },
        ],
      });
      expect(inventory.agentPresets, hasLength(1));
      expect(inventory.agentPresets.single.id, 'planner');
      expect(inventory.agentPresets.single.isDefault, isTrue);
      expect(
        inventory.agentPresets.single.rows.single.moduleName,
        'dsh-plugin-a',
      );
    });
  });
}
