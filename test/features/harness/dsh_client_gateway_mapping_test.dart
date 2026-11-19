import 'package:Cuplivo/core/dsh/dsh_catalog.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_errors.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_events.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_models.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_transport.dart' as dsh;
import 'package:Cuplivo/features/harness/services/dsh_client_gateway_mapping.dart';
import 'package:Cuplivo/features/harness/state/dsh_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

dsh.DshSessionSummary _summary(
  String id, {
  String? title,
  bool running = false,
  String? cwd,
}) {
  return dsh.DshSessionSummary.fromJson({
    'sessionId': id,
    'updatedAt': 1700000000000,
    'running': running,
    'cwd': cwd,
    'projections': {
      'values': {if (title != null) 'title': title},
    },
  });
}

dsh.DshCatalogSnapshot _catalog() {
  final capabilities = dsh.DshCapabilities()
    ..record('session/list', true)
    ..record('workspace/follow', true)
    ..record('session/modelCatalog', true)
    ..record('permissionPresets/catalog', true)
    ..record('pluginInventory/list', true)
    ..record('settings/describe', false);
  return dsh.DshCatalogSnapshot(
    sessions: [
      _summary('s1', title: 'Pinned chat', running: true, cwd: '/repo'),
      _summary('s2', title: 'Loose chat'),
    ],
    workspaces: [
      dsh.DshWorkspace.fromJson({
        'workspaceId': 'w1',
        'path': '/repo',
        'title': 'Repo',
        'sessionIds': ['s1'],
      }),
    ],
    archivedSessionIds: const ['s2'],
    pinnedSessionIds: const ['s1'],
    models: dsh.DshModelCatalog.fromJson({
      'default': {'provider': 'deepseek', 'model': 'chat'},
      'groups': [
        {
          'id': 'deepseek',
          'name': 'DeepSeek',
          'models': [
            {
              'id': 'chat',
              'name': 'Chat',
              'reasoning': {
                'efforts': [
                  {'id': 'high', 'name': 'High'},
                ],
                'defaultEffort': 'high',
              },
            },
          ],
        },
      ],
      'failures': [
        {'id': 'broken', 'name': 'Broken', 'message': 'No credentials'},
      ],
    }),
    providers: const [],
    configurableProviders: const [],
    permissionPresets: dsh.DshPermissionPresetCatalog.fromJson({
      'options': [
        {'value': 'read-only', 'name': 'Read Only'},
      ],
      'defaultOptions': const [],
      'defaultPreset': 'read-only',
    }),
    plugins: dsh.DshPluginInventory.fromJson({
      'entries': [
        {
          'entryId': 'e1',
          'moduleName': 'm1',
          'enabled': true,
          'meta': {'title': 'Plugin One', 'description': 'Does things'},
        },
      ],
    }),
    settings: dsh.DshSettingsDescription.fromJson({
      'writable': true,
      'namespaces': [
        {
          'ns': 'session-log-deepseek',
          'revision': 3,
          'value': {'enabled': true},
        },
      ],
    }),
    capabilities: capabilities,
    loadedAt: DateTime.utc(2026, 1, 1),
  );
}

void main() {
  group('mapDshCatalog', () {
    test('joins sessions, presets, models, plugins and capabilities', () {
      final catalog = mapDshCatalog(_catalog());

      expect(catalog.generalSettings.defaultPermissionPresetId, 'read-only');
      expect(catalog.generalSettings.uploadSessionLog, isTrue);
      expect(catalog.permissionPresets.single.title, 'Read Only');
      expect(catalog.models.defaultSelection?.modelId, 'chat');
      expect(catalog.models.providers.first.models.single.title, 'Chat');
      expect(
        catalog.models.providers.first.models.single.defaultReasoningEffortId,
        'high',
      );
      expect(catalog.models.providers.last.failureMessage, 'No credentials');
      expect(catalog.workspaces.single.sessions.single.workspaceId, 'w1');
      expect(catalog.workspaces.single.sessions.single.running, isTrue);
      expect(catalog.workspaces.single.sessions.single.pinned, isTrue);
      expect(catalog.ungroupedSessions.single.id, 's2');
      expect(catalog.ungroupedSessions.single.archived, isTrue);
      expect(catalog.plugins.single.title, 'Plugin One');
      expect(catalog.capabilities.supports(DshCapability.modelCatalog), isTrue);
      expect(catalog.capabilities.supports(DshCapability.workspaces), isTrue);
      expect(
        catalog.capabilities.supports(DshCapability.sessionFiles),
        isFalse,
      );
      expect(catalog.capabilities.supports(DshCapability.approvals), isTrue);
      expect(
        catalog.failures.single.section,
        DshCatalogSection.generalSettings,
      );
      expect(catalog.failures.single.failure, DshFailure.unsupported);
      expect(catalog.commands, isEmpty);
      expect(catalog.skills, isEmpty);
    });
  });

  group('session roster mapping', () {
    test('maps command descriptors and skills', () {
      final command = mapDshCommand(
        dsh.DshCommandDescriptor.fromJson({
          'name': 'compact',
          'description': 'Compact the transcript',
        }),
      );
      expect(command.name, 'compact');
      expect(command.description, 'Compact the transcript');

      final skill = mapDshSkill(
        dsh.DshSkill.fromJson({
          'name': 'review',
          'description': 'Review a change',
        }),
      );
      expect(skill.id, 'review');
      expect(skill.title, 'review');
      expect(skill.description, 'Review a change');
    });
  });

  group('mapDshSessionControl', () {
    test('reads title, permissions, model and inbox count', () {
      final projections = dsh.DshSessionProjections.fromJson({
        'asOfSeq': 7,
        'values': {
          'title': 'Live title',
          'permissions': {'currentValue': 'workspace-write'},
          'modelSelection': {
            'next': {'provider': 'deepseek', 'model': 'chat'},
          },
          'inbox': {
            'next-turn': [
              {'id': 'a'},
              {'id': 'b'},
            ],
            'next-step': [
              {'id': 'c'},
            ],
          },
        },
      });
      final control = mapDshSessionControl(
        sessionId: 's1',
        projections: projections,
      );
      expect(control.title, 'Live title');
      expect(control.permissionPreset, 'workspace-write');
      expect(control.selectedModel?.modelId, 'chat');
      expect(control.queued, 3);
      expect(control.running, isFalse);

      final running = mapDshSessionControl(
        sessionId: 's1',
        projections: projections,
        running: true,
      );
      expect(running.running, isTrue);
    });

    test('falls back to the summary when there is no projection yet', () {
      final control = mapDshSessionControl(
        sessionId: 's1',
        summary: _summary('s1', title: 'Summary title', running: true),
      );
      expect(control.title, 'Summary title');
      expect(control.running, isTrue);
    });
  });

  group('mapDshWorkspaceUpdate', () {
    test('upserts a workspace with its joined sessions', () {
      final patch = mapDshWorkspaceUpdate(
        dsh.DshWorkspaceUpsertUpdate(
          dsh.DshWorkspace.fromJson({
            'workspaceId': 'w2',
            'path': '/other',
            'title': 'Other',
            'sessionIds': ['s1', 'missing'],
          }),
        ),
        summaries: {'s1': _summary('s1', title: 'One')},
        archivedIds: const {},
        pinnedIds: const {},
      );
      expect(patch, isA<DshWorkspaceUpsert>());
      final workspace = (patch as DshWorkspaceUpsert).workspace;
      expect(workspace.id, 'w2');
      expect(workspace.sessions.single.id, 's1');
      expect(workspace.sessions.single.workspaceId, 'w2');
    });

    test('removes and orders patches pass through', () {
      final removed = mapDshWorkspaceUpdate(
        const dsh.DshWorkspaceRemoveUpdate('w1'),
        summaries: const {},
        archivedIds: const {},
        pinnedIds: const {},
      );
      expect(removed, isA<DshWorkspaceRemoved>());
      expect((removed as DshWorkspaceRemoved).workspaceId, 'w1');

      final order = mapDshWorkspaceUpdate(
        const dsh.DshWorkspaceOrderUpdate(['w2', 'w1']),
        summaries: const {},
        archivedIds: const {},
        pinnedIds: const {},
      );
      expect(order, isA<DshWorkspaceOrder>());
      expect((order as DshWorkspaceOrder).workspaceIds, ['w2', 'w1']);
    });

    test('baselines invalidate instead of patching', () {
      final patch = mapDshWorkspaceUpdate(
        DshWorkspaceBaselineUpdate(
          dsh.DshWorkspaceBaseline.fromJson({
            'items': const [],
            'archivedSessionIds': const [],
            'pinnedSessionIds': const [],
          }),
        ),
        summaries: const {},
        archivedIds: const {},
        pinnedIds: const {},
      );
      expect(patch, isA<DshCatalogInvalidated>());
    });
  });

  group('host requests', () {
    test('maps an approval request', () {
      final approval = mapDshApproval(
        dsh.DshApprovalRequest.fromJson(
          eventId: 'evt-1',
          sessionId: 's1',
          request: {
            'toolName': 'bash',
            'reason': 'run tests',
            'callId': 'call-1',
            'displayReason': {'en': 'Allow bash?'},
          },
        ),
      );
      expect(approval.id, 'evt-1');
      expect(approval.title, 'Allow bash?');
      expect(approval.toolName, 'bash');
      expect(approval.toolCallId, 'call-1');
    });

    test('maps a question request and its answers', () {
      final request = mapDshQuestionRequest(
        dsh.DshUserQuestionRequest.fromJson(
          eventId: 'evt-2',
          sessionId: 's1',
          request: {
            'questions': [
              {
                'id': 'q1',
                'question': 'Which branch?',
                'header': 'Branch',
                'multiSelect': false,
                'options': [
                  {'label': 'main'},
                  {'label': 'dev'},
                ],
              },
            ],
          },
        ),
      );
      expect(request.id, 'evt-2');
      expect(request.title, 'Branch');
      expect(request.questions.single.options, ['main', 'dev']);

      final answers = mapDshQuestionAnswers(request, const [
        DshQuestionAnswer(questionId: 'q1', text: 'dev'),
      ]);
      expect(answers.single.id, 'q1');
      expect(answers.single.selected, ['dev']);
      expect(answers.single.custom, isNull);

      final freeText = mapDshQuestionAnswers(request, const [
        DshQuestionAnswer(questionId: 'q1', text: 'release/4.7'),
      ]);
      expect(freeText.single.selected, isEmpty);
      expect(freeText.single.custom, 'release/4.7');
    });
  });

  group('file mapping', () {
    test('joins child paths and reads type/size', () {
      final entry = mapWorkspaceFileEntry(const {
        'name': 'lib',
        'type': 'directory',
      }, '');
      expect(entry.path, 'lib');
      expect(entry.isDirectory, isTrue);

      final nested = mapWorkspaceFileEntry(const {
        'name': 'main.dart',
        'type': 'file',
        'size': 42,
      }, 'lib');
      expect(nested.name, 'main.dart');
      expect(nested.path, 'lib/main.dart');
      expect(nested.isDirectory, isFalse);
      expect(nested.size, 42);
    });

    test('wire paths use "." for the workspace root', () {
      expect(workspaceFilePathForWire(''), '.');
      expect(workspaceFilePathForWire('  '), '.');
      expect(workspaceFilePathForWire('lib'), 'lib');
    });
  });

  group('failures and link status', () {
    test('maps client exceptions to user-actionable failures', () {
      expect(
        dshFailureFromClient(const dsh.DshAuthException('no')),
        DshFailure.auth,
      );
      expect(
        dshFailureFromClient(const dsh.DshTransportException('down')),
        DshFailure.unreachable,
      );
      expect(
        dshFailureFromClient(const dsh.DshUnsupportedException('x/y')),
        DshFailure.unsupported,
      );
      expect(
        dshFailureFromClient(
          const dsh.DshRemoteException('gateway/internal', 'x'),
        ),
        DshFailure.unknown,
      );
      final wrapped = dshGatewayExceptionFromClient(
        const dsh.DshAuthException('rejected'),
      );
      expect(wrapped.failure, DshFailure.auth);
      expect(wrapped.detail, 'rejected');
    });

    test('maps connection states to link status', () {
      expect(
        dshLinkStatusFromClient(dsh.DshConnectionState.connected).isReady,
        isTrue,
      );
      expect(
        dshLinkStatusFromClient(
          dsh.DshConnectionState.reconnecting,
        ).isConnecting,
        isTrue,
      );
      final unauthorized = dshLinkStatusFromClient(
        dsh.DshConnectionState.unauthorized,
      );
      expect(unauthorized.isFailed, isTrue);
      expect(unauthorized.failure, DshFailure.auth);
      expect(
        dshLinkStatusFromClient(dsh.DshConnectionState.closed).isIdle,
        isTrue,
      );
    });
  });

  group('cookie codec', () {
    test('round-trips the persisted cookie JSON', () {
      const cookie = dsh.DshCookie(
        name: 'dsh-auth',
        value: 'secret-value',
        authority: '127.0.0.1:3080',
      );
      final encoded = encodeDshCookie(cookie);
      expect(encoded, isNot(contains('token')));
      final decoded = decodeDshCookie(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.name, 'dsh-auth');
      expect(decoded.value, 'secret-value');
      expect(decoded.authority, '127.0.0.1:3080');
    });

    test('a corrupt record means "no credential"', () {
      expect(decodeDshCookie('not json'), isNull);
      expect(decodeDshCookie('[]'), isNull);
      expect(decodeDshCookie('{"name":"x"}'), isNull);
      expect(decodeDshCookie(null), isNull);
    });
  });
}
