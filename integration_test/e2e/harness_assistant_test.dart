import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/features/assistant/pages/assistant_settings_page.dart';
import 'package:Cuplivo/features/harness/pages/harness_settings_page.dart';
import 'package:Cuplivo/features/harness/pages/harness_web_page.dart';
import 'package:Cuplivo/features/home/pages/home_mobile_layout.dart';
import 'package:Cuplivo/features/home/widgets/message_list_view.dart';
import 'package:Cuplivo/features/home/widgets/side_drawer.dart';
import 'package:Cuplivo/features/settings/pages/settings_page.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import 'acceptance_support.dart';

/// Acceptance scenario for the remote DeepSeek Harness assistant.
///
/// The flow mirrors the product surfaces:
/// 1. create the harness assistant from the "+" menu of the assistants page
///    (create sheet, then its connection page);
/// 2. claim the link in the connection page — the button only turns into
///    "已连接" after this app itself redeems the token for the operator cookie
///    and answers one authenticated Remote API request;
/// 3. the assistants list shows the harness row with the connected dot;
/// 4. the native sidebar lists the harness row, and tapping it opens the
///    embedded DSH WebUI under a return bar that goes back to the chat page.
///
/// Live path (`E2E_DSH_URL` + `E2E_DSH_TOKEN` from `--dart-define-from-file`):
/// additionally proves the operator session is usable for a whole turn —
/// create a session, send one prompt and read the answer back through the same
/// JSON-RPC the embedded WebUI uses. The embedded view is the remote product's
/// own SPA, which a Flutter test cannot drive; the turn therefore runs through
/// the endpoint the app just authenticated, not through DOM scripting.
/// Hermetic path (both defines empty): the stored link is seeded through the
/// public provider API instead of a live probe, and the scenario keeps all the
/// navigation/screenshot steps; only live-server assertions are skipped.
///
/// The launch token is live credential material: it is typed once, never
/// logged, and the connection field is cleared by the success path before any
/// screenshot is taken.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final l10n = lookupAppLocalizations(const Locale('en'));

  testWidgets('harness acceptance scenario', (tester) async {
    final baseUrl = String.fromEnvironment('E2E_DSH_URL');
    final token = String.fromEnvironment('E2E_DSH_TOKEN');
    if (baseUrl.isNotEmpty != token.isNotEmpty) {
      fail(
        'E2E_DSH_URL and E2E_DSH_TOKEN must be provided together; exactly one '
        'was set, so the run would silently mix a live and a hermetic path.',
      );
    }
    final live = baseUrl.isNotEmpty;

    await bootSeededApp(tester, binding);

    // --- Settings: create the harness assistant and connect it ---------------
    await _openCreateMenu(tester, binding, l10n);

    expect(find.text(l10n.assistantHarnessWebUiUrlLabel), findsOneWidget);
    expect(find.text(l10n.assistantHarnessWebUiUrlHelper), findsOneWidget);
    expect(
      find.byKey(const Key('harness-connected-status')),
      findsNothing,
      reason: 'a freshly created harness has no saved link yet',
    );

    if (live) {
      await tester.enterText(
        find.byKey(const Key('harness-url-field')),
        '$baseUrl/?token=$token',
      );
      await pumpFrames(tester);
      await tester.tap(find.byKey(const Key('harness-confirm-button')));
      await pumpUntil(
        tester,
        () => find
            .byKey(const Key('harness-connected-status'))
            .evaluate()
            .isNotEmpty,
        maxFrames: 450,
      );
      expect(find.byKey(const Key('harness-connected-status')), findsOneWidget);
      expect(find.text(l10n.assistantHarnessConnected), findsWidgets);
      // The success path clears the field: the credential must not sit on a
      // surface that is about to be captured.
      final onScreen = tester
          .widgetList<EditableText>(find.byType(EditableText))
          .map((field) => field.controller.text)
          .where((text) => text.contains(token));
      expect(
        onScreen,
        isEmpty,
        reason: 'the launch token must not stay on screen',
      );
      await capture(tester, binding, 'harness_02_settings_connected');
    } else {
      // Hermetic run: there is no server to prove the link against, so seed the
      // stored link through the provider it belongs to and keep the UI path.
      final context = tester.element(find.byType(HarnessSettingsPage));
      final assistants = Provider.of<AssistantProvider>(context, listen: false);
      final harness = assistants.assistants.firstWhere(
        (assistant) => assistant.isDeepSeekHarness,
      );
      await assistants.updateAssistant(
        harness.copyWith(harnessUrl: 'https://dsh-e2e.example.com'),
      );
      await pumpFrames(tester);
      await capture(tester, binding, 'harness_02_settings_hermetic');
    }

    // --- Assistants list: the harness row and its connected dot --------------
    await _tapAppBarBack(tester);
    await pumpUntil(
      tester,
      () => find.byType(ChatOwnerSettingsPage).evaluate().isNotEmpty,
      maxFrames: 150,
    );
    expect(find.text(l10n.assistantHarnessRemoteSubtitle), findsOneWidget);
    if (live) {
      await pumpUntil(
        tester,
        () => find
            .byKey(const Key('harness-connected-dot'))
            .evaluate()
            .isNotEmpty,
        maxFrames: 100,
      );
      expect(find.byKey(const Key('harness-connected-dot')), findsOneWidget);
    } else {
      expect(find.byKey(const Key('harness-connected-dot')), findsNothing);
    }
    await capture(tester, binding, 'harness_03_assistant_list');

    // --- Native sidebar: the harness row next to the assistants --------------
    await _tapAppBarBack(tester);
    await pumpUntil(
      tester,
      () => find.byType(SettingsPage).evaluate().isNotEmpty,
      maxFrames: 150,
    );
    await _tapAppBarBack(tester);
    await pumpUntil(
      tester,
      () => find.byType(HomeMobileScaffold).evaluate().isNotEmpty,
      maxFrames: 150,
    );
    final home = tester.widget<HomeMobileScaffold>(
      find.byType(HomeMobileScaffold),
    );
    home.drawerController.jumpTo(1.0);
    await pumpFrames(tester);
    expect(find.byType(SideDrawer), findsOneWidget);
    final harnessRow = find.descendant(
      of: find.byType(SideDrawer),
      matching: find.text(l10n.assistantHarnessDefaultName),
    );
    expect(harnessRow, findsOneWidget);
    await capture(tester, binding, 'harness_04_native_sidebar');

    // --- The embedded WebUI and its return bar -------------------------------
    await tester.tap(harnessRow);
    await pumpUntil(
      tester,
      () => find.byType(HarnessWebPage).evaluate().isNotEmpty,
      maxFrames: 200,
    );
    expect(find.byType(HarnessWebPage), findsOneWidget);
    expect(find.byKey(const Key('harness-return-button')), findsOneWidget);
    expect(find.byKey(const Key('harness-web-view')), findsOneWidget);
    if (live) {
      // The remote SPA is the only thing that can report a broken link here:
      // wait for it, then require that the widget did not land in its error
      // state. A token the server rejected would show up exactly there.
      await pumpUntil(
        tester,
        () => find
            .byKey(const Key('harness-web-view-error'))
            .evaluate()
            .isNotEmpty,
        maxFrames: 250,
      );
      expect(
        find.byKey(const Key('harness-web-view-error')),
        findsNothing,
        reason: 'the live DSH WebUI must load through the stored link',
      );
      expect(
        find.byKey(const Key('harness-web-view-unsupported')),
        findsNothing,
      );
    }
    await pumpFrames(tester);
    await capture(tester, binding, 'harness_05_web_ui');

    // The return bar is a page exit, not a chat entry: the Cuplivo chat page is
    // exactly where it was, drawer closed.
    await tester.tap(find.byKey(const Key('harness-return-button')));
    await pumpUntil(
      tester,
      () => find.byType(HarnessWebPage).evaluate().isEmpty,
      maxFrames: 150,
    );
    expect(find.byType(HarnessWebPage), findsNothing);
    final homeAfter = tester.widget<HomeMobileScaffold>(
      find.byType(HomeMobileScaffold),
    );
    expect(homeAfter.drawerController.isClosed, isTrue);
    expect(find.byType(MessageListView), findsWidgets);
    await capture(tester, binding, 'harness_06_back_to_chat');

    // --- Live endpoint contract: one whole prompt round trip ------------------
    if (live) {
      final answer = await _promptTheEndpoint(baseUrl: baseUrl, token: token);
      expect(
        answer.trim(),
        isNotEmpty,
        reason: 'the real DSH endpoint must answer the acceptance prompt',
      );
      debugPrint(
        'harness acceptance: the endpoint answered with '
        '${answer.trim().length} characters',
      );
    }

    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 8)));
}

/// Home drawer → Settings → Assistants and groups → "+" → DeepSeek Harness.
///
/// Leaves the harness settings page on screen, after capturing the create menu
/// (the bottom sheet the third entry belongs to).
Future<void> _openCreateMenu(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  AppLocalizations l10n,
) async {
  final home = tester.widget<HomeMobileScaffold>(
    find.byType(HomeMobileScaffold),
  );
  home.drawerController.jumpTo(1.0);
  await pumpFrames(tester);

  final settingsButton = find.descendant(
    of: find.byType(SideDrawer),
    matching: find.byIcon(Lucide.Settings),
  );
  expect(settingsButton, findsOneWidget);
  await tester.tap(settingsButton);
  await pumpUntil(
    tester,
    () => find.byType(SettingsPage).evaluate().isNotEmpty,
    maxFrames: 150,
  );
  expect(find.byType(SettingsPage), findsOneWidget);

  await tester.tap(find.text(l10n.settingsPageChatOwners).first);
  await pumpUntil(
    tester,
    () => find.byType(ChatOwnerSettingsPage).evaluate().isNotEmpty,
    maxFrames: 150,
  );
  expect(find.byType(ChatOwnerSettingsPage), findsOneWidget);

  final plus = find.descendant(
    of: find.byType(AppBar),
    matching: find.byIcon(Lucide.Plus),
  );
  expect(plus, findsOneWidget);
  await tester.tap(plus);
  await pumpUntil(
    tester,
    () => find.byKey(const Key('harness-create-item')).evaluate().isNotEmpty,
    maxFrames: 100,
  );
  await capture(tester, binding, 'harness_01_create_menu');

  await tester.tap(find.byKey(const Key('harness-create-item')));
  await pumpUntil(
    tester,
    () => find.byType(HarnessSettingsPage).evaluate().isNotEmpty,
    maxFrames: 150,
  );
  expect(find.byType(HarnessSettingsPage), findsOneWidget);
}

Future<void> _tapAppBarBack(WidgetTester tester) async {
  final back = find.descendant(
    of: find.byType(AppBar),
    matching: find.byIcon(Lucide.ArrowLeft),
  );
  expect(back, findsOneWidget);
  await tester.tap(back);
  await pumpFrames(tester);
}

/// Runs the real-endpoint half of the contract: redeem the launch token for the
/// operator session, create a session, send one prompt and read the answer back.
Future<String> _promptTheEndpoint({
  required String baseUrl,
  required String token,
}) async {
  final endpoint = await _DshOperator.connect(baseUrl: baseUrl, token: token);
  try {
    final sessionId = await endpoint.createSession();
    await endpoint.prompt(
      sessionId: sessionId,
      text: 'Reply with the single word OK.',
    );
    return await endpoint.waitForAnswer(sessionId);
  } finally {
    endpoint.close();
  }
}

/// A minimal Remote API client for the acceptance scenario.
///
/// This is deliberately test-side: it is how the scenario proves the endpoint
/// the app just connected to is usable for a turn, without scripting the remote
/// SPA inside the WebView.
class _DshOperator {
  _DshOperator._(this._client, this._base, this._cookies);

  static const Duration _requestTimeout = Duration(seconds: 30);

  final HttpClient _client;
  final Uri _base;
  final Map<String, String> _cookies;

  static Future<_DshOperator> connect({
    required String baseUrl,
    required String token,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final base = _baseUri(baseUrl);
      final cookies = <String, String>{};

      final launchUri = base.replace(
        queryParameters: <String, String>{'token': token},
      );
      final launch = await _get(client, launchUri).timeout(_requestTimeout);
      final launchStatus = launch.statusCode;
      cookies.addAll(_cookiesOf(launch));
      await launch.drain<void>();
      if (!_isRedirectOrOk(launchStatus)) {
        throw StateError('the launch link answered HTTP $launchStatus');
      }

      final connectUri = base.replace(
        path: _joinPath(base.path, 'connect'),
        queryParameters: <String, String>{
          'token': token,
          'interactions': 'answer',
        },
      );
      final connect = await _get(client, connectUri).timeout(_requestTimeout);
      final connectStatus = connect.statusCode;
      cookies.addAll(_cookiesOf(connect));
      await connect.drain<void>();
      if (!_isRedirectOrOk(connectStatus)) {
        throw StateError('the token exchange answered HTTP $connectStatus');
      }
      if (cookies.isEmpty) {
        throw StateError('the token exchange returned no cookie');
      }
      return _DshOperator._(client, base, cookies);
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, Object?> args,
  ) async {
    final rpcId = const Uuid().v4();
    final uri = _base.replace(path: _joinPath(_base.path, 'api/$method'));
    final request = await _client.postUrl(uri).timeout(_requestTimeout);
    request.headers.contentType = ContentType.json;
    request.headers.set(
      HttpHeaders.cookieHeader,
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
    );
    request.write(
      jsonEncode(<String, Object?>{
        'type': 'client-request',
        'rpcId': rpcId,
        'method': method,
        'payload': <String, Object?>{'args': args},
      }),
    );
    final response = await request.close().timeout(_requestTimeout);
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(_requestTimeout);
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('$method answered HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw StateError('$method returned a non-object response');
    }
    if (decoded['rpcId'] != rpcId) {
      throw StateError('$method answered a different request id');
    }
    final result = decoded['result'];
    if (result is! Map || result['ok'] != true) {
      throw StateError('$method failed: $body');
    }
    final value = result['value'];
    return value is Map ? value.cast<String, dynamic>() : <String, dynamic>{};
  }

  Future<String> createSession() async {
    final value = await _call('session/create', <String, Object?>{
      'request': <String, Object?>{},
    });
    final sessionId = value['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) {
      throw StateError('session/create returned no session id');
    }
    return sessionId;
  }

  Future<void> prompt({required String sessionId, required String text}) async {
    final value = await _call('session/prompt', <String, Object?>{
      'request': <String, Object?>{
        'requestId': const Uuid().v4(),
        'sessionId': sessionId,
        'mode': 'queue',
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': text},
        ],
      },
    });
    if (value['accepted'] != true) {
      throw StateError('session/prompt was not accepted');
    }
  }

  /// Polls the cold-safe history page — the same records the WebUI's view is
  /// built from — until an assistant message with text has landed.
  Future<String> waitForAnswer(String sessionId) async {
    final deadline = DateTime.now().add(const Duration(seconds: 150));
    while (DateTime.now().isBefore(deadline)) {
      final value = await _call('session/events', <String, Object?>{
        'request': <String, Object?>{
          'address': <String, Object?>{
            'kind': 'session',
            'sessionId': sessionId,
          },
          'maxMessages': 200,
        },
      });
      final records = value['records'];
      final answer = _lastAssistantText(records);
      if (answer != null && answer.trim().isNotEmpty) return answer;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw StateError('the DSH session produced no answer within 150 seconds');
  }

  void close() => _client.close(force: true);

  static String? _lastAssistantText(Object? records) {
    if (records is! List) return null;
    String? answer;
    for (final record in records) {
      if (record is! Map) continue;
      final event = record['event'];
      if (event is! Map || event['type'] != 'assistant/message') continue;
      final data = event['data'];
      final message = data is Map ? data['message'] : null;
      final content = message is Map ? message['content'] : null;
      if (content is! List) continue;
      final text = StringBuffer();
      for (final part in content) {
        if (part is Map && part['type'] == 'text' && part['text'] is String) {
          text.write(part['text']);
        }
      }
      if (text.isNotEmpty) answer = text.toString();
    }
    return answer;
  }

  static Future<HttpClientResponse> _get(HttpClient client, Uri uri) async {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'text/html,application/json');
    return request.close();
  }

  static bool _isRedirectOrOk(int status) =>
      status == HttpStatus.ok ||
      status == HttpStatus.found ||
      status == HttpStatus.seeOther;

  static Uri _baseUri(String baseUrl) {
    final uri = Uri.parse(baseUrl.trim());
    if (uri.host.isEmpty) {
      throw StateError('E2E_DSH_URL is not an absolute URL');
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    );
  }

  static String _joinPath(String basePath, String tail) {
    if (basePath.isEmpty || basePath == '/') return '/$tail';
    return basePath.endsWith('/') ? '$basePath$tail' : '$basePath/$tail';
  }

  static Map<String, String> _cookiesOf(HttpClientResponse response) {
    final cookies = <String, String>{};
    final values = response.headers[HttpHeaders.setCookieHeader];
    if (values == null) return cookies;
    for (final raw in values) {
      final pair = raw.split(';').first.trim();
      final equals = pair.indexOf('=');
      if (equals <= 0) continue;
      cookies[pair.substring(0, equals).trim()] = pair
          .substring(equals + 1)
          .trim();
    }
    return cookies;
  }
}
