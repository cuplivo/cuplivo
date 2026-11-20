import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/dsh/dsh_catalog.dart';
import 'package:Cuplivo/core/dsh/dsh_endpoint.dart';
import 'package:Cuplivo/core/dsh/dsh_events.dart';
import 'package:Cuplivo/core/dsh/dsh_errors.dart';
import 'package:Cuplivo/core/dsh/dsh_models.dart';
import 'package:Cuplivo/core/dsh/dsh_mux.dart';
import 'package:Cuplivo/core/dsh/dsh_rpc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dsh_fakes.dart';

Future<void> waitFor(bool Function() condition, {int tries = 100}) async {
  for (var i = 0; i < tries; i += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition not met in time');
}

Map<String, Object?> _catalogValues() =>
    (jsonDecode(
              File(
                'test/core/dsh/fixtures/catalog_values.json',
              ).readAsStringSync(),
            )
            as Map)
        .cast<String, Object?>();

void main() {
  late FakeDshTransport transport;
  late DshMux mux;
  late DshCatalog catalog;

  setUp(() async {
    final fixture = _catalogValues();
    transport = FakeDshTransport(
      endpoint: DshEndpoint.parse('http://127.0.0.1:3080/?token=t'),
    );
    fixture.forEach((key, value) {
      if (key == 'workspace/follow') {
        transport.streamOpening['workspace/follow'] = [value];
      } else {
        transport.values[key] = value;
      }
    });
    mux = DshMux(transport, options: const DshMuxOptions(retryDelay: _zero));
    catalog = DshCatalog(DshRpc(transport), mux);
    await mux.ready;
  });

  tearDown(() async {
    await mux.close();
  });

  test(
    'load() batches the whole first paint and tolerates optional endpoints',
    () async {
      final snapshot = await catalog.load();

      expect(snapshot.sessions, hasLength(2));
      expect(snapshot.sessions.first.title, 'Pong');
      expect(snapshot.sessions.first.nextModel!.model, 'deepseek-flash');
      expect(snapshot.sessions.first.usage!.outputTokens, 4);
      expect(snapshot.sessions.last.blank, isTrue);
      expect(snapshot.workspaces.single.path, '/workspace/demo');
      expect(snapshot.archivedSessionIds, isEmpty);
      expect(snapshot.pinnedSessionIds, [
        'session-7f3c2a9e-0000-4000-8000-000000000001',
      ]);
      expect(snapshot.models.defaultSelection!.model, 'deepseek-flash');
      expect(snapshot.providers, hasLength(2));
      expect(snapshot.configurableProviders.first.settingsNs, 'llm-deepseek');
      expect(snapshot.permissionPresets.defaultPreset, 'workspace-write');
      expect(snapshot.permissionPresets.option('read-only')!.name, 'read-only');
      expect(snapshot.agentPresets, hasLength(4));
      expect(snapshot.agentPresets.first.id, 'standard');
      expect(snapshot.agentPresets.first.isDefault, isTrue);
      expect(snapshot.agentPresets[2].name, 'Code review');
      expect(
        snapshot.agentPresets[2].description,
        'Prioritizes bugs and test gaps.',
      );
      expect(
        snapshot.agentPresets.last.broken,
        'Its plugin failed to activate.',
      );
      expect(snapshot.plugins.managementAvailable, isTrue);
      expect(snapshot.plugins.entries, hasLength(2));
      expect(snapshot.plugins.entries.last.title!.resolve('zh'), '插件管理');
      expect(
        snapshot.plugins.agentPresets.single.rows.last.conditional,
        isTrue,
      );
      expect(snapshot.settings.writable, isTrue);
      expect(snapshot.settings.namespace('permission')!.revision, 3);
      expect(
        snapshot.settings.namespace('permission')!.secrets.single.set,
        isFalse,
      );
      expect(snapshot.account!.signedOut, isTrue);
      expect(snapshot.capabilities.supports('session/list'), isTrue);
      expect(snapshot.capabilities.supports('workspace/follow'), isTrue);
      expect(snapshot.capabilities.lookup('session/list'), isTrue);
      expect(snapshot.loadedAt.isUtc, isTrue);
    },
  );

  test(
    'an absent optional endpoint degrades to empty + capability false',
    () async {
      transport.values.remove('pluginInventory/list');
      transport.values.remove('settings/describe');
      transport.values.remove('agentPresets/list');
      final snapshot = await catalog.load();
      expect(snapshot.agentPresets, isEmpty);
      expect(snapshot.capabilities.supports('agentPresets/list'), isFalse);
      expect(snapshot.plugins.entries, isEmpty);
      expect(snapshot.settings.writable, isFalse);
      expect(snapshot.capabilities.supports('pluginInventory/list'), isFalse);
      expect(snapshot.capabilities.lookup('pluginInventory/list'), isFalse);
      expect(snapshot.sessions, hasLength(2));
    },
  );

  test('a missing required session/list fails the load', () async {
    transport.values.remove('session/list');
    await expectLater(catalog.load(), throwsA(isA<DshUnsupportedException>()));
    expect(catalog.capabilities.lookup('session/list'), isFalse);
  });

  test('supports() probes once and caches the answer', () async {
    expect(await catalog.supports('future/endpoint'), isFalse);
    final probes = transport.posted.map((post) => post['endpoint']).toList();
    expect(probes, ['future/endpoint']);
    expect(await catalog.supports('future/endpoint'), isFalse);
    expect(transport.posted, hasLength(1));

    transport.values['another/endpoint'] = const {};
    expect(await catalog.supports('another/endpoint'), isTrue);
    expect(catalog.capabilities.supports('another/endpoint'), isTrue);
  });

  test(
    'createSession rejects cwd+workspaceId and sends the request shape',
    () async {
      transport.values['session/create'] = {
        'sessionId': 'session-new',
        'agentPreset': 'standard',
      };
      expect(
        () => catalog.createSession(cwd: '/x', workspaceId: 'w1'),
        throwsArgumentError,
      );
      final created = await catalog.createSession(workspaceId: 'w1');
      expect(created.sessionId, 'session-new');
      expect(transport.posted.single['payload'], {
        'args': {
          'request': {'workspaceId': 'w1'},
        },
      });
    },
  );

  test(
    'agentPresets/list keeps host order and select sends the roster value',
    () async {
      transport.values['agentPresets/list'] = {
        'presets': [
          {'id': 'ptc', 'order': 2, 'isDefault': false},
          {'id': 'standard', 'order': 1, 'isDefault': true},
        ],
      };
      final roster = await catalog.listAgentPresets();
      expect(roster.map((preset) => preset.id), ['standard', 'ptc']);
      expect(roster.first.isDefault, isTrue);

      transport.values['agentPresets/select'] = 'ptc';
      final committed = await catalog.selectAgentPreset('s1', 'ptc');
      expect(committed, 'ptc');
      expect(transport.posted.last['payload'], {
        'args': {'agentId': 's1', 'agentPreset': 'ptc'},
      });
    },
  );

  test('session reads use the documented request envelopes', () async {
    transport.values['session/state'] = {
      'cursor': 4,
      'active': true,
      'running': false,
      'queue': [
        {
          'id': 'i1',
          'placement': 'next-turn',
          'content': [
            {'type': 'text', 'text': 'queued'},
          ],
        },
      ],
      'pendingInput': [],
    };
    final state = await catalog.sessionState('s1');
    expect(state.cursor, 4);
    expect(state.active, isTrue);
    expect(state.queue.single.text, 'queued');
    expect(transport.posted.last['payload'], {
      'args': {
        'request': {'sessionId': 's1'},
      },
    });

    transport.values['session/projections'] = {
      'kind': 'sequenced',
      'asOfSeq': 9,
      'values': {
        'title': 'T',
        'permissions': {'currentValue': 'read-only'},
      },
    };
    final projections = await catalog.sessionProjections('s1');
    expect(projections!.title, 'T');
    expect(projections.permissionsCurrent, 'read-only');
  });

  test('workspace follow baseline is loadable without a unary list', () async {
    final baseline = await catalog.loadWorkspaces();
    expect(baseline.items.single.title, 'Demo');
    expect(baseline.pinnedSessionIds, hasLength(1));
    final open = transport.sockets.single.sent.cast<Map?>().firstWhere(
      (frame) => frame != null && frame['endpoint'] == 'workspace/follow',
    )!;
    expect(open['payload'], {'args': <String, Object?>{}});
  });

  test('watchWorkspaces emits the baseline and increments', () async {
    final updates = <DshWorkspaceUpdate>[];
    final sub = catalog.watchWorkspaces().listen(updates.add);
    await waitFor(() => updates.isNotEmpty);
    expect(updates.first, isA<DshWorkspaceBaselineUpdate>());

    final socket = transport.sockets.single;
    final open = socket.sent.cast<Map?>().firstWhere(
      (frame) => frame != null && frame['endpoint'] == 'workspace/follow',
    )!;
    socket.pushItem('${open['streamId']}', {
      'type': 'upsert',
      'workspace': {
        'workspaceId': 'w2',
        'path': '/workspace/other',
        'title': 'Other',
        'sessionIds': [],
      },
    });
    await waitFor(() => updates.length == 2);
    expect(updates.last, isA<DshWorkspaceUpsertUpdate>());
    expect((updates.last as DshWorkspaceUpsertUpdate).workspace.title, 'Other');
    await sub.cancel();
  });

  test(
    'watchSessionControl parses the baseline and replacement frames',
    () async {
      transport.streamOpening['session/control'] = [
        {
          'type': 'baseline',
          'value': {
            'projections': {
              's1': {
                'asOfSeq': 3,
                'values': {
                  'permissions': {'currentValue': 'read-only'},
                },
              },
            },
          },
        },
        {
          'type': 'projection',
          'sessionId': 's1',
          'seq': 4,
          'changes': [
            {
              'key': 'permissions',
              'val': {'currentValue': 'workspace-write'},
            },
          ],
        },
      ];
      final updates = <DshSessionControlUpdate>[];
      final sub = catalog.watchSessionControl().listen(updates.add);
      await waitFor(() => updates.length == 2);
      final baseline = updates.first as DshSessionControlBaseline;
      expect(baseline.projections['s1']!.permissionsCurrent, 'read-only');
      final projection = updates.last as DshSessionControlProjection;
      expect(projection.sessionId, 's1');
      expect(projection.key, 'permissions');
      expect(projection.seq, 4);
      expect(projection.value, {'currentValue': 'workspace-write'});
      await sub.cancel();
    },
  );

  test('settings conveniences write the documented mutations', () async {
    transport.values['settings/mutate'] = {
      'ns': 'permission',
      'revision': 4,
      'value': {'defaultPreset': 'read-only'},
      'secrets': [],
    };
    await catalog.setDefaultPermissionPreset('read-only');
    final mutate = transport.posted.last;
    expect(mutate['endpoint'], 'settings/mutate');
    expect(mutate['payload'], {
      'args': {
        'ns': 'permission',
        'ops': [
          {
            'op': 'set',
            'path': ['defaultPreset'],
            'value': 'read-only',
          },
        ],
        'expectedRevision': 3,
      },
    });

    transport.values['settings/update'] = {
      'ns': 'session-log-deepseek',
      'revision': 1,
      'value': {'enabled': false},
      'secrets': [],
    };
    await catalog.setSessionLogUpload(false);
    expect(transport.posted.last['payload'], {
      'args': {
        'ns': 'session-log-deepseek',
        'patch': {'enabled': false},
        'expectedRevision': 0,
      },
    });
  });

  test('model selection sends request with provider/model/effort', () async {
    transport.values['session/selectModel'] = {
      'selected': {
        'provider': 'deepseek-official',
        'model': 'deepseek-pro',
        'reasoningEffort': 'high',
      },
    };
    final selected = await catalog.selectModel(
      's1',
      const DshModelSelection(
        provider: 'deepseek-official',
        model: 'deepseek-pro',
        reasoningEffort: 'high',
      ),
    );
    expect(selected.model, 'deepseek-pro');
    expect(transport.posted.last['payload'], {
      'args': {
        'request': {
          'sessionId': 's1',
          'provider': 'deepseek-official',
          'model': 'deepseek-pro',
          'reasoningEffort': 'high',
        },
      },
    });
  });
}

Duration _zero(int attempt) => Duration.zero;
