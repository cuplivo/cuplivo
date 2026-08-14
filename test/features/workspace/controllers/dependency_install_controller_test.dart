import 'dart:async';

import 'package:Cuplivo/core/models/workspace.dart';
import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:Cuplivo/features/workspace/controllers/dependency_install_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake installer that records concurrency and order. Each dep can be gated
/// on a completer so tests observe the queue deterministically mid-run.
class _FakeInstaller {
  final List<String> order = <String>[];
  final List<String> hostPaths = <String>[];
  final List<DependencyInstallPref> prefs = <DependencyInstallPref>[];
  int maxConcurrent = 0;
  int concurrent = 0;
  final Map<String, Object?> failures = <String, Object?>{};
  final Map<String, Completer<void>> gate = <String, Completer<void>>{};

  Future<void> call({
    required String workspaceHostPath,
    required String depId,
    required DependencyInstallPref pref,
    void Function(SandboxInstallProgress)? onProgress,
  }) async {
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    order.add(depId);
    hostPaths.add(workspaceHostPath);
    prefs.add(pref);
    try {
      onProgress?.call(SandboxInstallProgress(stage: 'install', progress: 0.5));
      final g = gate[depId];
      if (g != null) await g.future;
      final fail = failures[depId];
      if (fail != null) throw StateError(fail.toString());
    } finally {
      concurrent--;
    }
  }
}

Future<void> _pumpUntil(bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'timed out waiting for condition');
}

void main() {
  const wsId = 'workspace_default';
  const pref = DependencyInstallPref(sourceId: 'official');

  test('runs enqueued deps serially in FIFO order', () async {
    final fake = _FakeInstaller()
      ..gate[WorkspaceDependencyIds.nodejs] = Completer<void>()
      ..gate[WorkspaceDependencyIds.git] = Completer<void>()
      ..gate[WorkspaceDependencyIds.python] = Completer<void>();
    final controller = DependencyInstallController(installer: fake.call);

    controller.enqueue(
      workspaceId: wsId,
      depId: WorkspaceDependencyIds.nodejs,
      hostPath: '/ws',
      pref: pref,
    );
    controller.enqueue(
      workspaceId: wsId,
      depId: WorkspaceDependencyIds.git,
      hostPath: '/ws',
      pref: pref,
    );
    controller.enqueue(
      workspaceId: wsId,
      depId: WorkspaceDependencyIds.python,
      hostPath: '/ws',
      pref: pref,
    );

    expect(
      controller.statusFor(wsId, WorkspaceDependencyIds.nodejs),
      DepInstallStatus.installing,
    );
    expect(
      controller.statusFor(wsId, WorkspaceDependencyIds.git),
      DepInstallStatus.queued,
    );
    expect(
      controller.statusFor(wsId, WorkspaceDependencyIds.python),
      DepInstallStatus.queued,
    );
    expect(fake.maxConcurrent, 1);
    expect(fake.order, [WorkspaceDependencyIds.nodejs]);

    fake.gate[WorkspaceDependencyIds.nodejs]!.complete();
    await _pumpUntil(
      () =>
          controller.statusFor(wsId, WorkspaceDependencyIds.git) ==
          DepInstallStatus.installing,
    );
    expect(
      controller.statusFor(wsId, WorkspaceDependencyIds.python),
      DepInstallStatus.queued,
    );
    expect(fake.maxConcurrent, 1);
    expect(fake.order, [
      WorkspaceDependencyIds.nodejs,
      WorkspaceDependencyIds.git,
    ]);

    fake.gate[WorkspaceDependencyIds.git]!.complete();
    await _pumpUntil(
      () =>
          controller.statusFor(wsId, WorkspaceDependencyIds.python) ==
          DepInstallStatus.installing,
    );
    expect(fake.maxConcurrent, 1);

    fake.gate[WorkspaceDependencyIds.python]!.complete();
    await _pumpUntil(
      () =>
          controller.statusFor(wsId, WorkspaceDependencyIds.python) ==
          DepInstallStatus.idle,
    );
    expect(fake.maxConcurrent, 1);
    expect(fake.order, [
      WorkspaceDependencyIds.nodejs,
      WorkspaceDependencyIds.git,
      WorkspaceDependencyIds.python,
    ]);
    // The runner must receive the exact host path and pref per workspace.
    expect(fake.hostPaths, ['/ws', '/ws', '/ws']);
    expect(fake.prefs, [pref, pref, pref]);
    final completed = controller.takeCompleted(wsId);
    expect(completed, containsPair(WorkspaceDependencyIds.nodejs, isNull));
  });

  test('duplicate enqueue of the same dep is ignored', () async {
    final fake = _FakeInstaller();
    final controller = DependencyInstallController(installer: fake.call);

    controller.enqueue(
      workspaceId: wsId,
      depId: WorkspaceDependencyIds.git,
      hostPath: '/ws',
      pref: pref,
    );
    controller.enqueue(
      workspaceId: wsId,
      depId: WorkspaceDependencyIds.git,
      hostPath: '/ws',
      pref: pref,
    );
    await _pumpUntil(
      () =>
          controller.statusFor(wsId, WorkspaceDependencyIds.git) ==
          DepInstallStatus.idle,
    );
    expect(fake.order, [WorkspaceDependencyIds.git]);
  });

  test('a failing dep does not block later queued deps', () async {
    final fake = _FakeInstaller()
      ..failures[WorkspaceDependencyIds.nodejs] = 'apt lock held';
    final controller = DependencyInstallController(installer: fake.call);

    controller.enqueue(
      workspaceId: wsId,
      depId: WorkspaceDependencyIds.nodejs,
      hostPath: '/ws',
      pref: pref,
    );
    controller.enqueue(
      workspaceId: wsId,
      depId: WorkspaceDependencyIds.git,
      hostPath: '/ws',
      pref: pref,
    );
    await _pumpUntil(
      () =>
          controller.statusFor(wsId, WorkspaceDependencyIds.git) ==
              DepInstallStatus.idle &&
          controller.statusFor(wsId, WorkspaceDependencyIds.nodejs) ==
              DepInstallStatus.idle,
    );
    expect(fake.order, [
      WorkspaceDependencyIds.nodejs,
      WorkspaceDependencyIds.git,
    ]);
    final completed = controller.takeCompleted(wsId);
    expect(completed[WorkspaceDependencyIds.nodejs], isA<StateError>());
    expect(completed, containsPair(WorkspaceDependencyIds.git, isNull));
    // Consumption is one-shot: a second call returns nothing.
    expect(controller.takeCompleted(wsId), isEmpty);
  });

  test('a dep enqueued while another is running is deduped', () async {
    final fake = _FakeInstaller()
      ..gate[WorkspaceDependencyIds.nodejs] = Completer<void>();
    final controller = DependencyInstallController(installer: fake.call);

    controller.enqueue(
      workspaceId: wsId,
      depId: WorkspaceDependencyIds.nodejs,
      hostPath: '/ws',
      pref: pref,
    );
    controller.enqueue(
      workspaceId: wsId,
      depId: WorkspaceDependencyIds.git,
      hostPath: '/ws',
      pref: pref,
    );
    // git is queued behind the gated nodejs install; re-enqueueing it while
    // queued must be ignored (the queue-level dedupe path).
    controller.enqueue(
      workspaceId: wsId,
      depId: WorkspaceDependencyIds.git,
      hostPath: '/ws',
      pref: pref,
    );

    fake.gate[WorkspaceDependencyIds.nodejs]!.complete();
    await _pumpUntil(
      () =>
          controller.statusFor(wsId, WorkspaceDependencyIds.git) ==
          DepInstallStatus.idle,
    );
    expect(fake.order, [
      WorkspaceDependencyIds.nodejs,
      WorkspaceDependencyIds.git,
    ]);
  });

  test('a failed dep can be retried by enqueueing again', () async {
    final fake = _FakeInstaller()
      ..failures[WorkspaceDependencyIds.nodejs] = 'transient error';
    final controller = DependencyInstallController(installer: fake.call);

    controller.enqueue(
      workspaceId: wsId,
      depId: WorkspaceDependencyIds.nodejs,
      hostPath: '/ws',
      pref: pref,
    );
    await _pumpUntil(
      () =>
          controller.statusFor(wsId, WorkspaceDependencyIds.nodejs) ==
          DepInstallStatus.idle,
    );
    expect(fake.order, [WorkspaceDependencyIds.nodejs]);
    expect(
      controller.takeCompleted(wsId)[WorkspaceDependencyIds.nodejs],
      isA<StateError>(),
    );

    // Clear the failure and retry: the controller must accept a fresh
    // enqueue after the dep went idle.
    fake.failures.remove(WorkspaceDependencyIds.nodejs);
    controller.enqueue(
      workspaceId: wsId,
      depId: WorkspaceDependencyIds.nodejs,
      hostPath: '/ws',
      pref: pref,
    );
    await _pumpUntil(
      () =>
          controller.statusFor(wsId, WorkspaceDependencyIds.nodejs) ==
          DepInstallStatus.idle,
    );
    expect(fake.order, [
      WorkspaceDependencyIds.nodejs,
      WorkspaceDependencyIds.nodejs,
    ]);
    expect(
      controller.takeCompleted(wsId)[WorkspaceDependencyIds.nodejs],
      isNull,
    );
  });

  test('progress and stage are exposed only while installing', () async {
    final fake = _FakeInstaller()
      ..gate[WorkspaceDependencyIds.git] = Completer<void>();
    final controller = DependencyInstallController(installer: fake.call);

    controller.enqueue(
      workspaceId: wsId,
      depId: WorkspaceDependencyIds.git,
      hostPath: '/ws',
      pref: pref,
    );
    expect(
      controller.statusFor(wsId, WorkspaceDependencyIds.git),
      DepInstallStatus.installing,
    );
    expect(controller.stageFor(wsId, WorkspaceDependencyIds.git), 'install');
    expect(controller.progressFor(wsId, WorkspaceDependencyIds.git), 0.5);

    fake.gate[WorkspaceDependencyIds.git]!.complete();
    await _pumpUntil(
      () =>
          controller.statusFor(wsId, WorkspaceDependencyIds.git) ==
          DepInstallStatus.idle,
    );
    expect(controller.progressFor(wsId, WorkspaceDependencyIds.git), isNull);
    expect(controller.stageFor(wsId, WorkspaceDependencyIds.git), isNull);
  });

  test('separate workspaces install in parallel', () async {
    final fake = _FakeInstaller()
      ..gate[WorkspaceDependencyIds.git] = Completer<void>()
      ..gate['git2'] = Completer<void>();
    final controller = DependencyInstallController(installer: fake.call);

    controller.enqueue(
      workspaceId: 'ws_a',
      depId: WorkspaceDependencyIds.git,
      hostPath: '/ws_a',
      pref: pref,
    );
    controller.enqueue(
      workspaceId: 'ws_b',
      depId: 'git2',
      hostPath: '/ws_b',
      pref: pref,
    );
    await _pumpUntil(() => fake.concurrent == 2);
    expect(fake.maxConcurrent, 2);

    fake.gate[WorkspaceDependencyIds.git]!.complete();
    fake.gate['git2']!.complete();
    await _pumpUntil(
      () =>
          controller.statusFor('ws_a', WorkspaceDependencyIds.git) ==
              DepInstallStatus.idle &&
          controller.statusFor('ws_b', 'git2') == DepInstallStatus.idle,
    );
    expect(fake.order, containsAll([WorkspaceDependencyIds.git, 'git2']));
    // Each workspace's install must run against its own rootfs path.
    expect(fake.hostPaths, containsAll(['/ws_a', '/ws_b']));
  });
}
