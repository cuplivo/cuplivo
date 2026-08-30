import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/models/backup.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/asr/asr_service_options.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

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

  group('ASR backup policy', () {
    late Directory root;

    setUp(() async {
      businessPrefs = BusinessPreferences.memoryForTests();
      root = await Directory.systemTemp.createTemp('cuplivo_asr_sync_test_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test(
      'export strips device-bound ASR and keeps cloud services only',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'asr_services_v1': jsonEncode([
            {'id': 'system-asr', 'kind': 'system', 'localeId': 'zh_CN'},
            {
              'id': 'local-asr',
              'kind': 'sherpa_onnx',
              'modelDirectory': '/device/models/sense-voice',
            },
            {
              'id': 'cloud-asr',
              'kind': 'openai_realtime',
              'apiKey': 'asr-secret',
            },
          ]),
          'asr_selected_service_id_v1': 'local-asr',
        });

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(content: BackupContentScope(chatsAndAssistants: false, attachments: false, workspaces: false, fontsAndAvatars: false, settings: true, skills: true)),
        );
        addTearDown(() => backupFile.deleteSync());

        final archive = ZipDecoder().decodeBytes(backupFile.readAsBytesSync());
        final settingsEntry = archive.findFile('settings.json');
        expect(settingsEntry, isNotNull);
        final settings =
            jsonDecode(utf8.decode(settingsEntry!.content as List<int>))
                as Map<String, dynamic>;

        final asrServices =
            jsonDecode(settings['asr_services_v1'] as String) as List;
        expect(asrServices.map((entry) => (entry as Map)['id']), ['cloud-asr']);
        // Selected device-bound service is dropped with its services.
        expect(settings, isNot(contains('asr_selected_service_id_v1')));
      },
    );

    test('export keeps the selected id when a cloud service remains', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'asr_services_v1': jsonEncode([
          {'id': 'local-asr', 'kind': 'sherpa_onnx', 'modelDirectory': '/m'},
          {'id': 'cloud-asr', 'kind': 'step'},
        ]),
        'asr_selected_service_id_v1': 'cloud-asr',
      });

      final sync = DataSync(
        preferences: businessPrefs,
        chatService: ChatService(),
      );
      final backupFile = await sync.prepareBackupFile(
        const WebDavConfig(content: BackupContentScope(chatsAndAssistants: false, attachments: false, workspaces: false, fontsAndAvatars: false, settings: true, skills: true)),
      );
      addTearDown(() => backupFile.deleteSync());

      final archive = ZipDecoder().decodeBytes(backupFile.readAsBytesSync());
      final settings =
          jsonDecode(
                utf8.decode(
                  (archive.findFile('settings.json')!.content as List<int>),
                ),
              )
              as Map<String, dynamic>;

      final asrServices =
          jsonDecode(settings['asr_services_v1'] as String) as List;
      expect(asrServices.map((entry) => (entry as Map)['id']), ['cloud-asr']);
      expect(settings['asr_selected_service_id_v1'], 'cloud-asr');
    });

    test(
      'merge restore deduplicates ASR services by id, preferring existing',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'asr_services_v1': jsonEncode([
            {
              'id': 'cloud-asr',
              'kind': 'openai_realtime',
              'apiKey': 'existing-key',
            },
          ]),
        });

        // Build an incoming backup whose settings.json carries an overlapping
        // ASR service (newer apiKey) plus one brand-new service.
        final settingsFile = File(p.join(root.path, 'settings.json'));
        await settingsFile.writeAsString(
          jsonEncode({
            'asr_services_v1': jsonEncode([
              {
                'id': 'cloud-asr',
                'kind': 'openai_realtime',
                'apiKey': 'incoming-key',
              },
              {'id': 'new-cloud', 'kind': 'volcengine'},
            ]),
          }),
        );
        final encoder = ZipFileEncoder();
        final zipFile = File(p.join(root.path, 'backup.zip'));
        encoder.create(zipFile.path);
        encoder.addFileSync(settingsFile, 'settings.json');
        encoder.close();

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(content: BackupContentScope(chatsAndAssistants: false, attachments: false, workspaces: false, fontsAndAvatars: false, settings: true, skills: true)),
          mode: RestoreMode.merge,
        );

        final prefs = businessPrefs;
        final merged = jsonDecode(prefs.getString('asr_services_v1')!) as List;
        expect(merged.map((entry) => (entry as Map)['id']), [
          'cloud-asr',
          'new-cloud',
        ]);
        // Existing value wins for the overlapping id.
        expect((merged.first as Map)['apiKey'], 'existing-key');
      },
    );
  });

  group('SettingsProvider ASR persistence', () {
    test(
      'ASR is opt-in and persists services with a stable selection',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests(const {});
        final settings = await _newSettings();

        expect(settings.asrServices, isEmpty);
        expect(settings.selectedAsrService, isNull);

        final system = SystemAsrOptions(id: 'system-asr', localeId: 'zh_CN');
        final openAi = OpenAiRealtimeAsrOptions(
          id: 'openai-asr',
          apiKey: 'test-key',
        );
        await settings.setAsrServices(<AsrServiceOptions>[system, openAi]);
        expect(settings.selectedAsrServiceId, system.id);
        await settings.setSelectedAsrServiceId(openAi.id);

        final reloaded = await _newSettings();
        expect(reloaded.asrServices, hasLength(2));
        expect(reloaded.selectedAsrServiceId, openAi.id);
        expect(reloaded.selectedAsrService, isA<OpenAiRealtimeAsrOptions>());
        expect(
          (reloaded.selectedAsrService! as OpenAiRealtimeAsrOptions).apiKey,
          'test-key',
        );
      },
    );

    test(
      'removing the selected ASR falls back to the first remaining service',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests(const {});
        final settings = await _newSettings();
        final first = SystemAsrOptions(id: 'first');
        final second = MimoAsrOptions(id: 'second', apiKey: 'test-key');
        await settings.setAsrServices(<AsrServiceOptions>[first, second]);
        await settings.setSelectedAsrServiceId(second.id);

        await settings.setAsrServices(<AsrServiceOptions>[first]);
        expect(settings.selectedAsrServiceId, first.id);
        await settings.setAsrServices(const <AsrServiceOptions>[]);
        expect(settings.selectedAsrServiceId, isNull);
      },
    );

    test('copyWith carries the ASR snapshot without another load', () async {
      businessPrefs = BusinessPreferences.memoryForTests(const {});
      final settings = await _newSettings();

      await settings.setAsrServices(<AsrServiceOptions>[
        SystemAsrOptions(id: 'copy-system'),
      ]);

      final copy = settings.copyWith(searchAutoTestOnLaunch: true);
      expect(copy.asrServices, hasLength(1));
      expect(copy.selectedAsrServiceId, 'copy-system');
      expect(copy.searchAutoTestOnLaunch, isTrue);
    });

    test(
      'malformed service rows are skipped while valid ones survive',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'asr_services_v1': jsonEncode([
            {'id': 'valid', 'kind': 'step'},
            'not-a-map',
            {'id': 'no-kind'},
          ]),
          'asr_selected_service_id_v1': 'valid',
        });
        final settings = await _newSettings();

        expect(settings.asrServices, hasLength(1));
        expect(settings.selectedAsrServiceId, 'valid');
      },
    );
  });
}

Future<SettingsProvider> _newSettings() async {
  final settings = SettingsProvider(preferences: businessPrefs);
  await settings.loaded;
  return settings;
}
