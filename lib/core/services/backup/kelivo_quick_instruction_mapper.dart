import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/quick_instruction.dart';
import '../../models/quick_phrase.dart';

/// Splits Cuplivo's unified quick-instruction library back into the two legacy
/// Kelivo preference keys for the `kelivoLegacy` backup format.
///
/// ADR-0061 unified Quick Phrases (composer insertion) and Instruction
/// Injections (system/user-message placement) into one
/// `instruction_injections_v1` JSON list. Original Kelivo only understands the
/// pre-unification split:
/// - `quick_phrases_v1`: `QuickPhrase {id, title, content, isGlobal,
///   assistantId}` — items that write into the composer.
/// - `instruction_injections_v1`: `InstructionInjection {id, title, prompt,
///   group}` — items injected into the prompt.
///
/// An export meant for original Kelivo must therefore re-partition by
/// placement: `inputBox` items become quick phrases, everything else stays an
/// instruction injection.
///
/// Non-inputBox entries keep Cuplivo's full unified JSON (extra `placement` /
/// `triggerMode` / `toolPolicy` fields included). Original Kelivo's `fromJson`
/// ignores unknown keys, while Cuplivo's own restore reads them back to
/// preserve placement — projecting down to the v1 shape would downgrade
/// `beforeUserMessage` / `afterUserMessage` items to `systemPrompt` on
/// round-trip.
///
/// The unified model stores no assistant scope for `inputBox` items, so every
/// reconstructed quick phrase is global (`isGlobal: true`, no `assistantId`).
/// This mirrors the loss already accepted by the unification migration.
class KelivoQuickInstructionMapper {
  KelivoQuickInstructionMapper._();

  static const String unifiedKey = 'instruction_injections_v1';
  static const String quickPhrasesKey = 'quick_phrases_v1';

  /// Re-partitions `settings[unifiedKey]` into the legacy keys, in place.
  ///
  /// A no-op when [unifiedKey] is absent or unusable; in the latter case the
  /// original payload is left untouched and the failure is logged, so an
  /// export never silently drops the user's definitions.
  static void translateToLegacy(Map<String, dynamic> settings) {
    final raw = settings[unifiedKey];
    if (raw == null) return;

    final List<QuickInstruction> items;
    try {
      items = _decode(raw);
    } catch (error, stackTrace) {
      debugPrint(
        '[KelivoQuickInstructionMapper] $unifiedKey decode failed: '
        '$error\n$stackTrace',
      );
      return;
    }

    final phrases = <Map<String, dynamic>>[];
    final injections = <Map<String, dynamic>>[];
    for (final item in items) {
      if (item.isInputBox) {
        phrases.add(
          QuickPhrase(
            id: item.id,
            title: item.title,
            content: item.prompt,
          ).toJson(),
        );
      } else {
        injections.add(item.toJson());
      }
    }

    settings[unifiedKey] = jsonEncode(injections);
    settings[quickPhrasesKey] = jsonEncode(phrases);
  }

  static List<QuickInstruction> _decode(Object? raw) {
    final decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is! List) {
      throw const FormatException(
        'Unified quick instruction payload is not a list.',
      );
    }
    final items = <QuickInstruction>[];
    for (final value in decoded) {
      if (value is! Map) {
        throw const FormatException(
          'Unified quick instruction item is not a map.',
        );
      }
      items.add(QuickInstruction.fromJson(value.cast<String, dynamic>()));
    }
    return items;
  }
}
