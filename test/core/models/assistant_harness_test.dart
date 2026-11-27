import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';

const _local = Assistant(id: 'local', name: 'Local');
const _link = 'https://harness.example:8443/ui/?token=launch-token';

Assistant _harness({String? harnessUrl}) => Assistant.harness(
  id: 'harness',
  name: 'Remote DeepSeek Harness',
  harnessUrl: harnessUrl,
);

void main() {
  group('Assistant.harness', () {
    test('starts as an unlinked harness with the chat settings cleared', () {
      final assistant = _harness();

      expect(assistant.kind, AssistantKind.deepSeekHarness);
      expect(assistant.isDeepSeekHarness, isTrue);
      expect(assistant.harnessUrl, isNull);
      expect(assistant.temperature, isNull);
      expect(assistant.topP, isNull);
      expect(assistant.limitContextMessages, isFalse);
      expect(assistant.toJson()['kind'], 'deepSeekHarness');
      expect(assistant.toJson()['harnessUrl'], isNull);
    });

    test('a local assistant defaults to kind local and no link', () {
      expect(_local.kind, AssistantKind.local);
      expect(_local.isDeepSeekHarness, isFalse);
      expect(_local.harnessUrl, isNull);
      expect(_local.toJson()['kind'], 'local');
      expect(_local.toJson()['harnessUrl'], isNull);
    });
  });

  group('Assistant JSON round-trip', () {
    test('kind and link survive toJson/fromJson', () {
      final json = _harness(harnessUrl: _link).toJson();

      expect(json['kind'], 'deepSeekHarness');
      expect(json['harnessUrl'], _link);

      final decoded = Assistant.fromJson(json);
      expect(decoded.id, 'harness');
      expect(decoded.name, 'Remote DeepSeek Harness');
      expect(decoded.kind, AssistantKind.deepSeekHarness);
      expect(decoded.isDeepSeekHarness, isTrue);
      expect(decoded.harnessUrl, _link);
    });

    test('a payload with an absent or unknown kind is a local assistant', () {
      expect(
        Assistant.fromJson({'id': 'a', 'name': 'A'}).kind,
        AssistantKind.local,
      );
      expect(
        Assistant.fromJson({'id': 'a', 'name': 'A', 'kind': null}).kind,
        AssistantKind.local,
      );
      // A kind from another version/device is not a reason to lose the row.
      expect(
        Assistant.fromJson({
          'id': 'a',
          'name': 'A',
          'kind': 'deepseek_harness',
        }).kind,
        AssistantKind.local,
      );
      expect(
        Assistant.fromJson({
          'id': 'a',
          'name': 'A',
          'kind': 'deepSeekHarness',
        }).kind,
        AssistantKind.deepSeekHarness,
      );
    });

    test('an empty, blank or missing link is normalized to null', () {
      expect(Assistant.fromJson({'id': 'h', 'name': 'H'}).harnessUrl, isNull);
      expect(
        Assistant.fromJson({
          'id': 'h',
          'name': 'H',
          'harnessUrl': '',
        }).harnessUrl,
        isNull,
      );
      expect(
        Assistant.fromJson({
          'id': 'h',
          'name': 'H',
          'harnessUrl': '   ',
        }).harnessUrl,
        isNull,
      );
      // A link pasted with surrounding whitespace is still usable.
      expect(
        Assistant.fromJson({
          'id': 'h',
          'name': 'H',
          'harnessUrl': '  $_link  ',
        }).harnessUrl,
        _link,
      );
    });
  });

  group('Assistant.copyWith harness fields', () {
    test('unrelated edits preserve kind and link', () {
      final linked = _harness(harnessUrl: _link);

      final renamed = linked.copyWith(name: 'Renamed');
      expect(renamed.name, 'Renamed');
      expect(renamed.kind, AssistantKind.deepSeekHarness);
      expect(renamed.harnessUrl, _link);

      final otherLink = linked.copyWith(
        harnessUrl: 'https://other.example/?token=other',
      );
      expect(otherLink.harnessUrl, 'https://other.example/?token=other');
      expect(otherLink.kind, AssistantKind.deepSeekHarness);
      expect(otherLink.name, linked.name);
    });

    test('clearHarnessUrl clears the link without changing the kind', () {
      final cleared = _harness(
        harnessUrl: _link,
      ).copyWith(clearHarnessUrl: true);

      expect(cleared.harnessUrl, isNull);
      expect(cleared.kind, AssistantKind.deepSeekHarness);
      expect(cleared.isDeepSeekHarness, isTrue);
    });

    test('kind can be changed on its own', () {
      final promoted = _local.copyWith(kind: AssistantKind.deepSeekHarness);
      expect(promoted.kind, AssistantKind.deepSeekHarness);
      expect(promoted.isDeepSeekHarness, isTrue);
      expect(promoted.harnessUrl, isNull);

      final demoted = _harness(
        harnessUrl: _link,
      ).copyWith(kind: AssistantKind.local);
      expect(demoted.kind, AssistantKind.local);
      expect(demoted.isDeepSeekHarness, isFalse);
      // copyWith(kind:) alone does not touch a link; clearing is explicit.
      expect(demoted.harnessUrl, _link);
    });
  });

  group('Assistant list encoding', () {
    test('a mixed local and harness list keeps both kinds and the link', () {
      final decoded = Assistant.decodeList(
        Assistant.encodeList([_local, _harness(harnessUrl: _link)]),
      );

      expect(decoded, hasLength(2));
      expect(decoded[0].kind, AssistantKind.local);
      expect(decoded[0].harnessUrl, isNull);
      expect(decoded[1].kind, AssistantKind.deepSeekHarness);
      expect(decoded[1].isDeepSeekHarness, isTrue);
      expect(decoded[1].harnessUrl, _link);
    });

    test('a list saved before this feature decodes as local assistants', () {
      // The exact shape an install that predates the harness feature has on disk.
      const legacy = '[{"id":"a","name":"A"},{"id":"b","name":"B"}]';

      final decoded = Assistant.decodeList(legacy);

      expect(decoded, hasLength(2));
      expect(decoded.map((assistant) => assistant.kind), <AssistantKind>[
        AssistantKind.local,
        AssistantKind.local,
      ]);
      expect(
        decoded.every((assistant) => assistant.harnessUrl == null),
        isTrue,
      );
    });
  });

  group('Assistant.harness tailcat connection', () {
    test('a tailcat harness carries its address and peer port', () {
      final assistant = _tailcatHarness(port: 14000);

      expect(assistant.kind, AssistantKind.deepSeekHarness);
      expect(assistant.harnessConnectionMode, HarnessConnectionMode.tailcat);
      expect(assistant.harnessTailcatAddress, _tailcatAddress);
      expect(assistant.harnessTailcatPort, 14000);
      expect(assistant.harnessUrl, isNull);
      expect(assistant.hasHarnessConnection, isTrue);
    });

    test(
      'the connection mode decides which credential counts as connected',
      () {
        // A link-mode assistant ignores a leftover tailcat address.
        expect(
          Assistant.harness(
            id: 'h',
            name: 'H',
            harnessTailcatAddress: _tailcatAddress,
          ).hasHarnessConnection,
          isFalse,
        );
        // A tailcat-mode assistant ignores a leftover link.
        expect(_tailcatHarness(harnessUrl: _link).hasHarnessConnection, isTrue);
        expect(_tailcatHarness(address: null).hasHarnessConnection, isFalse);
        expect(_tailcatHarness(address: '   ').hasHarnessConnection, isFalse);
        expect(_harness(harnessUrl: _link).hasHarnessConnection, isTrue);
        expect(_harness().hasHarnessConnection, isFalse);
        expect(_local.hasHarnessConnection, isFalse);
      },
    );

    test('kind and transport survive toJson/fromJson together', () {
      final json = _tailcatHarness(port: 14000).toJson();
      expect(json['kind'], 'deepSeekHarness');
      expect(json['harnessConnectionMode'], 'tailcat');
      expect(json['harnessTailcatAddress'], _tailcatAddress);
      expect(json['harnessTailcatPort'], 14000);

      final decoded = Assistant.fromJson(json);
      expect(decoded.kind, AssistantKind.deepSeekHarness);
      expect(decoded.harnessConnectionMode, HarnessConnectionMode.tailcat);
      expect(decoded.harnessTailcatAddress, _tailcatAddress);
      expect(decoded.harnessTailcatPort, 14000);
      expect(decoded.harnessUrl, isNull);
    });

    test('payloads written before the tailcat field are link-mode', () {
      final decoded = Assistant.fromJson({
        'id': 'h',
        'name': 'H',
        'kind': 'deepSeekHarness',
        'harnessUrl': _link,
      });

      expect(decoded.harnessConnectionMode, HarnessConnectionMode.publicLink);
      expect(decoded.harnessTailcatAddress, isNull);
      expect(decoded.harnessTailcatPort, 13080);
      expect(decoded.hasHarnessConnection, isTrue);
    });

    test(
      'an unknown transport falls back to link mode instead of losing the row',
      () {
        final decoded = Assistant.fromJson({
          'id': 'h',
          'name': 'H',
          'kind': 'deepSeekHarness',
          'harnessConnectionMode': 'carrier-pigeon',
        });

        expect(decoded.harnessConnectionMode, HarnessConnectionMode.publicLink);
        expect(decoded.kind, AssistantKind.deepSeekHarness);
      },
    );

    test('the peer port is normalized into a usable TCP port', () {
      expect(
        Assistant.fromJson({
          'id': 'h',
          'name': 'H',
          'kind': 'deepSeekHarness',
          'harnessTailcatPort': 0,
        }).harnessTailcatPort,
        13080,
      );
      expect(
        Assistant.fromJson({
          'id': 'h',
          'name': 'H',
          'kind': 'deepSeekHarness',
          'harnessTailcatPort': -1,
        }).harnessTailcatPort,
        13080,
      );
      expect(
        Assistant.fromJson({
          'id': 'h',
          'name': 'H',
          'kind': 'deepSeekHarness',
          'harnessTailcatPort': 70000,
        }).harnessTailcatPort,
        13080,
      );
      expect(
        Assistant.fromJson({
          'id': 'h',
          'name': 'H',
          'kind': 'deepSeekHarness',
          'harnessTailcatPort': 8443,
        }).harnessTailcatPort,
        8443,
      );
    });

    test('an empty or blank tailcat address is normalized to null', () {
      expect(
        Assistant.fromJson({
          'id': 'h',
          'name': 'H',
          'kind': 'deepSeekHarness',
          'harnessConnectionMode': 'tailcat',
          'harnessTailcatAddress': '   ',
        }).harnessTailcatAddress,
        isNull,
      );
    });

    test('saving a tailcat connection can retire the link in one copyWith', () {
      final linked = _harness(harnessUrl: _link);
      final tailcat = linked.copyWith(
        harnessConnectionMode: HarnessConnectionMode.tailcat,
        harnessTailcatAddress: _tailcatAddress,
        harnessTailcatPort: 14000,
        clearHarnessUrl: true,
      );

      expect(tailcat.harnessConnectionMode, HarnessConnectionMode.tailcat);
      expect(tailcat.harnessTailcatAddress, _tailcatAddress);
      expect(tailcat.harnessTailcatPort, 14000);
      expect(tailcat.harnessUrl, isNull);
      expect(tailcat.hasHarnessConnection, isTrue);
    });

    test('saving a link can retire the tailcat address in one copyWith', () {
      final tailcat = _tailcatHarness();
      final linked = tailcat.copyWith(
        harnessConnectionMode: HarnessConnectionMode.publicLink,
        harnessUrl: _link,
        clearHarnessTailcatAddress: true,
      );

      expect(linked.harnessConnectionMode, HarnessConnectionMode.publicLink);
      expect(linked.harnessUrl, _link);
      expect(linked.harnessTailcatAddress, isNull);
      expect(linked.harnessTailcatPort, 13080);
      expect(linked.hasHarnessConnection, isTrue);
    });

    test('unrelated edits preserve mode, address and port', () {
      final renamed = _tailcatHarness(port: 14000).copyWith(name: 'Renamed');

      expect(renamed.name, 'Renamed');
      expect(renamed.harnessConnectionMode, HarnessConnectionMode.tailcat);
      expect(renamed.harnessTailcatAddress, _tailcatAddress);
      expect(renamed.harnessTailcatPort, 14000);
    });

    test('a mixed list keeps one connection per assistant', () {
      final decoded = Assistant.decodeList(
        Assistant.encodeList([
          _harness(harnessUrl: _link),
          _tailcatHarness(port: 14000),
        ]),
      );

      expect(decoded, hasLength(2));
      expect(
        decoded[0].harnessConnectionMode,
        HarnessConnectionMode.publicLink,
      );
      expect(decoded[0].harnessUrl, _link);
      expect(decoded[1].harnessConnectionMode, HarnessConnectionMode.tailcat);
      expect(decoded[1].harnessTailcatAddress, _tailcatAddress);
      expect(decoded[1].harnessTailcatPort, 14000);
    });
  });
}

const _tailcatAddress =
    'tcAPpXUQeEXAMPLEaddressEXAMPLEaddressEXAMPLEaddressEXAMPLE00';

Assistant _tailcatHarness({
  String? address = _tailcatAddress,
  int port = 13080,
  String? harnessUrl,
}) => Assistant.harness(
  id: 'tailcat-harness',
  name: 'Tailcat DeepSeek Harness',
  harnessConnectionMode: HarnessConnectionMode.tailcat,
  harnessTailcatAddress: address,
  harnessTailcatPort: port,
  harnessUrl: harnessUrl,
);
