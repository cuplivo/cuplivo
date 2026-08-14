import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/models/workspace.dart';
import '../../../core/services/workspace/linux_sandbox_service.dart';

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

/// Serialized per-workspace dependency install queue.
///
/// Users may tap "Install" on several dependencies in a row; each workspace
/// runs at most one `apt-get` at a time (apt/dpkg are not concurrency-safe
/// inside one rootfs), and the rest wait in order. Cross-workspace installs
/// are independent (each workspace owns its own rootfs).
class DependencyInstallController extends ChangeNotifier {
  DependencyInstallController({DependencyInstallRunner? installer})
    : _runner = installer ?? LinuxSandboxService.instance.installPackage;

  final DependencyInstallRunner _runner;

  final Map<String, List<_DepEntry>> _queues = <String, List<_DepEntry>>{};
  final Set<String> _running = <String>{};
  final Map<String, _DepEntry> _active = <String, _DepEntry>{};
  final Map<String, Map<String, Object?>> _completed =
      <String, Map<String, Object?>>{};

  /// Enqueue [depId] for [workspaceId]. Duplicate enqueues (queued or
  /// currently installing) are ignored.
  void enqueue({
    required String workspaceId,
    required String depId,
    required String hostPath,
    required DependencyInstallPref pref,
  }) {
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

  Future<void> _pump(String workspaceId) async {
    if (!_running.add(workspaceId)) return;
    try {
      final queue = _queues[workspaceId];
      while (queue != null && queue.isNotEmpty) {
        final entry = queue.removeAt(0);
        _active[workspaceId] = entry;
        entry.status = DepInstallStatus.installing;
        notifyListeners();
        Object? error;
        try {
          await _runner(
            workspaceHostPath: entry.hostPath,
            depId: entry.depId,
            pref: entry.pref,
            onProgress: (p) {
              entry.progress = p.progress;
              entry.stage = p.stage;
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
        }
      }
    } finally {
      _running.remove(workspaceId);
      // The queue list is empty here (loop drained it); drop it so the
      // controller does not accumulate per-workspace entries over the app
      // lifetime. The next enqueue recreates it via putIfAbsent. No awaits
      // below this point, so no enqueue can interleave.
      _queues.remove(workspaceId);
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
