import 'dart:async';

import 'package:flutter/widgets.dart';

import '../database/business_preferences.dart';
import '../models/backup.dart';
import '../services/backup/auto_snapshot_service.dart';
import '../services/backup/backup_activity_gate.dart';
import '../services/backup/data_sync.dart';
import '../services/chat/chat_service.dart';

/// Outcome of one snapshot attempt, surfaced to the UI for its toast.
enum AutoSnapshotOutcome { created, deduplicated, skipped, failed }

/// Schedules and executes local auto snapshots.
///
/// Trigger model (agreed design): a countdown from the last successful
/// snapshot. While the app is foregrounded a 1-minute ticker checks whether
/// the configured interval has elapsed and fires when it has; cold starts and
/// background resumes recompute the elapsed time through the same check, so a
/// month-long gap produces exactly one catch-up snapshot on open.
class AutoSnapshotProvider extends ChangeNotifier
    with WidgetsBindingObserver {
  AutoSnapshotProvider({
    required this.preferences,
    required this.chatService,
    bool autoLoad = true,
  }) {
    if (autoLoad) {
      unawaited(load());
    }
    WidgetsBinding.instance.addObserver(this);
  }

  static const List<int> presetIntervalMinutes = [720, 1440, 4320, 7200];

  static const String _enabledKey = 'auto_snapshot_enabled_v1';
  static const String _intervalMinutesKey = 'auto_snapshot_interval_minutes_v1';
  static const String _lastSnapshotAtKey = 'auto_snapshot_last_snapshot_at_v1';

  final BusinessPreferences preferences;
  final ChatService chatService;

  late AutoSnapshotService _service;

  bool _loaded = false;
  bool _serviceBuilt = false;
  bool _enabled = false;
  int _intervalMinutes = 1440;
  DateTime? _lastSnapshotAt;
  bool _busy = false;
  String? _lastError;
  List<SnapshotMetadata> _snapshots = const [];
  Timer? _ticker;

  bool get loaded => _loaded;
  bool get enabled => _enabled;
  int get intervalMinutes => _intervalMinutes;
  DateTime? get lastSnapshotAt => _lastSnapshotAt;
  bool get busy => _busy;
  String? get lastError => _lastError;
  List<SnapshotMetadata> get snapshots => List.unmodifiable(_snapshots);

  Future<void> load() async {
    _enabled = preferences.getBool(_enabledKey) ?? false;
    _intervalMinutes = _normalizeInterval(
      preferences.getInt(_intervalMinutesKey) ?? 1440,
    );
    _lastSnapshotAt = _parseDate(preferences.getString(_lastSnapshotAtKey));
    _service = AutoSnapshotService(
      exportBackup: () => DataSync(
        chatService: chatService,
        preferences: preferences,
      ).exportToFile(
        // The snapshot is a local full backup; no remote config is used.
        const WebDavConfig(),
      ),
      assistantCount: _countAssistants,
      conversationCount: _countConversations,
      messageCount: _countMessages,
    );
    _serviceBuilt = true;
    await refreshSnapshots();
    _loaded = true;
    if (_enabled) _startTicker();
    unawaited(_evaluateDue());
    notifyListeners();
  }

  /// Turns the feature off. If [deleteSnapshots] is true (default), all
  /// stored snapshots are removed for good — the UI prompts for this before
  /// calling. The schedule anchor is cleared either way.
  Future<void> setEnabled(bool value, {bool deleteSnapshots = true}) async {
    if (value) {
      _enabled = true;
      await preferences.setBool(_enabledKey, true);
      _startTicker();
      // Baseline snapshot the moment the feature is switched on, so there is
      // always at least one restore point without waiting a full interval.
      unawaited(createSnapshot());
    } else {
      _stopTicker();
      _enabled = false;
      await preferences.setBool(_enabledKey, false);
      _lastSnapshotAt = null;
      await preferences.remove(_lastSnapshotAtKey);
      if (deleteSnapshots && _serviceBuilt) {
        await _service.deleteAllSnapshots();
      }
      await refreshSnapshots();
    }
    notifyListeners();
  }

  Future<void> setIntervalMinutes(int minutes) async {
    _intervalMinutes = _normalizeInterval(minutes);
    await preferences.setInt(_intervalMinutesKey, _intervalMinutes);
    // Changing the cadence does not snapshot immediately; it only recomputes
    // when the next tick is due.
    unawaited(_evaluateDue());
    notifyListeners();
  }

  /// Manual "create snapshot now" — always attempts regardless of schedule.
  Future<AutoSnapshotOutcome> createSnapshot() async {
    if (_busy || BackupActivityGate.active) {
      return AutoSnapshotOutcome.skipped;
    }
    _busy = true;
    notifyListeners();
    try {
      final result = await _service.createSnapshot();
      _lastError = null;
      // The schedule anchor advances on *every* successful attempt — both a
      // created snapshot and a deduplicated skip (identical payload) mean the
      // cadence has been satisfied; only a hard failure keeps the anchor so
      // the next tick retries.
      _lastSnapshotAt = result.status == AutoSnapshotStatus.created
          ? result.metadata!.createdAt
          : DateTime.now();
      await preferences.setString(
        _lastSnapshotAtKey,
        _lastSnapshotAt!.toIso8601String(),
      );
      await refreshSnapshots();
      return result.status == AutoSnapshotStatus.created
          ? AutoSnapshotOutcome.created
          : AutoSnapshotOutcome.deduplicated;
    } catch (e) {
      // Atomic failure: the snapshot store is untouched; only the error is
      // surfaced. The schedule anchor is intentionally not advanced so the
      // next tick retries.
      _lastError = e.toString();
      return AutoSnapshotOutcome.failed;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> refreshSnapshots() async {
    try {
      _snapshots = await _service.listSnapshots();
    } catch (_) {
      _snapshots = const [];
    }
  }

  // ===== Scheduling =====

  void _startTicker() {
    _stopTicker();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_evaluateDue());
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // iOS suspends timers in the background: recompute elapsed time on
      // return, which also covers the "opened after a month" case.
      unawaited(_evaluateDue());
    }
  }

  Future<void> _evaluateDue() async {
    if (!_loaded || !_enabled || _busy) return;
    if (BackupActivityGate.active) return; // retry on the next tick
    final last = _lastSnapshotAt;
    if (last == null ||
        DateTime.now().difference(last) >=
            Duration(minutes: _intervalMinutes)) {
      await createSnapshot();
    }
  }

  // ===== Count providers (cheap reads for the snapshot metadata) =====

  Future<int> _countAssistants() async {
    if (!chatService.initialized) return 0;
    try {
      return (await chatService.getAllAssistants()).length;
    } catch (_) {
      return 0;
    }
  }

  Future<int> _countConversations() async {
    if (!chatService.initialized) return 0;
    try {
      return chatService.repo.getConversationCountSync();
    } catch (_) {
      return 0;
    }
  }

  Future<int> _countMessages() async {
    if (!chatService.initialized) return 0;
    try {
      return chatService.repo.getTotalMessageCountSync();
    } catch (_) {
      return 0;
    }
  }

  static int _normalizeInterval(int minutes) {
    if (presetIntervalMinutes.contains(minutes)) return minutes;
    return presetIntervalMinutes.firstWhere(
      (m) => m >= minutes,
      orElse: () => presetIntervalMinutes.last,
    );
  }

  static DateTime? _parseDate(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return DateTime.parse(raw);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _stopTicker();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

