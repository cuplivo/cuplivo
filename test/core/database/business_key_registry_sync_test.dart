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
      'compress_new_conversation',
      'compress_prompt_v1',
      'compression_defaults_v1',
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
      'native_compression_v1',
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
      'auto_retry_options',
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
    // Sorted: `listSync` returns filesystem order, and the same scan has to give
    // the same answer on every machine — an unsorted walk is what made an
    // earlier version of this test green on Windows and red on Linux CI.
    final paths = [
      for (final entity in Directory('lib').listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.dart'))
          entity.path.replaceAll(r'\', '/'),
    ]..sort();
    for (final path in paths) {
      if (path.contains('/l10n/') || path.endsWith('.g.dart')) continue;
      sources[path] = File(path).readAsStringSync();
    }
    expect(sources, isNotEmpty, reason: 'run this test from the package root');

    final constantPattern = RegExp(
      r"const\s+(?:String\s+)?(\w+)\s*=\s*'([^']+)'",
    );
    final constantsByFile = <String, Map<String, String>>{};
    for (final entry in sources.entries) {
      final local = <String, String>{};
      for (final match in constantPattern.allMatches(entry.value)) {
        local[match.group(1)!] = match.group(2)!;
      }
      constantsByFile[entry.key] = local;
    }

    // `Class.staticConst` — `ScheduledTaskStore.preferenceKey` in `main.dart` —
    // resolves through the class that declares it. A bare name is read from its
    // own file only: `key` is a JS snippet's name in one file and a closure
    // parameter in another, and resolving a bare name across every file made
    // this scan depend on directory listing order — green on Windows, red on
    // Linux CI, where a different file won the lookup (review of #1068).
    final classHeaderPattern = RegExp(r'^class\s+(\w+)', multiLine: true);
    final qualifiedArgumentPattern = RegExp(
      r'^([A-Za-z_]\w*)\.([A-Za-z_]\w*)$',
    );
    final staticConstants = <String, Map<String, String>>{};
    for (final entry in sources.entries) {
      final headers = [
        for (final match in classHeaderPattern.allMatches(entry.value))
          (name: match.group(1)!, at: match.start),
      ];
      if (headers.isEmpty) continue;
      for (final match in constantPattern.allMatches(entry.value)) {
        String? owner;
        for (final header in headers) {
          if (header.at < match.start) owner = header.name;
        }
        if (owner == null) continue;
        (staticConstants[owner] ??= <String, String>{})[match.group(1)!] = match
            .group(2)!;
      }
    }

    // A key can also be an entity's *source key*:
    // `static final String _profileKey = BusinessEntityKind.userProfileField.sourceKey`
    // (`memory_repository.dart`) writes the profile blob through this same store.
    // Resolved from the enum rather than from source, so the scan can name it.
    final entitySourceKeyPattern = RegExp(
      r'(?:static\s+(?:final|const)|final|const)\s+(?:String\s+)?(\w+)\s*=\s*'
      r'BusinessEntityKind\.(\w+)\.sourceKey',
    );
    final entitySourceKeys = {
      for (final kind in BusinessEntityKind.values) kind.name: kind.sourceKey,
    };
    final entityConstantsByFile = <String, Map<String, String>>{};
    for (final entry in sources.entries) {
      final local = <String, String>{};
      for (final match in entitySourceKeyPattern.allMatches(entry.value)) {
        final sourceKey = entitySourceKeys[match.group(2)!];
        if (sourceKey != null) local[match.group(1)!] = sourceKey;
      }
      entityConstantsByFile[entry.key] = local;
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
        // A getter can also be a *derived* value — `image_context.dart`'s
        // `key => '$messageId|$slot|$imageIndex'` — and treating that as a key
        // made any write whose argument happens to be called `key` look like a
        // writer of it. Only a getter that resolves to something static is one.
        if (resolved.contains(r'$')) continue;
        getterKeys.putIfAbsent(match.group(1)!, () => <String>{}).add(resolved);
      }
    }
    expect(
      getterKeys['storageKey'],
      contains('desktop_scheduled_tasks_v1'),
      reason: 'the getter hop is what makes a JsonBlobStore write visible',
    );

    // This scan is the exhaustive guard, so it does not filter by
    // `BusinessKeyRegistry.appKeyPattern`: that convention is narrower than the
    // app's real vocabulary. `user_name`, `avatar_type` and `avatar_value` are
    // synced and version-less, `auto_retry_options` was backed up and
    // version-less, and a scan that reads only `_vN` names cannot see any of
    // them — which is how the last one stayed outside the table while both
    // guards reported it clean (review of #1068). The debug assert in
    // `BusinessPreferences.setMany` keeps the narrower pattern on purpose: at
    // runtime it cannot tell an app key from a plugin's, so it must fail closed
    // for anything it does not recognise. Exhaustiveness is this test's job.
    //
    // The argument is not always one name: `setChatInputBackgroundOpacity`
    // writes `setDouble(brightness == Brightness.dark ? keyA : keyB, v)`, and a
    // one-name capture missed both keys until the debug assert fired on them in
    // CI. Every token of the argument is resolved instead, `'${_prefix}name'` is
    // expanded from the const the interpolation names (`desktop_side_panel_*`
    // writes five keys that way), and an argument nothing can resolve is a
    // failure rather than a silent pass.
    final writePattern = RegExp(
      r"[A-Za-z_][\w.]*\s*\.\s*"
      r'(?:setBool|setInt|setDouble|setString|setStringList)'
      r"\(\s*([^,()]+?)\s*,",
    );
    final tokenPattern = RegExp(r"'([^']*)'|([A-Za-z_]\w*)");
    final written = <String, String>{};
    final unresolved = <String>{};
    for (final entry in sources.entries) {
      final fileConstants = constantsByFile[entry.key]!;
      for (final match in writePattern.allMatches(entry.value)) {
        final argument = match.group(1)!;
        final candidates = <String>[];
        final qualified = qualifiedArgumentPattern.firstMatch(argument);
        if (qualified != null) {
          final staticValue =
              staticConstants[qualified.group(1)!]?[qualified.group(2)!];
          if (staticValue != null) candidates.add(staticValue);
        }
        for (final token in tokenPattern.allMatches(argument)) {
          final literal = token.group(1);
          if (literal != null) {
            final expanded = _expandInterpolations(literal, fileConstants);
            if (expanded != null) candidates.add(expanded);
            continue;
          }
          final name = token.group(2)!;
          final local = fileConstants[name];
          if (local != null) candidates.add(local);
          final entitySourceKey = entityConstantsByFile[entry.key]?[name];
          if (entitySourceKey != null) candidates.add(entitySourceKey);
          final viaGetter = getterKeys[name];
          if (viaGetter != null) candidates.addAll(viaGetter);
        }
        if (candidates.isEmpty) {
          // Every write the scan cannot name is listed, not skipped: an
          // identifier here is a parameter or a value the caller supplies, and
          // the list below pins the ones that exist so a new one is looked at.
          unresolved.add('$argument (${entry.key})');
        }
        for (final key in candidates) {
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
        // One key per shape the filter used to hide: version-less AND backed up
        // (`auto_retry_options`, the one that was missing from the table), and
        // built by interpolation (`'${_prefix}open_v1'`), which the scan now
        // expands from the const it names.
        'auto_retry_options',
        'desktop_side_panel_open_v1',
      ]),
    );

    // Pinned, not ignored: a write whose key argument the scan cannot name is
    // listed so a new one is seen. Both entries are parameters, and both keys
    // are accounted for elsewhere:
    //
    // - `_setDate(key, …)` in the backup reminder is called with
    //   `backup_reminder_enabled_at_v1` / `backup_reminder_last_backup_at_v1`,
    //   both rows in the table;
    // - `prefs.setInt(key, …)` in `main.dart` is `SharedPreferences`, not the
    //   business store: its key is `restore_archive_prune_cold_starts_v1`, which
    //   never travels anywhere.
    expect(unresolved.toList()..sort(), <String>[
      'key (lib/core/providers/backup_reminder_provider.dart)',
      'key (lib/main.dart)',
    ]);

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

/// A key literal with its same-file `'${name}'` interpolations substituted, or
/// null when the argument is built at runtime.
///
/// `desktop_side_panel_controller.dart` writes five keys as
/// `'${_prefix}open_v1'`, where `_prefix` is a `static const` in the same file.
/// Reading the literal verbatim yields `${_prefix}open_v1`, which is not a key
/// and matches no pattern, so the whole family used to be skipped in silence.
/// Anything still carrying a `$` after the substitution is dynamic — a value, or
/// a key no scan can name — and is reported separately rather than dropped.
String? _expandInterpolations(
  String literal,
  Map<String, String> fileConstants,
) {
  if (!literal.contains(r'$')) return literal;
  const unreadable = '\u0000';
  final replaced = literal.replaceAllMapped(
    RegExp(r'\$\{(\w+)\}'),
    (match) => fileConstants[match.group(1)!] ?? unreadable,
  );
  return replaced.contains(r'$') || replaced.contains(unreadable)
      ? null
      : replaced;
}
