import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/services/network/request_logger.dart';
import 'package:Cuplivo/core/services/search/providers/tavily_search_service.dart';
import 'package:Cuplivo/core/services/search/search_service.dart';
import 'package:Cuplivo/core/services/search/search_service_usage_service.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform previousPathProvider;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kelivo_search_logs_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    RequestLogger.saveOutput = true;
    await RequestLogger.setEnabled(true);
  });

  tearDown(() async {
    await RequestLogger.setEnabled(false);
    PathProviderPlatform.instance = previousPathProvider;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'search and usage requests are written to the common request log',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.method == 'POST') {
          await utf8.decoder.bind(request).join();
        }
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/usage') {
          request.response.write(
            jsonEncode({
              'account': {'plan_usage': 25, 'plan_limit': 100},
            }),
          );
        } else {
          request.response.write(jsonEncode({'results': <Object>[]}));
        }
        await request.response.close();
      });

      final endpoint = 'http://127.0.0.1:${server.port}/search';
      final options = TavilyOptions(
        id: 'logged-tavily',
        apiKey: 'test-key',
        url: endpoint,
      );

      await HttpOverrides.runZoned(
        () async {
          await TavilySearchService().search(
            query: 'logged search',
            commonOptions: const SearchCommonOptions(timeout: 5000),
            serviceOptions: options,
          );
          await SearchServiceUsageService.fetch(options);
        },
        createHttpClient: (context) =>
            _RealHttpOverrides().createHttpClient(context),
      );

      final log = await _waitForLog(
        File('${tempDir.path}/logs/logs.txt'),
        expected: <String>[
          'POST $endpoint',
          'GET http://127.0.0.1:${server.port}/usage',
          'status=200',
        ],
      );
      expect(log, contains('body='));
    },
  );
}

Future<String> _waitForLog(File file, {required List<String> expected}) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (await file.exists()) {
      final content = await file.readAsString();
      if (expected.every(content.contains)) return content;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return file.existsSync() ? file.readAsStringSync() : '';
}
