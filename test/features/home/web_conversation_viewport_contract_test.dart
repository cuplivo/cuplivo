import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'web viewport stops scrolling through every supported native bridge',
    () {
      final source = File(
        'lib/features/home/webview/web_conversation_viewport.dart',
      ).readAsStringSync();

      expect(source, contains('onPointerDown'));
      expect(
        source,
        contains(r'window.CuplivoWeb?.stopScrolling?.(${jsonEncode(origin)});'),
      );
      expect(source, contains("_stopWebScrolling('programmatic')"));
      expect(source, contains('PointerDeviceKind.touch'));
      expect(source, contains('_windowsController?.executeScript'));
      expect(source, contains('_androidController?.stopScrolling(origin)'));
      expect(source, contains('_flutterController?.runJavaScript'));
    },
  );

  test(
    'viewport navigation cancels native momentum before sending commands',
    () {
      final source = File(
        'lib/features/home/webview/web_conversation_viewport.dart',
      ).readAsStringSync();

      expect(source, contains('_sendViewportCommand'));
      final methodStart = source.indexOf('Future<void> _sendViewportCommand');
      final methodBody = source.substring(methodStart, methodStart + 500);
      expect(methodBody, contains("_stopWebScrolling('programmatic')"));
      expect(
        methodBody.indexOf("_sendEnvelope(command)"),
        greaterThan(methodBody.indexOf("_stopWebScrolling('programmatic')")),
      );
    },
  );

  test('streaming bridge serializes batches and retains latest patches', () {
    final source = File(
      'lib/features/home/webview/web_conversation_viewport.dart',
    ).readAsStringSync();
    final protocolSource = File(
      'lib/features/home/webview/web_chat_protocol.dart',
    ).readAsStringSync();

    expect(source, contains('WebChatStreamingPatchBuffer'));
    expect(source, contains('completeBatch()'));
    expect(source, contains('hasPending'));
    expect(source, contains('_snapshotQueue.hasInFlight'));
    expect(source, contains('_streamPatchBuffer.inFlight'));
    expect(protocolSource, contains("'streamRevision'"));
  });

  test(
    'snapshot commits pause during scrolling and fail with exact context',
    () {
      final source = File(
        'lib/features/home/webview/web_conversation_viewport.dart',
      ).readAsStringSync();

      expect(source, contains('widget.viewportPort.isUserScrolling'));
      expect(source, contains('_pauseRenderCommitWatchdog'));
      expect(source, contains('_resumeRenderCommitWatchdog'));
      expect(source, contains('_renderCommitIdentity'));
      expect(source, contains("code == 'render_failed'"));
      expect(source, contains("'renderRevision': _failedRenderRevision"));
      expect(source, contains("'messageCount': _failedMessageCount"));

      final drainStart = source.indexOf('Future<void> _drainSnapshotQueue()');
      final watchdogStart = source.indexOf(
        'void _beginRenderCommitWatchdog',
        drainStart,
      );
      final drainBody = source.substring(drainStart, watchdogStart);
      expect(
        drainBody.indexOf('widget.viewportPort.isUserScrolling'),
        lessThan(drainBody.indexOf('_snapshotQueue.takeNext()')),
      );

      final armStart = source.indexOf('void _armRenderCommitWatchdog');
      final pauseStart = source.indexOf(
        'void _pauseRenderCommitWatchdog',
        armStart,
      );
      final watchdogBody = source.substring(armStart, pauseStart);
      expect(
        watchdogBody,
        contains('identity.matches(_snapshotQueue.inFlight)'),
      );
      expect(watchdogBody, contains("'render_commit_timeout'"));

      final sessionStart = source.indexOf('if (sessionChanged)');
      final portSwapStart = source.indexOf(
        'if (!identical(oldWidget.viewportPort',
        sessionStart,
      );
      final sessionBody = source.substring(sessionStart, portSwapStart);
      expect(sessionBody, contains('_snapshotQueue.clear()'));
      expect(sessionBody, contains('_clearRenderCommitWatchdog()'));
    },
  );

  test(
    'translation listeners detach from the notifier instance they bound',
    () {
      final source = File(
        'lib/features/home/webview/web_conversation_viewport.dart',
      ).readAsStringSync();
      final homeSource = File(
        'lib/features/home/pages/home_page.dart',
      ).readAsStringSync();

      expect(source, contains('_StreamingListenerBinding'));
      expect(
        source,
        contains('binding.notifier.removeListener(binding.listener)'),
      );
      final detachStart = source.indexOf('void _detachStreamingListeners()');
      final detachBody = source.substring(detachStart, detachStart + 300);
      expect(detachBody, isNot(contains('getNotifier')));
      expect(homeSource, contains("'patchKind': 'translation'"));
    },
  );

  test('layout interaction bridge is authorized before detaching follow', () {
    final source = File(
      'lib/features/home/webview/web_conversation_viewport.dart',
    ).readAsStringSync();
    final interactionStart = source.indexOf("case 'viewportInteraction':");
    final nextCase = source.indexOf("case 'action':", interactionStart);
    final interactionBody = source.substring(interactionStart, nextCase);

    expect(interactionStart, isNonNegative);
    expect(interactionBody, contains('_isAuthorizedBridgeRequest(message)'));
    expect(interactionBody, contains('viewportPort.cancelAutoFollow()'));
    expect(interactionBody, contains('widget.onUserScrollIntent()'));
  });

  test('remote media and message actions stay behind opaque registries', () {
    final viewportSource = File(
      'lib/features/home/webview/web_conversation_viewport.dart',
    ).readAsStringSync();
    final homeSource = File(
      'lib/features/home/pages/home_page.dart',
    ).readAsStringSync();

    expect(viewportSource, contains("handle.startsWith('remote:')"));
    expect(viewportSource, contains('WebChatRemoteImageLoader'));
    expect(viewportSource, contains('unknown media handle'));
    expect(homeSource, contains('remoteMediaClientFactory'));
    expect(homeSource, contains('NetworkProxyConfig'));
    expect(homeSource, contains('settings.globalProxyEnabled'));
    expect(homeSource, contains('forceCloseOnDispose: true'));
    expect(homeSource, contains('ImageViewerPage'));
    expect(homeSource, contains('OpenFilex.open'));
    expect(homeSource, contains('buildWebChatCitationSources'));
    final targetLookup = homeSource.substring(
      homeSource.indexOf('ChatMessage? _findWebActionMessage'),
      homeSource.indexOf('bool _webMessageActionAllowed'),
    );
    expect(targetLookup, isNot(contains('groupedMessages')));
  });

  test('HTML preview actions require a current Dart registry entry', () {
    final homeSource = File(
      'lib/features/home/pages/home_page.dart',
    ).readAsStringSync();
    final previewSource = File(
      'lib/shared/widgets/isolated_html_preview_document.dart',
    ).readAsStringSync();

    expect(homeSource, contains('buildWebChatHtmlPreviewRegistry(snapshot)'));
    expect(homeSource, contains('replaceWebChatHtmlPreviews('));
    expect(homeSource, contains('resolveWebChatHtmlPreviewSource('));
    expect(homeSource, contains("case 'openHtmlPreview':"));
    expect(homeSource, contains('isolated: true'));
    expect(previewSource, contains('sandbox="allow-scripts"'));
    expect(previewSource, isNot(contains('allow-same-origin')));
    expect(previewSource, contains("connect-src 'none'"));
    expect(previewSource, contains("form-action 'none'"));
  });

  test('automatic and explicit MultiAI fallback use distinct dialogs', () {
    final source = File(
      'lib/features/home/pages/home_page.dart',
    ).readAsStringSync();
    final scheduleStart = source.indexOf('void _scheduleMultiAIFallbackPrompt');
    final confirmStart = source.indexOf(
      'Future<bool> _confirmWebMultiAIFallback',
      scheduleStart,
    );
    final automaticBody = source.substring(scheduleStart, confirmStart);
    final explicitBody = source.substring(
      confirmStart,
      source.indexOf('String _webCssColor', confirmStart),
    );

    expect(automaticBody, contains('_showWebMultiAIFallbackNotice()'));
    expect(automaticBody, contains('barrierDismissible: false'));
    expect(automaticBody, contains('PopScope'));
    expect(automaticBody, contains('canPop: false'));
    expect(automaticBody, isNot(contains('_confirmWebMultiAIFallback()')));
    expect(explicitBody, contains('l10n.homePageCancel'));
    expect(explicitBody, contains('l10n.webChatMultiAIFallbackConfirm'));
  });

  test(
    'conversation switching restores a saved Web viewport before bottoming',
    () {
      final source = File(
        'lib/features/home/controllers/home_page_controller.dart',
      ).readAsStringSync();

      expect(source, contains('savedAnchorForConversation(id)'));
      expect(source, contains('restoreAnchor(savedAnchor)'));
    },
  );

  test(
    'HomePage assigns the Flutter-owned background mode to Web snapshots',
    () {
      final source = File(
        'lib/features/home/pages/home_page.dart',
      ).readAsStringSync();

      expect(source, contains("'backgroundOwner': 'flutter'"));
    },
  );

  test(
    'HomePage passes Flutter code-block surface tokens to Web snapshots',
    () {
      final source = File(
        'lib/features/home/pages/home_page.dart',
      ).readAsStringSync();

      expect(source, contains("'code-body'"));
      expect(source, contains("'code-header'"));
      expect(source, contains("'code-border'"));
      expect(source, contains("'code-header-text'"));
      expect(source, contains("'code-action'"));
    },
  );

  test(
    'HomePage reuses the localized Web loading label for virtual windows',
    () {
      final source = File(
        'lib/features/home/pages/home_page.dart',
      ).readAsStringSync();

      expect(source, contains("'loading': l10n.webChatLoading"));
    },
  );

  test('Windows Web assets reuse only complete versioned caches', () {
    final source = File(
      'lib/features/home/webview/web_conversation_viewport.dart',
    ).readAsStringSync();

    expect(source, contains('.complete'));
    expect(source, contains('.complete.tmp'));
    expect(source, contains('_windowsCacheIsComplete'));
    expect(source, contains('_cleanupOldWindowsCaches'));
    expect(source, contains("'mermaid.min.js'"));
    expect(
      source,
      contains("queryParameters: <String, String>{'platform': 'windows'}"),
    );
    expect(source, contains('addVirtualHostNameMapping'));
    expect(source, contains("scheme: 'https'"));
    expect(source, contains("host: _windowsVirtualHost"));
    expect(source, contains('winweb.WebviewHostResourceAccessKind.deny'));
    expect(source, isNot(contains('Uri.file(shell.path)')));
    expect(RegExp(r'flush: true').allMatches(source), hasLength(1));
  });

  test(
    'Android WebView cancels compositor fling before the JavaScript lock',
    () {
      final nativeSource = File(
        'android/app/src/main/kotlin/com/cup11/cuplivo/AndroidWebChatView.kt',
      ).readAsStringSync();
      final controllerSource = File(
        'lib/features/home/webview/android_web_chat_view.dart',
      ).readAsStringSync();

      expect(nativeSource, contains('setOnTouchListener'));
      expect(nativeSource, contains('MotionEvent.ACTION_DOWN'));
      expect(nativeSource, contains('"stopScrolling"'));
      expect(nativeSource, contains('webView.flingScroll(0, 0)'));
      expect(
        nativeSource,
        contains("window.CuplivoWeb?.stopScrolling?.('touch');"),
      );
      expect(
        nativeSource,
        contains("window.CuplivoWeb?.stopScrolling?.('programmatic');"),
      );
      expect(
        nativeSource,
        contains('stopScrolling(call.arguments as? String)'),
      );
      expect(
        controllerSource,
        contains(
          "Future<void> stopScrolling([String origin = 'programmatic'])",
        ),
      );
    },
  );

  test(
    'Darwin shell loads from a loopback server and awaits channel registration',
    () {
      final source = File(
        'lib/features/home/webview/web_conversation_viewport.dart',
      ).readAsStringSync();

      expect(source, contains('LocalWebChatShellServer.acquire()'));
      expect(source, contains('isLocalShellUri'));
      final acquireAt = source.indexOf('LocalWebChatShellServer.acquire()');
      final channelAt = source.indexOf('await controller.addJavaScriptChannel');
      expect(acquireAt, greaterThan(0));
      expect(channelAt, greaterThan(0));
      final loadAt = source.indexOf(
        'await controller.loadRequest(server.shellUri)',
      );
      expect(loadAt, greaterThan(0));
      expect(channelAt, greaterThan(acquireAt));
      expect(loadAt, greaterThan(channelAt));
      expect(source.substring(acquireAt, loadAt), contains("'CuplivoChat'"));
    },
  );
}
