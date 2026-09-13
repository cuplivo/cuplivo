import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/models/workspace.dart';
import '../../../core/services/workspace/linux_sandbox_service.dart';
import '../../../core/services/workspace/workspace_terminal_native_bridge.dart';

/// Per-dependency install state inside a workspace's install queue.
enum DepInstallStatus {
  /// Waiting for the currently running install to finish.
  queued,

  /// Currently being installed by the worker.
  installing,

  /// Not queued and not running (installed or not, decided by probing).
  idle,
}

/// Signature matching `LinuxSandboxService.installPackage`, injectable so the
/// queue can be tested without platform channels.
typedef DependencyInstallRunner =
    Future<void> Function({
      required String workspaceHostPath,
      required String depId,
      required DependencyInstallPref pref,
      void Function(SandboxInstallProgress)? onProgress,
    });

/// Keep-screen-on switch for one workspace queue, injectable so tests can
/// record holds without platform channels. [hold] true = acquire, false =
/// release (ref-counted in the service, so multiple concurrent holders —
/// other workspace queues and the terminal session — compose).
typedef KeepScreenOnSwitch = Future<void> Function(bool hold);

/// Signature matching `LinuxSandboxService.dependencyStatus`, injectable so
/// `refreshSnapshot` can be exercised in tests without platform channels.
typedef DependencyStatusProber =
    Future<SandboxDependencyStatusSnapshot> Function(
      String workspaceHostPath,
    );

/// Serialized per-workspace dependency install queue.
///
/// Users may tap "Install" on several dependencies in a row; each workspace
/// runs at most one `apt-get` at a time (apt/dpkg are not concurrency-safe
/// inside one rootfs), and the rest wait in order. Cross-workspace installs
/// are independent (each workspace owns its own rootfs).
///
/// The queue itself owns the keep-screen-on hold (acquired when a workspace
/// starts pumping, released when its queue drains — success or failure), so
/// a long install keeps the screen on even after the observing detail page
/// is gone, which aggressive One UI app freezing would otherwise stall
/// mid-transaction.
///
/// The controller also caches the last successful dependency snapshot per
/// workspace so the UI's "what's installed" view survives a page rebuild —
/// see [snapshotFor]. Without this, popping back to the workspace list and
/// re-entering the detail page during an in-flight install would briefly
/// blank every dep row back to `未安装` because the probe that populates
/// the page's local state is queued behind the running install in the
/// shared workspace execution FIFO.
class DependencyInstallController extends ChangeNotifier {
  DependencyInstallController({
    DependencyInstallRunner? installer,
    KeepScreenOnSwitch? keepScreenOn,
    DependencyStatusProber? prober,
    Future<void> Function(String workspaceHostPath)? beforeBaseMutation,
  }) : _runner = installer ?? LinuxSandboxService.instance.installPackage,
       _keepScreenOn = keepScreenOn ?? _serviceKeepScreenOn,
       _prober = prober ?? LinuxSandboxService.instance.dependencyStatus,
       _beforeBaseMutation =
           beforeBaseMutation ??
           WorkspaceTerminalNativeBridge.instance.stopSessionForWorkspacePath;

  static Future<void> _serviceKeepScreenOn(bool hold) => hold
      ? LinuxSandboxService.instance.acquireKeepScreenOn()
      : LinuxSandboxService.instance.releaseKeepScreenOn();

  final DependencyInstallRunner _runner;
  final KeepScreenOnSwitch _keepScreenOn;
  final DependencyStatusProber _prober;
  final Future<void> Function(String workspaceHostPath) _beforeBaseMutation;

  final Map<String, List<_DepEntry>> _queues = <String, List<_DepEntry>>{};
  final Set<String> _running = <String>{};
  final Map<String, _DepEntry> _active = <String, _DepEntry>{};
  final Map<String, Map<String, Object?>> _completed =
      <String, Map<String, Object?>>{};
  final Map<String, Set<String>> _notices = <String, Set<String>>{};

  /// Last successful dependency probe snapshot per workspace, or null until
  /// the first probe lands. Owning the snapshot here (not on the detail
  /// page) is what stops the dep list from briefly flipping back to
  /// "未安装" while an install is still in progress: when the detail page
  /// is rebuilt (e.g. user pops back to the workspace list and re-enters)
  /// the new page instance reads the cached snapshot synchronously, so
  /// base shows `已安装 ✓` instead of the stale empty map that triggered
  /// the red `请先安装基础依赖` hint.
  final Map<String, SandboxDependencyStatusSnapshot> _snapshotsByWorkspace =
      <String, SandboxDependencyStatusSnapshot>{};

  /// Per-workspace generation counter for in-flight `refreshSnapshot`
  /// calls. Bumped on entry; if the in-flight probe completes after a
  /// newer generation was started, the older result is discarded so the
  /// UI never applies a stale snapshot.
  final Map<String, int> _snapshotGenerationByWorkspace =
      <String, int>{};

  /// True while a `refreshSnapshot` probe is queued or running for the
  /// workspace. Drives the disabled state of the retry button in the
  /// detail page's probe-error banner.
  final Map<String, bool> _snapshotLoadingByWorkspace = <String, bool>{};

  /// True if the most recent probe attempt for the workspace threw.
  /// Distinct from "no snapshot yet" — null here means we have never
  /// tried to probe this workspace, true means the last attempt failed.
  final Map<String, bool> _snapshotProbeFailedByWorkspace =
      <String, bool>{};

  /// Last host path observed for a workspace (via [enqueue] or an
  /// explicit `refreshSnapshot(hostPath: ...)`). Used by the post-install
  /// auto-refresh so callers don't have to thread the path through every
  /// `enqueue` consumer.
  final Map<String, String> _lastHostPathByWorkspace = <String, String>{};

  /// Drop every cached piece of state for [workspaceId]. Called from the
  /// workspace deletion path so the controller does not leak entries for
  /// workspaces that no longer exist (and, more importantly, does not
  /// serve a stale "base installed" snapshot to a freshly-created
  /// workspace that happens to reuse the id — see review issue on the
  /// dep-status PR).
  void forgetWorkspace(String workspaceId) {
    final hadSnapshot = _snapshotsByWorkspace.remove(workspaceId) != null;
    _snapshotGenerationByWorkspace.remove(workspaceId);
    _snapshotLoadingByWorkspace.remove(workspaceId);
    _snapshotProbeFailedByWorkspace.remove(workspaceId);
    _lastHostPathByWorkspace.remove(workspaceId);
    if (hadSnapshot) notifyListeners();
  }

  /// Snapshot of which deps are installed for [workspaceId], or null if no
  /// probe has ever succeeded for that workspace. Survives page rebuilds
  /// — see [_snapshotsByWorkspace].
  SandboxDependencyStatusSnapshot? snapshotFor(String workspaceId) =>
      _snapshotsByWorkspace[workspaceId];

  /// True while a refresh probe for [workspaceId] is queued or running.
  bool isLoadingSnapshotFor(String workspaceId) =>
      _snapshotLoadingByWorkspace[workspaceId] ?? false;

  /// True if the last probe attempt for [workspaceId] threw and we still
  /// have no fresh snapshot. False on success or when no probe has been
  /// attempted yet.
  bool didLastSnapshotProbeFailFor(String workspaceId) =>
      _snapshotProbeFailedByWorkspace[workspaceId] ?? false;

  /// Refresh the cached snapshot for [workspaceId] by running the
  /// dependency probe in the sandbox. No-op if neither [hostPath] nor a
  /// previously seen host path is available (i.e. the workspace has never
  /// been enqueued and the caller didn't supply a path). Bumps the
  /// per-workspace generation so any older in-flight probe is ignored.
  ///
  /// Coalesces concurrent calls for the same workspace + host path: while
  /// a probe is already in flight, additional `refreshSnapshot` requests
  /// for the same path are skipped instead of piling onto the shared
  /// per-workspace execution FIFO (which would serialize behind the
  /// running install and surface as multi-second UI stalls).
  Future<void> refreshSnapshot({
    required String workspaceId,
    String? hostPath,
  }) async {
    final path = hostPath ?? _lastHostPathByWorkspace[workspaceId];
    if (path == null) return;
    if (_snapshotLoadingByWorkspace[workspaceId] == true &&
        _lastHostPathByWorkspace[workspaceId] == path) {
      // A probe for this workspace/path is already in flight; don't pile
      // a second one onto the shared execution FIFO.
      return;
    }
    if (hostPath != null) _lastHostPathByWorkspace[workspaceId] = hostPath;
    final generation = (_snapshotGenerationByWorkspace[workspaceId] ?? 0) + 1;
    _snapshotGenerationByWorkspace[workspaceId] = generation;
    _snapshotLoadingByWorkspace[workspaceId] = true;
    notifyListeners();
    try {
      final snapshot = await _prober(path);
      if (generation != _snapshotGenerationByWorkspace[workspaceId]) return;
      _snapshotsByWorkspace[workspaceId] = snapshot;
      _snapshotLoadingByWorkspace[workspaceId] = false;
      _snapshotProbeFailedByWorkspace[workspaceId] = false;
      notifyListeners();
    } catch (e, stackTrace) {
      debugPrint(
        'DependencyInstallController.refreshSnapshot: $e\n$stackTrace',
      );
      if (generation != _snapshotGenerationByWorkspace[workspaceId]) return;
      _snapshotLoadingByWorkspace[workspaceId] = false;
      // Queue saturation and cancellation are transient queueing artefacts
      // (the shared per-workspace FIFO throws SandboxBusyException when
      // >4 requests pile up, and SandboxCancelledException when the user
      // cancels the in-flight install). Neither is a status the user can
      // act on — surfacing them as `probe failed` would disable every
      // install button and render the red error banner until the user
      // taps Retry, with no actual error to retry against. Keep the last
      // good snapshot in place and only flip the flag on real probe
      // failures.
      final transient =
          e is SandboxBusyException || e is SandboxCancelledException;
      _snapshotProbeFailedByWorkspace[workspaceId] = !transient;
      notifyListeners();
    }
  }

  /// Enqueue [depId] for [workspaceId]. Duplicate enqueues (queued or
  /// currently installing) are ignored.
  void enqueue({
    required String workspaceId,
    required String depId,
    required String hostPath,
    required DependencyInstallPref pref,
  }) {
    _lastHostPathByWorkspace[workspaceId] = hostPath;
    if (_active[workspaceId]?.depId == depId) return;
    final queue = _queues.putIfAbsent(workspaceId, () => <_DepEntry>[]);
    if (queue.any((e) => e.depId == depId)) return;
    queue.add(_DepEntry(depId: depId, hostPath: hostPath, pref: pref));
    notifyListeners();
    unawaited(_pump(workspaceId));
  }

  DepInstallStatus statusFor(String workspaceId, String depId) {
    final active = _active[workspaceId];
    if (active != null && active.depId == depId) return active.status;
    for (final e in _queues[workspaceId] ?? const <_DepEntry>[]) {
      if (e.depId == depId) return e.status;
    }
    return DepInstallStatus.idle;
  }

  /// 0-1 download progress of the running install, null otherwise.
  double? progressFor(String workspaceId, String depId) {
    final active = _active[workspaceId];
    if (active != null && active.depId == depId) return active.progress;
    return null;
  }

  /// Stage label of the running install (`downloading`, `extracting`,
  /// `recover`, `update`, `install`, ...), null otherwise.
  String? stageFor(String workspaceId, String depId) {
    final active = _active[workspaceId];
    if (active != null && active.depId == depId) return active.stage;
    return null;
  }

  /// Deps that finished (success or failure) since the last call, keyed by
  /// depId with the captured error (null = success).
  Map<String, Object?> takeCompleted(String workspaceId) {
    final done = _completed.remove(workspaceId);
    return done ?? const <String, Object?>{};
  }

  /// Non-fatal, user-visible notices captured since the last call (see
  /// [SandboxInstallProgress.notice]).
  Set<String> takeNotices(String workspaceId) {
    final notices = _notices.remove(workspaceId);
    return notices ?? const <String>{};
  }

  Future<void> _pump(String workspaceId) async {
    if (!_running.add(workspaceId)) return;
    try {
      try {
        await _keepScreenOn(true);
      } catch (e) {
        // The hold failing must not abort installs: the queue can still
        // work, it just stops keeping the screen up.
        debugPrint(
          'DependencyInstallController: keep-screen-on acquire failed: $e',
        );
      }
      final queue = _queues[workspaceId];
      while (queue != null && queue.isNotEmpty) {
        final entry = queue.removeAt(0);
        _active[workspaceId] = entry;
        entry.status = DepInstallStatus.installing;
        notifyListeners();
        Object? error;
        try {
          if (entry.depId == WorkspaceDependencyIds.base) {
            try {
              await _beforeBaseMutation(entry.hostPath);
            } catch (error) {
              throw WorkspaceTerminalStopException(error);
            }
          }
          await _runner(
            workspaceHostPath: entry.hostPath,
            depId: entry.depId,
            pref: entry.pref,
            onProgress: (p) {
              entry.progress = p.progress;
              entry.stage = p.stage;
              final notice = p.notice;
              if (notice != null) {
                _notices.putIfAbsent(workspaceId, () => <String>{}).add(notice);
              }
              notifyListeners();
            },
          );
        } catch (e) {
          error = e;
          debugPrint(
            'DependencyInstallController: ${entry.depId} install failed: $e',
          );
        } finally {
          entry.progress = null;
          entry.stage = null;
          entry.status = DepInstallStatus.idle;
          _completed.putIfAbsent(
            workspaceId,
            () => <String, Object?>{},
          )[entry.depId] = error;
          _active.remove(workspaceId);
          notifyListeners();
          // Re-probe on every install completion so the cached snapshot
          // reflects the new state without the observing page having to
          // poll. This survives page rebuilds (the cached snapshot lives
          // on the controller, not the page state) which is what closes
          // the "install ran while the detail page was away → UI shows
          // stale `未安装` on remount" gap.
          unawaited(
            refreshSnapshot(
              workspaceId: workspaceId,
              hostPath: entry.hostPath,
            ),
          );
        }
      }
    } finally {
      // Hand worker ownership back BEFORE the asynchronous release: an
      // enqueue landing while `_keepScreenOn(false)` is awaiting the method
      // channel must create a fresh queue and start its own pump, not be
      // appended to a queue this pump is about to delete (review race: a
      // dep enqueued during the release window was left idle forever).
      _running.remove(workspaceId);
      // The queue list is empty here (loop drained it); drop it so the
      // controller does not accumulate per-workspace entries over the app
      // lifetime. The next enqueue recreates it via putIfAbsent.
      _queues.remove(workspaceId);
      try {
        await _keepScreenOn(false);
      } catch (e) {
        debugPrint(
          'DependencyInstallController: keep-screen-on release failed: $e',
        );
      }
    }
  }
}

class _DepEntry {
  _DepEntry({required this.depId, required this.hostPath, required this.pref});

  final String depId;
  final String hostPath;
  final DependencyInstallPref pref;
  DepInstallStatus status = DepInstallStatus.queued;
  double? progress;
  String? stage;
}
