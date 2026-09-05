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

/// One-shot outcome carried from an automatic snapshot attempt (baseline or
/// due tick) to the UI. The page consumes it exactly once: [pendingNotice]
/// reads the latest un-consumed notice, [consumeNotice] clears it so a page
/// rebuild or re-mount never re-displays the same toast.
class AutoSnapshotNotice {
  const AutoSnapshotNotice(this.outcome, this.error);

  final AutoSnapshotOutcome outcome;

  /// Populated when [outcome] is [AutoSnapshotOutcome.failed].
  final String? error;
}

/// Schedules and executes local auto snapshots.
///
/// Trigger model (agreed design): a countdown from the last successful
/// snapshot. While the app is foregrounded a 1-minute ticker checks whether
/// the configured interval has elapsed and fires when it has; cold starts and
/// background resumes recompute the elapsed time through the same check, so a
/// month-long gap produces exactly one catch-up snapshot on open.
class AutoSnapshotProvider extends ChangeNotifier with WidgetsBindingObserver {
  AutoSnapshotProvider({
    required this.preferences,
    required this.chatService,
    bool autoLoad = true,
    this.serviceFactory,
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

  /// Overrides service construction — a test seam for providers that need to
  /// observe or control snapshot timing. Null in production.
  final AutoSnapshotService Function()? serviceFactory;

  late AutoSnapshotService _service;

  bool _loaded = false;
  bool _serviceBuilt = false;
  bool _enabled = false;
  int _intervalMinutes = 1440;
  DateTime? _lastSnapshotAt;
  bool _busy = false;
  bool _teardown = false;
  Future<AutoSnapshotOutcome>? _inflight;
  String? _lastError;
  AutoSnapshotNotice? _pendingNotice;
  List<SnapshotMetadata> _snapshots = const [];
  Object? _listError;
  Timer? _ticker;

  /// Serializes [setEnabled] transitions (FIFO); the stored future is the
  /// error-swallowed chain, so a failed transition never dead-locks the next
  /// toggle, while each caller awaits the real [setEnabled] future.
  Future<void>? _transition;

  bool get loaded => _loaded;
  bool get enabled => _enabled;
  int get intervalMinutes => _intervalMinutes;
  DateTime? get lastSnapshotAt => _lastSnapshotAt;
  bool get busy => _busy;
  String? get lastError => _lastError;
  AutoSnapshotNotice? get pendingNotice => _pendingNotice;
  List<SnapshotMetadata> get snapshots => List.unmodifiable(_snapshots);

  /// Set when the last listing failed: [snapshots] then holds the last known
  /// state and must NOT be treated as "no snapshots" (used by the page to
  /// require confirmation before a destructive delete).
  Object? get listError => _listError;

  Future<void> load() async {
    _enabled = preferences.getBool(_enabledKey) ?? false;
    _intervalMinutes = _normalizeInterval(
      preferences.getInt(_intervalMinutesKey) ?? 1440,
    );
    _lastSnapshotAt = _parseDate(preferences.getString(_lastSnapshotAtKey));
    _service =
        serviceFactory?.call() ??
        AutoSnapshotService(
          exportBackup: () =>
              DataSync(
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

  /// Turns the feature on or off. If [value] is false and [deleteSnapshots]
  /// is true (default), all stored snapshots are removed for good — the UI
  /// prompts for this before calling. The schedule anchor is cleared either
  /// way.
  ///
  /// Transitions are FIFO-serialized through [_transition]: an enable issued
  /// while a disable (teardown) is still awaiting an in-flight create, gate,
  /// or deletion does not touch any state until the disable fully completes,
  /// and then runs its own full lifecycle — persisted key, ticker, and the
  /// baseline snapshot — so the last accepted toggle owns both persisted
  /// state and the baseline guarantee.
  ///
  /// Lifecycle guarantee (disable): [createSnapshot] is rejected from the
  /// moment the teardown starts ([_teardown] is set synchronously and
  /// re-checked inside the gate), the previous in-flight attempt is awaited,
  /// and the deletion itself runs under the same [BackupActivityGate] as
  /// every create path — so no snapshot can be written before or after the
  /// delete. A failed deletion throws (the feature stays off and the
  /// remaining store stays restorable; the caller surfaces the error).
  Future<void> setEnabled(bool value, {bool deleteSnapshots = true}) {
    final prev = _transition;
    final next = prev == null
        ? _applySetEnabled(value, deleteSnapshots: deleteSnapshots)
        : prev.then(
            (_) => _applySetEnabled(value, deleteSnapshots: deleteSnapshots),
          );
    // The chain itself never fails — a throwing transition would otherwise
    // dead-lock every later toggle. Callers still see the real outcome
    // through `next`.
    _transition = next.catchError((_) {});
    return next;
  }

  Future<void> _applySetEnabled(
    bool value, {
    bool deleteSnapshots = true,
  }) async {
    // Runtime idempotence: a queued transition may find the state already at
    // the requested value (e.g. enable+disable+enable stacking) — only the
    // first no-op-on-change transition run matters. Because failures roll the
    // mutated fields back (or — enable — commit durability before publishing
    // the in-memory state), a failed transition never leaves the state at the
    // requested value, so a retry always passes this guard.
    if (value == _enabled) return;
    if (value) {
      // Durable first: if the write is rejected the in-memory state stays
      // off, no ticker/baseline was started, and a retry is accepted — no
      // split where the UI reports enabled but persistence says disabled.
      await preferences.setBool(_enabledKey, true);
      _enabled = true;
      _startTicker();
      // Baseline snapshot the moment the feature is switched on, so there is
      // always at least one restore point without waiting a full interval.
      unawaited(createSnapshot().then(_setAutoNotice));
    } else {
      // Publish the off-state synchronously first — it is what blocks new
      // create attempts — then make the durable write; on failure roll the
      // in-memory state back so the transition stays retryable and the
      // persisted key (still true) matches. The persist-failure window is
      // safe on its own: createSnapshot is guarded by `!_enabled`.
      _enabled = false;
      notifyListeners();
      try {
        await preferences.setBool(_enabledKey, false);
      } catch (e) {
        _enabled = true;
        notifyListeners();
        rethrow;
      }
      _stopTicker();
      _teardown = true;
      var cleanupFailed = false;
      try {
        final inflight = _inflight;
        if (inflight != null) {
          // createSnapshot never throws on its own — failures surface as
          // AutoSnapshotOutcome.failed — so awaiting is always safe. This
          // awaits any attempt that cleared the _teardown check before we
          // set it; attempts after it are already rejected.
          await inflight;
        }
        _lastSnapshotAt = null;
        await preferences.remove(_lastSnapshotAtKey);
        if (deleteSnapshots && _serviceBuilt) {
          await BackupActivityGate.scoped(() => _service.deleteAllSnapshots());
        }
      } catch (e) {
        // The confirmed cleanup (anchor removal / permanent delete) did not
        // finish. The disable as a whole must fail — not a half-disabled
        // state the user can never re-invoke from the switch. Roll back to
        // enabled so tapping the switch off again retries the same intent
        // (remove/deleteAll are idempotent, and the confirmation dialog is
        // shown again, re-establishing consent).
        cleanupFailed = true;
        rethrow;
      } finally {
        _teardown = false;
        if (cleanupFailed) {
          _enabled = true;
          try {
            await preferences.setBool(_enabledKey, true);
          } catch (_) {
            // Best effort: the durable key stays false (restart will keep
            // the feature off), but the in-memory state keeps a retry
            // possible in-session.
          }
          _startTicker();
        }
        await refreshSnapshots();
        notifyListeners();
      }
    }
  }

  /// Consumes the pending automatic-attempt notice so the UI shows it once.
  void consumeNotice() {
    if (_pendingNotice == null) return;
    _pendingNotice = null;
  }

  /// Stashes the outcome of an automatic attempt (baseline, due tick) as a
  /// one-shot notice for the page. Manual attempts keep using their return
  /// value so the page does not get a duplicate toast. Skips when the attempt
  /// never got to run (gate busy / teardown).
  void _setAutoNotice(AutoSnapshotOutcome outcome) {
    if (outcome == AutoSnapshotOutcome.skipped) return;
    _pendingNotice = AutoSnapshotNotice(outcome, _lastError);
    notifyListeners();
  }

  Future<void> setIntervalMinutes(int minutes) async {
    // Durable first, same failure-safety rule as setEnabled: a rejected
    // write must leave the published interval untouched and the transition
    // retryable.
    final normalized = _normalizeInterval(minutes);
    await preferences.setInt(_intervalMinutesKey, normalized);
    _intervalMinutes = normalized;
    // Changing the cadence does not snapshot immediately; it only recomputes
    // when the next tick is due.
    unawaited(_evaluateDue());
    notifyListeners();
  }

  /// Manual "create snapshot now" — always attempts regardless of schedule.
  ///
  /// Rejected (returns [AutoSnapshotOutcome.skipped]) while a teardown is in
  /// flight, while the feature is off, while another attempt is busy, or when
  /// the activity gate is held by another backup-family operation. The
  /// [_teardown] rejection windows cannot be slipped: the check passes into
  /// the gate synchronously (no await between here and [_inflight] being
  /// set), and is re-checked as the first thing inside the scoped action.
  Future<AutoSnapshotOutcome> createSnapshot() async {
    if (_teardown || !_enabled || _busy || BackupActivityGate.active) {
      return AutoSnapshotOutcome.skipped;
    }
    _busy = true;
    notifyListeners();
    final future = BackupActivityGate.scoped(_createSnapshotInternal);
    _inflight = future;
    try {
      return await future;
    } finally {
      _inflight = null;
      _busy = false;
      notifyListeners();
    }
  }

  Future<AutoSnapshotOutcome> _createSnapshotInternal() async {
    if (_teardown) {
      // A teardown began after this attempt cleared the entry check (only
      // possible for an attempt queued behind the gate) — aborted here, the
      // disable flow owns the store from now on.
      return AutoSnapshotOutcome.skipped;
    }
    // Phase 1: the store work. A throw here means nothing was committed —
    // this is the only path that is a hard failure for the attempt.
    final AutoSnapshotResult result;
    try {
      result = await _service.createSnapshot();
    } catch (e) {
      // Atomic failure: the snapshot store is untouched; only the error is
      // surfaced. The schedule anchor is not touched so the next tick
      // retries.
      _lastError = e.toString();
      return AutoSnapshotOutcome.failed;
    }
    // Phase 2: the store DID change (or was deduplicated — which also evicts
    // over-cap pairs since the repair fix). The cadence anchor persistence is
    // a separate outcome from the snapshot itself: a failed anchor write
    // must not report the committed snapshot as failed, must keep the list
    // truthful, and must leave scheduling state so persistence is retried on
    // the next (cheap dedup) attempt.
    _lastError = null;
    final anchor = result.status == AutoSnapshotStatus.created
        ? result.metadata!.createdAt
        : DateTime.now();
    final previousAnchor = _lastSnapshotAt;
    _lastSnapshotAt = anchor;
    try {
      await preferences.setString(_lastSnapshotAtKey, anchor.toIso8601String());
    } catch (e) {
      debugPrint(
        '[AutoSnapshotProvider] anchor persistence failed (snapshot is '
        'committed): $e',
      );
      // Restore the previous anchor so the next due tick re-attempts the
      // durable write as a dedup, instead of waiting a full interval while
      // scheduling state and persistence disagree.
      _lastSnapshotAt = previousAnchor;
    }
    await refreshSnapshots();
    return result.status == AutoSnapshotStatus.created
        ? AutoSnapshotOutcome.created
        : AutoSnapshotOutcome.deduplicated;
  }

  Future<void> refreshSnapshots() async {
    try {
      _snapshots = await _service.listSnapshots();
      _listError = null;
    } catch (e) {
      // Keep the last known list: an unknown store must never be presented
      // as "no snapshots", or the page would skip deletion consent.
      _listError = e;
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
      final outcome = await createSnapshot();
      _setAutoNotice(outcome);
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
