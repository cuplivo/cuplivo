import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/harness_connection_provider.dart';
import 'package:Cuplivo/core/services/harness/harness_connection_probe.dart';
import 'package:Cuplivo/core/services/harness/harness_tailcat_dialer.dart';
import 'package:Cuplivo/core/services/harness/harness_tailcat_probe.dart';
import 'package:Cuplivo/core/services/harness/harness_tailcat_tunnels.dart';

import '../../support/business_test_harness.dart';

/// A probe whose answers arrive when the test says so, so transitions and
/// races can be observed without touching a socket.
final class _ControllableProbe extends HarnessConnectionProbe {
  final List<String> requestedUrls = <String>[];
  final List<Completer<HarnessConnectionResult>> calls =
      <Completer<HarnessConnectionResult>>[];

  @override
  Future<HarnessConnectionResult> check(String rawUrl) {
    requestedUrls.add(rawUrl);
    final completer = Completer<HarnessConnectionResult>();
    calls.add(completer);
    return completer.future;
  }

  void answer(int call, HarnessConnectionResult result) {
    calls[call].complete(result);
  }
}

/// The tailcat half of the probe, controllable like [_ControllableProbe].
final class _ControllableTailcatProbe extends HarnessTailcatProbe {
  _ControllableTailcatProbe() : super(tunnels: HarnessTailcatTunnels());

  final List<String> requestedAddresses = <String>[];
  final List<int?> requestedPorts = <int?>[];
  final List<Completer<HarnessConnectionResult>> calls =
      <Completer<HarnessConnectionResult>>[];

  @override
  Future<HarnessConnectionResult> check(String rawInput, {int? remotePort}) {
    requestedAddresses.add(rawInput);
    requestedPorts.add(remotePort);
    final completer = Completer<HarnessConnectionResult>();
    calls.add(completer);
    return completer.future;
  }

  void answer(int call, HarnessConnectionResult result) {
    calls[call].complete(result);
  }
}

/// A tunnel client that never dials: these tests only observe tunnel
/// lifecycle, so the loopback listener is enough.
final class _NoopDialer implements HarnessTailcatDialer {
  @override
  Future<Socket> connect(int port) async => throw UnimplementedError();

  @override
  Future<void> close() async {}
}

const String _tailcatAddress =
    'tcAPpXUQeEXAMPLEaddressEXAMPLEaddressEXAMPLEaddressEXAMPLE00';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const local = Assistant(id: 'local-1', name: 'Local');
  final linked = Assistant.harness(
    id: 'harness-1',
    name: 'Linked harness',
    harnessUrl: 'http://127.0.0.1:9/?token=launch',
  );
  final unlinked = Assistant.harness(id: 'harness-2', name: 'Unlinked harness');

  late AssistantProvider assistants;
  late _ControllableProbe probe;
  late HarnessConnectionProvider connections;

  setUp(() async {
    final harness = await createBusinessTestHarness(
      initial: <String, Object?>{
        'assistants_v1': Assistant.encodeList(<Assistant>[
          local,
          linked,
          unlinked,
        ]),
        'current_assistant_id_v1': local.id,
      },
    );
    assistants = AssistantProvider(preferences: harness.preferences);
    addTearDown(assistants.dispose);
    await assistants.loaded;
    probe = _ControllableProbe();
    connections = HarnessConnectionProvider(
      assistants: assistants,
      probe: probe,
    );
    addTearDown(connections.dispose);
  });

  group('HarnessConnectionProvider', () {
    test(
      'a check moves from unknown to checking to connected and notifies each step',
      () async {
        final phases = <HarnessConnectionPhase>[];
        connections.addListener(() {
          phases.add(connections.phaseOf(linked.id));
        });

        expect(connections.phaseOf(linked.id), HarnessConnectionPhase.unknown);

        final pending = connections.check(assistants.getById(linked.id)!);
        expect(connections.phaseOf(linked.id), HarnessConnectionPhase.checking);
        expect(phases, <HarnessConnectionPhase>[
          HarnessConnectionPhase.checking,
        ]);
        expect(probe.requestedUrls, <String>[linked.harnessUrl!]);

        probe.answer(0, const HarnessConnectionResult.connected());
        final result = await pending;
        expect(result.isConnected, isTrue);
        expect(
          connections.phaseOf(linked.id),
          HarnessConnectionPhase.connected,
        );
        expect(connections.isConnected(linked.id), isTrue);
        expect(phases, <HarnessConnectionPhase>[
          HarnessConnectionPhase.checking,
          HarnessConnectionPhase.connected,
        ]);
      },
    );

    test('a failed check exposes its failure reason', () async {
      final pending = connections.check(assistants.getById(linked.id)!);

      probe.answer(
        0,
        const HarnessConnectionResult.failed(HarnessConnectionFailure.rejected),
      );
      final result = await pending;

      expect(result.failure, HarnessConnectionFailure.rejected);
      expect(connections.phaseOf(linked.id), HarnessConnectionPhase.failed);
      expect(
        connections.failureOf(linked.id),
        HarnessConnectionFailure.rejected,
      );
      expect(connections.isConnected(linked.id), isFalse);
    });

    test(
      'ensureChecked starts only harness assistants with a link and no answer',
      () async {
        const localWithLink = Assistant(
          id: 'local-with-link',
          name: 'Local with a link',
          harnessUrl: 'http://127.0.0.1:9/?token=local',
        );
        final unlinkedHarness = Assistant.harness(
          id: 'unlinked-harness',
          name: 'Unlinked',
        );
        final readyHarness = Assistant.harness(
          id: 'ready-harness',
          name: 'Ready',
          harnessUrl: 'http://127.0.0.1:9/?token=ready',
        );

        connections.ensureChecked(<Assistant>[
          localWithLink,
          unlinkedHarness,
          readyHarness,
          // Listed twice, e.g. two surfaces opening together.
          readyHarness,
        ]);

        expect(probe.requestedUrls, <String>[
          'http://127.0.0.1:9/?token=ready',
        ]);
        expect(
          connections.phaseOf('ready-harness'),
          HarnessConnectionPhase.checking,
        );
        expect(
          connections.phaseOf('unlinked-harness'),
          HarnessConnectionPhase.unknown,
        );
        expect(
          connections.phaseOf('local-with-link'),
          HarnessConnectionPhase.unknown,
        );

        probe.answer(0, const HarnessConnectionResult.connected());
        await pumpEventQueue();
        expect(
          connections.phaseOf('ready-harness'),
          HarnessConnectionPhase.connected,
        );

        // An assistant that already has an answer is not probed again.
        connections.ensureChecked(<Assistant>[readyHarness]);
        expect(probe.requestedUrls, hasLength(1));
      },
    );

    test(
      'reset forgets the answer so a changed link is checked again',
      () async {
        final assistant = assistants.getById(linked.id)!;
        final first = connections.check(assistant);
        probe.answer(0, const HarnessConnectionResult.connected());
        await first;
        expect(
          connections.phaseOf(linked.id),
          HarnessConnectionPhase.connected,
        );

        connections.reset(linked.id);
        expect(connections.phaseOf(linked.id), HarnessConnectionPhase.unknown);
        expect(connections.failureOf(linked.id), isNull);

        final second = connections.check(assistant);
        expect(probe.requestedUrls, hasLength(2));
        expect(connections.phaseOf(linked.id), HarnessConnectionPhase.checking);
        probe.answer(
          1,
          const HarnessConnectionResult.failed(
            HarnessConnectionFailure.apiUnavailable,
          ),
        );
        await second;
        expect(
          connections.failureOf(linked.id),
          HarnessConnectionFailure.apiUnavailable,
        );
      },
    );

    test(
      'an answer that arrives after reset cannot revive the old link',
      () async {
        final pending = connections.check(assistants.getById(linked.id)!);

        connections.reset(linked.id);
        expect(connections.phaseOf(linked.id), HarnessConnectionPhase.unknown);

        probe.answer(0, const HarnessConnectionResult.connected());
        final result = await pending;

        // The caller still learns what that attempt saw, but the provider does not
        // remember it: the link was being changed.
        expect(result.isConnected, isTrue);
        expect(connections.phaseOf(linked.id), HarnessConnectionPhase.unknown);
        expect(connections.isConnected(linked.id), isFalse);
      },
    );

    test('a slow earlier check cannot overwrite a newer answer', () async {
      final assistant = assistants.getById(linked.id)!;
      final slow = connections.check(assistant);
      final fast = connections.check(assistant);
      expect(probe.calls, hasLength(2));

      probe.answer(
        1,
        const HarnessConnectionResult.failed(HarnessConnectionFailure.rejected),
      );
      expect((await fast).failure, HarnessConnectionFailure.rejected);
      expect(connections.phaseOf(linked.id), HarnessConnectionPhase.failed);

      probe.answer(0, const HarnessConnectionResult.connected());
      expect((await slow).isConnected, isTrue);
      // The earlier answer describes an exchange the later one already replaced.
      expect(connections.phaseOf(linked.id), HarnessConnectionPhase.failed);
      expect(
        connections.failureOf(linked.id),
        HarnessConnectionFailure.rejected,
      );
    });

    test('deleting a harness assistant prunes only its answer', () async {
      final firstPending = connections.check(assistants.getById(linked.id)!);
      final secondPending = connections.check(assistants.getById(unlinked.id)!);
      probe.answer(0, const HarnessConnectionResult.connected());
      probe.answer(1, const HarnessConnectionResult.connected());
      await Future.wait(<Future<HarnessConnectionResult>>[
        firstPending,
        secondPending,
      ]);
      expect(connections.phaseOf(linked.id), HarnessConnectionPhase.connected);
      expect(
        connections.phaseOf(unlinked.id),
        HarnessConnectionPhase.connected,
      );

      expect(await assistants.deleteAssistant(linked.id), isTrue);

      expect(connections.phaseOf(linked.id), HarnessConnectionPhase.unknown);
      expect(connections.failureOf(linked.id), isNull);
      expect(
        connections.phaseOf(unlinked.id),
        HarnessConnectionPhase.connected,
      );
    });

    test(
      'a check answering after dispose does not notify a disposed provider',
      () async {
        final localProbe = _ControllableProbe();
        final provider = HarnessConnectionProvider(
          assistants: assistants,
          probe: localProbe,
        );
        var notifications = 0;
        provider.addListener(() {
          notifications++;
        });

        final pending = provider.check(assistants.getById(linked.id)!);
        expect(notifications, 1); // checking
        provider.dispose();

        localProbe.answer(0, const HarnessConnectionResult.connected());
        expect((await pending).isConnected, isTrue);
        expect(notifications, 1);
      },
    );
  });
  test('a tailcat-mode assistant is proved by the tailcat probe', () async {
    final tailcatProbe = _ControllableTailcatProbe();
    final provider = HarnessConnectionProvider(
      assistants: assistants,
      probe: probe,
      tailcatProbe: tailcatProbe,
    );
    addTearDown(provider.dispose);
    final tailcat = Assistant.harness(
      id: 'tailcat-1',
      name: 'Tailcat harness',
      harnessConnectionMode: HarnessConnectionMode.tailcat,
      harnessTailcatAddress: _tailcatAddress,
      harnessTailcatPort: 14000,
    );

    final pending = provider.check(tailcat);

    expect(provider.phaseOf(tailcat.id), HarnessConnectionPhase.checking);
    expect(tailcatProbe.requestedAddresses, <String>[_tailcatAddress]);
    expect(tailcatProbe.requestedPorts, <int?>[14000]);
    expect(
      probe.requestedUrls,
      isEmpty,
      reason: 'the link probe must not see a tailcat credential',
    );

    tailcatProbe.answer(0, const HarnessConnectionResult.connected());
    expect((await pending).isConnected, isTrue);
    expect(provider.phaseOf(tailcat.id), HarnessConnectionPhase.connected);
  });

  test('a link-mode assistant still uses the link probe', () async {
    final tailcatProbe = _ControllableTailcatProbe();
    final provider = HarnessConnectionProvider(
      assistants: assistants,
      probe: probe,
      tailcatProbe: tailcatProbe,
    );
    addTearDown(provider.dispose);

    final pending = provider.check(assistants.getById(linked.id)!);

    expect(probe.requestedUrls, <String>[linked.harnessUrl!]);
    expect(tailcatProbe.requestedAddresses, isEmpty);

    probe.answer(0, const HarnessConnectionResult.connected());
    expect((await pending).isConnected, isTrue);
  });

  test(
    'ensureChecked probes a configured tailcat harness and skips a bare one',
    () async {
      final tailcatProbe = _ControllableTailcatProbe();
      final provider = HarnessConnectionProvider(
        assistants: assistants,
        probe: probe,
        tailcatProbe: tailcatProbe,
      );
      addTearDown(provider.dispose);
      final configured = Assistant.harness(
        id: 'tailcat-configured',
        name: 'Configured',
        harnessConnectionMode: HarnessConnectionMode.tailcat,
        harnessTailcatAddress: _tailcatAddress,
      );
      final bare = Assistant.harness(
        id: 'tailcat-bare',
        name: 'Bare',
        harnessConnectionMode: HarnessConnectionMode.tailcat,
      );

      provider.ensureChecked(<Assistant>[configured, bare, configured]);

      expect(tailcatProbe.requestedAddresses, <String>[_tailcatAddress]);
      expect(
        provider.phaseOf('tailcat-configured'),
        HarnessConnectionPhase.checking,
      );
      expect(provider.phaseOf('tailcat-bare'), HarnessConnectionPhase.unknown);

      tailcatProbe.answer(0, const HarnessConnectionResult.connected());
      await pumpEventQueue();
      expect(
        provider.phaseOf('tailcat-configured'),
        HarnessConnectionPhase.connected,
      );
    },
  );

  test(
    'a tailcat assistant on a build without a client fails as unsupported',
    () async {
      final provider = HarnessConnectionProvider(
        assistants: assistants,
        probe: probe,
      );
      addTearDown(provider.dispose);
      final tailcat = Assistant.harness(
        id: 'tailcat-unsupported',
        name: 'Tailcat harness',
        harnessConnectionMode: HarnessConnectionMode.tailcat,
        harnessTailcatAddress: _tailcatAddress,
      );

      final result = await provider.check(tailcat);

      expect(result.failure, HarnessConnectionFailure.tailcatUnsupported);
      expect(
        provider.failureOf(tailcat.id),
        HarnessConnectionFailure.tailcatUnsupported,
      );
      expect(probe.requestedUrls, isEmpty);
    },
  );

  test('deleting a tailcat assistant stops its tunnel', () async {
    final tunnels = HarnessTailcatTunnels(dialer: (_) => _NoopDialer());
    addTearDown(tunnels.closeAll);
    final tailcatProbe = _ControllableTailcatProbe();
    final provider = HarnessConnectionProvider(
      assistants: assistants,
      probe: probe,
      tailcatProbe: tailcatProbe,
      tailcatTunnels: tunnels,
    );
    addTearDown(provider.dispose);
    final id = await assistants.addHarnessAssistant(name: 'Tailcat harness');
    await assistants.updateAssistant(
      assistants
          .getById(id)!
          .copyWith(
            harnessConnectionMode: HarnessConnectionMode.tailcat,
            harnessTailcatAddress: _tailcatAddress,
          ),
    );
    final uri = await tunnels.ensureOpen(_tailcatAddress);
    expect(uri.scheme, 'http');

    expect(await assistants.deleteAssistant(id), isTrue);

    expect(
      tunnels.localUriFor(_tailcatAddress),
      isNull,
      reason: 'a tunnel nothing can open must not keep running',
    );
  });
  test('an answer does not survive an edit to the stored link', () async {
    final pending = connections.check(assistants.getById(linked.id)!);
    probe.answer(0, const HarnessConnectionResult.connected());
    await pending;
    expect(connections.isConnected(linked.id), isTrue);

    await assistants.updateAssistant(
      assistants
          .getById(linked.id)!
          .copyWith(harnessUrl: 'https://dsh.example.com/other?token=other'),
    );

    expect(
      connections.phaseOf(linked.id),
      HarnessConnectionPhase.unknown,
      reason: 'the answer described the previous link',
    );
    expect(connections.failureOf(linked.id), isNull);

    final recheck = connections.check(assistants.getById(linked.id)!);
    expect(
      probe.requestedUrls.last,
      'https://dsh.example.com/other?token=other',
    );
    probe.answer(1, const HarnessConnectionResult.connected());
    expect((await recheck).isConnected, isTrue);
  });

  test(
    'an answer does not survive a switch to the tailcat transport',
    () async {
      final tailcatProbe = _ControllableTailcatProbe();
      final provider = HarnessConnectionProvider(
        assistants: assistants,
        probe: probe,
        tailcatProbe: tailcatProbe,
      );
      addTearDown(provider.dispose);
      final linkedId = linked.id;

      final pending = provider.check(assistants.getById(linkedId)!);
      probe.answer(0, const HarnessConnectionResult.connected());
      await pending;
      expect(provider.isConnected(linkedId), isTrue);

      await assistants.updateAssistant(
        assistants
            .getById(linkedId)!
            .copyWith(
              harnessConnectionMode: HarnessConnectionMode.tailcat,
              harnessTailcatAddress: _tailcatAddress,
            ),
      );

      expect(provider.phaseOf(linkedId), HarnessConnectionPhase.unknown);
      expect(
        provider.failureOf(linkedId),
        isNull,
        reason: 'the link answer must not read as a tailcat rejection either',
      );
    },
  );
}
