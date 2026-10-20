import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/database/startup_failure_report.dart' show formatBytes;
import '../../../core/providers/assistant_provider.dart';
import '../../../core/services/recycle/recycle_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../recycle_actions.dart';

/// How much of a body is drawn. The bin's own caps allow a single entry to be
/// hundreds of megabytes, and a page that tries to lay one out stalls the UI
/// thread long before the user can read it; the notice says it was cut.
const int kRecyclePreviewCapBytes = 200 * 1024;

/// Cuts [text] to [capBytes] without splitting a character: a half-decoded rune
/// would draw as the replacement glyph and read as damage.
@visibleForTesting
String capRecyclePreview(
  String text, {
  int capBytes = kRecyclePreviewCapBytes,
}) {
  if (utf8.encode(text).length <= capBytes) return text;
  var used = 0;
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    final size = rune < 0x80
        ? 1
        : rune < 0x800
        ? 2
        : rune < 0x10000
        ? 3
        : 4;
    if (used + size > capBytes) break;
    buffer.writeCharCode(rune);
    used += size;
  }
  return buffer.toString();
}

/// The name to warn with when a staged conversation's assistant is gone, or null
/// when there is nothing to say.
///
/// [exists] answers "does this assistant still exist here". A cascade names the
/// assistant on the group its conversations carry, which is the only surviving
/// copy of that name once the row is deleted; a conversation staged on its own
/// still has its assistant, so there is nothing to warn about.
@visibleForTesting
String? orphanAssistantName({
  required Map<String, List<Map<String, Object?>>>? tables,
  required bool Function(String id) exists,
  String? fallbackName,
}) {
  final rows = tables?['conversation_rows'];
  if (rows == null || rows.isEmpty) return null;
  final assistantId = rows.first['assistant_id'];
  if (assistantId is! String || assistantId.isEmpty) return null;
  if (exists(assistantId)) return null;
  return fallbackName ?? assistantId;
}

/// What one bin entry actually holds.
///
/// The list says "a conversation, deleted on this date, this big"; that is not
/// enough to decide whether to bring it back, so this page shows the thing
/// itself: the row the bin captured, as the JSON it is stored as. Reading the
/// staged copy is the point — a preview rendered from anything else could
/// disagree with what a restore would write.
class RecycleEntryDetailPage extends StatefulWidget {
  const RecycleEntryDetailPage({super.key, required this.entry});

  final RecycleEntry entry;

  @override
  State<RecycleEntryDetailPage> createState() => _RecycleEntryDetailPageState();
}

class _RecycleEntryDetailPageState extends State<RecycleEntryDetailPage> {
  static final DateFormat _stampFormat = DateFormat('yyyy-MM-dd HH:mm');
  static const JsonEncoder _pretty = JsonEncoder.withIndent('  ');

  RecycleEntry get _entry => widget.entry;

  Map<String, List<Map<String, Object?>>>? _tables;
  List<int>? _fileBytes;
  bool _fileIsText = false;
  bool _loading = true;
  bool _busy = false;
  String? _orphanAssistantName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _read();
    });
  }

  RecycleService? get _service {
    try {
      return context.read<RecycleService>();
    } catch (_) {
      return null;
    }
  }

  Future<void> _read() async {
    final service = _service;
    if (service == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (_entry.bodyKind == RecycleBodyKind.byteFile) {
      final file = await service.bodyFile(_entry);
      final bytes = file == null ? null : await _readFile(file);
      if (!mounted) return;
      setState(() {
        _fileBytes = bytes;
        _fileIsText = bytes != null && _decodesAsText(bytes);
        _loading = false;
      });
      return;
    }
    final tables = await service.readTables(_entry);
    if (!mounted) return;
    setState(() {
      _tables = tables;
      _loading = false;
    });
    if (_entry.type == RecycleEntryType.conversation) {
      final name = await _orphanAssistant(tables);
      if (mounted && name != null) setState(() => _orphanAssistantName = name);
    }
  }

  static Future<List<int>?> _readFile(File file) async {
    try {
      return await file.readAsBytes();
    } catch (error) {
      debugPrint('recycle: reading ${file.path} failed: $error');
      return null;
    }
  }

  static bool _decodesAsText(List<int> bytes) {
    try {
      utf8.decode(bytes);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The name to warn with when the conversation's assistant is gone.
  ///
  /// Outside the provider tree there is no way to answer "does it still exist",
  /// and claiming it is gone would be the wrong guess.
  Future<String?> _orphanAssistant(
    Map<String, List<Map<String, Object?>>>? tables,
  ) async {
    final providers = _maybe<AssistantProvider>();
    if (providers == null) return null;
    return orphanAssistantName(
      tables: tables,
      exists: (id) => providers.getById(id) != null,
      fallbackName: _entry.group?.label,
    );
  }

  T? _maybe<T extends Object>() {
    try {
      return context.read<T>();
    } catch (_) {
      return null;
    }
  }

  Future<void> _restore() async {
    final service = _service;
    if (service == null || _busy) return;
    setState(() => _busy = true);
    final RecycleRestoreOutcome? outcome;
    try {
      outcome = await restoreRecycleEntry(
        context,
        service: service,
        entry: _entry,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    // The entry it was showing is retired once its rows are back.
    if (!mounted || outcome != RecycleRestoreOutcome.restored) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  Future<void> _purge() async {
    final service = _service;
    if (service == null || _busy) return;
    setState(() => _busy = true);
    final bool gone;
    try {
      gone = await purgeRecycleEntry(context, service: service, entry: _entry);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted || !gone) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final title = _entry.title.trim().isEmpty
        ? l10n.recycleBinUntitled
        : _entry.title;

    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          size: 22,
          minSize: 44,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: const [SizedBox(width: 6)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                  children: [
                    if (_orphanAssistantName case final name?)
                      _notice(
                        icon: Lucide.TriangleAlert,
                        text: l10n.recycleBinDetailAssistantGone(name),
                        color: cs.error,
                      ),
                    _facts(l10n),
                    const SizedBox(height: 12),
                    _actions(l10n),
                    const SizedBox(height: 18),
                    _content(l10n),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _facts(AppLocalizations l10n) {
    return SectionCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _field(
              l10n.recycleBinDetailOrigin,
              '${_kindLabel(l10n)} · ${_originLabel(l10n)}',
            ),
            _field(
              l10n.recycleBinDetailWhen,
              _stampFormat.format(_entry.deletedAt.toLocal()),
            ),
            _field(l10n.recycleBinDetailSize, formatBytes(_entry.sizeBytes)),
            if (_entry.mtimeMs case final mtimeMs?)
              _field(
                l10n.recycleBinDetailModified,
                _stampFormat.format(
                  DateTime.fromMillisecondsSinceEpoch(mtimeMs).toLocal(),
                ),
              ),
            _field(
              l10n.recycleBinDetailKey,
              _entry.relPath ?? _entry.key,
              mono: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(String label, String value, {bool mono = false}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: cs.onSurface.withValues(alpha: 0.9),
                fontFamily: mono ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        IosTileButton(
          label: l10n.recycleBinRestore,
          icon: Lucide.RotateCcw,
          backgroundColor: cs.primary,
          enabled: !_busy,
          onTap: _restore,
        ),
        IosTileButton(
          label: l10n.recycleBinDeleteForever,
          icon: Lucide.Trash2,
          backgroundColor: cs.error,
          enabled: !_busy,
          onTap: _purge,
        ),
      ],
    );
  }

  Widget _content(AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    final Widget body;
    if (_entry.bodyKind == RecycleBodyKind.byteFile) {
      body = _fileBody(l10n);
    } else if (_tables == null) {
      body = _notice(
        icon: Lucide.TriangleAlert,
        text: l10n.recycleBinDetailUnreadable,
        color: cs.error,
      );
    } else {
      body = _tablesBody(l10n, _tables!);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(
            l10n.recycleBinDetailContent,
            style: TextStyle(
              fontSize: 13,
              fontWeight: AppFontWeights.semibold,
              color: cs.onSurface.withValues(alpha: 0.8),
            ),
          ),
        ),
        body,
      ],
    );
  }

  /// The captured tables as the JSON they are stored as, with one line per
  /// table saying how many rows came with it.
  Widget _tablesBody(
    AppLocalizations l10n,
    Map<String, List<Map<String, Object?>>> tables,
  ) {
    final cs = Theme.of(context).colorScheme;
    // Messages first for a conversation: they are the part a reader recognises.
    const preferred = ['conversation_rows', 'message_rows'];
    final names = [
      for (final name in preferred)
        if (tables.containsKey(name)) name,
      for (final name in tables.keys)
        if (!preferred.contains(name)) name,
    ];
    final json = _pretty.convert({
      for (final name in names) name: tables[name],
    });
    final preview = capRecyclePreview(json);
    final truncated = preview.length < json.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionCard(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final name in names)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontFamily: 'monospace',
                              color: cs.onSurface.withValues(alpha: 0.75),
                            ),
                          ),
                        ),
                        Text(
                          l10n.recycleBinDetailRows(tables[name]!.length),
                          style: TextStyle(
                            fontSize: 12.5,
                            color: cs.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        _jsonBlock(l10n, preview, truncated: truncated, full: json),
      ],
    );
  }

  Widget _jsonBlock(
    AppLocalizations l10n,
    String preview, {
    required bool truncated,
    required String full,
    String? copyLabel,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            preview,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.45,
              fontFamily: 'monospace',
              color: cs.onSurface.withValues(alpha: 0.85),
            ),
          ),
          if (truncated)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l10n.recycleBinDetailTruncated(
                  formatBytes(kRecyclePreviewCapBytes),
                ),
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => copyTextWithConfirmation(
                context,
                full,
                message: l10n.recycleBinDetailCopied,
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                copyLabel ?? l10n.recycleBinDetailCopyJson,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fileBody(AppLocalizations l10n) {
    final bytes = _fileBytes;
    if (bytes == null) {
      return _notice(
        icon: Lucide.TriangleAlert,
        text: l10n.recycleBinDetailUnreadable,
        color: Theme.of(context).colorScheme.error,
      );
    }
    if (!_fileIsText) {
      return _notice(
        icon: Lucide.FileText,
        text: l10n.recycleBinDetailBinary,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
      );
    }
    final text = utf8.decode(bytes);
    final preview = capRecyclePreview(text);
    return _jsonBlock(
      l10n,
      preview,
      truncated: preview.length < text.length,
      full: text,
      // A file's body is the file, not JSON: the same block, named for what it
      // actually copies.
      copyLabel: l10n.recycleBinDetailCopyText,
    );
  }

  Widget _notice({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: color.withValues(alpha: 0.9),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _kindLabel(AppLocalizations l10n) => switch (_entry.type) {
    RecycleEntryType.conversation => l10n.recycleBinKindConversation,
    RecycleEntryType.preference => l10n.recycleBinKindPreference,
    RecycleEntryType.workspaceFile => l10n.recycleBinKindWorkspaceFile,
    RecycleEntryType.businessEntity => switch (_entry.kindWire) {
      'assistant_rows' => l10n.recycleBinKindAssistant,
      'provider_rows' || 'provider_group_rows' => l10n.recycleBinKindProvider,
      'world_book_rows' => l10n.recycleBinKindWorldBook,
      'assistant_memory_rows' ||
      'memory_entry_rows' => l10n.recycleBinKindMemory,
      _ => l10n.recycleBinKindConfig,
    },
  };

  String _originLabel(AppLocalizations l10n) =>
      _entry.reason == RecycleReason.overwritten
      ? l10n.recycleBinReasonOverwritten
      : _entry.origin == RecycleOrigin.remote
      ? l10n.recycleBinOriginRemote
      : l10n.recycleBinOriginLocal;
}
