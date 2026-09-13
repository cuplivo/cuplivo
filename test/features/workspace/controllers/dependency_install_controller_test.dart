import 'dart:async';

import 'package:Cuplivo/core/models/workspace.dart';
import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:Cuplivo/core/services/workspace/workspace_terminal_native_bridge.dart';
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

    // The pump acquires its keep-screen-on hold first, so the first
    // install starts asynchronously; wait for it instead of asserting in
    // the same frame.
    await _pumpUntil(
      () =>
          controller.statusFor(wsId, WorkspaceDependencyIds.nodejs) ==
          DepInstallStatus.installing,
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
    await _pumpUntil(
      () =>
          controller.statusFor(wsId, WorkspaceDependencyIds.git) ==
          DepInstallStatus.installing,
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

  test('base reinstall stops the workspace terminal before mutation', () async {
    final events = <String>[];
    final controller = DependencyInstallController(
      beforeBaseMutation: (hostPath) async {
        events.add('stop:$hostPath');
      },
      installer:
          ({
            required workspaceHostPath,
            required depId,
            required pref,
            onProgress,
          }) async {
            events.add('install:$workspaceHostPath:$depId');
          },
    );

    controller.enqueue(
      workspaceId: wsId,
      depId: WorkspaceDependencyIds.base,
      hostPath: '/ws',
      pref: pref,
    );
    await _pumpUntil(
      () =>
          controller.statusFor(wsId, WorkspaceDependencyIds.base) ==
          DepInstallStatus.idle,
    );

    expect(events, <String>['stop:/ws', 'install:/ws:base']);
  });

  test('base reinstall is cancelled when terminal stop fails', () async {
    var installerCalled = false;
    final controller = DependencyInstallController(
      beforeBaseMutation: (_) async => throw StateError('stop failed'),
      installer:
          ({
            required workspaceHostPath,
            required depId,
            required pref,
            onProgress,
          }) async {
            installerCalled = true;
          },
    );

    controller.enqueue(
      workspaceId: wsId,
      depId: WorkspaceDependencyIds.base,
      hostPath: '/ws',
      pref: pref,
    );
    await _pumpUntil(
      () =>
          controller.statusFor(wsId, WorkspaceDependencyIds.base) ==
          DepInstallStatus.idle,
    );

    expect(installerCalled, isFalse);
    expect(
      controller.takeCompleted(wsId)[WorkspaceDependencyIds.base],
      isA<WorkspaceTerminalStopException>(),
    );
  });

  group('keep-screen-on queue hold', () {
    test('spans the whole queue and survives listeners detaching', () async {
      final holds = <bool>[];
      final fake = _FakeInstaller()
        ..gate[WorkspaceDependencyIds.git] = Completer<void>()
        ..gate[WorkspaceDependencyIds.python] = Completer<void>();
      final controller = DependencyInstallController(
        installer: fake.call,
        keepScreenOn: (hold) async => holds.add(hold),
      );

      // No observer ever attaches (standing in for a detail page already
      // popped): the queue must still keep the screen on by itself.
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
      await _pumpUntil(() => holds.contains(true));
      expect(holds, [true]);

      // Between dependencies the hold must not flicker: queue still busy.
      fake.gate[WorkspaceDependencyIds.git]!.complete();
      await _pumpUntil(
        () =>
            controller.statusFor(wsId, WorkspaceDependencyIds.git) ==
            DepInstallStatus.idle,
      );
      expect(holds, [true]);

      // Last dependency finishes: hold releases exactly once.
      fake.gate[WorkspaceDependencyIds.python]!.complete();
      await _pumpUntil(
        () =>
            controller.statusFor(wsId, WorkspaceDependencyIds.python) ==
            DepInstallStatus.idle,
      );
      expect(holds, [true, false]);
    });

    test('releases on runner failure even without any listener', () async {
      final holds = <bool>[];
      final fake = _FakeInstaller()
        ..failures[WorkspaceDependencyIds.nodejs] = 'apt lock held';
      final controller = DependencyInstallController(
        installer: fake.call,
        keepScreenOn: (hold) async => holds.add(hold),
      );

      controller.enqueue(
        workspaceId: wsId,
        depId: WorkspaceDependencyIds.nodejs,
        hostPath: '/ws',
        pref: pref,
      );
      await _pumpUntil(() => holds.contains(false));
      expect(holds, [true, false]);
      expect(
        controller.takeCompleted(wsId)[WorkspaceDependencyIds.nodejs],
        isA<StateError>(),
      );
    });

    test('acquires once per pump and composes across workspaces', () async {
      final holds = <bool>[];
      final fake = _FakeInstaller()
        ..gate[WorkspaceDependencyIds.git] = Completer<void>()
        ..gate['git2'] = Completer<void>();
      final controller = DependencyInstallController(
        installer: fake.call,
        keepScreenOn: (hold) async => holds.add(hold),
      );

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
      // Two concurrent pumps -> two acquires; the service refcount keeps the
      // flag until the last release (composition with the terminal hold).
      expect(holds, [true, true]);

      fake.gate[WorkspaceDependencyIds.git]!.complete();
      fake.gate['git2']!.complete();
      await _pumpUntil(
        () =>
            controller.statusFor('ws_a', WorkspaceDependencyIds.git) ==
                DepInstallStatus.idle &&
            controller.statusFor('ws_b', 'git2') == DepInstallStatus.idle,
      );
      expect(holds, [true, true, false, false]);
    });

    test('a failing keep-screen-on switch never aborts the install', () async {
      final fake = _FakeInstaller()
        ..gate[WorkspaceDependencyIds.git] = Completer<void>();
      final controller = DependencyInstallController(
        installer: fake.call,
        keepScreenOn: (hold) async => throw StateError('no activity'),
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
            DepInstallStatus.installing,
      );
      expect(
        controller.statusFor(wsId, WorkspaceDependencyIds.git),
        DepInstallStatus.installing,
      );
      fake.gate[WorkspaceDependencyIds.git]!.complete();
      await _pumpUntil(
        () =>
            controller.statusFor(wsId, WorkspaceDependencyIds.git) ==
            DepInstallStatus.idle,
      );
      expect(fake.order, [WorkspaceDependencyIds.git]);
      expect(
        controller.takeCompleted(wsId)[WorkspaceDependencyIds.git],
        isNull,
      );
    });

    test('an enqueue during the async release runs in a fresh pump', () async {
      // Regression (review): the pump used to await `keepScreenOn(false)`
      // BEFORE releasing worker ownership, so a dependency enqueued while
      // that release was in flight landed in a queue the finishing pump was
      // about to delete — it stayed idle forever. The first release is
      // gated to widen that window deterministically.
      final holds = <bool>[];
      final gateRelease = Completer<void>();
      var releases = 0;
      final fake = _FakeInstaller()
        ..gate[WorkspaceDependencyIds.git] = Completer<void>();
      final controller = DependencyInstallController(
        installer: fake.call,
        keepScreenOn: (hold) async {
          holds.add(hold);
          if (!hold) {
            releases++;
            if (releases == 1) await gateRelease.future;
          }
        },
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
            DepInstallStatus.installing,
      );
      fake.gate[WorkspaceDependencyIds.git]!.complete();
      // The drain finished and the release is in flight, still gated.
      await _pumpUntil(() => holds.contains(false));

      controller.enqueue(
        workspaceId: wsId,
        depId: WorkspaceDependencyIds.python,
        hostPath: '/ws',
        pref: pref,
      );
      gateRelease.complete();
      await _pumpUntil(
        () =>
            controller.statusFor(wsId, WorkspaceDependencyIds.python) ==
            DepInstallStatus.idle,
      );
      expect(fake.order, [
        WorkspaceDependencyIds.git,
        WorkspaceDependencyIds.python,
      ]);
      expect(
        controller.statusFor(wsId, WorkspaceDependencyIds.python),
        DepInstallStatus.idle,
      );
      expect(
        controller.takeCompleted(wsId)[WorkspaceDependencyIds.python],
        isNull,
      );
      // Holds stay balanced: one acquire/release per queue the controller
      // actually ran.
      expect(holds, [true, false, true, false]);
    });
  });

  test('collects and drains non-fatal install notices', () async {
    var emitted = false;
    final controller = DependencyInstallController(
      installer:
          ({
            required String workspaceHostPath,
            required String depId,
            required DependencyInstallPref pref,
            void Function(SandboxInstallProgress)? onProgress,
          }) async {
            onProgress?.call(
              const SandboxInstallProgress(
                stage: 'notice',
                notice: sandboxNoticeDebianMirrorDefault,
              ),
            );
            onProgress?.call(
              const SandboxInstallProgress(stage: 'install', progress: 0.5),
            );
            emitted = true;
          },
      keepScreenOn: (_) async {},
    );

    controller.enqueue(
      workspaceId: wsId,
      depId: WorkspaceDependencyIds.git,
      hostPath: '/ws',
      pref: pref,
    );
    await _pumpUntil(
      () =>
          emitted &&
          controller.statusFor(wsId, WorkspaceDependencyIds.git) ==
              DepInstallStatus.idle,
    );

    expect(
      controller.takeNotices(wsId),
      contains(sandboxNoticeDebianMirrorDefault),
    );
    // Drained on read, so a rebuild does not repeat the snackbar.
    expect(controller.takeNotices(wsId), isEmpty);
    // A notice is not a failure: the dependency still completes.
    expect(controller.takeCompleted(wsId)[WorkspaceDependencyIds.git], isNull);
  });

  group('snapshot cache survives controller reuse (page rebuild)', () {
    SandboxDependencyStatusSnapshot snapshot({
      required bool base,
      bool hasRuntime = true,
      Map<String, bool> extra = const <String, bool>{},
    }) {
      return SandboxDependencyStatusSnapshot(
        hasRuntime: hasRuntime,
        installed: <String, bool>{
          for (final id in WorkspaceDependencyIds.ordered)
            id:
                id == WorkspaceDependencyIds.base
                    ? base
                    : extra[id] ?? false,
        },
      );
    }

    test(
      'refreshSnapshot stores the result so a later snapshotFor reads it '
      'back without re-probing (regression: detail page rebuild during an '
      'install briefly showed `未安装` for already-installed deps because '
      'the page-local `_depInstalled` map was reset on rebuild).',
      () async {
        var probeCount = 0;
        final controller = DependencyInstallController(
          installer: _FakeInstaller().call,
          keepScreenOn: (_) async {},
          prober: (hostPath) async {
            probeCount++;
            return snapshot(base: true);
          },
        );

        expect(controller.snapshotFor(wsId), isNull);
        await controller.refreshSnapshot(
          workspaceId: wsId,
          hostPath: '/ws',
        );
        expect(probeCount, 1);
        final cached = controller.snapshotFor(wsId);
        expect(cached, isNotNull);
        expect(cached!.installed[WorkspaceDependencyIds.base], isTrue);

        // A second refresh overwrites the cache (regression guard for the
        // generation-counter discard path).
        await controller.refreshSnapshot(
          workspaceId: wsId,
          hostPath: '/ws',
        );
        expect(probeCount, 2);
        expect(
          controller.snapshotFor(wsId)!.installed[WorkspaceDependencyIds.base],
          isTrue,
        );
      },
    );

    test(
      'an install completion triggers a snapshot refresh without the '
      'page having to call refreshSnapshot itself',
      () async {
        final gate = Completer<void>();
        final proberCalls = <String>[];
        final fake = _FakeInstaller()
          ..gate[WorkspaceDependencyIds.python] = gate;
        final controller = DependencyInstallController(
          installer: fake.call,
          keepScreenOn: (_) async {},
          prober: (hostPath) async {
            proberCalls.add(hostPath);
            return snapshot(base: true, extra: const <String, bool>{});
          },
        );

        controller.enqueue(
          workspaceId: wsId,
          depId: WorkspaceDependencyIds.python,
          hostPath: '/ws',
          pref: pref,
        );
        await _pumpUntil(
          () =>
              controller.statusFor(wsId, WorkspaceDependencyIds.python) ==
              DepInstallStatus.installing,
        );
        expect(proberCalls, isEmpty);

        gate.complete();
        await _pumpUntil(
          () =>
              controller.statusFor(wsId, WorkspaceDependencyIds.python) ==
              DepInstallStatus.idle,
        );
        // Auto-refresh fires after the install settles; the cached snapshot
        // is what a freshly-rebuilt detail page reads.
        await _pumpUntil(() => controller.snapshotFor(wsId) != null);
        expect(proberCalls, ['/ws']);
        expect(
          controller.snapshotFor(wsId)!.installed[WorkspaceDependencyIds.base],
          isTrue,
        );
      },
    );

    test(
      'a refreshSnapshot call while another probe for the same workspace '
      '+ host path is in flight is coalesced (no duplicate probe, no '
      'stall behind the shared per-workspace FIFO)',
      () async {
        // Regression: prior to the OCR-coalescing fix, two concurrent
        // calls for the same workspace + path both entered the prober,
        // bumping the generation counter each time. The generation
        // counter discarded the first probe's eventual result so the
        // cache stayed consistent, but both probes still RAN — they
        // serialized behind whatever the shared per-workspace FIFO was
        // already doing (typically the in-flight install), and the
        // second call's UI stall could last for tens of seconds. The
        // user's retry-button spam surfaced this as "tap → frozen for
        // 30s → tap again → frozen for 60s". Now: the second call
        // returns immediately, the in-flight probe's result is shared
        // by both callers, no extra load on the FIFO.
        final gate = Completer<SandboxDependencyStatusSnapshot>();
        var proberCalls = 0;
        final controller = DependencyInstallController(
          installer: _FakeInstaller().call,
          keepScreenOn: (_) async {},
          prober: (hostPath) async {
            proberCalls++;
            return gate.future;
          },
        );

        // Kick off a probe that will be held open.
        final first = controller.refreshSnapshot(
          workspaceId: wsId,
          hostPath: '/ws',
        );
        // Second + third call for the SAME workspace + SAME path are
        // coalesced: they observe _snapshotLoadingByWorkspace[ws] == true
        // and the same path, so they return immediately without bumping
        // the generation counter or entering the prober.
        final second = controller.refreshSnapshot(
          workspaceId: wsId,
          hostPath: '/ws',
        );
        final third = controller.refreshSnapshot(
          workspaceId: wsId,
          hostPath: '/ws',
        );

        // Let the (synchronous parts of the) coalesced calls settle
        // before we complete the in-flight probe.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(proberCalls, 1);

        gate.complete(snapshot(base: true));
        await Future.wait<void>([first, second, third]);

        // Coalesced: only one probe ran, all three callers see the same
        // result.
        expect(proberCalls, 1);
        expect(
          controller.snapshotFor(wsId)!.installed[WorkspaceDependencyIds.base],
          isTrue,
        );
        expect(controller.isLoadingSnapshotFor(wsId), isFalse);
      },
    );

    test(
      'refreshSnapshot records failure and exposes it via '
      'didLastSnapshotProbeFailFor',
      () async {
        final controller = DependencyInstallController(
          installer: _FakeInstaller().call,
          keepScreenOn: (_) async {},
          prober: (hostPath) async {
            throw StateError('probe blew up');
          },
        );

        await controller.refreshSnapshot(
          workspaceId: wsId,
          hostPath: '/ws',
        );
        expect(controller.snapshotFor(wsId), isNull);
        expect(controller.didLastSnapshotProbeFailFor(wsId), isTrue);
        expect(controller.isLoadingSnapshotFor(wsId), isFalse);
      },
    );

    test(
      'refreshSnapshot is a no-op when no host path is known (the page '
      'probing before the user ever tapped install)',
      () async {
        var proberCalls = 0;
        final controller = DependencyInstallController(
          installer: _FakeInstaller().call,
          keepScreenOn: (_) async {},
          prober: (hostPath) async {
            proberCalls++;
            return snapshot(base: false);
          },
        );
        await controller.refreshSnapshot(workspaceId: wsId);
        expect(proberCalls, 0);
        expect(controller.snapshotFor(wsId), isNull);
      },
    );

    test(
      'forgetWorkspace clears every per-workspace cache entry so the '
      'workspace id never leaks a stale `已安装` snapshot after deletion',
      () async {
        final controller = DependencyInstallController(
          installer: _FakeInstaller().call,
          keepScreenOn: (_) async {},
          prober: (hostPath) async => snapshot(base: true),
        );
        await controller.refreshSnapshot(
          workspaceId: wsId,
          hostPath: '/ws',
        );
        expect(controller.snapshotFor(wsId), isNotNull);
        expect(controller.didLastSnapshotProbeFailFor(wsId), isFalse);

        controller.forgetWorkspace(wsId);
        expect(controller.snapshotFor(wsId), isNull);
        expect(controller.didLastSnapshotProbeFailFor(wsId), isFalse);
      },
    );

    test(
      'SandboxBusyException from a saturated per-workspace FIFO is NOT '
      'surfaced as a user-visible probe failure (the queue cap is a '
      'transient artefact, not a status the user can retry against)',
      () async {
        final controller = DependencyInstallController(
          installer: _FakeInstaller().call,
          keepScreenOn: (_) async {},
          prober: (hostPath) async {
            throw SandboxBusyException('/ws');
          },
        );
        await controller.refreshSnapshot(
          workspaceId: wsId,
          hostPath: '/ws',
        );
        // No snapshot is cached (probe threw), but the error flag must
        // stay false so the UI does not render the retry banner or
        // disable install buttons.
        expect(controller.snapshotFor(wsId), isNull);
        expect(controller.didLastSnapshotProbeFailFor(wsId), isFalse);
        expect(controller.isLoadingSnapshotFor(wsId), isFalse);
      },
    );

    test(
      'SandboxCancelledException is treated as transient (same reason as '
      'SandboxBusyException)',
      () async {
        final controller = DependencyInstallController(
          installer: _FakeInstaller().call,
          keepScreenOn: (_) async {},
          prober: (hostPath) async {
            throw SandboxCancelledException('install_python');
          },
        );
        await controller.refreshSnapshot(
          workspaceId: wsId,
          hostPath: '/ws',
        );
        expect(controller.snapshotFor(wsId), isNull);
        expect(controller.didLastSnapshotProbeFailFor(wsId), isFalse);
      },
    );

    test(
      'a real probe failure (non-transient exception) still flips '
      'didLastSnapshotProbeFailFor so the user sees the retry banner',
      () async {
        final controller = DependencyInstallController(
          installer: _FakeInstaller().call,
          keepScreenOn: (_) async {},
          prober: (hostPath) async {
            throw StateError('probe blew up');
          },
        );
        await controller.refreshSnapshot(
          workspaceId: wsId,
          hostPath: '/ws',
        );
        expect(controller.snapshotFor(wsId), isNull);
        expect(controller.didLastSnapshotProbeFailFor(wsId), isTrue);
      },
    );
  });
}
