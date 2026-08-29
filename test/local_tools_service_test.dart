import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/features/home/services/local_tools_service.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Assistant local tools', () {
    final localToolsAssistant = Assistant(
      id: 'a1',
      name: 'Assistant',
      localToolIds: [
        LocalToolNames.timeInfo,
        LocalToolNames.clipboard,
        LocalToolNames.textToSpeech,
        LocalToolNames.askUser,
      ],
    );

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    test('assistant defaults to no local tools', () {
      final assistant = Assistant(id: 'a1', name: 'Assistant');

      expect(assistant.localToolIds, isEmpty);
    });

    test('assistant defaults to web search disabled', () {
      final assistant = Assistant(id: 'a1', name: 'Assistant');

      expect(assistant.searchEnabled, isFalse);
    });

    test('assistant json keeps missing local tools disabled', () {
      final assistant = Assistant.fromJson(const {
        'id': 'a1',
        'name': 'Assistant',
      });

      expect(assistant.localToolIds, isEmpty);
    });

    test('assistant json keeps missing web search disabled', () {
      final assistant = Assistant.fromJson(const {
        'id': 'a1',
        'name': 'Assistant',
      });

      expect(assistant.searchEnabled, isFalse);
    });

    test('assistant json round trips enabled web search', () {
      final assistant = Assistant(
        id: 'a1',
        name: 'Assistant',
        searchEnabled: true,
      );

      final decoded = Assistant.fromJson(assistant.toJson());

      expect(decoded.searchEnabled, isTrue);
    });

    test('assistant json round trips enabled local tools', () {
      final assistant = Assistant(
        id: 'a1',
        name: 'Assistant',
        localToolIds: [LocalToolNames.timeInfo, LocalToolNames.clipboard],
      );

      final decoded = Assistant.fromJson(assistant.toJson());

      expect(decoded.localToolIds, const [
        LocalToolNames.timeInfo,
        LocalToolNames.clipboard,
      ]);
    });

    test(
      'builds enabled local tool definitions only when model supports tools',
      () {
        final disabled = LocalToolsService.buildToolDefinitions(
          assistant: Assistant(id: 'a2', name: 'Assistant'),
          supportsTools: true,
        );
        final unsupported = LocalToolsService.buildToolDefinitions(
          assistant: localToolsAssistant,
          supportsTools: false,
        );
        final enabled = LocalToolsService.buildToolDefinitions(
          assistant: localToolsAssistant,
          supportsTools: true,
        );

        expect(disabled, isEmpty);
        expect(unsupported, isEmpty);
        expect(enabled.map((tool) => tool['function']['name']), const [
          LocalToolNames.timeInfo,
          LocalToolNames.clipboard,
          LocalToolNames.textToSpeech,
          LocalToolNames.askUser,
        ]);
        expect(enabled.first['function']['parameters']['properties'], isEmpty);
        expect(
          enabled[1]['function']['parameters']['properties']['action']['enum'],
          const ['read', 'write'],
        );
        final ttsParameters = enabled[2]['function']['parameters'];
        expect(ttsParameters['required'], const ['text']);
        expect(ttsParameters['properties']['text']['type'], 'string');
        final askUserParameters = enabled[3]['function']['parameters'];
        expect(askUserParameters['required'], const ['questions']);
        final questionSchema =
            askUserParameters['properties']['questions']['items'];
        expect(questionSchema['required'], const ['id', 'question']);
        expect(questionSchema['properties']['type']['enum'], const [
          'single',
          'multi',
        ]);
        expect(
          questionSchema['properties']['options']['items']['type'],
          'string',
        );
      },
    );

    test('builds handoff definitions only when enabled and lists targets', () {
      final handoffAssistant = Assistant(
        id: 'a1',
        name: 'Assistant',
        localToolIds: [LocalToolNames.handoff, LocalToolNames.handoffSync],
      );
      final targets = [
        Assistant(
          id: 'target-1',
          name: 'Research Bot',
          discoverable: true,
          handoffId: 'research-bot',
          handoffDescription: 'researches topics',
        ),
        Assistant(id: 'target-2', name: 'Code Helper', discoverable: true),
      ];

      final noTargets = LocalToolsService.buildToolDefinitions(
        assistant: handoffAssistant,
        supportsTools: true,
      );
      final withTargets = LocalToolsService.buildToolDefinitions(
        assistant: handoffAssistant,
        supportsTools: true,
        discoverableAssistants: targets,
      );

      expect(noTargets.map((tool) => tool['function']['name']), const [
        LocalToolNames.handoff,
      ]);
      expect(
        (noTargets.first['function']['description'] as String),
        contains('No assistants are currently available'),
      );
      expect(withTargets.map((tool) => tool['function']['name']), const [
        LocalToolNames.handoff,
      ]);
      for (final tool in withTargets) {
        final fn = tool['function'] as Map<String, dynamic>;
        final params = fn['parameters'] as Map<String, dynamic>;
        expect(params['required'], const ['assistant', 'task']);
        final props = params['properties'] as Map<String, dynamic>;
        expect(props['assistant']['type'], 'string');
        expect(props['task']['type'], 'string');
      }
      final handoffDesc =
          withTargets.first['function']['description'] as String;
      expect(handoffDesc, contains('research-bot'));
      expect(handoffDesc, contains('WAIT for it to finish'));
    });

    test('single wait-mode tool regardless of legacy handoff ids', () {
      final onlyHandoff = LocalToolsService.buildToolDefinitions(
        assistant: Assistant(
          id: 'a1',
          name: 'Assistant',
          localToolIds: [LocalToolNames.handoff],
        ),
        supportsTools: true,
        discoverableAssistants: const [],
      );
      expect(onlyHandoff.map((tool) => tool['function']['name']), const [
        LocalToolNames.handoff,
      ]);
      expect(
        (onlyHandoff.first['function']['description'] as String),
        contains('No assistants are currently available'),
      );
      expect(
        (onlyHandoff.first['function']['description'] as String),
        contains('WAIT for it to finish'),
      );

      // A legacy sync-id list normalizes onto the single wait-mode tool
      // (ADR-0045) — the definition comes out identical.
      final onlySync = LocalToolsService.buildToolDefinitions(
        assistant: Assistant(
          id: 'a1',
          name: 'Assistant',
          localToolIds: [LocalToolNames.handoffSync],
        ),
        supportsTools: true,
        discoverableAssistants: const [],
      );
      expect(onlySync.map((tool) => tool['function']['name']), const [
        LocalToolNames.handoff,
      ]);
      expect(
        (onlySync.first['function']['description'] as String),
        contains('WAIT for it to finish'),
      );
    });

    test('assistant localToolIds normalize legacy sync id onto handoff', () {
      final assistant = Assistant(
        id: 'a1',
        name: 'Assistant',
        localToolIds: [
          LocalToolNames.handoffSync,
          LocalToolNames.timeInfo,
          LocalToolNames.handoff,
        ],
      );
      expect(assistant.localToolIds, const [
        LocalToolNames.timeInfo,
        LocalToolNames.handoff,
      ]);

      final decoded = Assistant.fromJson(assistant.toJson());
      expect(decoded.localToolIds, const [
        LocalToolNames.timeInfo,
        LocalToolNames.handoff,
      ]);
    });

    test('handoffTargets filters discoverable, non-empty ids and self', () {
      final delegating = Assistant(
        id: 'delegator',
        name: 'Delegator',
        localToolIds: [LocalToolNames.handoff],
      );
      final targets = LocalToolsService.handoffTargets([
        delegating,
        Assistant(id: 'plain', name: 'Plain'),
        Assistant(
          id: 'visible',
          name: 'Visible',
          discoverable: true,
          handoffId: 'visible-bot',
        ),
        Assistant(id: 'empty-id', name: 'Empty', discoverable: true),
      ], excludeId: 'delegator');
      expect(targets.map((t) => t.id), const ['visible']);
    });

    test('handoff target lists exclude the delegating assistant itself', () {
      final delegating = Assistant(
        id: 'delegator',
        name: 'Delegator',
        discoverable: true,
        handoffId: 'delegator',
        localToolIds: [LocalToolNames.handoff],
      );
      final defs = LocalToolsService.buildToolDefinitions(
        assistant: delegating,
        supportsTools: true,
        discoverableAssistants: [
          delegating,
          Assistant(
            id: 'other',
            name: 'Other',
            discoverable: true,
            handoffId: 'other-bot',
          ),
        ],
      );
      final desc = defs.first['function']['description'] as String;
      expect(desc, contains('other-bot'));
      expect(desc, isNot(contains('delegator')));
    });

    test('text to speech call starts playback and returns success', () async {
      final spokenTexts = <String>[];

      final result = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.textToSpeech,
        const {'text': 'Read this aloud.'},
        localToolsAssistant,
        onSpeakText: (text) async {
          spokenTexts.add(text);
        },
      );

      expect(spokenTexts, const ['Read this aloud.']);
      expect(result, isNotNull);
      expect(jsonDecode(result!) as Map<String, dynamic>, {'success': true});
    });

    test('text to speech requires non-empty text', () async {
      expect(
        () => LocalToolsService.tryHandleToolCall(
          LocalToolNames.textToSpeech,
          const {},
          localToolsAssistant,
          onSpeakText: (_) async {},
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => LocalToolsService.tryHandleToolCall(
          LocalToolNames.textToSpeech,
          const {'text': '   '},
          localToolsAssistant,
          onSpeakText: (_) async {},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'time info call returns local date, weekday, time, timezone fields',
      () async {
        final result = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.timeInfo,
          const {},
          localToolsAssistant,
        );

        expect(result, isNotNull);
        final payload = jsonDecode(result!) as Map<String, dynamic>;
        expect(payload['year'], isA<int>());
        expect(payload['month'], isA<int>());
        expect(payload['day'], isA<int>());
        expect(payload['weekday'], isA<String>());
        expect(payload['weekday_en'], isA<String>());
        expect(payload['weekday_index'], inInclusiveRange(1, 7));
        expect(payload['date'], isA<String>());
        expect(payload['time'], isA<String>());
        expect(payload['datetime'], isA<String>());
        expect(payload['timezone'], isA<String>());
        expect(payload['utc_offset'], isA<String>());
        expect(payload['timestamp_ms'], isA<int>());
      },
    );

    test(
      'clipboard read returns plain text from the device clipboard',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.getData') {
                return const <String, dynamic>{'text': 'clipboard text'};
              }
              fail('Unexpected platform call: ${call.method}');
            });

        final result = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.clipboard,
          const {'action': 'read'},
          localToolsAssistant,
        );

        expect(result, isNotNull);
        expect(jsonDecode(result!) as Map<String, dynamic>, {
          'text': 'clipboard text',
        });
      },
    );

    test('clipboard write updates the device clipboard', () async {
      String? writtenText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              writtenText =
                  (call.arguments as Map<Object?, Object?>)['text'] as String?;
              return null;
            }
            fail('Unexpected platform call: ${call.method}');
          });

      final result = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.clipboard,
        const {'action': 'write', 'text': 'next clipboard'},
        localToolsAssistant,
      );

      expect(writtenText, 'next clipboard');
      expect(result, isNotNull);
      expect(jsonDecode(result!) as Map<String, dynamic>, {
        'success': true,
        'text': 'next clipboard',
      });
    });

    test('clipboard write requires text', () async {
      expect(
        () => LocalToolsService.tryHandleToolCall(
          LocalToolNames.clipboard,
          const {'action': 'write'},
          localToolsAssistant,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('disabled or unknown local tool calls are not handled', () async {
      expect(
        await LocalToolsService.tryHandleToolCall(
          LocalToolNames.timeInfo,
          const {},
          Assistant(id: 'a1', name: 'Assistant'),
        ),
        isNull,
      );
      expect(
        await LocalToolsService.tryHandleToolCall(
          'unknown_local_tool',
          const {},
          localToolsAssistant,
        ),
        isNull,
      );
    });
  });

  group('Skill download/create tools', () {
    final skillToolsAssistant = Assistant(
      id: 'a2',
      name: 'Assistant',
      localToolIds: [LocalToolNames.downloadSkill, LocalToolNames.createSkill],
    );
    late Directory root;

    setUpAll(() async {
      root = await Directory.systemTemp.createTemp('skill_tools_test_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    });

    tearDownAll(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    test(
      'builds download/create definitions only when their switches are on',
      () {
        final enabled = LocalToolsService.buildToolDefinitions(
          assistant: skillToolsAssistant,
          supportsTools: true,
        );
        final disabled = LocalToolsService.buildToolDefinitions(
          assistant: Assistant(
            id: 'a3',
            name: 'Assistant',
            skillIds: ['alpha'],
          ),
          supportsTools: true,
        );

        final names = enabled.map((tool) => tool['function']['name']).toSet();
        expect(
          names,
          containsAll([
            LocalToolNames.downloadSkill,
            LocalToolNames.createSkill,
          ]),
        );

        final downloadDef = enabled.firstWhere(
          (t) => t['function']['name'] == LocalToolNames.downloadSkill,
        );
        expect(
          (downloadDef['function']['parameters'] as Map)['required'],
          const ['url'],
        );
        final createDef = enabled.firstWhere(
          (t) => t['function']['name'] == LocalToolNames.createSkill,
        );
        expect((createDef['function']['parameters'] as Map)['required'], const [
          'content',
        ]);

        expect(
          disabled.any(
            (t) => t['function']['name'] == LocalToolNames.downloadSkill,
          ),
          isFalse,
        );
        expect(
          disabled.any(
            (t) => t['function']['name'] == LocalToolNames.createSkill,
          ),
          isFalse,
        );
      },
    );

    test('create_skill saves the skill and reports it as enabled', () async {
      final imported = <List<String>>[];
      final content =
          '---\nname: alpha\ndescription: test skill\n---\nbody text';

      final result = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.createSkill,
        {'content': content},
        skillToolsAssistant,
        onSkillsImported: (names) async => imported.add(names),
      );

      expect(imported, const [
        ['alpha'],
      ]);
      expect(result, isNotNull);
      final payload = jsonDecode(result!) as Map<String, dynamic>;
      expect(payload['success'], isTrue);
      expect(payload['name'], 'alpha');
    });

    test('create_skill rejects empty content', () async {
      final result = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.createSkill,
        const {},
        skillToolsAssistant,
      );

      expect(result, isNotNull);
      final payload = jsonDecode(result!) as Map<String, dynamic>;
      expect(payload['error'], 'missing_content');
    });

    test('create_skill rejects content without YAML frontmatter', () async {
      final result = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.createSkill,
        const {'content': 'plain body without frontmatter'},
        skillToolsAssistant,
      );

      expect(result, isNotNull);
      final payload = jsonDecode(result!) as Map<String, dynamic>;
      expect(payload['error'], 'invalid_frontmatter');
    });

    test('create_skill rejects frontmatter without a name field', () async {
      final result = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.createSkill,
        const {'content': '---\ndescription: no name here\n---\nbody'},
        skillToolsAssistant,
      );

      expect(result, isNotNull);
      final payload = jsonDecode(result!) as Map<String, dynamic>;
      expect(payload['error'], 'name_missing');
    });

    test('create_skill reports save failures back to the model', () async {
      final result = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.createSkill,
        const {
          // uppercase name fails SkillPaths.validateName
          'content': '---\nname: ALPHA\n---\nbody',
        },
        skillToolsAssistant,
      );

      expect(result, isNotNull);
      final payload = jsonDecode(result!) as Map<String, dynamic>;
      expect(payload['error'], 'save_failed');
    });

    test('download_skill requires a url', () async {
      final result = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.downloadSkill,
        const {},
        skillToolsAssistant,
      );

      expect(result, isNotNull);
      final payload = jsonDecode(result!) as Map<String, dynamic>;
      expect(payload['error'], 'missing_url');
    });

    test(
      'download_skill rejects non-GitHub urls before any network call',
      () async {
        final result = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.downloadSkill,
          const {'url': 'https://example.com/not-github'},
          skillToolsAssistant,
        );

        expect(result, isNotNull);
        final payload = jsonDecode(result!) as Map<String, dynamic>;
        expect(payload['error'], 'invalid_url');
      },
    );

    test('download_skill is not handled when its switch is off', () async {
      final assistant = Assistant(
        id: 'a4',
        name: 'Assistant',
        localToolIds: [LocalToolNames.createSkill],
      );

      expect(
        await LocalToolsService.tryHandleToolCall(
          LocalToolNames.downloadSkill,
          const {'url': 'https://github.com/o/r'},
          assistant,
        ),
        isNull,
      );
    });
  });

  group('Device local tools', () {
    final deviceToolsAssistant = Assistant(
      id: 'd1',
      name: 'Assistant',
      localToolIds: [
        LocalToolNames.screenTime,
        LocalToolNames.calendarQuery,
        LocalToolNames.calendarCreate,
      ],
    );

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DeviceLocalTools.channel, null);
    });

    test('screen time supported only on Android', () {
      expect(DeviceLocalTools.screenTimeSupported, isTrue);
      expect(DeviceLocalTools.calendarSupported, isTrue);

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(DeviceLocalTools.screenTimeSupported, isFalse);
      expect(DeviceLocalTools.calendarSupported, isTrue);

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(DeviceLocalTools.screenTimeSupported, isFalse);
      expect(DeviceLocalTools.calendarSupported, isFalse);

      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(DeviceLocalTools.calendarSupported, isFalse);
    });

    test('definitions are gated by platform support and localToolIds', () {
      final android = LocalToolsService.buildToolDefinitions(
        assistant: deviceToolsAssistant,
        supportsTools: true,
      );
      final names = android
          .map((t) => (t['function'] as Map)['name'] as String)
          .toList();
      expect(
        names,
        containsAll(<String>[
          LocalToolNames.screenTime,
          LocalToolNames.calendarQuery,
          LocalToolNames.calendarCreate,
        ]),
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final ios = LocalToolsService.buildToolDefinitions(
        assistant: deviceToolsAssistant,
        supportsTools: true,
      );
      final iosNames = ios
          .map((t) => (t['function'] as Map)['name'] as String)
          .toList();
      expect(iosNames, isNot(contains(LocalToolNames.screenTime)));
      expect(iosNames, contains(LocalToolNames.calendarQuery));
      expect(iosNames, contains(LocalToolNames.calendarCreate));
      expect(
        ios
            .firstWhere(
              (t) =>
                  (t['function'] as Map)['name'] ==
                  LocalToolNames.calendarCreate,
            )
            .toString(),
        contains('reminder_minutes'),
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final windows = LocalToolsService.buildToolDefinitions(
        assistant: deviceToolsAssistant,
        supportsTools: true,
      );
      expect(windows, isEmpty);
    });

    test('tryHandleToolCall passes args JSON through the channel', () async {
      const channel = DeviceLocalTools.channel;
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            final args = jsonDecode(call.arguments as String) as Map;
            if (call.method == 'getScreenTime') {
              expect(args['top'], 5);
            }
            if (call.method == 'createCalendarEvent') {
              expect(args['reminder_minutes'], 30);
            }
            return '{"success":true}';
          });

      expect(
        await LocalToolsService.tryHandleToolCall(
          LocalToolNames.screenTime,
          const {'top': 5, 'range': 'week'},
          deviceToolsAssistant,
        ),
        '{"success":true}',
      );
      expect(
        await LocalToolsService.tryHandleToolCall(
          LocalToolNames.calendarQuery,
          const {'range': 'month'},
          deviceToolsAssistant,
        ),
        '{"success":true}',
      );
      expect(
        await LocalToolsService.tryHandleToolCall(
          LocalToolNames.calendarCreate,
          const {
            'title': 'Dentist',
            'start': '2026-10-01T10:00:00',
            'reminder_minutes': 30,
          },
          deviceToolsAssistant,
        ),
        '{"success":true}',
      );
      expect(calls, ['getScreenTime', 'queryCalendar', 'createCalendarEvent']);
    });

    test('native error payloads reach the model un-mangled', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DeviceLocalTools.channel, (call) async {
            if (call.method == 'getScreenTime') {
              return '{"error":"NO_PERMISSION","message":"open the usage access settings"}';
            }
            return '{"error":"INVALID_REMINDER","message":"reminder_minutes must be positive"}';
          });

      final screenTime = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.screenTime,
        const <String, dynamic>{},
        deviceToolsAssistant,
      );
      final screenTimePayload = jsonDecode(screenTime!) as Map;
      expect(screenTimePayload['error'], 'NO_PERMISSION');

      final create = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.calendarCreate,
        const {'title': 'x', 'start': '2026-10-01', 'reminder_minutes': 0},
        deviceToolsAssistant,
      );
      final createPayload = jsonDecode(create!) as Map;
      expect(createPayload['error'], 'INVALID_REMINDER');
    });

    test('unsupported platforms disable the device tools entirely', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(
        await LocalToolsService.tryHandleToolCall(
          LocalToolNames.screenTime,
          const <String, dynamic>{},
          deviceToolsAssistant,
        ),
        isNull,
      );
      expect(
        await LocalToolsService.tryHandleToolCall(
          LocalToolNames.calendarQuery,
          const <String, dynamic>{},
          deviceToolsAssistant,
        ),
        isNull,
      );
    });

    test(
      'requestToggleEnable: usage access missing keeps the tool enabled',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(DeviceLocalTools.channel, (call) async {
              if (call.method == 'hasUsageStatsPermission') return false;
              if (call.method == 'openUsageAccessSettings') return null;
              return false;
            });
        expect(
          await DeviceLocalTools.requestToggleEnable(LocalToolNames.screenTime),
          DeviceToolToggleOutcome.canEnableUsageAccessMissing,
        );
      },
    );

    test('requestToggleEnable: calendar denied keeps the tool off', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DeviceLocalTools.channel, (call) async {
            if (call.method == 'hasCalendarPermission') return false;
            if (call.method == 'requestCalendarPermission') return false;
            return false;
          });
      expect(
        await DeviceLocalTools.requestToggleEnable(
          LocalToolNames.calendarCreate,
        ),
        DeviceToolToggleOutcome.blocked,
      );
    });

    test('requestToggleEnable: calendar granted enables the tool', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DeviceLocalTools.channel, (call) async {
            if (call.method == 'hasCalendarPermission') return false;
            if (call.method == 'requestCalendarPermission') return true;
            return false;
          });
      expect(
        await DeviceLocalTools.requestToggleEnable(
          LocalToolNames.calendarQuery,
        ),
        DeviceToolToggleOutcome.canEnable,
      );
    });

    test(
      'requestCalendarPermission times out and re-checks the grant state',
      () async {
        final previousTimeout = DeviceLocalTools.calendarPermissionTimeout;
        DeviceLocalTools.calendarPermissionTimeout = const Duration(
          milliseconds: 50,
        );
        addTearDown(
          () => DeviceLocalTools.calendarPermissionTimeout = previousTimeout,
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(DeviceLocalTools.channel, (call) async {
              if (call.method == 'requestCalendarPermission') {
                // Simulate a lost native result: never completes.
                return Completer<bool>().future;
              }
              if (call.method == 'hasCalendarPermission') return true;
              return false;
            });

        // The user granted before the recreation → re-check reports the grant.
        expect(await DeviceLocalTools.requestCalendarPermission(), isTrue);
      },
    );

    test(
      'requestCalendarPermission times out and stays false when un-granted',
      () async {
        final previousTimeout = DeviceLocalTools.calendarPermissionTimeout;
        DeviceLocalTools.calendarPermissionTimeout = const Duration(
          milliseconds: 50,
        );
        addTearDown(
          () => DeviceLocalTools.calendarPermissionTimeout = previousTimeout,
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(DeviceLocalTools.channel, (call) async {
              if (call.method == 'requestCalendarPermission') {
                return Completer<bool>().future;
              }
              return false;
            });

        expect(await DeviceLocalTools.requestCalendarPermission(), isFalse);
      },
    );
  });
}
