import 'dart:convert';

import 'package:Cuplivo/core/models/quick_instruction.dart';
import 'package:Cuplivo/core/services/backup/kelivo_quick_instruction_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String encodeUnified(List<QuickInstruction> items) =>
      jsonEncode(items.map((item) => item.toJson()).toList(growable: false));

  QuickInstruction item({
    required String id,
    required QuickInstructionPlacement placement,
    String title = '',
    String prompt = '',
    String group = '',
    QuickInstructionTriggerMode triggerMode =
        QuickInstructionTriggerMode.oneShot,
  }) {
    return QuickInstruction(
      id: id,
      title: title,
      prompt: prompt,
      group: group,
      placement: placement,
      triggerMode: triggerMode,
    );
  }

  group('KelivoQuickInstructionMapper.translateToLegacy', () {
    test('splits inputBox items into quick_phrases_v1 only', () {
      final settings = <String, dynamic>{
        KelivoQuickInstructionMapper.unifiedKey: encodeUnified([
          item(
            id: 'sys',
            placement: QuickInstructionPlacement.systemPrompt,
            title: 'System',
            prompt: 'sys prompt',
            group: 'Group A',
          ),
          item(
            id: 'phrase-global',
            placement: QuickInstructionPlacement.inputBox,
            title: 'Global Phrase',
            prompt: 'insert me',
          ),
          item(
            id: 'before',
            placement: QuickInstructionPlacement.beforeUserMessage,
            title: 'Before',
            prompt: 'before prompt',
            triggerMode: QuickInstructionTriggerMode.persistent,
          ),
          item(
            id: 'after',
            placement: QuickInstructionPlacement.afterUserMessage,
            title: 'After',
            prompt: 'after prompt',
          ),
        ]),
      };

      KelivoQuickInstructionMapper.translateToLegacy(settings);

      final injections =
          (jsonDecode(
                    settings[KelivoQuickInstructionMapper.unifiedKey] as String,
                  )
                  as List)
              .cast<Map<String, dynamic>>();
      expect(injections.map((json) => json['id']), [
        'sys',
        'before',
        'after',
      ], reason: 'inputBox items must be removed from the injection list');
      expect(injections.first['title'], 'System');
      expect(injections.first['prompt'], 'sys prompt');
      expect(injections.first['group'], 'Group A');

      final phrases =
          (jsonDecode(
                    settings[KelivoQuickInstructionMapper.quickPhrasesKey]
                        as String,
                  )
                  as List)
              .cast<Map<String, dynamic>>();
      expect(phrases, hasLength(1));
      expect(phrases.single, {
        'id': 'phrase-global',
        'title': 'Global Phrase',
        'content': 'insert me',
        'isGlobal': true,
        'assistantId': null,
      });
    });

    test('preserves unified fields for non-inputBox items', () {
      final settings = <String, dynamic>{
        KelivoQuickInstructionMapper.unifiedKey: encodeUnified([
          item(
            id: 'before',
            placement: QuickInstructionPlacement.beforeUserMessage,
            title: 'Before',
            prompt: 'before prompt',
            triggerMode: QuickInstructionTriggerMode.persistent,
          ),
        ]),
      };

      KelivoQuickInstructionMapper.translateToLegacy(settings);

      final injections =
          (jsonDecode(
                    settings[KelivoQuickInstructionMapper.unifiedKey] as String,
                  )
                  as List)
              .cast<Map<String, dynamic>>();
      final json = injections.single;
      expect(json['placement'], 'beforeUserMessage');
      expect(json['triggerMode'], 'persistent');
      expect(json.containsKey('toolPolicy'), isTrue);
    });

    test('is a no-op when the unified key is absent', () {
      final settings = <String, dynamic>{'theme_mode_v1': 'light'};

      KelivoQuickInstructionMapper.translateToLegacy(settings);

      expect(settings, {'theme_mode_v1': 'light'});
    });

    test('leaves the payload untouched when it is not valid JSON', () {
      final settings = <String, dynamic>{
        KelivoQuickInstructionMapper.unifiedKey: 'not json',
      };

      KelivoQuickInstructionMapper.translateToLegacy(settings);

      expect(settings[KelivoQuickInstructionMapper.unifiedKey], 'not json');
      expect(
        settings.containsKey(KelivoQuickInstructionMapper.quickPhrasesKey),
        isFalse,
      );
    });

    test('leaves the payload untouched when an item is not a map', () {
      final settings = <String, dynamic>{
        KelivoQuickInstructionMapper.unifiedKey: jsonEncode(['bad']),
      };

      KelivoQuickInstructionMapper.translateToLegacy(settings);

      expect(
        settings[KelivoQuickInstructionMapper.unifiedKey],
        jsonEncode(['bad']),
      );
      expect(
        settings.containsKey(KelivoQuickInstructionMapper.quickPhrasesKey),
        isFalse,
      );
    });

    test('empty library yields empty legacy lists', () {
      final settings = <String, dynamic>{
        KelivoQuickInstructionMapper.unifiedKey: '[]',
      };

      KelivoQuickInstructionMapper.translateToLegacy(settings);

      expect(settings[KelivoQuickInstructionMapper.unifiedKey], '[]');
      expect(settings[KelivoQuickInstructionMapper.quickPhrasesKey], '[]');
    });

    test('accepts an already-decoded list payload', () {
      final settings = <String, dynamic>{
        KelivoQuickInstructionMapper.unifiedKey: [
          item(
            id: 'phrase',
            placement: QuickInstructionPlacement.inputBox,
            title: 'P',
            prompt: 'body',
          ).toJson(),
        ],
      };

      KelivoQuickInstructionMapper.translateToLegacy(settings);

      final phrases =
          (jsonDecode(
                    settings[KelivoQuickInstructionMapper.quickPhrasesKey]
                        as String,
                  )
                  as List)
              .cast<Map<String, dynamic>>();
      expect(phrases.single['id'], 'phrase');
      expect(phrases.single['content'], 'body');
    });
  });
}
