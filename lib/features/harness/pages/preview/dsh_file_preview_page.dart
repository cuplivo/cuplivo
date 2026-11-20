import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:Cuplivo/features/harness/models/dsh_remote.dart';
import 'package:Cuplivo/features/harness/services/dsh_credential_store.dart';
import 'package:Cuplivo/features/harness/services/dsh_file_preview_host.dart';
import 'package:Cuplivo/features/harness/services/dsh_preview_cache.dart';
import 'package:Cuplivo/features/harness/services/dsh_preview_kind.dart';
import 'package:Cuplivo/features/harness/state/dsh_connections_provider.dart';
import 'package:Cuplivo/features/harness/state/dsh_gateway.dart';
import 'package:Cuplivo/features/harness/widgets/dsh_remote_file_card.dart';
import 'package:Cuplivo/features/harness/widgets/dsh_web_ui_view.dart';
import 'package:Cuplivo/features/workspace/widgets/preview/file_preview.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';

/// Builds the WebView pane for a preview kind that cannot render natively
/// (PDF, and the image fallback when `/api/file` bytes are unavailable).
///
/// Injected so the chat/settings slice can pass the shared `DshWebUiView`
/// wrapper (and a test can pass a stub); the default is `DshWebUiView` itself.
typedef DshFilePreviewWebViewBuilder =
    Widget Function(BuildContext context, Uri uri);

/// Full-screen preview of one file that lives on a DeepSeek Harness Host.
///
/// Reuse policy (see `docs/cuplivo-dsh/v2-reuse-map.md` §5): remote text and
/// image bodies are materialized into a bounded temp file by
/// [DshPreviewCache] and rendered by the existing `File`-based workspace
/// previews. PDFs (and images whose bytes are unavailable) load through the
/// embedded Host Web UI on the authenticated `/api/file` URL. Everything else
/// renders [DshRemoteFileCard] with a distinguishable reason — never a blank
/// pane.
class DshFilePreviewPage extends StatefulWidget {
  const DshFilePreviewPage({
    super.key,
    required this.remote,
    required this.sessionId,
    required this.path,
    this.displayName,
    this.cache,
    this.webViewBuilder,
  });

  final DshRemote remote;

  /// The Host session whose workspace the file belongs to.
  final String sessionId;

  /// Workspace-relative path as listed by `workspaceFiles/list`.
  final String path;

  /// Name shown in the AppBar; defaults to the path's basename.
  final String? displayName;

  /// Test/DI hook; the page owns a default bounded cache otherwise.
  final DshPreviewCache? cache;

  /// Optional WebView factory; the default mounts [DshWebUiView].
  final DshFilePreviewWebViewBuilder? webViewBuilder;

  /// Pushes the page; the one-line entry point for the rail/home call site.
  static Future<void> open(
    BuildContext context, {
    required DshRemote remote,
    required String sessionId,
    required String path,
    String? displayName,
    DshPreviewCache? cache,
    DshFilePreviewWebViewBuilder? webViewBuilder,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DshFilePreviewPage(
          remote: remote,
          sessionId: sessionId,
          path: path,
          displayName: displayName,
          cache: cache,
          webViewBuilder: webViewBuilder,
        ),
      ),
    );
  }

  @override
  State<DshFilePreviewPage> createState() => _DshFilePreviewPageState();
}

class _DshFilePreviewPageState extends State<DshFilePreviewPage> {
  late final DshPreviewCache _cache = widget.cache ?? DshPreviewCache();

  String? _cookie;
  bool _loading = true;
  DshRemoteFileCardReason? _reason;
  File? _file;
  FilePreviewKind? _kind;
  Uri? _webUri;
  DshPluginWebFailure? _webFailure;
  int _webGeneration = 0;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    final cookie = await const SecureDshCredentialStore().readCookie(
      widget.remote.id,
    );
    if (!mounted) return;
    _cookie = cookie;
    await _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _reason = null;
      _file = null;
      _kind = null;
      _webUri = null;
      _webFailure = null;
      _webGeneration += 1;
    });
    if (widget.sessionId.isEmpty) {
      _fail(generation, DshRemoteFileCardReason.noSession);
      return;
    }
    final connections = context.read<DshConnectionsProvider?>();
    final gateway = connections?.gatewayFor(widget.remote.id);
    if (gateway == null) {
      _fail(generation, DshRemoteFileCardReason.noConnection);
      return;
    }
    try {
      final stat = await gateway.statFile(widget.sessionId, widget.path);
      if (!mounted || generation != _loadGeneration) return;
      if (stat.isDirectory) {
        _fail(generation, DshRemoteFileCardReason.notFound);
        return;
      }
      final kind = classifyDshRemotePreview(
        widget.path,
        mediaType: stat.mediaType,
      );
      switch (kind) {
        case DshRemotePreviewKind.pdf:
          final uri = _fileUri(gateway, stat);
          if (uri == null) {
            _fail(generation, DshRemoteFileCardReason.notFound);
            return;
          }
          _showWeb(generation, uri);
        case DshRemotePreviewKind.office:
          _fail(generation, DshRemoteFileCardReason.unsupported);
        case DshRemotePreviewKind.image:
          await _loadImage(generation, gateway, stat);
        case DshRemotePreviewKind.text:
          await _loadText(generation, gateway);
        case DshRemotePreviewKind.unknown:
          await _loadText(generation, gateway);
      }
    } on DshGatewayException catch (error) {
      _fail(generation, _gatewayReason(error.failure, stat: true));
    } on DshPreviewCacheException catch (error) {
      _fail(
        generation,
        error.failure == DshPreviewCacheFailure.tooLarge
            ? DshRemoteFileCardReason.tooLarge
            : DshRemoteFileCardReason.loadFailed,
      );
    } catch (_) {
      _fail(generation, DshRemoteFileCardReason.loadFailed);
    }
  }

  Future<void> _loadImage(
    int generation,
    DshGateway gateway,
    DshFileStat stat,
  ) async {
    try {
      final bytes = await gateway.readFileBytes(widget.sessionId, widget.path);
      if (!mounted || generation != _loadGeneration) return;
      final file = await _cache.materializeBytes(
        remoteId: widget.remote.id,
        sessionId: widget.sessionId,
        path: widget.path,
        bytes: bytes,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _reason = null;
        _file = file;
        _kind = FilePreviewKind.image;
      });
    } on DshGatewayException catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      // Bytes unavailable: the Host's own `/api/file` URL is the documented
      // image fallback (same cookie, no text decoding).
      final uri = _fileUri(gateway, stat);
      if (uri != null) {
        _showWeb(generation, uri);
        return;
      }
      _fail(generation, _gatewayReason(error.failure));
    } on DshPreviewCacheException catch (error) {
      _fail(
        generation,
        error.failure == DshPreviewCacheFailure.tooLarge
            ? DshRemoteFileCardReason.tooLarge
            : DshRemoteFileCardReason.loadFailed,
      );
    }
  }

  Future<void> _loadText(int generation, DshGateway gateway) async {
    try {
      final text = await gateway.readTextFile(widget.sessionId, widget.path);
      if (!mounted || generation != _loadGeneration) return;
      final file = await _cache.materializeText(
        remoteId: widget.remote.id,
        sessionId: widget.sessionId,
        path: widget.path,
        text: text,
      );
      if (!mounted || generation != _loadGeneration) return;
      final kind = await classifyFilePreview(file);
      if (!mounted || generation != _loadGeneration) return;
      if (kind == FilePreviewKind.binary) {
        // The Host served a text page for a body that is not UTF-8 text; do
        // not show a garbage preview.
        _fail(generation, DshRemoteFileCardReason.unsupported);
        return;
      }
      setState(() {
        _loading = false;
        _reason = null;
        _file = file;
        _kind = kind;
      });
    } on DshGatewayException catch (error) {
      _fail(generation, _gatewayReason(error.failure));
    } on DshPreviewCacheException catch (error) {
      _fail(
        generation,
        error.failure == DshPreviewCacheFailure.tooLarge
            ? DshRemoteFileCardReason.tooLarge
            : DshRemoteFileCardReason.loadFailed,
      );
    }
  }

  void _showWeb(int generation, Uri uri) {
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _loading = false;
      _reason = null;
      _file = null;
      _kind = null;
      _webUri = uri;
      _webGeneration += 1;
    });
  }

  void _fail(int generation, DshRemoteFileCardReason reason) {
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _loading = false;
      _reason = reason;
      _file = null;
      _kind = null;
      _webUri = null;
    });
  }

  Uri? _fileUri(DshGateway gateway, DshFileStat stat) {
    if (!stat.hasAbsolutePath) return null;
    if (gateway case final DshFilePreviewHost host) {
      return host.fileUri(stat.absolutePath!, version: stat.version);
    }
    return null;
  }

  DshRemoteFileCardReason _gatewayReason(
    DshFailure failure, {
    bool stat = false,
  }) {
    return switch (failure) {
      DshFailure.notConfigured ||
      DshFailure.unreachable => DshRemoteFileCardReason.noConnection,
      DshFailure.auth => DshRemoteFileCardReason.loadFailed,
      DshFailure.protocol => DshRemoteFileCardReason.loadFailed,
      // A stat refusal is usually "this path does not exist"; a text-read
      // refusal for a binary body is a genuine unsupported preview.
      DshFailure.unsupported =>
        stat
            ? DshRemoteFileCardReason.notFound
            : DshRemoteFileCardReason.unsupported,
      DshFailure.unknown => DshRemoteFileCardReason.loadFailed,
    };
  }

  String get _title =>
      widget.displayName ??
      p.basename(widget.path.isEmpty ? 'file' : widget.path);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      key: const Key('dsh-file-preview-page'),
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            minSize: 44,
            semanticLabel: l10n.settingsPageBackButton,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (!_loading)
            Tooltip(
              message: l10n.workspacePreviewRetry,
              child: IosIconButton(
                icon: Lucide.RotateCw,
                size: 20,
                minSize: 44,
                semanticLabel: l10n.workspacePreviewRetry,
                onTap: () => unawaited(_load()),
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final reason = _reason;
    if (reason != null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: DshRemoteFileCard(
          name: _title,
          path: widget.path,
          reason: reason,
          size: null,
          onRetry: () => unawaited(_load()),
        ),
      );
    }
    final file = _file;
    final kind = _kind;
    if (file != null && kind != null) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: buildFilePreviewBody(kind: kind, file: file),
      );
    }
    final webUri = _webUri;
    if (webUri != null) {
      final failure = _webFailure;
      if (failure != null) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: DshRemoteFileCard(
            name: _title,
            path: widget.path,
            reason: failure == DshPluginWebFailure.unsupported
                ? DshRemoteFileCardReason.webPreviewUnavailable
                : DshRemoteFileCardReason.loadFailed,
            onRetry: () => unawaited(_load()),
          ),
        );
      }
      final builder = widget.webViewBuilder;
      if (builder != null) {
        return builder(context, webUri);
      }
      return DshWebUiView(
        key: ValueKey<String>('dsh-file-preview-web-$_webGeneration'),
        remote: widget.remote,
        cookie: _cookie,
        initialUrl: webUri,
        showHonestyNote: false,
        onFailureChanged: (failure) {
          if (!mounted || failure == null || _webFailure == failure) return;
          setState(() => _webFailure = failure);
        },
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: DshRemoteFileCard(
        name: _title,
        path: widget.path,
        reason: DshRemoteFileCardReason.unsupported,
        onRetry: () => unawaited(_load()),
      ),
    );
  }
}
