import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/services/network/request_logger.dart';
import 'package:Cuplivo/core/services/search/providers/tavily_search_service.dart';
import 'package:Cuplivo/core/services/search/search_service.dart';
import 'package:Cuplivo/core/services/search/search_service_usage_service.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../support/temp_directory_cleanup.dart';

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
    // Disabling the logger stops the next write, not one already in flight, so
    // the log file can still be open here for a moment. POSIX unlinks it anyway;
    // Windows answers `errno = 32` and the failure lands in `tearDown` after a
    // test that passed.
    await deleteDirectoryWhenReleased(tempDir);
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
  // The logger writes from whichever isolate finished the request, so this is a
  // wall-clock ceiling rather than a frame count — one second was enough alone
  // and not enough with the whole suite running. Ten is the same ceiling the
  // migration fixture uses.
  String last = '';
  for (var attempt = 0; attempt < 500; attempt++) {
    if (await file.exists()) {
      last = await file.readAsString();
      if (expected.every(last.contains)) return last;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Request log never carried ${[for (final e in expected) if (!last.contains(e)) e]}.\n$last');
}
