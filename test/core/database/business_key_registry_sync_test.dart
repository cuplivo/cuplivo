import 'dart:io';

import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/business_settings_router.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the sync face's membership. These lists are the single authority for
/// what LAN sync carries (ADR-0003 decision 6), so a change here is a change to
/// the wire face and should be a deliberate edit to this expectation too.
void main() {
  const synced = BusinessKeyRegistry.syncedPreferenceKeys;

  test('the synced set is a subset of the business preferences', () {
    for (final key in synced) {
      expect(
        BusinessKeyRegistry.preferenceKeys,
        contains(key),
        reason: '$key must still be an ordinary business preference',
      );
    }
  });

  test('every synced key classifies as syncedPreference', () {
    for (final key in synced) {
      expect(
        BusinessKeyRegistry.classify(key),
        BusinessKeyDisposition.syncedPreference,
        reason: key,
      );
    }
  });

  test('device-local keys are excluded by the new-device test', () {
    const deviceLocal = <String>[
      // Session position: where this device is looking, not how the app is set
      // up.
      'current_assistant_id_v1',
      'selected_model_v1',
      // Platform and window facts.
      'window_width_v1',
      'display_chat_font_scale_v1',
      'flutter_log_enabled_v1',
      // Local network environment.
      'global_proxy_enabled_v1',
      'global_proxy_host_v1',
      // Platform fallbacks and runtime state.
      'tts_engine_v1',
      'tts_language_v1',
      'app_launch_count_v1',
      'memory_trace_enabled_v1',
      'instruction_injections_active_ids_by_assistant_v1',
      'search_auto_test_on_launch_v1',
    ];
    for (final key in deviceLocal) {
      expect(synced, isNot(contains(key)), reason: key);
      expect(
        BusinessKeyRegistry.classify(key),
        isNot(BusinessKeyDisposition.syncedPreference),
        reason: key,
      );
    }
  });

  test('an unclassified key is fail-closed', () {
    expect(
      BusinessKeyRegistry.classify('some_future_key_v1'),
      BusinessKeyDisposition.unknownPreference,
    );
    expect(synced, isNot(contains('some_future_key_v1')));
  });

  test('skills and workspaces are entities but not part of this slice', () {
    // Both are entities to the router; the sync face adds its own exclusion
    // until skills travel with their directory blob (slice 3) and workspaces
    // stay device-local forever.
    for (final kind in [
      BusinessEntityKind.skill,
      BusinessEntityKind.workspace,
    ]) {
      expect(
        BusinessKeyRegistry.classify(kind.sourceKey),
        BusinessKeyDisposition.entity,
      );
    }
  });

  test('the synced face covers what a new device needs', () {
    // Named anchors from the ADR: assistants and providers are entities, and
    // these are the preference-side essentials.
    expect(synced, containsAll(<String>['user_name', 'avatar_type']));
    expect(synced, containsAll(<String>['theme_mode_v1', 'app_locale_v1']));
    expect(synced, containsAll(<String>['pinned_models_v1']));
    expect(synced, containsAll(<String>['webdav_config_v1', 's3_config_v1']));
    expect(
      BusinessKeyRegistry.classify(BusinessEntityKind.assistant.sourceKey),
      BusinessKeyDisposition.entity,
    );
    expect(
      BusinessKeyRegistry.classify(BusinessEntityKind.provider.sourceKey),
      BusinessKeyDisposition.entity,
    );
  });

  test('the families with a synced sibling ride sync too', () {
    // Each of these was written into `preference_rows` but left unclassified —
    // or classified without sync — while its own family already travelled, so a
    // paired device arrived with half a feature: memory prompts but no memory
    // model, a compress model and prompt but different limits, a
    // 'theme_palette_v1' naming a custom palette whose definition never came.
    expect(
      synced,
      containsAll(<String>[
        // Memory: the model is what auto-organize needs to run at all.
        'memory_model_v1',
        'memory_model_thinking_enabled_v1',
        'memory_legacy_mode_v1',
        'memory_injection_max_items_v1',
        // Legacy memories sync, so the new device runs that migration as well.
        'memory_migration_batch_size_v1',
        // Compress: the limits are part of the same configuration.
        'compress_generation_thinking_enabled_v1',
        'compress_limit_mode_v1',
        'compress_keep_user_messages_v1',
        'compress_max_chars_v1',
        // The ASR twin of an already-synced TTS key.
        'asr_selected_service_id_v1',
        // A custom palette is named by 'theme_palette_v1' and defined by these.
        'custom_themes_v1',
        'custom_theme_selected_v1',
      ]),
    );
  });

  test('every preference key the app writes is classified', () {
    // The registry is the single authority for what LAN sync carries (ADR-0003
    // decision 6), and an unclassified key is fail-closed: never synced. That
    // default is right for a key nobody has thought about, but it silently
    // swallowed whole families of real settings, because nothing checked the
    // *writers* — only the keys someone remembered to list here. So this test
    // walks the source instead.
    //
    // Coverage: the repo's `_vN` preference-key convention. The few business
    // preferences without that suffix ('user_name', 'avatar_type',
    // 'avatar_value') are pinned by the assertions above instead.
    final sources = <String, String>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (path.contains('/l10n/') || path.endsWith('.g.dart')) continue;
      sources[path] = entity.readAsStringSync();
    }
    expect(sources, isNotEmpty, reason: 'run this test from the package root');

    // A key is usually a named constant; resolve those first so a write naming
    // `_memoryModelKey` is checked under the key it actually stores. A file's own
    // declarations win over another file's constant of the same name.
    final constantPattern = RegExp(
      r"const\s+(?:String\s+)?(\w+)\s*=\s*'([^']+)'",
    );
    final constantsByFile = <String, Map<String, String>>{};
    final sharedConstants = <String, String>{};
    for (final entry in sources.entries) {
      final local = <String, String>{};
      for (final match in constantPattern.allMatches(entry.value)) {
        local[match.group(1)!] = match.group(2)!;
      }
      constantsByFile[entry.key] = local;
      for (final constant in local.entries) {
        sharedConstants.putIfAbsent(constant.key, () => constant.value);
      }
    }

    final keyPattern = RegExp(r'^[a-z][a-z0-9_]*_v\d+$');
    final writePattern = RegExp(
      r"[A-Za-z_][\w.]*\s*\.\s*"
      r'(?:setBool|setInt|setDouble|setString|setStringList)'
      r"\(\s*([A-Za-z_]\w*|'[^']*')\s*,",
    );
    final written = <String, String>{};
    for (final entry in sources.entries) {
      for (final match in writePattern.allMatches(entry.value)) {
        final argument = match.group(1)!;
        final key = argument.startsWith("'")
            ? argument.substring(1, argument.length - 1)
            : constantsByFile[entry.key]![argument] ??
                  sharedConstants[argument];
        if (key == null || !keyPattern.hasMatch(key)) continue;
        written.putIfAbsent(key, () => entry.key);
      }
    }
    // A scan that quietly matched nothing would guard nothing, so pin a floor
    // and a few keys the app certainly writes.
    expect(written.length, greaterThan(150));
    expect(
      written.keys,
      containsAll(<String>[
        'theme_mode_v1',
        'assistants_v1',
        'memory_model_v1',
        'custom_themes_v1',
        'local_snapshot_enabled_v1',
      ]),
    );

    final unclassified = [
      for (final key in written.keys)
        if (BusinessKeyRegistry.classify(key) ==
            BusinessKeyDisposition.unknownPreference)
          '$key (${written[key]})',
    ]..sort();
    expect(
      unclassified,
      isEmpty,
      reason:
          'A key written to the preference store must be classified in '
          'BusinessKeyRegistry: unclassified is fail-closed and never syncs '
          '(ADR-0003 decision 6), which is how the memory model, the compress '
          'extras, the custom themes and the whole local-snapshot family '
          'silently stayed behind. Add each key to syncedPreferenceKeys, '
          'preferenceKeys, localOnlyKeys or discardedKeys.',
    );
  });
}
