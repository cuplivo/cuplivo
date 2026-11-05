import 'dart:io';

import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/business_settings_router.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the registry, the single authority for what LAN sync carries (ADR-0003
/// decision 6). `business_settings_router.dart` holds the table; this file is the
/// contract a change to it has to meet, because a key that never syncs produces
/// no error and no warning — only a new device missing a setting.
void main() {
  const rules = BusinessKeyRegistry.rules;

  Iterable<String> keysWhere(bool Function(KeyRule rule) test) sync* {
    for (final entry in rules.entries) {
      if (test(entry.value)) yield entry.key;
    }
  }

  test('the synced face is pinned', () {
    final synced = keysWhere((rule) => rule.policy == KeyPolicy.synced).toList()
      ..sort();
    expect(synced, <String>[
      'app_locale_v1',
      'asr_selected_service_id_v1',
      'asr_services_v1',
      'assistant_tag_map_v1',
      'avatar_type',
      'avatar_value',
      'backup_reminder_enabled_v1',
      'backup_reminder_interval_days_v1',
      'backup_reminder_minutes_of_day_v1',
      'chat_bubble_style_overrides_v1',
      'chat_owner_order_v1',
      'compress_generation_thinking_enabled_v1',
      'compress_keep_user_messages_v1',
      'compress_limit_mode_v1',
      'compress_max_chars_v1',
      'compress_model_v1',
      'compress_prompt_v1',
      'custom_theme_selected_v1',
      'custom_themes_v1',
      'group_director_model_v1',
      'instruction_injections_active_ids_by_assistant_v1',
      'mcp_presentation_v1',
      'memory_extract_prompt_en_v1',
      'memory_extract_prompt_zh_v1',
      'memory_gate_prompt_en_v1',
      'memory_gate_prompt_zh_v1',
      'memory_injection_max_items_v1',
      'memory_legacy_mode_v1',
      'memory_legacy_prompt_en_v1',
      'memory_legacy_prompt_zh_v1',
      'memory_migrate_prompt_en_v1',
      'memory_migrate_prompt_zh_v1',
      'memory_migration_batch_size_v1',
      'memory_model_thinking_enabled_v1',
      'memory_model_v1',
      'memory_profile_distill_prompt_en_v1',
      'memory_profile_distill_prompt_zh_v1',
      'memory_prompt_lang_v1',
      'memory_rules_prompt_en_v1',
      'memory_rules_prompt_zh_v1',
      'memory_smart_add_batch_prompt_en_v1',
      'memory_smart_add_batch_prompt_zh_v1',
      'memory_smart_add_prompt_en_v1',
      'memory_smart_add_prompt_zh_v1',
      'ocr_enabled_v1',
      'ocr_generation_thinking_enabled_v1',
      'ocr_model_v1',
      'ocr_prompt_v1',
      'pinned_models_v1',
      'provider_group_map_v1',
      'provider_ungrouped_position_v1',
      's3_config_v1',
      'search_common_v1',
      'search_enabled_v1',
      'search_selected_v1',
      'suggestion_generation_enabled_v1',
      'suggestion_generation_thinking_enabled_v1',
      'suggestion_insert_on_tap_only_v1',
      'suggestion_model_v1',
      'suggestion_prompt_v1',
      'summary_generation_thinking_enabled_v1',
      'summary_model_v1',
      'summary_prompt_v1',
      'theme_mode_v1',
      'theme_palette_v1',
      'title_generation_enabled_v1',
      'title_generation_thinking_enabled_v1',
      'title_model_v1',
      'title_prompt_v1',
      'tool_schema_overrides_v1',
      'translate_generation_thinking_enabled_v1',
      'translate_model_v1',
      'translate_prompt_v1',
      'translate_target_lang_v1',
      'translate_visible_languages_v1',
      'tts_pitch_v1',
      'tts_selected_service_id_v1',
      'tts_speech_rate_v1',
      'use_dynamic_color_v1',
      'user_name',
      'webdav_config_v1',
      'world_books_active_ids_by_assistant_v1',
    ], reason: 'a change here changes what a paired device receives');
  });

  test('the organization of a synced entity rides sync', () {
    // #1062: the groups and the providers travelled; the assignment between them
    // did not. #1054: the tags and the instruction injections did the same. Four
    // keys, one rule — and the companion table below is what makes the fifth one
    // impossible.
    for (final key in <String>[
      'provider_group_map_v1',
      'assistant_tag_map_v1',
      'instruction_injections_active_ids_by_assistant_v1',
      'world_books_active_ids_by_assistant_v1',
      // Order is part of the organization: a group's own sort_order travels with
      // its row, and the synthetic "ungrouped" bucket's position travels here.
      'provider_ungrouped_position_v1',
    ]) {
      expect(BusinessKeyRegistry.isSynced(key), isTrue, reason: key);
    }
  });

  test('what this device is showing stays home', () {
    // The one deliberate exception is mcp_presentation_v1, whose collapsed set is
    // co-stored with MCP's groups; its rule note says so.
    for (final key in <String>[
      'provider_group_collapsed_v1',
      'assistant_tag_collapsed_v1',
      'world_books_collapsed_v1',
      'instruction_injection_group_collapsed_v1',
    ]) {
      expect(BusinessKeyRegistry.isSynced(key), isFalse, reason: key);
    }
    expect(
      BusinessKeyRegistry.isSynced('mcp_presentation_v1'),
      isTrue,
      reason: 'MCP groups live inside this blob, so it travels with them',
    );
  });

  test(
    'every entity kind has a companion row, and its companions are synced',
    () {
      expect(
        BusinessKeyRegistry.companionKeys.length,
        BusinessEntityKind.values.length,
        reason: 'one row per kind, empty when the kind needs no companion',
      );
      for (final kind in BusinessEntityKind.values) {
        final companions = BusinessKeyRegistry.companionKeys[kind];
        expect(companions, isNotNull, reason: '$kind has no row');
        for (final key in companions!) {
          expect(
            BusinessKeyRegistry.isSynced(key),
            isTrue,
            reason: '$kind → $key',
          );
          expect(BusinessKeyRegistry.entityKindFor(key), isNull, reason: key);
        }
      }
    },
  );

  test(
    'a key whose name promises ownership or a local view obeys its name',
    () {
      final ownership = RegExp(r'_by_assistant$|_tag_map_v1$|_group_map_v1$');
      for (final key in rules.keys) {
        if (ownership.hasMatch(key)) {
          expect(BusinessKeyRegistry.isSynced(key), isTrue, reason: key);
        }
        if (key.startsWith('window_') ||
            key.startsWith('desktop_') ||
            key.startsWith('display_')) {
          expect(BusinessKeyRegistry.isSynced(key), isFalse, reason: key);
        }
      }
    },
  );

  test('the table holds preferences only, and every row has a policy', () {
    for (final kind in BusinessEntityKind.values) {
      expect(
        rules.containsKey(kind.sourceKey),
        isFalse,
        reason: kind.sourceKey,
      );
    }
    expect(rules.containsKey(BusinessKeyRegistry.providerOrderKey), isFalse);
    expect(BusinessKeyRegistry.isProviderOrder('providers_order_v1'), isTrue);
    for (final rule in rules.values) {
      expect(rule.policy, isNotNull);
    }
    // The one key family outside the table: restore progress markers are minted
    // per run, so they are a prefix rule.
    expect(
      BusinessKeyRegistry.isPlatformOnly(
        'restore_archive_prune_cold_starts_v1',
      ),
      isTrue,
    );
    expect(rules.containsKey('restore_archive_prune_cold_starts_v1'), isFalse);
  });

  test('every reason is used, and the reasons that imply a policy do', () {
    final used = {for (final rule in rules.values) rule.reason};
    expect(
      used,
      containsAll(PolicyReason.values),
      reason: 'a reason with no key is a dead bucket; delete it',
    );
    for (final entry in rules.entries) {
      final rule = entry.value;
      if (rule.reason == PolicyReason.syncCompanionOfEntity) {
        expect(rule.policy, KeyPolicy.synced, reason: entry.key);
      }
      if (rule.reason == PolicyReason.deviceViewState) {
        expect(rule.policy, isNot(KeyPolicy.synced), reason: entry.key);
      }
      if (rule.reason == PolicyReason.notYetReviewed) {
        expect(rule.policy, isNot(KeyPolicy.synced), reason: entry.key);
      }
    }
  });

  test('the unreviewed set is explicit, so it can only shrink', () {
    // Every key here is device-local today because nobody recorded why, not
    // because the new-device test says so. Pinned on purpose: a new key cannot
    // join the list without editing this expectation, which is the moment to
    // decide instead.
    final unreviewed = keysWhere(
      (rule) => rule.reason == PolicyReason.notYetReviewed,
    ).toList()..sort();
    expect(unreviewed, <String>[
      'backup_encryption_enabled_v1',
      'chat_bubble_style_overrides_user_v1',
      'chat_edit_assistant_keep_thinking_tool_cards_v1',
      'chat_fork_keep_message_versions_v1',
      'image_compress_custom_quality_v1',
      'image_compress_transparent_enabled_v1',
      'image_compression_mode_v1',
      'image_cropper_enabled_v1',
      'image_upload_quality_v1',
      'learning_mode_enabled_v1',
      'learning_mode_prompt_v1',
      'manual_compress_format_v1',
      'manual_compress_max_long_edge_v1',
      'manual_compress_quality_v1',
      'memory_full_injection_types_v1',
      'per_chat_model_enabled_v1',
      'proactive_care_decision_model_v1',
      'reasoning_choice_by_model_v1',
      'search_web_fetch_v1',
      'send_markdown_image_links_as_images_v1',
      'tts_auto_play_assistant_replies_v1',
      'tts_cache_network_audio_for_replay_v1',
      'tts_text_selection_mode_v1',
    ]);
  });

  test('every preference key the app writes has a row', () {
    // The table can only be exhaustive over what the scan can discover, so the
    // scan resolves the one hop it used to miss: a write whose key argument is a
    // getter (`JsonBlobStore.writeAll` writes `setString(storageKey, …)`, which is
    // how desktop_scheduled_tasks_v1 once slipped through).
    final sources = <String, String>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (path.contains('/l10n/') || path.endsWith('.g.dart')) continue;
      sources[path] = entity.readAsStringSync();
    }
    expect(sources, isNotEmpty, reason: 'run this test from the package root');

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

    // One-hop getter resolution: `String get storageKey => _itemsKey;` in the
    // subclass file, with `_itemsKey` a constant in that same file.
    final getterPattern = RegExp(
      r"String\s+get\s+(\w+)\s*=>\s*(?:'([^']+)'|(\w+))\s*;",
    );
    final getterKeys = <String, Set<String>>{};
    for (final entry in sources.entries) {
      for (final match in getterPattern.allMatches(entry.value)) {
        final resolved =
            match.group(2) ?? constantsByFile[entry.key]![match.group(3)!];
        if (resolved == null) continue;
        getterKeys.putIfAbsent(match.group(1)!, () => <String>{}).add(resolved);
      }
    }
    expect(
      getterKeys['storageKey'],
      contains('desktop_scheduled_tasks_v1'),
      reason: 'the getter hop is what makes a JsonBlobStore write visible',
    );

    final keyPattern = RegExp(r'^[a-z][a-z0-9_]*_v\d+$');
    // The argument is not always one name: `setChatInputBackgroundOpacity`
    // writes `setDouble(brightness == Brightness.dark ? keyA : keyB, v)`, and a
    // one-name capture missed both keys until the debug assert fired on them in
    // CI. Every token of the argument is resolved instead.
    final writePattern = RegExp(
      r"[A-Za-z_][\w.]*\s*\.\s*"
      r'(?:setBool|setInt|setDouble|setString|setStringList)'
      r"\(\s*([^,()]+?)\s*,",
    );
    final tokenPattern = RegExp(r"'([^']*)'|([A-Za-z_]\w*)");
    final written = <String, String>{};
    for (final entry in sources.entries) {
      for (final match in writePattern.allMatches(entry.value)) {
        final candidates = <String>[];
        for (final token in tokenPattern.allMatches(match.group(1)!)) {
          final literal = token.group(1);
          if (literal != null) {
            candidates.add(literal);
            continue;
          }
          final name = token.group(2)!;
          final local = constantsByFile[entry.key]![name];
          if (local != null) candidates.add(local);
          final shared = sharedConstants[name];
          if (shared != null) candidates.add(shared);
          final viaGetter = getterKeys[name];
          if (viaGetter != null) candidates.addAll(viaGetter);
        }
        for (final key in candidates) {
          if (!keyPattern.hasMatch(key)) continue;
          written.putIfAbsent(key, () => entry.key);
        }
      }
    }

    // A scan that quietly matched nothing would guard nothing, so pin a floor and
    // a few keys the app certainly writes — including one only the getter hop can
    // see.
    expect(written.length, greaterThan(150));
    expect(
      written.keys,
      containsAll(<String>[
        'theme_mode_v1',
        'assistants_v1',
        'memory_model_v1',
        'custom_themes_v1',
        'local_snapshot_enabled_v1',
        'desktop_scheduled_tasks_v1',
      ]),
    );

    final unclassified = [
      for (final key in written.keys)
        if (!_isClassified(key)) '$key (${written[key]})',
    ]..sort();
    expect(
      unclassified,
      isEmpty,
      reason:
          'A key written to the preference store must have a row in '
          'BusinessKeyRegistry.rules: anything else is fail-closed and never '
          'syncs (ADR-0003 decision 6), which is how the memory model, the '
          'compress extras, the whole local-snapshot family and four '
          'organization keys (#1054, #1062) silently stayed behind.',
    );
  });
}

bool _isClassified(String key) =>
    BusinessKeyRegistry.ruleFor(key) != null ||
    BusinessKeyRegistry.entityKindFor(key) != null ||
    BusinessKeyRegistry.isProviderOrder(key) ||
    BusinessKeyRegistry.isPlatformOnly(key);
