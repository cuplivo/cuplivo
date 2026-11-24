import 'dart:async';

import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/features/harness/pages/harness_web_page.dart';
import 'package:Cuplivo/features/home/widgets/message_list_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'acceptance_support.dart';

/// TEMPORARY diagnostics scenario: it replaces the acceptance scenario for one
/// device run so the embedded WebView's load failure can be observed on the
/// real runtime (error type, cookie state, first-load versus retry).
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('harness webview diagnostics', (tester) async {
    const baseUrl = String.fromEnvironment('E2E_DSH_URL');
    const token = String.fromEnvironment('E2E_DSH_TOKEN');
    final live = baseUrl.isNotEmpty && token.isNotEmpty;
    _mark('live=$live');
    if (!live) {
      fail('the diagnostics scenario needs E2E_DSH_URL and E2E_DSH_TOKEN');
    }
    _mark('boot');
    await bootSeededApp(tester, binding);
    _mark('booted');

    final context = tester.element(find.byType(MessageListView));
    final assistants = Provider.of<AssistantProvider>(context, listen: false);
    await assistants.addHarnessAssistant(name: 'Diag Harness');
    final harness = assistants.assistants.firstWhere(
      (assistant) => assistant.isDeepSeekHarness,
    );
    await assistants.updateAssistant(
      harness.copyWith(harnessUrl: '$baseUrl/?token=$token'),
    );
    _mark('harness stored for ${Uri.parse(baseUrl).host}');

    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => HarnessWebPage(assistantId: harness.id),
        ),
      ),
    );
    await pumpUntil(
      tester,
      () => find.byKey(const Key('harness-web-page')).evaluate().isNotEmpty,
      maxFrames: 150,
    );
    _mark('embedded page pushed');

    var seen = 'none';
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final error = find
          .byKey(const Key('harness-web-view-error'))
          .evaluate()
          .isNotEmpty;
      final view = find
          .byKey(const Key('harness-web-view'))
          .evaluate()
          .isNotEmpty;
      final state = error ? 'error' : (view ? 'view' : 'gone');
      if (state != seen) {
        seen = state;
        _mark('webview state: $state');
      }
      if (error) break;
      if (i == 20 || i == 40) {
        await _logCookies(baseUrl);
      }
    }
    _mark('first wait ended in state: $seen');
    await _logCookies(baseUrl);

    // A retry re-runs the same navigation with the WebView's cookie store
    // already primed: if that loads, the first failure is a cookie/late-setup
    // race rather than a rejected link.
    if (find.byKey(const Key('harness-web-view-error')).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const Key('harness-web-view-retry')));
      _mark('retry tapped');
      var retried = 'none';
      for (var i = 0; i < 250; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        final error = find
            .byKey(const Key('harness-web-view-error'))
            .evaluate()
            .isNotEmpty;
        final state = error ? 'error' : 'loading';
        if (state != retried) {
          retried = state;
          _mark('retry state: $state');
        }
        if (!error && i > 60) break;
      }
      _mark('retry wait ended in state: $retried');
      await _logCookies(baseUrl);
    }

    _mark('done');
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 8)));
}

final _clock = Stopwatch()..start();

void _mark(String step) =>
    debugPrint('[diag +${_clock.elapsedMilliseconds}ms] $step');

Future<void> _logCookies(String baseUrl) async {
  try {
    final cookies = await CookieManager.instance().getCookies(
      url: WebUri(baseUrl),
    );
    debugPrint(
      '[diag] cookies: ${cookies.map((cookie) => cookie.name).toList()}',
    );
  } catch (error) {
    debugPrint('[diag] cookie read failed: $error');
  }
}
