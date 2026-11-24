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
}
