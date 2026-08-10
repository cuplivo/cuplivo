import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/models/chat_input_data.dart';

/// Persists the chat input bar's unsent content (`text` + media) across app
/// restarts, under the single global key `chat_draft_v1`.
///
/// Owns the 800ms debounced writes and the lifecycle immediate flush. The
/// draft is preloaded synchronously at startup (see [ensureInitialized],
/// called from `main()` right after the SharedPreferences handle is ready),
/// so restore at input-bar mount is race-free: the event loop cannot deliver
/// user input before the first frame.
class InputDraftPersistence with WidgetsBindingObserver {
  /// Public so tests can construct isolated instances with a mock prefs
  /// handle. The process-wide instance is created by [ensureInitialized].
  ///
  /// A null [prefs] yields a degraded no-op instance: the draft feature is
  /// unavailable this session (startup SharedPreferences failure), every
  /// method is a no-op and restore returns null — never a crash.
  InputDraftPersistence(this._prefs) {
    WidgetsBinding.instance.addObserver(this);
    _preloadedDraft = _readFromPrefs();
  }

  static const String key = chatInputDraftPrefsKey;
  static const Duration debounceDuration = Duration(milliseconds: 800);

  static InputDraftPersistence? _instance;

  /// The process-wide instance, installed by [ensureInitialized] in `main()`.
  static InputDraftPersistence get instance {
    final i = _instance;
    if (i == null) {
      throw StateError(
        'InputDraftPersistence.ensureInitialized() must be called before '
        'accessing instance',
      );
    }
    return i;
  }

  /// Loads the persisted draft (if any) and installs the process-wide
  /// instance. Must complete before `runApp` for the no-race restore
  /// guarantee. On SharedPreferences failure the app degrades to a no-op
  /// instance instead of dying before `runApp`.
  static Future<void> ensureInitialized() async {
    try {
      _instance ??= InputDraftPersistence(
        await SharedPreferences.getInstance(),
      );
    } catch (e, st) {
      debugPrint(
        '[InputDraftPersistence] prefs unavailable, draft disabled: $e\n$st',
      );
      _instance ??= InputDraftPersistence(null);
    }
  }

  final SharedPreferences? _prefs;
  ChatInputData? _preloadedDraft;
  ChatInputData? _pending;
  Timer? _debounce;
  bool _disposed = false;

  /// Cold-start restore handle. Consumed once per process: a second call (or
  /// a later input-bar remount, e.g. a desktop window recreate) returns null.
  ChatInputData? takeDraftForRestore() {
    if (_prefs == null) return null;
    final draft = _preloadedDraft;
    _preloadedDraft = null;
    return draft;
  }

  /// Debounced save of the latest input-bar content. Empty content removes
  /// the persisted key instead of storing an empty blob.
  void save(ChatInputData input) {
    if (_disposed || _prefs == null) return;
    _pending = input;
    _debounce?.cancel();
    _debounce = Timer(debounceDuration, flushNow);
  }

  /// Immediate removal. Send success / queued-send and bar clears all go
  /// through here so a process death right after sending cannot resurrect
  /// the draft. Best-effort: the underlying prefs write is async
  /// fire-and-forget, so a kill inside the platform-channel write window
  /// can still leave the stale key behind.
  void clearNow() {
    if (_disposed || _prefs == null) return;
    _debounce?.cancel();
    _debounce = null;
    _pending = null;
    _preloadedDraft = null;
    _prefs.remove(key);
  }

  /// Writes any pending debounced content immediately (lifecycle save).
  /// Best-effort like all other writes: fire-and-forget async.
  void flushNow() {
    if (_disposed || _prefs == null) return;
    _debounce?.cancel();
    _debounce = null;
    final content = _pending;
    if (content == null) return;
    _pending = null;
    _write(content);
  }

  /// Files (image paths + document paths) referenced by the unsent draft —
  /// the union of the pending in-memory content and the persisted snapshot.
  /// Used by the storage deletion guardrail (warn-and-allow).
  Set<String> draftReferencedFiles() {
    if (_prefs == null) return const <String>{};
    final files = <String>{};
    final preloaded = _preloadedDraft;
    if (preloaded != null) {
      files.addAll(preloaded.imagePaths);
      files.addAll(preloaded.documents.map((d) => d.path));
    }
    final pending = _pending;
    if (pending != null) {
      files.addAll(pending.imagePaths);
      files.addAll(pending.documents.map((d) => d.path));
    }
    final persisted = _readFromPrefs();
    if (persisted != null) {
      files.addAll(persisted.imagePaths);
      files.addAll(persisted.documents.map((d) => d.path));
    }
    return files;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Any transition away from resumed (paused/inactive/hidden/detached)
    // flushes a pending debounced write immediately.
    if (state != AppLifecycleState.resumed) {
      flushNow();
    }
  }

  void disposeInternal() {
    if (_disposed) return;
    _disposed = true;
    _debounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }

  void _write(ChatInputData input) {
    final prefs = _prefs;
    if (prefs == null) return;
    final empty =
        input.text.trim().isEmpty &&
        input.imagePaths.isEmpty &&
        input.documents.isEmpty;
    if (empty) {
      prefs.remove(key);
      return;
    }
    prefs.setString(key, _encode(input));
  }

  static String _encode(ChatInputData input) {
    return jsonEncode({
      'text': input.text,
      'images': input.imagePaths,
      'documents': [
        for (final d in input.documents)
          {'path': d.path, 'fileName': d.fileName, 'mime': d.mime},
      ],
    });
  }

  ChatInputData? _readFromPrefs() {
    final prefs = _prefs;
    if (prefs == null) return null;
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    final parsed = _decode(raw);
    if (parsed == null) {
      debugPrint('[InputDraftPersistence] corrupt draft removed: $key');
      prefs.remove(key);
    }
    return parsed;
  }

  static ChatInputData? _decode(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return null;
      final text = map['text'];
      final images = map['images'];
      final documents = map['documents'];
      final parsedDocs = documents is List
          ? documents
                .whereType<Map<String, dynamic>>()
                .map(
                  (d) => DocumentAttachment(
                    path: (d['path'] as String?) ?? '',
                    fileName: (d['fileName'] as String?) ?? '',
                    mime: (d['mime'] as String?) ?? '',
                  ),
                )
                .where((d) => d.path.isNotEmpty)
                .toList()
          : const <DocumentAttachment>[];
      return ChatInputData(
        text: text is String ? text : '',
        imagePaths: images is List
            ? images.whereType<String>().toList()
            : const <String>[],
        documents: parsedDocs,
      );
    } catch (e) {
      debugPrint('[InputDraftPersistence] draft decode failed: $e');
      return null;
    }
  }
}
